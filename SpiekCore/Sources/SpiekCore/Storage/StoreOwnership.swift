import Foundation

/// Wallet-bound storage (v1.21, P0.5).
///
/// A store belongs to exactly one wallet. The owner is recorded as a
/// domain-separated fingerprint of the wallet's *public* identity —
/// `SHA256("spiek-owner-v1" || compressed public key)` — never anything derived
/// from the mnemonic, seed, private key or WIF. The full fingerprint is
/// compared; nothing is decided on a short prefix.
///
/// A store without an owner record (written by a build before 1.21) is adopted
/// only when its contents deterministically prove they belong to the active
/// wallet: it is empty, or it carries this wallet's own notes channel / own
/// sent records. Anything else is a mismatch, and a mismatch means quarantine:
/// the app must not render or use a single byte of it.
public enum StoreOwnership {

    public static let metaKey = "owner"
    private static let domain = "spiek-owner-v1"

    public enum Verdict: Equatable {
        /// Owner record present and equal to the active wallet.
        case match
        /// No owner record, store empty: claimed for the active wallet.
        case adoptedEmpty
        /// No owner record, but the contents prove the wallet: claimed.
        case adoptedVerified
        /// Owner record differs, or ownerless contents do not prove the wallet.
        case mismatch
    }

    public static func fingerprint(compressedPublicKey: [UInt8]) -> String {
        Hash.sha256(Array(domain.utf8) + compressedPublicKey).hex
    }

    /// Checks — and on adoption records — the owner of `store`. Never writes on
    /// a mismatch. Call before the first UI render and before an engine touches
    /// the store.
    public static func verify(store: Store, fingerprint: String, ownHash: String) async throws -> Verdict {
        if let recorded = try await store.meta(String.self, key: metaKey) {
            return recorded.lowercased() == fingerprint.lowercased() ? .match : .mismatch
        }
        let channels = try await store.allChannels()
        if channels.isEmpty {
            try await store.putMeta(key: metaKey, value: fingerprint)
            return .adoptedEmpty
        }
        // Deterministic proof: the notes channel *is* the owner's hash160, and
        // only the owner can have written `mine` records.
        let ownsNotes = channels.contains { $0.kind == .note && $0.channelId.lowercased() == ownHash.lowercased() }
        var ownsRecords = false
        if !ownsNotes {
            for channel in channels {
                let mine = try await store.messages(channel: channel.channelId, sender: ownHash)
                if mine.contains(where: { $0.mine }) { ownsRecords = true; break }
            }
        }
        if ownsNotes || ownsRecords {
            try await store.putMeta(key: metaKey, value: fingerprint)
            return .adoptedVerified
        }
        return .mismatch
    }
}

/// Quarantine of a store that belongs to another wallet (v1.21, P0.5). The
/// files are moved aside under an opaque, random name — nothing in the name
/// says whose data it is — and the move is journaled so a crash halfway is
/// completed on the next start. Orphans are never opened; they can only be
/// deleted.
public enum StoreQuarantine {

    private static let journalKey = "spiek.orphans"

    public struct Orphan: Equatable {
        public let id: String
        public let state: String
    }

    static func randomId() -> String {
        var bytes = [UInt8](repeating: 0, count: 16)
        for index in bytes.indices { bytes[index] = UInt8.random(in: 0...255) }
        return bytes.hex
    }

    /// Moves the live store (and its -wal/-shm sidecars) aside. Returns the orphan id.
    @discardableResult
    public static func quarantine(liveDatabase: URL, defaults: UserDefaults = .standard) -> String {
        let id = randomId()
        journal(id: id, state: "moving", defaults: defaults)
        move(liveDatabase: liveDatabase, id: id)
        journal(id: id, state: "done", defaults: defaults)
        return id
    }

    /// Completes a quarantine interrupted by a crash. Safe to call every start.
    public static func recoverInterrupted(liveDatabase: URL, defaults: UserDefaults = .standard) {
        for orphan in orphans(defaults: defaults) where orphan.state == "moving" {
            move(liveDatabase: liveDatabase, id: orphan.id)
            journal(id: orphan.id, state: "done", defaults: defaults)
        }
    }

    public static func orphans(defaults: UserDefaults = .standard) -> [Orphan] {
        let raw = defaults.string(forKey: journalKey) ?? ""
        return raw.split(separator: ";").compactMap { entry in
            let parts = entry.split(separator: ":", maxSplits: 1).map(String.init)
            guard parts.count == 2 else { return nil }
            return Orphan(id: parts[0], state: parts[1])
        }
    }

    /// Deletes an orphaned store without ever opening it.
    public static func delete(id: String, liveDatabase: URL, defaults: UserDefaults = .standard) {
        let folder = liveDatabase.deletingLastPathComponent()
        for suffix in ["", "-wal", "-shm"] {
            try? FileManager.default.removeItem(at: folder.appendingPathComponent("spiek-orphan-\(id).sqlite\(suffix)"))
        }
        let remaining = orphans(defaults: defaults).filter { $0.id != id }
        defaults.set(remaining.map { "\($0.id):\($0.state)" }.joined(separator: ";"), forKey: journalKey)
    }

    private static func move(liveDatabase: URL, id: String) {
        let folder = liveDatabase.deletingLastPathComponent()
        let orphan = folder.appendingPathComponent("spiek-orphan-\(id).sqlite")
        for suffix in ["", "-wal", "-shm"] {
            let from = URL(fileURLWithPath: liveDatabase.path + suffix)
            let to = URL(fileURLWithPath: orphan.path + suffix)
            if FileManager.default.fileExists(atPath: from.path) {
                try? FileManager.default.moveItem(at: from, to: to)
            }
        }
    }

    private static func journal(id: String, state: String, defaults: UserDefaults) {
        var others = orphans(defaults: defaults).filter { $0.id != id }
        others.append(Orphan(id: id, state: state))
        defaults.set(others.map { "\($0.id):\($0.state)" }.joined(separator: ";"), forKey: journalKey)
        defaults.synchronize()
    }
}
