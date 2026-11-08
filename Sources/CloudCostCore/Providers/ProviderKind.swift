import Foundation

public enum ProviderKind: String, Codable, Sendable, CaseIterable, Identifiable {
    case scaleway
    case aws
    case azure
    case gcp
    case demo

    public var id: String { rawValue }

    public var displayName: String {
        switch self {
        case .scaleway: "Scaleway"
        case .aws: "Amazon Web Services"
        case .azure: "Microsoft Azure"
        case .gcp: "Google Cloud"
        case .demo: "Demo data"
        }
    }

    public var shortName: String {
        switch self {
        case .scaleway: "Scaleway"
        case .aws: "AWS"
        case .azure: "Azure"
        case .gcp: "GCP"
        case .demo: "Demo"
        }
    }

    public var symbol: String {
        switch self {
        case .scaleway: "cloud.fill"
        case .aws: "shippingbox.fill"
        case .azure: "triangle.fill"
        case .gcp: "hexagon.fill"
        case .demo: "sparkles"
        }
    }

    /// Brand-adjacent tint, hex RGB.
    public var tintHex: String {
        switch self {
        case .scaleway: "#4F0599"
        case .aws: "#FF9900"
        case .azure: "#0078D4"
        case .gcp: "#4285F4"
        case .demo: "#14B8A6"
        }
    }

    /// Whether a working implementation exists. Others are listed as coming soon.
    public var isAvailable: Bool {
        switch self {
        case .scaleway, .aws, .demo: true
        case .azure, .gcp: false
        }
    }

    public var blurb: String {
        switch self {
        case .scaleway: "Billing API plus inventory, so costs are split by environment and resource."
        case .aws: "Cost Explorer, split by environment tag or account, service, usage type and region."
        case .azure: "Cost Management queries per subscription."
        case .gcp: "BigQuery billing export."
        case .demo: "A realistic fictional company, to try the app without credentials."
        }
    }

    /// Shortest automatic refresh interval. Cost Explorer bills every request
    /// and only updates its data a few times a day, so polling it hourly would
    /// cost money for nothing. Manual refreshes are not limited.
    public var minimumAutoRefreshHours: Int {
        self == .aws ? 6 : 0
    }

    /// Whether keys can come from the provider's own CLI configuration.
    public var supportsCLIProfiles: Bool {
        self == .scaleway || self == .aws
    }

    /// Settings asked for whatever the credential source, including when keys
    /// come from a CLI profile.
    public var options: [CredentialField] {
        self == .aws ? Self.awsOptions : []
    }

    private static let awsOptions = [
        CredentialField(key: AWSProvider.environmentTagKey, label: "Environment tag", placeholder: "Optional, e.g. Environment", isSecret: false,
                        help: "A cost allocation tag whose value names the environment. Without it, environments are read from account names.",
                        isOptional: true),
    ]

    /// The credentials the add-account form asks for when keys are typed in.
    public var fields: [CredentialField] {
        switch self {
        case .scaleway:
            [
                CredentialField(key: "secret_key", label: "Secret key", placeholder: "xxxxxxxx-xxxx-…", isSecret: true,
                                help: "An IAM API key with BillingReadOnly, plus read access to the products you use for per-resource attribution."),
                CredentialField(key: "organization_id", label: "Organization ID", placeholder: "xxxxxxxx-xxxx-…", isSecret: false,
                                help: "Console → Organization settings."),
            ]
        case .aws:
            [
                CredentialField(key: "access_key_id", label: "Access key ID", placeholder: "AKIA…", isSecret: false,
                                help: "An IAM user key allowed ce:GetCostAndUsage. Use the management (payer) account to see every linked account."),
                CredentialField(key: "secret_access_key", label: "Secret access key", placeholder: "", isSecret: true, help: nil),
                CredentialField(key: "session_token", label: "Session token", placeholder: "Only for temporary keys", isSecret: true,
                                help: "Needed with temporary (ASIA…) credentials only.", isOptional: true),
            ]
        case .azure:
            [
                CredentialField(key: "tenant_id", label: "Tenant ID", placeholder: "", isSecret: false, help: nil),
                CredentialField(key: "client_id", label: "Client ID", placeholder: "", isSecret: false, help: nil),
                CredentialField(key: "client_secret", label: "Client secret", placeholder: "", isSecret: true, help: nil),
                CredentialField(key: "subscription_id", label: "Subscription ID", placeholder: "", isSecret: false, help: nil),
            ]
        case .gcp:
            [
                CredentialField(key: "service_account_json", label: "Service account JSON", placeholder: "", isSecret: true, help: nil),
                CredentialField(key: "billing_table", label: "Billing export table", placeholder: "project.dataset.table", isSecret: false, help: nil),
            ]
        case .demo:
            []
        }
    }
}

public struct CredentialField: Sendable, Hashable, Identifiable {
    public var id: String { key }
    public var key: String
    public var label: String
    public var placeholder: String
    public var isSecret: Bool
    public var help: String?
    /// The form can be submitted with this left empty.
    public var isOptional: Bool

    public init(key: String, label: String, placeholder: String, isSecret: Bool, help: String?, isOptional: Bool = false) {
        self.key = key
        self.label = label
        self.placeholder = placeholder
        self.isSecret = isSecret
        self.help = help
        self.isOptional = isOptional
    }
}
