import SwiftUI

/// Host USB C ports. Macs that are not in DFU are invisible over USB, so this is the only place they show up.
struct PortStrip: View {
    let store: DeviceStore

    @State private var renamingPort: HostPort?
    @State private var draftName = ""
    @State private var restartingPort: HostPort?

    var body: some View {
        HStack(spacing: 10) {
            VStack(alignment: .leading, spacing: 2) {
                Text("Host ports").font(.headline)
                Text("Select ports for DFU. Right click to rename.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .frame(minWidth: 150, alignment: .leading)

            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 10) {
                    ForEach(store.ports) { port in
                        PortChip(
                            port: port,
                            name: store.portName(port.rid),
                            state: store.portState(port),
                            isSelected: store.selectedPorts.contains(port.rid),
                            isEnabled: store.canSelectPort(port)
                        ) { store.togglePort(port) }
                        .contextMenu {
                            Button("Rename…") {
                                draftName = store.portNames[port.rid] ?? ""
                                renamingPort = port
                            }
                            if store.portNames[port.rid] != nil {
                                Button("Reset name") { store.renamePort(port.rid, to: "") }
                            }
                            Divider()
                            Button("Restart Mac on this port…") { restartingPort = port }
                                .disabled(!store.canRestartPort(port))
                        }
                    }
                }
            }

            if store.currentDFUPort != nil {
                Button {
                    store.stopCurrentDFU()
                } label: {
                    Label("Stop", systemImage: "stop.circle.fill")
                }
                .tint(.red)
                .buttonStyle(.borderedProminent)
                .help("Stop waiting on the port entering DFU. You can select it again right away")
            }

            if !store.dfuQueue.isEmpty {
                Button("Stop all") { store.stopAllDFU() }
                    .help("Stop the current port and drop every queued port")
            }

            Button("Select waiting") { store.selectWaitingPorts() }
                .disabled(store.waitingPorts.isEmpty)
                .help("Select every port with a Mac that is not in DFU yet")
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .alert(
            "Rename \(renamingPort.map { store.portName($0.rid) } ?? "port")",
            isPresented: Binding(get: { renamingPort != nil }, set: { if !$0 { renamingPort = nil } }),
            presenting: renamingPort
        ) { port in
            TextField("For example Left front", text: $draftName)
            Button("Save") { store.renamePort(port.rid, to: draftName) }
            Button("Cancel", role: .cancel) {}
        } message: { port in
            Text("Saved on this Mac only. Leave empty to use Port \(port.rid).")
        }
        .confirmationDialog(
            "Restart the Mac on \(restartingPort.map { store.portName($0.rid) } ?? "this port")?",
            isPresented: Binding(get: { restartingPort != nil }, set: { if !$0 { restartingPort = nil } }),
            presenting: restartingPort
        ) { port in
            Button("Restart", role: .destructive) { store.restartPort(port.rid) }
        } message: { port in
            Text(store.hasRunningJob(onPort: port.rid)
                ? "A Restore or Revive is running on this Mac. Restarting now will interrupt it and can leave the Mac unbootable until restored again."
                : "This is a forced restart, like holding the power button. The Mac leaves DFU and starts normally.")
        }
    }
}

private struct PortChip: View {
    let port: HostPort
    let name: String
    let state: PortState
    let isSelected: Bool
    let isEnabled: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 8) {
                statusIcon
                VStack(alignment: .leading, spacing: 1) {
                    Text(name).font(.callout.weight(.semibold)).lineLimit(1)
                    Text(statusText).font(.caption).foregroundStyle(.secondary)
                }
                if isEnabled {
                    Image(systemName: isSelected ? "checkmark.circle.fill" : "circle")
                        .foregroundStyle(isSelected ? Color.accentColor : .secondary)
                }
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            .frame(minWidth: 150, alignment: .leading)
            .background(RoundedRectangle(cornerRadius: 8).fill(tint.opacity(0.12)))
            .overlay(
                RoundedRectangle(cornerRadius: 8)
                    .strokeBorder(isSelected ? Color.accentColor : tint.opacity(0.35), lineWidth: isSelected ? 2 : 1)
            )
            .contentShape(RoundedRectangle(cornerRadius: 8))
        }
        .buttonStyle(.plain)
        .disabled(!isEnabled)
        .accessibilityLabel("\(name), \(statusText)")
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }

    @ViewBuilder
    private var statusIcon: some View {
        switch state {
        case .enteringDFU:
            ProgressView().controlSize(.small)
        case .queued:
            Image(systemName: "clock").foregroundStyle(.blue)
        case .failed:
            Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.red)
        case .inDFU:
            Image(systemName: "bolt.circle.fill").foregroundStyle(.blue)
        case .connected(let maybeCharger):
            Image(systemName: maybeCharger ? "powerplug.fill" : "laptopcomputer")
                .foregroundStyle(maybeCharger ? Color.secondary : .orange)
        case .empty:
            Image(systemName: "circle.dashed").foregroundStyle(.secondary)
        }
    }

    private var statusText: String {
        switch state {
        case .empty: "Empty"
        case .connected(let maybeCharger): maybeCharger ? "Connected, may be a charger" : "Not in DFU"
        case .failed: "DFU failed, select to retry"
        case .queued: "Queued"
        case .enteringDFU(let attempt): attempt > 1 ? "Entering DFU, try \(attempt)…" : "Entering DFU…"
        case .inDFU: "In DFU"
        }
    }

    private var tint: Color {
        switch state {
        case .empty: .secondary
        case .connected(let maybeCharger): maybeCharger ? .secondary : .orange
        case .failed: .red
        case .queued, .enteringDFU, .inDFU: .blue
        }
    }
}
