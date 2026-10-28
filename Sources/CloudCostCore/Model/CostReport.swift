import Foundation

/// Everything known about one account for one billing period.
public struct CostReport: Codable, Sendable, Identifiable {
    public var accountID: UUID
    public var period: BillingPeriod
    public var currency: String
    public var generatedAt: Date
    /// What the invoice will say: usage minus credits and discounts.
    public var billed: Double
    /// Usage before credits.
    public var gross: Double
    /// Credits and discounts, as a negative amount.
    public var credits: Double
    public var lines: [CostLine]
    /// The same money cut along different dimensions. The first one is the default.
    public var views: [CostView]
    public var findings: [Finding]
    /// Non-fatal problems met while building the report (missing permission…).
    public var warnings: [String]

    public var id: String { "\(accountID.uuidString)/\(period.code)" }

    public init(
        accountID: UUID,
        period: BillingPeriod,
        currency: String,
        generatedAt: Date = .now,
        billed: Double,
        gross: Double,
        credits: Double,
        lines: [CostLine],
        views: [CostView],
        findings: [Finding] = [],
        warnings: [String] = []
    ) {
        self.accountID = accountID
        self.period = period
        self.currency = currency
        self.generatedAt = generatedAt
        self.billed = billed
        self.gross = gross
        self.credits = credits
        self.lines = lines
        self.views = views
        self.findings = findings
        self.warnings = warnings
    }

    public func view(_ id: CostView.ID?) -> CostView? {
        views.first { $0.id == id } ?? views.first
    }

    public var isPartial: Bool { period.isCurrent() }

    /// Straight-line projection of the month's total from what has been billed so far.
    /// Returns nil for closed months and for the first hours of a month, where it is noise.
    public func forecast(now: Date = .now) -> Double? {
        let elapsed = period.elapsedFraction(now)
        guard elapsed < 1, elapsed > 0.03 else { return nil }
        return billed / elapsed
    }
}

/// One invoice line as the provider reported it.
public struct CostLine: Codable, Sendable, Hashable, Identifiable {
    public var id: String { "\(sku)|\(resource)|\(project ?? "")" }
    public var category: String
    public var product: String
    public var resource: String
    public var sku: String
    public var amount: Double
    public var project: String?
    public var region: String?
    public var quantity: String?

    public init(category: String, product: String, resource: String, sku: String, amount: Double,
                project: String? = nil, region: String? = nil, quantity: String? = nil) {
        self.category = category
        self.product = product
        self.resource = resource
        self.sku = sku
        self.amount = amount
        self.project = project
        self.region = region
        self.quantity = quantity
    }
}

/// A hierarchy of the report's costs along one dimension.
public struct CostView: Codable, Sendable, Identifiable, Hashable {
    public var id: String
    public var title: String
    /// SF Symbol name, so the UI does not need to know about every dimension.
    public var symbol: String
    public var root: CostNode

    public init(id: String, title: String, symbol: String, root: CostNode) {
        self.id = id
        self.title = title
        self.symbol = symbol
        self.root = root
    }

    public static let environment = "environment"
    public static let service = "service"
    public static let project = "project"
    public static let region = "region"
}

/// Something in the bill worth acting on.
public struct Finding: Codable, Sendable, Identifiable, Hashable {
    public enum Kind: String, Codable, Sendable {
        /// Money spent on something nobody uses.
        case reclaim
        /// Probably justified, but worth a decision.
        case review
        case info

        public var symbol: String {
            switch self {
            case .reclaim: "trash.circle.fill"
            case .review: "exclamationmark.circle.fill"
            case .info: "info.circle.fill"
            }
        }
    }

    public var id: String { title }
    public var kind: Kind
    public var title: String
    public var note: String
    public var amount: Double
    /// Nodes of `viewID` this finding is about, for highlighting.
    public var viewID: String?
    public var nodeIDs: [String]

    public init(kind: Kind, title: String, note: String, amount: Double, viewID: String? = nil, nodeIDs: [String] = []) {
        self.kind = kind
        self.title = title
        self.note = note
        self.amount = amount
        self.viewID = viewID
        self.nodeIDs = nodeIDs
    }
}
