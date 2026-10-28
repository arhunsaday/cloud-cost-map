import Foundation

/// Reads profiles from the Scaleway CLI's `~/.config/scw/config.yaml`.
///
/// Only the flat `key: value` subset the CLI writes is understood, which keeps
/// this free of a YAML dependency. The top level is exposed as profile "default".
public struct ScalewayCLIConfig: Sendable {
    public struct Profile: Sendable, Hashable, Identifiable {
        public var id: String { name }
        public var name: String
        public var accessKey: String?
        public var secretKey: String?
        public var organizationID: String?
        public var projectID: String?
        public var region: String?
        public var apiURL: String?

        public var isUsable: Bool { secretKey != nil && organizationID != nil }
    }

    public var profiles: [Profile]
    public var activeProfile: String?

    public static var defaultURL: URL {
        if let custom = ProcessInfo.processInfo.environment["SCW_CONFIG_PATH"] {
            return URL(fileURLWithPath: custom)
        }
        return FileManager.default.homeDirectoryForCurrentUser.appending(path: ".config/scw/config.yaml")
    }

    public static func load(from url: URL = defaultURL) -> ScalewayCLIConfig? {
        guard let text = try? String(contentsOf: url, encoding: .utf8) else { return nil }
        return parse(text)
    }

    public static func parse(_ text: String) -> ScalewayCLIConfig {
        var top: [String: String] = [:]
        var named: [(String, [String: String])] = []
        var inProfiles = false

        for raw in text.components(separatedBy: .newlines) {
            let line = raw.split(separator: "#", maxSplits: 1, omittingEmptySubsequences: false).first.map(String.init) ?? ""
            guard !line.trimmingCharacters(in: .whitespaces).isEmpty else { continue }
            let indent = line.prefix { $0 == " " }.count
            let body = line.trimmingCharacters(in: .whitespaces)
            guard let colon = body.firstIndex(of: ":") else { continue }
            let key = String(body[..<colon])
            let value = body[body.index(after: colon)...].trimmingCharacters(in: .whitespaces)
                .trimmingCharacters(in: CharacterSet(charactersIn: "\"'"))

            if indent == 0 {
                inProfiles = key == "profiles"
                if !inProfiles, !value.isEmpty { top[key] = value }
            } else if inProfiles {
                if value.isEmpty, indent <= 4 {
                    named.append((key, [:]))
                } else if !named.isEmpty {
                    named[named.count - 1].1[key] = value
                }
            }
        }

        func profile(_ name: String, _ v: [String: String]) -> Profile {
            Profile(name: name, accessKey: v["access_key"], secretKey: v["secret_key"],
                    organizationID: v["default_organization_id"], projectID: v["default_project_id"],
                    region: v["default_region"], apiURL: v["api_url"])
        }

        var profiles: [Profile] = []
        if top["secret_key"] != nil { profiles.append(profile("default", top)) }
        profiles += named.map { profile($0.0, $0.1) }
        return ScalewayCLIConfig(profiles: profiles, activeProfile: top["active_profile"])
    }

    public func profile(named name: String) -> Profile? {
        profiles.first { $0.name == name }
    }
}
