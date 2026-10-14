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
        case let .running(kind, progress):
            RunningProgressView(kind: kind, progress: progress)
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

/// Live progress like Apple Configurator: step, bar, percentage and elapsed time.
private struct RunningProgressView: View {
    let kind: JobKind
    let progress: JobProgress

    private var title: String {
        if let step = progress.step, let total = progress.totalSteps {
            let name = progress.stepName.map { ": \($0)" } ?? ""
            return "\(kind.rawValue) · Step \(step) of \(total)\(name)"
        }
        return kind.rawValue
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title)
                .font(.callout.weight(.semibold))
                .lineLimit(1)

            if let fraction = progress.overallFraction {
                ProgressView(value: fraction)
                    .progressViewStyle(.linear)
            } else {
                ProgressView()
                    .progressViewStyle(.linear)
            }

            HStack {
                Text(progress.line)
                    .lineLimit(1)
                    .truncationMode(.tail)
                Spacer(minLength: 8)
                TimelineView(.periodic(from: progress.startedAt, by: 1)) { context in
                    Text(detail(now: context.date))
                        .monospacedDigit()
                }
            }
            .font(.caption)
            .foregroundStyle(.secondary)
        }
        .help(progress.line)
    }

    private func detail(now: Date) -> String {
        let elapsed = Int(now.timeIntervalSince(progress.startedAt))
        let time = String(format: "%d:%02d", elapsed / 60, elapsed % 60)
        guard let fraction = progress.overallFraction else { return time }
        return "\(Int((fraction * 100).rounded()))% · \(time)"
    }
}
