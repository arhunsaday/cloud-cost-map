import Foundation

/// The Cost Explorer results one refresh needs, for every requested month at
/// once. Each query is one billed API request, so the set is kept small: four
/// without an environment tag, six with one.
public struct AWSCostData: Sendable {
    static let metric = "UnblendedCost"

    /// Record types that reduce the bill. They are left out of the breakdowns,
    /// otherwise credits covering a whole service would make it vanish from the charts.
    static let creditRecordTypes = ["Credit", "Refund", "Discount", "BundledDiscount", "EdpDiscount",
                                    "PrivateRateDiscount", "DistributorDiscount", "SppDiscount"]

    public enum Query: String, CaseIterable, Sendable {
        /// What the invoice says: everything, credits included.
        case total
        case serviceAccount = "service_account"
        case serviceUsage = "service_usage"
        case regionService = "region_service"
        /// Only with an environment tag.
        case tagService = "tag_service"
        /// Only with an environment tag: costs without it, per account.
        case untaggedServiceAccount = "untagged_service_account"

        public static func all(tagKey: String?) -> [Query] {
            tagKey == nil ? [.total, .serviceAccount, .serviceUsage, .regionService] : allCases
        }

        func request(_ timePeriod: CostAndUsageRequest.Period, tagKey: String?) -> CostAndUsageRequest {
            let usage = CostFilter.not(.dimension("RECORD_TYPE", AWSCostData.creditRecordTypes))
            let groups: [CostAndUsageRequest.GroupBy]
            var filter: CostFilter? = usage
            switch self {
            case .total:
                groups = []
                filter = nil
            case .serviceAccount: groups = [.dimension("SERVICE"), .dimension("LINKED_ACCOUNT")]
            case .serviceUsage: groups = [.dimension("SERVICE"), .dimension("USAGE_TYPE")]
            case .regionService: groups = [.dimension("REGION"), .dimension("SERVICE")]
            case .tagService: groups = [.tag(tagKey ?? ""), .dimension("SERVICE")]
            case .untaggedServiceAccount:
                groups = [.dimension("SERVICE"), .dimension("LINKED_ACCOUNT")]
                filter = .and([usage, .tagAbsent(tagKey ?? "")])
            }
            return CostAndUsageRequest(timePeriod: timePeriod, groupBy: groups.isEmpty ? nil : groups, filter: filter)
        }
    }

    /// One query's answer, merged across pages.
    public struct Result: Sendable {
        public struct Group: Sendable, Hashable {
            public var keys: [String]
            public var amount: Double
        }

        /// Period code → total, for queries without grouping.
        public var totals: [String: Double] = [:]
        /// Period code → groups.
        public var groups: [String: [Group]] = [:]
        public var currency: String?
        /// Linked account id → name.
        public var accountNames: [String: String] = [:]

        public init(pages: [JSONValue]) {
            func amount(_ metrics: JSONValue) -> Double? { metrics[AWSCostData.metric]["Amount"].double }
            for page in pages {
                for attr in page["DimensionValueAttributes"].array {
                    if let id = attr["Value"].string, let name = attr["Attributes"]["description"].string, !name.isEmpty {
                        accountNames[id] = name
                    }
                }
                for result in page["ResultsByTime"].array {
                    guard let code = result["TimePeriod"]["Start"].string.map({ String($0.prefix(7)) }) else { continue }
                    if let total = amount(result["Total"]) {
                        totals[code, default: 0] += total
                        currency = currency ?? result["Total"][AWSCostData.metric]["Unit"].string
                    }
                    for g in result["Groups"].array {
                        guard let value = amount(g["Metrics"]) else { continue }
                        groups[code, default: []].append(Group(keys: g["Keys"].array.compactMap(\.string), amount: value))
                        currency = currency ?? g["Metrics"][AWSCostData.metric]["Unit"].string
                    }
                }
            }
        }

        public func groups(_ period: BillingPeriod) -> [Group] { groups[period.code] ?? [] }
    }

    public var tagKey: String?
    public var results: [Query: Result]

    public init(tagKey: String?, pages: (Query) throws -> [JSONValue]) rethrows {
        self.tagKey = tagKey
        var results: [Query: Result] = [:]
        for query in Query.all(tagKey: tagKey) { results[query] = Result(pages: try pages(query)) }
        self.results = results
    }

    public subscript(_ query: Query) -> Result? { results[query] }

    /// Linked account names from every result.
    public var accountNames: [String: String] {
        results.values.reduce(into: [:]) { $0.merge($1.accountNames) { a, _ in a } }
    }

    /// Calendar months in UTC, as AWS bills. The end is capped at tomorrow so
    /// the current month is requested up to today.
    static func timePeriod(_ periods: [BillingPeriod], now: Date = .now) -> CostAndUsageRequest.Period {
        let first = periods.min() ?? .current(now), last = periods.max() ?? .current(now)
        var utc = Calendar(identifier: .gregorian)
        utc.timeZone = TimeZone(identifier: "UTC")!
        let tomorrow = utc.date(byAdding: .day, value: 1, to: utc.startOfDay(for: now))!
        let parts = utc.dateComponents([.year, .month, .day], from: tomorrow)
        let cap = String(format: "%04d-%02d-%02d", parts.year!, parts.month!, parts.day!)
        let end = "\(last.next.code)-01"
        return .init(start: "\(first.code)-01", end: min(end, cap))
    }
}
