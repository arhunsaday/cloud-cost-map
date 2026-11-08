import Foundation

/// Turns Cost Explorer results into a `CostReport`. Pure: no network, so it is
/// tested against recorded fixtures.
///
/// Environments come from the configured cost allocation tag when there is
/// one, and otherwise from linked account names (`acme-prod`, `acme-staging`),
/// the usual multi-account layout. Untagged costs fall back to the account
/// name too.
public struct AWSCostAttribution: Sendable {
    public let environments: EnvironmentClassifier

    public init(environments: EnvironmentClassifier) {
        self.environments = environments
    }

    // MARK: - Services

    struct Group {
        let key: String
        let label: String
    }

    /// Same keys as the other providers, so colours match across accounts.
    static let groups: [Group] = [
        Group(key: "compute", label: "Compute"),
        Group(key: "db", label: "Databases"),
        Group(key: "network", label: "Network"),
        Group(key: "storage", label: "Storage"),
        Group(key: "other", label: "Other Services"),
    ]

    static func groupLabel(_ key: String) -> String {
        groups.first { $0.key == key }?.label ?? key
    }

    static func group(ofService service: String) -> String {
        let s = service.lowercased()
        func has(_ words: [String]) -> Bool { words.contains { s.contains($0) } }
        if has(["container registry"]) { return "other" }
        if has(["relational database", "dynamodb", "elasticache", "redshift", "documentdb", "neptune", "opensearch",
                "elasticsearch", "memorydb", "keyspaces", "timestream", "aurora", "database"]) { return "db" }
        if has(["cloudfront", "route 53", "load balancing", "virtual private cloud", "vpc", "direct connect", "global accelerator",
                "api gateway", "data transfer", "transit gateway", "network firewall", "privatelink", "nat gateway"]) { return "network" }
        if has(["simple storage service", "elastic file system", "glacier", "backup", "fsx", "storage gateway",
                "elastic block store"]) { return "storage" }
        if has(["elastic compute cloud", "ec2", "lambda", "fargate", "lightsail", "batch", "app runner", "beanstalk", "kubernetes",
                "elastic container service", "sagemaker", "workspaces", "elastic mapreduce", "emr"]) { return "compute" }
        return "other"
    }

    private static let shortNames: [String: String] = [
        "Amazon Elastic Compute Cloud - Compute": "EC2 instances",
        "EC2 - Other": "EC2 other (EBS, NAT, IPs)",
        "Amazon Relational Database Service": "RDS",
        "Amazon Simple Storage Service": "S3",
        "Amazon Elastic Container Service for Kubernetes": "EKS",
        "Amazon Elastic Kubernetes Service": "EKS",
        "Amazon Elastic Container Service": "ECS",
        "Amazon EC2 Container Registry (ECR)": "ECR",
        "Amazon Elastic File System": "EFS",
        "Amazon Elastic Block Store": "EBS",
        "Amazon Virtual Private Cloud": "VPC",
        "AmazonCloudWatch": "CloudWatch",
        "Amazon Simple Queue Service": "SQS",
        "Amazon Simple Notification Service": "SNS",
        "Amazon Simple Email Service": "SES",
        "AWS Key Management Service": "KMS",
        "Amazon OpenSearch Service": "OpenSearch",
    ]

    /// "Amazon Relational Database Service" → "RDS"; otherwise drops the vendor prefix.
    static func shortName(_ service: String) -> String {
        if let short = shortNames[service] { return short }
        for prefix in ["Amazon ", "AWS "] where service.hasPrefix(prefix) { return String(service.dropFirst(prefix.count)) }
        return service.isEmpty ? "Unknown service" : service
    }

    static func regionName(_ region: String) -> String {
        region.isEmpty || region == "NoRegion" || region == "global" ? "Global" : region
    }

    /// `Environment$prod` → `prod`; `Environment$` (untagged) → "".
    static func tagValue(_ key: String) -> String {
        key.firstIndex(of: "$").map { String(key[key.index(after: $0)...]) } ?? key
    }

    // MARK: - Report

    public func report(accountID: UUID, period: BillingPeriod, data: AWSCostData, generatedAt: Date = .now) -> CostReport {
        let names = data.accountNames
        func accountName(_ id: String) -> String { names[id] ?? id }
        let byAccount = (data[.serviceAccount]?.groups(period) ?? []).filter(\.isCost)
        let byUsage = (data[.serviceUsage]?.groups(period) ?? []).filter(\.isCost)

        let gross = byAccount.reduce(0) { $0 + $1.amount }
        let billed = data[.total]?.totals[period.code] ?? gross
        let currency = data.results.values.lazy.compactMap(\.currency).first ?? "USD"

        let lines = byUsage.map { g in
            let service = g.keys.first ?? "", usage = g.keys.dropFirst().first ?? ""
            return CostLine(category: Self.groupLabel(Self.group(ofService: service)), product: service, resource: usage,
                            sku: "\(service)/\(usage)", amount: g.amount)
        }

        var warnings: [String] = []
        let envView = environmentView(period: period, data: data, accountName: accountName, warnings: &warnings)
        let serviceView = serviceView(byUsage)
        var views = [envView, serviceView]
        if Set(byAccount.compactMap { $0.keys.dropFirst().first }).count > 1 {
            views.append(accountView(byAccount, accountName: accountName))
        }
        views.append(regionView((data[.regionService]?.groups(period) ?? []).filter(\.isCost)))

        return CostReport(accountID: accountID, period: period, currency: currency, generatedAt: generatedAt,
                          billed: billed, gross: gross, credits: billed - gross, lines: lines, views: views,
                          findings: findings(envView: envView, serviceView: serviceView, gross: gross, tagKey: data.tagKey),
                          warnings: warnings)
    }

    private struct Leaf {
        var env: String
        var service: String
        var label: String
        var detail: String
        var amount: Double
    }

    private func environmentView(period: BillingPeriod, data: AWSCostData, accountName: (String) -> String,
                                 warnings: inout [String]) -> CostView {
        var leaves: [Leaf] = []
        let accounts = Set((data[.serviceAccount]?.groups(period) ?? []).compactMap { $0.keys.dropFirst().first })
        func label(_ service: String, account: String) -> String {
            accounts.count > 1 ? "\(Self.shortName(service)) · \(accountName(account))" : Self.shortName(service)
        }

        if let tagKey = data.tagKey, let tagged = data[.tagService], let untagged = data[.untaggedServiceAccount] {
            var taggedTotal = 0.0
            for g in tagged.groups(period).filter(\.isCost) {
                let value = Self.tagValue(g.keys.first ?? ""), service = g.keys.dropFirst().first ?? ""
                guard !value.isEmpty else { continue } // counted per account below
                taggedTotal += g.amount
                let env = environments.classify(value)
                leaves.append(Leaf(env: env ?? EnvironmentClassifier.shared, service: service,
                                   label: env == nil ? "\(Self.shortName(service)) · \(value)" : Self.shortName(service),
                                   detail: "\(service), tag \(tagKey)=\(value)", amount: g.amount))
            }
            for g in untagged.groups(period).filter(\.isCost) {
                let service = g.keys.first ?? "", account = g.keys.dropFirst().first ?? ""
                let env = environments.classify(accountName(account))
                leaves.append(Leaf(env: env ?? EnvironmentClassifier.unassigned, service: service, label: label(service, account: account),
                                   detail: "\(service), no \(tagKey) tag" + (env == nil ? "" : "; environment from the account name"),
                                   amount: g.amount))
            }
            if taggedTotal == 0 {
                warnings.append("No cost carries the tag “\(tagKey)”. Activate it under Billing → Cost allocation tags; it applies from activation onwards.")
            }
        } else {
            for g in (data[.serviceAccount]?.groups(period) ?? []).filter(\.isCost) {
                let service = g.keys.first ?? "", account = g.keys.dropFirst().first ?? ""
                let name = accountName(account)
                let env = environments.classify(name)
                leaves.append(Leaf(env: env ?? EnvironmentClassifier.shared, service: service, label: label(service, account: account),
                                   detail: "\(service), account \(name)" + (name == account ? "" : " (\(account))"), amount: g.amount))
            }
        }

        // env → group → label
        var buckets: [String: [String: [String: (amount: Double, detail: String, services: Set<String>)]]] = [:]
        for leaf in leaves {
            let group = Self.group(ofService: leaf.service)
            var b = buckets[leaf.env, default: [:]][group, default: [:]][leaf.label, default: (0, leaf.detail, [])]
            b.amount += leaf.amount
            b.services.insert(leaf.service)
            buckets[leaf.env, default: [:]][group, default: [:]][leaf.label] = b
        }
        let envNodes: [CostNode] = environments.order.compactMap { env in
            guard let groups = buckets[env] else { return nil }
            let groupNodes = Self.groups.compactMap { g -> CostNode? in
                guard let items = groups[g.key] else { return nil }
                return .group(id: "env/\(env)/\(g.key)", name: g.label, colorKey: g.key, children: items.map { label, b in
                    CostNode(id: "env/\(env)/\(g.key)/\(label)", name: label, subtitle: b.services.sorted().joined(separator: ", "),
                             cost: b.amount, detail: b.detail, skus: b.services.sorted(), colorKey: g.key)
                })
            }
            return .group(id: "env/\(env)", name: environments.name(of: env), colorKey: "env:\(env)", children: groupNodes)
        }
        // Configured order rather than by cost: Production first reads better.
        var root = CostNode.group(id: "env", name: "All environments", children: envNodes)
        root.children = envNodes
        return CostView(id: CostView.environment, title: "Environment", symbol: "square.stack.3d.up", root: root)
    }

    /// Service group → service → usage type.
    private func serviceView(_ groups: [AWSCostData.Result.Group]) -> CostView {
        let byGroup = Dictionary(grouping: groups, by: { Self.group(ofService: $0.keys.first ?? "") })
        let groupNodes: [CostNode] = Self.groups.compactMap { g in
            guard let items = byGroup[g.key] else { return nil }
            let services = Dictionary(grouping: items, by: { $0.keys.first ?? "" }).map { service, entries -> CostNode in
                let leaves = entries.map { e -> CostNode in
                    let usage = e.keys.dropFirst().first ?? ""
                    return CostNode(id: "svc/\(service)/\(usage)", name: usage.isEmpty ? Self.shortName(service) : usage,
                                    subtitle: Self.shortName(service), cost: e.amount, detail: "\(service), usage type \(usage)",
                                    flag: usage.contains("IdleAddress") ? .orphan : nil, skus: [usage], colorKey: g.key)
                }
                if leaves.count == 1 {
                    var only = leaves[0]
                    only.subtitle = only.name
                    only.name = Self.shortName(service)
                    return only
                }
                return .group(id: "svc/\(g.key)/\(service)", name: Self.shortName(service), subtitle: service, colorKey: g.key, children: leaves)
            }
            return .group(id: "svc/\(g.key)", name: g.label, colorKey: g.key, children: services)
        }
        return CostView(id: CostView.service, title: "Service", symbol: "square.grid.2x2",
                        root: .group(id: "svc", name: "All services", children: groupNodes))
    }

    /// Two-level tree `outer → service group → service`, for the account and region views.
    private func tree(_ groups: [AWSCostData.Result.Group], prefix: String, outer: (AWSCostData.Result.Group) -> String,
                      service: (AWSCostData.Result.Group) -> String, name: (String) -> String, colorKey: (String) -> String) -> CostNode {
        let byOuter = Dictionary(grouping: groups, by: outer).map { key, items in
            let byGroup = Dictionary(grouping: items, by: { Self.group(ofService: service($0)) }).map { g, entries in
                CostNode.group(id: "\(prefix)/\(key)/\(g)", name: Self.groupLabel(g), colorKey: g,
                               children: Dictionary(grouping: entries, by: service).map { s, e in
                                   CostNode(id: "\(prefix)/\(key)/\(g)/\(s)", name: Self.shortName(s), subtitle: s,
                                            cost: e.reduce(0) { $0 + $1.amount }, detail: s, skus: [s], colorKey: g)
                               })
            }
            return CostNode.group(id: "\(prefix)/\(key)", name: name(key), colorKey: colorKey(key), children: byGroup)
        }
        return .group(id: prefix, name: "", children: byOuter)
    }

    private func accountView(_ groups: [AWSCostData.Result.Group], accountName: @escaping (String) -> String) -> CostView {
        var root = tree(groups, prefix: "acct", outer: { $0.keys.dropFirst().first ?? "" }, service: { $0.keys.first ?? "" },
                        name: accountName, colorKey: { "account:\($0)" })
        root.name = "All accounts"
        return CostView(id: CostView.account, title: "Account", symbol: "person.2", root: root)
    }

    private func regionView(_ groups: [AWSCostData.Result.Group]) -> CostView {
        var root = tree(groups, prefix: "rgn", outer: { Self.regionName($0.keys.first ?? "") }, service: { $0.keys.dropFirst().first ?? "" },
                        name: { $0 }, colorKey: { "region:\($0)" })
        root.name = "All regions"
        return CostView(id: CostView.region, title: "Region", symbol: "globe", root: root)
    }

    // MARK: - Findings

    private func findings(envView: CostView, serviceView: CostView, gross: Double, tagKey: String?) -> [Finding] {
        let envLeaves: [(env: String, node: CostNode)] = envView.root.children.flatMap { envNode in
            envNode.leaves.map { (String(envNode.id.dropFirst("env/".count)), $0) }
        }
        let usageLeaves = serviceView.root.leaves
        func total(_ nodes: [CostNode]) -> Double { nodes.reduce(0) { $0 + $1.cost } }
        func usage(_ needles: [String]) -> [CostNode] {
            usageLeaves.filter { node in node.skus.contains { sku in needles.contains { sku.contains($0) } } }
        }
        func share(_ amount: Double) -> Double { gross > 0 ? amount / gross : 0 }
        func percent(_ amount: Double) -> String { share(amount).formatted(.percent.precision(.fractionLength(0))) }
        func onService(_ kind: Finding.Kind, _ title: String, _ note: String, _ nodes: [CostNode]) -> Finding {
            Finding(kind: kind, title: title, note: note, amount: total(nodes), viewID: CostView.service, nodeIDs: nodes.map(\.id))
        }
        var out: [Finding] = []

        let idle = usage(["IdleAddress"])
        if total(idle) > 0 {
            out.append(onService(.reclaim, "Idle public IPv4 addresses",
                                 "Elastic IPs not attached to a running instance are billed by the hour. Release the ones nobody needs.", idle))
        }

        let gp2 = usage(["VolumeUsage.gp2"])
        if total(gp2) > 0 {
            out.append(onService(.review, "gp2 volumes",
                                 "gp3 costs about 20 % less for the same size and starts at 3,000 IOPS. Volumes convert in place without downtime.", gp2))
        }

        let nat = usage(["NatGateway"])
        if total(nat) > 0, share(total(nat)) >= 0.01 {
            out.append(onService(.review, "NAT Gateways (\(percent(total(nat))) of the bill)",
                                 "Billed per hour and per GB processed. Free gateway endpoints for S3 and DynamoDB take that traffic off the NAT; non-production VPCs can share one gateway.", nat))
        }

        let egress = usage(["DataTransfer-Out", "AWS-Out-Bytes"])
        if share(total(egress)) >= 0.05 {
            out.append(onService(.review, "Data transfer out (\(percent(total(egress))) of the bill)",
                                 "Internet and inter-region traffic. A CDN in front of S3 or EC2, compression, or keeping chatty services in one region usually lowers it.", egress))
        }

        let snapshots = usage(["SnapshotUsage"])
        if share(total(snapshots)) >= 0.03 {
            out.append(onService(.review, "EBS snapshots (\(percent(total(snapshots))) of the bill)",
                                 "Snapshots pile up silently. Data Lifecycle Manager or AWS Backup retention rules keep only what is needed.", snapshots))
        }

        let nonProd = environments.nonProduction
        let compute = envLeaves.filter { nonProd.contains($0.env) && $0.node.colorKey == "compute" }.map(\.node)
        if total(compute) > 0 {
            out.append(Finding(kind: .review, title: "Non-production compute",
                               note: "Stopping development and staging instances, node groups and tasks outside working hours (Instance Scheduler, scaling to zero) saves about two thirds.",
                               amount: total(compute), viewID: CostView.environment, nodeIDs: compute.map(\.id)))
        }

        let untagged = envLeaves.filter { $0.env == EnvironmentClassifier.unassigned }.map(\.node)
        if let tagKey, total(untagged) > 0 {
            out.append(Finding(kind: .info, title: "Costs without a \(tagKey) tag",
                               note: "\(percent(total(untagged))) of the month could not be placed in an environment. Tag those resources, or name accounts after their environment. Some charges (tax, support, data transfer) cannot be tagged.",
                               amount: total(untagged), viewID: CostView.environment, nodeIDs: untagged.map(\.id)))
        }
        return out.sorted { $0.amount > $1.amount }
    }
}

extension AWSCostData.Result.Group {
    /// Whether the group belongs in a breakdown. Negative groups (a Savings
    /// Plan negation alone, say) are left to the credits line.
    var isCost: Bool { amount >= 0.005 }
}
