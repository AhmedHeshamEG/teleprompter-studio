import MultipeerConnectivity
import SwiftUI

/// Shown from Settings/Studio to pick a role and connect to a nearby device. No pairing codes:
/// same-LAN devices simply show up, and the user taps to invite/accept.
struct PeerDiscoveryView: View {
    let coordinator: SyncCoordinator
    @Environment(\.dismiss) private var dismiss
    @State private var isHosting = false

    var body: some View {
        NavigationStack {
            List {
                Section("This Device's Role") {
                    Picker("Role", selection: Binding(
                        get: { coordinator.role },
                        set: { coordinator.setRole($0) }
                    )) {
                        Text("Director (camera + control)").tag(SyncRole.director)
                        Text("Companion (mirror + remote)").tag(SyncRole.companion)
                    }
                    .pickerStyle(.inline)
                }

                Section {
                    Toggle("Discoverable on this Wi-Fi network", isOn: $isHosting)
                        .onChange(of: isHosting) { _, newValue in
                            newValue ? coordinator.startHosting() : coordinator.stopHosting()
                        }
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
                            Label(peer.displayName, systemImage: "checkmark.circle.fill")
                                .foregroundStyle(Theme.success)
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
            .alert(
                "Connect with \(coordinator.pendingInvite?.peer.displayName ?? "device")?",
                isPresented: Binding(
                    get: { coordinator.pendingInvite != nil },
                    set: { if !$0 { coordinator.pendingInvite = nil } }
                )
            ) {
                Button("Decline", role: .cancel) {
                    coordinator.pendingInvite?.respond(false)
                    coordinator.pendingInvite = nil
                }
                Button("Connect") {
                    coordinator.pendingInvite?.respond(true)
                    coordinator.pendingInvite = nil
                }
            }
        }
        .preferredColorScheme(.dark)
        .onAppear {
            isHosting = true
            coordinator.startHosting()
        }
    }
}
