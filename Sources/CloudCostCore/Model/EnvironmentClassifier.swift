import Foundation

/// Guesses which environment a resource belongs to from its name or tags.
/// Users edit the list in Settings, so naming conventions are not hard-coded.
public struct EnvironmentClassifier: Codable, Sendable, Hashable {
    public struct Environment: Codable, Sendable, Hashable, Identifiable {
        public var id: String
        public var name: String
        /// Whole words matched in resource names: `api-dev-1` matches `dev`, `devops` does not.
        public var keywords: [String]
        /// Counted as non-production by the insights.
        public var isProduction: Bool

        public init(id: String, name: String, keywords: [String], isProduction: Bool = false) {
            self.id = id
            self.name = name
            self.keywords = keywords
            self.isProduction = isProduction
        }
    }

    /// Checked in order; the first match wins.
    public var environments: [Environment]

    public init(environments: [Environment]) {
        self.environments = environments
    }

    public static let `default` = EnvironmentClassifier(environments: [
        Environment(id: "prod", name: "Production", keywords: ["prod", "production", "prd", "live"], isProduction: true),
        Environment(id: "staging", name: "Staging", keywords: ["staging", "stg", "preprod", "uat"]),
        Environment(id: "demo", name: "Demo", keywords: ["demo", "sandbox"]),
        Environment(id: "dev", name: "Development", keywords: ["dev", "development", "test", "qa"]),
    ])

    // Buckets that exist regardless of configuration.
    public static let shared = "shared"
    public static let orphan = "orphan"
    public static let unassigned = "unassigned"

    /// The environment id for a name, or nil when nothing matches.
    ///
    /// Production is checked last so that `prod-like-staging` style names, which
    /// are rarer than `api-dev`, are not all counted as production.
    public func classify(_ text: String?) -> String? {
        guard let text, !text.isEmpty else { return nil }
        let tokens = Set(text.lowercased().split(whereSeparator: { !$0.isLetter && !$0.isNumber }).map(String.init))
        let ordered = environments.filter { !$0.isProduction } + environments.filter(\.isProduction)
        return ordered.first { env in env.keywords.contains { tokens.contains($0.lowercased()) } }?.id
    }

    /// First match among several candidate strings (name, then tags…).
    public func classify(_ candidates: [String?]) -> String? {
        for candidate in candidates {
            if let hit = classify(candidate) { return hit }
        }
        return nil
    }

    public func name(of id: String) -> String {
        if let env = environments.first(where: { $0.id == id }) { return env.name }
        switch id {
        case Self.shared: return "Shared"
        case Self.orphan: return "Unattached"
        case Self.unassigned: return "Unallocated"
        default: return id.capitalized
        }
    }

    /// Display order: configured environments, then the built-in buckets.
    public var order: [String] {
        environments.map(\.id) + [Self.shared, Self.orphan, Self.unassigned]
    }

    public var nonProduction: Set<String> {
        Set(environments.filter { !$0.isProduction }.map(\.id))
    }
}
