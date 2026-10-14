import Foundation

/// Reads lines like "Step 2 of 4: Downloading System" and "45%" from cfgutil output.
enum ProgressParser {
    private static let stepPattern = try! NSRegularExpression(
        pattern: #"step\s+(\d+)\s+of\s+(\d+)\s*[:\-]?\s*([^\d%]*)"#,
        options: [.caseInsensitive]
    )
    private static let percentPattern = try! NSRegularExpression(pattern: #"(\d{1,3}(?:\.\d+)?)\s?%"#)
    private static let ansiPattern = try! NSRegularExpression(pattern: #"\u001B\[[0-9;?]*[A-Za-z]"#)

    static func clean(_ line: String) -> String {
        let range = NSRange(line.startIndex..., in: line)
        return ansiPattern.stringByReplacingMatches(in: line, range: range, withTemplate: "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    static func apply(_ line: String, to progress: inout JobProgress) {
        progress.line = line
        let range = NSRange(line.startIndex..., in: line)

        if let match = stepPattern.firstMatch(in: line, range: range),
           let step = Int(text(match, 1, in: line)),
           let total = Int(text(match, 2, in: line)) {
            if step != progress.step { progress.stepFraction = nil }
            progress.step = step
            progress.totalSteps = total
            let name = text(match, 3, in: line).trimmingCharacters(in: CharacterSet(charactersIn: " .:-()"))
            if !name.isEmpty { progress.stepName = name }
        }

        if let match = percentPattern.firstMatch(in: line, range: range),
           let value = Double(text(match, 1, in: line)) {
            progress.stepFraction = min(1, max(0, value / 100))
        }
    }

    private static func text(_ match: NSTextCheckingResult, _ group: Int, in line: String) -> String {
        guard let range = Range(match.range(at: group), in: line) else { return "" }
        return String(line[range])
    }
}
