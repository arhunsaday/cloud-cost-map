import Foundation

/// Loosely typed JSON for provider responses we only read a few fields of.
/// Avoids a Codable struct per API resource and tolerates fields that come and go.
public enum JSONValue: Sendable, Hashable, Decodable {
    case null
    case bool(Bool)
    case number(Double)
    case string(String)
    case array([JSONValue])
    case object([String: JSONValue])

    public init(from decoder: Decoder) throws {
        let c = try decoder.singleValueContainer()
        if c.decodeNil() { self = .null }
        else if let v = try? c.decode(Bool.self) { self = .bool(v) }
        else if let v = try? c.decode(Double.self) { self = .number(v) }
        else if let v = try? c.decode(String.self) { self = .string(v) }
        else if let v = try? c.decode([JSONValue].self) { self = .array(v) }
        else { self = .object(try c.decode([String: JSONValue].self)) }
    }

    public static func parse(_ data: Data) throws -> JSONValue {
        try JSONDecoder().decode(JSONValue.self, from: data)
    }

    public subscript(key: String) -> JSONValue {
        if case .object(let o) = self { return o[key] ?? .null }
        return .null
    }

    public var string: String? {
        switch self {
        case .string(let s): s
        case .number(let n): n.rounded() == n ? String(Int64(n)) : String(n)
        default: nil
        }
    }

    /// Numbers, and numbers sent as strings (int64 fields often are).
    public var double: Double? {
        switch self {
        case .number(let n): n
        case .string(let s): Double(s)
        default: nil
        }
    }

    public var int: Int? { double.map { Int($0) } }

    public var bool: Bool? {
        if case .bool(let b) = self { return b }
        return nil
    }

    public var array: [JSONValue] {
        if case .array(let a) = self { return a }
        return []
    }

    public var isNull: Bool {
        if case .null = self { return true }
        return false
    }

    /// `"key=value"` style tags, as Scaleway uses them.
    public func tag(_ key: String) -> String? {
        for t in self["tags"].array.compactMap(\.string) where t.hasPrefix(key + "=") {
            return String(t.dropFirst(key.count + 1))
        }
        return nil
    }
}
