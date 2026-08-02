import SwiftData
import SwiftUI

struct SettingsView: View {
    @Environment(\.modelContext) private var modelContext
    @Environment(AppState.self) private var appState
    @Query private var allSettings: [AppSettings]

    @State private var showingPeerSheet = false
    @State private var showingCompanionMode = false

    private var settings: AppSettings { AppSettings.current(in: modelContext) }

    var body: some View {
        Form {
            Section("Second Device") {
                Button {
                    showingPeerSheet = true
                } label: {
                    Label("Connect a Device", systemImage: "personalhotspot")
                }
                Button {
                    showingCompanionMode = true
                } label: {
                    Label("Enter Companion Mode", systemImage: "ipad.and.iphone")
                }
                if !appState.syncCoordinator.connectedPeers.isEmpty {
                    ForEach(appState.syncCoordinator.connectedPeers, id: \.self) { peer in
                        Label(peer.displayName, systemImage: "checkmark.circle.fill")
                            .foregroundStyle(Theme.success)
                    }
                }
            }

            Section("Laptop Script Editor") {
                Toggle("Enable LAN Server", isOn: Binding(
                    get: { settings.lanServerEnabled },
                    set: { newValue in
                        settings.lanServerEnabled = newValue
                        try? modelContext.save()
                        if newValue {
                            appState.lanServer.start(port: settings.lanPort, modelContainer: modelContext.container)
                        } else {
                            appState.lanServer.stop()
                        }
                    }
                ))

                if appState.lanServer.isRunning, let url = appState.lanServer.serverURL {
                    VStack(alignment: .leading, spacing: Theme.spacingS) {
                        Text(url)
                            .font(.system(.body, design: .monospaced))
                            .foregroundStyle(Theme.accent)
                        if let qrImage = appState.lanServer.qrCodeImage() {
                            Image(uiImage: qrImage)
                                .interpolation(.none)
                                .resizable()
                                .frame(width: 160, height: 160)
                                .background(Color.white)
                                .cornerRadius(Theme.cornerRadiusSmall)
                        }
                        Text("Open this address in a browser on the same Wi-Fi network to edit scripts from your laptop.")
                            .font(.caption)
                            .foregroundStyle(Theme.textSecondary)
                    }
                    .padding(.vertical, Theme.spacingS)
                } else if let error = appState.lanServer.lastError {
                    Text(error).font(.caption).foregroundStyle(Theme.record)
                }
            }

            Section("Defaults") {
                LabeledSlider(
                    label: "Default Speed",
                    systemImage: "speedometer",
                    value: Binding(
                        get: { settings.defaultSpeedPxPerSec },
                        set: { settings.defaultSpeedPxPerSec = $0; try? modelContext.save() }
                    ),
                    range: 10...400
                ) { "\(Int($0)) px/s" }
                LabeledSlider(
                    label: "Default Font Size",
                    systemImage: "textformat.size",
                    value: Binding(
                        get: { settings.defaultFontSize },
                        set: { settings.defaultFontSize = $0; try? modelContext.save() }
                    ),
                    range: 18...120
                ) { "\(Int($0)) pt" }
            }

            Section("About") {
                LabeledContent("Version", value: "1.0.0")
                Text("Teleprompter Studio is 100% on-device. Device sync and the laptop editor use your local Wi-Fi network only — nothing leaves your network, and no account is required.")
                    .font(.caption)
                    .foregroundStyle(Theme.textSecondary)
            }
        }
        .scrollContentBackground(.hidden)
        .background(Theme.background)
        .navigationTitle("Settings")
        .sheet(isPresented: $showingPeerSheet) {
            PeerDiscoveryView(coordinator: appState.syncCoordinator)
        }
        .fullScreenCover(isPresented: $showingCompanionMode) {
            CompanionView(coordinator: appState.syncCoordinator)
        }
    }
}
