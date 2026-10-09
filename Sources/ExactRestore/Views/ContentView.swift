import AppKit
import SwiftUI

struct PendingJob: Identifiable {
    let id = UUID()
    let ecids: Set<String>
    let ipsw: URL?
}

struct ContentView: View {
    @State private var store = DeviceStore()
    @State private var pendingErase: PendingJob?
    @State private var pendingIPSW: PendingJob?
    @State private var logDevice: Device?
    @State private var showsKPIs = false
    @State private var restartingDevice: Device?
    @Environment(\.openURL) private var openURL

    private static let configuratorURL = URL(string: "macappstore://apps.apple.com/app/id1037126344")!
    private let columns = [GridItem(.adaptive(minimum: 250), spacing: 16)]

    var body: some View {
        VStack(spacing: 0) {
            AppHeader(kpi: store.kpi, onShowKPIs: { showsKPIs = true })
            Divider()
            banners
            ActionBar(
                store: store,
                onErase: { pendingErase = PendingJob(ecids: store.runnable(store.selection), ipsw: nil) }
            )
            if store.showsPorts {
                Divider()
                PortStrip(store: store)
            }
            Divider()

            Group {
                if store.devices.isEmpty {
                    EmptyStateGuide(remoteDFU: store.remoteDFUSupported)
                } else {
                ScrollView {
                    LazyVGrid(columns: columns, spacing: 16) {
                        ForEach(store.devices) { device in
                            DeviceCard(
                                device: device,
                                state: store.state(for: device.ecid),
                                isConnected: store.isConnected(device.ecid),
                                mode: store.mode(for: device.ecid),
                                portName: store.port(for: device.ecid).map(store.portName),
                                activation: store.activationStatus(for: device.ecid),
                                isSelected: store.selection.contains(device.ecid),
                                onTap: { store.toggleSelection(device.ecid) },
                                onShowLog: { logDevice = device },
                                onRestart: restartAction(for: device),
                                onDropIPSW: { handleDrop($0, on: device.ecid) }
                            )
                        }
                    }
                    .padding(16)
                }
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)

            Divider()
            StatusFooter(store: store)
        }
        .frame(minWidth: 820, minHeight: 500)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .confirmationDialog(
            eraseTitle(pendingErase),
            isPresented: Binding(get: { pendingErase != nil }, set: { if !$0 { pendingErase = nil } }),
            presenting: pendingErase
        ) { job in
            Button("Restore", role: .destructive) {
                store.run(.eraseInstall, on: job.ecids, ipsw: job.ipsw)
            }
        } message: { _ in
            Text("All data will be permanently removed. Apple Silicon Macs get the latest macOS. T2 Macs get firmware only; install macOS from Recovery afterwards.")
        }
        .confirmationDialog(
            "Use \(pendingIPSW?.ipsw?.lastPathComponent ?? "this file") on \(countText(pendingIPSW))?",
            isPresented: Binding(get: { pendingIPSW != nil }, set: { if !$0 { pendingIPSW = nil } }),
            presenting: pendingIPSW
        ) { job in
            Button("Restore, erase all data", role: .destructive) {
                store.run(.eraseInstall, on: job.ecids, ipsw: job.ipsw)
            }
            Button("Revive, keep data") {
                store.run(.reinstall, on: job.ecids, ipsw: job.ipsw)
            }
        } message: { _ in
            Text("Restore permanently removes all data and installs this file. Revive only updates firmware and recoveryOS.")
        }
        .alert(
            "Something went wrong",
            isPresented: Binding(get: { store.alertMessage != nil }, set: { if !$0 { store.alertMessage = nil } })
        ) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(store.alertMessage ?? "")
        }
        .sheet(isPresented: Binding(get: { !store.isSignedIn }, set: { _ in })) {
            SignInSheet(kpi: store.kpi)
        }
        .confirmationDialog(
            "Restart \(restartingDevice?.name ?? "this Mac")?",
            isPresented: Binding(get: { restartingDevice != nil }, set: { if !$0 { restartingDevice = nil } }),
            presenting: restartingDevice
        ) { device in
            Button("Restart", role: .destructive) {
                if let rid = store.port(for: device.ecid) { store.restartPort(rid) }
            }
        } message: { _ in
            Text("This is a forced restart, like holding the power button. The Mac leaves DFU and starts normally.")
        }
        .sheet(isPresented: $showsKPIs) {
            KPISheet(kpi: store.kpi)
        }
        .sheet(item: $logDevice) { device in
            LogSheet(title: device.name, lines: store.log(for: device.ecid))
        }
        .task {
            await store.checkHost()
            store.startPolling()
        }
    }

    @ViewBuilder
    private var banners: some View {
        if store.configuratorMissing {
            Banner(
                message: "Apple Configurator is required. Install it, choose Install Automation Tools from its menu, then reopen this app.",
                actionTitle: "Get Apple Configurator"
            ) { openURL(Self.configuratorURL) }
        }

        if !store.remoteDFUSupported {
            Banner(message: "Remote DFU needs an Apple Silicon host. Put targets into DFU manually; erase and reinstall work as normal.")
        } else if !store.hostReady {
            Banner(
                message: "Remote DFU needs setup or an update on this Mac.",
                actionTitle: store.isSettingUpHost ? "Setting up…" : "Set up this Mac",
                isActionDisabled: store.isSettingUpHost
            ) { store.setUpHost() }
        }

        if let listError = store.listError {
            Banner(message: listError)
        }
    }

    /// Restart needs the Mac's host port, which is known once the app put it into DFU.
    private func restartAction(for device: Device) -> (() -> Void)? {
        guard store.remoteDFUSupported, store.isSignedIn, store.port(for: device.ecid) != nil else { return nil }
        return { restartingDevice = device }
    }

    /// A drop on a selected card applies to the whole selection.
    private func handleDrop(_ url: URL, on ecid: String) {
        let targets = store.selection.contains(ecid) ? store.selection : [ecid]
        let ready = store.runnable(targets)
        guard !ready.isEmpty else {
            store.alertMessage = "Put the Mac into DFU before dropping an IPSW file on it."
            return
        }
        pendingIPSW = PendingJob(ecids: ready, ipsw: url)
    }

    private func countText(_ job: PendingJob?) -> String {
        let count = job?.ecids.count ?? 0
        return "\(count) Mac\(count == 1 ? "" : "s")"
    }

    private func eraseTitle(_ job: PendingJob?) -> String {
        "Restore \(countText(job))?"
    }
}

private struct ActionBar: View {
    let store: DeviceStore
    let onErase: () -> Void

    private var readySelection: Set<String> { store.runnable(store.selection) }

    private var enterDFUTitle: String {
        let count = store.selectedPorts.count
        if count > 0 { return "Enter DFU (\(count))" }
        return store.isEnteringDFU ? "Entering DFU…" : "Enter DFU"
    }

    var body: some View {
        HStack(spacing: 12) {
            Button {
                store.enterDFUOnSelectedPorts()
            } label: {
                Label(enterDFUTitle, systemImage: "bolt.horizontal.circle.fill")
                    .frame(minWidth: 140)
            }
            .buttonStyle(.borderedProminent)
            .tint(.blue)
            .disabled(!store.canEnterDFU)
            .help(store.remoteDFUSupported ? "Put the Macs on the selected host ports into DFU" : "Needs an Apple Silicon host")

            VStack(alignment: .leading, spacing: 2) {
                Text("\(readySelection.count) selected · \(store.readyCount) ready")
                    .font(.headline)
                Text("Drop an .ipsw file on a Mac to use it")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .padding(.leading, 4)

            Spacer()

            Button("Select all ready") { store.selectAllReady() }
                .disabled(store.readyCount == 0)
            Button("Clear finished") { store.clearFinished() }

            Button {
                store.run(.reinstall, on: readySelection)
            } label: {
                Label("Revive", systemImage: "arrow.clockwise.circle.fill")
                    .frame(minWidth: 110)
            }
            .buttonStyle(.bordered)
            .disabled(readySelection.isEmpty)
            .help("Update firmware and recoveryOS. Keeps macOS and data")

            Button(role: .destructive, action: onErase) {
                Label("Restore", systemImage: "trash.circle.fill")
                    .frame(minWidth: 150)
            }
            .buttonStyle(.borderedProminent)
            .tint(.red)
            .disabled(readySelection.isEmpty)
            .help("Erase everything. Apple Silicon: installs macOS. T2: firmware only")
        }
        .controlSize(.large)
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
    }
}

private struct Banner: View {
    let message: String
    var actionTitle: String?
    var isActionDisabled = false
    var action: (() -> Void)?

    var body: some View {
        HStack(spacing: 12) {
            Label(message, systemImage: "exclamationmark.triangle.fill")
                .font(.callout)
                .frame(maxWidth: .infinity, alignment: .leading)

            if let actionTitle, let action {
                Button(actionTitle, action: action)
                    .controlSize(.small)
                    .disabled(isActionDisabled)
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(.yellow.opacity(0.15))
    }
}

private struct AppHeader: View {
    let kpi: KPIStore
    let onShowKPIs: () -> Void

    var body: some View {
        HStack(spacing: 10) {
            Image(nsImage: NSApp.applicationIconImage)
                .resizable()
                .frame(width: 34, height: 34)
                .accessibilityHidden(true)
            Text("Exact Restore")
                .font(.system(size: 20, weight: .semibold))
            Spacer()
            EmployeeBar(kpi: kpi, onShowKPIs: onShowKPIs)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
    }
}

private struct LogSheet: View {
    let title: String
    let lines: [String]
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("\(title) log").font(.headline)
            ScrollView {
                Text(lines.isEmpty ? "No output yet." : lines.joined(separator: "\n"))
                    .font(.caption.monospaced())
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .frame(minHeight: 260)
            .padding(8)
            .background(RoundedRectangle(cornerRadius: 8).fill(.background.secondary))
            HStack {
                Button("Copy") {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(lines.joined(separator: "\n"), forType: .string)
                }
                Spacer()
                Button("Done") { dismiss() }.keyboardShortcut(.defaultAction)
            }
        }
        .padding(20)
        .frame(width: 560)
    }
}

/// Bottom bar: live station numbers on the left, the watermark on the right.
private struct StatusFooter: View {
    let store: DeviceStore

    private var today: EmployeeSummary? {
        guard let employee = store.kpi.currentEmployee else { return nil }
        let start = Calendar.current.startOfDay(for: Date())
        return store.kpi.summary(since: start).first { $0.employee == employee }
    }

    var body: some View {
        HStack(spacing: 18) {
            stat("bolt.circle.fill", "\(store.devices.filter { store.mode(for: $0.ecid) == .dfu && store.isConnected($0.ecid) }.count) in DFU", .blue)
            stat("arrow.triangle.2.circlepath", "\(store.runningCount) running", store.runningCount > 0 ? .orange : .secondary)

            if let employee = store.kpi.currentEmployee {
                Divider().frame(height: 14)
                let row = today
                stat(
                    "person.crop.circle",
                    "\(employee) today: \(row?.dfu ?? 0) DFU · \(row?.restores ?? 0) restores · \(row?.revives ?? 0) revives",
                    .secondary
                )
                if let failed = row?.failed, failed > 0 {
                    stat("exclamationmark.triangle.fill", "\(failed) failed", .red)
                }
            }

            Spacer()

            Link(AppInfo.watermark, destination: AppInfo.githubURL)
                .font(.caption2)
                .foregroundStyle(.tertiary)
                .help("Open the developer's GitHub profile")
        }
        .font(.caption)
        .padding(.horizontal, 16)
        .padding(.vertical, 8)
    }

    private func stat(_ icon: String, _ text: String, _ color: Color) -> some View {
        Label {
            Text(text).foregroundStyle(.secondary)
        } icon: {
            Image(systemName: icon).foregroundStyle(color)
        }
    }
}

/// Fills the device area when nothing is connected, with the three steps staff need.
private struct EmptyStateGuide: View {
    let remoteDFU: Bool

    var body: some View {
        VStack(spacing: 28) {
            VStack(spacing: 8) {
                Image(systemName: "laptopcomputer.and.arrow.down")
                    .font(.system(size: 44))
                    .foregroundStyle(.secondary)
                Text("No Macs in DFU yet").font(.title2.weight(.semibold))
                Text("Macs appear here once they are in DFU.")
                    .foregroundStyle(.secondary)
            }

            HStack(alignment: .top, spacing: 16) {
                step(1, "cable.connector", "Connect",
                     "Cable each Mac by its DFU port directly to this Mac, using a data cable. No hubs.")
                step(2, "bolt.horizontal.circle", "Enter DFU",
                     remoteDFU
                        ? "Select the orange ports under Host ports, then click Enter DFU."
                        : "This host cannot send DFU. Put each Mac into DFU with its key combination.")
                step(3, "arrow.clockwise.circle", "Restore",
                     "Select the Macs, then click Restore, or drop an .ipsw file on a Mac.")
            }
            .frame(maxWidth: 820)
        }
        .padding(32)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func step(_ number: Int, _ icon: String, _ title: String, _ text: String) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                Text("\(number)")
                    .font(.callout.weight(.bold))
                    .frame(width: 24, height: 24)
                    .background(Circle().fill(Color.accentColor.opacity(0.18)))
                Image(systemName: icon).foregroundStyle(Color.accentColor)
                Text(title).font(.headline)
            }
            Text(text)
                .font(.callout)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(16)
        .frame(maxWidth: .infinity, minHeight: 120, alignment: .topLeading)
        .background(RoundedRectangle(cornerRadius: 12).fill(.background.secondary))
        .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(Color.secondary.opacity(0.2)))
    }
}
