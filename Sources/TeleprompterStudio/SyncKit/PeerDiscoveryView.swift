import MultipeerConnectivity
import SwiftUI

/// Shown from Settings/Studio to pick a role and connect to a nearby device. No pairing codes:
/// same-LAN devices simply show up, and the user taps to invite/accept.
struct PeerDiscoveryView: View {
    let coordinator: SyncCoordinator
    @Environment(\.dismiss) private var dismiss
    @State private var showingCompanionMode = false

    var body: some View {
        NavigationStack {
            List {
                Section {
                    Picker("Role", selection: Binding(
                        get: { coordinator.role },
                        set: { coordinator.setRole($0) }
                    )) {
                        Text("Director (camera + control)").tag(SyncRole.director)
                        Text("Companion (mirror + remote)").tag(SyncRole.companion)
                    }
                    .pickerStyle(.inline)

                    // Picking a role used to change nothing you could see. Each role now has the
                    // one action that role actually needs, right here.
                    if coordinator.role == .companion {
                        Button {
                            showingCompanionMode = true
                        } label: {
                            Label("Open Companion Screen", systemImage: "ipad.and.iphone")
                        }
                    }
                } header: {
                    Text("This Device's Role")
                } footer: {
                    Text(coordinator.role == .director
                         ? "Director records and controls. Open a script and tap Go Live — the Companion mirrors this device's script, scroll position and camera."
                         : "Companion mirrors the Director's script and camera, and can start/stop the take remotely.")
                }

                Section {
                    Toggle("Discoverable on this Wi-Fi network", isOn: Binding(
                        // Bound to the coordinator, not to local view state: a fresh @State toggle
                        // reopened as "off" while discovery was actually running, and flipping it
                        // tore down a working connection.
                        get: { coordinator.isHosting },
                        set: { $0 ? coordinator.startHosting() : coordinator.stopHosting() }
                    ))
                    LabeledContent("This Device", value: coordinator.localDeviceName)
                    LabeledContent("Status", value: statusText)
                } footer: {
                    Text("Uses Wi-Fi/Bluetooth on your local network only. No internet connection or account required.")
                }

                if !coordinator.discoveredPeers.isEmpty {
                    Section("Nearby Devices") {
                        ForEach(coordinator.discoveredPeers, id: \.self) { peer in
                            Button {
                                coordinator.invite(peer: peer)
                            } label: {
                                HStack {
                                    Image(systemName: "ipad.and.iphone")
                                    Text(peer.displayName)
                                    Spacer()
                                    if coordinator.connectedPeers.contains(peer) {
                                        Badge(text: "Connected", color: Theme.success, filled: true)
                                    }
                                }
                            }
                        }
                    }
                }

                if !coordinator.connectedPeers.isEmpty {
                    Section("Connected") {
                        ForEach(coordinator.connectedPeers, id: \.self) { peer in
                            HStack {
                                Label(peer.displayName, systemImage: "checkmark.circle.fill")
                                    .foregroundStyle(Theme.success)
                                Spacer()
                                if let peerRole = coordinator.peerRole {
                                    Badge(text: peerRole == .director ? "Director" : "Companion", color: Theme.accent)
                                }
                            }
                        }
                    }
                }
            }
            .scrollContentBackground(.hidden)
            .background(Theme.background)
            .navigationTitle("Connect a Device")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
            }
        }
        .preferredColorScheme(.dark)
        .peerInviteAlert(coordinator: coordinator)
        .fullScreenCover(isPresented: $showingCompanionMode) {
            CompanionView(coordinator: coordinator)
        }
        .onAppear {
            coordinator.startHosting()
        }
    }

    private var statusText: String {
        switch coordinator.connectionState {
        case .connected: return "Connected"
        case .connecting: return "Connecting…"
        case .notConnected: return coordinator.isHosting ? "Looking for devices…" : "Off"
        }
    }
}
