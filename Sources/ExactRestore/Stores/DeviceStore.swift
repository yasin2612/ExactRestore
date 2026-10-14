import Foundation
import Observation

@MainActor
@Observable
final class DeviceStore {
    private(set) var connected: Set<String> = []
    private(set) var modes: [String: DeviceMode] = [:]
    private(set) var jobs: [String: JobState] = [:]
    private(set) var activation: [String: ActivationStatus] = [:]
    /// Recent tool output per Mac, kept in memory only.
    private(set) var logs: [String: [String]] = [:]
    private(set) var portNames: [Int: String] = PortNameStore.load()
    private(set) var listError: String?
    private(set) var isEnteringDFU = false
    private(set) var hostReady = false
    private(set) var isSettingUpHost = false
    private(set) var ports: [HostPort] = []
    private(set) var selectedPorts: Set<Int> = []
    /// Port currently being sent DFU, and ports waiting their turn.
    private(set) var currentDFUPort: Int?
    private(set) var dfuQueue: [Int] = []
    private(set) var failedPorts: Set<Int> = []
    /// True only while macvdmtool is running a DFU command, so port listing never overlaps it.
    private var isToolBusy = false
    /// Learned when a Mac appears in DFU after a command to a specific port. Session only.
    private(set) var portForECID: [String: Int] = [:]
    var selection: Set<String> = []
    var alertMessage: String?

    private var known: [String: Device] = [:]
    private var batchSucceeded = 0
    private var batchFailed = 0
    private var pollTask: Task<Void, Never>?

    private let configurator = Tools.locate(Tools.cfgutil).map(ConfiguratorService.init(path:))
    private var dfu: DFUService? {
        remoteDFUSupported && hostReady ? DFUService(path: HostSetupService.installPath) : nil
    }

    /// macvdmtool talks to Apple Silicon USB C controllers, so remote DFU needs an Apple Silicon host.
    var remoteDFUSupported: Bool {
        #if arch(arm64)
        true
        #else
        false
        #endif
    }

    /// Connected devices plus any device with a job (targets drop off USB while restoring).
    var devices: [Device] {
        known.values
            .filter { connected.contains($0.ecid) || jobs[$0.ecid] != nil }
            .sorted { $0.locationID < $1.locationID }
    }

    var configuratorMissing: Bool { configurator == nil }

    let kpi = KPIStore.shared

    /// Work is only allowed while someone is signed in, so every count has an owner.
    var isSignedIn: Bool { kpi.currentEmployee != nil }

    var canEnterDFU: Bool { dfu != nil && !selectedPorts.isEmpty && isSignedIn }

    var showsPorts: Bool { dfu != nil && !ports.isEmpty }

    func canRun(on ecids: Set<String>) -> Bool {
        configurator != nil && isSignedIn && ecids.contains(where: isRunnable)
    }

    func mode(for ecid: String) -> DeviceMode { modes[ecid] ?? .unknown }

    func runnable(_ ecids: Set<String>) -> Set<String> { ecids.filter(isRunnable) }

    var readyCount: Int { connected.filter(isRunnable).count }

    func toggleSelection(_ ecid: String) {
        if selection.contains(ecid) { selection.remove(ecid) } else { selection.insert(ecid) }
    }

    func selectAllReady() { selection = connected.filter(isRunnable) }

    func clearSelection() { selection = [] }

    /// Unknown is allowed so a failed USB read never blocks work.
    private func isRunnable(_ ecid: String) -> Bool {
        guard connected.contains(ecid), !state(for: ecid).isRunning else { return false }
        let mode = mode(for: ecid)
        return mode == .dfu || mode == .unknown
    }

    func state(for ecid: String) -> JobState { jobs[ecid] ?? .idle }

    func isConnected(_ ecid: String) -> Bool { connected.contains(ecid) }

    func checkHost() async {
        guard remoteDFUSupported else { return }
        hostReady = await HostSetupService.isReady()
    }

    func setUpHost() {
        guard !isSettingUpHost else { return }
        isSettingUpHost = true
        Task {
            defer { isSettingUpHost = false }
            do {
                try await HostSetupService.install()
                await checkHost()
                if !hostReady {
                    alertMessage = "Setup finished, but remote DFU is still unavailable on this Mac."
                }
            } catch HostSetupError.cancelled {
                return
            } catch {
                alertMessage = "Setup failed: \(error.localizedDescription)"
            }
        }
    }

    func startPolling() {
        guard pollTask == nil else { return }
        pollTask = Task { [weak self] in
            while !Task.isCancelled {
                await self?.refresh()
                await self?.refreshPorts()
                try? await Task.sleep(for: .seconds(3))
            }
        }
    }

    func refresh() async {
        guard let configurator else { return }
        do {
            let list = try await configurator.listDevices()
            let usbModes = await USBModeService.modesByECID()
            list.forEach { known[$0.ecid] = $0 }
            connected = Set(list.map(\.ecid))
            modes = Dictionary(uniqueKeysWithValues: list.map { device in
                guard let usbModes else { return (device.ecid, DeviceMode.unknown) }
                let ecid = USBModeService.ecid(fromCfgutil: device.ecid)
                return (device.ecid, ecid.flatMap { usbModes[$0] } ?? .notDFU)
            })
            selection = selection.filter { known[$0] != nil }
            listError = nil
        } catch {
            listError = error.localizedDescription
        }
    }

    // MARK: Host ports

    func portName(_ rid: Int) -> String {
        portNames[rid] ?? "Port \(rid)"
    }

    func renamePort(_ rid: Int, to name: String) {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty { portNames[rid] = nil } else { portNames[rid] = trimmed }
        PortNameStore.save(portNames)
    }

    func port(for ecid: String) -> Int? { portForECID[ecid] }

    func portState(_ port: HostPort) -> PortState {
        if currentDFUPort == port.rid { return .enteringDFU }
        if dfuQueue.contains(port.rid) { return .queued }
        switch port.connection {
        case .none, .unreadable:
            return .empty
        case .source, .sink:
            let hasMacInDFU = portForECID.contains { ecid, rid in
                rid == port.rid && connected.contains(ecid) && modes[ecid] == .dfu
            }
            if hasMacInDFU { return .inDFU }
            if failedPorts.contains(port.rid) { return .failed }
            return .connected(maybeCharger: port.connection == .sink)
        }
    }

    func canSelectPort(_ port: HostPort) -> Bool {
        switch portState(port) {
        case .connected, .failed: true
        default: false
        }
    }

    var waitingPorts: [HostPort] {
        ports.filter { portState($0) == .connected(maybeCharger: false) }
    }

    func togglePort(_ port: HostPort) {
        guard canSelectPort(port) else { return }
        if selectedPorts.contains(port.rid) { selectedPorts.remove(port.rid) } else { selectedPorts.insert(port.rid) }
    }

    func selectWaitingPorts() {
        selectedPorts.formUnion(waitingPorts.map(\.rid))
    }

    func cancelQueuedPorts() {
        dfuQueue = []
    }

    func refreshPorts() async {
        guard let dfu, !isToolBusy else { return }
        guard let list = try? await dfu.listPorts() else { return }

        ports = list
        let emptyPorts = Set(list.filter { $0.connection == .none || $0.connection == .unreadable }.map(\.rid))
        portForECID = portForECID.filter { !emptyPorts.contains($0.value) }
        failedPorts.subtract(emptyPorts)
        dfuQueue.removeAll { emptyPorts.contains($0) }
        selectedPorts = selectedPorts.filter { rid in list.contains { $0.rid == rid && canSelectPort($0) } }
    }

    func canRestartPort(_ port: HostPort) -> Bool {
        guard dfu != nil, isSignedIn, currentDFUPort != port.rid, !dfuQueue.contains(port.rid) else { return false }
        return port.connection == .source || port.connection == .sink
    }

    /// True when a Restore or Revive is running on a Mac known to be on this port.
    func hasRunningJob(onPort rid: Int) -> Bool {
        portForECID.contains { ecid, portRID in portRID == rid && state(for: ecid).isRunning }
    }

    func restartPort(_ rid: Int) {
        guard let dfu, isSignedIn, !isToolBusy else {
            alertMessage = "The DFU tool is busy. Try again in a moment."
            return
        }
        Task {
            isToolBusy = true
            defer { isToolBusy = false }
            do {
                try await dfu.restart(rid: rid)
                failedPorts.remove(rid)
                portForECID = portForECID.filter { $0.value != rid }
            } catch ShellError.failed(_, let output) where HostSetupService.isPasswordError(output) {
                hostReady = false
                alertMessage = "This Mac needs setup before it can restart targets. Click Set up this Mac."
            } catch {
                alertMessage = "Could not restart the Mac on \(portName(rid)): \(error.localizedDescription)"
            }
        }
    }

    private var ecidsInDFU: Set<String> {
        connected.filter { modes[$0] == .dfu }
    }

    /// Adds the selected ports to the queue. Ports stay selectable while the queue runs.
    func enterDFUOnSelectedPorts() {
        guard dfu != nil, !selectedPorts.isEmpty, isSignedIn else { return }
        let newPorts = selectedPorts.sorted().filter { $0 != currentDFUPort && !dfuQueue.contains($0) }
        failedPorts.subtract(newPorts)
        dfuQueue.append(contentsOf: newPorts)
        selectedPorts = []

        guard !isEnteringDFU else { return }
        isEnteringDFU = true
        Task { await processDFUQueue() }
    }

    /// One port at a time so each Mac that appears can be matched to its port.
    private func processDFUQueue() async {
        defer {
            isEnteringDFU = false
            currentDFUPort = nil
        }

        var problems: [String] = []
        while let dfu, !dfuQueue.isEmpty {
            let rid = dfuQueue.removeFirst()
            currentDFUPort = rid
            let before = ecidsInDFU
            let employee = kpi.currentEmployee ?? "Unknown"
            let startedAt = Date()

            do {
                isToolBusy = true
                defer { isToolBusy = false }
                try await dfu.enterDFU(rid: rid)
            } catch ShellError.failed(_, let output) where HostSetupService.isPasswordError(output) {
                hostReady = false
                dfuQueue = []
                alertMessage = "This Mac needs setup before it can enter DFU. Click Set up this Mac."
                return
            } catch {
                failedPorts.insert(rid)
                problems.append("\(portName(rid)): \(error.localizedDescription)")
                kpi.record(KPIEvent(
                    kind: .dfu, result: .failed, employee: employee, port: portName(rid),
                    error: error.localizedDescription, startedAt: startedAt
                ))
                continue
            }

            if let ecid = await waitForNewDFU(excluding: before) {
                portForECID[ecid] = rid
                kpi.record(KPIEvent(
                    kind: .dfu, result: .succeeded, employee: employee, port: portName(rid), ecid: ecid,
                    deviceType: known[ecid]?.deviceType, deviceName: known[ecid]?.name, startedAt: startedAt
                ))
            } else {
                failedPorts.insert(rid)
                kpi.record(KPIEvent(
                    kind: .dfu, result: .failed, employee: employee, port: portName(rid),
                    error: "Mac did not appear in DFU", startedAt: startedAt
                ))
                problems.append("\(portName(rid)): the Mac got the DFU command but never appeared. Cable it by its DFU port and use a data cable, not a charging cable.")
            }
        }

        if !problems.isEmpty {
            alertMessage = problems.joined(separator: "\n\n")
        }
    }

    private func waitForNewDFU(excluding before: Set<String>) async -> String? {
        for _ in 0..<10 {
            try? await Task.sleep(for: .seconds(2))
            await refresh()
            if let ecid = ecidsInDFU.subtracting(before).first { return ecid }
        }
        return nil
    }

    var runningCount: Int { jobs.values.filter(\.isRunning).count }

    func run(_ kind: JobKind, on ecids: Set<String>, ipsw: URL? = nil) {
        guard let configurator, let employee = kpi.currentEmployee else { return }

        for ecid in ecids where isRunnable(ecid) {
            let startedAt = Date()
            jobs[ecid] = .running(kind, JobProgress(line: ipsw.map { "Starting with \($0.lastPathComponent)" } ?? "Starting"))
            AlertService.setDockBadge(runningCount)
            activation[ecid] = nil
            logs[ecid] = []

            let onLine: @Sendable (String) -> Void = { [weak self] line in
                Task { @MainActor in self?.updateProgress(ecid: ecid, kind: kind, line: line) }
            }

            Task {
                do {
                    switch kind {
                    case .eraseInstall: try await configurator.eraseAndInstall(ecid: ecid, ipsw: ipsw, onLine: onLine)
                    case .reinstall: try await configurator.reinstall(ecid: ecid, ipsw: ipsw, onLine: onLine)
                    }
                    jobs[ecid] = .succeeded(kind)
                    AlertService.setDockBadge(runningCount)
                    batchSucceeded += 1
                    await checkActivation(ecid: ecid, using: configurator)
                    recordJob(kind, .succeeded, ecid: ecid, employee: employee, ipsw: ipsw, error: nil, startedAt: startedAt)
                } catch {
                    let message = error.localizedDescription
                    jobs[ecid] = .failed(kind, message)
                    AlertService.setDockBadge(runningCount)
                    batchFailed += 1
                    if Self.mentionsActivationLock(message) { activation[ecid] = .locked }
                    recordJob(kind, .failed, ecid: ecid, employee: employee, ipsw: ipsw, error: message, startedAt: startedAt)
                    AlertService.notify(
                        title: "\(kind.rawValue) failed",
                        body: "\(describe(ecid)): \(message)",
                        success: false
                    )
                }
                finishBatchIfDone()
            }
        }
    }

    private func recordJob(
        _ kind: JobKind, _ result: KPIEvent.Result, ecid: String, employee: String,
        ipsw: URL?, error: String?, startedAt: Date
    ) {
        let activationText: String? = switch activation[ecid] {
        case .locked: "locked"
        case .clear: "clear"
        case .unknown: "unknown"
        case nil: nil
        }
        kpi.record(KPIEvent(
            kind: kind == .eraseInstall ? .restore : .revive,
            result: result,
            employee: employee,
            port: portForECID[ecid].map(portName),
            ecid: ecid,
            deviceType: known[ecid]?.deviceType,
            deviceName: known[ecid]?.name,
            ipsw: ipsw?.lastPathComponent,
            activation: activationText,
            error: error,
            startedAt: startedAt
        ))
    }

    func clearFinished() {
        let finished = Set(jobs.filter { !$0.value.isRunning }.keys)
        jobs = jobs.filter { $0.value.isRunning }
        finished.forEach { activation[$0] = nil; logs[$0] = nil }
    }

    func activationStatus(for ecid: String) -> ActivationStatus? { activation[ecid] }

    func log(for ecid: String) -> [String] { logs[ecid] ?? [] }

    private func checkActivation(ecid: String, using configurator: ConfiguratorService) async {
        guard activation[ecid] != .locked else { return }
        guard let state = await configurator.activationState(ecid: ecid) else {
            activation[ecid] = activation[ecid] ?? .unknown
            return
        }
        if Self.mentionsActivationLock(state) {
            activation[ecid] = .locked
        } else if state.caseInsensitiveCompare("Activated") == .orderedSame {
            activation[ecid] = .clear
        } else {
            activation[ecid] = .unknown
        }
    }

    private static func mentionsActivationLock(_ text: String) -> Bool {
        let lower = text.lowercased()
        return lower.contains("activation lock") || lower.contains("activation locked") || lower.contains("activationlock")
    }

    /// One summary when the last running job ends, so a big batch does not flood notifications.
    private func finishBatchIfDone() {
        guard runningCount == 0, batchSucceeded + batchFailed > 0 else { return }
        let locked = activation.values.filter { $0 == .locked }.count
        var body = "\(batchSucceeded) succeeded, \(batchFailed) failed."
        if locked > 0 { body += " \(locked) Activation Locked." }
        AlertService.notify(title: "All jobs finished", body: body, success: batchFailed == 0 && locked == 0)
        batchSucceeded = 0
        batchFailed = 0
    }

    private func describe(_ ecid: String) -> String {
        let name = known[ecid]?.name ?? "Mac"
        return portForECID[ecid].map { "\(name) on \(portName($0))" } ?? name
    }

    private func updateProgress(ecid: String, kind: JobKind, line: String) {
        let cleaned = ProgressParser.clean(line)
        guard !cleaned.isEmpty else { return }

        var lines = logs[ecid] ?? []
        lines.append(cleaned)
        logs[ecid] = Array(lines.suffix(300))

        if Self.mentionsActivationLock(cleaned) { activation[ecid] = .locked }

        guard case .running(let runningKind, var progress) = state(for: ecid) else { return }
        ProgressParser.apply(cleaned, to: &progress)
        jobs[ecid] = .running(runningKind, progress)
    }
}

/// Port names are saved per host Mac, since RIDs map to different physical ports on each model.
enum PortNameStore {
    private static let key = "portNames"

    static func load() -> [Int: String] {
        let stored = UserDefaults.standard.dictionary(forKey: key) as? [String: String] ?? [:]
        return Dictionary(uniqueKeysWithValues: stored.compactMap { key, value in Int(key).map { ($0, value) } })
    }

    static func save(_ names: [Int: String]) {
        UserDefaults.standard.set(Dictionary(uniqueKeysWithValues: names.map { (String($0.key), $0.value) }), forKey: key)
    }
}
