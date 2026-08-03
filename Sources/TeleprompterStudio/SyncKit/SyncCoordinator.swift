import Foundation
import MultipeerConnectivity
import Observation
import UIKit

enum PeerConnectionState: String {
    case notConnected, connecting, connected
}

struct PendingInvite: Identifiable {
    let id = UUID()
    let peer: MCPeerID
    let respond: (Bool) -> Void
}

/// Peer-to-peer sync over MultipeerConnectivity: no internet, no login, same Wi-Fi/Bluetooth.
/// Either device can be Director (recording/primary, source of truth for scroll/play-state) or
/// Companion (teleprompter mirror + live monitor + remote). Auto-discovers and auto-reconnects;
/// invitations still require a tap-to-confirm per spec ("confirm before connecting").
@MainActor
@Observable
final class SyncCoordinator: NSObject {
    private static let serviceType = "tpsync" // matches NSBonjourServices in Info.plist

    private let peerID = MCPeerID(displayName: UIDevice.current.name)
    private var session: MCSession!
    private var advertiser: MCNearbyServiceAdvertiser?
    private var browser: MCNearbyServiceBrowser?

    private(set) var role: SyncRole = .director
    private(set) var connectionState: PeerConnectionState = .notConnected
    private(set) var connectedPeers: [MCPeerID] = []
    private(set) var discoveredPeers: [MCPeerID] = []
    var pendingInvite: PendingInvite?

    /// Latest state received from the Director, for Companion UI to render.
    private(set) var latestDocument: PrompterDocument?
    private(set) var latestPlayback: (fraction: Double, isPlaying: Bool, speed: Double, fontSize: Double)?
    private(set) var latestPreviewImage: UIImage?
    private(set) var isPreviewStreamAvailable = true
    private(set) var remoteIsRecording = false
    private(set) var remoteElapsed: TimeInterval = 0

    /// Companion -> Director command callback, wired up by `CameraStudioViewModel`.
    var onRemoteCommand: ((SyncMessage.RemoteCommand) -> Void)?
    var onPeerConnected: ((MCPeerID) -> Void)?
    /// Fired with `true` when the first peer connects and `false` when the last one drops. Studio
    /// uses this to start/stop the expensive frame-streaming machinery instead of running it
    /// unconditionally.
    var onConnectedPeersChanged: ((Bool) -> Void)?

    private var previewSequence: UInt32 = 0

    override init() {
        super.init()
        session = MCSession(peer: peerID, securityIdentity: nil, encryptionPreference: .none)
        session.delegate = self
    }

    func setRole(_ role: SyncRole) {
        self.role = role
        broadcast(.roleAnnounce(role), reliable: true)
    }

    func startHosting() {
        let advertiser = MCNearbyServiceAdvertiser(peer: peerID, discoveryInfo: ["role": role.rawValue], serviceType: Self.serviceType)
        advertiser.delegate = self
        advertiser.startAdvertisingPeer()
        self.advertiser = advertiser

        let browser = MCNearbyServiceBrowser(peer: peerID, serviceType: Self.serviceType)
        browser.delegate = self
        browser.startBrowsingForPeers()
        self.browser = browser
    }

    func stopHosting() {
        advertiser?.stopAdvertisingPeer()
        browser?.stopBrowsingForPeers()
        advertiser = nil
        browser = nil
        session.disconnect()
        connectedPeers = []
        connectionState = .notConnected
    }

    func invite(peer: MCPeerID) {
        browser?.invitePeer(peer, to: session, withContext: nil, timeout: 15)
    }

    // MARK: Director -> Companion outbound state

    func publishDocument(_ document: PrompterDocument, title: String) {
        broadcast(.scriptSync(title: title, markdown: document.markdown, style: SyncStyleSnapshot(document: document)), reliable: true)
    }

    func publishPlayback(fraction: Double, isPlaying: Bool, speedPxPerSec: Double, fontSize: Double) {
        broadcast(.playbackState(fraction: fraction, isPlaying: isPlaying, speedPxPerSec: speedPxPerSec, fontSize: fontSize), reliable: false)
    }

    func publishRecordingState(isRecording: Bool, elapsed: Double) {
        broadcast(.recordingStateChanged(isRecording: isRecording, elapsed: elapsed), reliable: true)
    }

    /// Called by `AdaptivePreviewStreamer` with an already-downscaled/compressed JPEG.
    func publishPreviewFrame(_ jpeg: Data) {
        previewSequence &+= 1
        broadcast(.previewFrame(jpeg: jpeg, sequence: previewSequence), reliable: false)
    }

    func publishPreviewAvailability(_ available: Bool) {
        broadcast(.previewStreamAvailability(available: available), reliable: true)
    }

    // MARK: Companion -> Director commands

    func sendRemoteCommand(_ command: SyncMessage.RemoteCommand) {
        broadcast(.remoteCommand(command), reliable: true)
    }

    // MARK: Internals

    private func broadcast(_ message: SyncMessage, reliable: Bool) {
        guard !session.connectedPeers.isEmpty else { return }
        guard let data = try? JSONEncoder().encode(message) else { return }
        try? session.send(data, toPeers: session.connectedPeers, with: reliable ? .reliable : .unreliable)
    }

    private func handle(_ message: SyncMessage) {
        switch message {
        case .roleAnnounce:
            break // role is user-selected locally; peer role is informational only for now.
        case .scriptSync(let title, let markdown, let style):
            latestDocument = style.asDocument(markdown)
            _ = title
        case .playbackState(let fraction, let isPlaying, let speed, let fontSize):
            latestPlayback = (fraction, isPlaying, speed, fontSize)
        case .remoteCommand(let command):
            onRemoteCommand?(command)
        case .previewFrame(let jpeg, _):
            latestPreviewImage = UIImage(data: jpeg)
        case .recordingStateChanged(let isRecording, let elapsed):
            remoteIsRecording = isRecording
            remoteElapsed = elapsed
        case .previewStreamAvailability(let available):
            isPreviewStreamAvailable = available
        }
    }
}

extension SyncCoordinator: MCSessionDelegate {
    nonisolated func session(_ session: MCSession, peer peerID: MCPeerID, didChange state: MCSessionState) {
        Task { @MainActor in
            let hadPeers = !self.connectedPeers.isEmpty
            switch state {
            case .connected:
                if !self.connectedPeers.contains(peerID) { self.connectedPeers.append(peerID) }
                self.connectionState = .connected
                self.onPeerConnected?(peerID)
            case .connecting:
                self.connectionState = .connecting
            case .notConnected:
                self.connectedPeers.removeAll { $0 == peerID }
                if self.connectedPeers.isEmpty { self.connectionState = .notConnected }
            @unknown default:
                break
            }
            let hasPeers = !self.connectedPeers.isEmpty
            if hasPeers != hadPeers { self.onConnectedPeersChanged?(hasPeers) }
        }
    }

    nonisolated func session(_ session: MCSession, didReceive data: Data, fromPeer peerID: MCPeerID) {
        guard let message = try? JSONDecoder().decode(SyncMessage.self, from: data) else { return }
        Task { @MainActor in self.handle(message) }
    }

    nonisolated func session(_ session: MCSession, didReceive stream: InputStream, withName streamName: String, fromPeer peerID: MCPeerID) {}
    nonisolated func session(_ session: MCSession, didStartReceivingResourceWithName resourceName: String, fromPeer peerID: MCPeerID, with progress: Progress) {}
    nonisolated func session(_ session: MCSession, didFinishReceivingResourceWithName resourceName: String, fromPeer peerID: MCPeerID, at localURL: URL?, withError error: Error?) {}
}

extension SyncCoordinator: MCNearbyServiceAdvertiserDelegate {
    nonisolated func advertiser(
        _ advertiser: MCNearbyServiceAdvertiser,
        didReceiveInvitationFromPeer peerID: MCPeerID,
        withContext context: Data?,
        invitationHandler: @escaping (Bool, MCSession?) -> Void
    ) {
        Task { @MainActor in
            self.pendingInvite = PendingInvite(peer: peerID) { accept in
                invitationHandler(accept, accept ? self.session : nil)
            }
        }
    }
}

extension SyncCoordinator: MCNearbyServiceBrowserDelegate {
    nonisolated func browser(_ browser: MCNearbyServiceBrowser, foundPeer peerID: MCPeerID, withDiscoveryInfo info: [String: String]?) {
        Task { @MainActor in
            if !self.discoveredPeers.contains(peerID) {
                self.discoveredPeers.append(peerID)
            }
        }
    }

    nonisolated func browser(_ browser: MCNearbyServiceBrowser, lostPeer peerID: MCPeerID) {
        Task { @MainActor in
            self.discoveredPeers.removeAll { $0 == peerID }
        }
    }
}
