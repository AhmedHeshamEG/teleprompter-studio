import SwiftUI
import SwiftData

struct RootView: View {
    @State private var appState = AppState()
    @Environment(\.modelContext) private var modelContext

    var body: some View {
        TabView {
            NavigationStack {
                ScriptLibraryView()
            }
            .tabItem { Label("Scripts", systemImage: "doc.text") }

            NavigationStack {
                SettingsView()
            }
            .tabItem { Label("Settings", systemImage: "gearshape") }
        }
        .tint(Theme.accent)
        .environment(appState)
        .preferredColorScheme(.dark)
        // Base presenter for incoming connection requests, so an invitation is answerable from
        // anywhere in the app rather than only while the "Connect a Device" sheet happens to be up.
        .peerInviteAlert(coordinator: appState.syncCoordinator)
        .onAppear {
            let settings = AppSettings.current(in: modelContext)
            if settings.lanServerEnabled {
                appState.lanServer.start(port: settings.lanPort, modelContainer: modelContext.container)
            }
        }
    }
}
