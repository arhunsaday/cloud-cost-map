import Foundation

/// A billing account the user has connected. Holds no secret: those live in a
/// `CredentialStore`, keyed by the account id.
public struct Account: Codable, Sendable, Identifiable, Hashable {
    public var id: UUID
    public var name: String
    public var provider: ProviderKind
    /// Non-secret provider settings (organisation id, region…), keyed by `CredentialField.key`.
    public var settings: [String: String]
    /// Where the secret comes from.
    public var credentialSource: CredentialSource
    /// Monthly budget in the account's currency, if the user set one.
    public var monthlyBudget: Double?
    public var isEnabled: Bool

    public init(
        id: UUID = UUID(),
        name: String,
        provider: ProviderKind,
        settings: [String: String] = [:],
        credentialSource: CredentialSource = .keychain,
        monthlyBudget: Double? = nil,
        isEnabled: Bool = true
    ) {
        self.id = id
        self.name = name
        self.provider = provider
        self.settings = settings
        self.credentialSource = credentialSource
        self.monthlyBudget = monthlyBudget
        self.isEnabled = isEnabled
    }
}

public enum CredentialSource: Codable, Sendable, Hashable {
    /// Secrets typed into the app, kept in the macOS Keychain.
    case keychain
    /// Read at fetch time from a Scaleway CLI profile, so rotating a key in
    /// `~/.config/scw/config.yaml` needs no change here.
    case scalewayProfile(String)
    /// No secret needed (demo data).
    case none

    public var label: String {
        switch self {
        case .keychain: "Keychain"
        case .scalewayProfile(let name): "Scaleway CLI profile “\(name)”"
        case .none: "None"
        }
    }
}

/// Reads and writes secrets for an account. The app backs it with the Keychain;
/// tests back it with a dictionary.
public protocol CredentialStore: Sendable {
    func secret(_ key: String, for account: UUID) -> String?
    func setSecret(_ value: String?, _ key: String, for account: UUID) throws
}
