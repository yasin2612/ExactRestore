import Foundation

struct Device: Identifiable, Hashable {
    let ecid: String
    let name: String
    let deviceType: String
    let locationID: String

    var id: String { ecid }
}

struct HostPort: Identifiable, Hashable {
    let rid: Int
    let connection: PortConnection

    var id: Int { rid }
}

enum PortConnection: String {
    case none = "None"
    case source = "Source"
    case sink = "Sink"
    case unreadable = "Unreadable"
}

enum PortState: Equatable {
    case empty
    /// Sink means the other end supplies power, which is often a charger rather than a Mac.
    case connected(maybeCharger: Bool)
    case failed
    case queued
    case enteringDFU
    case inDFU
}

enum DeviceMode {
    case dfu
    case recovery
    case notDFU
    case unknown
}

enum ActivationStatus: Equatable {
    case unknown
    case clear
    case locked
}

enum JobKind: String {
    /// cfgutil restore: erases the Mac. Apple Silicon also gets macOS; T2 Macs get firmware only.
    case eraseInstall = "Restore"
    /// cfgutil revive: updates firmware and recoveryOS, keeps macOS and data.
    case reinstall = "Revive"
}

enum JobState: Equatable {
    case idle
    case running(JobKind, String)
    case succeeded(JobKind)
    case failed(JobKind, String)

    var isRunning: Bool {
        if case .running = self { return true }
        return false
    }
}
