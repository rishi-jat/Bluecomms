//
//  main.swift  (BlueCommsCLI)
//
//  Why this file exists:
//    Terminal client. Same NetworkManager as the Mac app. Exists so you can
//    chat without a window. Files and screenshots are app-only.
//
//  What it does:
//    Loads identity, starts Bonjour/AWDL, then reads stdin on a background
//    queue. Network callbacks stay on the manager queue. The main thread
//    just runs RunLoop so GCD / Network.framework can fire.
//
//    readLine() must NOT run on the main thread — it would block Bonjour.
//    An empty readLine() is EOF (Ctrl-D / pipe end), not "keep spinning".
//

import Foundation
import BlueCommsCore

let manager: NetworkManager
do {
    manager = try NetworkManager(store: IdentityStore(directory: dataDirectory()))
} catch {
    fputs("Failed to load device identity: \(error)\n", stderr)
    exit(1)
}

print("========================================")
print("BlueComms")
print("Local device: \(manager.deviceName) · \(manager.shortID)")
print("Fingerprint:  \(manager.fingerprint)")
print("Type 'help' for commands.")
print("========================================")

manager.onLog = { message in
    print("\n\(message)")
    printPrompt()
}

manager.onPeersUpdated = { peers in
    print("\n--- Discovered Peers ---")
    if peers.isEmpty {
        print("(none yet)")
    } else {
        for (index, peer) in peers.enumerated() {
            print("[\(index)] \(peer.displayName) · \(peer.shortName)")
        }
    }
    print("------------------------")
    printPrompt()
}

manager.onConnectionEstablished = {
    print("\nSecure session ready. Type a message, or 'disconnect' / 'quit'.")
    printPrompt()
}

manager.onMessageReceived = { message in
    print("\n[RECEIVE] \(message.utf8.count) bytes: \(message)")
    printPrompt()
}

manager.start()

// stdin on its own queue so a blocked readLine does not stall the radio.
let inputQueue = DispatchQueue(label: "bluecomms.input")
inputQueue.async {
    printPrompt()
    while true {
        guard let input = readLine() else {
            // nil = EOF. Looping here used to peg a CPU core.
            manager.stop()
            exit(0)
        }
        let trimmed = input.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty {
            printPrompt()
            continue
        }
        handleCommand(trimmed, manager: manager)
    }
}

// Keep the process alive. Network.framework needs a run loop / GCD.
RunLoop.main.run()

/// Built-in verbs first. Anything else is a chat line (only if connected).
private func handleCommand(_ raw: String, manager: NetworkManager) {
    let lowered = raw.lowercased()
    if lowered == "quit" || lowered == "exit" {
        manager.stop()
        exit(0)
    }
    if lowered == "help" {
        printHelp()
        printPrompt()
        return
    }
    if lowered == "list" {
        printPeerList(manager.peers)
        printPrompt()
        return
    }
    if lowered == "disconnect" {
        manager.disconnect()
        printPrompt()
        return
    }
    // `connect 0` or `connect Rishi's Mac`. Anything else is a chat line.
    if lowered == "connect" || lowered.hasPrefix("connect ") {
        let rest = raw.dropFirst("connect".count).trimmingCharacters(in: .whitespacesAndNewlines)
        if rest.isEmpty {
            print("Usage: connect <index|name>")
            printPrompt()
            return
        }
        if let index = Int(rest) {
            manager.connectToPeer(at: index)
        } else {
            manager.connectToPeer(named: rest)
        }
        printPrompt()
        return
    }
    if manager.isConnected {
        manager.send(message: raw)
    } else {
        print("Not connected. Type 'list', then 'connect <index>', or 'help'.")
    }
    printPrompt()
}

private func printPeerList(_ peers: [DiscoveredPeer]) {
    print("--- Discovered Peers ---")
    if peers.isEmpty {
        print("(none yet)")
    } else {
        for (index, peer) in peers.enumerated() {
            print("[\(index)] \(peer.displayName) · \(peer.shortName)")
        }
    }
    print("------------------------")
}

private func printHelp() {
    print(
        """
        Commands:
          help                 Show this list
          list                 Show discovered peers
          connect <index>      Connect by list index
          connect <name>       Connect by name or short id
          disconnect           Close the current session
          quit / exit          Stop advertising and leave
          <text>               Send a message once connected

        Two copies on one Mac need different identities:
          swift run BlueCommsCLI --data-dir /tmp/bluecomms-a
          swift run BlueCommsCLI --data-dir /tmp/bluecomms-b
        """
    )
}

/// Default is ~/.bluecomms. Override with --data-dir or BLUECOMMS_HOME so
/// two processes on the same Mac do not share an identity and hide each other.
private func dataDirectory() -> URL {
    let args = CommandLine.arguments
    if let flag = args.firstIndex(of: "--data-dir") {
        let valueIndex = args.index(after: flag)
        if valueIndex < args.endIndex {
            return URL(fileURLWithPath: args[valueIndex], isDirectory: true)
        }
        fputs("Usage: --data-dir <path>\n", stderr)
        exit(2)
    }
    if let env = ProcessInfo.processInfo.environment["BLUECOMMS_HOME"], !env.isEmpty {
        return URL(fileURLWithPath: env, isDirectory: true)
    }
    return IdentityStore.defaultDirectory
}

private func printPrompt() {
    print("> ", terminator: "")
    fflush(stdout)
}
