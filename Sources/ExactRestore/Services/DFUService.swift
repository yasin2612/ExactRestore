import Foundation

/// Drives the bundled, patched `macvdmtool` for Apple Silicon hosts. Requires a NOPASSWD sudoers entry.
struct DFUService {
    let path: String

    func listPorts() async throws -> [HostPort] {
        let output = try await runTool(["list"])
        return Self.parsePorts(output)
    }

    /// Reboots the Mac cabled to host port `rid` into DFU.
    func enterDFU(rid: Int) async throws {
        _ = try await runTool(["dfu", String(rid)])
    }

    /// Force restarts the Mac on host port `rid` into normal mode, like holding the power button.
    func restart(rid: Int) async throws {
        _ = try await runTool(["restart", String(rid)])
    }

    private func runTool(_ arguments: [String]) async throws -> String {
        do {
            return try await ShellRunner.run("/usr/bin/sudo", ["-n", path] + arguments)
        } catch ShellError.failed(let status, let output) {
            // The tool prints its failure as "ERROR: ..."; surface that rather than the last line.
            if let line = output.split(whereSeparator: \.isNewline).last(where: { $0.hasPrefix("ERROR: ") }) {
                throw DFUError(message: String(line.dropFirst("ERROR: ".count)), output: output)
            }
            throw ShellError.failed(status: status, output: output)
        }
    }

    /// Parses lines like "PORT rid=1 connection=Source path=...".
    static func parsePorts(_ output: String) -> [HostPort] {
        output.split(whereSeparator: \.isNewline).compactMap { rawLine in
            guard rawLine.hasPrefix("PORT ") else { return nil }
            var fields: [String: String] = [:]
            for pair in rawLine.dropFirst("PORT ".count).split(separator: " ") {
                let parts = pair.split(separator: "=", maxSplits: 1)
                if parts.count == 2 { fields[String(parts[0])] = String(parts[1]) }
            }
            guard let rid = fields["rid"].flatMap({ Int($0) }) else { return nil }
            return HostPort(rid: rid, connection: PortConnection(rawValue: fields["connection"] ?? "") ?? .unreadable)
        }
        .sorted { $0.rid < $1.rid }
    }
}

struct DFUError: LocalizedError {
    let message: String
    let output: String

    var errorDescription: String? { message }
}
