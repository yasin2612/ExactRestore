import Foundation

enum HostSetupError: LocalizedError {
    case missingBundledTool
    case cancelled

    var errorDescription: String? {
        switch self {
        case .missingBundledTool: "macvdmtool is not bundled in this app. Rebuild it with scripts/build-app.sh."
        case .cancelled: "Setup was cancelled."
        }
    }
}

/// Installs the bundled macvdmtool and a NOPASSWD sudoers entry, with a single admin prompt.
enum HostSetupService {
    static let installPath = "/usr/local/bin/macvdmtool"
    static let sudoersPath = "/etc/sudoers.d/macvdmtool"

    static var bundledTool: String? {
        Bundle.main.path(forResource: "macvdmtool", ofType: nil)
    }

    /// Ready when the tool is installed and passwordless sudo is active for it.
    static func isReady() async -> Bool {
        guard
            FileManager.default.isExecutableFile(atPath: installPath),
            FileManager.default.fileExists(atPath: sudoersPath)
        else { return false }

        // A rebuilt app may bundle a newer tool; setup must run again to install it.
        if let bundledTool, !FileManager.default.contentsEqual(atPath: bundledTool, andPath: installPath) {
            return false
        }

        // Running without arguments only prints usage. We only care whether sudo asked for a password.
        do {
            _ = try await ShellRunner.run("/usr/bin/sudo", ["-n", installPath])
            return true
        } catch ShellError.failed(_, let output) {
            return !isPasswordError(output)
        } catch {
            return false
        }
    }

    static func isPasswordError(_ output: String) -> Bool {
        output.localizedCaseInsensitiveContains("password is required")
    }

    static func install() async throws {
        guard let source = bundledTool else { throw HostSetupError.missingBundledTool }

        let rule = "\(NSUserName()) ALL=(root) NOPASSWD: \(installPath)"
        let script = [
            "set -e",
            "mkdir -p /usr/local/bin",
            "install -m 755 \(quote(source)) \(installPath)",
            "xattr -d com.apple.quarantine \(installPath) 2>/dev/null || true",
            "tmp=$(mktemp)",
            "echo \(quote(rule)) > \"$tmp\"",
            "visudo -cf \"$tmp\"",
            "install -m 440 -o root -g wheel \"$tmp\" \(sudoersPath)",
            "rm -f \"$tmp\""
        ].joined(separator: "\n")

        let appleScript = "do shell script \"\(escapeForAppleScript(script))\" with administrator privileges"

        do {
            _ = try await ShellRunner.run("/usr/bin/osascript", ["-e", appleScript])
        } catch ShellError.failed(_, let output) where output.contains("-128") {
            throw HostSetupError.cancelled
        }
    }

    private static func quote(_ value: String) -> String {
        "'" + value.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }

    private static func escapeForAppleScript(_ value: String) -> String {
        value
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
    }
}
