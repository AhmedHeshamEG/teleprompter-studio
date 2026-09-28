import SwiftUI
import SwiftData

struct RootView: View {
    @State private var appState = AppState()
    @Environment(\.modelContext) private var modelContext
    @Environment(\.scenePhase) private var scenePhase
    /// Set while the Companion screen is up (see `CompanionView`). A device that was a Companion
    /// when the app was closed goes straight back to being one when it's reopened.
    @AppStorage(CompanionView.resumeKey) private var resumeCompanion = false
    @State private var showingResumedCompanion = false

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
        .fullScreenCover(isPresented: $showingResumedCompanion) {
            CompanionView(coordinator: appState.syncCoordinator)
        }
        .onChange(of: scenePhase) { _, phase in
            if phase == .active { appState.syncCoordinator.appBecameActive() }
        }
        .onAppear {
            appState.syncCoordinator.resumeIfPaired()
            if resumeCompanion { showingResumedCompanion = true }
            let settings = AppSettings.current(in: modelContext)
            if settings.lanServerEnabled {
                appState.lanServer.start(port: settings.lanPort, modelContainer: modelContext.container)
            }
        }
    }
}
