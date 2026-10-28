import Charts
import CloudCostCore
import SwiftUI

/// Every account side by side: totals, trend and what to look at.
struct OverviewView: View {
    @Environment(AppModel.self) private var model

    private struct Point: Identifiable {
        var id: String { account.id.uuidString + period.code }
        let account: Account
        let period: BillingPeriod
        let amount: Double
    }

    /// Totals per currency for the selected month: accounts billed in different currencies are never summed.
    private var totals: [(currency: String, billed: Double, forecast: Double)] {
        let reports = model.accounts.compactMap { model.report($0.id) }
        return Dictionary(grouping: reports, by: \.currency).map { currency, rs in
            (currency, rs.reduce(0) { $0 + $1.billed }, rs.reduce(0) { $0 + ($1.forecast() ?? $1.billed) })
        }
        .sorted { $0.billed > $1.billed }
    }

    private var points: [Point] {
        model.accounts.flatMap { a in model.history(a.id).map { Point(account: a, period: $0.period, amount: $0.billed) } }
    }

    private var findings: [(Account, Finding, String)] {
        model.accounts.flatMap { a -> [(Account, Finding, String)] in
            guard let r = model.report(a.id) else { return [] }
            return r.findings.filter { $0.kind != .info }.map { (a, $0, r.currency) }
        }
        .sorted { $0.1.amount > $1.1.amount }
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                HStack(spacing: 12) {
                    ForEach(totals, id: \.currency) { t in
                        StatCard(title: model.period.isCurrent() ? "All accounts, to date" : "All accounts",
                                 value: t.billed.money(t.currency), footnote: model.period.title)
                        if model.period.isCurrent() {
                            StatCard(title: "Forecast", value: t.forecast.money(t.currency), footnote: "end of \(model.period.shortTitle)")
                        }
                    }
                    StatCard(title: "Accounts", value: "\(model.accounts.count)",
                             footnote: Set(model.accounts.map(\.provider.shortName)).sorted().joined(separator: ", "))
                    StatCard(title: "Savings to review", value: "\(findings.count)",
                             footnote: findings.isEmpty ? "nothing flagged" : "\(findings.filter { $0.1.kind == .reclaim }.count) unused resources")
                }
                .fixedSize(horizontal: false, vertical: true)

                card("Monthly spend by account") {
                    Chart(points) { p in
                        BarMark(x: .value("Month", p.period.start(), unit: .month), y: .value("Cost", p.amount))
                            .foregroundStyle(by: .value("Account", p.account.name))
                            .cornerRadius(2)
                    }
                    .chartXAxis { AxisMarks(values: .stride(by: .month)) { _ in AxisValueLabel(format: .dateTime.month(.abbreviated)) } }
                    .chartLegend(position: .bottom, alignment: .leading)
                    .frame(height: 220)
                }

                card("Accounts") {
                    VStack(spacing: 0) {
                        ForEach(model.accounts) { account in
                            AccountSummaryRow(account: account)
                                .onTapGesture { model.selection = .account(account.id) }
                            if account.id != model.accounts.last?.id { Divider() }
                        }
                    }
                }

                if !findings.isEmpty {
                    card("Worth a look") {
                        VStack(alignment: .leading, spacing: 10) {
                            ForEach(findings.prefix(8), id: \.1.id) { account, finding, currency in
                                HStack(alignment: .firstTextBaseline) {
                                    Image(systemName: finding.kind.symbol).foregroundStyle(finding.kind == .reclaim ? .orange : .blue)
                                    VStack(alignment: .leading, spacing: 2) {
                                        Text(finding.title).font(.callout.weight(.medium))
                                        Text(account.name).font(.caption).foregroundStyle(.secondary)
                                    }
                                    Spacer()
                                    Text(finding.amount.money(currency)).monospacedDigit()
                                }
                                .contentShape(Rectangle())
                                .onTapGesture { model.selection = .account(account.id) }
                            }
                        }
                    }
                }
            }
            .padding(20)
        }
        .navigationTitle("Overview")
        .navigationSubtitle(model.period.title)
        .toolbar {
            ToolbarItem(placement: .navigation) {
                @Bindable var model = model
                Picker("Month", selection: $model.period) {
                    ForEach(model.periods.reversed()) { p in Text(p.title).tag(p) }
                }
                .fixedSize()
            }
            ToolbarItem(placement: .primaryAction) {
                Button {
                    Task { await model.refreshAll() }
                } label: {
                    Label("Refresh All", systemImage: "arrow.clockwise")
                }
                .disabled(model.isLoadingAny)
            }
        }
    }

    private func card<Content: View>(_ title: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(title).font(.headline)
            content()
        }
        .padding(16)
        .background(.background.secondary, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
    }
}

private struct AccountSummaryRow: View {
    @Environment(AppModel.self) private var model
    let account: Account

    var body: some View {
        let report = model.report(account.id)
        let history = model.history(account.id)
        HStack(spacing: 12) {
            ProviderBadge(kind: account.provider, size: 28)
            VStack(alignment: .leading, spacing: 2) {
                Text(account.name).font(.body.weight(.medium))
                Text(account.provider.displayName).font(.caption).foregroundStyle(.secondary)
            }
            .frame(width: 200, alignment: .leading)
            Chart(history) { r in
                LineMark(x: .value("Month", r.period.start()), y: .value("Cost", r.billed))
                    .interpolationMethod(.monotone)
                    .foregroundStyle(Palette.provider(account.provider))
            }
            .chartXAxis(.hidden)
            .chartYAxis(.hidden)
            .frame(width: 120, height: 30)
            Spacer()
            if let report {
                if let budget = account.monthlyBudget, budget > 0 {
                    Gauge(value: min(report.billed / budget, 1)) { EmptyView() }
                        .gaugeStyle(.accessoryCircularCapacity)
                        .tint((report.forecast() ?? report.billed) > budget ? .red : .accentColor)
                        .scaleEffect(0.55)
                        .frame(width: 30, height: 30)
                        .help("\(Int(report.billed / budget * 100))% of \(budget.money(report.currency)) budget")
                }
                VStack(alignment: .trailing, spacing: 2) {
                    Text(report.billed.money(report.currency)).font(.body.monospacedDigit().weight(.medium))
                    if let forecast = report.forecast() {
                        Text("→ \(forecast.money(report.currency))").font(.caption.monospacedDigit()).foregroundStyle(.secondary)
                    }
                }
                .frame(width: 110, alignment: .trailing)
            } else if model.status[account.id]?.isLoading == true {
                ProgressView().controlSize(.small)
            } else {
                Text("No data").foregroundStyle(.secondary)
            }
            Image(systemName: "chevron.right").foregroundStyle(.tertiary)
        }
        .padding(.vertical, 10)
        .contentShape(Rectangle())
    }
}
