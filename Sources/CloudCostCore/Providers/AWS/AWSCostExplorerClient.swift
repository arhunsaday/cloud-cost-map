import Foundation

/// Minimal Cost Explorer client: SigV4-signed JSON calls, pagination, readable errors.
///
/// Cost Explorer has a single endpoint, in us-east-1, for every account and
/// region. Each API request is billed by AWS (USD 0.01 at the time of writing),
/// so callers batch periods into one request and avoid needless refreshes.
struct AWSCostExplorerClient: Sendable {
    var credentials: AWSCredentials
    var endpoint = URL(string: "https://ce.us-east-1.amazonaws.com/")!
    var region = "us-east-1"
    var session: URLSession = .shared

    /// Every page of a GetCostAndUsage call.
    func costAndUsage(_ request: CostAndUsageRequest) async throws -> [JSONValue] {
        var request = request
        var pages: [JSONValue] = []
        for _ in 0..<100 {
            let page = try await call("GetCostAndUsage", body: try JSONEncoder().encode(request))
            pages.append(page)
            guard let token = page["NextPageToken"].string, !token.isEmpty else { break }
            request.nextPageToken = token
        }
        return pages
    }

    private func call(_ operation: String, body: Data) async throws -> JSONValue {
        let headers = [
            "Content-Type": "application/x-amz-json-1.1",
            "X-Amz-Target": "AWSInsightsIndexService.\(operation)",
        ]
        let signer = AWSSigner(credentials: credentials, region: region, service: "ce")
        var request = URLRequest(url: endpoint)
        request.httpMethod = "POST"
        request.httpBody = body
        request.timeoutInterval = 60
        request.setValue("CloudCostMap/1.0", forHTTPHeaderField: "User-Agent")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        for (name, value) in headers.merging(signer.signingHeaders(method: "POST", url: endpoint, headers: headers, body: body),
                                             uniquingKeysWith: { _, new in new }) {
            request.setValue(value, forHTTPHeaderField: name)
        }

        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse else { throw ProviderError.invalidResponse("not HTTP") }
        guard (200..<300).contains(http.statusCode) else { throw Self.error(status: http.statusCode, data: data) }
        return try JSONValue.parse(data)
    }

    /// AWS answers 400 for most failures and names them in `__type`; map the
    /// common ones onto the statuses `ProviderError` explains.
    static func error(status: Int, data: Data) -> ProviderError {
        let json = try? JSONValue.parse(data)
        let type = (json?["__type"].string ?? "").split(separator: "#").last.map(String.init) ?? ""
        let message = json?["message"].string ?? json?["Message"].string ?? String(decoding: data.prefix(200), as: UTF8.self)
        switch type {
        case "UnrecognizedClientException", "InvalidSignatureException", "IncompleteSignature", "ExpiredTokenException",
             "InvalidClientTokenId", "SignatureDoesNotMatch":
            return .http(status: 401, message: message)
        case "AccessDeniedException":
            return .http(status: 403, message: "Allow ce:GetCostAndUsage for this key. \(message)")
        case "DataUnavailableException":
            return .invalidResponse("Cost Explorer has no data yet. Open Cost Explorer once in the Billing console to enable it; data appears within 24 hours")
        case "":
            return .http(status: status, message: message)
        default:
            return .http(status: status, message: "\(type): \(message)")
        }
    }
}

/// The body of a GetCostAndUsage call.
/// https://docs.aws.amazon.com/aws-cost-management/latest/APIReference/API_GetCostAndUsage.html
struct CostAndUsageRequest: Encodable, Sendable {
    struct Period: Encodable, Sendable {
        var start: String
        var end: String
        enum CodingKeys: String, CodingKey { case start = "Start", end = "End" }
    }

    struct GroupBy: Encodable, Sendable, Hashable {
        var type: String
        var key: String
        enum CodingKeys: String, CodingKey { case type = "Type", key = "Key" }

        static func dimension(_ key: String) -> GroupBy { GroupBy(type: "DIMENSION", key: key) }
        static func tag(_ key: String) -> GroupBy { GroupBy(type: "TAG", key: key) }
    }

    var timePeriod: Period
    var granularity = "MONTHLY"
    var metrics = [AWSCostData.metric]
    var groupBy: [GroupBy]?
    var filter: CostFilter?
    var nextPageToken: String?

    enum CodingKeys: String, CodingKey {
        case timePeriod = "TimePeriod", granularity = "Granularity", metrics = "Metrics", groupBy = "GroupBy"
        case filter = "Filter", nextPageToken = "NextPageToken"
    }
}

/// A Cost Explorer filter expression.
indirect enum CostFilter: Encodable, Sendable {
    case dimension(String, [String])
    case tagAbsent(String)
    case not(CostFilter)
    case and([CostFilter])

    private struct Key: CodingKey {
        var stringValue: String
        var intValue: Int? { nil }
        init(_ s: String) { stringValue = s }
        init?(stringValue: String) { self.stringValue = stringValue }
        init?(intValue: Int) { nil }
    }

    private struct Values: Encodable {
        var key: String
        var values: [String]?
        var matchOptions: [String]?
        enum CodingKeys: String, CodingKey { case key = "Key", values = "Values", matchOptions = "MatchOptions" }
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: Key.self)
        switch self {
        case .dimension(let key, let values): try c.encode(Values(key: key, values: values), forKey: Key("Dimensions"))
        case .tagAbsent(let key): try c.encode(Values(key: key, matchOptions: ["ABSENT"]), forKey: Key("Tags"))
        case .not(let inner): try c.encode(inner, forKey: Key("Not"))
        case .and(let all): try c.encode(all, forKey: Key("And"))
        }
    }
}
