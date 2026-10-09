import Foundation

/// One unit of work by an employee. This is the payload sent to the KPI API.
struct KPIEvent: Codable, Identifiable, Hashable {
    enum Kind: String, Codable {
        case dfu
        case restore
        case revive
    }

    enum Result: String, Codable {
        case succeeded
        case failed
    }

    let id: UUID
    let kind: Kind
    let result: Result
    let employee: String
    let station: String
    let port: String?
    let ecid: String?
    let deviceType: String?
    let deviceName: String?
    let ipsw: String?
    let activation: String?
    let error: String?
    let startedAt: Date
    let finishedAt: Date
    let durationSeconds: Int

    init(
        kind: Kind,
        result: Result,
        employee: String,
        port: String? = nil,
        ecid: String? = nil,
        deviceType: String? = nil,
        deviceName: String? = nil,
        ipsw: String? = nil,
        activation: String? = nil,
        error: String? = nil,
        startedAt: Date,
        finishedAt: Date = Date()
    ) {
        self.id = UUID()
        self.kind = kind
        self.result = result
        self.employee = employee
        self.station = KPIEvent.stationName
        self.port = port
        self.ecid = ecid
        self.deviceType = deviceType
        self.deviceName = deviceName
        self.ipsw = ipsw
        self.activation = activation
        self.error = error
        self.startedAt = startedAt
        self.finishedAt = finishedAt
        self.durationSeconds = max(0, Int(finishedAt.timeIntervalSince(startedAt).rounded()))
    }

    static let stationName = Host.current().localizedName ?? "Mac"
}

struct EmployeeSummary: Identifiable {
    let employee: String
    var dfu = 0
    var restores = 0
    var revives = 0
    var failed = 0
    var activationLocked = 0

    var id: String { employee }
}
