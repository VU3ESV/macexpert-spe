import SwiftUI

/// The per-app part of UpdateChecker.swift (that file is identical in every
/// VU2CPL app — see its header). Both live only in the standalone app: the
/// Suite plugin target excludes them (Xcode/project.yml).
extension UpdateChecker.Configuration {
    static let app = UpdateChecker.Configuration(
        repository: "vu2cpl/macexpert-spe", appName: "MacExpert")
}

@main
struct MacExpertApp: App {
    @State private var viewModel = AmplifierViewModel()

    init() {
        // About 10 s from now: ask GitHub whether a newer release exists
        // (at most once a day; the toggle is in the app menu).
        UpdateChecker.shared.scheduleAutomaticCheck()
    }

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environment(viewModel)
        }
        .windowStyle(.titleBar)
        .defaultSize(width: 400, height: 580)
        .commands {
            // No settings window in this app, so the automatic-check toggle
            // sits in the app menu next to Check for Updates…
            CommandGroup(after: .appInfo) {
                UpdateChecker.CheckButton()
                UpdateChecker.AutomaticToggle()
            }
        }
    }
}
