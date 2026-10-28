import Foundation

/// Snapshot of the resources that exist now, used to split invoice lines
/// (which only name a SKU and a zone) across the resources that caused them.
///
/// Inventory is optional enrichment: a product the key cannot list just leaves
/// its costs in "Shared" or "Unallocated" and adds a warning.
public struct ScalewayInventory: Sendable {
    public var clusters: [JSONValue] = []
    public var pools: [JSONValue] = []
    public var instances: [JSONValue] = []
    public var flexibleIPs: [JSONValue] = []
    public var localVolumes: [JSONValue] = []
    public var blockVolumes: [JSONValue] = []
    public var databases: [JSONValue] = []
    public var snapshots: [JSONValue] = []
    public var redis: [JSONValue] = []
    public var loadBalancers: [JSONValue] = []
    public var loadBalancerIPs: [JSONValue] = []
    public var gatewayIPs: [JSONValue] = []
    public var dnsZones: [JSONValue] = []
    public var secrets: [JSONValue] = []
    public var appleSilicon: [JSONValue] = []
    public var edgePipelines: [JSONValue] = []
    /// Project id → name.
    public var projects: [String: String] = [:]
    public var warnings: [String] = []

    public init() {}

    /// Builds an inventory from the JSON files `scw … -o json` writes, one per
    /// resource type, as the original shell script did. Used by tests and for
    /// importing offline dumps.
    public init(directory: URL) {
        func load(_ name: String) -> [JSONValue] {
            guard let data = try? Data(contentsOf: directory.appending(path: name)) else { return [] }
            return (try? JSONValue.parse(data))?.array ?? []
        }
        clusters = load("clusters.json")
        pools = load("pools.json")
        instances = load("instances.json")
        flexibleIPs = load("ips.json")
        localVolumes = load("local_vols.json")
        blockVolumes = load("block_vols.json")
        databases = load("dbs.json")
        snapshots = load("snapshots.json")
        redis = load("redis.json")
        loadBalancers = load("lbs.json")
        loadBalancerIPs = load("lb_ips.json")
        gatewayIPs = load("gw_ips.json")
        dnsZones = load("dns_zones.json")
        secrets = load("secrets.json")
        appleSilicon = load("apple.json")
        edgePipelines = load("edge_pipelines.json")
    }
}

extension ScalewayInventory {
    private enum Scope { case zone, region, global }

    private struct Source: Sendable {
        let label: String
        let path: String
        let key: String
        nonisolated(unsafe) let keyPath: WritableKeyPath<ScalewayInventory, [JSONValue]>
        let scope: Scope

        func paths() -> [(path: String, location: String?)] {
            switch scope {
            case .zone: ScalewayClient.zones.map { (path.replacingOccurrences(of: "{z}", with: $0), $0) }
            case .region: ScalewayClient.regions.map { (path.replacingOccurrences(of: "{r}", with: $0), $0) }
            case .global: [(path, nil)]
            }
        }
    }

    private static let sources: [Source] = [
        Source(label: "Kubernetes clusters", path: "/k8s/v1/regions/{r}/clusters", key: "clusters", keyPath: \.clusters, scope: .region),
        Source(label: "Instances", path: "/instance/v1/zones/{z}/servers", key: "servers", keyPath: \.instances, scope: .zone),
        Source(label: "Flexible IPs", path: "/instance/v1/zones/{z}/ips", key: "ips", keyPath: \.flexibleIPs, scope: .zone),
        Source(label: "Local volumes", path: "/instance/v1/zones/{z}/volumes", key: "volumes", keyPath: \.localVolumes, scope: .zone),
        Source(label: "Block volumes", path: "/block/v1alpha1/zones/{z}/volumes", key: "volumes", keyPath: \.blockVolumes, scope: .zone),
        Source(label: "Databases", path: "/rdb/v1/regions/{r}/instances", key: "instances", keyPath: \.databases, scope: .region),
        Source(label: "Database snapshots", path: "/rdb/v1/regions/{r}/snapshots", key: "snapshots", keyPath: \.snapshots, scope: .region),
        Source(label: "Redis", path: "/redis/v1/zones/{z}/clusters", key: "clusters", keyPath: \.redis, scope: .zone),
        Source(label: "Load balancers", path: "/lb/v1/zones/{z}/lbs", key: "lbs", keyPath: \.loadBalancers, scope: .zone),
        Source(label: "Load balancer IPs", path: "/lb/v1/zones/{z}/ips", key: "ips", keyPath: \.loadBalancerIPs, scope: .zone),
        Source(label: "Public Gateway IPs", path: "/vpc-gw/v2/zones/{z}/ips", key: "ips", keyPath: \.gatewayIPs, scope: .zone),
        Source(label: "DNS zones", path: "/domain/v2beta1/dns-zones", key: "dns_zones", keyPath: \.dnsZones, scope: .global),
        Source(label: "Secrets", path: "/secret-manager/v1beta1/regions/{r}/secrets", key: "secrets", keyPath: \.secrets, scope: .region),
        Source(label: "Apple silicon", path: "/apple-silicon/v1alpha1/zones/{z}/servers", key: "servers", keyPath: \.appleSilicon, scope: .zone),
        Source(label: "Edge Services", path: "/edge-services/v1beta1/pipelines", key: "pipelines", keyPath: \.edgePipelines, scope: .global),
    ]

    static func fetch(client: ScalewayClient, organizationID: String) async -> ScalewayInventory {
        typealias Result = (index: Int, items: [JSONValue], warning: String?)
        var inventory = ScalewayInventory()

        let results = await withTaskGroup(of: Result.self) { group -> [Result] in
            for (index, source) in sources.enumerated() {
                for (path, location) in source.paths() {
                    group.addTask {
                        let query = source.scope == .global ? ["organization_id": organizationID] : [:]
                        do {
                            let items = try await client.list(path, key: source.key, query: query)
                            return (index, items.map { $0.withDefault("zone", location) }, nil)
                        } catch ProviderError.http(let status, _) where [400, 404, 501].contains(status) {
                            return (index, [], nil) // Product not offered in this location.
                        } catch ProviderError.http(403, _) {
                            return (index, [], "No permission to list \(source.label); their cost stays unallocated.")
                        } catch {
                            return (index, [], "Could not list \(source.label): \(error.localizedDescription)")
                        }
                    }
                }
            }
            var all: [Result] = []
            for await r in group { all.append(r) }
            return all
        }
        for r in results {
            inventory[keyPath: sources[r.index].keyPath] += r.items
            if let w = r.warning, !inventory.warnings.contains(w) { inventory.warnings.append(w) }
        }

        // Pools hang off clusters; project names make the project view readable.
        await withTaskGroup(of: [JSONValue].self) { group in
            for cluster in inventory.clusters {
                guard let id = cluster["id"].string, let region = cluster["region"].string else { continue }
                group.addTask { (try? await client.list("/k8s/v1/regions/\(region)/clusters/\(id)/pools", key: "pools")) ?? [] }
            }
            for await pools in group { inventory.pools += pools }
        }
        if let projects = try? await client.list("/account/v3/projects", key: "projects", query: ["organization_id": organizationID]) {
            for p in projects {
                if let id = p["id"].string, let name = p["name"].string { inventory.projects[id] = name }
            }
        }
        return inventory
    }
}

extension JSONValue {
    /// Adds `key` to an object that lacks it.
    func withDefault(_ key: String, _ value: String?) -> JSONValue {
        guard let value, case .object(var o) = self, o[key] == nil || o[key] == .null else { return self }
        o[key] = .string(value)
        return .object(o)
    }
}
