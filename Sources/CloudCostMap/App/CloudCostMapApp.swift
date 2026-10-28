import AppKit
import CloudCostCore
import SwiftUI

@main
struct CloudCostMapApp: App {
    @NSApplicationDelegateAdaptor private var delegate: AppDelegate
    @State private var preferences: Preferences
    @State private var model: AppModel

    init() {
        let preferences = Preferences()
        _preferences = State(initialValue: preferences)
        _model = State(initialValue: AppModel(preferences: preferences))
    }

    var body: some Scene {
        Window("Cloud Cost Map", id: "main") {
            ContentView()
                .environment(model)
                .environment(preferences)
                .frame(minWidth: 960, minHeight: 620)
                .task { model.startAutoRefresh() }
        }
        .defaultSize(width: 1280, height: 820)
        .commands { AppCommands(model: model, preferences: preferences) }

        Settings {
            SettingsView()
                .environment(model)
                .environment(preferences)
        }

        MenuBarExtra(isInserted: $preferences.showsMenuBarExtra) {
            MenuBarView()
                .environment(model)
                .environment(preferences)
        } label: {
            MenuBarLabel().environment(model)
        }
        .menuBarExtraStyle(.window)
    }
}

/// When launched as a bare executable (`swift run`) the process is not a
/// bundled app and would start without a Dock icon or focus.
final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.regular)
        NSApp.activate()
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }
}

struct AppCommands: Commands {
    let model: AppModel
    @Bindable var preferences: Preferences

    var body: some Commands {
        CommandGroup(after: .newItem) {
            Button("Add Account…") { model.isAddingAccount = true }
                .keyboardShortcut("n")
        }
        CommandGroup(before: .toolbar) {
            Picker("Chart", selection: $preferences.chartStyle) {
                ForEach(Array(ChartStyle.allCases.enumerated()), id: \.element) { index, style in
                    Text(style.title).keyboardShortcut(KeyEquivalent(Character("\(index + 1)")), modifiers: .command)
                }
            }
            .pickerStyle(.inline)
            Divider()
            Button("Refresh") {
                Task {
                    if let id = model.selectedAccount?.id { await model.refresh(id) } else { await model.refreshAll() }
                }
            }
            .keyboardShortcut("r")
            Button("Refresh All Accounts") { Task { await model.refreshAll() } }
                .keyboardShortcut("r", modifiers: [.command, .shift])
            Divider()
        }
    }
}
