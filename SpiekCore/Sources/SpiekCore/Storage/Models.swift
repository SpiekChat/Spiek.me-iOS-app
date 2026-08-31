import Foundation

public enum MessageStatus: String, Codable, Sendable {
    case pending
    case sent
    case confirmed
}

/// Sort key shared with the web app: confirmed messages sort by block position,
/// unconfirmed ones fall after every confirmed message, ordered by arrival.
public func spiekSortKey(height: Int?, pos: Int?, time: Int) -> Double {
    if let height { return Double(height) * 1e6 + Double(pos ?? 0) }
    return 1e15 + Double(time)
}

public struct MessageRecord: Codable, Identifiable, Equatable, Sendable {
    public var txid: String
    public var channel: String
    public var sender: String
    public var senderPub: String
    public var senderAddress: String
    public var kind: ChannelKind
    public var op: SpiekOp
    /// Satoshis this message paid to us.
    public var payIn: UInt64
    /// Satoshis we paid out with this message.
    public var payOut: UInt64
    public var prev: String?
    public var ref: String?
    public var payload: String
    public var height: Int?
    public var pos: Int?
    public var time: Int
    public var sort: Double
    public var status: MessageStatus
    public var mine: Bool

    public var fee: UInt64?
    public var paySats: UInt64?
    /// Hex of the decrypted inner payload, once we have it.
    public var decrypted: String?
    public var decryptedOp: SpiekOp?
    public var decryptedRef: String?
    public var error: String?

    /// A later edit, persisted here when the edit's target sat outside the
    /// page being viewed — so the effect survives paging instead of being a
    /// display-time-only overlay. Hex of the new payload.
    public var editedPayload: String?
    public var editedTime: Int?
    /// True when a later `del` withdrew this message. Same persistence rule.
    public var deleted: Bool?

    public var id: String { txid }

    public init(txid: String,
                channel: String,
                sender: String,
                senderPub: String,
                senderAddress: String,
                kind: ChannelKind,
                op: SpiekOp,
                payIn: UInt64 = 0,
                payOut: UInt64 = 0,
                prev: String? = nil,
                ref: String? = nil,
                payload: String = "",
                height: Int? = nil,
                pos: Int? = nil,
                time: Int,
                sort: Double,
                status: MessageStatus,
                mine: Bool) {
        self.txid = txid
        self.channel = channel
        self.sender = sender
        self.senderPub = senderPub
        self.senderAddress = senderAddress
        self.kind = kind
        self.op = op
        self.payIn = payIn
        self.payOut = payOut
        self.prev = prev
        self.ref = ref
        self.payload = payload
        self.height = height
        self.pos = pos
        self.time = time
        self.sort = sort
        self.status = status
        self.mine = mine
    }
}

public struct ChannelRecord: Codable, Identifiable, Equatable, Sendable {
    public var channelId: String
    public var kind: ChannelKind
    /// Local-only label; never written to chain.
    public var name: String?
    /// Opt *out* of encryption for this chat. Direct messages are encrypted as
    /// soon as the other side's public key is known; the lock button in the
    /// conversation flips this flag.
    public var plain: Bool = false
    public var peerHash: String?
    public var peerPub: String?
    /// The hash of someone who announced a key on this chat *after* it already
    /// had a peer, or whose announced key was not the key that signed the
    /// record. Their key was refused; this is here so the refusal is visible
    /// rather than silent. Optional, so channel rows written by an earlier
    /// build still decode.
    public var peerKeyConflict: String?
    public var lastTxid: String?
    public var lastTime: Int
    public var lastSort: Double
    public var lastRead: Int
    public var unread: Int
    /// v1.20, encrypted groups: hex of the 32-byte symmetric group key. It
    /// travels in the invite code and never touches the chain. Nil for direct
    /// messages, notes and the public (pre-1.20 or keyless) groups. Optional,
    /// so channel rows written by an earlier build still decode.
    public var groupKey: String?

    public var id: String { channelId }

    public init(channelId: String,
                kind: ChannelKind,
                name: String? = nil,
                plain: Bool = false,
                peerHash: String? = nil,
                peerPub: String? = nil,
                peerKeyConflict: String? = nil,
                lastTxid: String? = nil,
                lastTime: Int = 0,
                lastSort: Double = 0,
                lastRead: Int = 0,
                unread: Int = 0,
                groupKey: String? = nil) {
        self.channelId = channelId
        self.kind = kind
        self.name = name
        self.plain = plain
        self.peerHash = peerHash
        self.peerPub = peerPub
        self.peerKeyConflict = peerKeyConflict
        self.lastTxid = lastTxid
        self.lastTime = lastTime
        self.lastSort = lastSort
        self.lastRead = lastRead
        self.unread = unread
        self.groupKey = groupKey
    }

    public var inviteCode: String { InviteCode.encode(channelId: channelId, kind: kind, groupKey: groupKey) }

    /// Keyless group chats have no shared secret: anyone holding the code can read and
    /// write. Worth saying out loud wherever a group is shown. Notes-to-self do
    /// have one — they encrypt against the wallet's own key.
    public var isEncryptable: Bool { kind == .dm || kind == .note }

    /// Hand-written so a channel stored by an older build — which had no
    /// `plain` key — still decodes. The synthesized decoder ignores property
    /// defaults and would throw `keyNotFound`, which the store swallows,
    /// silently dropping the whole chat list on upgrade.
    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        channelId = try container.decode(String.self, forKey: .channelId)
        kind = try container.decode(ChannelKind.self, forKey: .kind)
        name = try container.decodeIfPresent(String.self, forKey: .name)
        plain = try container.decodeIfPresent(Bool.self, forKey: .plain) ?? false
        peerHash = try container.decodeIfPresent(String.self, forKey: .peerHash)
        peerPub = try container.decodeIfPresent(String.self, forKey: .peerPub)
        // This decoder is hand-written, so a new property is *not* picked up by
        // "optionals decode as nil when absent" — that only holds for the
        // synthesised one. Left out, the field would be written to the store
        // and read back as nil every time, which would make the refusal it
        // records invisible: exactly the silence it exists to end.
        peerKeyConflict = try container.decodeIfPresent(String.self, forKey: .peerKeyConflict)
        lastTxid = try container.decodeIfPresent(String.self, forKey: .lastTxid)
        lastTime = try container.decodeIfPresent(Int.self, forKey: .lastTime) ?? 0
        lastSort = try container.decodeIfPresent(Double.self, forKey: .lastSort) ?? 0
        lastRead = try container.decodeIfPresent(Int.self, forKey: .lastRead) ?? 0
        unread = try container.decodeIfPresent(Int.self, forKey: .unread) ?? 0
    }
}

/// Bookmark for the oldest message we hold from one sender in one channel, so
/// "load older" knows where to keep walking back.
public struct ChainRecord: Codable, Equatable, Sendable {
    public var key: String
    public var oldestTxid: String
    public var oldestPrev: String?
    public var oldestSort: Double

    public init(key: String, oldestTxid: String, oldestPrev: String?, oldestSort: Double) {
        self.key = key
        self.oldestTxid = oldestTxid
        self.oldestPrev = oldestPrev
        self.oldestSort = oldestSort
    }
}

public struct OutboxItem: Codable, Equatable, Sendable {
    public var txid: String
    public var rawHex: String
    public var channel: String
    public var time: Int

    public init(txid: String, rawHex: String, channel: String, time: Int) {
        self.txid = txid
        self.rawHex = rawHex
        self.channel = channel
        self.time = time
    }
}

public struct StoredProfile: Codable, Equatable, Sendable {
    public var name: String?
    public var bio: String?
    public var time: Int

    public init(name: String?, bio: String?, time: Int) {
        self.name = name
        self.bio = bio
        self.time = time
    }
}

/// Persisted account material. The phrase is optional because a wallet can also
/// be restored from a bare WIF key.
public struct StoredAccount: Codable, Equatable, Sendable {
    public var wif: String
    public var phrase: String?
    /// Which derivation the phrase belongs to, so the settings screen can say
    /// so and a re-import stays consistent. Absent for accounts stored before
    /// BIP-39 support existed, which were all legacy.
    public var scheme: PhraseScheme?

    public init(wif: String, phrase: String?, scheme: PhraseScheme? = nil) {
        self.wif = wif
        self.phrase = phrase
        self.scheme = scheme
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        wif = try container.decode(String.self, forKey: .wif)
        phrase = try container.decodeIfPresent(String.self, forKey: .phrase)
        // An account stored before v13 has a phrase but no scheme, and such a
        // phrase can only have come from the legacy derivation.
        let storedScheme = try container.decodeIfPresent(PhraseScheme.self, forKey: .scheme)
        scheme = storedScheme ?? (phrase != nil ? .legacy : nil)
    }
}

public enum WalletMode: String, Codable, CaseIterable, Sendable {
    /// Talks to the public Spiek endpoints.
    case chain
    /// Talks to endpoints the user configured themselves.
    case node
    /// Entirely local; nothing is broadcast.
    case demo
}

public struct Settings: Codable, Equatable, Sendable {
    public var mode: WalletMode?
    public var feePerByte: Double
    public var dust: UInt64
    public var mediaLimitMB: Int
    public var pollSeconds: Int
    // No fiat rate is stored here any more. It used to be a number the user
    // typed, defaulting to 55, which meant the wallet quoted a price nobody had
    // checked. The live rate is fetched instead — see `PriceFeed`. An older
    // settings blob still carrying `eurPerBSV` decodes fine: the key is simply
    // no longer read.
    /// Also push every broadcast to WhatsOnChain, which gets a transaction
    /// seen faster but tells a third party what you sent.
    public var mirrorBroadcast: Bool = true
    /// Ask for Face ID, Touch ID or the device passcode before opening.
    public var requireUnlock: Bool = false
    /// Raise a local notification when a background refresh finds something.
    public var notifyOnNewMessages: Bool = true
    public var getTxURL: String
    public var watchURL: String
    public var broadcastURL: String
    public var utxoURL: String
    /// BSV21 token-index base URL (…/bsv21/v1); blank = no token section.
    public var tokenURL: String = ""

    /// Miners started rejecting anything under this, so it is both the
    /// default and a hard floor.
    public static let minimumFeePerByte: Double = 0.1

    public static let defaultEndpoints = (
        getTx: "https://spiek.me/api/v2/tx/{txid}",
        watch: "https://spiek.me/api/v2/address/{address}?since={since}",
        broadcast: "https://spiek.me/api/v2/broadcast",
        utxo: "https://api.whatsonchain.com/v1/bsv/main/address/{address}/unspent"
    )

    public init(mode: WalletMode? = nil,
                feePerByte: Double = 0.1,
                dust: UInt64 = 1,
                mediaLimitMB: Int = 200,
                pollSeconds: Int = 30,
                mirrorBroadcast: Bool = true,
                requireUnlock: Bool = false,
                notifyOnNewMessages: Bool = true,
                getTxURL: String = "",
                watchURL: String = "",
                broadcastURL: String = "",
                utxoURL: String = "",
                tokenURL: String = "") {
        self.mode = mode
        self.feePerByte = feePerByte
        self.dust = dust
        self.mediaLimitMB = mediaLimitMB
        self.pollSeconds = pollSeconds
        self.mirrorBroadcast = mirrorBroadcast
        self.requireUnlock = requireUnlock
        self.notifyOnNewMessages = notifyOnNewMessages
        self.getTxURL = getTxURL
        self.watchURL = watchURL
        self.broadcastURL = broadcastURL
        self.utxoURL = utxoURL
        self.tokenURL = tokenURL
    }

    /// Tolerant decoding, so a settings blob written by an earlier build keeps
    /// working when new keys appear.
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        mode = try c.decodeIfPresent(WalletMode.self, forKey: .mode)
        feePerByte = try c.decodeIfPresent(Double.self, forKey: .feePerByte) ?? 0.1
        dust = try c.decodeIfPresent(UInt64.self, forKey: .dust) ?? 1
        mediaLimitMB = try c.decodeIfPresent(Int.self, forKey: .mediaLimitMB) ?? 200
        pollSeconds = try c.decodeIfPresent(Int.self, forKey: .pollSeconds) ?? 30
        mirrorBroadcast = try c.decodeIfPresent(Bool.self, forKey: .mirrorBroadcast) ?? true
        requireUnlock = try c.decodeIfPresent(Bool.self, forKey: .requireUnlock) ?? false
        notifyOnNewMessages = try c.decodeIfPresent(Bool.self, forKey: .notifyOnNewMessages) ?? true
        getTxURL = try c.decodeIfPresent(String.self, forKey: .getTxURL) ?? ""
        watchURL = try c.decodeIfPresent(String.self, forKey: .watchURL) ?? ""
        broadcastURL = try c.decodeIfPresent(String.self, forKey: .broadcastURL) ?? ""
        utxoURL = try c.decodeIfPresent(String.self, forKey: .utxoURL) ?? ""
        tokenURL = try c.decodeIfPresent(String.self, forKey: .tokenURL) ?? ""
    }

    /// Clamps anything a stored settings blob or the settings screen might
    /// hand back to something the network will actually accept.
    public func normalized() -> Settings {
        var copy = self
        if !copy.feePerByte.isFinite || copy.feePerByte < Settings.minimumFeePerByte {
            copy.feePerByte = Settings.minimumFeePerByte
        }
        // An upper bound as well: several places multiply this by a byte count
        // and convert to UInt64, which traps on an absurd typed value.
        copy.feePerByte = min(copy.feePerByte, 100)
        copy.dust = max(1, copy.dust)
        copy.pollSeconds = min(600, max(10, copy.pollSeconds))
        copy.mediaLimitMB = min(2000, max(10, copy.mediaLimitMB))
        return copy
    }

    /// Fills blank endpoints with the public defaults for chain mode.
    public func resolvedEndpoints() -> Settings {
        var copy = self
        if copy.getTxURL.isEmpty { copy.getTxURL = Settings.defaultEndpoints.getTx }
        if copy.watchURL.isEmpty { copy.watchURL = Settings.defaultEndpoints.watch }
        if copy.broadcastURL.isEmpty { copy.broadcastURL = Settings.defaultEndpoints.broadcast }
        if copy.utxoURL.isEmpty { copy.utxoURL = Settings.defaultEndpoints.utxo }
        return copy
    }
}
