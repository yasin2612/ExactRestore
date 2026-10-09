import AppKit
import SwiftUI

@main
struct ExactRestoreApp: App {
    init() {
        NSApplication.shared.setActivationPolicy(.regular)
        DispatchQueue.main.async {
            NSApp.activate()
            AlertService.requestPermission()
        }
    }

    var body: some Scene {
        WindowGroup("Exact Restore") {
            ContentView()
        }
        .windowResizability(.contentMinSize)

        Settings {
            SettingsView()
        }
    }
}

struct SettingsView: View {
    var body: some View {
        TabView {
            GeneralSettings()
                .tabItem { Label("General", systemImage: "gearshape") }
            EmployeeSettings()
                .tabItem { Label("Employees", systemImage: "person.2") }
            SyncSettings()
                .tabItem { Label("KPI sync", systemImage: "icloud.and.arrow.up") }
        }
        .frame(width: 500, height: 360)
    }
}

private struct GeneralSettings: View {
    @AppStorage(SettingsKey.sounds) private var sounds = true
    @AppStorage(SettingsKey.notifications) private var notifications = true

    var body: some View {
        Form {
            Toggle("Play sounds when jobs finish or fail", isOn: $sounds)
            Toggle("Show notifications", isOn: $notifications)
            Text("Notifications also need permission in System Settings > Notifications > Exact Restore.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .padding(20)
    }
}

private struct EmployeeSettings: View {
    private var kpi: KPIStore { KPIStore.shared }
    @State private var newName = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            List {
                ForEach(kpi.employees, id: \.self) { name in
                    HStack {
                        Text(name)
                        if kpi.currentEmployee == name {
                            Text("Signed in").font(.caption).foregroundStyle(.secondary)
                        }
                        Spacer()
                        Button(role: .destructive) {
                            kpi.removeEmployee(name)
                        } label: {
                            Image(systemName: "trash")
                        }
                        .buttonStyle(.borderless)
                        .help("Remove \(name). Their recorded work is kept.")
                    }
                }
            }
            HStack {
                TextField("Employee name", text: $newName)
                    .textFieldStyle(.roundedBorder)
                    .onSubmit(add)
                Button("Add", action: add)
                    .disabled(newName.trimmingCharacters(in: .whitespaces).isEmpty)
            }
            Text("The list is saved on this Mac. Add the same names on every station so dashboards match.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .padding(20)
    }

    private func add() {
        if kpi.addEmployee(newName) { newName = "" }
    }
}

private struct SyncSettings: View {
    private var kpi: KPIStore { KPIStore.shared }
    @AppStorage(KPIKeys.endpoint) private var endpoint = ""
    @State private var apiKey = Keychain.read(KPIKeys.apiKeyAccount) ?? ""

    var body: some View {
        Form {
            TextField("API URL", text: $endpoint, prompt: Text("https://example.com/api/kpi/events"))
            SecureField("API key", text: $apiKey)
                .onSubmit { Keychain.save(apiKey, for: KPIKeys.apiKeyAccount) }

            HStack {
                Button("Save and sync now") {
                    Keychain.save(apiKey, for: KPIKeys.apiKeyAccount)
                    kpi.uploadNow()
                }
                Spacer()
                Text(status).font(.caption).foregroundStyle(.secondary)
            }

            Text("Events are stored on this Mac and sent in batches. Nothing is lost while the API is offline or not set up yet.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .padding(20)
    }

    private var status: String {
        if let error = kpi.lastUploadError { return "\(kpi.pendingCount) waiting. \(error)" }
        if kpi.pendingCount > 0 { return "\(kpi.pendingCount) waiting to sync" }
        return kpi.lastUploadAt.map { "Synced \($0.formatted(date: .omitted, time: .shortened))" } ?? "Nothing waiting"
    }
}
