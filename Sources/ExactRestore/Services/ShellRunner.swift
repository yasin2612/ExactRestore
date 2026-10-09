import Foundation

enum ShellError: LocalizedError {
    case failed(status: Int32, output: String)

    var errorDescription: String? {
        switch self {
        case let .failed(status, output):
            let lastLine = output
                .split(whereSeparator: \.isNewline)
                .last { !$0.trimmingCharacters(in: .whitespaces).isEmpty }
            return lastLine.map(String.init) ?? "Command failed with exit code \(status)"
        }
    }
}

private final class OutputBuffer: @unchecked Sendable {
    private var storage = ""
    private let lock = NSLock()

    func append(_ text: String) {
        lock.lock()
        storage += text
        lock.unlock()
    }

    var value: String {
        lock.lock()
        defer { lock.unlock() }
        return storage
    }
}

enum ShellRunner {
    /// Runs a command and returns combined stdout and stderr. `onLine` receives output lines as they arrive (background thread).
    static func run(
        _ executable: String,
        _ arguments: [String],
        onLine: (@Sendable (String) -> Void)? = nil
    ) async throws -> String {
        try await withCheckedThrowingContinuation { continuation in
            let process = Process()
            let pipe = Pipe()
            let buffer = OutputBuffer()

            process.executableURL = URL(fileURLWithPath: executable)
            process.arguments = arguments
            process.standardOutput = pipe
            process.standardError = pipe

            pipe.fileHandleForReading.readabilityHandler = { handle in
                let data = handle.availableData
                guard !data.isEmpty, let text = String(data: data, encoding: .utf8) else { return }
                buffer.append(text)
                text.split(whereSeparator: \.isNewline).forEach { onLine?(String($0)) }
            }

            process.terminationHandler = { finished in
                pipe.fileHandleForReading.readabilityHandler = nil
                let rest = pipe.fileHandleForReading.readDataToEndOfFile()
                if let text = String(data: rest, encoding: .utf8) { buffer.append(text) }

                if finished.terminationStatus == 0 {
                    continuation.resume(returning: buffer.value)
                } else {
                    continuation.resume(throwing: ShellError.failed(status: finished.terminationStatus, output: buffer.value))
                }
            }

            do {
                try process.run()
            } catch {
                pipe.fileHandleForReading.readabilityHandler = nil
                continuation.resume(throwing: error)
            }
        }
    }
}
