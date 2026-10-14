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

/// Live progress of a running job, parsed from cfgutil output.
struct JobProgress: Equatable {
    let startedAt: Date
    var line: String
    var step: Int?
    var totalSteps: Int?
    var stepName: String?
    /// Progress within the current step, 0...1.
    var stepFraction: Double?

    init(startedAt: Date = Date(), line: String) {
        self.startedAt = startedAt
        self.line = line
    }

    /// Overall 0...1 when steps are known, otherwise the current step's fraction.
    var overallFraction: Double? {
        if let step, let totalSteps, totalSteps > 0 {
            let within = stepFraction ?? 0
            return min(1, max(0, (Double(step - 1) + within) / Double(totalSteps)))
        }
        return stepFraction
    }
}

enum JobState: Equatable {
    case idle
    case running(JobKind, JobProgress)
    case succeeded(JobKind)
    case failed(JobKind, String)

    var isRunning: Bool {
        if case .running = self { return true }
        return false
    }
}
