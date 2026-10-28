import Foundation
import Testing
@testable import CloudCostCore

/// Hits the real Scaleway API with a CLI profile. Skipped unless enabled:
///   SCW_LIVE_PROFILE=my-profile swift test --filter LiveScaleway
/// Read-only: billing and inventory list calls.
@Suite(.enabled(if: ProcessInfo.processInfo.environment["SCW_LIVE_PROFILE"] != nil))
struct LiveScalewayTests {
    @Test func fetchesAndAllocatesRealBilling() async throws {
        let profile = ProcessInfo.processInfo.environment["SCW_LIVE_PROFILE"]!
        let account = Account(name: profile, provider: .scaleway, credentialSource: .scalewayProfile(profile))
        let provider = try ProviderFactory.make(for: account, credentials: NoCredentials(), options: FetchOptions())
        try await provider.validate()

        let periods = BillingPeriod.recent(2)
        let reports = try await provider.fetchReports(for: periods) { _ in }
        #expect(reports.count == 2)
        for r in reports {
            print("\(r.period): billed \(r.billed) \(r.currency), gross \(r.gross), \(r.lines.count) lines")
            for env in r.view(CostView.environment)!.root.children {
                print("  \(env.name): \(String(format: "%.2f", env.cost))")
            }
            for f in r.findings { print("  ! \(f.title): \(String(format: "%.2f", f.amount))") }
            for w in r.warnings { print("  ~ \(w)") }
            for view in r.views { #expect(abs(view.root.cost - r.gross) < 0.05, "\(view.id) does not add up") }
        }
    }
}

private struct NoCredentials: CredentialStore {
    func secret(_ key: String, for account: UUID) -> String? { nil }
    func setSecret(_ value: String?, _ key: String, for account: UUID) throws {}
}
