import SwiftUI

struct StatusView: View {
    let state: JobState
    let isConnected: Bool
    let mode: DeviceMode

    var body: some View {
        switch state {
        case .idle where isConnected:
            modeLabel
        case .idle:
            Text("Disconnected").foregroundStyle(.secondary)
        case let .running(kind, line):
            HStack(spacing: 6) {
                ProgressView().controlSize(.small)
                Text("\(kind.rawValue): \(line)")
                    .lineLimit(1)
                    .truncationMode(.tail)
            }
            .help(line)
        case let .succeeded(kind):
            Label("\(kind.rawValue) complete", systemImage: "checkmark.circle.fill")
                .foregroundStyle(.green)
        case let .failed(_, message):
            Label(message, systemImage: "xmark.octagon.fill")
                .foregroundStyle(.red)
                .lineLimit(1)
                .help(message)
        }
    }

    @ViewBuilder
    private var modeLabel: some View {
        switch mode {
        case .dfu:
            Label("In DFU, ready", systemImage: "bolt.circle.fill")
                .foregroundStyle(.blue)
        case .recovery:
            Label("In Recovery, enter DFU first", systemImage: "lifepreserver")
                .foregroundStyle(.orange)
        case .notDFU:
            Label("Connected, not in DFU", systemImage: "circle.dashed")
                .foregroundStyle(.secondary)
        case .unknown:
            Label("Connected", systemImage: "questionmark.circle")
                .foregroundStyle(.secondary)
        }
    }
}
