import CloudCostCore
import Foundation
import Observation

enum SidebarItem: Hashable {
    case overview
    case account(UUID)
}

enum FetchStatus: Equatable {
    case idle
    case loading(String)
    case failed(String)

    var isLoading: Bool {
        if case .loading = self { return true }
        return false
    }
}

/// App-wide state: accounts, their reports and fetching. Views read from it;
/// only it talks to providers, the Keychain and the disk.
@MainActor @Observable
final class AppModel {
    let preferences: Preferences
    let credentials = KeychainStore()
    private let storage: Storage

    private(set) var accounts: [Account]
    /// Reports per account, keyed by period.
    private(set) var reports: [UUID: [BillingPeriod: CostReport]] = [:]
    private(set) var status: [UUID: FetchStatus] = [:]

    var selection: SidebarItem? = .overview
    var period: BillingPeriod = .current()
    var isAddingAccount = false
    var editingAccount: Account?

    private var autoRefreshTask: Task<Void, Never>?

    init(preferences: Preferences, storage: Storage = .shared) {
        self.preferences = preferences
        self.storage = storage
        accounts = storage.loadAccounts()
        for account in accounts {
            let cached = storage.loadReports(account.id)
            reports[account.id] = Dictionary(cached.map { ($0.period, $0) }, uniquingKeysWith: { a, _ in a })
        }
        if let first = accounts.first, accounts.count == 1 { selection = .account(first.id) }
    }

    // MARK: - Reading

    var periods: [BillingPeriod] { BillingPeriod.recent(preferences.monthsToLoad) }

    func account(_ id: UUID) -> Account? { accounts.first { $0.id == id } }

    func report(_ id: UUID, _ period: BillingPeriod? = nil) -> CostReport? {
        reports[id]?[period ?? self.period]
    }

    /// Reports of the loaded months, oldest first.
    func history(_ id: UUID) -> [CostReport] {
        periods.compactMap { reports[id]?[$0] }
    }

    var selectedAccount: Account? {
        if case .account(let id) = selection { return account(id) }
        return nil
    }

    var isLoadingAny: Bool { status.values.contains { $0.isLoading } }

    func lastUpdated(_ id: UUID) -> Date? {
        reports[id]?.values.map(\.generatedAt).max()
    }

    // MARK: - Fetching

    func refresh(_ id: UUID) async {
        guard let account = account(id), account.isEnabled, status[id]?.isLoading != true else { return }
        status[id] = .loading("Connecting…")
        do {
            let provider = try ProviderFactory.make(for: account, credentials: credentials,
                                                    options: FetchOptions(environments: preferences.environments))
            let fetched = try await provider.fetchReports(for: periods) { [weak self] message in
                Task { @MainActor in
                    if self?.status[id]?.isLoading == true { self?.status[id] = .loading(message) }
                }
            }
            var merged = reports[id] ?? [:]
            for r in fetched { merged[r.period] = r }
            reports[id] = merged
            storage.save(reports: Array(merged.values).sorted { $0.period < $1.period }, for: id)
            status[id] = .idle
        } catch {
            status[id] = .failed(error.localizedDescription)
        }
    }

    func refreshAll() async {
        await withTaskGroup(of: Void.self) { group in
            for account in accounts where account.isEnabled {
                group.addTask { await self.refresh(account.id) }
            }
        }
    }

    /// Refreshes stale accounts now, then keeps them fresh at the configured interval.
    func startAutoRefresh() {
        autoRefreshTask?.cancel()
        autoRefreshTask = Task { [weak self] in
            while !Task.isCancelled {
                guard let self else { return }
                let hours = preferences.refreshIntervalHours
                let threshold = Date.now.addingTimeInterval(-Double(max(hours, 1)) * 3600)
                for account in accounts where account.isEnabled {
                    let missing = periods.contains { reports[account.id]?[$0] == nil }
                    if missing || (hours > 0 && (lastUpdated(account.id) ?? .distantPast) < threshold) {
                        Task { await self.refresh(account.id) }
                    }
                }
                try? await Task.sleep(for: .seconds(15 * 60))
            }
        }
    }

    // MARK: - Accounts

    func add(_ account: Account, secrets: [String: String]) throws {
        try saveSecrets(secrets, for: account)
        accounts.append(account)
        storage.save(accounts: accounts)
        selection = .account(account.id)
        Task { await refresh(account.id) }
    }

    func update(_ account: Account, secrets: [String: String]) throws {
        try saveSecrets(secrets, for: account)
        guard let index = accounts.firstIndex(where: { $0.id == account.id }) else { return }
        accounts[index] = account
        storage.save(accounts: accounts)
        Task { await refresh(account.id) }
    }

    func setBudget(_ budget: Double?, for id: UUID) {
        guard let index = accounts.firstIndex(where: { $0.id == id }) else { return }
        accounts[index].monthlyBudget = budget
        storage.save(accounts: accounts)
    }

    func remove(_ id: UUID) {
        guard let account = account(id) else { return }
        credentials.removeAll(for: id, keys: account.provider.fields.map(\.key))
        accounts.removeAll { $0.id == id }
        reports[id] = nil
        status[id] = nil
        storage.removeReports(id)
        storage.save(accounts: accounts)
        if selection == .account(id) { selection = .overview }
    }

    func moveAccounts(from source: IndexSet, to destination: Int) {
        accounts.move(fromOffsets: source, toOffset: destination)
        storage.save(accounts: accounts)
    }

    /// Links every usable Scaleway CLI profile not already linked.
    @discardableResult
    func importScalewayProfiles() -> Int {
        guard let config = ScalewayCLIConfig.load() else { return 0 }
        let linked = Set(accounts.compactMap { a -> String? in
            if case .scalewayProfile(let name) = a.credentialSource { return name }
            return nil
        })
        var added = 0
        for profile in config.profiles where profile.isUsable && !linked.contains(profile.name) {
            // The top-level "default" profile often duplicates a named one.
            if profile.name == "default", config.profiles.contains(where: { $0.name != "default" && $0.secretKey == profile.secretKey }) { continue }
            let account = Account(name: profile.name.replacingOccurrences(of: "-", with: " ").capitalized, provider: .scaleway,
                                  settings: ["organization_id": profile.organizationID ?? ""],
                                  credentialSource: .scalewayProfile(profile.name))
            accounts.append(account)
            added += 1
            Task { await refresh(account.id) }
        }
        storage.save(accounts: accounts)
        if added > 0, let last = accounts.last { selection = .account(last.id) }
        return added
    }

    func addDemoAccount() {
        try? add(Account(name: "Acme Corp (demo)", provider: .demo, credentialSource: .none), secrets: [:])
    }

    private func saveSecrets(_ secrets: [String: String], for account: Account) throws {
        guard account.credentialSource == .keychain else { return }
        for (key, value) in secrets { try credentials.setSecret(value, key, for: account.id) }
    }
}
