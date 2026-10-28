import CloudCostCore
import SwiftUI

struct SettingsView: View {
    var body: some View {
        TabView {
            GeneralSettings().tabItem { Label("General", systemImage: "gearshape") }
            AccountsSettings().tabItem { Label("Accounts", systemImage: "person.2") }
            EnvironmentSettings().tabItem { Label("Environments", systemImage: "square.stack.3d.up") }
        }
        .frame(width: 560, height: 420)
    }
}

private struct GeneralSettings: View {
    @Environment(Preferences.self) private var preferences

    var body: some View {
        @Bindable var preferences = preferences
        Form {
            Section("Data") {
                Stepper("History: \(preferences.monthsToLoad) months", value: $preferences.monthsToLoad, in: 1...12)
                Picker("Refresh automatically", selection: $preferences.refreshIntervalHours) {
                    Text("Never").tag(0)
                    Text("Every hour").tag(1)
                    Text("Every 6 hours").tag(6)
                    Text("Every day").tag(24)
                }
            }
            Section("Display") {
                Stepper("Sunburst rings: \(preferences.sunburstRings)", value: $preferences.sunburstRings, in: 2...5)
                Picker("Default chart", selection: $preferences.chartStyle) {
                    ForEach(ChartStyle.allCases) { Text($0.title).tag($0) }
                }
                Toggle("Show spend in the menu bar", isOn: $preferences.showsMenuBarExtra)
            }
            Section {
                LabeledContent("Data folder") {
                    Button("Show in Finder") { NSWorkspace.shared.activateFileViewerSelecting([Storage.shared.directory]) }
                }
            } footer: {
                Text("Reports are cached there so the app opens instantly and works offline. Secrets stay in the Keychain or your CLI config.")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
    }
}

private struct AccountsSettings: View {
    @Environment(AppModel.self) private var model
    @State private var selection: UUID?

    var body: some View {
        VStack(spacing: 0) {
            List(selection: $selection) {
                ForEach(model.accounts) { account in
                    HStack(spacing: 10) {
                        ProviderBadge(kind: account.provider, size: 22)
                        VStack(alignment: .leading) {
                            Text(account.name)
                            Text(account.credentialSource.label).font(.caption).foregroundStyle(.secondary)
                        }
                        Spacer()
                        if let budget = account.monthlyBudget {
                            Text("Budget \(budget.money(model.report(account.id)?.currency ?? "EUR"))").font(.caption).foregroundStyle(.secondary)
                        }
                    }
                    .tag(account.id)
                }
                .onMove { model.moveAccounts(from: $0, to: $1) }
            }
            Divider()
            HStack(spacing: 0) {
                Button { model.isAddingAccount = true } label: { Image(systemName: "plus").frame(width: 24, height: 20) }
                Button { if let selection { model.remove(selection) } } label: { Image(systemName: "minus").frame(width: 24, height: 20) }
                    .disabled(selection == nil)
                Spacer()
                Button("Edit…") { model.editingAccount = selection.flatMap(model.account) }
                    .disabled(selection == nil)
            }
            .buttonStyle(.borderless)
            .padding(8)
        }
        .padding()
    }
}

private struct EnvironmentSettings: View {
    @Environment(Preferences.self) private var preferences

    var body: some View {
        @Bindable var preferences = preferences
        VStack(alignment: .leading, spacing: 10) {
            Text("Resources are put in the first environment whose keyword appears as a whole word in their name or tags (api-**dev**-1). Production is checked last.")
                .font(.callout).foregroundStyle(.secondary)
            Table($preferences.environments.environments) {
                TableColumn("Name") { $env in TextField("Name", text: $env.name).labelsHidden() }
                    .width(120)
                TableColumn("Keywords") { $env in
                    TextField("Keywords", text: Binding(get: { env.keywords.joined(separator: ", ") },
                                                        set: { env.keywords = $0.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty } }))
                        .labelsHidden()
                }
                TableColumn("Production") { $env in Toggle("", isOn: $env.isProduction).labelsHidden() }
                    .width(76)
            }
            HStack {
                Button("Add Environment") {
                    preferences.environments.environments.append(.init(id: UUID().uuidString.prefix(8).lowercased(), name: "New", keywords: []))
                }
                Button("Remove Last") { _ = preferences.environments.environments.popLast() }
                    .disabled(preferences.environments.environments.isEmpty)
                Spacer()
                Button("Restore Defaults") { preferences.environments = .default }
            }
            Text("Changes apply on the next refresh.").font(.caption).foregroundStyle(.secondary)
        }
        .padding()
    }
}
