import Foundation
import Testing
@testable import CloudCostCore

@Suite struct ScalewayAttributionTests {
    let fixtures = Bundle.module.url(forResource: "Fixtures/scaleway", withExtension: nil)!

    func makeReport() throws -> CostReport {
        let inventory = ScalewayInventory(directory: fixtures)
        let consumptions = try JSONValue.parse(Data(contentsOf: fixtures.appending(path: "consumptions.json"))).array
        return ScalewayAttribution(inventory: inventory, environments: .default)
            .report(accountID: UUID(), period: BillingPeriod(year: 2026, month: 9), consumptions: consumptions)
    }

    @Test func totalsMatchInvoice() throws {
        let report = try makeReport()
        #expect(abs(report.billed - 135.5) < 0.001)
        #expect(abs(report.gross - 145.5) < 0.001)
        #expect(report.credits == -10)
        #expect(report.currency == "EUR")
        // Every view redistributes the same money.
        for view in report.views {
            #expect(abs(view.root.cost - report.gross) < 0.01, "\(view.id) sums to \(view.root.cost)")
        }
    }

    @Test func instancesSplitAcrossMatchingZoneOnly() throws {
        let env = try #require(try makeReport().view(CostView.environment)).root
        // Two DEV1-S in fr-par-1 share 100 €; the one in fr-par-2 gets nothing.
        #expect(env.find("env/dev/compute")?.cost == 50)
        #expect(env.find("env/prod/compute")?.cost == 50)
        #expect(env.leaves.contains { $0.name.contains("bastion") } == false)
    }

    @Test func detachedResourcesAreOrphans() throws {
        let report = try makeReport()
        let orphan = try #require(report.view(CostView.environment)?.root.find("env/orphan"))
        // 1/3 of block storage (10 of 30 GB) and one of two IPs.
        #expect(abs(orphan.cost - (30.5 / 3 + 1.5)) < 0.001)
        #expect(orphan.leaves.allSatisfy { $0.flag == .orphan })
        #expect(report.findings.first { $0.kind == .reclaim }?.nodeIDs.count == 2)
    }

    @Test func unknownSKUsAreUnallocatedButCounted() throws {
        let report = try makeReport()
        #expect(report.view(CostView.environment)?.root.find("env/unassigned")?.cost == 12)
        #expect(report.warnings.contains { $0.contains("/quantum/qpu/fr-par") })
    }

    @Test func zoneKeys() {
        #expect(ScalewayAttribution.zoneKey("fr-par-1") == "par1")
        #expect(ScalewayAttribution.zoneKey("run_fr-par-2") == "par2")
        #expect(ScalewayAttribution.zoneKey("/storage/block/sbs/nl-ams-3") == "ams3")
        #expect(ScalewayAttribution.zoneKey("/k8s/control-plane") == nil)
    }
}

@Suite struct EnvironmentClassifierTests {
    let c = EnvironmentClassifier.default

    @Test(arguments: [
        ("api-dev-1", "dev"), ("k8s-staging", "staging"), ("pg-prod", "prod"), ("my_demo_db", "demo"),
        ("devops-tools", nil), ("production-replica-dev", "dev"), ("", nil),
    ] as [(String, String?)])
    func classify(name: String, expected: String?) {
        #expect(c.classify(name) == expected)
    }
}

@Suite struct ScalewayCLIConfigTests {
    @Test func parsesProfiles() {
        let config = ScalewayCLIConfig.parse("""
        # comment
        access_key: SCWTOP
        secret_key: top-secret
        default_organization_id: org-top
        active_profile: work
        profiles:
          work:
            access_key: SCWWORK
            secret_key: work-secret # trailing comment
            default_organization_id: org-work
            # api_url: https://example.com
          empty:
            default_region: fr-par
        """)
        #expect(config.activeProfile == "work")
        #expect(config.profiles.map(\.name) == ["default", "work", "empty"])
        #expect(config.profile(named: "work")?.secretKey == "work-secret")
        #expect(config.profile(named: "work")?.apiURL == nil)
        #expect(config.profile(named: "empty")?.isUsable == false)
    }
}
