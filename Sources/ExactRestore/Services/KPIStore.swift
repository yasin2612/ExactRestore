import AppKit
import Foundation
import Observation
import UniformTypeIdentifiers

enum KPIKeys {
    static let employees = "kpiEmployees"
    static let currentEmployee = "kpiCurrentEmployee"
    static let endpoint = "kpiEndpoint"
    static let apiKeyAccount = "kpiApiKey"
}

/// Employees, the local KPI history, and the upload queue. Shared by the main window and Settings.
@MainActor
@Observable
final class KPIStore {
    static let shared = KPIStore()

    private(set) var employees: [String]
    private(set) var currentEmployee: String?
    private(set) var history: [KPIEvent] = []
    private(set) var pendingCount = 0
    private(set) var lastUploadError: String?
    private(set) var lastUploadAt: Date?

    @ObservationIgnored private var pending: [KPIEvent] = []
    @ObservationIgnored private var isUploading = false
    @ObservationIgnored private var uploadLoop: Task<Void, Never>?
    private let directory: URL

    private static let historyLimit = 50_000
    private static let batchSize = 100

    private init() {
        let defaults = UserDefaults.standard
        employees = defaults.stringArray(forKey: KPIKeys.employees) ?? []
        currentEmployee = defaults.string(forKey: KPIKeys.currentEmployee)

        let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        directory = support.appendingPathComponent("ExactRestore", isDirectory: true)
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)

        history = load("history.json")
        pending = load("pending.json")
        pendingCount = pending.count

        if let current = currentEmployee, !employees.contains(current) { currentEmployee = nil }
        startUploadLoop()
    }

    // MARK: Employees

    func signIn(_ name: String) {
        guard employees.contains(name) else { return }
        currentEmployee = name
        UserDefaults.standard.set(name, forKey: KPIKeys.currentEmployee)
    }

    func signOut() {
        currentEmployee = nil
        UserDefaults.standard.removeObject(forKey: KPIKeys.currentEmployee)
    }

    @discardableResult
    func addEmployee(_ name: String) -> Bool {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, !employees.contains(where: { $0.caseInsensitiveCompare(trimmed) == .orderedSame }) else { return false }
        employees.append(trimmed)
        employees.sort { $0.localizedCaseInsensitiveCompare($1) == .orderedAscending }
        UserDefaults.standard.set(employees, forKey: KPIKeys.employees)
        return true
    }

    func removeEmployee(_ name: String) {
        employees.removeAll { $0 == name }
        UserDefaults.standard.set(employees, forKey: KPIKeys.employees)
        if currentEmployee == name { signOut() }
    }

    // MARK: Recording

    func record(_ event: KPIEvent) {
        history.append(event)
        if history.count > Self.historyLimit { history.removeFirst(history.count - Self.historyLimit) }
        pending.append(event)
        pendingCount = pending.count
        save(history, to: "history.json")
        save(pending, to: "pending.json")
        Task { await upload() }
    }

    func summary(since start: Date) -> [EmployeeSummary] {
        var byEmployee: [String: EmployeeSummary] = [:]
        for event in history where event.finishedAt >= start {
            var row = byEmployee[event.employee] ?? EmployeeSummary(employee: event.employee)
            switch (event.kind, event.result) {
            case (_, .failed): row.failed += 1
            case (.dfu, .succeeded): row.dfu += 1
            case (.restore, .succeeded): row.restores += 1
            case (.revive, .succeeded): row.revives += 1
            }
            if event.activation == "locked" { row.activationLocked += 1 }
            byEmployee[event.employee] = row
        }
        return byEmployee.values.sorted { $0.employee.localizedCaseInsensitiveCompare($1.employee) == .orderedAscending }
    }

    func exportCSV(since start: Date) {
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.commaSeparatedText]
        panel.nameFieldStringValue = "ExactRestore KPIs \(Self.fileDate.string(from: Date())).csv"
        guard panel.runModal() == .OK, let url = panel.url else { return }

        let header = "finished_at,employee,station,kind,result,port,ecid,device_type,device_name,ipsw,activation,duration_seconds,error"
        let rows: [String] = history
            .filter { $0.finishedAt >= start }
            .map(Self.csvRow)
        do {
            try ([header] + rows).joined(separator: "\n").write(to: url, atomically: true, encoding: .utf8)
        } catch {
            NSAlert(error: error).runModal()
        }
    }

    // MARK: Upload

    var endpoint: String { UserDefaults.standard.string(forKey: KPIKeys.endpoint) ?? "" }

    var isSyncConfigured: Bool { URL(string: endpoint)?.scheme?.hasPrefix("http") == true }

    func uploadNow() {
        Task { await upload() }
    }

    private func startUploadLoop() {
        uploadLoop = Task { [weak self] in
            while !Task.isCancelled {
                await self?.upload()
                try? await Task.sleep(for: .seconds(60))
            }
        }
    }

    /// Sends the queue in batches. Events stay queued until the server answers with 2xx.
    private func upload() async {
        guard !isUploading, !pending.isEmpty, isSyncConfigured, let url = URL(string: endpoint) else { return }
        isUploading = true
        defer { isUploading = false }

        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601

        while !pending.isEmpty {
            let batch = Array(pending.prefix(Self.batchSize))
            var request = URLRequest(url: url, timeoutInterval: 20)
            request.httpMethod = "POST"
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            if let key = Keychain.read(KPIKeys.apiKeyAccount) {
                request.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization")
            }

            do {
                request.httpBody = try encoder.encode(UploadBody(station: KPIEvent.stationName, events: batch))
                let (_, response) = try await URLSession.shared.data(for: request)
                let status = (response as? HTTPURLResponse)?.statusCode ?? 0
                guard (200..<300).contains(status) else {
                    lastUploadError = "Server answered \(status)"
                    return
                }
            } catch {
                lastUploadError = error.localizedDescription
                return
            }

            let sent = Set(batch.map(\.id))
            pending.removeAll { sent.contains($0.id) }
            pendingCount = pending.count
            save(pending, to: "pending.json")
            lastUploadError = nil
            lastUploadAt = Date()
        }
    }

    private struct UploadBody: Encodable {
        let station: String
        let events: [KPIEvent]
    }

    // MARK: Files

    private func load(_ name: String) -> [KPIEvent] {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        guard let data = try? Data(contentsOf: directory.appendingPathComponent(name)) else { return [] }
        return (try? decoder.decode([KPIEvent].self, from: data)) ?? []
    }

    private func save(_ events: [KPIEvent], to name: String) {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        guard let data = try? encoder.encode(events) else { return }
        try? data.write(to: directory.appendingPathComponent(name), options: .atomic)
    }

    private static let fileDate: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd"
        return formatter
    }()

    private static let isoFormatter = ISO8601DateFormatter()

    private static func csvRow(_ event: KPIEvent) -> String {
        let fields: [String] = [
            isoFormatter.string(from: event.finishedAt),
            event.employee,
            event.station,
            event.kind.rawValue,
            event.result.rawValue,
            event.port ?? "",
            event.ecid ?? "",
            event.deviceType ?? "",
            event.deviceName ?? "",
            event.ipsw ?? "",
            event.activation ?? "",
            String(event.durationSeconds),
            event.error ?? ""
        ]
        return fields.map(csvField).joined(separator: ",")
    }

    private static func csvField(_ value: String) -> String {
        guard value.contains(where: { $0 == "," || $0 == "\"" || $0 == "\n" }) else { return value }
        return "\"" + value.replacingOccurrences(of: "\"", with: "\"\"") + "\""
    }
}
