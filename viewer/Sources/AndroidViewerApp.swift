import SwiftUI

@main
struct AndroidViewerApp: App {
    @StateObject private var settings = ViewerSettings()

    var body: some Scene {
        WindowGroup {
            RootView()
                .environmentObject(settings)
        }
    }
}

struct RootView: View {
    @EnvironmentObject private var settings: ViewerSettings

    var body: some View {
        if settings.isConfigured && !settings.showSetup {
            ViewerView()
        } else {
            SetupView()
        }
    }
}
