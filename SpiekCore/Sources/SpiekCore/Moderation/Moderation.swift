import Foundation

/// Trust & Safety plumbing shared by every client (v1.21, P0.2).
///
/// The operator publishes a **signed moderation feed**: entries that name a
/// txid or a sender hash with one of three levels. Clients enforce it by
/// default — `soft_hide` can be shown on request, `policy_block` cannot, and
/// `legal_block` is never rendered and never triggers a media fetch. The feed
/// is signed exactly like an SNS answer (canonical form, sha256d, secp256k1
/// DER) under a key pinned in the client. A feed that fails verification, is
/// expired, or carries a lower sequence than the last accepted one is ignored
/// — and ignoring a feed never releases an existing hard block.
public enum Moderation {

    public static let feedKey = "modfeed"
    public static let blockedKey = "blocked"
    public static let termsKey = "terms"
    public static let reportsKey = "reports"
    public static let disclosureKey = "disclosed"

    /// Bump when the Terms/Community Standards text changes; users re-accept.
    public static let termsVersion = "2026-09-01"

    /// The operator's feed-signing key: keyId (first 8 hex of SHA-256 of the
    /// compressed public key) and the key itself. Empty means no feed is trusted
    /// — fail-closed, nothing is ever released. Set after `tools/feed.mjs keygen`.
    public static let pinnedKeyId = ""
    public static let pinnedPubkey = ""

    public enum Level: String, Comparable, Codable, Sendable {
        case softHide = "soft_hide"
        case policyBlock = "policy_block"
        case legalBlock = "legal_block"
        var rank: Int { switch self { case .softHide: return 1; case .policyBlock: return 2; case .legalBlock: return 3 } }
        public static func < (a: Level, b: Level) -> Bool { a.rank < b.rank }
    }

    public struct Entry: Codable, Equatable, Sendable {
        public let kind: String
        public let value: String
        public let level: Level
        public init(kind: String, value: String, level: Level) { self.kind = kind; self.value = value; self.level = level }
    }

    public struct Feed: Codable, Equatable, Sendable {
        public var version: Int
        public var seq: Int64
        public var issuedAt: String
        public var expiresAt: String
        public var keyId: String
        public var signer: String
        public var entries: [Entry]
        public var sig: String

        /// The strictest level that applies to a record, or nil.
        public func level(txid: String?, sender: String?) -> Level? {
            var best: Level?
            for entry in entries {
                let hit = (entry.kind == "txid" && txid?.lowercased() == entry.value.lowercased())
                    || (entry.kind == "sender" && sender?.lowercased() == entry.value.lowercased())
                if hit, best == nil || entry.level > best! { best = entry.level }
            }
            return best
        }
    }

    public enum Verdict: Equatable { case ok, malformed, wrongKey, badSignature, expired, stale }

    public static func parse(_ data: Data) -> Feed? {
        guard let feed = try? JSONDecoder().decode(Feed.self, from: data), feed.version == 1 else { return nil }
        let hex = CharacterSet(charactersIn: "0123456789abcdef")
        for entry in feed.entries {
            guard entry.kind == "txid" || entry.kind == "sender",
                  entry.value.count == 40 || entry.value.count == 64,
                  entry.value.unicodeScalars.allSatisfy({ hex.contains($0) }) else { return nil }
        }
        return feed
    }

    /// `UTF8("spiek-modfeed-v1")` then, per field, `0x1f` + `UTF8(field)`; the
    /// fields are version, seq, issuedAt, expiresAt, keyId and the entries as
    /// `kind:value:level`, sorted, joined with commas. Same shape as SNS.
    public static func canonical(_ feed: Feed) -> [UInt8] {
        let entries = feed.entries.map { "\($0.kind):\($0.value.lowercased()):\($0.level.rawValue)" }.sorted().joined(separator: ",")
        let fields = [String(feed.version), String(feed.seq), feed.issuedAt, feed.expiresAt, feed.keyId, entries]
        var out = Array("spiek-modfeed-v1".utf8)
        for field in fields { out.append(0x1f); out.append(contentsOf: Array(field.utf8)) }
        return out
    }

    public static func keyId(of pubkeyHex: String) -> String {
        guard let bytes = Hex.decode(pubkeyHex) else { return "" }
        return String(Hash.sha256(bytes).hex.prefix(8))
    }

    /// Verifies a feed against the pinned key. `lastAcceptedSeq` guards against
    /// rollback/replay: an older feed, however validly signed, is refused.
    public static func verify(_ feed: Feed,
                              pinnedKeyId: String = Moderation.pinnedKeyId,
                              pinnedPubkey: String = Moderation.pinnedPubkey,
                              lastAcceptedSeq: Int64 = 0,
                              now: String = ISO8601DateFormatter().string(from: Date())) -> Verdict {
        if feed.version != 1 { return .malformed }
        if pinnedKeyId.isEmpty || pinnedPubkey.isEmpty { return .wrongKey }
        if feed.keyId != pinnedKeyId || feed.signer.lowercased() != pinnedPubkey.lowercased() { return .wrongKey }
        if feed.keyId != keyId(of: feed.signer) { return .wrongKey }
        guard SNS.isSignatureValid(digest: Hash.sha256d(canonical(feed)), derHex: feed.sig, publicKeyHex: feed.signer) else { return .badSignature }
        if feed.expiresAt < now { return .expired }
        if lastAcceptedSeq > 0, feed.seq <= lastAcceptedSeq { return .stale }
        return .ok
    }

    public static func accepted(_ store: Store) async throws -> Feed? {
        try await store.meta(Feed.self, key: feedKey)
    }

    /// Accepts a fresh feed if it verifies and is newer; returns the verdict.
    /// On anything but `.ok` the previously accepted feed stays in force.
    public static func accept(_ store: Store, data: Data,
                              pinnedKeyId: String = Moderation.pinnedKeyId,
                              pinnedPubkey: String = Moderation.pinnedPubkey) async throws -> Verdict {
        guard let feed = parse(data) else { return .malformed }
        let last = try await accepted(store)?.seq ?? 0
        let verdict = verify(feed, pinnedKeyId: pinnedKeyId, pinnedPubkey: pinnedPubkey, lastAcceptedSeq: last)
        if verdict == .ok { try await store.putMeta(key: feedKey, value: feed) }
        return verdict
    }

    // MARK: Terms

    public struct TermsRecord: Codable, Sendable { public let version: String; public let acceptedAt: String }

    public static func termsAccepted(_ store: Store) async -> Bool {
        (try? await store.meta(TermsRecord.self, key: termsKey))?.version == termsVersion
    }

    public static func acceptTerms(_ store: Store) async throws {
        try await store.putMeta(key: termsKey, value: TermsRecord(version: termsVersion, acceptedAt: ISO8601DateFormatter().string(from: Date())))
    }

    // MARK: Just-in-time disclosures (P0.3)

    public static func disclosed(_ store: Store, topic: String) async -> Bool {
        ((try? await store.meta([String: Bool].self, key: disclosureKey)) ?? [:])[topic] == true
    }

    public static func markDisclosed(_ store: Store, topic: String) async throws {
        var current = (try? await store.meta([String: Bool].self, key: disclosureKey)) ?? [:]
        current[topic] = true
        try await store.putMeta(key: disclosureKey, value: current)
    }

    // MARK: Report categories (the service refuses anything else)

    public static let categories: [(id: String, label: String)] = [
        ("user", "A person"),
        ("text_message", "A text message"),
        ("media", "An image"),
        ("public_group", "A public group"),
        ("encrypted_group", "An encrypted group"),
        ("spam_scam", "Spam or scam"),
        ("harassment_threat", "Harassment or threat"),
        ("illegal_content", "Illegal content"),
        ("child_safety", "Child safety (CSAE)"),
    ]
}
