import Foundation

/// Images live on chain in their own transaction, and a message references one
/// by outpoint — so the same picture can be linked from several chats without
/// paying to store it twice.
///
/// Two formats exist. Current builds inscribe a 1Sat Ordinal, which makes the
/// image an asset the recipient owns. Earlier ones wrote a plain
/// `"spiekmedia"` data output. Reading accepts both; writing only produces the
/// inscription.
public enum Media {
    public static let legacyPrefix: [UInt8] = Array("spiekmedia".utf8)

    /// Anything larger than this is refused before it costs money.
    public static let maximumBytes = 5 * 1024 * 1024

    public struct Stored: Sendable {
        public let mime: String
        public let bytes: Data
    }

    public struct Published: Sendable {
        public let txid: String
        public let vout: UInt32
        public let size: Int
        public let mime: String
        public let fee: UInt64
    }

    public enum Failure: Error, LocalizedError {
        case notAnImage
        case tooLarge(Int)

        public var errorDescription: String? {
            switch self {
            case .notAnImage:
                return "Only images can be inscribed here."
            case let .tooLarge(bytes):
                let megabytes = Double(bytes) / 1_048_576
                return String(format: "That is %.1f MB — larger than 5 MB. Compress it further.", megabytes)
            }
        }
    }

    /// The legacy `"spiekmedia"` data output, kept for reading old messages.
    public static func legacyScript(bytes: Data, mime: String) -> [UInt8] {
        var script: [UInt8] = [0x00, Opcode.OP_RETURN]
        script += Script.pushData(legacyPrefix)
        script += Script.pushData(Array(mime.utf8))
        script += Script.pushData([UInt8](bytes))
        return script
    }

    public static func decode(transactionHex: String, vout: Int) -> Stored? {
        guard let tx = Transaction.parse(hex: transactionHex),
              vout >= 0, vout < tx.outputs.count else { return nil }
        return decode(script: tx.outputs[vout].lockingScript)
    }

    public static func decode(script: [UInt8]) -> Stored? {
        if let inscription = Ordinal.parse(script: script) {
            return Stored(mime: inscription.mime, bytes: inscription.bytes)
        }
        guard script.count >= 2, script[0] == 0x00, script[1] == Opcode.OP_RETURN,
              let chunks = Script.parsePushes(script, from: 2),
              chunks.count >= 3,
              chunks[0] == legacyPrefix else { return nil }
        return Stored(mime: String(decoding: chunks[1], as: UTF8.self),
                      bytes: Data(chunks[2]))
    }

    public static func isSupported(mime: String) -> Bool {
        mime.hasPrefix("image/")
    }
}

public extension Engine {
    /// Inscribes an image as a 1Sat Ordinal and returns the outpoint a message
    /// can point at. The satoshi is inscribed to `owner` — the person being
    /// sent the picture — so it lands in their wallet, not the sender's.
    func publishMedia(bytes: Data, mime: String, ownerHash: [UInt8]? = nil) async throws -> Media.Published {
        guard Media.isSupported(mime: mime) else { throw Media.Failure.notAnImage }
        guard bytes.count <= Media.maximumBytes else { throw Media.Failure.tooLarge(bytes.count) }

        // The same lock a send takes: an inscription spends from the same UTXO
        // set, and two builders reading it at once select the same coins.
        await lockCompose()
        defer { unlockCompose() }

        let built = try buildInscription(bytes: bytes, mime: mime, ownerHash: ownerHash)
        try await store.putOutbox(OutboxItem(txid: built.txid,
                                             rawHex: built.rawHex,
                                             channel: "",
                                             time: Int(Date().timeIntervalSince1970)))
        // The catch must cover the broadcast and nothing else. If it also
        // covered `deleteOutbox`, a database error after a *successful*
        // broadcast would hand back coins that are already spent on chain, and
        // the next send would build a conflicting transaction.
        do {
            _ = try await broadcastRaw(built.rawHex)
        } catch {
            let reason = String(describing: error).lowercased()
            // "Already known" means the node has it — the coins really are
            // spent, so releasing them would be wrong. Leave the outbox row in
            // place; `flushOutbox` sorts it out.
            if !(reason.contains("already known") || reason.contains("already in the mempool")) {
                releaseCoins(rawHex: built.rawHex)
                // Best effort: the throw below must carry the broadcast error,
                // not whatever the cleanup ran into.
                try? await store.deleteOutbox(txid: built.txid)
            }
            throw error
        }
        try? await store.deleteOutbox(txid: built.txid)

        try await store.putMedia(outpoint: "\(built.txid):0",
                                 bytes: bytes,
                                 mime: mime,
                                 lastUsed: Int(Date().timeIntervalSince1970))
        try await persistUTXOs()
        return Media.Published(txid: built.txid, vout: 0, size: bytes.count, mime: mime, fee: built.fee)
    }

    /// Fetches an image, preferring the local cache.
    func loadMedia(txid: String, vout: UInt32, mediaLimitMB: Int) async throws -> Media.Stored? {
        let outpoint = "\(txid):\(vout)"
        let timestamp = Int(Date().timeIntervalSince1970)

        if let cached = try await store.media(outpoint: outpoint) {
            try await store.touchMedia(outpoint: outpoint, at: timestamp)
            return Media.Stored(mime: cached.mime, bytes: cached.bytes)
        }

        guard let chainTx = try await fetchRaw(txid: txid),
              let stored = Media.decode(transactionHex: chainTx.hex, vout: Int(vout)) else { return nil }

        try await store.putMedia(outpoint: outpoint,
                                 bytes: stored.bytes,
                                 mime: stored.mime,
                                 lastUsed: timestamp)
        try await store.trimMedia(toBytes: mediaLimitMB * 1_000_000)
        return stored
    }

    /// What inscribing this many bytes would cost, so the composer can show it
    /// before the user commits.
    nonisolated func inscriptionFeeEstimate(byteCount: Int, settings: Settings) -> UInt64 {
        let scriptSize = 25 + 2 + 5 + 1 + 12 + 1 + byteCount + 6
        let size = 10 + 148 + (9 + scriptSize) + (9 + 25)
        return max(10, UInt64(ceil(Double(size) * settings.feePerByte))) + 1
    }
}
