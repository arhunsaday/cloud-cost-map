import Foundation
import Testing
@testable import CloudCostCore

@Suite struct AWSAttributionTests {
    let fixtures = Bundle.module.url(forResource: "Fixtures/aws", withExtension: nil)!
    let september = BillingPeriod(year: 2026, month: 9)

    func data(tagKey: String?) throws -> AWSCostData {
        try AWSCostData(tagKey: tagKey) { query in
            try JSONValue.parse(Data(contentsOf: fixtures.appending(path: "\(query.rawValue).json"))).array
        }
    }

    func report(tagKey: String? = nil, period: BillingPeriod? = nil) throws -> CostReport {
        AWSCostAttribution(environments: .default)
            .report(accountID: UUID(), period: period ?? september, data: try data(tagKey: tagKey))
    }

    @Test func totalsMatchInvoice() throws {
        let r = try report()
        #expect(r.currency == "USD")
        #expect(abs(r.billed - 705) < 0.001)
        // Pages merged; the negative Savings Plan group is left to credits.
        #expect(abs(r.gross - 810) < 0.001)
        #expect(abs(r.credits - -105) < 0.001)
        #expect(r.views.map(\.id) == [CostView.environment, CostView.service, CostView.account, CostView.region])
        for view in r.views {
            #expect(abs(view.root.cost - r.gross) < 0.01, "\(view.id) sums to \(view.root.cost)")
        }
        #expect(abs(r.lines.reduce(0) { $0 + $1.amount } - r.gross) < 0.01)
    }

    @Test func monthsAreKeptApart() throws {
        let r = try report(period: BillingPeriod(year: 2026, month: 10))
        #expect(r.billed == 100)
        #expect(r.gross == 100)
        #expect(r.credits == 0)
        // A single account: no account view, no account suffix on labels.
        #expect(r.view(CostView.account)?.id == CostView.environment)
        #expect(r.view(CostView.environment)?.root.find("env/prod/compute/EC2 instances")?.cost == 100)
    }

    @Test func environmentsFromAccountNames() throws {
        let env = try #require(try report().view(CostView.environment)).root
        #expect(env.children.map(\.id) == ["env/prod", "env/dev", "env/shared"])
        #expect(env.find("env/prod")?.cost == 550)
        #expect(env.find("env/dev")?.cost == 150)
        #expect(env.find("env/shared")?.cost == 110)
        #expect(env.find("env/prod/compute/EC2 instances · acme-prod")?.cost == 300)
        #expect(env.find("env/prod/db")?.cost == 200)
    }

    @Test func environmentsFromTagThenAccount() throws {
        let r = try report(tagKey: "Environment")
        let env = try #require(r.view(CostView.environment)).root
        #expect(abs(env.cost - 810) < 0.001)
        // Tagged production EC2 plus untagged EC2-Other in the prod account.
        #expect(env.find("env/prod/compute")?.cost == 330)
        #expect(env.find("env/staging")?.cost == 20)
        #expect(env.find("env/dev")?.cost == 150)
        // A tag value that names no environment is shared, labelled with the value.
        #expect(env.find("env/shared/storage/S3 · marketing")?.cost == 10)
        // Untagged, in an account that names no environment.
        #expect(env.find("env/unassigned")?.cost == 100)
        #expect(r.warnings.isEmpty)

        let untagged = try #require(r.findings.first { $0.kind == .info })
        #expect(untagged.amount == 100)
        #expect(r.findings.first { $0.title == "Non-production compute" }?.amount == 140)
    }

    @Test func warnsWhenTagIsNotActivated() throws {
        // Keep only the untagged bucket, as when the tag was never activated.
        var d = try data(tagKey: "Environment")
        var tagged = try #require(d.results[.tagService])
        tagged.groups["2026-09"] = tagged.groups["2026-09"]?.filter { $0.keys[0] == "Environment$" }
        d.results[.tagService] = tagged
        let r = AWSCostAttribution(environments: .default).report(accountID: UUID(), period: september, data: d)
        #expect(r.warnings.contains { $0.contains("Cost allocation tags") })
    }

    @Test func serviceViewAndFindings() throws {
        let r = try report()
        let svc = try #require(r.view(CostView.service)).root
        #expect(svc.find("svc/compute")?.cost == 470)
        // One usage type: collapsed into a leaf named after the service.
        let rds = try #require(svc.find("svc/\(rdsName)/USE1-InstanceUsage:db.r6g.large"))
        #expect(rds.name == "RDS")
        #expect(svc.find("svc/other")?.leaves.first?.name == "Tax")
        #expect(svc.find("svc/EC2 - Other/USE1-ElasticIP:IdleAddress")?.flag == .orphan)

        #expect(r.findings.map(\.title) == ["Non-production compute", "gp2 volumes", "NAT Gateways (2% of the bill)", "Idle public IPv4 addresses"])
        let idle = try #require(r.findings.last)
        #expect(idle.kind == .reclaim)
        #expect(idle.viewID == CostView.service)
        #expect(idle.nodeIDs.allSatisfy { svc.find($0) != nil })
    }

    @Test func regionAndAccountViews() throws {
        let r = try report()
        let region = try #require(r.view(CostView.region)).root
        #expect(Set(region.children.map(\.name)) == ["us-east-1", "eu-west-1", "Global"])
        #expect(region.find("rgn/Global")?.cost == 70)
        let accounts = try #require(r.view(CostView.account)).root
        #expect(accounts.children.map(\.name) == ["acme-prod", "acme-dev", "acme-shared"])
    }

    let rdsName = "Amazon Relational Database Service"

    @Test(arguments: [
        ("Amazon Elastic Compute Cloud - Compute", "compute"), ("EC2 - Other", "compute"), ("AWS Lambda", "compute"),
        ("Amazon Relational Database Service", "db"), ("Amazon DynamoDB", "db"), ("Amazon CloudFront", "network"),
        ("Amazon Virtual Private Cloud", "network"), ("Amazon Simple Storage Service", "storage"),
        ("Amazon EC2 Container Registry (ECR)", "other"), ("AWS Secrets Manager", "other"), ("Tax", "other"),
    ])
    func serviceGroups(service: String, group: String) {
        #expect(AWSCostAttribution.group(ofService: service) == group)
    }

    @Test func names() {
        #expect(AWSCostAttribution.shortName("Amazon Relational Database Service") == "RDS")
        #expect(AWSCostAttribution.shortName("AWS Secrets Manager") == "Secrets Manager")
        #expect(AWSCostAttribution.tagValue("Environment$prod") == "prod")
        #expect(AWSCostAttribution.tagValue("Environment$") == "")
        #expect(AWSCostAttribution.regionName("NoRegion") == "Global")
    }
}

@Suite struct AWSRequestTests {
    @Test func timePeriodCoversMonthsAndStopsAtTomorrow() {
        let now = ISO8601DateFormatter().date(from: "2026-11-08T22:00:00Z")!
        let periods = [BillingPeriod(year: 2026, month: 9), BillingPeriod(year: 2026, month: 10)]
        let closed = AWSCostData.timePeriod(periods, now: now)
        #expect(closed.start == "2026-09-01")
        #expect(closed.end == "2026-11-01")
        let open = AWSCostData.timePeriod(periods + [BillingPeriod(year: 2026, month: 11)], now: now)
        #expect(open.end == "2026-11-09")
    }

    @Test func encodesUntaggedQuery() throws {
        let request = AWSCostData.Query.untaggedServiceAccount.request(.init(start: "2026-09-01", end: "2026-10-01"), tagKey: "Environment")
        let json = try JSONValue.parse(JSONEncoder().encode(request))
        #expect(json["TimePeriod"]["Start"].string == "2026-09-01")
        #expect(json["Granularity"].string == "MONTHLY")
        #expect(json["Metrics"].array.first?.string == "UnblendedCost")
        #expect(json["GroupBy"].array.map { $0["Key"].string } == ["SERVICE", "LINKED_ACCOUNT"])
        let and = json["Filter"]["And"].array
        #expect(and.count == 2)
        #expect(and[0]["Not"]["Dimensions"]["Key"].string == "RECORD_TYPE")
        #expect(and[0]["Not"]["Dimensions"]["Values"].array.contains { $0.string == "Credit" })
        #expect(and[1]["Tags"]["Key"].string == "Environment")
        #expect(and[1]["Tags"]["MatchOptions"].array.first?.string == "ABSENT")
        #expect(json["NextPageToken"].isNull)

        let total = try JSONValue.parse(JSONEncoder().encode(AWSCostData.Query.total.request(.init(start: "a", end: "b"), tagKey: nil)))
        #expect(total["GroupBy"].isNull)
        #expect(total["Filter"].isNull)
        #expect(AWSCostData.Query.all(tagKey: nil).count == 4)
        #expect(AWSCostData.Query.all(tagKey: "Environment").count == 6)
    }

    @Test func mapsErrors() {
        func status(_ body: String) -> String? {
            AWSCostExplorerClient.error(status: 400, data: Data(body.utf8)).errorDescription
        }
        #expect(status(#"{"__type":"UnrecognizedClientException","message":"The security token included in the request is invalid."}"#)?.contains("401") == true)
        #expect(status(#"{"__type":"com.amazon.coral.service#AccessDeniedException","Message":"no"}"#)?.contains("ce:GetCostAndUsage") == true)
        #expect(status(#"{"__type":"DataUnavailableException","Message":"x"}"#)?.contains("Cost Explorer") == true)
    }
}

@Suite struct AWSSignerTests {
    let credentials = AWSCredentials(accessKeyID: "AKIDEXAMPLE", secretAccessKey: "wJalrXUtnFEMI/K7MDENG+bPxRfiCYEXAMPLEKEY")
    let date = ISO8601DateFormatter().date(from: "2015-08-30T12:36:00Z")!

    /// The worked example of the AWS Signature Version 4 documentation.
    @Test func matchesDocumentationExample() {
        let signer = AWSSigner(credentials: credentials, region: "us-east-1", service: "iam")
        #expect(signer.signingKey(day: "20150830").hex == "c4afb1cc5771d871763a393e44b703571b55cc28424d1a5e86da6ed3c154a4b9")
        let headers = signer.signingHeaders(method: "GET", url: URL(string: "https://iam.amazonaws.com/?Version=2010-05-08&Action=ListUsers")!,
                                            headers: ["Content-Type": "application/x-www-form-urlencoded; charset=utf-8"],
                                            body: Data(), date: date)
        #expect(headers["X-Amz-Date"] == "20150830T123600Z")
        #expect(headers["Authorization"] == "AWS4-HMAC-SHA256 Credential=AKIDEXAMPLE/20150830/us-east-1/iam/aws4_request, "
            + "SignedHeaders=content-type;host;x-amz-date, Signature=5d672d79c15b13162d9279b0855cfba6789a8edb4c82c400e06b5924a6f2b5d7")
        #expect(headers["X-Amz-Security-Token"] == nil)
    }

    @Test func signsSessionToken() {
        var temporary = credentials
        temporary.sessionToken = "token"
        let signer = AWSSigner(credentials: temporary, region: "us-east-1", service: "ce")
        let headers = signer.signingHeaders(method: "POST", url: URL(string: "https://ce.us-east-1.amazonaws.com/")!,
                                            headers: ["X-Amz-Target": "AWSInsightsIndexService.GetCostAndUsage"], body: Data("{}".utf8), date: date)
        #expect(headers["X-Amz-Security-Token"] == "token")
        #expect(headers["Authorization"]?.contains("SignedHeaders=host;x-amz-date;x-amz-security-token;x-amz-target,") == true)
    }
}

@Suite struct AWSCLIConfigTests {
    @Test func mergesCredentialsAndConfig() {
        let config = AWSCLIConfig.parse(credentials: """
        [default]
        aws_access_key_id = AKIADEFAULT
        aws_secret_access_key = default-secret
        # comment
        [billing]
        aws_access_key_id=AKIABILLING
        aws_secret_access_key=billing-secret
        aws_session_token = tok
        """, config: """
        [default]
        region = eu-west-1
        [profile billing]
        region = us-east-1
        s3 =
          max_concurrent_requests = 20
        [profile sso-dev]
        sso_session = corp
        sso_account_id = 123
        [sso-session corp]
        sso_start_url = https://corp.awsapps.com/start
        [profile admin]
        role_arn = arn:aws:iam::123:role/Admin
        source_profile = default
        """, activeProfile: "billing")

        #expect(config.profiles.map(\.name) == ["default", "billing", "sso-dev", "admin"])
        #expect(config.activeProfile == "billing")
        let billing = config.profile(named: "billing")
        #expect(billing?.credentials == AWSCredentials(accessKeyID: "AKIABILLING", secretAccessKey: "billing-secret", sessionToken: "tok"))
        #expect(billing?.region == "us-east-1")
        #expect(config.profile(named: "default")?.region == "eu-west-1")
        #expect(config.profile(named: "sso-dev")?.isUsable == false)
        #expect(config.profile(named: "sso-dev")?.unsupportedReason == "Uses IAM Identity Center (SSO)")
        #expect(config.profile(named: "admin")?.unsupportedReason == "Assumes a role")
    }

    @Test func resolvesKeychainAccount() throws {
        let account = Account(name: "AWS", provider: .aws, settings: ["access_key_id": "AKIA1", AWSProvider.environmentTagKey: " env "])
        let store = DictionaryStore(values: ["secret_access_key": "s", "session_token": ""])
        let config = try AWSProvider.Configuration.resolve(account: account, credentials: store)
        #expect(config.credentials == AWSCredentials(accessKeyID: "AKIA1", secretAccessKey: "s"))
        #expect(config.environmentTag == "env")
        #expect(throws: ProviderError.self) {
            try AWSProvider.Configuration.resolve(account: account, credentials: DictionaryStore(values: [:]))
        }
    }
}

private struct DictionaryStore: CredentialStore {
    let values: [String: String]
    func secret(_ key: String, for account: UUID) -> String? { values[key] }
    func setSecret(_ value: String?, _ key: String, for account: UUID) throws {}
}
