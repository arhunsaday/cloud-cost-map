import Foundation

/// AWS through Cost Explorer. Needs `ce:GetCostAndUsage` only; using the
/// management account's key shows every linked account of the organization.
public struct AWSProvider: CloudProvider {
    /// Settings key of the optional environment cost allocation tag.
    public static let environmentTagKey = "environment_tag"

    public struct Configuration: Sendable {
        public var credentials: AWSCredentials
        /// Cost allocation tag whose value names the environment, if any.
        public var environmentTag: String?

        public init(credentials: AWSCredentials, environmentTag: String? = nil) {
            self.credentials = credentials
            let tag = environmentTag?.trimmingCharacters(in: .whitespaces)
            self.environmentTag = tag?.isEmpty == false ? tag : nil
        }

        /// Reads the keys from the Keychain or from the linked CLI profile.
        public static func resolve(account: Account, credentials: CredentialStore) throws -> Configuration {
            let tag = account.settings[AWSProvider.environmentTagKey]
            switch account.credentialSource {
            case .awsProfile(let name):
                guard let profile = AWSCLIConfig.load()?.profile(named: name) else {
                    throw ProviderError.missingCredential("AWS CLI profile “\(name)” in \(AWSCLIConfig.credentialsURL.path)")
                }
                guard let keys = profile.credentials else {
                    throw ProviderError.missingCredential("access keys in profile “\(name)” (\(profile.unsupportedReason ?? "none found"))")
                }
                return Configuration(credentials: keys, environmentTag: tag)
            case .keychain, .none, .scalewayProfile:
                guard let id = account.settings["access_key_id"], !id.isEmpty else { throw ProviderError.missingCredential("access key ID") }
                guard let secret = credentials.secret("secret_access_key", for: account.id), !secret.isEmpty else {
                    throw ProviderError.missingCredential("secret access key")
                }
                let token = credentials.secret("session_token", for: account.id)
                return Configuration(credentials: AWSCredentials(accessKeyID: id, secretAccessKey: secret,
                                                                 sessionToken: token?.isEmpty == false ? token : nil),
                                     environmentTag: tag)
            }
        }
    }

    public let account: Account
    public let configuration: Configuration
    public let options: FetchOptions

    public init(account: Account, configuration: Configuration, options: FetchOptions) {
        self.account = account
        self.configuration = configuration
        self.options = options
    }

    private var client: AWSCostExplorerClient {
        AWSCostExplorerClient(credentials: configuration.credentials)
    }

    public func validate() async throws {
        let period = AWSCostData.timePeriod([.current()])
        _ = try await client.costAndUsage(AWSCostData.Query.total.request(period, tagKey: nil))
    }

    public func fetchReports(for periods: [BillingPeriod], progress: @escaping @Sendable (String) -> Void) async throws -> [CostReport] {
        let client = client
        let tag = configuration.environmentTag
        let span = AWSCostData.timePeriod(periods)
        progress("Querying Cost Explorer…")

        // Every month in one request per query: Cost Explorer bills per request.
        let pages = try await withThrowingTaskGroup(of: (AWSCostData.Query, [JSONValue]).self) { group in
            for query in AWSCostData.Query.all(tagKey: tag) {
                group.addTask { (query, try await client.costAndUsage(query.request(span, tagKey: tag))) }
            }
            var out: [AWSCostData.Query: [JSONValue]] = [:]
            for try await (query, result) in group { out[query] = result }
            return out
        }

        progress("Allocating costs…")
        let data = AWSCostData(tagKey: tag) { pages[$0] ?? [] }
        let attribution = AWSCostAttribution(environments: options.environments)
        let now = Date.now
        return periods.map { attribution.report(accountID: account.id, period: $0, data: data, generatedAt: now) }
    }
}
