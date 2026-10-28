import Foundation

public struct ScalewayProvider: CloudProvider {
    public struct Configuration: Sendable {
        public var secretKey: String
        public var organizationID: String
        public var apiURL: URL

        public init(secretKey: String, organizationID: String, apiURL: URL = URL(string: "https://api.scaleway.com")!) {
            self.secretKey = secretKey
            self.organizationID = organizationID
            self.apiURL = apiURL
        }

        /// Reads the key from the Keychain or from the linked CLI profile.
        public static func resolve(account: Account, credentials: CredentialStore) throws -> Configuration {
            switch account.credentialSource {
            case .scalewayProfile(let name):
                guard let profile = ScalewayCLIConfig.load()?.profile(named: name) else {
                    throw ProviderError.missingCredential("Scaleway CLI profile “\(name)” in \(ScalewayCLIConfig.defaultURL.path)")
                }
                guard let secret = profile.secretKey else { throw ProviderError.missingCredential("secret_key in profile “\(name)”") }
                guard let org = account.settings["organization_id"] ?? profile.organizationID else {
                    throw ProviderError.missingCredential("default_organization_id in profile “\(name)”")
                }
                return Configuration(secretKey: secret, organizationID: org,
                                     apiURL: profile.apiURL.flatMap(URL.init(string:)) ?? URL(string: "https://api.scaleway.com")!)
            case .keychain, .none:
                guard let secret = credentials.secret("secret_key", for: account.id), !secret.isEmpty else {
                    throw ProviderError.missingCredential("secret key")
                }
                guard let org = account.settings["organization_id"], !org.isEmpty else {
                    throw ProviderError.missingCredential("organization ID")
                }
                return Configuration(secretKey: secret, organizationID: org)
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

    private var client: ScalewayClient {
        ScalewayClient(baseURL: configuration.apiURL, secretKey: configuration.secretKey)
    }

    public func validate() async throws {
        _ = try await client.get("/billing/v2beta1/consumptions", query: [
            "organization_id": configuration.organizationID,
            "billing_period": BillingPeriod.current().code,
            "page_size": "1",
        ])
    }

    public func fetchReports(for periods: [BillingPeriod], progress: @escaping @Sendable (String) -> Void) async throws -> [CostReport] {
        let client = client
        let org = configuration.organizationID
        progress("Fetching billing and inventory…")

        // Billing is required and fails the whole fetch; inventory only enriches.
        async let inventory = ScalewayInventory.fetch(client: client, organizationID: org)
        let consumptions = try await withThrowingTaskGroup(of: (BillingPeriod, [JSONValue]).self) { group in
            for period in periods {
                group.addTask {
                    let lines = try await client.list("/billing/v2beta1/consumptions", key: "consumptions",
                                                      query: ["organization_id": org, "billing_period": period.code])
                    return (period, lines)
                }
            }
            var out: [BillingPeriod: [JSONValue]] = [:]
            for try await (period, lines) in group { out[period] = lines }
            return out
        }

        progress("Allocating costs…")
        let attribution = ScalewayAttribution(inventory: await inventory, environments: options.environments)
        let now = Date.now
        return periods.map { period in
            attribution.report(accountID: account.id, period: period, consumptions: consumptions[period] ?? [], generatedAt: now)
        }
    }
}
