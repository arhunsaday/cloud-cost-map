import CloudCostCore
import SwiftUI

/// Month-to-date total in the menu bar, using the first currency billed.
struct MenuBarLabel: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        let reports = model.accounts.compactMap { model.report($0.id, .current()) }
        if let currency = reports.first?.currency {
            let total = reports.filter { $0.currency == currency }.reduce(0) { $0 + $1.billed }
            Label(total.money(currency, compact: true), systemImage: "chart.pie.fill")
                .labelStyle(.titleAndIcon)
        } else {
            Image(systemName: "chart.pie.fill")
        }
    }
}

struct MenuBarView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("Spend this month").font(.headline)
                Spacer()
                Text(BillingPeriod.current().title).font(.caption).foregroundStyle(.secondary)
            }
            if model.accounts.isEmpty {
                Text("No accounts yet.").foregroundStyle(.secondary)
            }
            ForEach(model.accounts) { account in
                Button {
                    model.selection = .account(account.id)
                    open()
                } label: {
                    HStack(spacing: 10) {
                        ProviderBadge(kind: account.provider, size: 20)
                        VStack(alignment: .leading, spacing: 1) {
                            Text(account.name).lineLimit(1)
                            if let r = model.report(account.id, .current()), let f = r.forecast() {
                                Text("Forecast \(f.money(r.currency))").font(.caption).foregroundStyle(.secondary)
                            }
                        }
                        Spacer()
                        if model.status[account.id]?.isLoading == true {
                            ProgressView().controlSize(.mini)
                        } else if let r = model.report(account.id, .current()) {
                            Text(r.billed.money(r.currency)).monospacedDigit()
                                .foregroundStyle(account.monthlyBudget.map { (r.forecast() ?? r.billed) > $0 } == true ? .red : .primary)
                        }
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
            Divider()
            HStack {
                Button("Open Cloud Cost Map") { open() }
                Spacer()
                Button {
                    Task { await model.refreshAll() }
                } label: {
                    Image(systemName: "arrow.clockwise")
                }
                .help("Refresh all accounts")
                Button {
                    NSApp.terminate(nil)
                } label: {
                    Image(systemName: "power")
                }
                .help("Quit")
            }
            .buttonStyle(.borderless)
        }
        .padding(14)
        .frame(width: 300)
    }

    private func open() {
        model.period = .current()
        openWindow(id: "main")
        NSApp.activate()
    }
}
