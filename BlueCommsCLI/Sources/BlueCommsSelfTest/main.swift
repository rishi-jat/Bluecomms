//
//  main.swift  (BlueCommsSelfTest)
//
//  Why this file exists:
//    Command Line Tools do not ship XCTest / Swift Testing, so we cannot
//    use `swift test`. This executable runs the same checks and prints
//    ok / FAIL. Cover framing, crypto, identity, archive, file messages.
//
//  These are in-process unit checks. They do not prove two Macs can see
//  each other over AWDL — that still needs two machines and working AirDrop.
//

import CryptoKit
import Foundation
import BlueCommsCore

@main
struct BlueCommsSelfTest {
    static func main() throws {
        var failures = 0
        let cases: [(String, () throws -> Void)] = [
            ("frame round trip", testFrameRoundTrip),
            ("two frames in one chunk", testTwoFramesInOneChunk),
            ("split header then payload", testSplitHeaderThenPayload),
            ("split payload across chunks", testSplitPayloadAcrossChunks),
            ("empty payload", testEmptyPayload),
            ("max frame size accepted", testMaxSizeAccepted),
            ("encode rejects oversized payload", testEncodeRejectsOversizedPayload),
            ("decode rejects oversized declared length", testDecodeRejectsOversizedDeclaredLength),
            ("trailing partial frame stays buffered", testTrailingPartialFrame),
            ("crypto handshake round trip", testHandshakeRoundTrip),
            ("multiple messages decrypt", testMultipleMessagesDecrypt),
            ("same key rejected", testSameKeyRejected),
            ("invalid public key rejected", testInvalidPublicKeyRejected),
            ("seal before establish fails", testSealBeforeEstablishFails),
            ("handshake payload round trip", testHandshakePayloadRoundTrip),
            ("handshake rejects unsupported protocol", testHandshakeRejectsUnsupportedProtocol),
            ("fingerprint is stable", testFingerprintIsStable),
            ("identity load is stable", testLoadOrCreateIsStable),
            ("tofu remembers then matches", testTOFURemembersThenMatches),
            ("tofu mismatch", testTOFUMismatch),
            ("computer name is non-empty", testComputerNameIsNonEmpty),
            ("bonjour name respects byte limit", testBonjourNameRespectsByteLimit),
            ("framed ciphertext round trip", testFramedCiphertextRoundTrip),
            ("archive round trip", testArchiveRoundTrip),
            ("archive empty load", testArchiveEmptyLoad),
            ("archive rejects wrong key", testArchiveWrongKey),
            ("file offer round trip", testFileOfferRoundTrip),
            ("file chunk round trip", testFileChunkRoundTrip),
            ("file name sanitizes slashes", testFileNameSanitize),
            ("file offer rejects huge size", testFileOfferRejectsHugeSize),
            ("file stream reassembles with matching hash", testFileStreamReassembles),
            ("two local peers discover and send a file", testTwoPeersSendFile),
        ]

        for (name, body) in cases {
            do {
                try body()
                print("ok   \(name)")
            } catch {
                failures += 1
                print("FAIL \(name): \(error)")
            }
        }

        if failures > 0 {
            print("\n\(failures) test(s) failed")
            exit(1)
        }
        print("\n\(cases.count) tests passed")
    }
}

private struct Failure: Error, CustomStringConvertible {
    let message: String
    var description: String { message }
}

private func expect(_ condition: Bool, _ message: String) throws {
    if !condition { throw Failure(message: message) }
}

private func expectEqual<T: Equatable>(_ actual: T, _ expected: T) throws {
    try expect(actual == expected, "expected \(expected), got \(actual)")
}

private func expectThrows<E: Error & Equatable>(_ work: () throws -> some Any, as expected: E) throws {
    do {
        _ = try work()
        throw Failure(message: "expected \(expected), but no error was thrown")
    } catch let error as E {
        try expectEqual(error, expected)
    } catch let error as Failure {
        throw error
    } catch {
        throw Failure(message: "threw \(error), expected \(expected)")
    }
}

private func testFrameRoundTrip() throws {
    let payload = Data("hello".utf8)
    let frames = try FrameDecoder().append(try FrameCodec.encode(payload))
    try expectEqual(frames, [payload])
}

private func testTwoFramesInOneChunk() throws {
    let first = try FrameCodec.encode(Data("hi".utf8))
    let second = try FrameCodec.encode(Data("there".utf8))
    try expectEqual(try FrameDecoder().append(first + second), [Data("hi".utf8), Data("there".utf8)])
}

private func testSplitHeaderThenPayload() throws {
    let encoded = try FrameCodec.encode(Data("abc".utf8))
    let decoder = FrameDecoder()
    try expectEqual(try decoder.append(encoded.prefix(2)), [])
    try expectEqual(try decoder.append(encoded.dropFirst(2)), [Data("abc".utf8)])
}

private func testSplitPayloadAcrossChunks() throws {
    let payload = Data(repeating: 0x61, count: 100)
    let encoded = try FrameCodec.encode(payload)
    let decoder = FrameDecoder()
    try expectEqual(try decoder.append(encoded.prefix(10)), [])
    try expectEqual(try decoder.append(encoded.dropFirst(10)), [payload])
}

private func testEmptyPayload() throws {
    try expectEqual(try FrameDecoder().append(try FrameCodec.encode(Data())), [Data()])
}

private func testMaxSizeAccepted() throws {
    let payload = Data(repeating: 0x42, count: FrameCodec.maxPayloadSize)
    let frames = try FrameDecoder().append(try FrameCodec.encode(payload))
    try expectEqual(frames.first?.count, FrameCodec.maxPayloadSize)
}

private func testEncodeRejectsOversizedPayload() throws {
    let payload = Data(repeating: 0x42, count: FrameCodec.maxPayloadSize + 1)
    try expectThrows({ try FrameCodec.encode(payload) }, as: FrameError.payloadTooLarge(payload.count))
}

private func testDecodeRejectsOversizedDeclaredLength() throws {
    var header = Data(count: 4)
    let length = UInt32(FrameCodec.maxPayloadSize + 1).bigEndian
    Swift.withUnsafeBytes(of: length) { bytes in
        header.replaceSubrange(0..<4, with: bytes)
    }
    try expectThrows({ try FrameDecoder().append(header) }, as: FrameError.declaredLengthTooLarge(UInt32(FrameCodec.maxPayloadSize + 1)))
}

private func testTrailingPartialFrame() throws {
    let first = try FrameCodec.encode(Data("one".utf8))
    let second = try FrameCodec.encode(Data("two".utf8))
    let decoder = FrameDecoder()
    try expectEqual(try decoder.append(first + second.prefix(3)), [Data("one".utf8)])
    try expectEqual(try decoder.append(second.dropFirst(3)), [Data("two".utf8)])
}

private func connectedSessions() throws -> (CryptoSession, CryptoSession) {
    let aliceKey = Curve25519.KeyAgreement.PrivateKey()
    let bobKey = Curve25519.KeyAgreement.PrivateKey()
    var alice = CryptoSession(localPrivateKey: aliceKey)
    var bob = CryptoSession(localPrivateKey: bobKey)
    try alice.establish(peerPublicKey: bobKey.publicKey.rawRepresentation)
    try bob.establish(peerPublicKey: aliceKey.publicKey.rawRepresentation)
    return (alice, bob)
}

private func testHandshakeRoundTrip() throws {
    var (alice, bob) = try connectedSessions()
    let sealed = try alice.seal(Data("ping".utf8))
    try expectEqual(try bob.open(sealed), Data("ping".utf8))
    let reply = try bob.seal(Data("pong".utf8))
    try expectEqual(try alice.open(reply), Data("pong".utf8))
}

private func testMultipleMessagesDecrypt() throws {
    var (alice, bob) = try connectedSessions()
    let first = try alice.seal(Data("one".utf8))
    let second = try alice.seal(Data("two".utf8))
    try expectEqual(try bob.open(first), Data("one".utf8))
    try expectEqual(try bob.open(second), Data("two".utf8))
}

private func testSameKeyRejected() throws {
    let key = Curve25519.KeyAgreement.PrivateKey()
    var session = CryptoSession(localPrivateKey: key)
    try expectThrows({ try session.establish(peerPublicKey: key.publicKey.rawRepresentation) }, as: CryptoError.invalidPublicKey)
}

private func testInvalidPublicKeyRejected() throws {
    var session = CryptoSession(localPrivateKey: Curve25519.KeyAgreement.PrivateKey())
    try expectThrows({ try session.establish(peerPublicKey: Data(repeating: 0, count: 8)) }, as: CryptoError.invalidPublicKey)
}

private func testSealBeforeEstablishFails() throws {
    var session = CryptoSession(localPrivateKey: Curve25519.KeyAgreement.PrivateKey())
    try expectThrows({ try session.seal(Data("x".utf8)) }, as: CryptoError.notEstablished)
}

private func testHandshakePayloadRoundTrip() throws {
    let id = UUID()
    let key = Curve25519.KeyAgreement.PrivateKey().publicKey.rawRepresentation
    let decoded = try HandshakePayload.decode(HandshakePayload(peerID: id, publicKey: key).encoded())
    try expectEqual(decoded.peerID, id)
    try expectEqual(decoded.publicKey, key)
}

private func testHandshakeRejectsUnsupportedProtocol() throws {
    var data = HandshakePayload(
        peerID: UUID(),
        publicKey: Curve25519.KeyAgreement.PrivateKey().publicKey.rawRepresentation
    ).encoded()
    data[0] = 99
    try expectThrows({ try HandshakePayload.decode(data) }, as: CryptoError.unsupportedProtocol(99))
}

private func testFingerprintIsStable() throws {
    let key = Data(repeating: 0x11, count: 32)
    try expectEqual(keyFingerprint(key), keyFingerprint(key))
    try expectEqual(keyFingerprint(key).count, 14)
}

private func makeStore() throws -> (IdentityStore, URL) {
    let url = FileManager.default.temporaryDirectory
        .appendingPathComponent("bluecomms-tests-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    return (IdentityStore(directory: url), url)
}

private func testLoadOrCreateIsStable() throws {
    let (store, url) = try makeStore()
    defer { try? FileManager.default.removeItem(at: url) }
    let first = try store.loadOrCreate()
    let second = try store.loadOrCreate()
    try expectEqual(first.id, second.id)
    try expectEqual(first.publicKeyData, second.publicKeyData)
    try expect(!first.bonjourName.isEmpty, "bonjour name should not be empty")
    try expect(first.bonjourName.utf8.count <= 63, "bonjour name exceeds 63 bytes")
}

private func testTOFURemembersThenMatches() throws {
    let (store, url) = try makeStore()
    defer { try? FileManager.default.removeItem(at: url) }
    let peerID = UUID()
    let key = Curve25519.KeyAgreement.PrivateKey().publicKey.rawRepresentation
    try expectEqual(try store.verifyOrRemember(peerID: peerID, publicKey: key), .firstSeen)
    try expectEqual(try store.verifyOrRemember(peerID: peerID, publicKey: key), .matched)
}

private func testTOFUMismatch() throws {
    let (store, url) = try makeStore()
    defer { try? FileManager.default.removeItem(at: url) }
    let peerID = UUID()
    let first = Curve25519.KeyAgreement.PrivateKey().publicKey.rawRepresentation
    let second = Curve25519.KeyAgreement.PrivateKey().publicKey.rawRepresentation
    _ = try store.verifyOrRemember(peerID: peerID, publicKey: first)
    try expectThrows({ try store.verifyOrRemember(peerID: peerID, publicKey: second) }, as: CryptoError.tofuMismatch)
}

private func testComputerNameIsNonEmpty() throws {
    try expect(!localComputerName().isEmpty, "computer name should not be empty")
}

private func testBonjourNameRespectsByteLimit() throws {
    let identity = DeviceIdentity(
        id: UUID(),
        displayName: String(repeating: "나", count: 80),
        privateKey: Curve25519.KeyAgreement.PrivateKey()
    )
    try expect(identity.bonjourName.utf8.count <= 63, "bonjour name exceeds 63 bytes")
    try expect(identity.bonjourName.contains(identity.shortID), "bonjour name should include short id")
}

private func testFramedCiphertextRoundTrip() throws {
    var (alice, bob) = try connectedSessions()
    let sealed = try alice.seal(Data("secret chat".utf8))
    var payload = Data([WireType.ciphertext.rawValue])
    payload.append(sealed)
    let frames = try FrameDecoder().append(try FrameCodec.encode(payload))
    try expectEqual(frames.count, 1)
    guard let frame = frames.first, let type = frame.first, type == WireType.ciphertext.rawValue else {
        throw Failure(message: "expected ciphertext frame")
    }
    try expectEqual(try bob.open(frame.dropFirst()), Data("secret chat".utf8))
}

private func testArchiveRoundTrip() throws {
    let url = FileManager.default.temporaryDirectory
        .appendingPathComponent("bluecomms-archive-\(UUID().uuidString)", isDirectory: true)
    defer { try? FileManager.default.removeItem(at: url) }
    let archive = try MessageArchive(directory: url)
    let peer = UUID().uuidString
    let message = ChatMessage(peerID: peer, text: "held for later", isLocal: true, delivery: .queued)
    try archive.save(ConversationSnapshot(conversations: [peer: [message]], outboundIDs: [message.id]))
    let loaded = try MessageArchive(directory: url).load()
    try expectEqual(loaded.conversations[peer]?.first?.text, "held for later")
    try expectEqual(loaded.conversations[peer]?.first?.delivery, .queued)
    try expectEqual(loaded.outboundIDs, [message.id])
}

private func testArchiveEmptyLoad() throws {
    let url = FileManager.default.temporaryDirectory
        .appendingPathComponent("bluecomms-archive-\(UUID().uuidString)", isDirectory: true)
    defer { try? FileManager.default.removeItem(at: url) }
    let loaded = try MessageArchive(directory: url).load()
    try expect(loaded.conversations.isEmpty, "expected empty archive")
}

private func testArchiveWrongKey() throws {
    let url = FileManager.default.temporaryDirectory
        .appendingPathComponent("bluecomms-archive-\(UUID().uuidString)", isDirectory: true)
    defer { try? FileManager.default.removeItem(at: url) }
    let archive = try MessageArchive(directory: url)
    try archive.save(ConversationSnapshot(conversations: ["x": [ChatMessage(peerID: "x", text: "secret", isLocal: true)]]))
    try FileManager.default.removeItem(at: url.appendingPathComponent("archive.key"))
    do {
        _ = try MessageArchive(directory: url).load()
        throw Failure(message: "expected decrypt to fail after key rotation")
    } catch is Failure {
        throw Failure(message: "expected decrypt to fail after key rotation")
    } catch {
        // AES-GCM open failure is the success path
    }
}

private func testFileOfferRoundTrip() throws {
    let id = UUID()
    let encoded = try FileMessage.offer(id: id, size: 540_000_000, name: "clip.mov").encoded()
    guard case .offer(let decodedID, let size, let name) = try FileMessage.decode(encoded) else {
        throw Failure(message: "expected offer")
    }
    try expectEqual(decodedID, id)
    try expectEqual(size, 540_000_000)
    try expectEqual(name, "clip.mov")
}

private func testFileChunkRoundTrip() throws {
    let id = UUID()
    let payload = Data(repeating: 0xAB, count: 4096)
    let encoded = try FileMessage.chunk(id: id, offset: 256 * 1024, data: payload).encoded()
    guard case .chunk(let decodedID, let offset, let data) = try FileMessage.decode(encoded) else {
        throw Failure(message: "expected chunk")
    }
    try expectEqual(decodedID, id)
    try expectEqual(offset, UInt64(256 * 1024))
    try expectEqual(data, payload)
}

private func testFileNameSanitize() throws {
    try expectEqual(sanitizeFileName("../../etc/passwd"), "..-..-etc-passwd")
    try expectEqual(sanitizeFileName("   "), "file")
}

private func testFileOfferRejectsHugeSize() throws {
    var data = try FileMessage.offer(id: UUID(), size: 1, name: "x").encoded()
    // size sits at bytes 17..<25 after opcode + uuid
    let huge = FileMessage.maxFileSize + 1
    data.replaceSubrange(17..<25, with: uInt64Bytes(huge))
    try expectThrows({ try FileMessage.decode(data) }, as: FileTransferError.badMessage)
}

private func testFileStreamReassembles() throws {
    var payload = Data(count: FileMessage.chunkSize + 1200)
    for index in payload.indices {
        payload[index] = UInt8(index % 251)
    }
    let id = UUID()
    var received = Data()
    var sendHasher = SHA256()
    var recvHasher = SHA256()
    var offset = 0
    while offset < payload.count {
        let end = min(offset + FileMessage.chunkSize, payload.count)
        let piece = payload.subdata(in: offset..<end)
        sendHasher.update(data: piece)
        let encoded = try FileMessage.chunk(id: id, offset: UInt64(offset), data: piece).encoded()
        guard case .chunk(_, let decodedOffset, let data) = try FileMessage.decode(encoded) else {
            throw Failure(message: "chunk did not decode")
        }
        try expectEqual(decodedOffset, UInt64(offset))
        received.append(data)
        recvHasher.update(data: data)
        offset = end
    }
    let sendDigest = Data(sendHasher.finalize())
    let complete = try FileMessage.complete(id: id, sha256: sendDigest).encoded()
    guard case .complete(_, let digest) = try FileMessage.decode(complete) else {
        throw Failure(message: "complete did not decode")
    }
    try expectEqual(received, payload)
    try expectEqual(digest, Data(recvHasher.finalize()))
    try expectEqual(digest, sendDigest)
}

private func testTwoPeersSendFile() throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("bc-pair-\(UUID().uuidString)", isDirectory: true)
    defer { try? FileManager.default.removeItem(at: root) }
    let sender = try NetworkManager(store: IdentityStore(directory: root.appendingPathComponent("sender")))
    let receiver = try NetworkManager(store: IdentityStore(directory: root.appendingPathComponent("receiver")))

    let payload = Data((0..<80_000).map { UInt8($0 % 251) })
    let source = root.appendingPathComponent("screenshot.png")
    try payload.write(to: source)

    var discovered: [DiscoveredPeer] = []
    var sessionReady = false
    var receivedURL: URL?
    var receivedName = ""
    sender.onPeersUpdated = { discovered = $0 }
    sender.onSecureSession = { _ in sessionReady = true }
    receiver.onSecureSession = { _ in sessionReady = true }
    receiver.onFileTransfer = { _, update in
        if update.state == .complete {
            receivedURL = update.localURL
            receivedName = update.name
        }
    }

    sender.start()
    receiver.start()
    defer {
        sender.stop()
        receiver.stop()
    }

    let discoverDeadline = Date().addingTimeInterval(15)
    while discovered.isEmpty, Date() < discoverDeadline {
        RunLoop.current.run(until: Date().addingTimeInterval(0.2))
    }
    guard let peer = discovered.first else {
        throw Failure(message: "peers did not discover each other on the local radio")
    }
    sender.connectToPeer(id: peer.id)
    let handshakeDeadline = Date().addingTimeInterval(10)
    while !sessionReady, Date() < handshakeDeadline {
        RunLoop.current.run(until: Date().addingTimeInterval(0.2))
    }
    guard sessionReady else {
        throw Failure(message: "secure session did not come up")
    }
    sender.send(file: source, to: peer.id)

    let receiveDeadline = Date().addingTimeInterval(8)
    while receivedURL == nil, Date() < receiveDeadline {
        RunLoop.current.run(until: Date().addingTimeInterval(0.2))
    }
    guard let got = receivedURL else {
        throw Failure(message: "receiver never completed the file")
    }
    try expectEqual(receivedName, "screenshot.png")
    try expectEqual(try Data(contentsOf: got), payload)
}
