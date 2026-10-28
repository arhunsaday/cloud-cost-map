import CloudCostCore
import Foundation
import Observation

enum ChartStyle: String, CaseIterable, Identifiable {
    case sunburst, treemap, list

    var id: String { rawValue }
    var title: String { rawValue.capitalized }
    var symbol: String {
        switch self {
        case .sunburst: "chart.pie"
        case .treemap: "square.grid.3x3.square"
        case .list: "list.bullet.indent"
        }
    }
}

/// User settings, persisted in UserDefaults as they change.
@MainActor @Observable
final class Preferences {
    private let defaults: UserDefaults

    var monthsToLoad: Int { didSet { defaults.set(monthsToLoad, forKey: "monthsToLoad") } }
    /// Hours between background refreshes; 0 turns it off.
    var refreshIntervalHours: Int { didSet { defaults.set(refreshIntervalHours, forKey: "refreshIntervalHours") } }
    var showsMenuBarExtra: Bool { didSet { defaults.set(showsMenuBarExtra, forKey: "showsMenuBarExtra") } }
    var sunburstRings: Int { didSet { defaults.set(sunburstRings, forKey: "sunburstRings") } }
    var chartStyle: ChartStyle { didSet { defaults.set(chartStyle.rawValue, forKey: "chartStyle") } }
    var viewID: String { didSet { defaults.set(viewID, forKey: "viewID") } }
    var environments: EnvironmentClassifier {
        didSet { defaults.set(try? JSONEncoder().encode(environments), forKey: "environments") }
    }

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        defaults.register(defaults: [
            "monthsToLoad": 6, "refreshIntervalHours": 6, "showsMenuBarExtra": true, "sunburstRings": 3,
            "chartStyle": ChartStyle.sunburst.rawValue, "viewID": CostView.environment,
        ])
        monthsToLoad = defaults.integer(forKey: "monthsToLoad")
        refreshIntervalHours = defaults.integer(forKey: "refreshIntervalHours")
        showsMenuBarExtra = defaults.bool(forKey: "showsMenuBarExtra")
        sunburstRings = defaults.integer(forKey: "sunburstRings")
        chartStyle = ChartStyle(rawValue: defaults.string(forKey: "chartStyle") ?? "") ?? .sunburst
        viewID = defaults.string(forKey: "viewID") ?? CostView.environment
        environments = defaults.data(forKey: "environments")
            .flatMap { try? JSONDecoder().decode(EnvironmentClassifier.self, from: $0) } ?? .default
    }
}
