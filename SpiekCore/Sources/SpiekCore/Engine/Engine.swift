import Foundation

/// A message shaped for display: encrypted records are already opened, and
/// edits, deletions and reactions from later records have been applied.
public struct ViewMessage: Identifiable, Equatable, Sendable {
    public var record: MessageRecord
    /// The effective operation — for an `emsg` this is what was inside.
    public var viewOp: SpiekOp
    public var viewPayload: [UInt8]
    public var encrypted: Bool
    /// True when the record is an `emsg` we could not open.
    public var unreadable: Bool
    /// v1.21 (P0.2): the moderation feed marked this `soft_hide` — shown only on request.
    public var hiddenSoft: Bool = false

    public var edited: [UInt8]? = nil
    public var editTime: Int? = nil
    public var deleted: Bool = false
    public var reactions: [Reaction] = []
    /// Set when this message is a reply — a plain message carrying a `ref`.
    public var replyTo: Quote? = nil

    /// A one-line preview of the message a reply points at.
    public struct Quote: Equatable, Sendable {
        public var txid: String
        public var sender: String
        public var mine: Bool
        public var preview: String
        /// True when the original is not on this device, so only a
        /// placeholder can be shown.
        public var isMissing: Bool
    }

    public struct Reaction: Equatable, Sendable {
        public var sender: String
        public var emoji: String
        public var mine: Bool
    }

    public var id: String { record.txid }

    /// v1.20: public on purpose — the app builds a synthetic pending row for
    /// the optimistic send echo and replaces it on the next reload.
    public init(record: MessageRecord,
                viewOp: SpiekOp,
                viewPayload: [UInt8],
                encrypted: Bool,
                unreadable: Bool) {
        self.record = record
        self.viewOp = viewOp
        self.viewPayload = viewPayload
        self.encrypted = encrypted
        self.unreadable = unreadable
    }

    public var text: String {
        if let edited { return Codecs.decodeText(edited) }
        return Codecs.decodeText(viewPayload)
    }

    public var mediaRef: Codecs.MediaRef? {
        viewOp == .media ? Codecs.decodeMedia(viewPayload) : nil
    }
}

public protocol EngineDelegate: AnyObject, Sendable {
    /// Called whenever stored state changed and the UI should re-read it.
    func engineDidUpdate() async
}

/// Drives everything: polling the chain, decoding records into the store,
/// composing and broadcasting new messages.
public actor Engine {
    /// Private on purpose: the wallet is not thread-safe on its own, and this
    /// actor is the only thing allowed to touch it.
    private let wallet: Wallet
    private let adapter: any ChainAdapter
    /// `nonisolated` is required, not decorative: a `let` on an actor is only
    /// implicitly non-isolated *within* its own module. The app target is a
    /// different module, so reading `engine.store` from a view is an error in
    /// the Swift 6 language mode without this. `Store` is itself an actor, and
    /// therefore Sendable, so handing it across is sound.
    public nonisolated let store: Store
    private weak var delegate: (any EngineDelegate)?

    private var pollTask: Task<Void, Never>?
    private var utxoTask: Task<Void, Never>?
    /// Serialises composing so two concurrent sends never claim the same
    /// `prev`. Actor isolation alone does not prevent this: both would suspend
    /// at their first `await` and resume with the same answer.
    private var sendGate: Task<Void, Never>?

    public init(wallet: Wallet,
                adapter: any ChainAdapter,
                store: Store,
                delegate: (any EngineDelegate)? = nil) {
        self.wallet = wallet
        self.adapter = adapter
        self.store = store
        self.delegate = delegate
    }

    public func setDelegate(_ delegate: (any EngineDelegate)?) {
        self.delegate = delegate
    }

    private func now() -> Int { Int(Date().timeIntervalSince1970) }

    // MARK: Wallet surface for the UI

    public nonisolated var address: String { wallet.address }
    public nonisolated var publicKeyHex: String { wallet.publicKeyBytes.hex }
    public nonisolated var hashHex: String { wallet.hash.hex }
    public nonisolated var recoveryWIF: String { wallet.key.wif }

    public func balance() -> UInt64 { wallet.balance }
    public func confirmedBalance() -> UInt64 { wallet.confirmedBalance }
    public func unspentOutputs() -> [UTXO] { Array(wallet.utxos.values) }

    public func updateFeePolicy(feePerByte: Double, dust: UInt64) {
        wallet.feePerByte = feePerByte
        wallet.dust = dust
    }

    /// Escape hatches for the media layer, which builds its own transactions.
    func broadcastRaw(_ rawHex: String) async throws -> String {
        try await adapter.broadcast(rawHex)
    }

    /// Returns the inputs of a transaction that never reached the network. The
    /// wallet itself stays private, so the media layer asks through here.
    func releaseCoins(rawHex: String) {
        wallet.release(rawHex: rawHex)
    }

    func buildInscription(bytes: Data, mime: String, ownerHash: [UInt8]?) throws -> BuiltTransaction {
        let owner = ownerHash ?? wallet.hash
        return try wallet.buildDataTransaction(
            script: Ordinal.script(owner: owner, mime: mime, bytes: bytes),
            satoshis: 1
        )
    }

    /// Sends coins straight to an address, with no chat and no record.
    @discardableResult
    public func pay(address: String, satoshis: UInt64) async throws -> BuiltTransaction {
        guard let hash = Address.hash160(from: address) else { throw KeyError.invalidAddress }
        await lockCompose()
        defer { unlockCompose() }

        // The 10-sat service fee travels as its own output on the same
        // transaction, so one broadcast settles both.
        let serviceOutputs = ServiceFee.paymentTarget.map { [$0] } ?? []
        let built = try wallet.buildPayment(to: hash, satoshis: satoshis, extraPayTo: serviceOutputs)
        try await store.putOutbox(OutboxItem(txid: built.txid,
                                             rawHex: built.rawHex,
                                             channel: "",
                                             time: now()))
        // Only the broadcast is guarded. A database error after a *successful*
        // broadcast must not release coins that are already spent on chain —
        // the next payment would then build a conflicting transaction.
        do {
            _ = try await adapter.broadcast(built.rawHex)
        } catch {
            let reason = String(describing: error).lowercased()
            // "Already known" means the node has it; the coins are genuinely
            // spent, so leave the outbox row for `flushOutbox` to resolve.
            if !(reason.contains("already known") || reason.contains("already in the mempool")) {
                wallet.release(rawHex: built.rawHex)
                // Best effort: the throw must carry the broadcast error.
                try? await store.deleteOutbox(txid: built.txid)
            }
            throw error
        }
        try? await store.deleteOutbox(txid: built.txid)

        // A local record of the payment, or money would move with no trace
        // anywhere in the app once the toast fades. `senderAddress` carries
        // the *destination* here — the row is local-only and `mine`, so the
        // field is free — and the reserved channel keeps it out of the chat
        // list while the wallet's Activity screen reads it.
        let timestamp = now()
        var record = MessageRecord(txid: built.txid,
                                   channel: Engine.paymentsChannel,
                                   sender: wallet.hash.hex,
                                   senderPub: wallet.publicKeyBytes.hex,
                                   senderAddress: address,
                                   kind: .note,
                                   op: .msg,
                                   payOut: satoshis,
                                   time: timestamp,
                                   sort: spiekSortKey(height: nil, pos: nil, time: timestamp),
                                   status: .sent,
                                   mine: true)
        record.fee = built.fee
        record.paySats = satoshis
        try? await store.putMessage(record)

        try await persistUTXOs()
        await notifyUpdate()
        return built
    }

    /// The reserved local-only channel bare payments are recorded under. Not a
    /// chat: no ChannelRecord row is ever written for it, so it cannot appear
    /// in the chat list — only the wallet's Activity list reads it. It can
    /// never collide with a real channel id, which is always 40 hex characters.
    public static let paymentsChannel = "payments"

    /// The hash160 the other side of a chat is reachable at, if we know it.
    public func peerHash(channelId: String) async throws -> [UInt8]? {
        guard let channel = try await store.channel(channelId),
              channel.kind == .dm,
              let peerHash = channel.peerHash else { return nil }
        return Hex.decode(peerHash)
    }

    /// The five-group fingerprint both sides compare to rule out a key swap.
    /// Derived from the two public keys in a fixed order, so both ends produce
    /// the same string.
    public func keyFingerprint(channelId: String) async throws -> String? {
        // Direct messages only. A note would produce a fingerprint of our own
        // key against itself, which verifies nothing and reads as if there were
        // a second party.
        guard let channel = try await store.channel(channelId),
              channel.kind == .dm,
              let peerPub = channel.peerPub else { return nil }
        let mine = wallet.publicKeyBytes.hex
        let combined = mine < peerPub ? mine + peerPub : peerPub + mine
        guard let bytes = Hex.decode(combined) else { return nil }

        let digest = Hash.sha256(bytes).hex.uppercased()
        return stride(from: 0, to: 20, by: 4)
            .map { String(digest.dropFirst($0).prefix(4)) }
            .joined(separator: " ")
    }

    // MARK: Compose lock

    private var isComposing = false
    private var composeWaiters: [CheckedContinuation<Void, Never>] = []

    /// FIFO lock around composing. Without it, two sends that both suspend on
    /// their first `await` would read the same `prev` and fork the chain.
    /// Internal rather than private so the inscription path in `Media.swift`
    /// can take the same lock — it spends from the very same UTXO set.
    func lockCompose() async {
        guard isComposing else {
            isComposing = true
            return
        }
        await withCheckedContinuation { continuation in
            composeWaiters.append(continuation)
        }
    }

    func unlockCompose() {
        if composeWaiters.isEmpty {
            isComposing = false
        } else {
            composeWaiters.removeFirst().resume()
        }
    }

    /// Internal is not enough: the app target reads a raw transaction to
    /// recompute an OpNS holder from its locking script.
    public func fetchRaw(txid: String) async throws -> ChainTx? {
        try await adapter.getTx(txid)
    }

    /// Adds coins in demo mode; a no-op against a real chain.
    @discardableResult
    public func demoTopUp(satoshis: UInt64) async throws -> Bool {
        guard let mock = adapter as? MockAdapter else { return false }
        let funded = try await mock.faucet(to: wallet.address, satoshis: satoshis)
        wallet.absorb(rawHex: funded.rawHex, confirmed: true)
        try await persistUTXOs()
        await notifyUpdate()
        return true
    }

    public func demoMineBlock() async {
        guard let mock = adapter as? MockAdapter else { return }
        await mock.mineBlock()
    }

    private func notifyUpdate() async {
        await delegate?.engineDidUpdate()
    }

    // MARK: Channels

    /// Notes-to-self lives on a channel whose id is the wallet's own hash160.
    public var notesChannelId: String { wallet.hash.hex }

    @discardableResult
    public func ensureNotesChannel() async throws -> String {
        let id = notesChannelId

        // Repair rather than short-circuit. `peerPub` is what encrypts these
        // notes, and a row can exist without it — the chain walker recreates a
        // deleted channel from an incoming record with no key attached. Left
        // alone, every existing note would read as unreadable and every new one
        // would quietly go on chain in the clear.
        if var existing = try await store.channel(id) {
            let ownPub = wallet.publicKeyBytes.hex
            guard existing.kind != .note || existing.peerPub != ownPub || existing.peerHash != id else {
                return id
            }
            existing.kind = .note
            existing.peerPub = ownPub
            existing.peerHash = id
            if existing.name?.isEmpty ?? true { existing.name = "Notes to self" }
            try await store.putChannel(existing)
            return id
        }

        let channel = ChannelRecord(channelId: id,
                                    kind: .note,
                                    name: "Notes to self",
                                    peerHash: wallet.hash.hex,
                                    peerPub: wallet.publicKeyBytes.hex,
                                    lastTime: now())
        try await store.putChannel(channel)
        return id
    }

    /// Our own address, plus the address of every group and every DM whose peer
    /// has not identified itself yet.
    func watchedAddresses() async throws -> [(address: String, key: String)] {
        // The own-address cursor is keyed by wallet hash, not a flat "self":
        // a different account activated against the same store would otherwise
        // inherit the previous account's cursor and silently skip its history.
        var result: [(address: String, key: String)] = [(wallet.address, "self:\(wallet.hash.hex)")]
        for channel in try await store.allChannels() {
            let unclaimedDM = channel.kind == .dm && channel.peerPub == nil
            guard channel.kind == .group || unclaimedDM,
                  let address = ChannelID.address(for: channel.channelId) else { continue }
            result.append((address, channel.channelId))
        }
        return result
    }

    // MARK: Polling

    public func start(intervalSeconds: Int) {
        stop()
        let interval = max(2, intervalSeconds)
        pollTask = Task { [weak self] in
            while !Task.isCancelled {
                await self?.pollOnceIgnoringErrors()
                try? await Task.sleep(nanoseconds: UInt64(interval) * 1_000_000_000)
            }
        }
    }

    public func startUTXOSync(intervalSeconds: Int) {
        utxoTask?.cancel()
        let interval = max(30, intervalSeconds)
        utxoTask = Task { [weak self] in
            while !Task.isCancelled {
                if let changed = try? await self?.syncUTXOs(), changed == true {
                    await self?.notifyUpdate()
                }
                try? await Task.sleep(nanoseconds: UInt64(interval) * 1_000_000_000)
            }
        }
    }

    public func stop() {
        pollTask?.cancel()
        pollTask = nil
        utxoTask?.cancel()
        utxoTask = nil
    }

    private func pollOnceIgnoringErrors() async {
        _ = try? await pollOnce()
    }

    /// One polling round: retry the outbox, then pull new activity for every
    /// address we watch.
    @discardableResult
    public func pollOnce() async throws -> Bool {
        try await flushOutbox()

        var changed = false
        for watched in try await watchedAddresses() {
            let cursorKey = "seq:\(watched.key)"
            let cursor: Int = (try? await store.meta(Int.self, key: cursorKey)).flatMap { $0 } ?? 0

            let activity: [AddressActivity]
            do {
                activity = try await adapter.watchAddress(watched.address, since: cursor)
            } catch {
                continue
            }

            var highest = cursor
            for entry in activity {
                highest = max(highest, entry.seq)
                if try await handle(txid: entry.txid, height: entry.height, pos: entry.pos) {
                    changed = true
                }
            }
            if highest != cursor {
                try await store.putMeta(key: cursorKey, value: highest)
            }
        }

        if changed { await notifyUpdate() }
        return changed
    }

    /// Rebroadcasts anything still unconfirmed, and gives up on transactions
    /// whose inputs were spent elsewhere.
    private func flushOutbox() async throws {
        for item in try await store.allOutbox() {
            // Set inside the do/catch and acted on after it, so a store write
            // cannot land in the catch block and be described with a broadcast
            // error's words.
            var accepted = false
            do {
                _ = try await adapter.broadcast(item.rawHex)
                accepted = true
            } catch {
                let reason = String(describing: error).lowercased()
                if reason.contains("already known") || reason.contains("already in the mempool") {
                    // The node already has it. That is a success, not a
                    // failure, and it clears the same way.
                    accepted = true
                }
                let unrecoverable = reason.contains("missing inputs") || reason.contains("mempool-conflict")
                if unrecoverable, now() - item.time > 300 {
                    wallet.release(rawHex: item.rawHex)
                    try await store.deleteOutbox(txid: item.txid)
                    if var message = try await store.message(txid: item.txid) {
                        message.error = "dropped — its input was spent elsewhere"
                        try await store.putMessage(message)
                    }
                    await notifyUpdate()
                }
            }

            // It went out this time. Clearing the earlier failure is not
            // cosmetic: the pinned bar reads `error`, and a message that failed
            // once and then succeeded would otherwise sit there as "failed" for
            // the life of the account — nothing else in the app ever writes
            // that field back to nil.
            if accepted {
                try await clearSendFailure(txid: item.txid)
            }
        }
    }

    /// Marks a message as broadcast after a retry succeeded.
    ///
    /// The read-modify-write happens inside the store, in one hop. Doing it
    /// here would mean reading the record, suspending, and writing a whole row
    /// back — and `pollOnce` runs from the poll loop, from pull-to-refresh and
    /// from opening a chat, with nothing serialising them. A confirmation
    /// landing in that gap would be overwritten by the stale copy.
    private func clearSendFailure(txid: String) async throws {
        if try await store.markBroadcast(txid: txid) {
            await notifyUpdate()
        }
    }

    @discardableResult
    public func syncUTXOs() async throws -> Bool {
        guard adapter.supportsUTXOFetch else { return false }
        let fetched = try await adapter.fetchUTXOs(wallet.address)
        let pending = Set(try await store.allOutbox().map(\.txid))

        let before = wallet.utxos.keys.sorted().joined(separator: ",")
        wallet.replaceUTXOs(with: fetched, keepingTxids: pending)
        let after = wallet.utxos.keys.sorted().joined(separator: ",")

        try await persistUTXOs()
        return before != after
    }

    public func persistUTXOs() async throws {
        struct Snapshot: Codable {
            var utxos: [UTXO]
            var spent: [String]
        }
        // Keyed by wallet hash: a UTXO snapshot restored into a *different*
        // account's wallet would show a wrong balance and select coins the
        // new key cannot sign for. Absent key just means a fresh re-scan.
        try await store.putMeta(key: "utxos:\(wallet.hash.hex)",
                                value: Snapshot(utxos: Array(wallet.utxos.values),
                                                spent: Array(wallet.spent)))
    }

    public func restoreUTXOs() async throws {
        struct Snapshot: Codable {
            var utxos: [UTXO]
            var spent: [String]
        }
        guard let snapshot = try await store.meta(Snapshot.self, key: "utxos:\(wallet.hash.hex)") else { return }
        wallet.restore(utxos: snapshot.utxos, spent: Set(snapshot.spent))
    }

    // MARK: Ingesting transactions

    /// Returns true when anything about our stored state changed.
    @discardableResult
    public func handle(txid: String, height: Int?, pos: Int?) async throws -> Bool {
        if var existing = try await store.message(txid: txid) {
            let newStatus: MessageStatus = height != nil
                ? .confirmed
                : (existing.status == .confirmed ? .sent : existing.status)
            // A message that is in a block cannot still be a failed send. The
            // error is part of what changed, or a transaction that failed once
            // and then mined would sit in the pinned bar as "failed" forever.
            let clearsError = height != nil && existing.error != nil
            let changed = newStatus != existing.status || height != existing.height || clearsError
            guard changed else { return false }

            existing.status = newStatus
            existing.height = height
            existing.pos = pos
            if clearsError { existing.error = nil }
            existing.sort = spiekSortKey(height: height, pos: pos, time: existing.time)
            try await store.putMessage(existing)

            if height != nil {
                wallet.markConfirmed(txid: txid)
                try await store.deleteOutbox(txid: txid)
                try await persistUTXOs()
            }
            return true
        }

        guard let chainTx = try await adapter.getTx(txid) else { return false }

        // The answer must be the transaction that was asked for. A txid is the
        // double-SHA256 of the bytes, so this one comparison binds everything
        // read out of them — including `senderPub`, which comes straight from
        // an unlocking script and is otherwise only as trustworthy as the
        // endpoint that served it. Without it, a hostile or compromised
        // endpoint could hand back a transaction it made up and choose who this
        // device believes it is talking to. Checked on the raw transaction, not
        // on the Spiek parse, because a plain payment must still be absorbed.
        guard let servedTx = Transaction.parse(hex: chainTx.hex), servedTx.txid == txid else {
            return false
        }

        guard let parsed = ParsedSpiekTx.parse(rawHex: chainTx.hex) else {
            // Not a Spiek record, but it may still pay us.
            wallet.absorb(rawHex: chainTx.hex, confirmed: chainTx.height != nil)
            try await persistUTXOs()
            return true
        }

        _ = try await storeParsed(parsed, height: chainTx.height, pos: chainTx.pos)
        _ = try await walkBack(from: parsed, limit: 50)
        return true
    }

    /// Turns a parsed transaction into a stored message and updates the
    /// channel, chain bookmark and wallet state around it.
    ///
    /// `countUnread` is false for backfill — the walkers pull in history that
    /// was never "new" on this device, and counting a restored chat's whole
    /// past as unread made the badge meaningless.
    @discardableResult
    func storeParsed(_ parsed: ParsedSpiekTx, height: Int?, pos: Int?,
                     countUnread: Bool = true) async throws -> MessageRecord {
        let envelope = parsed.envelope
        let channelId = envelope.channel.hex
        let sender = parsed.senderHash.hex
        let myHash = wallet.hash.hex
        let mine = sender == myHash
        let timestamp = now()

        wallet.absorb(transaction: parsed.transaction, confirmed: height != nil)
        try await persistUTXOs()

        var payIn: UInt64 = 0
        var payOut: UInt64 = 0
        // The operator's service-fee output is overhead, not money the user
        // sent to anyone — counting it inflated every displayed Sent amount.
        let serviceHex = ServiceFee.hash160.hex
        for output in parsed.outputs {
            guard let hash = output.hash else { continue }
            let hex = hash.hex
            if !mine && hex == myHash { payIn += output.satoshis }
            if mine && hex != myHash && hex != channelId && hex != serviceHex {
                payOut += output.satoshis
            }
        }

        var record = MessageRecord(
            txid: parsed.txid,
            channel: channelId,
            sender: sender,
            senderPub: parsed.senderPub.hex,
            senderAddress: parsed.senderAddress,
            kind: envelope.kind,
            op: envelope.op,
            payIn: payIn,
            payOut: payOut,
            prev: envelope.prev == Envelope.noPrev ? nil : envelope.prev.reversedBytes.hex,
            ref: envelope.ref?.reversedBytes.hex,
            payload: envelope.payload.hex,
            height: height,
            pos: pos,
            time: timestamp,
            sort: spiekSortKey(height: height, pos: pos, time: timestamp),
            status: height != nil ? .confirmed : .sent,
            mine: mine
        )
        try await store.putMessage(record)

        var channel = try await store.channel(channelId)
            ?? ChannelRecord(channelId: channelId, kind: envelope.kind)

        // An `open` record carries the sender's public key, which is what makes
        // encryption possible in a DM. Two conditions guard it, and both are
        // load-bearing — without either, taking over someone else's
        // conversation costs one transaction.
        //
        // 1. *The announced key must be the key that signed the record.*
        //    Nothing in the protocol binds an OP_RETURN payload to its sender:
        //    the payload is data the sender chose, while `senderPub` comes out
        //    of the unlocking script and is what the miners' signature check
        //    actually validated. Taking the payload on trust let anyone
        //    announce anyone's key — including a key they hold themselves.
        //
        // 2. *Once a chat has a peer, that is the peer.* Channel ids travel in
        //    the clear inside every record, so they are visible to anyone
        //    watching the chain — an unconditional overwrite meant a stranger
        //    could post a single `open` into an established conversation and
        //    have this device encrypt everything after it to their key. First
        //    key wins; a later, different one is refused and recorded.
        //
        // Direct messages only, judged by **`channel.kind`** — the kind this
        // device stored — and never by `envelope.kind`, which is a field the
        // sender fills in. A group has no shared secret, nobody's key is "the"
        // peer key there, and letting whoever joined first land in `peerHash`
        // also made the chat list label a group with that one person's name.
        //
        // The notes channel is excluded outright: its id *is* the wallet's own
        // hash160, which is public, so a record addressed to it always reaches
        // this device. Its key comes from the wallet, never from the chain.
        let isNotes = channelId == wallet.hash.hex
        let isDM = channel.kind == .dm && !isNotes

        if envelope.op == .open, !mine, isDM,
           let pub = Codecs.decodeOpen(envelope.payload) {
            if pub != parsed.senderPub {
                // Announced a key that is not theirs. Never trusted, whether
                // or not this chat already has a peer.
                channel.peerKeyConflict = sender
            } else if channel.peerHash == nil || channel.peerHash == sender {
                channel.peerPub = pub.hex
                channel.peerHash = sender
                if channel.peerKeyConflict == sender { channel.peerKeyConflict = nil }
            } else {
                channel.peerKeyConflict = sender
            }
        }
        // The same pin applies to the fallback. This key is genuine — it is
        // read from the unlocking script — but genuine is not the same as
        // *theirs*: a stranger writing into a chat that already has a peer must
        // not become that peer. And someone whose `open` was just caught
        // announcing a key that was not theirs must not be handed the channel
        // by this path a few lines later — that would make lying strictly
        // better for an attacker than staying quiet.
        if !mine, channel.peerPub == nil, isDM, channel.peerKeyConflict != sender {
            if channel.peerHash == nil || channel.peerHash == sender {
                channel.peerPub = parsed.senderPub.hex
                channel.peerHash = sender
            } else {
                channel.peerKeyConflict = sender
            }
        }
        // Notes-to-self encrypt against our own key, so a row recreated by the
        // walker must get that key back — otherwise the channel silently drops
        // to plaintext and the notes already on chain become unreadable.
        //
        // Keyed on the channel id alone. It used to also require
        // `envelope.kind == .note`, and that kind comes from the sender: after
        // deleting the notes chat, a stranger could recreate the row as a `.dm`
        // by addressing a record to this wallet's own hash, skip this repair,
        // and be pinned as the peer of your private notes.
        if isNotes {
            channel.kind = .note
            channel.peerPub = wallet.publicKeyBytes.hex
            channel.peerHash = channelId
        }
        if envelope.op == .profile, let profile = Codecs.decodeProfile(envelope.payload) {
            try await store.putMeta(key: "profile:\(sender)",
                                    value: StoredProfile(name: profile.name, bio: profile.bio, time: timestamp))
        }

        if record.sort >= channel.lastSort, envelope.op != .open {
            channel.lastTxid = record.txid
            channel.lastTime = timestamp
            channel.lastSort = record.sort
        }
        if countUnread, !mine, [SpiekOp.msg, .media, .emsg].contains(envelope.op) {
            // A blocked sender's messages are hidden, so they must not count
            // either — a badge for something that never shows is a haunting.
            if try await !isSuppressed(txid: record.txid, sender: sender) {
                channel.unread += 1
            }
        }
        try await store.putChannel(channel)

        // Remember the oldest message we hold from this sender in this channel.
        let chainKey = "\(channelId)|\(sender)"
        let existingChain = try await store.chain(chainKey)
        if existingChain == nil || record.sort < existingChain!.oldestSort {
            try await store.putChain(ChainRecord(key: chainKey,
                                                 oldestTxid: record.txid,
                                                 oldestPrev: record.prev,
                                                 oldestSort: record.sort))
        }

        record.channel = channelId
        return record
    }

    /// Follows the `prev` pointers backwards to pull in a thread we joined late.
    @discardableResult
    func walkBack(from parsed: ParsedSpiekTx, limit: Int) async throws -> Int {
        var prev = parsed.envelope.prev
        var count = 0

        while prev != Envelope.noPrev, count < limit {
            let txid = prev.reversedBytes.hex
            if try await store.hasMessage(txid: txid) { break }
            guard let chainTx = try await adapter.getTx(txid),
                  let older = ParsedSpiekTx.parse(rawHex: chainTx.hex),
                  // Same binding as in `handle`: the bytes must hash to the
                  // txid that was asked for, or nothing read out of them —
                  // sender included — means anything.
                  older.txid == txid else { break }
            _ = try await storeParsed(older, height: chainTx.height, pos: chainTx.pos,
                                      countUnread: false)
            prev = older.envelope.prev
            count += 1
        }
        return count
    }

    /// Pulls another page of history for every sender in a channel.
    @discardableResult
    public func loadOlder(channelId: String, limit: Int = 50) async throws -> Int {
        var loaded = 0
        for chain in try await store.chains(forChannel: channelId) {
            guard var cursor = chain.oldestPrev else { continue }
            var steps = 0
            while steps < limit {
                if try await store.hasMessage(txid: cursor) { break }
                guard let chainTx = try await adapter.getTx(cursor),
                      let older = ParsedSpiekTx.parse(rawHex: chainTx.hex),
                      older.txid == cursor else { break }
                _ = try await storeParsed(older, height: chainTx.height, pos: chainTx.pos,
                                          countUnread: false)
                guard older.envelope.prev != Envelope.noPrev else { break }
                cursor = older.envelope.prev.reversedBytes.hex
                steps += 1
                loaded += 1
            }
        }
        if loaded > 0 { await notifyUpdate() }
        return loaded
    }

    // MARK: Composing

    /// The txid of our own most recent message in a channel, which becomes the
    /// `prev` pointer of the next one.
    ///
    /// Tracked explicitly in `meta` rather than derived from the sort order:
    /// unconfirmed messages sort by whole seconds, so two messages sent in the
    /// same second would tie and the chain could fork.
    func myPrev(channelId: String) async throws -> [UInt8] {
        if let recorded = try await store.meta(String.self, key: myPrevKey(channelId)),
           let bytes = Hex.decode(recorded), bytes.count == 32 {
            return bytes.reversedBytes
        }
        let mine = try await store.messages(channel: channelId, sender: wallet.hash.hex)
        guard let last = mine.last, let bytes = Hex.decode(last.txid), bytes.count == 32 else {
            return Envelope.noPrev
        }
        return bytes.reversedBytes
    }

    /// Namespaced by wallet hash, like the cursor and the UTXO snapshot: the
    /// chain of *this* account must not leak into the next one activated
    /// against the same store.
    private func myPrevKey(_ channelId: String) -> String { "myprev:\(wallet.hash.hex):\(channelId)" }

    private func rememberMyPrev(channelId: String, txid: String) async throws {
        try await store.putMeta(key: myPrevKey(channelId), value: txid)
    }

    public struct SendRequest: Sendable {
        public var op: SpiekOp
        public var payload: [UInt8]
        public var ref: [UInt8]?
        /// Leave nil to follow the channel's own setting, which is the normal
        /// case: a direct message encrypts as soon as the peer's key is known,
        /// unless the user turned the lock off for that chat.
        public var encrypt: Bool?
        public var paySats: UInt64

        public init(op: SpiekOp,
                    payload: [UInt8],
                    ref: [UInt8]? = nil,
                    encrypt: Bool? = nil,
                    paySats: UInt64 = 0) {
            self.op = op
            self.payload = payload
            self.ref = ref
            self.encrypt = encrypt
            self.paySats = paySats
        }
    }

    /// Whether a channel encrypts by default: a direct message or notes-to-self
    /// whose counterparty key is known and that has not been switched to
    /// plaintext.
    ///
    /// Notes-to-self count. The channel stores the wallet's *own* public key as
    /// `peerPub`, so the ECDH runs against yourself and produces a key only this
    /// wallet can derive. Without it a private note would sit on the chain in
    /// the clear, readable by anyone — which is exactly what the web build
    /// avoids.
    public static func encryptsByDefault(_ channel: ChannelRecord) -> Bool {
        (channel.kind == .dm || channel.kind == .note)
            && channel.peerPub != nil
            && !channel.plain
    }

    /// Flips a chat between encrypted and plaintext. Returns the new state.
    ///
    /// Groups are excluded: they have no shared secret, so the flag would be
    /// one `encryptsByDefault` never reads.
    @discardableResult
    public func setPlain(_ plain: Bool, channelId: String) async throws -> Bool {
        guard var channel = try await store.channel(channelId) else { throw EngineError.unknownChannel }
        guard channel.kind == .dm || channel.kind == .note else { throw EngineError.unknownChannel }
        guard channel.peerPub != nil else { throw EngineError.peerKeyUnknown }
        channel.plain = plain
        try await store.putChannel(channel)
        await notifyUpdate()
        return plain
    }

    public enum EngineError: Error, LocalizedError, Equatable {
        case unknownChannel
        case peerKeyUnknown
        case paymentsOnlyInDM
        case badChannelId

        public var errorDescription: String? {
            switch self {
            case .unknownChannel:
                return "This chat no longer exists on this device."
            case .peerKeyUnknown:
                return "The other party's public key is not known yet — it arrives with their first message."
            case .paymentsOnlyInDM:
                return "Payments are only possible in a 1-on-1 chat."
            case .badChannelId:
                return "That is not a valid chat code."
            }
        }
    }

    @discardableResult
    public func send(channelId: String, request: SendRequest) async throws -> MessageRecord {
        await lockCompose()
        defer { unlockCompose() }
        return try await performSend(channelId: channelId, request: request)
    }

    private func performSend(channelId: String, request: SendRequest) async throws -> MessageRecord {
        guard let channel = try await store.channel(channelId) else { throw EngineError.unknownChannel }
        guard let channelBytes = ChannelID.bytes(from: channelId) else { throw EngineError.badChannelId }

        let prev = try await myPrev(channelId: channelId)

        var outerOp = request.op
        var outerPayload = request.payload
        var outerRef = request.ref

        // Only content-bearing records are encrypted in a DM; an `open`
        // announces a public key and reactions are too small to hide anything.
        // v1.20, encrypted groups: when the channel holds a group key, *every*
        // record except `open` is sealed under it (matching the web build) —
        // reactions, edits and withdrawals included, since the group cipher
        // costs nothing extra and a plaintext reaction would leak the emoji.
        let groupKeyBytes: [UInt8]? = {
            guard channel.kind == .group, request.op != .open,
                  let hex = channel.groupKey,
                  let bytes = Hex.decode(hex), bytes.count == 32 else { return nil }
            return bytes
        }()
        let encryptable: Set<SpiekOp> = [.msg, .media, .edit]
        let shouldEncrypt = groupKeyBytes != nil ||
            ((request.encrypt ?? Engine.encryptsByDefault(channel)) && encryptable.contains(request.op))

        if shouldEncrypt {
            let symmetric: [UInt8]
            if let groupKeyBytes {
                symmetric = groupKeyBytes
            } else {
                guard let peerPubHex = channel.peerPub,
                      let peerPubBytes = Hex.decode(peerPubHex),
                      let peerKey = PublicKey(bytes: peerPubBytes),
                      let conversationKey = wallet.key.conversationKey(with: peerKey) else {
                    throw EngineError.peerKeyUnknown
                }
                symmetric = conversationKey
            }
            let inner = try InnerEnvelope(op: request.op, payload: request.payload, ref: request.ref).encoded()
            outerPayload = try AESGCM.seal(plaintext: inner, key: symmetric)
            outerOp = .emsg
            outerRef = nil
        }

        var extraPayTo = [PayTarget]()
        if channel.kind == .dm,
           let peerHashHex = channel.peerHash,
           peerHashHex != wallet.hash.hex,
           let peerHash = Hex.decode(peerHashHex) {
            extraPayTo.append(PayTarget(hash: peerHash, satoshis: wallet.dust + request.paySats))
        } else if request.paySats > 0 {
            throw EngineError.paymentsOnlyInDM
        }

        // The operator's cut: 3 sats on a text, 10 on an image, 10 on a
        // payment. Decided on the *inner* op, so an encrypted message is
        // charged as what it is, not as `emsg`.
        if let serviceTarget = ServiceFee.target(op: request.op, paySats: request.paySats) {
            extraPayTo.append(serviceTarget)
        }

        let built = try wallet.buildMessage(kind: channel.kind,
                                            channel: channelBytes,
                                            prev: prev,
                                            op: outerOp,
                                            payload: outerPayload,
                                            ref: outerRef,
                                            extraPayTo: extraPayTo)

        guard let parsed = ParsedSpiekTx.parse(rawHex: built.rawHex) else {
            throw TransactionError.malformed
        }
        var record = try await storeParsed(parsed, height: nil, pos: nil)
        record.status = .pending
        record.fee = built.fee
        record.paySats = request.paySats
        if shouldEncrypt {
            // v1.21 (P0.5): the cached plaintext of our own sends is sealed under
            // a key derived from the wallet, so a store that ends up under another
            // wallet — or copied off the device — holds no readable text.
            record.decrypted = try sealCache(request.payload)
            record.decryptedOp = request.op
            record.decryptedRef = request.ref?.reversedBytes.hex
        }
        try await store.putMessage(record)
        try await rememberMyPrev(channelId: channelId, txid: built.txid)
        try await store.putOutbox(OutboxItem(txid: built.txid,
                                             rawHex: built.rawHex,
                                             channel: channelId,
                                             time: now()))
        await notifyUpdate()

        do {
            _ = try await adapter.broadcast(built.rawHex)
            record.status = .sent
            try await store.putMessage(record)
        } catch {
            record.error = error.localizedDescription
            try await store.putMessage(record)
        }

        // Re-read rather than writing back the snapshot taken at the top of
        // this method: storeParsed and any poll that ran in between have
        // already updated the channel.
        if var latest = try await store.channel(channelId) {
            latest.lastTxid = record.txid
            latest.lastTime = record.time
            latest.lastSort = max(latest.lastSort, record.sort)
            try await store.putChannel(latest)
        }

        await notifyUpdate()
        return record
    }

    /// Creates a channel locally and announces our public key on it.
    @discardableResult
    public func openChat(peerAddressOrHash: String? = nil,
                         name: String? = nil,
                         kind: ChannelKind = .dm,
                         channelId existingChannelId: String? = nil,
                         /// v1.20: the 64-hex group key from a keyed invite, or nil.
                         groupKey inviteGroupKey: String? = nil) async throws -> String {
        await lockCompose()
        defer { unlockCompose() }
        return try await performOpenChat(peerAddressOrHash: peerAddressOrHash,
                                         name: name,
                                         kind: kind,
                                         channelId: existingChannelId,
                                         groupKey: inviteGroupKey)
    }

    private func performOpenChat(peerAddressOrHash: String?,
                                 name: String?,
                                 kind: ChannelKind,
                                 channelId existingChannelId: String?,
                                 groupKey inviteGroupKey: String? = nil) async throws -> String {
        var peerHash: [UInt8]?
        if let peerAddressOrHash, !peerAddressOrHash.isEmpty {
            if peerAddressOrHash.count == 40, let bytes = Hex.decode(peerAddressOrHash) {
                peerHash = bytes
            } else if let bytes = Address.hash160(from: peerAddressOrHash) {
                peerHash = bytes
            } else {
                throw KeyError.invalidAddress
            }
        }

        let channelBytes: [UInt8]
        if let existingChannelId {
            guard let bytes = ChannelID.bytes(from: existingChannelId) else { throw EngineError.badChannelId }
            channelBytes = bytes
        } else {
            channelBytes = ChannelID.random()
        }
        let channelId = channelBytes.hex

        let existing = try await store.channel(channelId)
        if existing == nil {
            // v1.20: a freshly *created* group (no channelId passed in) gets a
            // random 32-byte key and is encrypted from its first message. A
            // *joined* group takes whatever the invite carried — a keyless
            // invite joins a public group, exactly as before.
            let groupKey: String?
            if kind == .group {
                groupKey = inviteGroupKey ?? (existingChannelId == nil ? SecureRandom.bytes(32).hex : nil)
            } else {
                groupKey = nil
            }
            try await store.putChannel(ChannelRecord(channelId: channelId,
                                                     kind: kind,
                                                     name: name,
                                                     peerHash: peerHash?.hex,
                                                     lastTime: now(),
                                                     groupKey: groupKey))
        } else if kind == .group, existing?.groupKey == nil,
                  let inviteGroupKey, !inviteGroupKey.isEmpty,
                  var adopting = existing {
            // Re-loading a fuller invite for a group we already follow adopts
            // the key, so earlier unreadable records open on the next render.
            adopting.groupKey = inviteGroupKey
            try await store.putChannel(adopting)
        }

        var extraPayTo = [PayTarget]()
        if kind == .dm, let peerHash {
            extraPayTo.append(PayTarget(hash: peerHash, satoshis: wallet.dust))
        }

        let built: BuiltTransaction
        do {
            built = try wallet.buildMessage(kind: kind,
                                            channel: channelBytes,
                                            prev: try await myPrev(channelId: channelId),
                                            op: .open,
                                            payload: wallet.publicKeyBytes,
                                            extraPayTo: extraPayTo)
        } catch {
            if existing == nil { try await store.deleteChannel(channelId) }
            throw error
        }

        guard let parsed = ParsedSpiekTx.parse(rawHex: built.rawHex) else {
            throw TransactionError.malformed
        }
        var record = try await storeParsed(parsed, height: nil, pos: nil)
        record.status = .pending
        try await store.putMessage(record)
        try await rememberMyPrev(channelId: channelId, txid: built.txid)
        try await store.putOutbox(OutboxItem(txid: built.txid,
                                             rawHex: built.rawHex,
                                             channel: channelId,
                                             time: now()))

        do {
            _ = try await adapter.broadcast(built.rawHex)
            record.status = .sent
            try await store.putMessage(record)
        } catch {
            record.error = error.localizedDescription
            try await store.putMessage(record)
        }

        await notifyUpdate()
        return channelId
    }

    // MARK: Reading

    /// Builds the display list for a channel, applying edits, deletions and
    /// reactions, and opening any encrypted records we hold keys for.
    public func viewChannel(_ channelId: String,
                            limit: Int = 50,
                            before: Double = .greatestFiniteMagnitude) async throws -> [ViewMessage] {
        let raw = try await store.messages(channel: channelId, limit: limit * 3, before: before)
        let byTxid = Dictionary(uniqueKeysWithValues: raw.map { ($0.txid, $0) })
        let blocked = try await blockedSenders()
        let feed = try? await Moderation.accepted(store)

        var visible = [ViewMessage]()
        var modifiers = [ViewMessage]()

        for record in raw {
            // A blocked sender's records are neither rendered nor allowed to
            // touch anyone else's messages with edits, deletions or reactions.
            // v1.21 (P0.2): policy/legal blocks from the signed feed likewise.
            if !record.mine, blocked.contains(record.sender) { continue }
            let ruling = feed?.level(txid: record.txid, sender: record.mine ? nil : record.sender)
            if ruling == .policyBlock || ruling == .legalBlock { continue }

            var effectiveOp = record.op
            var effectivePayload = Hex.decode(record.payload) ?? []
            var effectiveRef = record.ref
            var wasEncrypted = false

            if record.op == .emsg {
                wasEncrypted = true
                guard let inner = try await decryptRecord(record) else {
                    visible.append(ViewMessage(record: record,
                                               viewOp: .emsg,
                                               viewPayload: [],
                                               encrypted: true,
                                               unreadable: true))
                    continue
                }
                effectiveOp = inner.op
                effectivePayload = inner.payload
                effectiveRef = inner.ref?.reversedBytes.hex
            }

            switch effectiveOp {
            case .msg, .media:
                var message = ViewMessage(record: record,
                                          viewOp: effectiveOp,
                                          viewPayload: effectivePayload,
                                          encrypted: wasEncrypted,
                                          unreadable: false)
                message.record.ref = effectiveRef
                // Effects persisted earlier for a modifier whose target sat
                // outside the page being viewed at the time — see below.
                message.edited = record.editedPayload.flatMap { Hex.decode($0) }
                message.editTime = record.editedTime
                message.deleted = record.deleted ?? false
                message.hiddenSoft = ruling == .softHide
                visible.append(message)
            case .edit, .del, .react:
                var modifier = ViewMessage(record: record,
                                           viewOp: effectiveOp,
                                           viewPayload: effectivePayload,
                                           encrypted: wasEncrypted,
                                           unreadable: false)
                modifier.record.ref = effectiveRef
                modifiers.append(modifier)
            default:
                break
            }
        }

        for modifier in modifiers {
            guard let refTxid = modifier.record.ref else { continue }
            guard let index = visible.firstIndex(where: { $0.record.txid == refTxid }) else {
                // The target sits outside this page. Persist the effect onto
                // the stored record instead of dropping it, so the edit or
                // withdrawal shows whenever that part of the chat is loaded.
                // Done inside the store in one hop — a read-modify-write
                // across an `await` here could overwrite a confirmation
                // landing in the gap (see `markBroadcast`). The store checks
                // the author itself. A reaction to a message that is not on
                // screen has nothing to attach to and stays page-local.
                switch modifier.viewOp {
                case .edit:
                    try await store.applyModifier(txid: refTxid,
                                                  editedPayload: modifier.viewPayload.hex,
                                                  editedTime: modifier.record.time,
                                                  deleted: nil,
                                                  from: modifier.record.sender)
                case .del:
                    try await store.applyModifier(txid: refTxid,
                                                  editedPayload: nil,
                                                  editedTime: nil,
                                                  deleted: true,
                                                  from: modifier.record.sender)
                default:
                    break
                }
                continue
            }

            // Only the original author may edit or delete.
            if modifier.viewOp == .edit || modifier.viewOp == .del {
                guard visible[index].record.sender == modifier.record.sender else { continue }
            }

            switch modifier.viewOp {
            case .edit:
                visible[index].edited = modifier.viewPayload
                visible[index].editTime = modifier.record.time
            case .del:
                visible[index].deleted = true
            case .react:
                let emoji = Codecs.decodeText(modifier.viewPayload)
                // One reaction per person per emoji. Every react is its own
                // transaction, so tapping the same emoji twice — or a walker
                // re-reading the same page — used to stack it endlessly, and
                // nothing on chain says the second one is a repeat. The first
                // is kept: it is the one that actually happened.
                guard !visible[index].reactions.contains(where: {
                    $0.sender == modifier.record.sender && $0.emoji == emoji
                }) else { continue }
                visible[index].reactions.append(
                    ViewMessage.Reaction(sender: modifier.record.sender,
                                         emoji: emoji,
                                         mine: modifier.record.mine)
                )
            default:
                break
            }
        }

        // Resolve replies last: a message can quote one that appears earlier
        // in this same page, or one only still in the store.
        for index in visible.indices {
            guard let refTxid = visible[index].record.ref else { continue }
            visible[index].replyTo = try await quote(forTxid: refTxid, within: byTxid)
        }

        return Array(visible.suffix(limit))
    }

    /// Builds the preview line for a quoted message, opening it first if it
    /// was encrypted and we hold the key.
    private func quote(forTxid txid: String,
                       within page: [String: MessageRecord]) async throws -> ViewMessage.Quote {
        // Written out rather than with `??`: the right-hand side of `??` is an
        // autoclosure, and an autoclosure cannot be async — so `await` in there
        // does not compile.
        let found: MessageRecord?
        if let cached = page[txid] {
            found = cached
        } else {
            found = try await store.message(txid: txid)
        }

        guard let record = found else {
            return ViewMessage.Quote(txid: txid, sender: "", mine: false,
                                     preview: "earlier message", isMissing: true)
        }

        var preview = "encrypted message"
        switch record.op {
        case .msg:
            preview = Codecs.decodeText(Hex.decode(record.payload) ?? [])
        case .media:
            preview = "image"
        case .emsg:
            if let inner = try await decryptRecord(record) {
                switch inner.op {
                case .msg: preview = Codecs.decodeText(inner.payload)
                case .media: preview = "image"
                default: break
                }
            }
        default:
            break
        }

        return ViewMessage.Quote(txid: txid,
                                 sender: record.sender,
                                 mine: record.mine,
                                 preview: String(preview.prefix(80)),
                                 isMissing: false)
    }

    private static let cachePrefix = "c1:"

    private var cacheKey: [UInt8] {
        Hash.sha256(Array("spiek-cache-v1".utf8) + wallet.key.bytes)
    }

    private func sealCache(_ plaintext: [UInt8]) throws -> String {
        Engine.cachePrefix + (try AESGCM.seal(plaintext: plaintext, key: cacheKey)).hex
    }

    /// Opens a sealed cache entry; accepts pre-1.21 plain hex for old rows.
    private func openCache(_ stored: String) -> [UInt8]? {
        guard stored.hasPrefix(Engine.cachePrefix) else { return Hex.decode(stored) }
        guard let sealed = Hex.decode(String(stored.dropFirst(Engine.cachePrefix.count))) else { return nil }
        return try? AESGCM.open(sealed: sealed, key: cacheKey)
    }

    /// Opens an `emsg` record, using the cached plaintext when we wrote it.
    public func decryptRecord(_ record: MessageRecord) async throws -> InnerEnvelope? {
        if let decrypted = record.decrypted, let op = record.decryptedOp,
           let payload = openCache(decrypted) {
            return InnerEnvelope(op: op,
                                 payload: payload,
                                 ref: record.decryptedRef.flatMap { Hex.decode($0)?.reversedBytes })
        }
        // A cache we cannot open (another wallet's key) falls through to a real
        // decrypt, which also fails for a foreign record — unreadable, not leaked.

        let channel = try await store.channel(record.channel)
        // v1.20, encrypted groups: a group record decrypts under the channel's
        // symmetric key. No key (a public group, or an invite we only hold in
        // its keyless form) means the record stays unreadable — same rendering
        // as a foreign DM.
        if channel?.kind == .group {
            guard let keyHex = channel?.groupKey,
                  let key = Hex.decode(keyHex), key.count == 32,
                  let groupSealed = Hex.decode(record.payload),
                  let groupPlain = try? AESGCM.open(sealed: groupSealed, key: key) else { return nil }
            return InnerEnvelope.decode(groupPlain)
        }
        let counterpartyHex = record.mine ? channel?.peerPub : record.senderPub
        guard let counterpartyHex,
              let counterpartyBytes = Hex.decode(counterpartyHex),
              let counterparty = PublicKey(bytes: counterpartyBytes),
              let symmetric = wallet.key.conversationKey(with: counterparty),
              let sealed = Hex.decode(record.payload) else { return nil }

        guard let plaintext = try? AESGCM.open(sealed: sealed, key: symmetric) else { return nil }
        return InnerEnvelope.decode(plaintext)
    }

    public func markRead(channelId: String) async throws {
        guard var channel = try await store.channel(channelId), channel.unread != 0 else { return }
        channel.unread = 0
        channel.lastRead = now()
        try await store.putChannel(channel)
        await notifyUpdate()
    }

    public func profile(forSender sender: String) async throws -> StoredProfile? {
        try await store.meta(StoredProfile.self, key: "profile:\(sender)")
    }

    public func deleteChannel(_ channelId: String) async throws {
        try await store.deleteChannel(channelId)
        // `myprev` is namespaced by wallet hash, which the store cannot know.
        try await store.deleteMeta(key: myPrevKey(channelId))
        await notifyUpdate()
    }

    // MARK: Blocked senders

    /// Where the block list lives. Hashes (hex) of senders whose records this
    /// device refuses to show. Local only — nothing about a block goes on
    /// chain, and the other side is never told.
    static let blockedKey = "blocked"

    /// v1.21 (P0.2): true for anything that must not be rendered, counted,
    /// notified about or fetched — a blocked sender, or any feed entry.
    public func isSuppressed(txid: String, sender: String) async throws -> Bool {
        if try await blockedSenders().contains(sender) { return true }
        return (try? await Moderation.accepted(store))?.level(txid: txid, sender: sender) != nil
    }

    /// True when media bytes for this record must never be downloaded (legal block).
    public func isFetchForbidden(txid: String, sender: String) async -> Bool {
        (try? await Moderation.accepted(store))?.level(txid: txid, sender: sender) == .legalBlock
    }

    public func blockedSenders() async throws -> Set<String> {
        Set(try await store.meta([String].self, key: Engine.blockedKey) ?? [])
    }

    public func setBlocked(_ sender: String, blocked: Bool) async throws {
        var list = try await blockedSenders()
        if blocked { list.insert(sender) } else { list.remove(sender) }
        try await store.putMeta(key: Engine.blockedKey, value: list.sorted())
        await notifyUpdate()
    }
}
