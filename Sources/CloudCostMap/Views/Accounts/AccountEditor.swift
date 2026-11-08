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

    private let scalewayConfig = ScalewayCLIConfig.load()
    private let awsConfig = AWSCLIConfig.load()

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

                if kind.supportsCLIProfiles {
                    profileCredentials(kind)
                } else if !kind.fields.isEmpty {
                    Section("Credentials") { fields(kind.fields) }
                }

                if !kind.options.isEmpty {
                    Section {
                        fields(kind.options)
                    } footer: {
                        Text(kind.options.compactMap(\.help).joined(separator: " ")).font(.caption).foregroundStyle(.secondary)
                    }
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

    /// Usable CLI profile names for providers whose CLI config the app reads.
    private func profiles(_ kind: ProviderKind) -> [String] {
        switch kind {
        case .scaleway: scalewayConfig?.profiles.filter(\.isUsable).map(\.name) ?? []
        case .aws: awsConfig?.profiles.filter(\.isUsable).map(\.name) ?? []
        default: []
        }
    }

    private func activeProfile(_ kind: ProviderKind) -> String? {
        switch kind {
        case .scaleway: scalewayConfig?.activeProfile
        case .aws: awsConfig?.activeProfile ?? "default"
        default: nil
        }
    }

    @ViewBuilder private func profileCredentials(_ kind: ProviderKind) -> some View {
        let available = profiles(kind)
        let usesProfile = useCLIProfile && !available.isEmpty
        Section {
            if !available.isEmpty {
                Picker("Credentials", selection: $useCLIProfile) {
                    Text("\(kind.shortName) CLI profile").tag(true)
                    Text(kind == .aws ? "Access key" : "API key").tag(false)
                }
                .pickerStyle(.segmented)
            }
            if usesProfile {
                Picker("Profile", selection: $profileName) {
                    ForEach(available, id: \.self) { p in Text(p).tag(p) }
                }
                .onChange(of: profileName) { _, new in
                    if name.isEmpty || available.contains(where: { $0.capitalized == name }) { name = new.capitalized }
                }
            } else {
                fields(kind.fields)
            }
        } header: {
            Text("Credentials")
        } footer: {
            Text(credentialsFooter(kind, usesProfile: usesProfile)).font(.caption).foregroundStyle(.secondary)
        }
    }

    private func credentialsFooter(_ kind: ProviderKind, usesProfile: Bool) -> String {
        switch (kind, usesProfile) {
        case (.aws, true):
            let unsupported = awsConfig?.profiles.filter { !$0.isUsable }.map(\.name) ?? []
            return "Keys are read from \(AWSCLIConfig.credentialsURL.path(percentEncoded: false)) on every refresh. They need ce:GetCostAndUsage."
                + (unsupported.isEmpty ? "" : " Profiles without access keys (SSO, roles) are not listed: \(unsupported.joined(separator: ", ")).")
                + " " + Self.awsBillingNote
        case (.aws, false):
            return "The secret is stored in your login Keychain. The key needs ce:GetCostAndUsage; use the management account to see every linked account. "
                + Self.awsBillingNote
        case (_, true):
            return "The key is read from \(ScalewayCLIConfig.defaultURL.path(percentEncoded: false)) on every refresh, so rotating it there just works."
        default:
            return "The secret key is stored in your login Keychain. It needs BillingReadOnly, plus read access to products for per-resource attribution."
        }
    }

    private static let awsBillingNote = "AWS bills Cost Explorer USD 0.01 per request: a refresh makes 4, or 6 with an environment tag."

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
        guard let provider, provider.supportsCLIProfiles else { return false }
        return useCLIProfile && !profiles(provider).isEmpty
    }

    private var isComplete: Bool {
        guard let provider, !name.trimmingCharacters(in: .whitespaces).isEmpty else { return false }
        let options = provider.options.allSatisfy { $0.isOptional || !(settings[$0.key] ?? "").isEmpty }
        if usesCLIProfile { return options && !profileName.isEmpty }
        return options && provider.fields.allSatisfy { f in
            f.isOptional || (f.isSecret ? (!(secrets[f.key] ?? "").isEmpty || existing != nil) : !(settings[f.key] ?? "").isEmpty)
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
        if kind.supportsCLIProfiles, profileName.isEmpty {
            let usable = profiles(kind)
            profileName = activeProfile(kind).flatMap { a in usable.first { $0 == a } } ?? usable.first ?? ""
            if name.isEmpty { name = profileName.capitalized }
        }
    }

    private func load() {
        guard let existing else { return }
        provider = existing.provider
        name = existing.name
        settings = existing.settings
        budget = existing.monthlyBudget.map { String(Int($0)) } ?? ""
        switch existing.credentialSource {
        case .scalewayProfile(let p), .awsProfile(let p):
            useCLIProfile = true
            profileName = p
        case .keychain, .none:
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
            account.credentialSource = provider == .aws ? .awsProfile(profileName) : .scalewayProfile(profileName)
            let optionKeys = Set(provider.options.map(\.key))
            account.settings = settings.filter { optionKeys.contains($0.key) }
        } else {
            account.credentialSource = .keychain
            account.settings = settings
        }
        return account
    }

    private func runTest() {
        guard var account = draftAccount() else { return }
        // Test against throwaway Keychain-free credentials so nothing is saved yet.
        let store = MemoryCredentialStore(values: typedSecrets, fallback: existing.map { (model.credentials, $0.id) })
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

    /// Secrets typed in the form; fields left empty keep their stored value.
    /// Temporary AWS keys come with a token, so a new secret typed without one
    /// clears the old token (an empty value deletes it).
    private var typedSecrets: [String: String] {
        var typed = secrets.filter { !$0.value.isEmpty }
        if provider == .aws, typed["secret_access_key"] != nil, typed["session_token"] == nil { typed["session_token"] = "" }
        return typed
    }

    private func save() {
        guard let account = draftAccount() else { return }
        do {
            if existing == nil { try model.add(account, secrets: typedSecrets) } else { try model.update(account, secrets: typedSecrets) }
            dismiss()
        } catch {
            saveError = error.localizedDescription
        }
    }
}

/// Secrets typed in the form, falling back to the Keychain for fields left
/// unchanged while editing. An empty value means "cleared".
private struct MemoryCredentialStore: CredentialStore {
    let values: [String: String]
    let fallback: (KeychainStore, UUID)?

    func secret(_ key: String, for account: UUID) -> String? {
        if let v = values[key] { return v.isEmpty ? nil : v }
        return fallback.flatMap { $0.0.secret(key, for: $0.1) }
    }

    func setSecret(_ value: String?, _ key: String, for account: UUID) throws {}
}
