import SwiftUI

/// Presents the "confirm before connecting" invitation alert wherever the user actually is.
///
/// Connecting two devices requires the invited side to accept, and that acceptance used to be
/// reachable only from the "Connect a Device" sheet. Anyone invited while sitting in Companion
/// mode, in Studio, or anywhere else in the app simply never saw the prompt — the invitation timed
/// out, no peer ever connected, and Director/Companion looked dead.
///
/// Every full-screen context applies this modifier. The coordinator keeps a stack of registered
/// presenters and only the top one presents, so exactly one alert appears and it appears on the
/// screen that's actually visible.
private struct PeerInviteAlert: ViewModifier {
    let coordinator: SyncCoordinator
    @State private var id = UUID()

    func body(content: Content) -> some View {
        content
            .onAppear { coordinator.registerInvitePresenter(id) }
            .onDisappear { coordinator.unregisterInvitePresenter(id) }
            .alert(
                "Connect with \(coordinator.pendingInvite?.peer.displayName ?? "device")?",
                isPresented: Binding(
                    get: { coordinator.pendingInvite != nil && coordinator.isTopInvitePresenter(id) },
                    set: { if !$0 { coordinator.respondToPendingInvite(accept: false) } }
                )
            ) {
                Button("Decline", role: .cancel) { coordinator.respondToPendingInvite(accept: false) }
                Button("Connect") { coordinator.respondToPendingInvite(accept: true) }
            } message: {
                Text("This device will mirror the script, scroll position and camera monitor over your local network.")
            }
    }
}

extension View {
    func peerInviteAlert(coordinator: SyncCoordinator) -> some View {
        modifier(PeerInviteAlert(coordinator: coordinator))
    }
}
