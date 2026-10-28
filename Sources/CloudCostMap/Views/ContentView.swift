import CloudCostCore
import SwiftUI

struct ContentView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        @Bindable var model = model
        NavigationSplitView {
            SidebarView()
                .navigationSplitViewColumnWidth(min: 220, ideal: 250, max: 320)
        } detail: {
            Group {
                if model.accounts.isEmpty {
                    WelcomeView()
                } else {
                    switch model.selection {
                    case .account(let id):
                        if let account = model.account(id) {
                            DashboardView(account: account).id(id)
                        } else {
                            OverviewView()
                        }
                    case .overview, nil:
                        OverviewView()
                    }
                }
            }
        }
        .sheet(isPresented: $model.isAddingAccount) {
            AccountEditor(existing: nil)
        }
        .sheet(item: $model.editingAccount) { account in
            AccountEditor(existing: account)
        }
    }
}

/// Shown until the first account exists.
struct WelcomeView: View {
    @Environment(AppModel.self) private var model
    private let cliProfiles = ScalewayCLIConfig.load()?.profiles.filter(\.isUsable) ?? []

    var body: some View {
        VStack(spacing: 28) {
            AppIconView(size: 112)
            VStack(spacing: 8) {
                Text("Cloud Cost Map").font(.largeTitle.weight(.semibold))
                Text("See where your cloud money goes, by environment, service and resource.")
                    .font(.title3)
                    .foregroundStyle(.secondary)
            }
            VStack(spacing: 10) {
                if !cliProfiles.isEmpty {
                    Button {
                        model.importScalewayProfiles()
                    } label: {
                        Label("Import \(cliProfiles.count) Scaleway CLI profile\(cliProfiles.count == 1 ? "" : "s")", systemImage: "square.and.arrow.down")
                            .frame(maxWidth: 280)
                    }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.large)
                    Text(cliProfiles.map(\.name).joined(separator: ", "))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Button {
                    model.isAddingAccount = true
                } label: {
                    Label("Add an account…", systemImage: "plus").frame(maxWidth: 280)
                }
                .buttonStyle(.bordered)
                .controlSize(.large)
                Button("Explore with demo data") { model.addDemoAccount() }
                    .buttonStyle(.link)
                    .padding(.top, 4)
            }
        }
        .padding(40)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

struct AppIconView: View {
    var size: CGFloat
    var body: some View {
        Image(nsImage: NSApp.applicationIconImage)
            .resizable()
            .frame(width: size, height: size)
    }
}
