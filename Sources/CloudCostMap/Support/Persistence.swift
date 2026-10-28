import CloudCostCore
import Foundation
import Security

/// Secrets in the login Keychain, one generic password per account and field.
struct KeychainStore: CredentialStore {
    let service = "app.cloudcostmap.credentials"

    func secret(_ key: String, for account: UUID) -> String? {
        var query = baseQuery(key, account)
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var item: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &item) == errSecSuccess, let data = item as? Data else { return nil }
        return String(data: data, encoding: .utf8)
    }

    func setSecret(_ value: String?, _ key: String, for account: UUID) throws {
        let query = baseQuery(key, account)
        SecItemDelete(query as CFDictionary)
        guard let value, !value.isEmpty else { return }
        var add = query
        add[kSecValueData as String] = Data(value.utf8)
        add[kSecAttrLabel as String] = "Cloud Cost Map – \(key)"
        let status = SecItemAdd(add as CFDictionary, nil)
        guard status == errSecSuccess else {
            throw NSError(domain: NSOSStatusErrorDomain, code: Int(status),
                          userInfo: [NSLocalizedDescriptionKey: SecCopyErrorMessageString(status, nil) as String? ?? "Keychain error \(status)"])
        }
    }

    func removeAll(for account: UUID, keys: [String]) {
        for key in keys { try? setSecret(nil, key, for: account) }
    }

    private func baseQuery(_ key: String, _ account: UUID) -> [String: Any] {
        [kSecClass as String: kSecClassGenericPassword,
         kSecAttrService as String: service,
         kSecAttrAccount as String: "\(account.uuidString)/\(key)"]
    }
}

/// Accounts and cached reports as JSON files under Application Support.
/// Reports are cached so the app opens instantly and works offline.
struct Storage {
    let directory: URL

    static let shared: Storage = {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        return Storage(directory: base.appending(path: "Cloud Cost Map"))
    }()

    private var accountsURL: URL { directory.appending(path: "accounts.json") }
    private func reportsURL(_ id: UUID) -> URL { directory.appending(path: "Reports/\(id.uuidString).json") }

    private static let encoder: JSONEncoder = {
        let e = JSONEncoder()
        e.dateEncodingStrategy = .iso8601
        e.outputFormatting = [.prettyPrinted, .sortedKeys]
        return e
    }()

    private static let decoder: JSONDecoder = {
        let d = JSONDecoder()
        d.dateDecodingStrategy = .iso8601
        return d
    }()

    func loadAccounts() -> [Account] {
        guard let data = try? Data(contentsOf: accountsURL) else { return [] }
        return (try? Self.decoder.decode([Account].self, from: data)) ?? []
    }

    func save(accounts: [Account]) {
        write(try? Self.encoder.encode(accounts), to: accountsURL)
    }

    func loadReports(_ id: UUID) -> [CostReport] {
        guard let data = try? Data(contentsOf: reportsURL(id)) else { return [] }
        return (try? Self.decoder.decode([CostReport].self, from: data)) ?? []
    }

    func save(reports: [CostReport], for id: UUID) {
        write(try? Self.encoder.encode(reports), to: reportsURL(id))
    }

    func removeReports(_ id: UUID) {
        try? FileManager.default.removeItem(at: reportsURL(id))
    }

    private func write(_ data: Data?, to url: URL) {
        guard let data else { return }
        try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? data.write(to: url, options: .atomic)
    }
}
