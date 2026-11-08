import Foundation

/// Reads profiles from the AWS CLI's `~/.aws/credentials` and `~/.aws/config`.
///
/// Only profiles holding access keys are usable. SSO, assumed roles and
/// `credential_process` need the CLI to mint keys; such profiles are listed
/// with a reason so the app can say why they cannot be linked.
public struct AWSCLIConfig: Sendable {
    public struct Profile: Sendable, Hashable, Identifiable {
        public var id: String { name }
        public var name: String
        public var accessKeyID: String?
        public var secretAccessKey: String?
        public var sessionToken: String?
        public var region: String?
        /// Why the profile cannot be used directly, if it is not a key pair.
        public var unsupportedReason: String?

        public var isUsable: Bool { accessKeyID != nil && secretAccessKey != nil }

        public var credentials: AWSCredentials? {
            guard let accessKeyID, let secretAccessKey else { return nil }
            return AWSCredentials(accessKeyID: accessKeyID, secretAccessKey: secretAccessKey, sessionToken: sessionToken)
        }
    }

    public var profiles: [Profile]
    /// `AWS_PROFILE`, when set.
    public var activeProfile: String?

    public static var credentialsURL: URL {
        url(env: "AWS_SHARED_CREDENTIALS_FILE", default: ".aws/credentials")
    }

    public static var configURL: URL {
        url(env: "AWS_CONFIG_FILE", default: ".aws/config")
    }

    private static func url(env: String, default path: String) -> URL {
        if let custom = ProcessInfo.processInfo.environment[env], !custom.isEmpty {
            return URL(fileURLWithPath: (custom as NSString).expandingTildeInPath)
        }
        return FileManager.default.homeDirectoryForCurrentUser.appending(path: path)
    }

    /// Nil when neither file exists.
    public static func load(credentials: URL = credentialsURL, config: URL = configURL) -> AWSCLIConfig? {
        let c = try? String(contentsOf: credentials, encoding: .utf8)
        let f = try? String(contentsOf: config, encoding: .utf8)
        guard c != nil || f != nil else { return nil }
        return parse(credentials: c ?? "", config: f ?? "", activeProfile: ProcessInfo.processInfo.environment["AWS_PROFILE"])
    }

    public static func parse(credentials: String, config: String, activeProfile: String? = nil) -> AWSCLIConfig {
        var merged: [String: [String: String]] = [:]
        var order: [String] = []
        func add(_ sections: [(String, [String: String])]) {
            for (name, values) in sections {
                if merged[name] == nil { order.append(name) }
                // The credentials file wins over config for the same key, as in the CLI.
                merged[name] = values.merging(merged[name] ?? [:], uniquingKeysWith: { _, existing in existing })
            }
        }
        add(sections(credentials, isConfig: false))
        add(sections(config, isConfig: true))

        let profiles = order.map { name -> Profile in
            let v = merged[name]!
            var reason: String?
            if v["aws_access_key_id"] == nil || v["aws_secret_access_key"] == nil {
                if v["sso_session"] != nil || v["sso_start_url"] != nil {
                    reason = "Uses IAM Identity Center (SSO)"
                } else if v["role_arn"] != nil {
                    reason = "Assumes a role"
                } else if v["credential_process"] != nil {
                    reason = "Uses credential_process"
                } else {
                    reason = "No access keys"
                }
            }
            return Profile(name: name, accessKeyID: v["aws_access_key_id"], secretAccessKey: v["aws_secret_access_key"],
                           sessionToken: v["aws_session_token"], region: v["region"], unsupportedReason: reason)
        }
        return AWSCLIConfig(profiles: profiles, activeProfile: activeProfile)
    }

    /// `[name]` sections of an INI file. In `config`, profiles are `[profile name]`
    /// (except `default`) and other sections such as `[sso-session x]` are skipped.
    static func sections(_ text: String, isConfig: Bool) -> [(String, [String: String])] {
        var out: [(String, [String: String])] = []
        var current: Int?
        for raw in text.components(separatedBy: .newlines) {
            let line = raw.trimmingCharacters(in: .whitespaces)
            if line.isEmpty || line.hasPrefix("#") || line.hasPrefix(";") { continue }
            if line.hasPrefix("["), line.hasSuffix("]") {
                var name = line.dropFirst().dropLast().trimmingCharacters(in: .whitespaces)
                current = nil
                if isConfig {
                    if name.hasPrefix("profile ") {
                        name = name.dropFirst("profile ".count).trimmingCharacters(in: .whitespaces)
                    } else if name != "default" {
                        continue
                    }
                }
                out.append((name, [:]))
                current = out.count - 1
                continue
            }
            // Indented lines continue a nested block (`s3 =` sub-settings); not needed here.
            guard let current, raw.first != " ", raw.first != "\t", let eq = line.firstIndex(of: "=") else { continue }
            let key = line[..<eq].trimmingCharacters(in: .whitespaces).lowercased()
            let value = line[line.index(after: eq)...].trimmingCharacters(in: .whitespaces)
            if !key.isEmpty, !value.isEmpty { out[current].1[key] = value }
        }
        return out
    }

    public func profile(named name: String) -> Profile? {
        profiles.first { $0.name == name }
    }
}
