import CloudCostCore
import SwiftUI
import UniformTypeIdentifiers

/// One account: summary, trend, the chart, and the inspector.
struct DashboardView: View {
    @Environment(AppModel.self) private var model
    @Environment(Preferences.self) private var preferences
    let account: Account

    @State private var focusID: String?
    @State private var selectedID: String?
    @State private var hoveredID: String?
    @State private var highlighted: Set<String> = []
    @State private var showsInspector = true
    @State private var search = ""

    private var report: CostReport? { model.report(account.id) }
    private var view: CostView? { report?.view(preferences.viewID) }

    var body: some View {
        Group {
            if let report, let view {
                content(report: report, view: view)
            } else {
                placeholder
            }
        }
        .navigationTitle(account.name)
        .navigationSubtitle(subtitle)
        .toolbar { toolbar }
        .inspector(isPresented: $showsInspector) {
            Group {
                if let report, let view {
                    InspectorView(account: account, report: report, view: view, focus: focusNode(view),
                                  selectedID: $selectedID, highlighted: $highlighted, onZoom: zoom(to:))
                } else {
                    Color.clear
                }
            }
            .inspectorColumnWidth(min: 260, ideal: 310, max: 420)
        }
        .onChange(of: preferences.viewID) { reset() }
        .onChange(of: model.period) {
            // Keep the zoom when the same node exists in the new month.
            if let focusID, view?.root.find(focusID) == nil { self.focusID = nil }
            highlighted = []
        }
    }

    // MARK: Content

    private func content(report: CostReport, view: CostView) -> some View {
        let focus = focusNode(view)
        return VStack(spacing: 0) {
            if case .failed(let message) = model.status[account.id] ?? .idle {
                ErrorBanner(message: message) { Task { await model.refresh(account.id) } }
            }
            SummaryStrip(account: account, report: report, history: model.history(account.id))
                .padding([.horizontal, .top], 16)
                .padding(.bottom, 12)
            Divider()
            BreadcrumbBar(path: view.root.path(to: focus.id) ?? [view.root], currency: report.currency,
                          onSelect: { node in zoom(to: node.id == view.root.id ? nil : node) })
            Group {
                switch preferences.chartStyle {
                case .sunburst:
                    SunburstView(focus: focus, total: view.root.cost, currency: report.currency, rings: preferences.sunburstRings,
                                 selectedID: selectedID, highlighted: highlighted, hoveredID: $hoveredID,
                                 canZoomOut: focusID != nil, onActivate: activate, onZoomOut: zoomOut)
                        .padding(20)
                case .treemap:
                    TreemapView(focus: focus, total: view.root.cost, currency: report.currency, selectedID: selectedID,
                                highlighted: highlighted, hoveredID: $hoveredID, onActivate: activate)
                        .padding(12)
                case .list:
                    CostListView(focus: focus, total: view.root.cost, currency: report.currency, selectedID: $selectedID, search: search)
                        .searchable(text: $search, placement: .toolbar, prompt: "Filter resources or SKUs")
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .overlay {
                if focus.cost <= 0 {
                    ContentUnavailableView("Nothing billed", systemImage: "eurosign.circle",
                                           description: Text("No cost in \(model.period.title) for this view yet."))
                }
            }
        }
    }

    @ViewBuilder private var placeholder: some View {
        switch model.status[account.id] ?? .idle {
        case .loading(let message):
            ProgressView(message).frame(maxWidth: .infinity, maxHeight: .infinity)
        case .failed(let message):
            ContentUnavailableView {
                Label("Couldn’t load costs", systemImage: "exclamationmark.icloud")
            } description: {
                Text(message)
            } actions: {
                Button("Try Again") { Task { await model.refresh(account.id) } }
                Button("Edit Account…") { model.editingAccount = account }
            }
        case .idle:
            ContentUnavailableView {
                Label("No data for \(model.period.title)", systemImage: "calendar.badge.clock")
            } actions: {
                Button("Refresh") { Task { await model.refresh(account.id) } }
            }
        }
    }

    private var subtitle: String {
        if case .loading(let message) = model.status[account.id] ?? .idle { return message }
        guard let date = model.lastUpdated(account.id) else { return account.provider.displayName }
        return "\(account.provider.shortName) · updated \(date.formatted(.relative(presentation: .named)))"
    }

    // MARK: Toolbar

    @ToolbarContentBuilder private var toolbar: some ToolbarContent {
        @Bindable var model = model
        @Bindable var preferences = preferences
        ToolbarItem(placement: .navigation) {
            Picker("Month", selection: $model.period) {
                ForEach(model.periods.reversed()) { p in
                    Text(p.isCurrent() ? "\(p.title) (to date)" : p.title).tag(p)
                }
            }
            .pickerStyle(.menu)
            .frame(minWidth: 190)
            .help("Billing month")
        }
        ToolbarItemGroup(placement: .principal) {
            if let report, report.views.count > 1 {
                Picker("Group by", selection: $preferences.viewID) {
                    ForEach(report.views) { v in Text(v.title).tag(v.id) }
                }
                .pickerStyle(.segmented)
                .help("Group costs by")
            }
            Picker("Chart", selection: $preferences.chartStyle) {
                ForEach(ChartStyle.allCases) { s in Label(s.title, systemImage: s.symbol).tag(s) }
            }
            .pickerStyle(.segmented)
            .labelStyle(.iconOnly)
            .help("Sunburst ⌘1 · Treemap ⌘2 · List ⌘3")
        }
        ToolbarItemGroup(placement: .primaryAction) {
            Button {
                Task { await model.refresh(account.id) }
            } label: {
                Label("Refresh", systemImage: "arrow.clockwise")
            }
            .disabled(model.status[account.id]?.isLoading == true)
            ExportMenu(report: report, view: view)
            Button {
                showsInspector.toggle()
            } label: {
                Label("Inspector", systemImage: "sidebar.trailing")
            }
        }
    }

    // MARK: Navigation

    private func focusNode(_ view: CostView) -> CostNode {
        focusID.flatMap(view.root.find) ?? view.root
    }

    private func activate(_ node: CostNode) {
        selectedID = node.id
        highlighted = []
        if !node.isLeaf { zoom(to: node) }
    }

    private func zoom(to node: CostNode?) {
        withAnimation(.smooth) { focusID = node?.id }
        hoveredID = nil
    }

    private func zoomOut() {
        guard let view, let focusID, let path = view.root.path(to: focusID), path.count >= 2 else { return }
        let parent = path[path.count - 2]
        zoom(to: parent.id == view.root.id ? nil : parent)
        selectedID = focusID
    }

    private func reset() {
        focusID = nil
        selectedID = nil
        highlighted = []
    }
}

struct BreadcrumbBar: View {
    let path: [CostNode]
    let currency: String
    var onSelect: (CostNode) -> Void

    var body: some View {
        HStack(spacing: 4) {
            ForEach(Array(path.enumerated()), id: \.element.id) { index, node in
                if index > 0 { Image(systemName: "chevron.right").font(.caption2).foregroundStyle(.tertiary) }
                Button(node.name) { onSelect(node) }
                    .buttonStyle(.plain)
                    .font(.callout.weight(index == path.count - 1 ? .semibold : .regular))
                    .foregroundStyle(index == path.count - 1 ? .primary : .secondary)
                    .disabled(index == path.count - 1)
            }
            Spacer()
            if let last = path.last {
                Text(last.cost.money(currency)).font(.callout.monospacedDigit()).foregroundStyle(.secondary)
            }
        }
        .padding(.horizontal, 16)
        .frame(height: 34)
        .background(.bar)
        .overlay(alignment: .bottom) { Divider() }
    }
}

struct ErrorBanner: View {
    let message: String
    var retry: () -> Void

    var body: some View {
        HStack {
            Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange)
            Text("Last refresh failed: \(message) Showing cached data.").lineLimit(2)
            Spacer()
            Button("Retry", action: retry)
        }
        .font(.callout)
        .padding(.horizontal, 16)
        .padding(.vertical, 8)
        .background(.orange.opacity(0.12))
    }
}

struct ExportMenu: View {
    let report: CostReport?
    let view: CostView?

    var body: some View {
        Menu {
            Button("Export \(view?.title ?? "View") as CSV…") { export(kind: .csv) }
            Button("Export Invoice Lines as CSV…") { export(kind: .lines) }
            Button("Export Report as JSON…") { export(kind: .json) }
            Divider()
            Button("Copy Summary") { copySummary() }
        } label: {
            Label("Export", systemImage: "square.and.arrow.up")
        }
        .disabled(report == nil)
    }

    private enum Kind { case csv, lines, json }

    private func export(kind: Kind) {
        guard let report, let view else { return }
        let panel = NSSavePanel()
        let base = "cloud-costs-\(report.period.code)"
        switch kind {
        case .csv: panel.nameFieldStringValue = "\(base)-by-\(view.id).csv"; panel.allowedContentTypes = [.commaSeparatedText]
        case .lines: panel.nameFieldStringValue = "\(base)-lines.csv"; panel.allowedContentTypes = [.commaSeparatedText]
        case .json: panel.nameFieldStringValue = "\(base).json"; panel.allowedContentTypes = [.json]
        }
        guard panel.runModal() == .OK, let url = panel.url else { return }
        let data: Data? = switch kind {
        case .csv: Data(ReportExporter.csv(report, view: view).utf8)
        case .lines: Data(ReportExporter.linesCSV(report).utf8)
        case .json: try? ReportExporter.json(report)
        }
        try? data?.write(to: url)
    }

    private func copySummary() {
        guard let report, let view else { return }
        var lines = ["\(report.period.title): \(report.billed.money(report.currency))"]
        for child in view.root.children {
            lines.append("• \(child.name): \(child.cost.money(report.currency)) (\((child.cost / max(view.root.cost, .ulpOfOne)).percent))")
        }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(lines.joined(separator: "\n"), forType: .string)
    }
}
