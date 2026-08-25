//
//  ChatStore.swift
//
//  Why this file exists:
//    The Mac window cannot talk to Network.framework itself. This object is the
//    UI's brain: SwiftUI binds to @Published fields, and we translate button
//    taps into NetworkManager calls.
//
//  What it does:
//    • Holds the sidebar (peers), the selected thread, the draft box, and status.
//    • Starts Bonjour/AWDL once (see start()).
//    • Loads/saves encrypted history so a quit does not wipe chat.
//    • Queues text and files when that Mac is not connected, then flushes them
//      after the handshake.
//    • Hops every network callback onto the main thread so SwiftUI can redraw.
//
//  This is the glue from PRs #2 (window), #3 (history + queue), #4 (many peers),
//  #5 (files), and #6 (do not start the radio twice).
//

import BlueCommsCore
import Combine
import Foundation

@MainActor
final class ChatStore: ObservableObject {
    /// Sidebar list. Includes people who walked away (isOnline == false).
    @Published var peers: [NearbyPeer] = []
    /// Threads keyed by peer UUID string. Reloaded from disk in init.
    @Published var conversations: [String: [ChatMessage]] = [:]
    /// Which row is selected. nil = no thread on the right.
    @Published var selectedPeerID: String?
    /// The composer text field. Cleared when we send.
    @Published var draft: String = ""
    /// idle / connecting / ready — used to disable Connect while TCP is coming up.
    @Published var phase: ConnectionPhase = .idle
    /// One-line footer in the sidebar (logs, errors, "Secure session with …").
    @Published var statusLine: String

    let localName: String
    let shortID: String
    let fingerprint: String

    /// ~/.bluecomms, or BLUECOMMS_HOME when you want a second identity on this Mac.
    static var defaultDirectory: URL {
        if let env = ProcessInfo.processInfo.environment["BLUECOMMS_HOME"], !env.isEmpty {
            return URL(fileURLWithPath: env, isDirectory: true)
        }
        return IdentityStore.defaultDirectory
    }

    /// The radio. nil only if launch failed (disk / identity error).
    private var manager: NetworkManager?
    /// Peer ids that currently have a finished handshake.
    private var connectedIDs: Set<String> = []
    /// Encrypted history in ~/.bluecomms. nil if launch failed.
    private var archive: MessageArchive?
    /// start() can run from onAppear more than once. The radio must start once.
    private var didStart = false

    var selectedPeer: NearbyPeer? { peers.first { $0.id == selectedPeerID } }

    var selectedMessages: [ChatMessage] {
        guard let selectedPeerID else { return [] }
        return conversations[selectedPeerID] ?? []
    }

    var isConnectedToSelection: Bool {
        selectedPeerID.map { connectedIDs.contains($0) } ?? false
    }

    /// Empty store so SwiftUI still has an object if identity/archive cannot load.
    static func failed(_ error: Error) -> ChatStore {
        ChatStore(error: error)
    }

    /// Loads identity + history from disk. Does not start the radio — see `start()`.
    init(directory: URL = ChatStore.defaultDirectory) throws {
        let manager = try NetworkManager(store: IdentityStore(directory: directory))
        self.manager = manager
        localName = manager.deviceName
        shortID = manager.shortID
        fingerprint = manager.fingerprint
        statusLine = "Starting local radio…"
        archive = try MessageArchive(directory: directory)
        conversations = (try? archive?.load())?.conversations ?? [:]
        bind(manager)
    }

    /// Used only when init() throws. Window shows the error string instead of chat.
    private init(error: Error) {
        localName = "—"
        shortID = ""
        fingerprint = ""
        statusLine = String(describing: error)
    }

    /// Start Bonjour + AWDL once. Split-view / onAppear can fire more than once;
    /// a second start() used to cancel the live stacks and freeze the sidebar.
    func start() {
        guard !didStart else { return }
        didStart = true
        manager?.start()
    }

    func stop() { manager?.stop() }

    func select(peerID: String) { selectedPeerID = peerID }

    /// Outbound TCP to the selected Mac. They must still be in the Bonjour list.
    func connectToSelection() {
        guard let peer = selectedPeer else { return }
        guard peer.isOnline else {
            statusLine = "That peer is not nearby. The message will stay queued."
            return
        }
        phase = .connecting
        statusLine = "Connecting to \(peer.displayName)…"
        manager?.connectToPeer(id: peer.id)
    }

    func disconnect() {
        if let id = selectedPeerID {
            manager?.disconnect(from: id)
        } else {
            manager?.disconnect()
        }
    }

    /// Send typed text, or queue it if that session is down.
    func sendDraft() {
        let text = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty, let peerID = selectedPeerID else { return }
        draft = ""
        let live = isConnectedToSelection
        append(ChatMessage(peerID: peerID, text: text, isLocal: true, delivery: live ? .sent : .queued))
        if live {
            manager?.send(message: text, to: peerID)
        } else {
            statusLine = "Queued. It will send when this peer is back."
        }
        persist()
    }

    /// Stream a photo/video/file. Same queue rules as text.
    /// `startAccessingSecurityScopedResource` is required for files from the picker.
    func sendFile(url: URL) {
        guard let peerID = selectedPeerID else { return }
        let accessed = url.startAccessingSecurityScopedResource()
        defer { if accessed { url.stopAccessingSecurityScopedResource() } }
        let size = UInt64((try? url.resourceValues(forKeys: [.fileSizeKey]))?.fileSize ?? 0)
        let name = url.lastPathComponent
        let transferID = UUID()
        let live = isConnectedToSelection
        append(ChatMessage(
            peerID: peerID, text: name, isLocal: true,
            delivery: live ? .sent : .queued, kind: .file,
            fileName: name, fileSize: size, filePath: url.path,
            transferID: transferID, progress: 0,
            fileState: live ? .transferring : .queued
        ))
        if live {
            manager?.send(file: url, to: peerID, id: transferID)
            statusLine = "Sending \(name)…"
        } else {
            statusLine = "File queued. Connect to send \(name)."
        }
        persist()
    }

    /// Capture the main display to /tmp, then send it as a normal file.
    func sendScreenshot() {
        guard let url = ScreenGrab.savePNG() else {
            statusLine = "Could not capture the screen. Grant Screen Recording if asked."
            return
        }
        sendFile(url: url)
    }

    /// Wire NetworkManager callbacks. They arrive off the main thread.
    private func bind(_ manager: NetworkManager) {
        manager.onPeersUpdated = { [weak self] peers in
            Task { @MainActor in self?.mergePresence(peers) }
        }
        manager.onSecureSession = { [weak self] peerID in
            Task { @MainActor in
                guard let self else { return }
                let key = peerID.uuidString
                self.ensurePeer(id: key)
                self.connectedIDs.insert(key)
                self.markSession(peerID: key, open: true)
                self.selectedPeerID = key
                self.phase = .ready
                let name = self.peers.first { $0.id == key }?.displayName ?? "peer"
                self.statusLine = "Secure session with \(name)"
                // Anything typed while they were gone goes out now.
                self.flushOutbound(for: key)
            }
        }
        manager.onPeerDisconnected = { [weak self] peerID in
            Task { @MainActor in
                let key = peerID.uuidString
                self?.connectedIDs.remove(key)
                self?.markSession(peerID: key, open: false)
                self?.phase = self?.connectedIDs.isEmpty == true ? .idle : .ready
                self?.statusLine = "Disconnected"
            }
        }
        manager.onMessageFromPeer = { [weak self] peerID, text in
            Task { @MainActor in
                self?.append(ChatMessage(peerID: peerID.uuidString, text: text, isLocal: false))
                self?.persist()
            }
        }
        manager.onFileTransfer = { [weak self] peerID, update in
            Task { @MainActor in self?.applyFileUpdate(peerID: peerID, update: update) }
        }
        manager.onLog = { [weak self] line in
            Task { @MainActor in
                // Once a session is up, keep the footer on "Secure session…"
                if self?.phase != .ready { self?.statusLine = line }
            }
        }
    }

    private func append(_ message: ChatMessage) {
        conversations[message.peerID, default: []].append(message)
    }

    /// Update an existing file card, or add an incoming one we have not seen yet.
    private func applyFileUpdate(peerID: UUID, update: FileTransferUpdate) {
        let key = peerID.uuidString
        if let index = conversations[key]?.firstIndex(where: { $0.transferID == update.transferID }) {
            conversations[key]?[index].progress = update.progress
            conversations[key]?[index].fileState = update.state
            if let path = update.localURL?.path { conversations[key]?[index].filePath = path }
            if update.state == .complete { conversations[key]?[index].delivery = .sent }
            if update.state == .failed || update.state == .cancelled {
                statusLine = update.error ?? "File transfer failed"
            }
            if update.state == .complete || update.state == .failed || update.state == .cancelled {
                persist()
            }
            return
        }
        if !update.isOutgoing {
            append(ChatMessage(
                peerID: key, text: update.name, isLocal: false, kind: .file,
                fileName: update.name, fileSize: update.size, filePath: update.localURL?.path,
                transferID: update.transferID, progress: update.progress, fileState: update.state
            ))
            if update.state == .complete { persist() }
        }
    }

    /// Write the thread list to disk. Progress ticks are not written (too frequent).
    private func persist() {
        try? archive?.save(ConversationSnapshot(conversations: conversations))
    }

    /// After handshake, push anything we stored while they were gone.
    private func flushOutbound(for peerID: String) {
        guard var thread = conversations[peerID] else { return }
        var sent = false
        for i in thread.indices where thread[i].delivery == .queued && thread[i].isLocal {
            if thread[i].kind == .file, let path = thread[i].filePath {
                manager?.send(file: URL(fileURLWithPath: path), to: peerID, id: thread[i].transferID ?? UUID())
                thread[i].fileState = .transferring
            } else {
                manager?.send(message: thread[i].text, to: peerID)
            }
            thread[i].delivery = .sent
            sent = true
        }
        conversations[peerID] = thread
        if sent { statusLine = "Delivered queued messages." }
        persist()
    }

    /// Bonjour list in, sidebar list out. Only publishes when something actually changed
    /// so the sidebar does not flicker on every browse tick.
    private func mergePresence(_ discovered: [DiscoveredPeer]) {
        let online = Set(discovered.map(\.id))
        let now = Date()
        var next = peers
        var changed = false
        for peer in discovered {
            if let i = next.firstIndex(where: { $0.id == peer.id }) {
                if !next[i].isOnline { next[i].isOnline = true; changed = true }
            } else {
                next.append(NearbyPeer(
                    id: peer.id, displayName: peer.displayName, shortName: peer.shortName,
                    isOnline: true, lastSeen: now, isSessionOpen: connectedIDs.contains(peer.id)
                ))
                changed = true
            }
        }
        for i in next.indices where !online.contains(next[i].id) && next[i].isOnline {
            next[i].isOnline = false
            next[i].lastSeen = now
            changed = true
        }
        if changed { peers = next }
        if !next.isEmpty, statusLine.contains("Starting") { statusLine = "Nearby peers updated" }
    }

    private func markSession(peerID: String, open: Bool) {
        if let i = peers.firstIndex(where: { $0.id == peerID }) { peers[i].isSessionOpen = open }
    }

    /// Inbound connect can finish before Bonjour lists the peer. Invent a row so
    /// the chat pane has someone to show.
    private func ensurePeer(id: String) {
        guard !peers.contains(where: { $0.id == id }) else { return }
        let short = String(id.replacingOccurrences(of: "-", with: "").prefix(8))
        peers.append(NearbyPeer(
            id: id, displayName: "Peer \(short)", shortName: short,
            isOnline: true, lastSeen: Date(), isSessionOpen: true
        ))
    }
}
