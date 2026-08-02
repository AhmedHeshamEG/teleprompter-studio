import Foundation
import Observation

/// Cross-cutting, app-lifetime singletons that many screens need a handle to: the sync
/// coordinator (MultipeerConnectivity) and the LAN HTTP server. Kept separate from SwiftUI
/// environment @Model queries so views can opt in only where relevant.
@Observable
@MainActor
final class AppState {
    let syncCoordinator = SyncCoordinator()
    let lanServer = LANHTTPServer()

    /// Set while a Studio (camera + prompter) session is active, so other parts of the UI
    /// (e.g. tab bar) can react.
    var isStudioActive: Bool = false

    init() {}
}
