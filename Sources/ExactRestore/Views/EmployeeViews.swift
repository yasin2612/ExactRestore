import SwiftUI

/// Shown until someone signs in. Employees can also be added here so a new station is never stuck.
struct SignInSheet: View {
    let kpi: KPIStore
    @State private var newName = ""

    private let columns = [GridItem(.adaptive(minimum: 150), spacing: 10)]

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            VStack(alignment: .leading, spacing: 4) {
                Text("Who is working?").font(.title2.weight(.semibold))
                Text("Your DFU, Restore and Revive counts are recorded under your name.")
                    .foregroundStyle(.secondary)
            }

            if kpi.employees.isEmpty {
                Text("No employees yet. Add the first one below.")
                    .foregroundStyle(.secondary)
            } else {
                ScrollView {
                    LazyVGrid(columns: columns, spacing: 10) {
                        ForEach(kpi.employees, id: \.self) { name in
                            Button {
                                kpi.signIn(name)
                            } label: {
                                Label(name, systemImage: "person.crop.circle.fill")
                                    .frame(maxWidth: .infinity, alignment: .leading)
                                    .padding(.vertical, 6)
                            }
                            .buttonStyle(.bordered)
                            .controlSize(.large)
                        }
                    }
                }
                .frame(maxHeight: 280)
            }

            Divider()

            HStack {
                TextField("Add employee name", text: $newName)
                    .textFieldStyle(.roundedBorder)
                    .onSubmit(add)
                Button("Add", action: add)
                    .disabled(newName.trimmingCharacters(in: .whitespaces).isEmpty)
            }
        }
        .padding(24)
        .frame(width: 520)
        .interactiveDismissDisabled()
    }

    private func add() {
        if kpi.addEmployee(newName) { newName = "" }
    }
}

struct EmployeeBar: View {
    let kpi: KPIStore
    let onShowKPIs: () -> Void

    var body: some View {
        HStack(spacing: 10) {
            if kpi.isSyncConfigured {
                syncStatus
            }

            Button(action: onShowKPIs) {
                Label("KPIs", systemImage: "chart.bar.fill")
            }

            if let employee = kpi.currentEmployee {
                Label(employee, systemImage: "person.crop.circle.fill")
                    .font(.callout.weight(.semibold))
                Button("Switch") { kpi.signOut() }
                    .help("Sign out so another employee can sign in")
            }
        }
    }

    @ViewBuilder
    private var syncStatus: some View {
        if let error = kpi.lastUploadError {
            Label("Sync paused", systemImage: "exclamationmark.icloud.fill")
                .font(.caption)
                .foregroundStyle(.orange)
                .help("\(kpi.pendingCount) waiting. \(error)")
        } else if kpi.pendingCount > 0 {
            Label("\(kpi.pendingCount) waiting to sync", systemImage: "icloud.and.arrow.up")
                .font(.caption)
                .foregroundStyle(.secondary)
        } else {
            Label("Synced", systemImage: "checkmark.icloud.fill")
                .font(.caption)
                .foregroundStyle(.green)
        }
    }
}

struct KPISheet: View {
    let kpi: KPIStore
    @Environment(\.dismiss) private var dismiss
    @State private var range: Range = .today

    enum Range: String, CaseIterable, Identifiable {
        case today = "Today"
        case week = "Last 7 days"
        case month = "Last 30 days"

        var id: String { rawValue }

        var start: Date {
            let calendar = Calendar.current
            let today = calendar.startOfDay(for: Date())
            switch self {
            case .today: return today
            case .week: return calendar.date(byAdding: .day, value: -6, to: today) ?? today
            case .month: return calendar.date(byAdding: .day, value: -29, to: today) ?? today
            }
        }
    }

    var body: some View {
        let rows = kpi.summary(since: range.start)

        VStack(alignment: .leading, spacing: 14) {
            HStack {
                Text("Employee KPIs").font(.title2.weight(.semibold))
                Spacer()
                Picker("Range", selection: $range) {
                    ForEach(Range.allCases) { Text($0.rawValue).tag($0) }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .frame(width: 320)
            }

            Text("This station only. Your manager's dashboard combines every station once sync is set up in Settings.")
                .font(.caption)
                .foregroundStyle(.secondary)

            Table(rows) {
                TableColumn("Employee", value: \.employee)
                TableColumn("DFU") { Text("\($0.dfu)").monospacedDigit() }
                TableColumn("Restores") { Text("\($0.restores)").monospacedDigit() }
                TableColumn("Revives") { Text("\($0.revives)").monospacedDigit() }
                TableColumn("Failed") { Text("\($0.failed)").monospacedDigit() }
                TableColumn("Activation Locked") { Text("\($0.activationLocked)").monospacedDigit() }
            }
            .frame(minHeight: 240)
            .overlay {
                if rows.isEmpty {
                    ContentUnavailableView("No work recorded", systemImage: "chart.bar", description: Text("Counts appear here as employees work."))
                }
            }

            HStack {
                Button("Export CSV") { kpi.exportCSV(since: range.start) }
                Spacer()
                Button("Done") { dismiss() }.keyboardShortcut(.defaultAction)
            }
        }
        .padding(24)
        .frame(width: 760, height: 460)
    }
}
