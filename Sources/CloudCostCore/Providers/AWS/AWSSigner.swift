import Foundation

/// AWS Signature Version 4 for a single request.
/// https://docs.aws.amazon.com/IAM/latest/UserGuide/reference_sigv-create-signed-request.html
struct AWSSigner: Sendable {
    var credentials: AWSCredentials
    var region: String
    var service: String

    /// Headers to add to the request: `Authorization`, `X-Amz-Date` and, for
    /// temporary credentials, `X-Amz-Security-Token`. Every header in
    /// `headers` is signed, plus `host`.
    func signingHeaders(method: String, url: URL, headers: [String: String], body: Data, date: Date = .now) -> [String: String] {
        let amzDate = Self.timestamp(date)
        let day = String(amzDate.prefix(8))

        var added = ["X-Amz-Date": amzDate]
        if let token = credentials.sessionToken, !token.isEmpty { added["X-Amz-Security-Token"] = token }

        var signed: [String: String] = [:]
        for (name, value) in headers.merging(added, uniquingKeysWith: { _, new in new }) {
            signed[name.lowercased()] = value.trimmingCharacters(in: .whitespaces)
        }
        signed["host"] = Self.host(url)

        let names = signed.keys.sorted()
        let signedHeaders = names.joined(separator: ";")
        let canonical = [
            method.uppercased(),
            Self.canonicalPath(url),
            Self.canonicalQuery(url),
            names.map { "\($0):\(signed[$0]!)\n" }.joined(),
            signedHeaders,
            AWSCrypto.sha256Hex(body),
        ].joined(separator: "\n")

        let scope = "\(day)/\(region)/\(service)/aws4_request"
        let stringToSign = ["AWS4-HMAC-SHA256", amzDate, scope, AWSCrypto.sha256Hex(Data(canonical.utf8))].joined(separator: "\n")
        let signature = AWSCrypto.hmac(key: signingKey(day: day), stringToSign).hex

        added["Authorization"] = "AWS4-HMAC-SHA256 Credential=\(credentials.accessKeyID)/\(scope), SignedHeaders=\(signedHeaders), Signature=\(signature)"
        return added
    }

    func signingKey(day: String) -> Data {
        let date = AWSCrypto.hmac(key: Data("AWS4\(credentials.secretAccessKey)".utf8), day)
        let region = AWSCrypto.hmac(key: date, region)
        let service = AWSCrypto.hmac(key: region, service)
        return AWSCrypto.hmac(key: service, "aws4_request")
    }

    static func timestamp(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(identifier: "UTC")
        formatter.dateFormat = "yyyyMMdd'T'HHmmss'Z'"
        return formatter.string(from: date)
    }

    private static func host(_ url: URL) -> String {
        let host = url.host ?? ""
        guard let port = url.port, !(url.scheme == "https" && port == 443), !(url.scheme == "http" && port == 80) else { return host }
        return "\(host):\(port)"
    }

    private static func canonicalPath(_ url: URL) -> String {
        let path = URLComponents(url: url, resolvingAgainstBaseURL: false)?.percentEncodedPath ?? ""
        guard !path.isEmpty else { return "/" }
        // Normalise to RFC 3986 encoding, segment by segment.
        return path.split(separator: "/", omittingEmptySubsequences: false)
            .map { uriEncode($0.removingPercentEncoding ?? String($0)) }
            .joined(separator: "/")
    }

    private static func canonicalQuery(_ url: URL) -> String {
        let items = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems ?? []
        let pairs: [(name: String, value: String)] = items.map { (uriEncode($0.name), uriEncode($0.value ?? "")) }
        let sorted = pairs.sorted { a, b in a.name == b.name ? a.value < b.value : a.name < b.name }
        return sorted.map { "\($0.name)=\($0.value)" }.joined(separator: "&")
    }

    private static let unreserved = CharacterSet(charactersIn: "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-._~")

    static func uriEncode(_ text: String) -> String {
        text.addingPercentEncoding(withAllowedCharacters: unreserved) ?? text
    }
}

/// An access key pair, with the session token of temporary credentials.
public struct AWSCredentials: Sendable, Hashable {
    public var accessKeyID: String
    public var secretAccessKey: String
    public var sessionToken: String?

    public init(accessKeyID: String, secretAccessKey: String, sessionToken: String? = nil) {
        self.accessKeyID = accessKeyID
        self.secretAccessKey = secretAccessKey
        self.sessionToken = sessionToken
    }
}

extension Data {
    var hex: String { map { String(format: "%02x", $0) }.joined() }
}
