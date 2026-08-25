//
//  NetworkManager.swift
//
//  Why this file exists:
//    This is the radio. The app and CLI never touch NWListener / NWBrowser.
//    They create one NetworkManager and call start / connect / send / stop.
//
//  What it does:
//    • Advertises this Mac and browses for others on `_bluecomms._tcp`
//      in domain `local.` (nil domain was unreliable).
//    • includePeerToPeer = true turns on AWDL (AirDrop-class; no shared
//      Wi-Fi AP required). Same radio as AirDrop — if AirDrop cannot see
//      the other Mac, neither can we.
//    • One TCP session per peer id (PR #4). Pending connections live in
//      `pending` until handshake; then they move to `sessions`.
//    • All mutation is on `queue`. Callers hop in via start/connect/send.
//    • Failed/waiting listener or browser restarts with backoff (PR #1).
//    • Filters our own Bonjour row so we do not connect to ourselves.
//

import Foundation
import Network

/// A Bonjour result we can actually talk to (must have a device-id TXT record).
public struct DiscoveredPeer: Sendable, Equatable {
    /// Device UUID string from TXT `id`. Stable across Bonjour name changes.
    public let id: String
    public let displayName: String
    /// Full advertised name, including the short-id suffix.
    public let bonjourName: String
    /// Where to open TCP. Comes from the browse result.
    public let endpoint: NWEndpoint
}

/// Advertise + browse `_bluecomms._tcp` with `includePeerToPeer` (AWDL).
/// All mutation happens on `queue`. Callers hop in via start/connect/send.
public final class NetworkManager: @unchecked Sendable {
    static let serviceType = "_bluecomms._tcp"
    static let serviceDomain = "local."

    private let queue: DispatchQueue
    private let queueKey = DispatchSpecificKey<UInt8>()
    private let identity: DeviceIdentity
    private let store: IdentityStore

    private var listener: NWListener?
    private var browser: NWBrowser?
    private var sessions: [String: PeerConnection] = [:]
    private var pending: [UUID: PeerConnection] = [:]
    private var lastPeerID: String?
    private var discoveredByID: [String: DiscoveredPeer] = [:]
    private var lastSeenAt: [String: Date] = [:]
    private var isStopping = false
    private var restartWork: DispatchWorkItem?
    private var restartAttempt = 0
    private var restartScheduled = false

    /// Bonjour list changed. Already hopped to main.
    public var onPeersUpdated: (([DiscoveredPeer]) -> Void)?
    /// CLI: any session became ready. Prefer onSecureSession in the app.
    public var onConnectionEstablished: (() -> Void)?
    /// Handshake finished with this peer id.
    public var onSecureSession: ((UUID) -> Void)?
    /// CLI: some session died. Prefer onPeerDisconnected in the app.
    public var onDisconnected: (() -> Void)?
    public var onPeerDisconnected: ((UUID) -> Void)?
    /// CLI: inbound chat with no peer id. App uses onMessageFromPeer.
    public var onMessageReceived: ((String) -> Void)?
    public var onMessageFromPeer: ((UUID, String) -> Void)?
    public var onFileTransfer: ((UUID, FileTransferUpdate) -> Void)?
    public var onLog: ((String) -> Void)?

    public var deviceID: UUID { identity.id }
    public var deviceName: String { identity.displayName }
    public var shortID: String { identity.shortID }
    public var fingerprint: String { identity.fingerprint }

    public var isConnected: Bool {
        onQueueSync { sessions.values.contains(where: \.isReadyForMessages) }
    }

    public func isConnected(to peerID: String) -> Bool {
        onQueueSync { sessions[peerID]?.isReadyForMessages == true }
    }

    public func lastSeen(of peerID: String) -> Date? {
        onQueueSync { lastSeenAt[peerID] }
    }

    public var connectedPeerIDs: [String] {
        onQueueSync { sessions.filter { $0.value.isReadyForMessages }.map(\.key) }
    }

    public var peers: [DiscoveredPeer] {
        onQueueSync { orderedPeers() }
    }

    public convenience init() throws {
        try self.init(store: IdentityStore(directory: IdentityStore.defaultDirectory))
    }

    public init(store: IdentityStore) throws {
        self.store = store
        self.identity = try store.loadOrCreate()
        let queue = DispatchQueue(label: "bluecomms.network")
        self.queue = queue
        queue.setSpecific(key: queueKey, value: 1)
    }

    /// Advertise + browse. Safe to call once; ChatStore also guards with didStart.
    public func start() {
        onQueueAsync {
            self.isStopping = false
            self.restartAttempt = 0
            self.startStacks()
        }
    }

    public func stop() {
        onQueueSync { self.stopLocked() }
    }

    public func disconnect() {
        onQueueAsync {
            if let last = self.lastPeerID {
                self.disconnectLocked(peerID: last)
                return
            }
            for id in self.sessions.keys {
                self.disconnectLocked(peerID: id)
            }
        }
    }

    public func disconnect(from peerID: String) {
        onQueueAsync {
            self.disconnectLocked(peerID: peerID)
        }
    }

    /// Outbound TCP. `id` is the device UUID string from the Bonjour TXT record.
    public func connectToPeer(id: String) {
        onQueueAsync {
            guard let peer = self.discoveredByID[id] else {
                self.emitLog("Unknown peer.")
                return
            }
            self.connect(to: peer)
        }
    }

    public func connectToPeer(at index: Int) {
        onQueueAsync {
            let peers = self.orderedPeers()
            guard index >= 0, index < peers.count else {
                self.emitLog("Invalid peer index.")
                return
            }
            self.connect(to: peers[index])
        }
    }

    public func connectToPeer(named query: String) {
        onQueueAsync {
            let peers = self.orderedPeers()
            let needle = query.lowercased()
            let exact = peers.filter {
                $0.displayName.lowercased() == needle
                    || $0.bonjourName.lowercased() == needle
                    || $0.shortName.lowercased() == needle
                    || $0.id.lowercased() == needle
            }
            let matches = exact.isEmpty
                ? peers.filter {
                    $0.displayName.lowercased().contains(needle)
                        || $0.bonjourName.lowercased().contains(needle)
                        || $0.shortName.lowercased().contains(needle)
                }
                : exact

            if matches.count == 1, let peer = matches.first {
                self.connect(to: peer)
                return
            }
            if matches.isEmpty {
                self.emitLog("No peer matching '\(query)'. Type 'list'.")
                return
            }
            self.emitLog("Multiple peers match '\(query)'. Be more specific:")
            for (index, peer) in peers.enumerated() where matches.contains(peer) {
                self.emitLog("  [\(index)] \(peer.displayName) · \(peer.shortName)")
            }
        }
    }

    public func send(message: String) {
        onQueueAsync {
            let target = self.lastPeerID ?? self.sessions.first(where: { $0.value.isReadyForMessages })?.key
            guard let target, let conn = self.sessions[target], conn.isReadyForMessages else {
                self.emitLog("No active connection to send message.")
                return
            }
            conn.send(message: message)
        }
    }

    public func send(message: String, to peerID: String) {
        onQueueAsync {
            guard let conn = self.sessions[peerID], conn.isReadyForMessages else {
                self.emitLog("No session with that peer.")
                return
            }
            self.lastPeerID = peerID
            conn.send(message: message)
        }
    }

    /// Start an offer/chunk transfer. Session must already be ready.
    public func send(file url: URL, to peerID: String, id: UUID = UUID()) {
        // Hold any security-scoped bookmark across the hop onto `queue`.
        // PeerConnection takes its own nested access for the transfer lifetime.
        let accessed = url.startAccessingSecurityScopedResource()
        onQueueAsync {
            defer { if accessed { url.stopAccessingSecurityScopedResource() } }
            guard let conn = self.sessions[peerID], conn.isReadyForMessages else {
                self.emitLog("No session with that peer. Connect first, then send the file.")
                return
            }
            self.lastPeerID = peerID
            conn.sendFile(at: url, id: id)
        }
    }

    private func startStacks() {
        guard !isStopping else { return }
        restartScheduled = false
        startListener()
        startBrowser()
    }

    /// Publish `_bluecomms._tcp` with our id/name/proto in the TXT record.
    private func startListener() {
        listener?.cancel()
        listener = nil

        let params = Self.makeParameters()
        do {
            let newListener = try NWListener(using: params)
            var txt = NWTXTRecord()
            txt["id"] = identity.id.uuidString
            txt["proto"] = String(HandshakePayload.protoVersion)
            txt["name"] = identity.displayName
            newListener.service = NWListener.Service(
                name: identity.bonjourName,
                type: Self.serviceType,
                domain: Self.serviceDomain,
                txtRecord: txt
            )
            newListener.stateUpdateHandler = { [weak self] state in
                self?.handleListenerState(state)
            }
            newListener.newConnectionHandler = { [weak self] connection in
                self?.handleIncoming(connection)
            }
            newListener.start(queue: queue)
            listener = newListener
        } catch {
            emitLog("[LISTENER] Failed to create listener: \(error)")
            scheduleRestart(reason: "Listener could not start.")
        }
    }

    /// Watch the same service type. Domain must be `local.` not nil.
    private func startBrowser() {
        browser?.cancel()
        browser = nil

        let params = Self.makeParameters()
        // `.bonjour` never fills Result.metadata. We require TXT `id` below,
        // so without TXT the Nearby list stays empty even when peers exist.
        let newBrowser = NWBrowser(
            for: .bonjourWithTXTRecord(type: Self.serviceType, domain: Self.serviceDomain),
            using: params
        )
        newBrowser.stateUpdateHandler = { [weak self] state in
            self?.handleBrowserState(state)
        }
        newBrowser.browseResultsChangedHandler = { [weak self] results, _ in
            self?.applyBrowseResults(results)
        }
        newBrowser.start(queue: queue)
        browser = newBrowser
    }

    private func handleListenerState(_ state: NWListener.State) {
        switch state {
        case .ready:
            restartAttempt = 0
            emitLog("[LISTENER] Ready. Advertising '\(identity.bonjourName)'.")
        case .waiting(let error):
            emitLog("[LISTENER] Waiting: \(error.localizedDescription)")
            emitLog("If peers never appear, turn Wi-Fi on and grant Local Network permission in System Settings → Privacy & Security → Local Network.")
        case .failed(let error):
            emitLog("[LISTENER] Failed: \(error)")
            scheduleRestart(reason: "Listener failed.")
        case .cancelled:
            break
        default:
            break
        }
    }

    private func handleBrowserState(_ state: NWBrowser.State) {
        switch state {
        case .ready:
            restartAttempt = 0
            emitLog("[BROWSER] Browsing for peers.")
        case .waiting(let error):
            emitLog("[BROWSER] Waiting: \(error.localizedDescription)")
            emitLog("If peers never appear, turn Wi-Fi on and grant Local Network permission in System Settings → Privacy & Security → Local Network.")
        case .failed(let error):
            emitLog("[BROWSER] Failed: \(error)")
            scheduleRestart(reason: "Browser failed.")
        case .cancelled:
            break
        default:
            break
        }
    }

    /// Rebuild the peer map. Drop ourselves. Remember last-seen for people who left.
    private func applyBrowseResults(_ results: Set<NWBrowser.Result>) {
        var next: [String: DiscoveredPeer] = [:]
        for result in results {
            guard let peer = DiscoveredPeer(result: result) else { continue }
            if peer.id == identity.id.uuidString || peer.bonjourName == identity.bonjourName {
                continue
            }
            next[peer.id] = peer
        }
        let previous = Set(discoveredByID.keys)
        let gone = previous.subtracting(next.keys)
        for id in gone {
            lastSeenAt[id] = Date()
        }
        if next.isEmpty, !results.isEmpty {
            emitLog("[BROWSER] Saw \(results.count) Bonjour row(s) but none had a usable device id.")
        }
        discoveredByID = next
        let snapshot = orderedPeers()
        DispatchQueue.main.async { [onPeersUpdated] in
            onPeersUpdated?(snapshot)
        }
    }

    private func handleIncoming(_ connection: NWConnection) {
        emitLog("[LISTENER] Incoming connection from \(connection.endpoint)")
        attach(connection)
    }

    private func connect(to peer: DiscoveredPeer) {
        if sessions[peer.id]?.isReadyForMessages == true {
            emitLog("Already connected to \(peer.displayName).")
            lastPeerID = peer.id
            return
        }
        emitLog("[CONNECTION] Connecting to \(peer.displayName) · \(peer.shortName)")
        let connection = NWConnection(to: peer.endpoint, using: Self.makeParameters())
        attach(connection)
    }

    /// Wrap a new NWConnection (inbound or outbound) and wait for handshake.
    private func attach(_ connection: NWConnection) {
        let peerConnection = PeerConnection(connection: connection, identity: identity, queue: queue)
        let connectionID = peerConnection.id

        peerConnection.onLog = { [weak self] message in
            self?.emitLog(message)
        }
        peerConnection.onHandshake = { [weak self] payload in
            guard let self else { return .firstSeen }
            if payload.peerID == self.identity.id {
                throw CryptoError.invalidPublicKey
            }
            return try self.store.verifyOrRemember(peerID: payload.peerID, publicKey: payload.publicKey)
        }
        peerConnection.onReadyForChat = { [weak self] peerID in
            guard let self else { return }
            let key = peerID.uuidString
            guard let established = self.pending.removeValue(forKey: connectionID) else { return }
            // Two connections to the same peer: keep the one that just shook hands.
            if let old = self.sessions[key], old.id != connectionID {
                old.onStateChange = nil
                old.onReadyForChat = nil
                old.cancel()
            }
            self.sessions[key] = established
            self.lastPeerID = key
            DispatchQueue.main.async { [weak self] in
                self?.onConnectionEstablished?()
                self?.onSecureSession?(peerID)
            }
        }
        peerConnection.onMessageReceived = { [weak self] message in
            guard let self else { return }
            let peerKey = self.sessions.first(where: { $0.value.id == connectionID })?.key
            DispatchQueue.main.async { [weak self] in
                self?.onMessageReceived?(message)
                if let peerKey, let uuid = UUID(uuidString: peerKey) {
                    self?.onMessageFromPeer?(uuid, message)
                }
            }
        }
        peerConnection.onFileTransfer = { [weak self] update in
            guard let self else { return }
            let peerKey = self.sessions.first(where: { $0.value.id == connectionID })?.key
                ?? self.lastPeerID
            DispatchQueue.main.async { [weak self] in
                if let peerKey, let uuid = UUID(uuidString: peerKey) {
                    self?.onFileTransfer?(uuid, update)
                }
            }
        }
        peerConnection.onStateChange = { [weak self] state in
            guard let self else { return }
            switch state {
            case .ready:
                self.emitLog("[CONNECTION] Transport ready. Completing handshake...")
            case .failed(let error):
                self.emitLog("[CONNECTION] Failed: \(error)")
                self.removeSession(connectionID: connectionID)
            case .cancelled:
                self.emitLog("[CONNECTION] Cancelled")
                self.removeSession(connectionID: connectionID)
            case .preparing:
                self.emitLog("[CONNECTION] Preparing...")
            case .waiting(let error):
                self.emitLog("[CONNECTION] Waiting: \(error.localizedDescription)")
            case .setup:
                break
            @unknown default:
                break
            }
        }

        pending[connectionID] = peerConnection
        peerConnection.start()
    }

    private func disconnectLocked(peerID: String) {
        guard let conn = sessions.removeValue(forKey: peerID) else { return }
        conn.onStateChange = nil
        conn.onReadyForChat = nil
        conn.cancel()
        if lastPeerID == peerID {
            lastPeerID = sessions.keys.first
        }
        emitLog("[CONNECTION] Disconnected \(peerID.prefix(8)).")
        DispatchQueue.main.async { [weak self] in
            self?.onDisconnected?()
            if let uuid = UUID(uuidString: peerID) {
                self?.onPeerDisconnected?(uuid)
            }
        }
    }

    private func removeSession(connectionID: UUID) {
        pending[connectionID] = nil
        guard let key = sessions.first(where: { $0.value.id == connectionID })?.key else { return }
        sessions[key] = nil
        if lastPeerID == key {
            lastPeerID = sessions.keys.first
        }
        DispatchQueue.main.async { [weak self] in
            self?.onDisconnected?()
            if let uuid = UUID(uuidString: key) {
                self?.onPeerDisconnected?(uuid)
            }
        }
    }

    /// Listener/browser died. Exponential backoff, cap 30s. stop() cancels this.
    private func scheduleRestart(reason: String) {
        guard !isStopping, !restartScheduled else { return }
        restartScheduled = true
        listener?.cancel()
        browser?.cancel()
        listener = nil
        browser = nil
        restartWork?.cancel()

        let delay = min(pow(2.0, Double(restartAttempt)), 30)
        restartAttempt += 1
        emitLog("[NETWORK] \(reason) Retrying in \(Int(delay))s...")
        let work = DispatchWorkItem { [weak self] in
            self?.startStacks()
        }
        restartWork = work
        queue.asyncAfter(deadline: .now() + delay, execute: work)
    }

    private func stopLocked() {
        isStopping = true
        restartWork?.cancel()
        restartWork = nil
        restartScheduled = false
        for session in sessions.values {
            session.onStateChange = nil
            session.cancel()
        }
        for pendingConn in pending.values {
            pendingConn.onStateChange = nil
            pendingConn.cancel()
        }
        sessions.removeAll()
        pending.removeAll()
        lastPeerID = nil
        listener?.cancel()
        browser?.cancel()
        listener = nil
        browser = nil
    }

    private func orderedPeers() -> [DiscoveredPeer] {
        discoveredByID.values.sorted { lhs, rhs in
            let nameOrder = lhs.displayName.localizedCaseInsensitiveCompare(rhs.displayName)
            if nameOrder != .orderedSame { return nameOrder == .orderedAscending }
            return lhs.id < rhs.id
        }
    }

    private func emitLog(_ message: String) {
        DispatchQueue.main.async { [onLog] in
            onLog?(message)
        }
    }

    /// TCP + AWDL. Without includePeerToPeer we only work on the same Wi-Fi AP.
    private static func makeParameters() -> NWParameters {
        let params = NWParameters.tcp
        params.includePeerToPeer = true
        return params
    }

    /// Run on the network queue. If we are already on it, do not deadlock via async.
    private func onQueueAsync(_ body: @escaping @Sendable () -> Void) {
        if DispatchQueue.getSpecific(key: queueKey) != nil {
            body()
        } else {
            queue.async(execute: body)
        }
    }

    private func onQueueSync<T>(_ body: () -> T) -> T {
        if DispatchQueue.getSpecific(key: queueKey) != nil {
            return body()
        }
        return queue.sync(execute: body)
    }
}

extension DiscoveredPeer {
    public var shortName: String {
        if let range = bonjourName.range(of: " · ", options: .backwards) {
            return String(bonjourName[range.upperBound...])
        }
        return String(id.replacingOccurrences(of: "-", with: "").prefix(8))
    }

    /// Ignore rows with no `id` TXT or a proto we do not speak.
    init?(result: NWBrowser.Result) {
        guard case .service(let name, _, _, _) = result.endpoint else { return nil }
        guard case .bonjour(let txt) = result.metadata else { return nil }
        let record = txt.dictionary
        guard let txtID = record["id"], UUID(uuidString: txtID) != nil else {
            return nil
        }
        if let proto = record["proto"], proto != String(HandshakePayload.protoVersion) {
            return nil
        }

        self.id = txtID
        if let txtName = record["name"], !txtName.isEmpty {
            self.displayName = txtName
        } else {
            self.displayName = name
        }
        self.bonjourName = name
        self.endpoint = result.endpoint
    }
}
