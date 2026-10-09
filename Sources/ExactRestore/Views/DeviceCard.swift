import SwiftUI

struct DeviceCard: View {
    let device: Device
    let state: JobState
    let isConnected: Bool
    let mode: DeviceMode
    let portName: String?
    let activation: ActivationStatus?
    let isSelected: Bool
    let onTap: () -> Void
    let onShowLog: () -> Void
    var onRestart: (() -> Void)?
    let onDropIPSW: (URL) -> Void

    @State private var isDropTargeted = false

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .top) {
                Image(systemName: "laptopcomputer")
                    .font(.system(size: 30))
                    .foregroundStyle(isConnected ? Color.accentColor : .secondary)
                Spacer()
                if let portName {
                    Text(portName)
                        .lineLimit(1)
                        .font(.caption.weight(.semibold))
                        .padding(.horizontal, 8)
                        .padding(.vertical, 3)
                        .background(Capsule().fill(Color.accentColor.opacity(0.15)))
                }
                Image(systemName: isSelected ? "checkmark.circle.fill" : "circle")
                    .font(.title2)
                    .foregroundStyle(isSelected ? Color.accentColor : .secondary)
            }

            VStack(alignment: .leading, spacing: 2) {
                Text(device.name).font(.headline)
                Text(device.deviceType).font(.subheadline).foregroundStyle(.secondary)
                Text(device.ecid)
                    .font(.caption.monospaced())
                    .foregroundStyle(.secondary)
                    .textSelection(.enabled)
            }

            StatusView(state: state, isConnected: isConnected, mode: mode)
                .font(.callout)
                .frame(maxWidth: .infinity, alignment: .leading)

            if state == .succeeded(.eraseInstall), device.deviceType.hasPrefix("iBridge") {
                Label("macOS not included on T2 Macs. Install it from Recovery or a USB installer.", systemImage: "info.circle.fill")
                    .font(.caption)
                    .foregroundStyle(.orange)
                    .fixedSize(horizontal: false, vertical: true)
            }

            if let activation {
                ActivationBadge(status: activation)
            }
        }
        .padding(14)
        .frame(maxWidth: .infinity, minHeight: 170, alignment: .topLeading)
        .background(RoundedRectangle(cornerRadius: 12).fill(.background.secondary))
        .overlay(
            RoundedRectangle(cornerRadius: 12)
                .strokeBorder(borderColor, style: StrokeStyle(lineWidth: isSelected || isDropTargeted ? 2.5 : 1, dash: isDropTargeted ? [6] : []))
        )
        .contentShape(RoundedRectangle(cornerRadius: 12))
        .onTapGesture(perform: onTap)
        .contextMenu {
            Button("Show log", action: onShowLog)
            if let onRestart {
                Button("Restart this Mac…", action: onRestart)
                    .disabled(state.isRunning)
            }
        }
        .dropDestination(for: URL.self) { urls, _ in
            guard let ipsw = urls.first(where: { $0.pathExtension.lowercased() == "ipsw" }) else { return false }
            onDropIPSW(ipsw)
            return true
        } isTargeted: { isDropTargeted = $0 }
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(isSelected ? [.isButton, .isSelected] : .isButton)
    }

    private var borderColor: Color {
        if isDropTargeted { return .accentColor }
        return isSelected ? .accentColor : Color.secondary.opacity(0.25)
    }
}

private struct ActivationBadge: View {
    let status: ActivationStatus

    var body: some View {
        switch status {
        case .locked:
            Label("Activation Locked. Remove before shipping", systemImage: "lock.fill")
                .font(.caption.weight(.semibold))
                .foregroundStyle(.white)
                .padding(.horizontal, 8)
                .padding(.vertical, 4)
                .background(Capsule().fill(.red))
        case .clear:
            Label("Activation: not locked", systemImage: "lock.open.fill")
                .font(.caption)
                .foregroundStyle(.green)
        case .unknown:
            Label("Activation: check at Setup Assistant", systemImage: "questionmark.circle")
                .font(.caption)
                .foregroundStyle(.secondary)
                .help("The host could not read activation status after the restore")
        }
    }
}
