import Foundation

/// Wraps Apple Configurator's `cfgutil`.
struct ConfiguratorService {
    let path: String

    func listDevices() async throws -> [Device] {
        let output = try await ShellRunner.run(path, ["--format", "JSON", "list"])
        return Self.parseDevices(output)
    }

    /// cfgutil option for a custom IPSW. Confirm with `cfgutil help restore` if a restore with a dropped file fails.
    static let ipswOption = "-I"

    /// Full wipe, then installs macOS from `ipsw`, or the latest signed version when nil.
    func eraseAndInstall(ecid: String, ipsw: URL?, onLine: @escaping @Sendable (String) -> Void) async throws {
        try await run("restore", ecid: ecid, ipsw: ipsw, onLine: onLine)
    }

    /// Reinstalls firmware and recoveryOS without erasing user data.
    func reinstall(ecid: String, ipsw: URL?, onLine: @escaping @Sendable (String) -> Void) async throws {
        try await run("revive", ecid: ecid, ipsw: ipsw, onLine: onLine)
    }

    private func run(_ command: String, ecid: String, ipsw: URL?, onLine: @escaping @Sendable (String) -> Void) async throws {
        var arguments = ["--ecid", ecid, command]
        if let ipsw { arguments += [Self.ipswOption, ipsw.path] }
        _ = try await ShellRunner.run(path, arguments, onLine: onLine)
    }

    /// Best effort. Macs usually drop off USB after a restore, and then nothing can be read.
    func activationState(ecid: String) async -> String? {
        guard
            let output = try? await ShellRunner.run(path, ["--format", "JSON", "--ecid", ecid, "get", "activationState"]),
            let data = output.data(using: .utf8),
            let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
            let devices = root["Output"] as? [String: Any],
            let info = devices[ecid] as? [String: Any]
        else { return nil }
        return info["activationState"] as? String
    }

    static func parseDevices(_ json: String) -> [Device] {
        guard
            let data = json.data(using: .utf8),
            let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
            let output = root["Output"] as? [String: Any]
        else { return [] }

        return output
            .compactMap { key, value -> Device? in
                guard let info = value as? [String: Any] else { return nil }
                let deviceType = info["deviceType"] as? String ?? "Unknown"
                return Device(
                    ecid: key,
                    name: info["name"] as? String ?? defaultName(for: deviceType),
                    deviceType: deviceType,
                    locationID: (info["locationID"] as? NSNumber)?.stringValue ?? ""
                )
            }
            .sorted { $0.locationID < $1.locationID }
    }

    /// `iBridge` is the T2 chip, which is what DFU exposes on T2 Intel Macs.
    private static func defaultName(for deviceType: String) -> String {
        deviceType.hasPrefix("iBridge") ? "Intel Mac (T2)" : "Apple Silicon Mac"
    }
}
