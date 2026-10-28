import CloudCostCore
import SwiftUI

/// Add or edit an account: pick a provider, then fill its fields.
struct AccountEditor: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    let existing: Account?

    @State private var provider: ProviderKind?
    @State private var name = ""
    @State private var settings: [String: String] = [:]
    @State private var secrets: [String: String] = [:]
    @State private var useCLIProfile = true
    @State private var profileName = ""
    @State private var budget = ""
    @State private var test: TestState = .idle
    @State private var saveError: String?

    private let cliConfig = ScalewayCLIConfig.load()

    enum TestState: Equatable { case idle, running, passed, failed(String) }

    var body: some View {
        VStack(spacing: 0) {
            if let provider {
                form(for: provider)
            } else {
                providerPicker
            }
        }
        .frame(width: 520)
        .onAppear(perform: load)
    }

    // MARK: Step 1

    private var providerPicker: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Add an account").font(.title2.weight(.semibold))
            Text("Choose where your bill comes from.").foregroundStyle(.secondary)
            LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())], spacing: 10) {
                ForEach(ProviderKind.allCases) { kind in
                    Button {
                        select(kind)
                    } label: {
                        HStack(alignment: .top, spacing: 10) {
                            ProviderBadge(kind: kind, size: 30)
                            VStack(alignment: .leading, spacing: 3) {
                                HStack {
                                    Text(kind.shortName).font(.headline)
                                    if !kind.isAvailable {
                                        Text("Soon").font(.caption2.weight(.semibold)).padding(.horizontal, 5).padding(.vertical, 1)
                                            .background(.quaternary, in: Capsule())
                                    }
                                }
                                Text(kind.blurb).font(.caption).foregroundStyle(.secondary).multilineTextAlignment(.leading)
                                    .fixedSize(horizontal: false, vertical: true)
                            }
                            Spacer(minLength: 0)
                        }
                        .padding(12)
                        .frame(maxWidth: .infinity, minHeight: 86, alignment: .topLeading)
                        .background(.background.secondary, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .disabled(!kind.isAvailable)
                    .opacity(kind.isAvailable ? 1 : 0.55)
                }
            }
            HStack {
                Spacer()
                Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction)
            }
        }
        .padding(20)
    }

    // MARK: Step 2

    private func form(for kind: ProviderKind) -> some View {
        VStack(spacing: 0) {
            Form {
                Section {
                    HStack(spacing: 10) {
                        ProviderBadge(kind: kind, size: 28)
                        Text(kind.displayName).font(.headline)
                    }
                    TextField("Name", text: $name, prompt: Text("e.g. Production org"))
                }

                if kind == .scaleway {
                    scalewayCredentials
                } else if !kind.fields.isEmpty {
                    Section("Credentials") { fields(kind.fields) }
                }

                Section {
                    TextField("Monthly budget", text: $budget, prompt: Text("Optional"))
                } footer: {
                    Text("Shown as a gauge, with a warning when the forecast goes over.").font(.caption).foregroundStyle(.secondary)
                }

                if kind != .demo {
                    Section {
                        HStack {
                            Button("Test Connection", action: runTest).disabled(test == .running || !isComplete)
                            switch test {
                            case .idle: EmptyView()
                            case .running: ProgressView().controlSize(.small)
                            case .passed: Label("Connected", systemImage: "checkmark.circle.fill").foregroundStyle(.green)
                            case .failed(let message): Label(message, systemImage: "xmark.octagon.fill").foregroundStyle(.red).lineLimit(3)
                            }
                        }
                    }
                }
                if let saveError {
                    Text(saveError).foregroundStyle(.red)
                }
            }
            .formStyle(.grouped)

            Divider()
            HStack {
                if existing == nil {
                    Button("Back") { provider = nil; test = .idle }
                }
                Spacer()
                Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction)
                Button(existing == nil ? "Add Account" : "Save", action: save)
                    .keyboardShortcut(.defaultAction)
                    .disabled(!isComplete)
            }
            .padding(16)
        }
        .frame(minHeight: 420)
    }

    @ViewBuilder private var scalewayCredentials: some View {
        let profiles = cliConfig?.profiles.filter(\.isUsable) ?? []
        Section {
            if !profiles.isEmpty {
                Picker("Credentials", selection: $useCLIProfile) {
                    Text("Scaleway CLI profile").tag(true)
                    Text("API key").tag(false)
                }
                .pickerStyle(.segmented)
            }
            if useCLIProfile, !profiles.isEmpty {
                Picker("Profile", selection: $profileName) {
                    ForEach(profiles) { p in Text(p.name).tag(p.name) }
                }
                .onChange(of: profileName) { _, new in
                    if name.isEmpty || profiles.contains(where: { $0.name.capitalized == name }) { name = new.capitalized }
                }
            } else {
                fields(ProviderKind.scaleway.fields)
            }
        } header: {
            Text("Credentials")
        } footer: {
            Text(useCLIProfile && !profiles.isEmpty
                 ? "The key is read from \(ScalewayCLIConfig.defaultURL.path(percentEncoded: false)) on every refresh, so rotating it there just works."
                 : "The secret key is stored in your login Keychain. It needs BillingReadOnly, plus read access to products for per-resource attribution.")
                .font(.caption).foregroundStyle(.secondary)
        }
    }

    private func fields(_ fields: [CredentialField]) -> some View {
        ForEach(fields) { field in
            Group {
                if field.isSecret {
                    SecureField(field.label, text: binding(secret: field.key), prompt: Text(existing == nil ? field.placeholder : "Unchanged"))
                } else {
                    TextField(field.label, text: binding(setting: field.key), prompt: Text(field.placeholder))
                }
            }
            .help(field.help ?? "")
        }
    }

    // MARK: State

    private var usesCLIProfile: Bool {
        provider == .scaleway && useCLIProfile && !(cliConfig?.profiles.filter(\.isUsable).isEmpty ?? true)
    }

    private var isComplete: Bool {
        guard let provider, !name.trimmingCharacters(in: .whitespaces).isEmpty else { return false }
        if usesCLIProfile { return !profileName.isEmpty }
        return provider.fields.allSatisfy { f in
            f.isSecret ? (!(secrets[f.key] ?? "").isEmpty || existing != nil) : !(settings[f.key] ?? "").isEmpty
        }
    }

    private func binding(secret key: String) -> Binding<String> {
        Binding { secrets[key] ?? "" } set: { secrets[key] = $0; test = .idle }
    }

    private func binding(setting key: String) -> Binding<String> {
        Binding { settings[key] ?? "" } set: { settings[key] = $0.trimmingCharacters(in: .whitespaces); test = .idle }
    }

    private func select(_ kind: ProviderKind) {
        provider = kind
        if name.isEmpty { name = kind == .demo ? "Acme Corp (demo)" : "" }
        if kind == .scaleway, profileName.isEmpty {
            let usable = cliConfig?.profiles.filter(\.isUsable) ?? []
            profileName = cliConfig?.activeProfile.flatMap { a in usable.first { $0.name == a }?.name } ?? usable.first?.name ?? ""
            if name.isEmpty { name = profileName.capitalized }
        }
    }

    private func load() {
        guard let existing else { return }
        provider = existing.provider
        name = existing.name
        settings = existing.settings
        budget = existing.monthlyBudget.map { String(Int($0)) } ?? ""
        if case .scalewayProfile(let p) = existing.credentialSource {
            useCLIProfile = true
            profileName = p
        } else {
            useCLIProfile = false
        }
    }

    private func draftAccount() -> Account? {
        guard let provider else { return nil }
        var account = existing ?? Account(name: name, provider: provider)
        account.name = name.trimmingCharacters(in: .whitespaces)
        account.provider = provider
        account.monthlyBudget = Double(budget.replacingOccurrences(of: ",", with: ".").filter { $0.isNumber || $0 == "." })
        if provider == .demo {
            account.credentialSource = .none
        } else if usesCLIProfile {
            account.credentialSource = .scalewayProfile(profileName)
            account.settings = [:]
        } else {
            account.credentialSource = .keychain
            account.settings = settings
        }
        return account
    }

    private func runTest() {
        guard var account = draftAccount() else { return }
        // Test against throwaway Keychain-free credentials so nothing is saved yet.
        let store = MemoryCredentialStore(values: secrets, fallback: existing.map { (model.credentials, $0.id) })
        account.id = existing?.id ?? account.id
        test = .running
        Task {
            do {
                let provider = try ProviderFactory.make(for: account, credentials: store, options: FetchOptions())
                try await provider.validate()
                test = .passed
            } catch {
                test = .failed(error.localizedDescription)
            }
        }
    }

    private func save() {
        guard let account = draftAccount() else { return }
        do {
            let filled = secrets.filter { !$0.value.isEmpty }
            if existing == nil { try model.add(account, secrets: filled) } else { try model.update(account, secrets: filled) }
            dismiss()
        } catch {
            saveError = error.localizedDescription
        }
    }
}

/// Secrets typed in the form, falling back to the Keychain for fields left
/// unchanged while editing.
private struct MemoryCredentialStore: CredentialStore {
    let values: [String: String]
    let fallback: (KeychainStore, UUID)?

    func secret(_ key: String, for account: UUID) -> String? {
        if let v = values[key], !v.isEmpty { return v }
        return fallback.flatMap { $0.0.secret(key, for: $0.1) }
    }

    func setSecret(_ value: String?, _ key: String, for account: UUID) throws {}
}
