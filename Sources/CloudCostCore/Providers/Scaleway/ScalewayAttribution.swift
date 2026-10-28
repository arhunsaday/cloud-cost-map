import Foundation

/// Turns Scaleway billing lines plus an inventory snapshot into a `CostReport`.
///
/// An invoice line only says "DEV1-S in fr-par-1, 412 hours". The rules below
/// find which current resources match that SKU and split the amount across
/// them, so the bill can be read per environment and per resource. Pure: no
/// network, so it is tested against recorded fixtures.
public struct ScalewayAttribution: Sendable {
    public let inventory: ScalewayInventory
    public let environments: EnvironmentClassifier

    private let envOfCluster: [String: String]
    private let instanceByID: [String: JSONValue]

    public init(inventory: ScalewayInventory, environments: EnvironmentClassifier) {
        self.inventory = inventory
        self.environments = environments
        var clusters: [String: String] = [:]
        for c in inventory.clusters {
            if let id = c["id"].string { clusters[id] = environments.classify(c["name"].string) ?? EnvironmentClassifier.shared }
        }
        envOfCluster = clusters
        instanceByID = Dictionary(inventory.instances.compactMap { i in i["id"].string.map { ($0, i) } }, uniquingKeysWith: { a, _ in a })
    }

    // MARK: - Service groups

    struct Group {
        let key: String
        let label: String
    }

    static let groups: [Group] = [
        Group(key: "compute", label: "Compute"),
        Group(key: "db", label: "Managed Databases"),
        Group(key: "network", label: "Network"),
        Group(key: "storage", label: "Block Storage"),
        Group(key: "baremetal", label: "Bare Metal"),
        Group(key: "other", label: "Other Services"),
    ]

    static func group(ofCategory category: String) -> String {
        switch category {
        case "Compute": "compute"
        case "Managed Databases": "db"
        case "Network": "network"
        case "Storage": "storage"
        case "BareMetal": "baremetal"
        default: "other"
        }
    }

    static func groupLabel(_ key: String) -> String {
        groups.first { $0.key == key }?.label ?? key
    }

    // MARK: - Allocation

    /// A slice of one invoice line, attributed to one resource.
    struct Share {
        var env: String
        var label: String
        var fraction: Double
        var detail: String
        var flag: CostFlag?
    }

    private func env(of name: String?) -> String {
        environments.classify(name) ?? EnvironmentClassifier.shared
    }

    private func envOf(instance i: JSONValue) -> String {
        if let cluster = i.tag("kapsule") { return envOfCluster[cluster] ?? EnvironmentClassifier.shared }
        return env(of: i["name"].string)
    }

    private func label(instance i: JSONValue) -> String {
        let name = i["name"].string ?? "instance"
        if let pool = i.tag("pool-name") { return "Node \(pool) · \(name.suffix(6))" }
        return name
    }

    /// `fr-par-1`, `par1`, `run_fr-par-2` → `par1`, `par2`. Nil when no zone is named.
    static func zoneKey(_ text: String?) -> String? {
        guard let text, let m = text.captures(#"(par|ams|waw)-?(\d)"#) else { return nil }
        return m[0] + m[1]
    }

    private func even<T>(_ items: [T], env: (T) -> String, label: (T) -> String, detail: (T) -> String, flag: CostFlag? = nil) -> [Share]? {
        guard !items.isEmpty else { return nil }
        return items.map { Share(env: env($0), label: label($0), fraction: 1 / Double(items.count), detail: detail($0), flag: flag) }
    }

    private func bySize<T>(_ items: [T], size: (T) -> Double, env: (T) -> String, label: (T) -> String, detail: (T) -> String) -> [Share]? {
        let total = items.reduce(0) { $0 + size($1) }
        guard total > 0 else { return nil }
        return items.map { Share(env: env($0), label: label($0), fraction: size($0) / total, detail: detail($0)) }
    }

    private func markOrphans(_ shares: [Share]?) -> [Share]? {
        shares?.map { s in var s = s; if s.env == EnvironmentClassifier.orphan { s.flag = .orphan }; return s }
    }

    private func gigabytes(_ bytes: Double?) -> String {
        "\(Int(((bytes ?? 0) / 1e9).rounded())) GB"
    }

    func attribute(sku: String) -> [Share]? {
        let inv = inventory
        let zone = Self.zoneKey(sku)

        if let m = sku.captures(#"^/(?:instance/server|compute)/([^/]+)/(.+)"#) {
            let type = m[0].lowercased()
            let z = Self.zoneKey(m[1])
            let matching = inv.instances.filter {
                ($0["commercial_type"].string ?? "").lowercased().replacingOccurrences(of: "-", with: "_") == type && Self.zoneKey($0["zone"].string) == z
            }
            return even(matching, env: envOf(instance:), label: label(instance:),
                        detail: { "\($0["commercial_type"].string ?? ""), \($0["zone"].string ?? "")" })
        }
        if sku.hasPrefix("/instance/volume/l_ssd/") {
            let vols = inv.localVolumes.filter { Self.zoneKey($0["zone"].string) == zone && !$0["server"].isNull }
            return bySize(vols, size: { $0["size"].double ?? 0 },
                          env: { v in envOf(instance: instanceByID[v["server"]["id"].string ?? ""] ?? v["server"]) },
                          label: { "Local SSD · \(($0["server"]["name"].string ?? "").suffix(6)) (\(gigabytes($0["size"].double)))" },
                          detail: { _ in "Local disk included with the instance type" })
        }
        if sku.hasPrefix("/apple-silicon/") {
            return even(inv.appleSilicon, env: { env(of: $0["name"].string) }, label: { $0["name"].string ?? "Mac mini" },
                        detail: { "\($0["type"].string ?? ""), \($0["zone"].string ?? "")" })
        }
        if sku.hasPrefix("/storage/rdb/backup-storage") {
            return [Share(env: EnvironmentClassifier.shared, label: "Database backups", fraction: 1, detail: "Logical backup storage")]
        }
        if let m = sku.captures(#"^/storage/rdb/(node|instance|storage)/([^/]+)/"#) {
            return rdb(kind: m[0], key: m[1])
        }
        if let m = sku.captures(#"^/storage/redis/(main-node|additional-node)/([^/]+)/"#) {
            let type = m[1].lowercased()
            let matching = inv.redis.filter { ($0["node_type"].string ?? "").lowercased() == type }
            if m[0] == "main-node" {
                return even(matching, env: { env(of: $0["name"].string) }, label: { $0["name"].string ?? "Redis" },
                            detail: { $0["node_type"].string ?? "" })
            }
            return bySize(matching.filter { ($0["cluster_size"].double ?? 1) > 1 }, size: { ($0["cluster_size"].double ?? 1) - 1 },
                          env: { env(of: $0["name"].string) }, label: { "\($0["name"].string ?? "Redis") · replicas" },
                          detail: { "\($0["node_type"].string ?? ""), additional nodes" })
        }
        if sku.hasPrefix("/network/loadbalancer/ip/") {
            var owner: [String: JSONValue] = [:]
            for lb in inv.loadBalancers { for ip in lb["ip"].array { if let a = ip["ip_address"].string { owner[a] = lb } } }
            return markOrphans(even(inv.loadBalancerIPs,
                                    env: { owner[$0["ip_address"].string ?? ""].map(lbEnv) ?? EnvironmentClassifier.orphan },
                                    label: { ip in owner[ip["ip_address"].string ?? ""].map { "IP \($0["name"].string ?? "")" } ?? "LB IP \(ip["ip_address"].string ?? "")" },
                                    detail: { $0["ip_address"].string ?? "" }))
        }
        if let m = sku.captures(#"^/network/loadbalancer/loadbalancer-([^/]+)/"#) {
            let type = m[0]
            let matching = inv.loadBalancers.filter { ($0["type"].string ?? "").lowercased().replacingOccurrences(of: "lb-", with: "") == type }
            return even(matching, env: lbEnv, label: { "\($0["name"].string ?? "") (\(($0["type"].string ?? "").uppercased()))" },
                        detail: { _ in "Load balancer" })
        }
        if sku.hasPrefix("/network/ipam/ipv4/") {
            let ips = inv.flexibleIPs.filter {
                Self.zoneKey($0["zone"].string) == zone && $0["type"].string != "routed_ipv6" && $0["address"].string != nil
            }
            return markOrphans(even(ips, env: { ip in
                guard let server = ip["server"]["id"].string else { return EnvironmentClassifier.orphan }
                return instanceByID[server].map(envOf(instance:)) ?? EnvironmentClassifier.shared
            }, label: flexibleIPLabel, detail: { "\($0["address"].string ?? "")\($0["server"].isNull ? ", detached" : "")" }))
        }
        if sku.hasPrefix("/network/ipam/ipv6") {
            return [Share(env: EnvironmentClassifier.shared, label: "IPv6", fraction: 1, detail: "")]
        }
        if sku.hasPrefix("/network/vpc/public-gateway/ip/") {
            let ips = inv.gatewayIPs.filter { Self.zoneKey($0["zone"].string) == zone }
            return markOrphans(even(ips, env: { $0["gateway_id"].isNull ? EnvironmentClassifier.orphan : EnvironmentClassifier.shared },
                                    label: { "Public Gateway IP \($0["address"].string ?? "")" },
                                    detail: { $0["gateway_id"].isNull ? "Reserved, not attached to a gateway" : "Attached to a gateway" }))
        }
        if sku.hasPrefix("/network/vpc/") {
            return [Share(env: EnvironmentClassifier.shared, label: "VPC", fraction: 1, detail: "")]
        }
        if sku.hasPrefix("/network/domain/dns/external-zone/") {
            return even(rootDNSZones, env: { _ in EnvironmentClassifier.shared }, label: { "DNS zone \($0)" }, detail: { _ in "External DNS zone" })
        }
        if sku.hasPrefix("/network/domain/") {
            return [Share(env: EnvironmentClassifier.shared, label: "Domains", fraction: 1, detail: "")]
        }
        if sku.hasPrefix("/network/edge-services/") {
            return even(inv.edgePipelines, env: { env(of: $0["name"].string) }, label: { "Edge Services · \($0["name"].string ?? "")" },
                        detail: { "Shared Edge Services plan, split per pipeline (status \($0["status"].string ?? "?"))" })
        }
        if sku.hasPrefix("/storage/block/") {
            return blockStorage(zone: zone)
        }
        if sku.hasPrefix("/observability/") {
            return [Share(env: EnvironmentClassifier.shared, label: "Cockpit", fraction: 1, detail: "Cockpit rules and retention")]
        }
        if sku.hasPrefix("/paas/secret_manager/version/") {
            var acc: [String: (versions: Double, count: Int)] = [:]
            for s in inv.secrets {
                let e = environments.classify([s["name"].string] + s["tags"].array.map(\.string)) ?? EnvironmentClassifier.shared
                acc[e, default: (0, 0)].versions += s["version_count"].double ?? 1
                acc[e, default: (0, 0)].count += 1
            }
            return bySize(acc.sorted { $0.key < $1.key }, size: { $0.value.versions }, env: { $0.key },
                          label: { "Secrets \(environments.name(of: $0.key)) (\($0.value.count) secrets, \(Int($0.value.versions)) versions)" },
                          detail: { _ in "Version storage, split by number of versions" })
        }
        if sku.hasPrefix("/paas/secret_manager/access/") {
            return [Share(env: EnvironmentClassifier.shared, label: "Secret Manager · API access", fraction: 1, detail: "Read requests, all environments")]
        }
        for (prefix, label) in [("/tools/registry/", "Container Registry"), ("/storage/obj/", "Object Storage"),
                                ("/paas/", "Serverless"), ("/k8s/", "Kubernetes control planes")] where sku.hasPrefix(prefix) {
            return [Share(env: EnvironmentClassifier.shared, label: label, fraction: 1, detail: "")]
        }
        return nil
    }

    private func lbEnv(_ lb: JSONValue) -> String {
        environments.classify([lb["name"].string] + lb["tags"].array.map(\.string)) ?? EnvironmentClassifier.shared
    }

    private func flexibleIPLabel(_ ip: JSONValue) -> String {
        guard let server = ip["server"]["id"].string else { return "IPv4 \(ip["address"].string ?? "")" }
        if let inst = instanceByID[server], let pool = inst.tag("pool-name") { return "IPv4 nodes \(pool)" }
        return "IPv4 \(ip["server"]["name"].string ?? server)"
    }

    var rootDNSZones: [String] {
        Array(Set(inventory.dnsZones.filter { ($0["subdomain"].string ?? "").isEmpty }.compactMap(\.["domain"].string)
            .filter { $0 != "privatedns" })).sorted()
    }

    private func snapshotCount(_ db: JSONValue) -> Int {
        inventory.snapshots.filter { $0["instance_id"].string == db["id"].string }.count
    }

    private func rdb(kind: String, key: String) -> [Share]? {
        let dbs = inventory.databases
        let name: (JSONValue) -> String = { $0["name"].string ?? "database" }
        if kind == "storage" {
            let isSnapshot = key.hasSuffix("-snapshot")
            let volumeType = key.replacingOccurrences(of: "-snapshot", with: "")
            let matching = dbs.filter { $0["volume"]["type"].string == volumeType }
            if isSnapshot {
                return bySize(matching, size: { Double(max(snapshotCount($0), 1)) }, env: { env(of: name($0)) },
                              label: { "\(name($0)) · snapshots (\(snapshotCount($0)))" }, detail: { _ in "Snapshots \(volumeType)" })
            }
            return bySize(matching, size: { $0["volume"]["size"].double ?? 0 }, env: { env(of: name($0)) },
                          label: { "\(name($0)) · volume \(gigabytes($0["volume"]["size"].double))" }, detail: { _ in volumeType })
        }
        let matching = dbs.filter { ($0["node_type"].string ?? "").lowercased() == key }
        let what = kind == "node" ? "nodes" : "management"
        return even(matching, env: { env(of: name($0)) },
                    label: { "\(name($0)) · \(what)\(kind == "node" && $0["is_ha_cluster"].bool == true ? " HA (×2)" : "")" },
                    detail: { "\($0["node_type"].string ?? "")\($0["is_ha_cluster"].bool == true ? ", high availability" : "")" })
    }

    private func blockStorage(zone: String?) -> [Share]? {
        var groups: [String: (env: String, label: String, gb: Double, count: Int)] = [:]
        for v in inventory.blockVolumes where Self.zoneKey(v["zone"].string) == zone {
            let (env, label) = blockOwner(v)
            let key = env + "|" + label
            groups[key, default: (env, label, 0, 0)].gb += (v["size"].double ?? 0) / 1e9
            groups[key, default: (env, label, 0, 0)].count += 1
        }
        let items = groups.values.sorted { $0.label < $1.label }
        return markOrphans(bySize(items, size: { $0.gb }, env: { $0.env },
                                  label: { $0.count > 1 ? "\($0.label) (\($0.count) vol., \(Int($0.gb)) GB)" : "\($0.label) (\(Int($0.gb)) GB)" },
                                  detail: { _ in "Block volumes, split by provisioned GB" }))
    }

    private func blockOwner(_ v: JSONValue) -> (String, String) {
        let name = v["name"].string ?? "volume"
        if name.contains("_pvc-") {
            let env = envOfCluster[String(name.split(separator: "_").first ?? "")] ?? EnvironmentClassifier.shared
            return (env, "PVC \(environments.name(of: env)) · \(v["zone"].string ?? "")")
        }
        let refs = v["references"].array
        for ref in refs {
            if let inst = instanceByID[ref["product_resource_id"].string ?? ""] {
                return (envOf(instance: inst), "Disk \(label(instance: inst))")
            }
        }
        if refs.isEmpty { return (EnvironmentClassifier.orphan, "Detached volume \(name)") }
        return (env(of: name), "Volume \(name)")
    }

    // MARK: - Report

    /// Builds the report for one billing period from its raw consumption lines.
    public func report(accountID: UUID, period: BillingPeriod, consumptions: [JSONValue], generatedAt: Date = .now) -> CostReport {
        func amount(_ c: JSONValue) -> Double {
            (c["value"]["units"].double ?? 0) + (c["value"]["nanos"].double ?? 0) / 1e9
        }
        let currency = consumptions.lazy.compactMap { $0["value"]["currency_code"].string }.first ?? "EUR"
        let billed = consumptions.reduce(0) { $0 + amount($1) }

        var lines: [CostLine] = []
        var credits = 0.0
        for c in consumptions {
            let v = amount(c)
            if v < 0 { credits += v; continue }
            guard v >= 0.005 else { continue }
            let projectID = c["project_id"].string
            lines.append(CostLine(category: c["category_name"].string ?? "Other",
                                  product: c["product_name"].string ?? "Unknown",
                                  resource: c["resource_name"].string ?? "",
                                  sku: c["sku"].string ?? "",
                                  amount: v,
                                  project: projectID.map { inventory.projects[$0] ?? $0 },
                                  quantity: [c["billed_quantity"].string, c["unit"].string].compactMap { $0 }.joined(separator: " ").nilIfEmpty))
        }

        // Allocate every line once; the environment view and the line flags both use it.
        let allocations: [[Share]] = lines.map { line in
            attribute(sku: line.sku) ?? [Share(env: EnvironmentClassifier.unassigned, label: "\(line.product) · \(line.resource)",
                                               fraction: 1, detail: line.sku, flag: .unassigned)]
        }

        let envView = environmentView(lines: lines, allocations: allocations)
        let views = [
            envView,
            serviceView(lines: lines, allocations: allocations),
            projectView(lines: lines),
        ]
        var warnings = inventory.warnings
        let unassigned = Set(zip(lines, allocations).filter { $0.1.first?.flag == .unassigned }.map(\.0.sku))
        if !unassigned.isEmpty {
            warnings.append("\(unassigned.count) SKU\(unassigned.count == 1 ? "" : "s") without an allocation rule: \(unassigned.sorted().joined(separator: ", "))")
        }
        return CostReport(accountID: accountID, period: period, currency: currency, generatedAt: generatedAt,
                          billed: billed, gross: lines.reduce(0) { $0 + $1.amount }, credits: credits,
                          lines: lines, views: views, findings: findings(envView: envView), warnings: warnings)
    }

    private func environmentView(lines: [CostLine], allocations: [[Share]]) -> CostView {
        struct Bucket { var value = 0.0; var detail = ""; var flag: CostFlag?; var skus: Set<String> = [] }
        var buckets: [String: [String: [String: Bucket]]] = [:] // env → group → label
        for (line, shares) in zip(lines, allocations) {
            let group = Self.group(ofCategory: line.category)
            for share in shares {
                let value = line.amount * share.fraction
                guard value >= 0.005 else { continue }
                var b = buckets[share.env, default: [:]][group, default: [:]][share.label, default: Bucket()]
                b.value += value
                b.detail = share.detail
                b.flag = share.flag
                b.skus.insert(line.sku)
                buckets[share.env, default: [:]][group, default: [:]][share.label] = b
            }
        }
        let envNodes: [CostNode] = environments.order.compactMap { env in
            guard let groups = buckets[env] else { return nil }
            let groupNodes = Self.groups.compactMap { g -> CostNode? in
                guard let leaves = groups[g.key] else { return nil }
                return .group(id: "env/\(env)/\(g.key)", name: g.label, colorKey: g.key, children: leaves.map { label, b in
                    CostNode(id: "env/\(env)/\(g.key)/\(label)", name: label, subtitle: b.skus.sorted().joined(separator: ", "),
                             cost: b.value, detail: b.detail, flag: b.flag, skus: b.skus.sorted(), colorKey: g.key)
                })
            }
            return .group(id: "env/\(env)", name: environments.name(of: env), colorKey: "env:\(env)", children: groupNodes)
        }
        // Keep the configured order rather than sorting by cost: Production first reads better.
        var root = CostNode.group(id: "env", name: "All environments", children: envNodes)
        root.children = envNodes
        return CostView(id: CostView.environment, title: "Environment", symbol: "square.stack.3d.up", root: root)
    }

    private func serviceView(lines: [CostLine], allocations: [[Share]]) -> CostView {
        let indexed = Array(zip(lines, allocations).enumerated())
        let groupNodes: [CostNode] = Self.groups.compactMap { g in
            let inGroup = indexed.filter { Self.group(ofCategory: $0.element.0.category) == g.key }
            guard !inGroup.isEmpty else { return nil }

            func products(_ items: [(offset: Int, element: (CostLine, [Share]))], prefix: String) -> [CostNode] {
                Dictionary(grouping: items, by: { $0.element.0.product }).map { product, entries in
                    let leaves = entries.map { e -> CostNode in
                        let (line, shares) = e.element
                        let orphan = !shares.isEmpty && shares.allSatisfy { $0.flag == .orphan }
                        return CostNode(id: "svc/\(line.id)", name: line.resource.isEmpty ? line.product : line.resource,
                                        subtitle: line.quantity, cost: line.amount, detail: line.sku,
                                        flag: orphan ? .orphan : shares.first?.flag, skus: [line.sku], colorKey: g.key)
                    }
                    if leaves.count == 1 {
                        var only = leaves[0]
                        only.subtitle = only.name
                        only.name = product
                        return only
                    }
                    return .group(id: "\(prefix)/\(product)", name: product, colorKey: g.key, children: leaves)
                }
            }

            if g.key == "other" {
                let categories = Dictionary(grouping: inGroup, by: { $0.element.0.category }).map { category, items in
                    CostNode.group(id: "svc/other/\(category)", name: category, colorKey: g.key,
                                   children: products(items, prefix: "svc/other/\(category)"))
                }
                return .group(id: "svc/other", name: g.label, colorKey: g.key, children: categories)
            }
            return .group(id: "svc/\(g.key)", name: g.label, colorKey: g.key, children: products(inGroup, prefix: "svc/\(g.key)"))
        }
        return CostView(id: CostView.service, title: "Service", symbol: "square.grid.2x2",
                        root: .group(id: "svc", name: "All services", children: groupNodes))
    }

    private func projectView(lines: [CostLine]) -> CostView {
        let projects = Dictionary(grouping: lines.enumerated(), by: { $0.element.project ?? "No project" }).map { project, items in
            let groups = Dictionary(grouping: items, by: { Self.group(ofCategory: $0.element.category) }).map { key, items in
                CostNode.group(id: "prj/\(project)/\(key)", name: Self.groupLabel(key), colorKey: key, children: items.map { e in
                    CostNode(id: "prj/\(project)/\(e.element.id)", name: e.element.resource.isEmpty ? e.element.product : e.element.resource,
                             subtitle: e.element.product, cost: e.element.amount, detail: e.element.sku, skus: [e.element.sku], colorKey: key)
                })
            }
            return CostNode.group(id: "prj/\(project)", name: project, colorKey: "project:\(project)", children: groups)
        }
        return CostView(id: CostView.project, title: "Project", symbol: "folder",
                        root: .group(id: "prj", name: "All projects", children: projects))
    }

    // MARK: - Findings

    private func findings(envView: CostView) -> [Finding] {
        // (env id, leaf) pairs of the environment view.
        let leaves: [(env: String, node: CostNode)] = envView.root.children.flatMap { envNode in
            envNode.leaves.map { (String(envNode.id.dropFirst("env/".count)), $0) }
        }
        let nonProd = environments.nonProduction
        func total(_ items: [(env: String, node: CostNode)]) -> Double { items.reduce(0) { $0 + $1.node.cost } }
        func matching(envs: Set<String>? = nil, skuPrefixes: [String]) -> [(env: String, node: CostNode)] {
            leaves.filter { leaf in
                (envs?.contains(leaf.env) ?? true) && leaf.node.skus.contains { sku in skuPrefixes.contains { sku.hasPrefix($0) } }
            }
        }
        func finding(_ kind: Finding.Kind, _ title: String, _ note: String, _ items: [(env: String, node: CostNode)], amount: Double? = nil) -> Finding {
            Finding(kind: kind, title: title, note: note, amount: amount ?? total(items), viewID: CostView.environment, nodeIDs: items.map(\.node.id))
        }
        var out: [Finding] = []

        let orphans = leaves.filter { $0.env == EnvironmentClassifier.orphan }
        if !orphans.isEmpty {
            out.append(finding(.reclaim, "\(orphans.count) unattached resource\(orphans.count == 1 ? "" : "s")",
                               orphans.map(\.node.name).joined(separator: "; ") + ". Check none is still needed (reserved IP, volume to keep) before deleting.",
                               orphans))
        }

        let nodes = matching(envs: nonProd, skuPrefixes: ["/instance/server/", "/compute/", "/instance/volume/"])
        if total(nodes) > 0 {
            let pools = inventory.pools.filter { nonProd.contains(envOfCluster[$0["cluster_id"].string ?? ""] ?? "") }
            let atMax = pools.filter { ($0["size"].double ?? 0) >= ($0["max_size"].double ?? .infinity) }.compactMap(\.["name"].string)
            let count = pools.reduce(0) { $0 + ($1["size"].int ?? 0) }
            out.append(finding(.review, "Non-production compute running 24/7",
                               "\(count) non-production Kubernetes node\(count == 1 ? "" : "s")." + (atMax.isEmpty ? "" : " Pools at their maximum: \(atMax.joined(separator: ", ")).")
                               + " Scaling to zero outside working hours saves about two thirds.", nodes))
        }

        let redis = matching(envs: nonProd, skuPrefixes: ["/storage/redis/"])
        if total(redis) > 0 {
            let postgres = total(matching(envs: nonProd, skuPrefixes: ["/storage/rdb/"]))
            out.append(finding(.review, "Managed Redis outside production",
                               "Compared with \(postgres.formatted(.number.precision(.fractionLength(2)))) for non-production databases. An in-cluster Redis is usually enough for development.", redis))
        }

        let edge = matching(skuPrefixes: ["/network/edge-services/"])
        if total(edge) > 0 {
            let pipelines = inventory.edgePipelines
            let degraded = pipelines.filter { $0["status"].string != "ready" }.compactMap(\.["name"].string)
            out.append(finding(.review, "Edge Services plan",
                               "\(pipelines.count) pipeline\(pipelines.count == 1 ? "" : "s")" + (degraded.isEmpty ? "" : ", \(degraded.count) not ready (\(degraded.joined(separator: ", ")))")
                               + ". The plan is billed in full even if a single pipeline uses it.", edge))
        }

        let mac = matching(skuPrefixes: ["/apple-silicon/"])
        if total(mac) > 0 {
            out.append(finding(.review, "Apple silicon servers",
                               "Fixed monthly cost. Compare with hosted macOS CI minutes for your build volume.", mac))
        }

        let zones = rootDNSZones
        if zones.count > 1 {
            out.append(finding(.review, "\(zones.count) paid DNS zones",
                               "\(zones.joined(separator: ", ")). A domain that only redirects does not need its own zone.",
                               matching(skuPrefixes: ["/network/domain/dns/external-zone/"])))
        }

        for db in inventory.databases {
            let n = snapshotCount(db)
            guard n > 20, let name = db["name"].string else { continue }
            out.append(finding(.review, "\(n) snapshots of \(name)", "Shorten retention or purge old snapshots.",
                               leaves.filter { $0.node.name.hasPrefix("\(name) · snapshots") }))
        }

        let unassigned = leaves.filter { $0.env == EnvironmentClassifier.unassigned }
        if !unassigned.isEmpty {
            out.append(finding(.info, "Costs without an allocation rule",
                               "\(unassigned.count) line\(unassigned.count == 1 ? "" : "s") could not be matched to a resource. They are still counted in every total.", unassigned))
        }
        return out.sorted { $0.amount > $1.amount }
    }
}

extension String {
    /// Capture groups of the first match of `pattern`, or nil.
    func captures(_ pattern: String) -> [String]? {
        guard let regex = try? NSRegularExpression(pattern: pattern),
              let m = regex.firstMatch(in: self, range: NSRange(startIndex..., in: self)) else { return nil }
        return (1..<m.numberOfRanges).map { i in Range(m.range(at: i), in: self).map { String(self[$0]) } ?? "" }
    }

    var nilIfEmpty: String? { isEmpty ? nil : self }
}
