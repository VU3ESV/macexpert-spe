import SwiftUI
import ExtensionFoundation
import ExtensionKit

/// MacExpert (SPE Expert amplifier control) as a sandboxed, crash-isolated ExtensionKit
/// `.appex` for the Amateur Radio Suite.
///
/// To avoid restructuring this app's SwiftPM package, the Xcode `.appex` target compiles the
/// app's own sources directly (see `Xcode/project.yml`, which includes `../MacExpert` and
/// excludes the standalone `@main` in `MacExpertApp.swift`). The standalone app and its package
/// are unchanged. SwiftPM can't build `.appex` bundles, so this target is built by the Xcode
/// project.
struct MacExpertRootView: View {
    @State private var viewModel = AmplifierViewModel()
    var body: some View {
        ContentView()
            .environment(viewModel)
    }
}

@main
struct MacExpertExtension: AppExtension {
    var configuration: AppExtensionSceneConfiguration {
        AppExtensionSceneConfiguration(
            PrimitiveAppExtensionScene(id: "primary") { MacExpertRootView() }
        )
    }
}
