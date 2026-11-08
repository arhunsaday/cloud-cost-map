import Foundation
import Testing
@testable import CloudCostCore

/// Hits the real Cost Explorer API with an AWS CLI profile. Skipped unless enabled:
///   AWS_LIVE_PROFILE=my-profile [AWS_LIVE_TAG=Environment] swift test --filter LiveAWS
/// Read-only, but AWS bills each Cost Explorer request (USD 0.01): one run makes 5 or 7.
@Suite(.enabled(if: ProcessInfo.processInfo.environment["AWS_LIVE_PROFILE"] != nil))
struct LiveAWSTests {
    @Test func fetchesAndAllocatesRealBilling() async throws {
        let env = ProcessInfo.processInfo.environment
        let profile = env["AWS_LIVE_PROFILE"]!
        let account = Account(name: profile, provider: .aws, settings: [AWSProvider.environmentTagKey: env["AWS_LIVE_TAG"] ?? ""],
                              credentialSource: .awsProfile(profile))
        let provider = try ProviderFactory.make(for: account, credentials: NoAWSCredentials(), options: FetchOptions())
        try await provider.validate()

        let reports = try await provider.fetchReports(for: BillingPeriod.recent(2)) { _ in }
        #expect(reports.count == 2)
        for r in reports {
            print("\(r.period): billed \(r.billed) \(r.currency), gross \(r.gross), credits \(r.credits), \(r.lines.count) lines")
            for env in r.view(CostView.environment)!.root.children {
                print("  \(env.name): \(String(format: "%.2f", env.cost))")
            }
            for f in r.findings { print("  ! \(f.title): \(String(format: "%.2f", f.amount))") }
            for w in r.warnings { print("  ~ \(w)") }
            for view in r.views { #expect(abs(view.root.cost - r.gross) < 0.05, "\(view.id) does not add up") }
        }
    }
}

private struct NoAWSCredentials: CredentialStore {
    func secret(_ key: String, for account: UUID) -> String? { nil }
    func setSecret(_ value: String?, _ key: String, for account: UUID) throws {}
}
