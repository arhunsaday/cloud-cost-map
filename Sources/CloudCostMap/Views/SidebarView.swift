import CloudCostCore
import SwiftUI

struct SidebarView: View {
    @Environment(AppModel.self) private var model
    @State private var removing: Account?

    var body: some View {
        @Bindable var model = model
        List(selection: $model.selection) {
            Label("Overview", systemImage: "chart.bar.doc.horizontal")
                .tag(SidebarItem.overview)

            Section("Accounts") {
                ForEach(model.accounts) { account in
                    AccountRow(account: account)
                        .tag(SidebarItem.account(account.id))
                        .contextMenu {
                            Button("Refresh") { Task { await model.refresh(account.id) } }
                            Button("Edit…") { model.editingAccount = account }
                            Divider()
                            Button("Remove…", role: .destructive) { removing = account }
                        }
                }
                .onMove { model.moveAccounts(from: $0, to: $1) }
            }
        }
        .safeAreaInset(edge: .bottom) {
            HStack {
                Menu {
                    Button("Add Account…") { model.isAddingAccount = true }
                    Button("Import Scaleway CLI Profiles") { model.importScalewayProfiles() }
                    Button("Add Demo Account") { model.addDemoAccount() }
                } label: {
                    Label("Add Account", systemImage: "plus")
                }
                .menuStyle(.borderlessButton)
                .fixedSize()
                Spacer()
                if model.isLoadingAny { ProgressView().controlSize(.small) }
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 10)
        }
        .confirmationDialog("Remove “\(removing?.name ?? "")”?", isPresented: .init(get: { removing != nil }, set: { if !$0 { removing = nil } })) {
            Button("Remove Account", role: .destructive) {
                if let id = removing?.id { model.remove(id) }
            }
        } message: {
            Text("Its cached reports and Keychain secrets are deleted. Linked CLI profiles are left untouched.")
        }
    }
}

struct AccountRow: View {
    @Environment(AppModel.self) private var model
    let account: Account

    var body: some View {
        HStack(spacing: 10) {
            ProviderBadge(kind: account.provider, size: 22)
            VStack(alignment: .leading, spacing: 1) {
                Text(account.name).lineLimit(1)
                statusLine
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            Spacer(minLength: 4)
            if let report = model.report(account.id) {
                Text(report.billed.money(report.currency, compact: true))
                    .font(.callout.monospacedDigit())
                    .foregroundStyle(.secondary)
            }
        }
        .padding(.vertical, 2)
    }

    @ViewBuilder private var statusLine: some View {
        switch model.status[account.id] ?? .idle {
        case .loading(let message): Text(message)
        case .failed: Label("Refresh failed", systemImage: "exclamationmark.triangle.fill").foregroundStyle(.orange)
        case .idle:
            if let report = model.report(account.id), let forecast = report.forecast() {
                Text("→ \(forecast.money(report.currency, compact: true)) forecast")
            } else {
                Text(account.provider.shortName)
            }
        }
    }
}

struct ProviderBadge: View {
    let kind: ProviderKind
    var size: CGFloat = 20

    var body: some View {
        RoundedRectangle(cornerRadius: size * 0.28, style: .continuous)
            .fill(Palette.provider(kind).gradient)
            .frame(width: size, height: size)
            .overlay {
                Image(systemName: kind.symbol)
                    .font(.system(size: size * 0.5, weight: .semibold))
                    .foregroundStyle(.white)
            }
    }
}
