import Charts
import CloudCostCore
import SwiftUI

/// Headline numbers and the monthly trend above the chart.
struct SummaryStrip: View {
    @Environment(AppModel.self) private var model
    let account: Account
    let report: CostReport
    let history: [CostReport]

    private var previous: CostReport? { model.report(account.id, report.period.previous) }

    /// Drops the least important cards until the strip fits, instead of
    /// widening the detail column and pushing the chart off-centre.
    var body: some View {
        ViewThatFits(in: .horizontal) {
            strip(showsTrend: true, showsBudget: true)
            strip(showsTrend: false, showsBudget: true)
            strip(showsTrend: false, showsBudget: false)
        }
        .fixedSize(horizontal: false, vertical: true)
    }

    private func strip(showsTrend: Bool, showsBudget: Bool) -> some View {
        HStack(alignment: .top, spacing: 12) {
            StatCard(title: report.isPartial ? "Month to date" : "Billed", value: report.billed.money(report.currency),
                     footnote: report.credits < 0 ? "after \((-report.credits).money(report.currency)) credits" : report.period.title)
            changeCard
            if let forecast = report.forecast() {
                StatCard(title: "Forecast", value: forecast.money(report.currency),
                         footnote: "at today’s pace, \(Int((report.period.elapsedFraction() * 100).rounded()))% through the month")
            }
            if showsBudget { BudgetCard(account: account, report: report) }
            if showsTrend {
                TrendChart(history: history, selected: report.period, currency: report.currency)
                    .frame(minWidth: 220, maxWidth: .infinity)
            }
        }
    }

    /// Against the same share of last month while the month is running, so the comparison is fair.
    @ViewBuilder private var changeCard: some View {
        if let previous, previous.billed > 0 {
            let fraction = report.period.elapsedFraction()
            let baseline = previous.billed * fraction
            let change = (report.billed - baseline) / baseline
            StatCard(title: "vs. \(previous.period.shortTitle)", value: change.signedPercent,
                     footnote: fraction < 1 ? "same point last month" : "\(previous.billed.money(report.currency)) last month",
                     tint: change > 0.05 ? .red : change < -0.05 ? .green : nil,
                     symbol: change >= 0 ? "arrow.up.right" : "arrow.down.right")
        } else {
            StatCard(title: "Credits", value: (-report.credits).money(report.currency), footnote: "discounts and vouchers")
        }
    }
}

struct StatCard: View {
    let title: String
    let value: String
    var footnote: String? = nil
    var tint: Color? = nil
    var symbol: String? = nil

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title).font(.caption.weight(.medium)).foregroundStyle(.secondary).textCase(.uppercase)
            HStack(spacing: 4) {
                if let symbol { Image(systemName: symbol).font(.headline) }
                Text(value).font(.title2.weight(.semibold).monospacedDigit()).lineLimit(1).minimumScaleFactor(0.7)
            }
            .foregroundStyle(tint ?? .primary)
            if let footnote {
                Text(footnote).font(.caption).foregroundStyle(.secondary).lineLimit(2).fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 0)
        }
        .padding(12)
        .frame(minWidth: 140, maxWidth: 200, alignment: .leading)
        .frame(maxHeight: .infinity, alignment: .topLeading)
        .background(.background.secondary, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
    }
}

struct BudgetCard: View {
    @Environment(AppModel.self) private var model
    let account: Account
    let report: CostReport
    @State private var editing = false
    @State private var draft = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text("Budget").font(.caption.weight(.medium)).foregroundStyle(.secondary).textCase(.uppercase)
                Spacer()
                Button { draft = account.monthlyBudget.map { String(Int($0)) } ?? ""; editing = true } label: {
                    Image(systemName: "pencil")
                }
                .buttonStyle(.borderless)
                .help("Set a monthly budget")
            }
            if let budget = account.monthlyBudget, budget > 0 {
                let projected = report.forecast() ?? report.billed
                let ratio = projected / budget
                Text("\(Int((report.billed / budget * 100).rounded()))% used")
                    .font(.title2.weight(.semibold).monospacedDigit())
                    .foregroundStyle(ratio > 1 ? .red : ratio > 0.9 ? .orange : .primary)
                ProgressView(value: min(report.billed / budget, 1))
                    .tint(ratio > 1 ? .red : ratio > 0.9 ? .orange : .accentColor)
                Text(ratio > 1 ? "on track to exceed \(budget.money(report.currency))" : "of \(budget.money(report.currency))")
                    .font(.caption).foregroundStyle(.secondary)
            } else {
                Text("Not set").font(.title2.weight(.semibold)).foregroundStyle(.tertiary)
                Text("Get warned before you overspend").font(.caption).foregroundStyle(.secondary)
            }
            Spacer(minLength: 0)
        }
        .padding(12)
        .frame(minWidth: 150, maxWidth: 200, alignment: .leading)
        .frame(maxHeight: .infinity, alignment: .topLeading)
        .background(.background.secondary, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
        .popover(isPresented: $editing) {
            Form {
                TextField("Monthly budget (\(report.currency))", text: $draft)
                    .onSubmit(save)
                HStack {
                    Button("Clear") { draft = ""; save() }
                    Spacer()
                    Button("Save", action: save).keyboardShortcut(.defaultAction)
                }
            }
            .padding()
            .frame(width: 260)
        }
    }

    private func save() {
        model.setBudget(Double(draft.replacingOccurrences(of: ",", with: ".").filter { $0.isNumber || $0 == "." }), for: account.id)
        editing = false
    }
}

/// Monthly totals; the running month shows its forecast as a hatched extension.
struct TrendChart: View {
    @Environment(AppModel.self) private var model
    let history: [CostReport]
    let selected: BillingPeriod
    let currency: String

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("Last \(history.count) months").font(.caption.weight(.medium)).foregroundStyle(.secondary).textCase(.uppercase)
            Chart {
                ForEach(history) { r in
                    BarMark(x: .value("Month", r.period.shortTitle), y: .value("Cost", r.billed))
                        .foregroundStyle(r.period == selected ? Color.accentColor : Color.accentColor.opacity(0.35))
                        .cornerRadius(3)
                    if let forecast = r.forecast() {
                        BarMark(x: .value("Month", r.period.shortTitle), yStart: .value("Cost", r.billed), yEnd: .value("Forecast", forecast))
                            .foregroundStyle(Color.accentColor.opacity(0.15))
                            .cornerRadius(3)
                    }
                }
            }
            .chartYAxis {
                AxisMarks(position: .trailing, values: .automatic(desiredCount: 3)) { value in
                    AxisGridLine()
                    AxisValueLabel { if let v = value.as(Double.self) { Text(v.money(currency, compact: true)) } }
                }
            }
            .chartOverlay { proxy in
                GeometryReader { _ in
                    Rectangle().fill(.clear).contentShape(Rectangle())
                        .onTapGesture { location in
                            if let label: String = proxy.value(atX: location.x),
                               let r = history.first(where: { $0.period.shortTitle == label }) {
                                model.period = r.period
                            }
                        }
                }
            }
            .frame(minHeight: 70)
        }
        .padding(12)
        .background(.background.secondary, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
        .help("Click a month to show it")
    }
}
