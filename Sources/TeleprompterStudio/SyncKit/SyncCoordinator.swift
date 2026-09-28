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

/// A device this one has been linked with before. Keyed by its install ID, not its name: two
/// phones can both be called "iPhone", and a renamed phone is still the same phone.
struct KnownPeer: Codable, Hashable, Identifiable {
    let id: String
    var name: String
}

/// Peer-to-peer sync over MultipeerConnectivity: no internet, no login, same Wi-Fi/Bluetooth.
/// Either device can be Director (recording/primary, source of truth for scroll/play-state) or
/// Companion (teleprompter mirror + live monitor + remote).
///
/// **Pair once, then it heals itself.** iOS freezes every app's network links the moment the app
/// leaves the screen, and nothing an app is allowed to do keeps a link alive while it is closed or
/// the phone is locked. What *is* in our hands is how the link comes back, and it used to not come
/// back at all: each launch minted a new peer identity, the other side saw a stranger, and every
/// reconnect needed a fresh invite *and* a tap on "Connect". Now:
/// - this device keeps the same `MCPeerID` across launches (Apple's own advice for MC apps);
/// - devices you have accepted once are remembered, and their invitations are accepted silently;
/// - discovery starts at launch and again whenever the app comes back to the foreground;
/// - one side (picked deterministically, so the two never invite each other at once) re-invites a
///   remembered device as soon as it is seen, and a watchdog keeps retrying until the link is up.
@MainActor
@Observable
final class SyncCoordinator: NSObject {
    private static let serviceType = "tpsync" // matches NSBonjourServices in Info.plist
    private enum Key {
        static let role = "sync.role"
        static let peerID = "sync.peerID"
        static let installID = "sync.installID"
        static let knownPeers = "sync.knownPeers"
        static let autoConnect = "sync.autoConnect"
    }

    private let peerID: MCPeerID
    /// Stable per install; sent in discovery info and invitation context so a remembered device
    /// can be recognised whatever it is called today.
    private let installID: String
    private var session: MCSession!
    private var advertiser: MCNearbyServiceAdvertiser?
    private var browser: MCNearbyServiceBrowser?

    private(set) var role: SyncRole = .director
    /// The role the other device announced. Announcements are re-sent whenever a peer connects,
    /// because a role is always chosen *before* there is anyone to tell — the first announce
    /// (sent from `setRole`) has no peers and is dropped by design.
    private(set) var peerRole: SyncRole?
    private(set) var connectionState: PeerConnectionState = .notConnected
    private(set) var connectedPeers: [MCPeerID] = []
    private(set) var discoveredPeers: [MCPeerID] = []
    /// Whether this device is currently advertising itself and browsing for others. Published
    /// because more than one screen turns discovery on, and a stale local toggle that says "off"
    /// while the advertiser is running will happily shut down a working connection.
    private(set) var isHosting = false
    var pendingInvite: PendingInvite?

    /// Devices accepted before. Their invitations skip the confirmation alert.
    private(set) var knownPeers: [KnownPeer] = []
    /// The name of the device we were last linked to, kept after the link drops so the UI can say
    /// "Reconnecting to Ahmed's iPad…" instead of starting over from "Looking for a Director".
    private(set) var lastPeerName: String?

    var hasConnectedPeers: Bool { !connectedPeers.isEmpty }
    var isReconnecting: Bool { !hasConnectedPeers && lastPeerName != nil && isHosting }

    var localDeviceName: String { peerID.displayName }

    /// Latest state received from the Director, for Companion UI to render. Deliberately kept
    /// when the link drops: the reader keeps their script on screen while it heals.
    private(set) var latestDocument: PrompterDocument?
    private(set) var latestPlayback: (fraction: Double, isPlaying: Bool, speed: Double, fontSize: Double)?
    private(set) var latestPreviewImage: UIImage?
    private(set) var isPreviewStreamAvailable = true
    private(set) var remoteIsRecording = false
    /// When the Director's current take started, in this device's clock. The Director only says
    /// "recording, N seconds in" when a take starts or a link comes up; the Companion's timer
    /// counts from here instead of sitting on 0:00 for the whole take.
    private(set) var remoteRecordingStartedAt: Date?

    /// Companion -> Director command callback, wired up by `CameraStudioViewModel`.
    var onRemoteCommand: ((SyncMessage.RemoteCommand) -> Void)?
    var onPeerConnected: ((MCPeerID) -> Void)?
    /// Fired with `true` when the first peer connects and `false` when the last one drops. Studio
    /// uses this to start/stop the expensive frame-streaming machinery instead of running it
    /// unconditionally.
    var onConnectedPeersChanged: ((Bool) -> Void)?

    private var previewSequence: UInt32 = 0
    /// Install IDs of peers as they were discovered or as they introduced themselves.
    private var peerInstallIDs: [MCPeerID: String] = [:]
    /// Last automatic invite per install ID, so a slow handshake isn't trampled by a second one.
    private var lastAutoInvite: [String: Date] = [:]
    private var watchdog: Timer?
    private var watchdogTicks = 0
    /// Script pictures each connected peer already holds, so republishing a script only sends
    /// what's new.
    private var imagesSent: [MCPeerID: Set<String>] = [:]
    private var documentSendTask: Task<Void, Never>?

    override init() {
        let defaults = UserDefaults.standard
        installID = defaults.string(forKey: Key.installID) ?? {
            let fresh = UUID().uuidString
            defaults.set(fresh, forKey: Key.installID)
            return fresh
        }()
        peerID = Self.loadOrCreatePeerID()
        super.init()
        session = makeSession()
        if let stored = defaults.string(forKey: Key.role), let storedRole = SyncRole(rawValue: stored) {
            role = storedRole
        }
        if let data = defaults.data(forKey: Key.knownPeers),
           let peers = try? JSONDecoder().decode([KnownPeer].self, from: data) {
            knownPeers = peers
        }
    }

    /// Reuses the archived peer ID while the device name is unchanged. A fresh `MCPeerID` per
    /// launch is what made the other side see a new, unknown device after every relaunch.
    private static func loadOrCreatePeerID() -> MCPeerID {
        let name = UIDevice.current.name
        if let data = UserDefaults.standard.data(forKey: Key.peerID),
           let stored = try? NSKeyedUnarchiver.unarchivedObject(ofClass: MCPeerID.self, from: data),
           stored.displayName == name {
            return stored
        }
        let fresh = MCPeerID(displayName: name)
        if let data = try? NSKeyedArchiver.archivedData(withRootObject: fresh, requiringSecureCoding: true) {
            UserDefaults.standard.set(data, forKey: Key.peerID)
        }
        return fresh
    }

    private func makeSession() -> MCSession {
        let session = MCSession(peer: peerID, securityIdentity: nil, encryptionPreference: .none)
        session.delegate = self
        return session
    }

    func setRole(_ role: SyncRole) {
        self.role = role
        UserDefaults.standard.set(role.rawValue, forKey: Key.role)
        announceRole()
    }

    private func announceRole() {
        broadcast(.roleAnnounce(role), reliable: true)
    }

    // MARK: Lifecycle

    /// Whether this device should look for its remembered peers without being asked: it has been
    /// paired before, and the user hasn't switched discovery off.
    private var shouldAutoConnect: Bool {
        !knownPeers.isEmpty && UserDefaults.standard.object(forKey: Key.autoConnect) as? Bool ?? true
    }

    /// Called once at launch: a paired device starts looking for its partner straight away, so
    /// opening the app is all it takes to get the link back.
    func resumeIfPaired() {
        if shouldAutoConnect { startHosting() }
    }

    /// The app came back to the foreground. iOS tore the radios down while we were away, and the
    /// advertiser/browser pair doesn't always notice; restarting them is what makes the other
    /// device reappear within seconds instead of never.
    func appBecameActive() {
        guard isHosting || shouldAutoConnect else { return }
        if isHosting, hasConnectedPeers { return }
        restartDiscovery()
    }

    private func restartDiscovery() {
        stopDiscovery()
        if session.connectedPeers.isEmpty {
            // An MCSession that lost its peer while suspended can be left half-open, quietly
            // refusing new connections. A fresh one costs nothing when nobody is connected.
            session.disconnect()
            session = makeSession()
        }
        startDiscovery()
    }

    /// Idempotent: safe to call from every screen that needs the two devices to be able to find
    /// each other. Entering Companion mode used to start nothing at all, so a device that hadn't
    /// first visited "Connect a Device" sat on "Waiting for Director…" forever with no advertiser
    /// and no browser running.
    func startHosting() {
        UserDefaults.standard.set(true, forKey: Key.autoConnect)
        guard !isHosting else { return }
        startDiscovery()
    }

    /// The user switched discovery off. Also stops the automatic reconnect until it's back on.
    func stopHosting() {
        UserDefaults.standard.set(false, forKey: Key.autoConnect)
        let hadPeers = hasConnectedPeers
        stopDiscovery()
        session.disconnect()
        connectedPeers = []
        discoveredPeers = []
        peerRole = nil
        lastPeerName = nil
        imagesSent = [:]
        connectionState = .notConnected
        if hadPeers { onConnectedPeersChanged?(false) }
    }

    private func startDiscovery() {
        let advertiser = MCNearbyServiceAdvertiser(
            peer: peerID,
            discoveryInfo: ["role": role.rawValue, "id": installID],
            serviceType: Self.serviceType
        )
        advertiser.delegate = self
        advertiser.startAdvertisingPeer()
        self.advertiser = advertiser

        let browser = MCNearbyServiceBrowser(peer: peerID, serviceType: Self.serviceType)
        browser.delegate = self
        browser.startBrowsingForPeers()
        self.browser = browser

        isHosting = true
        startWatchdog()
    }

    private func stopDiscovery() {
        advertiser?.stopAdvertisingPeer()
        browser?.stopBrowsingForPeers()
        advertiser = nil
        browser = nil
        discoveredPeers = []
        watchdog?.invalidate()
        watchdog = nil
        isHosting = false
    }

    /// While a remembered device is out of reach: retry the invite every few seconds, and every
    /// half-minute restart discovery outright, since a browser that missed the peer's return
    /// won't report it again on its own.
    private func startWatchdog() {
        watchdog?.invalidate()
        watchdogTicks = 0
        watchdog = Timer.scheduledTimer(withTimeInterval: 5, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.watchdogTick() }
        }
    }

    private func watchdogTick() {
        guard isHosting, !knownPeers.isEmpty else { return }
        guard !hasConnectedPeers else {
            watchdogTicks = 0
            return
        }
        watchdogTicks += 1
        if watchdogTicks % 6 == 0 {
            restartDiscovery()
            return
        }
        for peer in discoveredPeers { autoInviteIfKnown(peer) }
    }

    // MARK: Pairing

    func invite(peer: MCPeerID) {
        startHosting() // inviting without a browser silently does nothing
        browser?.invitePeer(peer, to: session, withContext: Data(installID.utf8), timeout: 15)
    }

    func isKnown(_ peer: MCPeerID) -> Bool {
        guard let id = peerInstallIDs[peer] else { return false }
        return knownPeers.contains { $0.id == id }
    }

    func forget(_ known: KnownPeer) {
        knownPeers.removeAll { $0.id == known.id }
        saveKnownPeers()
        // Drop a live link to it too: "Forget" that leaves the device connected isn't forgetting.
        let linked = connectedPeers.filter { peerInstallIDs[$0] == known.id }
        if !linked.isEmpty {
            session.disconnect()
            session = makeSession()
        }
    }

    private func remember(_ peer: MCPeerID) {
        guard let id = peerInstallIDs[peer] else { return }
        if let index = knownPeers.firstIndex(where: { $0.id == id }) {
            knownPeers[index].name = peer.displayName
        } else {
            knownPeers.append(KnownPeer(id: id, name: peer.displayName))
        }
        saveKnownPeers()
    }

    private func saveKnownPeers() {
        if let data = try? JSONEncoder().encode(knownPeers) {
            UserDefaults.standard.set(data, forKey: Key.knownPeers)
        }
    }

    /// Only the device with the lower install ID invites. If both did, the two invitations would
    /// cross in flight and MultipeerConnectivity would drop both.
    private func autoInviteIfKnown(_ peer: MCPeerID) {
        guard let id = peerInstallIDs[peer],
              knownPeers.contains(where: { $0.id == id }),
              !connectedPeers.contains(where: { peerInstallIDs[$0] == id }),
              installID < id
        else { return }
        if let last = lastAutoInvite[id], Date().timeIntervalSince(last) < 12 { return }
        lastAutoInvite[id] = Date()
        browser?.invitePeer(peer, to: session, withContext: Data(installID.utf8), timeout: 10)
    }

    // MARK: Invitation presenters

    /// An incoming invitation has to be confirmed by a tap, and the confirmation used to live
    /// *only* on the "Connect a Device" sheet. Invite someone who is sitting in Companion mode (or
    /// in Studio) and the alert had nowhere to appear, so the connection could never complete and
    /// the whole feature looked broken. Screens register themselves here instead; the most recently
    /// presented one owns the alert, so it always lands on top of whatever is actually on screen.
    private(set) var invitePresenters: [UUID] = []

    func registerInvitePresenter(_ id: UUID) {
        guard !invitePresenters.contains(id) else { return }
        invitePresenters.append(id)
    }

    func unregisterInvitePresenter(_ id: UUID) {
        invitePresenters.removeAll { $0 == id }
    }

    func isTopInvitePresenter(_ id: UUID) -> Bool {
        invitePresenters.last == id
    }

    func respondToPendingInvite(accept: Bool) {
        let invite = pendingInvite
        pendingInvite = nil
        invite?.respond(accept)
    }

    // MARK: Director -> Companion outbound state

    /// Sends the script, preceded by any of its pictures the other side doesn't have yet. The
    /// pictures go first so the Companion typesets the script once, with them in place — a script
    /// that arrived before its pictures would have been laid out without them.
    func publishDocument(_ document: PrompterDocument, title: String) {
        let peers = session.connectedPeers
        guard !peers.isEmpty else { return }
        let imageIDs = Set(ScriptImageMarkup.matches(in: document.markdown).map(\.id))
        documentSendTask?.cancel()
        documentSendTask = Task { @MainActor [weak self] in
            guard let self else { return }
            for peer in peers {
                let missing = imageIDs.subtracting(self.imagesSent[peer] ?? [])
                for id in missing.sorted() {
                    guard !Task.isCancelled else { return }
                    guard let url = ScriptImageStore.url(for: id),
                          FileManager.default.fileExists(atPath: url.path)
                    else { continue }
                    if await self.sendResource(url, named: SyncMessage.imageResourcePrefix + id, to: peer) {
                        self.imagesSent[peer, default: []].insert(id)
                    }
                }
            }
            guard !Task.isCancelled else { return }
            self.broadcast(.scriptSync(title: title, markdown: document.markdown, style: SyncStyleSnapshot(document: document)), reliable: true)
        }
    }

    private func sendResource(_ url: URL, named name: String, to peer: MCPeerID) async -> Bool {
        guard session.connectedPeers.contains(peer) else { return false }
        let session = self.session!
        return await withCheckedContinuation { continuation in
            // MC may or may not call the completion when it refuses to start a transfer; either
            // way the continuation must resume exactly once.
            let once = ResumeOnce(continuation)
            let progress = session.sendResource(at: url, withName: name, toPeer: peer) { error in
                once.resume(error == nil)
            }
            if progress == nil { once.resume(false) }
        }
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
        case .roleAnnounce(let announced):
            peerRole = announced
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
            remoteRecordingStartedAt = isRecording ? Date().addingTimeInterval(-elapsed) : nil
        case .previewStreamAvailability(let available):
            isPreviewStreamAvailable = available
        }
    }

    private func peerStateChanged(_ peerID: MCPeerID, _ state: MCSessionState, in changedSession: MCSession) {
        // Callbacks from a session we've already replaced describe a link that no longer exists.
        guard changedSession === session else { return }
        let hadPeers = !connectedPeers.isEmpty
        switch state {
        case .connected:
            if !connectedPeers.contains(peerID) { connectedPeers.append(peerID) }
            connectionState = .connected
            lastPeerName = peerID.displayName
            remember(peerID)
            announceRole()
            onPeerConnected?(peerID)
        case .connecting:
            if connectedPeers.isEmpty { connectionState = .connecting }
        case .notConnected:
            connectedPeers.removeAll { $0 == peerID }
            imagesSent[peerID] = nil
            if connectedPeers.isEmpty {
                connectionState = .notConnected
                peerRole = nil
                // A Director that vanished mid-take can't tell us the take ended.
                remoteIsRecording = false
                remoteRecordingStartedAt = nil
            }
            // Try again straight away rather than waiting for the watchdog.
            if discoveredPeers.contains(peerID) { autoInviteIfKnown(peerID) }
        @unknown default:
            break
        }
        let hasPeers = !connectedPeers.isEmpty
        if hasPeers != hadPeers { onConnectedPeersChanged?(hasPeers) }
    }

    private func receiveInvitation(from peer: MCPeerID, context: Data?, handler: @escaping (Bool, MCSession?) -> Void) {
        if let context, let id = String(data: context, encoding: .utf8), !id.isEmpty {
            peerInstallIDs[peer] = id
        }
        if isKnown(peer) {
            // Paired before: no alert, the link just comes back.
            handler(true, session)
            return
        }
        let session = self.session!
        pendingInvite = PendingInvite(peer: peer) { accept in
            handler(accept, accept ? session : nil)
        }
    }
}

extension SyncCoordinator: MCSessionDelegate {
    nonisolated func session(_ session: MCSession, peer peerID: MCPeerID, didChange state: MCSessionState) {
        Task { @MainActor in self.peerStateChanged(peerID, state, in: session) }
    }

    nonisolated func session(_ session: MCSession, didReceive data: Data, fromPeer peerID: MCPeerID) {
        guard let message = try? JSONDecoder().decode(SyncMessage.self, from: data) else { return }
        Task { @MainActor in self.handle(message) }
    }

    nonisolated func session(_ session: MCSession, didReceive stream: InputStream, withName streamName: String, fromPeer peerID: MCPeerID) {}
    nonisolated func session(_ session: MCSession, didStartReceivingResourceWithName resourceName: String, fromPeer peerID: MCPeerID, with progress: Progress) {}

    /// A script picture from the Director. Moved into place here, synchronously: MC deletes the
    /// temporary file as soon as this returns.
    nonisolated func session(_ session: MCSession, didFinishReceivingResourceWithName resourceName: String, fromPeer peerID: MCPeerID, at localURL: URL?, withError error: Error?) {
        guard error == nil, let localURL, resourceName.hasPrefix(SyncMessage.imageResourcePrefix) else { return }
        let id = String(resourceName.dropFirst(SyncMessage.imageResourcePrefix.count))
        // `url(for:)` only accepts IDs this app could have generated, so a peer can't use the
        // name to write outside the pictures folder.
        guard let destination = ScriptImageStore.url(for: id) else { return }
        let fileManager = FileManager.default
        try? fileManager.createDirectory(at: ScriptImageStore.directory, withIntermediateDirectories: true)
        try? fileManager.removeItem(at: destination)
        try? fileManager.moveItem(at: localURL, to: destination)
    }
}

extension SyncCoordinator: MCNearbyServiceAdvertiserDelegate {
    nonisolated func advertiser(
        _ advertiser: MCNearbyServiceAdvertiser,
        didReceiveInvitationFromPeer peerID: MCPeerID,
        withContext context: Data?,
        invitationHandler: @escaping (Bool, MCSession?) -> Void
    ) {
        Task { @MainActor in
            self.receiveInvitation(from: peerID, context: context, handler: invitationHandler)
        }
    }
}

extension SyncCoordinator: MCNearbyServiceBrowserDelegate {
    nonisolated func browser(_ browser: MCNearbyServiceBrowser, foundPeer peerID: MCPeerID, withDiscoveryInfo info: [String: String]?) {
        let id = info?["id"]
        Task { @MainActor in
            guard browser === self.browser else { return }
            if let id { self.peerInstallIDs[peerID] = id }
            // One row per device: a peer that relaunched can be reported again before the old
            // entry is lost.
            self.discoveredPeers.removeAll { $0.displayName == peerID.displayName && $0 != peerID }
            if !self.discoveredPeers.contains(peerID) {
                self.discoveredPeers.append(peerID)
            }
            self.autoInviteIfKnown(peerID)
        }
    }

    nonisolated func browser(_ browser: MCNearbyServiceBrowser, lostPeer peerID: MCPeerID) {
        Task { @MainActor in
            self.discoveredPeers.removeAll { $0 == peerID }
        }
    }
}

private final class ResumeOnce: @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: CheckedContinuation<Bool, Never>?

    init(_ continuation: CheckedContinuation<Bool, Never>) {
        self.continuation = continuation
    }

    func resume(_ value: Bool) {
        lock.lock()
        let pending = continuation
        continuation = nil
        lock.unlock()
        pending?.resume(returning: value)
    }
}
