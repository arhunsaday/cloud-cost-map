import Foundation

/// A fictional company's cloud bill, deterministic for a given account and month,
/// so the app can be explored and screenshotted without any credentials.
public struct DemoProvider: CloudProvider {
    public let account: Account

    public init(account: Account) {
        self.account = account
    }

    public func validate() async throws {}

    public func fetchReports(for periods: [BillingPeriod], progress: @escaping @Sendable (String) -> Void) async throws -> [CostReport] {
        progress("Generating demo data…")
        try await Task.sleep(for: .milliseconds(350))
        return periods.map(report(for:))
    }

    // (environment, service group, product, resource, monthly base cost, region, flag)
    private typealias Item = (env: String, group: String, product: String, resource: String, base: Double, region: String, flag: CostFlag?)

    private static let items: [Item] = [
        ("prod", "compute", "Kubernetes nodes", "pool-general · 6 × PRO2-M", 1240, "fr-par", nil),
        ("prod", "compute", "Kubernetes nodes", "pool-workers · 3 × POP2-HC-8C", 610, "fr-par", nil),
        ("prod", "compute", "Instances", "bastion-prod", 18, "fr-par", nil),
        ("prod", "db", "PostgreSQL", "pg-prod · DB-PRO2-S HA", 486, "fr-par", nil),
        ("prod", "db", "PostgreSQL", "pg-prod · volume 200 GB", 52, "fr-par", nil),
        ("prod", "db", "Redis", "redis-prod · RED1-M", 145, "fr-par", nil),
        ("prod", "network", "Load balancers", "lb-prod (LB-GP-M)", 64, "fr-par", nil),
        ("prod", "network", "Edge Services", "cdn-prod", 95, "fr-par", nil),
        ("prod", "storage", "Block volumes", "PVC production (14 vol., 820 GB)", 71, "fr-par", nil),
        ("prod", "other", "Object Storage", "assets-prod", 38, "fr-par", nil),
        ("prod", "other", "Observability", "Cockpit logs & metrics", 54, "fr-par", nil),
        ("staging", "compute", "Kubernetes nodes", "pool-general · 3 × PRO2-S", 310, "nl-ams", nil),
        ("staging", "db", "PostgreSQL", "pg-staging · DB-DEV-M", 64, "nl-ams", nil),
        ("staging", "db", "Redis", "redis-staging · RED1-S", 72, "nl-ams", nil),
        ("staging", "network", "Load balancers", "lb-staging (LB-S)", 12, "nl-ams", nil),
        ("staging", "storage", "Block volumes", "PVC staging (6 vol., 240 GB)", 21, "nl-ams", nil),
        ("dev", "compute", "Kubernetes nodes", "pool-dev · 2 × DEV1-L", 96, "fr-par", nil),
        ("dev", "compute", "Instances", "gpu-experiments · L4-1-24G", 410, "fr-par", nil),
        ("dev", "db", "PostgreSQL", "pg-dev · DB-DEV-S", 18, "fr-par", nil),
        ("dev", "storage", "Block volumes", "PVC development (4 vol., 120 GB)", 11, "fr-par", nil),
        ("shared", "network", "DNS", "3 external zones", 9, "global", nil),
        ("shared", "other", "Container Registry", "registry · 180 GB", 27, "fr-par", nil),
        ("shared", "other", "Secret Manager", "142 secrets", 6, "fr-par", nil),
        ("shared", "baremetal", "Apple silicon", "mac-runner · M2-L", 112, "fr-par", nil),
        ("orphan", "network", "Flexible IPs", "IPv4 51.15.x.x, detached", 3.5, "fr-par", .orphan),
        ("orphan", "storage", "Block volumes", "Detached volume old-data (500 GB)", 43, "fr-par", .orphan),
    ]

    private func report(for period: BillingPeriod) -> CostReport {
        // `hashValue` is salted per launch, so derive the seed from the UUID text instead.
        let accountSeed = account.id.uuidString.utf8.reduce(UInt64(5381)) { ($0 &* 33) ^ UInt64($1) }
        var rng = SeededGenerator(seed: accountSeed ^ UInt64(period.year * 100 + period.month))
        // Steady growth of about 3 % a month, so trends have something to show.
        let monthsAgo = Double((BillingPeriod.current().year - period.year) * 12 + BillingPeriod.current().month - period.month)
        let growth = pow(1.03, -monthsAgo)
        let elapsed = period.elapsedFraction()

        let classifier = EnvironmentClassifier.default
        var lines: [CostLine] = []
        var leaves: [(Item, CostNode)] = []
        for (i, item) in Self.items.enumerated() {
            // The GPU box only appeared three months ago: a spike worth spotting.
            if item.resource.hasPrefix("gpu"), monthsAgo > 2 { continue }
            let jitter = 0.9 + Double(rng.next() % 200) / 1000
            let cost = (item.base * growth * jitter * elapsed * 100).rounded() / 100
            guard cost > 0 else { continue }
            let sku = "/demo/\(item.group)/\(item.product.lowercased().replacingOccurrences(of: " ", with: "-"))/\(item.region)"
            lines.append(CostLine(category: ScalewayAttribution.groupLabel(item.group), product: item.product, resource: item.resource,
                                  sku: sku, amount: cost, project: item.env == "shared" ? "platform" : "app-\(item.env)", region: item.region))
            leaves.append((item, CostNode(id: "\(i)", name: item.resource, subtitle: item.product, cost: cost,
                                          detail: sku, flag: item.flag, skus: [sku], colorKey: item.group)))
        }

        func tree(prefix: String, rootName: String, key: (Item) -> String, name: (String) -> String, color: (String) -> String,
                  order: [String]? = nil) -> CostNode {
            let grouped = Dictionary(grouping: leaves, by: { key($0.0) })
            let keys = order?.filter { grouped[$0] != nil } ?? grouped.keys.sorted()
            let children = keys.map { k in
                let inner = Dictionary(grouping: grouped[k]!, by: { $0.0.group }).map { g, entries in
                    CostNode.group(id: "\(prefix)/\(k)/\(g)", name: ScalewayAttribution.groupLabel(g), colorKey: g,
                                   children: entries.map { var n = $0.1; n.id = "\(prefix)/\(k)/\(g)/\(n.id)"; return n })
                }
                return CostNode.group(id: "\(prefix)/\(k)", name: name(k), colorKey: color(k), children: inner)
            }
            var root = CostNode.group(id: prefix, name: rootName, children: children)
            if order != nil { root.children = children }
            return root
        }

        let env = tree(prefix: "env", rootName: "All environments", key: \.env, name: classifier.name(of:), color: { "env:\($0)" },
                       order: classifier.order)
        let service = CostNode.group(id: "svc", name: "All services", children: Dictionary(grouping: leaves, by: { $0.0.group }).map { g, entries in
            CostNode.group(id: "svc/\(g)", name: ScalewayAttribution.groupLabel(g), colorKey: g,
                           children: Dictionary(grouping: entries, by: { $0.0.product }).map { product, entries in
                               CostNode.group(id: "svc/\(g)/\(product)", name: product, colorKey: g,
                                              children: entries.map { var n = $0.1; n.id = "svc/\(g)/\(product)/\(n.id)"; n.subtitle = classifier.name(of: $0.0.env); return n })
                           })
        })
        let region = tree(prefix: "rgn", rootName: "All regions", key: \.region, name: { $0 == "global" ? "Global" : $0 }, color: { "region:\($0)" })

        let gross = lines.reduce(0) { $0 + $1.amount }
        let credits = -(gross * 0.04 * 100).rounded() / 100
        let orphanIDs = env.children.first { $0.id == "env/orphan" }?.leaves.map(\.id) ?? []
        let gpu = env.find("env/dev/compute")?.leaves.filter { $0.name.hasPrefix("gpu") } ?? []
        var findings = [
            Finding(kind: .reclaim, title: "\(orphanIDs.count) unattached resources", note: "A detached IPv4 and a 500 GB volume nobody mounts.",
                    amount: env.find("env/orphan")?.cost ?? 0, viewID: CostView.environment, nodeIDs: orphanIDs),
            Finding(kind: .review, title: "Managed Redis outside production", note: "An in-cluster Redis is usually enough for staging.",
                    amount: env.find("env/staging/db")?.leaves.filter { $0.name.hasPrefix("redis") }.reduce(0) { $0 + $1.cost } ?? 0,
                    viewID: CostView.environment, nodeIDs: env.find("env/staging/db")?.leaves.filter { $0.name.hasPrefix("redis") }.map(\.id) ?? []),
        ]
        if let g = gpu.first {
            findings.insert(Finding(kind: .review, title: "GPU instance in development", note: "New this quarter and running around the clock.",
                                    amount: g.cost, viewID: CostView.environment, nodeIDs: [g.id]), at: 0)
        }

        return CostReport(accountID: account.id, period: period, currency: "EUR", billed: gross + credits, gross: gross, credits: credits,
                          lines: lines,
                          views: [
                              CostView(id: CostView.environment, title: "Environment", symbol: "square.stack.3d.up", root: env),
                              CostView(id: CostView.service, title: "Service", symbol: "square.grid.2x2", root: service),
                              CostView(id: CostView.region, title: "Region", symbol: "globe.europe.africa", root: region),
                          ],
                          findings: findings.sorted { $0.amount > $1.amount })
    }
}

/// SplitMix64: tiny, fast and reproducible across launches (unlike `SystemRandomNumberGenerator`).
struct SeededGenerator: RandomNumberGenerator {
    private var state: UInt64
    init(seed: UInt64) { state = seed }
    mutating func next() -> UInt64 {
        state &+= 0x9E37_79B9_7F4A_7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        return z ^ (z >> 31)
    }
}
