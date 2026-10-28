import Foundation

/// The one thing a cloud has to implement to appear in the app: turn billing
/// periods into `CostReport`s. Everything else (charts, insights, export,
/// budgets, menu bar) works from the reports.
public protocol CloudProvider: Sendable {
    /// Cheap call that proves the credentials work. Throws a readable error otherwise.
    func validate() async throws

    /// One report per requested period, in the same order. Providers should
    /// fetch shared data (inventory, project names) once for all periods.
    func fetchReports(for periods: [BillingPeriod], progress: @escaping @Sendable (String) -> Void) async throws -> [CostReport]
}

/// Options that apply to every provider.
public struct FetchOptions: Sendable {
    public var environments: EnvironmentClassifier

    public init(environments: EnvironmentClassifier = .default) {
        self.environments = environments
    }
}

public enum ProviderError: LocalizedError, Sendable {
    case missingCredential(String)
    case http(status: Int, message: String)
    case notImplemented(ProviderKind)
    case invalidResponse(String)

    public var errorDescription: String? {
        switch self {
        case .missingCredential(let field): "Missing \(field)."
        case .http(let status, let message):
            switch status {
            case 401: "The API rejected the key (401). Check that it is valid and not expired."
            case 403: "The key is valid but lacks billing permission (403). \(message)"
            default: "The API answered \(status). \(message)"
            }
        case .notImplemented(let kind): "\(kind.displayName) is not supported yet."
        case .invalidResponse(let what): "Unexpected response: \(what)."
        }
    }
}

/// Builds the provider for an account, resolving its credentials.
public enum ProviderFactory {
    public static func make(for account: Account, credentials: CredentialStore, options: FetchOptions) throws -> CloudProvider {
        switch account.provider {
        case .demo:
            return DemoProvider(account: account)
        case .scaleway:
            let config = try ScalewayProvider.Configuration.resolve(account: account, credentials: credentials)
            return ScalewayProvider(account: account, configuration: config, options: options)
        case .aws, .azure, .gcp:
            throw ProviderError.notImplemented(account.provider)
        }
    }
}
