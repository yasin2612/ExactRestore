import Foundation

/// GitHub username shown in the watermark. Keep in sync with AUTHOR in scripts/build-app.sh.
enum AppInfo {
    static let githubUsername = "yasin2612"

    static var githubURL: URL { URL(string: "https://github.com/\(githubUsername)")! }
    static var watermark: String { "Exact Restore · github.com/\(githubUsername)" }
}
