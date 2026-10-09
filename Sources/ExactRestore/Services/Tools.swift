import Foundation

enum Tools {
    static let cfgutil = [
        "/usr/local/bin/cfgutil",
        "/Applications/Apple Configurator.app/Contents/MacOS/cfgutil",
        "/Applications/Apple Configurator 2.app/Contents/MacOS/cfgutil"
    ]

    static let macvdmtool = [
        "/usr/local/bin/macvdmtool",
        "/opt/homebrew/bin/macvdmtool"
    ]

    static func locate(_ candidates: [String]) -> String? {
        candidates.first { FileManager.default.isExecutableFile(atPath: $0) }
    }
}
