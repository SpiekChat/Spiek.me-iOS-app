import Foundation
import LocalAuthentication
import Observation
import SpiekCore
import SwiftUI
import UIKit
import UniformTypeIdentifiers

@MainActor
@Observable
final class AppModel {
    enum Phase: Equatable {
        case loading
        case onboarding
        case ready
    }

    enum Tab: String, CaseIterable, Identifiable {
        case chats, wallet, you
        var id: String { rawValue }

        var title: String {
            switch self {
            case .chats: return "Chats"
            case .wallet: return "Wallet"
            case .you: return "You"
            }
        }

        var symbol: String {
            switch self {
            case .chats: return "bubble.left"
            case .wallet: return "creditcard"
            case .you: return "person"
            }
        }
    }

    // MARK: Observable state

    var phase: Phase = .loading
    var tab: Tab = .chats
    var notice: Notice?

    var settings = Settings()
    var address: String = ""
    var publicKeyHex: String = ""
    var myHash: String = ""
    var phrase: String?
    var balance: UInt64 = 0

    var channels: [ChannelRecord] = []
    var profiles: [String: StoredProfile] = [:]
    var searchQuery: String = ""

    var activeChannelId: String?
    var messages: [ViewMessage] = []
    var isSyncing = false
    var canLoadOlder = true

    /// Composer state for the open conversation.
    var draft: String = ""
    var editingTxid: String?
    /// The message the next send should quote.
    var replyingTo: ViewMessage?

    /// Chat photos, kept on this device only and never broadcast. Held in
    /// memory as well so the list does not decode them on every redraw.
    var chatPhotos: [String: UIImage] = [:]
    /// Channel ids already looked up, misses included — see `reload`.
    @ObservationIgnored private var photosProbed: Set<String> = []
    /// Pins the user waved away, keyed by message *and* state — so the pin
    /// comes back if the same message later fails.
    var dismissedPins: Set<String> = []

    /// Your own name and bio, kept on this device so the fields on the You
    /// screen still hold what was typed after the app is closed. Publishing
    /// puts the same thing on the chain; this is not a substitute for that, it
    /// is what the form reads back.
    var myProfile = StoredProfile(name: nil, bio: nil, time: 0)
    /// Your own picture. On this device only — it is never inscribed and never
    /// sent to anyone, exactly like a chat photo.
    var myPhoto: UIImage?
    @ObservationIgnored private var myPhotoProbed = false

    /// The live BSV price, or nil while none is known.
    var price: BSVPrice?
    /// Set when the last attempt failed, so the settings row can say why
    /// instead of silently showing an old number.
    var priceError: String?

    /// True while the device lock is in front of the app.
    var isLocked = false
    var phraseScheme: PhraseScheme?
    /// An image picked but not yet inscribed, so its size can be tuned first.
    var pendingImage: PendingImage?

    struct PendingImage {
        var original: UIImage
        var caption: String = ""
        var maxDimension: CGFloat = 1024
        var quality: Double = 0.8
        var keepOriginal = false
        var originalData: Data

        /// The choices the web build offers, plus "original".
        static let dimensionChoices: [CGFloat] = [512, 1024, 2048, 0]
    }

    private(set) var engine: Engine?
    private var store: Store?
    private var refreshTask: Task<Void, Never>?
    /// The account the running engine was built from. Kept in memory so that
    /// re-activations (saving settings rebuilds the engine) never have to
    /// read the Keychain again — with the device lock on, the item is gated
    /// on user presence and a re-read would raise a Face ID prompt out of
    /// nowhere. No security is lost: the engine already holds the private
    /// key itself.
    @ObservationIgnored private var currentAccount: StoredAccount?

    @ObservationIgnored private let priceFeed = PriceFeed()
    @ObservationIgnored private var priceTask: Task<Void, Never>?
    /// One minute, as asked for. Long enough that the feed is not hammered,
    /// short enough that the number on the wallet is never meaningfully old.
    static let priceIntervalSeconds: UInt64 = 60
    static let priceMetaKey = "price:usd"

    // MARK: Derived

    var activeChannel: ChannelRecord? {
        guard let activeChannelId else { return nil }
        return channels.first { $0.channelId == activeChannelId }
    }

    var visibleChannels: [ChannelRecord] {
        let query = searchQuery.trimmingCharacters(in: .whitespaces).lowercased()
        let sorted = channels.sorted { lhs, rhs in
            if lhs.lastSort != rhs.lastSort { return lhs.lastSort > rhs.lastSort }
            return lhs.lastTime > rhs.lastTime
        }
        guard !query.isEmpty else { return sorted }
        return sorted.filter { channel in
            displayName(for: channel).lowercased().contains(query)
                || channel.channelId.contains(query)
                || (channel.peerHash?.contains(query) ?? false)
        }
    }

    var totalUnread: Int {
        channels.reduce(0) { $0 + $1.unread }
    }

    /// Groups have no shared secret. A one-to-one gets one when the other
    /// side's key arrives; notes-to-self hold their own key from the start.
    var chatCanBeEncrypted: Bool {
        guard let channel = activeChannel else { return false }
        return channel.kind == .dm || channel.kind == .note
    }

    /// Encryption is only possible once we hold the counterparty's public key —
    /// which for notes-to-self is our own, so it is there immediately.
    var canEncrypt: Bool {
        guard let channel = activeChannel else { return false }
        return chatCanBeEncrypted && channel.peerPub != nil
    }

    /// Whether the open chat currently encrypts. Direct messages do so as soon
    /// as the peer's key arrives; the lock button opts out per chat.
    var chatIsEncrypted: Bool {
        guard let channel = activeChannel else { return false }
        return Engine.encryptsByDefault(channel)
    }

    var lockCaption: String {
        guard let channel = activeChannel, chatCanBeEncrypted else { return "" }
        // Said before anything else about this chat. Someone announced a key
        // here that was refused — either it was not the key that signed their
        // record, or this chat already has a peer. Nothing was taken over, and
        // the refusal is not something to find out about later.
        if channel.peerKeyConflict != nil {
            return "Someone else tried to announce a key on this chat. It was refused \u{2014} check the safety number."
        }
        if channel.peerPub == nil { return "Encryption starts after their first message" }
        if channel.kind == .note {
            return channel.plain
                ? "These notes are in the clear on the chain — tap to encrypt them"
                : "Encrypted to your own key — only this wallet can read them"
        }
        return channel.plain
            ? "Encryption is off for this chat — tap to turn it on"
            : "Encrypted — messages only the two keys can read"
    }

    /// Flips the open chat between encrypted and plaintext.
    func toggleEncryption() async {
        guard let engine, let channel = activeChannel else { return }
        guard channel.peerPub != nil else {
            show("Encryption starts after the other side's first message.", kind: .error)
            return
        }
        do {
            let nowPlain = try await engine.setPlain(!channel.plain, channelId: channel.channelId)
            if channel.kind == .note {
                show(nowPlain ? "These notes now go on the chain in the clear."
                              : "Encryption on — only this wallet can read these notes.")
            } else {
                show(nowPlain ? "Encryption off for this chat."
                              : "Encryption on — messages only the two keys can read.")
            }
            await reload()
        } catch {
            report(error)
        }
    }

    func displayName(for channel: ChannelRecord) -> String {
        if let name = channel.name, !name.isEmpty { return name }
        if channel.kind == .note { return "Notes to self" }
        if let peerHash = channel.peerHash, let profile = profiles[peerHash],
           let name = profile.name, !name.isEmpty {
            return name
        }
        if let peerHash = channel.peerHash {
            return Format.truncatedMiddle(Address.encode(hash160: Hex.decode(peerHash) ?? []), lead: 8, tail: 6)
        }
        return channel.kind == .group ? "Group" : Format.truncatedMiddle(channel.channelId)
    }

    func senderName(for message: ViewMessage) -> String {
        if message.record.mine { return "You" }
        if let profile = profiles[message.record.sender], let name = profile.name, !name.isEmpty {
            return name
        }
        return Format.truncatedMiddle(message.record.senderAddress, lead: 8, tail: 6)
    }

    /// A display name for a bare sender hash — used by reply quotes, which
    /// only carry the hash of whoever wrote the original.
    func name(forSender sender: String) -> String {
        if sender == myHash { return "You" }
        if let profile = profiles[sender], let name = profile.name, !name.isEmpty {
            return name
        }
        let address = Address.encode(hash160: Hex.decode(sender) ?? [])
        return Format.truncatedMiddle(address, lead: 8, tail: 6)
    }

    // MARK: Notices

    func show(_ text: String, kind: Notice.Kind = .info) {
        withAnimation(.easeOut(duration: 0.25)) {
            notice = Notice(text: text, kind: kind)
        }
    }

    func report(_ error: Error) {
        // A cancelled request is not a failure. Leaving the app mid-refresh
        // makes iOS cut the connection, and the bare word "cancelled" then
        // appeared as an error bar over the chat list. Nothing was lost — the
        // next poll picks everything up — so cancellations are not reported.
        if error is CancellationError { return }
        let nsError = error as NSError
        if nsError.domain == NSURLErrorDomain && nsError.code == NSURLErrorCancelled { return }
        show(error.localizedDescription, kind: .error)
    }

    // MARK: Device lock

    var lockAvailability: DeviceLock.Availability { DeviceLock.availability() }

    /// Prompts for Face ID, Touch ID or the passcode — whichever the phone has.
    func unlock() async {
        do {
            let context = try await DeviceLock.authenticate(reason: "Unlock Spiek")
            // A cold start with the lock on defers the Keychain read to this
            // moment: the account item demands user presence, and `context`
            // carries the presence just proven — one prompt, not two.
            if engine == nil {
                guard let store,
                      let account = Keychain.json(StoredAccount.self, for: "account",
                                                  context: context),
                      let mode = settings.mode else {
                    show("The account could not be read from the Keychain.", kind: .error)
                    return
                }
                try await activate(account: account, mode: mode, store: store)
            }
            isLocked = false
            await refresh()
        } catch DeviceLock.Failure.cancelled {
            // Leave the lock up; the user can try again.
        } catch {
            report(error)
        }
    }

    func setRequireUnlock(_ required: Bool) async {
        if required {
            guard lockAvailability.isUsable else {
                show("Set a passcode on this device first.", kind: .error)
                return
            }
            do {
                let context = try await DeviceLock.authenticate(reason: "Turn on the lock for Spiek")
                // The key itself moves behind user presence — the lock is a
                // keychain policy, not just a screen. Crash-safe; on failure
                // the item keeps its old protection and the toggle stays off.
                try Keychain.setProtection(userPresence: true, for: "account", context: context)
            } catch {
                report(error)
                return
            }
        } else {
            do {
                // Proven presence is required to switch the lock *off* too —
                // otherwise the toggle would defeat the very policy it
                // controls. Authenticated here, asynchronously, rather than
                // letting the keychain read block the main thread with its
                // own prompt; the same context then opens the item silently.
                let context = try await DeviceLock.authenticate(reason: "Turn off the lock for Spiek")
                try Keychain.setProtection(userPresence: false, for: "account", context: context)
            } catch {
                report(error)
                return
            }
        }
        var next = settings
        next.requireUnlock = required
        await saveSettings(next)
    }

    /// Locks again when the app leaves the foreground.
    func lockIfNeeded() {
        if settings.requireUnlock && phase == .ready { isLocked = true }
    }

    // MARK: Bootstrap

    func bootstrap() async {
        Typeface.register()
        do {
            // v1.21 (P0.5): finish a quarantine a crash interrupted before opening.
            StoreQuarantine.recoverInterrupted(liveDatabase: Store.defaultURL())
            let store = try Store(url: Store.defaultURL())
            self.store = store

            // Clamp whatever was stored: an older build wrote a 0.05 fee that
            // miners no longer accept.
            settings = (try await store.meta(Settings.self, key: "settings") ?? Settings()).normalized()

            // With the device lock on, the account item sits behind user
            // presence (`SecAccessControl`), so reading it here would raise
            // the system Face ID prompt before our own lock screen even
            // appears. Its presence is checked without touching the data;
            // the read happens in `unlock()`, with the context that single
            // prompt produces.
            if settings.requireUnlock, settings.mode != nil, Keychain.hasItem(for: "account") {
                isLocked = true
                phase = .ready  // LockView covers the (still empty) app.
                return
            }

            guard let account = Keychain.json(StoredAccount.self, for: "account"),
                  let mode = settings.mode else {
                phase = .onboarding
                return
            }
            isLocked = false
            try await activate(account: account, mode: mode, store: store)
        } catch {
            report(error)
            phase = .onboarding
        }
    }

    /// Creates a brand-new key from a freshly generated BIP-39 phrase.
    func createAccount(phrase: String, mode: WalletMode) async {
        do {
            let key = try RecoveryPhrase.key(forPhrase: phrase, scheme: .bip39)
            try await adopt(key: key, phrase: phrase, scheme: .bip39, mode: mode)
        } catch {
            report(error)
        }
    }

    /// Restores from 12 words or a WIF key. A phrase with a valid BIP-39
    /// checksum uses that derivation; anything else falls back to the older
    /// scheme, which `forceLegacy` can also be demanded outright.
    func importAccount(input: String, mode: WalletMode, forceLegacy: Bool = false) async {
        do {
            let restored = try RecoveryPhrase.restore(input, forceLegacy: forceLegacy)
            if restored.fellBackToLegacy {
                show("No valid BIP-39 checksum — restored with the older scheme.")
            }
            try await adopt(key: restored.key,
                            phrase: restored.phrase,
                            scheme: restored.scheme,
                            mode: mode)
        } catch {
            report(error)
        }
    }

    func startDemo() async {
        do {
            let phrase = RecoveryPhrase.generate()
            let key = try RecoveryPhrase.key(forPhrase: phrase, scheme: .bip39)
            try await adopt(key: key, phrase: phrase, scheme: .bip39, mode: .demo)
        } catch {
            report(error)
        }
    }

    private func adopt(key: PrivateKey,
                       phrase: String?,
                       scheme: PhraseScheme?,
                       mode: WalletMode) async throws {
        let account = StoredAccount(wif: key.wif, phrase: phrase, scheme: scheme)
        // Written under whatever protection the current lock setting asks
        // for: `requireUnlock` survives a sign-out, and a new account on a
        // locked device must not land in the keychain unguarded.
        try Keychain.setJSON(account, for: "account",
                             requireUserPresence: settings.requireUnlock)

        settings.mode = mode
        let store = try self.store ?? Store(url: Store.defaultURL())
        self.store = store
        try await store.putMeta(key: "settings", value: settings)

        // The person is right here, having just typed their phrase.
        isLocked = false
        try await activate(account: account, mode: mode, store: store)
    }

    private func activate(account: StoredAccount,
                          mode: WalletMode,
                          store: Store,
                          fundDemoWallet: Bool = true) async throws {
        // Re-onboarding without signing out would otherwise leave the previous
        // engine polling against the old wallet. The old one is kept around so
        // a failure below can put it back rather than leaving the app inert.
        let previous = engine
        await previous?.stop()

        do {
            let key = try PrivateKey(wif: account.wif)
            let wallet = Wallet(key: key,
                                dust: settings.dust,
                                feePerByte: settings.feePerByte)

            // v1.21 (P0.5): the durable store must belong to this wallet before
            // anything reads it. A mismatch is quarantined under an opaque name
            // and a fresh store takes its place — never rendered, never merged.
            var store = store
            if mode != .demo {
                let fingerprint = StoreOwnership.fingerprint(compressedPublicKey: key.publicKey.compressedBytes)
                let ownHash = key.publicKey.hash160.hex
                let verdict = try await StoreOwnership.verify(store: store, fingerprint: fingerprint, ownHash: ownHash)
                if verdict == .mismatch {
                    await store.close()
                    StoreQuarantine.quarantine(liveDatabase: Store.defaultURL())
                    let fresh = try Store(url: Store.defaultURL())
                    _ = try await StoreOwnership.verify(store: fresh, fingerprint: fingerprint, ownHash: ownHash)
                    try await fresh.putMeta(key: "settings", value: settings)
                    store = fresh
                    self.store = fresh
                    show("This device held chat data of another wallet. It was set aside unread — see You → Orphaned data to delete it.")
                }
            }

            let adapter: any ChainAdapter
            switch mode {
            case .demo:
                adapter = MockAdapter()
            case .chain, .node:
                adapter = RestAdapter(configuration: .from(settings: settings))
            }

            let next = Engine(wallet: wallet, adapter: adapter, store: store)
            await next.setDelegate(self)

            try await next.restoreUTXOs()
            _ = try await next.ensureNotesChannel()

            // Only on first activation: re-saving settings must not mint more
            // demo coins, and a fresh MockAdapter starts from an empty chain.
            if mode == .demo && fundDemoWallet {
                _ = try await next.demoTopUp(satoshis: 1_000_000)
            }

            engine = next
            currentAccount = account
            // v1.21 (P0.2): terms/report state and the signed moderation feed.
            Task { await loadTrustState(); await refreshModerationFeed() }
            address = next.address
            publicKeyHex = next.publicKeyHex
            myHash = next.hashHex
            phrase = account.phrase
            phraseScheme = account.scheme
            // The lock is deliberately NOT raised here. `saveSettings` rebuilds
            // the engine through this same path, and locking there would throw
            // the user out of the app every time they changed a setting. Only a
            // cold start locks — see `bootstrap`.

            await next.start(intervalSeconds: settings.pollSeconds)
            if mode != .demo {
                await next.startUTXOSync(intervalSeconds: settings.pollSeconds)
            }

            phase = .ready
            startPriceUpdates()
            await reload()
        } catch {
            // Put the working engine back rather than leaving the app inert.
            if let previous {
                engine = previous
                await previous.start(intervalSeconds: settings.pollSeconds)
                // The UTXO sync is its own task and needs its own restart.
                // Against a demo adapter it is a cheap no-op loop.
                await previous.startUTXOSync(intervalSeconds: settings.pollSeconds)
            }
            throw error
        }
    }

    // MARK: Price

    /// Keeps the dollar rate current for as long as the app is up.
    ///
    /// Deliberately separate from the chain poller: a price is not chain data,
    /// a node in node-mode does not serve one, and nothing on the sending path
    /// waits for it. If the feed is down the app shows sats and no dollars —
    /// never a stale number dressed up as a live one.
    func startPriceUpdates() {
        guard priceTask == nil else { return }
        priceTask = Task { [weak self] in
            // The last known rate first, so the wallet is not blank for the
            // length of one request after a cold start.
            await self?.loadStoredPrice()
            while !Task.isCancelled {
                guard let self else { return }
                await self.refreshPrice()
                do {
                    try await Task.sleep(nanoseconds: Self.priceIntervalSeconds * 1_000_000_000)
                } catch {
                    return
                }
            }
        }
    }

    func stopPriceUpdates() {
        priceTask?.cancel()
        priceTask = nil
    }

    private func loadStoredPrice() async {
        guard price == nil, let store else { return }
        if let stored = try? await store.meta(BSVPrice.self, key: Self.priceMetaKey) {
            price = stored
        }
    }

    func refreshPrice() async {
        do {
            let fetched = try await priceFeed.fetch()
            price = fetched
            priceError = nil
            // Cached so a relaunch has something to show immediately. It is
            // stamped with when it was fetched, and the settings row says so.
            try? await store?.putMeta(key: Self.priceMetaKey, value: fetched)
        } catch let failure as PriceFeed.Failure {
            priceError = failure.errorDescription ?? "The price could not be fetched."
            dropStalePrice()
        } catch {
            priceError = error.localizedDescription
            dropStalePrice()
        }
    }

    /// Lets go of a rate that has aged out while the feed was down.
    ///
    /// `usd(_:)` already refuses to print one, but it reads the clock, and a
    /// clock is not observable — a screen that is not redrawing for other
    /// reasons would keep the old figure on it. Clearing the value is what
    /// actually tells SwiftUI.
    private func dropStalePrice() {
        guard let price, Int(Date().timeIntervalSince1970) - price.fetched > Self.priceMaximumAgeSeconds
        else { return }
        self.price = nil
    }

    /// How old a rate may be before the app stops quoting it. BSV can move
    /// several percent in an hour; a figure next to a Send button that is
    /// hours old is worse than no figure at all.
    static let priceMaximumAgeSeconds = 30 * 60

    /// Whether the rate is fresh enough to print next to an amount.
    var priceIsFresh: Bool {
        guard let price else { return false }
        return Int(Date().timeIntervalSince1970) - price.fetched <= Self.priceMaximumAgeSeconds
    }

    /// Dollars for an amount, or nil when no *fresh* rate is known. Never a
    /// guess, and never a cached number passed off as a live one — the cache
    /// exists to fill the first second after launch, not to paper over a feed
    /// that has been down since yesterday. The settings row still shows the
    /// stale value, with its age spelled out.
    func usd(_ sats: UInt64) -> String? {
        guard priceIsFresh else { return nil }
        return Format.usd(sats: sats, price: price)
    }

    /// How old the rate on screen is, in words.
    var priceAge: String? {
        guard let price else { return nil }
        let seconds = max(0, Int(Date().timeIntervalSince1970) - price.fetched)
        if seconds < 90 { return "just now" }
        if seconds < 3600 { return "\(seconds / 60) min ago" }
        if seconds < 86_400 { return "\(seconds / 3600) h ago" }
        return "\(seconds / 86_400) d ago"
    }

    // MARK: Reading state back

    func reload() async {
        guard let engine, let store else { return }
        do {
            channels = try await store.allChannels()
            balance = await engine.balance()
            blockedSenders = (try? await engine.blockedSenders()) ?? []

            var loadedProfiles = [String: StoredProfile]()
            for channel in channels {
                guard let peerHash = channel.peerHash else { continue }
                if let profile = try await engine.profile(forSender: peerHash) {
                    loadedProfiles[peerHash] = profile
                }
            }
            profiles = loadedProfiles
            await loadMyProfile(store: store, engine: engine)

            // Probed ids are remembered, including the misses. Without that, a
            // chat with no photo costs one query per reload — and reload runs
            // after every send and every poll.
            let live = Set(channels.map(\.channelId))
            var loadedPhotos = chatPhotos.filter { live.contains($0.key) }
            photosProbed.formIntersection(live)
            for channel in channels where !photosProbed.contains(channel.channelId) {
                photosProbed.insert(channel.channelId)
                if let encoded = try await store.meta(String.self,
                                                      key: Self.photoKey(channel.channelId)),
                   let data = Data(base64Encoded: encoded),
                   let image = UIImage(data: data) {
                    loadedPhotos[channel.channelId] = image
                }
            }
            if loadedPhotos.keys.count != chatPhotos.keys.count
                || !loadedPhotos.keys.allSatisfy({ chatPhotos[$0] != nil }) {
                chatPhotos = loadedPhotos
            }

            if let activeChannelId {
                messages = try await engine.viewChannel(activeChannelId, limit: 60)
                // A message that arrives while its chat is on screen is read
                // the moment it is shown — without this the tab badge counted
                // the very conversation the user was looking at. `markRead`
                // no-ops when there is nothing unread, so this does not churn.
                try? await engine.markRead(channelId: activeChannelId)
            }
        } catch {
            report(error)
        }
    }

    func refresh() async {
        guard let engine else { return }
        isSyncing = true
        defer { isSyncing = false }
        do {
            _ = try await engine.syncUTXOs()
            _ = try await engine.pollOnce()
            if settings.mode == .demo { await engine.demoMineBlock() }
            await reload()
        } catch {
            report(error)
        }
    }

    // MARK: Channels

    func open(channel: ChannelRecord) async {
        await openChannel(id: channel.channelId)
    }

    /// Selects a channel and loads its contents. Every entry point — the chat
    /// list and all four sheets — goes through here, so a freshly created chat
    /// is never presented empty.
    func openChannel(id: String) async {
        activeChannelId = id
        editingTxid = nil
        replyingTo = nil
        draft = ""
        canLoadOlder = true
        await reload()
        try? await engine?.markRead(channelId: id)
        await reload()
    }

    func closeConversation() {
        activeChannelId = nil
        messages = []
        editingTxid = nil
        replyingTo = nil
        draft = ""
    }

    func loadOlder() async {
        guard let engine, let activeChannelId else { return }
        do {
            let loaded = try await engine.loadOlder(channelId: activeChannelId)
            if loaded == 0 {
                canLoadOlder = false
                show("No older messages found.")
            }
            await reload()
        } catch {
            report(error)
        }
    }

    // Opening a channel announces a public key on chain, so it costs a few
    // sats. There is deliberately no balance pre-check: `balance` is only as
    // fresh as the last poll, and coin selection already reports exactly what
    // is short.

    func newChat(name: String) async -> String? {
        await withEngine { engine in
            let id = try await engine.openChat(name: name.isEmpty ? nil : name, kind: .dm)
            await self.reload()
            return id
        }
    }

    func newGroup(name: String) async -> String? {
        await withEngine { engine in
            let id = try await engine.openChat(name: name.isEmpty ? nil : name, kind: .group)
            await self.reload()
            return id
        }
    }

    func loadInvite(code: String) async -> String? {
        guard let decoded = InviteCode.decode(code) else {
            show("That is not a chat code (spiek:chat:… or spiek:group:…).", kind: .error)
            return nil
        }
        return await withEngine { engine in
            let id = try await engine.openChat(name: nil,
                                               kind: decoded.kind,
                                               channelId: decoded.channelId,
                                               groupKey: decoded.groupKey)
            _ = try await engine.pollOnce()
            await self.reload()
            return id
        }
    }

    func openByAddress(_ address: String) async -> String? {
        await withEngine { engine in
            let id = try await engine.openChat(peerAddressOrHash: address, kind: .dm)
            await self.reload()
            return id
        }
    }

    func deleteActiveChannel() async {
        guard let engine, let activeChannelId else { return }
        do {
            try await engine.deleteChannel(activeChannelId)
            // The photo lives in meta, which `deleteChannel` knows nothing
            // about. Left behind, it would reappear on the same channel id if
            // the invite code were ever loaded again.
            try? await store?.deleteMeta(key: Self.photoKey(activeChannelId))
            chatPhotos[activeChannelId] = nil
            photosProbed.remove(activeChannelId)
            closeConversation()
            await reload()
            show("Chat removed from this device.")
        } catch {
            report(error)
        }
    }

    /// Takes an id, not a record. A sheet can sit open for minutes while the
    /// chat keeps moving, and `putChannel` writes the whole row — saving a
    /// stale copy would roll back `unread`, `lastSort`, `plain` and, worst of
    /// all, `peerPub`, which would drop the chat back to plaintext.
    func rename(channelId: String, to name: String) async {
        guard let store else { return }
        do {
            guard var updated = try await store.channel(channelId) else { return }
            let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
            updated.name = trimmed.isEmpty ? nil : trimmed
            try await store.putChannel(updated)
            await reload()
        } catch {
            report(error)
        }
    }

    // MARK: Chat photo

    /// Everything about a chat photo stays on this device: it is never written
    /// to the chain and never sent to the other side. Renaming works the same
    /// way, which is why anyone in a chat can do both — not only whoever
    /// created it.
    static func photoKey(_ channelId: String) -> String { "photo:\(channelId)" }

    /// Square, 250 points, and squeezed under 20 KB. A chat list holds hundreds
    /// of these, so the ceiling is the point.
    static let chatPhotoEdge: CGFloat = 250
    static let chatPhotoMaximumBytes = 20 * 1024

    static func encodeChatPhoto(_ image: UIImage) -> Data? {
        let edge = chatPhotoEdge
        let format = UIGraphicsImageRendererFormat.default()
        format.scale = 1
        format.opaque = true

        // Centre-crop to a square first, so nothing is squashed.
        let square = UIGraphicsImageRenderer(size: CGSize(width: edge, height: edge),
                                             format: format).image { _ in
            let size = image.size
            guard size.width > 0, size.height > 0 else { return }
            let scale = max(edge / size.width, edge / size.height)
            let scaled = CGSize(width: size.width * scale, height: size.height * scale)
            image.draw(in: CGRect(x: (edge - scaled.width) / 2,
                                  y: (edge - scaled.height) / 2,
                                  width: scaled.width,
                                  height: scaled.height))
        }

        // Walk the quality down until it fits. Photographs of people rarely
        // need more than the first few steps.
        // Integer steps: a Double stride from 0.7 by -0.05 lands on
        // 0.19999999999999996 and never reaches the 0.15 floor.
        for step in stride(from: 70, through: 15, by: -5) {
            guard let data = square.jpegData(compressionQuality: CGFloat(step) / 100) else { continue }
            if data.count <= chatPhotoMaximumBytes { return data }
        }
        // Last resort: half the edge as well, rather than refuse the picture.
        let small = UIGraphicsImageRenderer(size: CGSize(width: edge / 2, height: edge / 2),
                                            format: format).image { _ in
            square.draw(in: CGRect(x: 0, y: 0, width: edge / 2, height: edge / 2))
        }
        guard let data = small.jpegData(compressionQuality: 0.5),
              data.count <= chatPhotoMaximumBytes else { return nil }
        return data
    }

    func setChatPhoto(_ image: UIImage?, for channelId: String) async {
        guard let store else { return }
        do {
            guard let image else {
                try await store.deleteMeta(key: Self.photoKey(channelId))
                chatPhotos[channelId] = nil
                show("Photo removed.")
                return
            }
            guard let data = Self.encodeChatPhoto(image) else {
                show("That picture could not be made small enough.", kind: .error)
                return
            }
            try await store.putMeta(key: Self.photoKey(channelId),
                                    value: data.base64EncodedString())
            chatPhotos[channelId] = UIImage(data: data)
            show("Photo saved on this device.")
        } catch {
            report(error)
        }
    }

    func chatPhoto(for channelId: String) -> UIImage? { chatPhotos[channelId] }

    // MARK: Your own profile

    /// Kept apart from the chain copy under `profile:<hash>` on purpose. That
    /// one is written by the walker when your own PROFILE message comes back
    /// out of a block, which can take minutes; this one is written the moment
    /// you type it. Without it the fields on the You screen were pure `@State`
    /// and emptied themselves on every app launch — the exact complaint.
    ///
    /// Keyed by the wallet's own hash, not a bare "self": signing out does not
    /// empty the store, so a flat key would show the previous account's name
    /// and picture to whoever signs in next on the same phone.
    static func selfProfileKey(_ hash: String) -> String { "profile:self:\(hash)" }
    static func selfPhotoKey(_ hash: String) -> String { "photo:self:\(hash)" }

    /// Stores your name and bio on this device. Nothing is broadcast here —
    /// publishing is a separate, explicit step.
    func saveMyProfile(name: String, bio: String) async {
        let trimmedName = name.trimmingCharacters(in: .whitespacesAndNewlines)
        let trimmedBio = bio.trimmingCharacters(in: .whitespacesAndNewlines)
        let profile = StoredProfile(name: trimmedName.isEmpty ? nil : trimmedName,
                                    bio: trimmedBio.isEmpty ? nil : trimmedBio,
                                    time: Int(Date().timeIntervalSince1970))
        myProfile = profile
        guard !myHash.isEmpty else { return }
        do {
            try await store?.putMeta(key: Self.selfProfileKey(myHash), value: profile)
        } catch {
            report(error)
        }
    }

    /// Same size ceiling as a chat photo: 250 points square, under 20 KB.
    func setMyPhoto(_ image: UIImage?) async {
        guard let store, !myHash.isEmpty else { return }
        let key = Self.selfPhotoKey(myHash)
        do {
            guard let image else {
                try await store.deleteMeta(key: key)
                myPhoto = nil
                show("Picture removed.")
                return
            }
            guard let data = Self.encodeChatPhoto(image) else {
                show("That picture could not be made small enough.", kind: .error)
                return
            }
            try await store.putMeta(key: key, value: data.base64EncodedString())
            myPhoto = UIImage(data: data)
            show("Picture saved on this device.")
        } catch {
            report(error)
        }
    }

    /// The device copy wins whenever there is one. The chain copy only fills in
    /// on a phone that has never had one — a fresh restore, where it is the
    /// only copy in existence.
    ///
    /// Deliberately *not* decided on timestamps. The two are stamped on
    /// different clocks: the device copy carries the moment it was typed, the
    /// chain copy the moment this phone happened to walk past the transaction.
    /// Comparing them loses exactly where it matters — a two-year-old published
    /// name, ingested two minutes ago, would beat the name typed this morning
    /// and silently overwrite it. Which is the complaint this whole thing
    /// exists to fix.
    private func loadMyProfile(store: Store, engine: Engine) async {
        guard !myHash.isEmpty else { return }
        if let local = try? await store.meta(StoredProfile.self, key: Self.selfProfileKey(myHash)) {
            myProfile = local
        } else if let published = try? await engine.profile(forSender: myHash) {
            myProfile = published
        }

        // Decoding a base64 picture on every reload — which runs after every
        // send and every poll — would be wasteful, so it is read once.
        if !myPhotoProbed {
            myPhotoProbed = true
            if let encoded = try? await store.meta(String.self, key: Self.selfPhotoKey(myHash)),
               let data = Data(base64Encoded: encoded) {
                myPhoto = UIImage(data: data)
            }
        }
    }

    // MARK: SNS names

    /// One oracle for both namespaces: a direct question about a single
    /// outpoint. Not "is it in the holder address's unspent list" — that list
    /// truncates on a busy address and would report a perfectly good name as
    /// spent, and it cannot answer at all for an outpoint whose script differs
    /// from the address the name pays to.
    @ObservationIgnored private let outpoints = WhatsOnChainOracle()

    /// Level `prove`: signature against the pinned resolver key, the freshness
    /// window, *and* the holder's outpoint proved unspent. Opening a chat binds
    /// a dust output to the resolved address, so it is a payment and is treated
    /// as one.
    @ObservationIgnored private lazy var sns = SNSResolver(
        pins: KeychainSNSPins(),
        unspentCheck: { [outpoints] outpoint in
            switch await outpoints.state(txid: outpoint.txid, vout: outpoint.vout) {
            case .unspent: return true
            case .spent: return false
            // Never `false`: an oracle that could not answer has said nothing,
            // and turning that into "spent" would refuse a good name.
            case .unknown: return nil
            }
        }
    )

    @ObservationIgnored private let opnsIndex = OpNSIndex()
    /// The root check runs once per launch, not per lookup.
    @ObservationIgnored private var opnsRootChecked = false
    /// Set when the index answered but did not agree about the root. Thrown by
    /// every lookup for as long as it is set.
    @ObservationIgnored private var opnsRootRejected: OpNS.Failure?
    /// True only for a *disagreement*. A withheld root is also a refusal, but
    /// it is an absence rather than a contradiction, so it is re-checked; a
    /// wrong root is not something to retry past.
    @ObservationIgnored private var opnsRootRejectionIsFinal = false
    /// When the check last ran, so an index that is simply down does not cost
    /// every lookup an extra request and a 15-second timeout.
    @ObservationIgnored private var opnsRootLastAttempt: Date?
    /// The check in flight, shared by everyone who asks while it runs.
    @ObservationIgnored private var opnsRootCheck: Task<RootOutcome, Never>?
    static let opnsRootRetrySeconds: TimeInterval = 300

    enum RootOutcome: Sendable {
        /// The index named the root this app has pinned.
        case confirmed
        /// It answered, and did not. Refuses the lookup.
        case refused(OpNS.Failure)
        /// It could not be reached, or said something unreadable. That is not
        /// a statement about the root.
        case couldNotAsk
    }

    /// Cross-checks the root the index serves against the one pinned here.
    ///
    /// Three outcomes, and the difference between them is the whole design:
    ///
    /// - It named the pinned root. Checked once, then never again this launch.
    /// - It answered and named a *different* root — or would not name one at
    ///   all. Both refuse the lookup: an index that withholds the root is
    ///   indistinguishable from one serving a tree of its own, so waving it
    ///   through would let a tampered `/status` unlock everything. Only the
    ///   contradiction is permanent; the silence is re-checked on the backoff,
    ///   because one malformed answer must not lock the feature out for the
    ///   life of the process with no way back short of signing out.
    /// - It could not be reached. That says nothing about the root, so the
    ///   lookup continues. Blocking on it is what took the whole feature down
    ///   once already, over a cosmetic timestamp field.
    ///
    /// The in-flight check is shared. Setting a timestamp before awaiting and
    /// letting the next caller skip on it would open a window exactly as wide
    /// as the request it is meant to be protecting.
    private func confirmOpNSRoot() async throws {
        if let rejected = opnsRootRejected {
            if opnsRootRejectionIsFinal { throw rejected }
            // Still refusing — but due for another look.
            if let last = opnsRootLastAttempt,
               Date().timeIntervalSince(last) < Self.opnsRootRetrySeconds {
                throw rejected
            }
        } else if opnsRootChecked {
            return
        } else if let last = opnsRootLastAttempt,
                  Date().timeIntervalSince(last) < Self.opnsRootRetrySeconds {
            // A transport failure, recently. Let this lookup through rather
            // than paying for the same timeout again.
            return
        }

        let outcome: RootOutcome
        if let running = opnsRootCheck {
            outcome = await running.value
        } else {
            let task = Task<RootOutcome, Never> { [opnsIndex] in
                do {
                    _ = try await opnsIndex.status()
                    return .confirmed
                } catch let failure as OpNS.Failure {
                    switch failure {
                    case .genesisMismatch, .rootNotReported: return .refused(failure)
                    default: return .couldNotAsk
                    }
                } catch {
                    return .couldNotAsk
                }
            }
            opnsRootCheck = task
            outcome = await task.value
            opnsRootCheck = nil
        }

        switch outcome {
        case .confirmed:
            opnsRootChecked = true
            opnsRootRejected = nil
            opnsRootRejectionIsFinal = false
            opnsRootLastAttempt = nil
        case let .refused(failure):
            opnsRootRejected = failure
            // Only a contradiction is permanent. A withheld root is refused
            // just as hard, but re-checked, so one malformed answer cannot
            // lock the feature out until the app is force-quit.
            if case .genesisMismatch = failure { opnsRootRejectionIsFinal = true }
            opnsRootLastAttempt = Date()
            throw failure
        case .couldNotAsk:
            opnsRootLastAttempt = Date()
            // A standing refusal is not lifted by a failed attempt to re-check
            // it.
            if let rejected = opnsRootRejected { throw rejected }
            return
        }
    }

    /// The OpNS index, plus the two things that keep it honest: the chain to
    /// recompute the holder from, and the same outpoint oracle.
    @ObservationIgnored private lazy var opns = OpNSResolver(
        directory: opnsIndex,
        oracle: outpoints,
        rawTransaction: { [weak self] txid in
            guard let engine = await self?.engine else { return nil }
            return try? await engine.fetchRaw(txid: txid)?.hex
        }
    )

    /// The last lookup, so the sheet can show what was found before acting.
    var snsResult: SNSResolved?
    var snsBusy = false

    func inputLooksLikeSNS(_ input: String) async -> Bool {
        await sns.looksLikeSNS(input)
    }

    @discardableResult
    func lookUpSNS(_ input: String) async -> SNSResolved? {
        snsBusy = true
        defer { snsBusy = false }
        do {
            let found = try await sns.resolve(input, assurance: .prove)
            snsResult = found
            return found
        } catch let failure as SNS.Failure {
            snsResult = nil
            // The resolver's own wording is better than anything invented here,
            // and the domain status must never be phrased like a signature
            // problem — they are different things.
            show(failure.errorDescription ?? failure.code, kind: .error)
            return nil
        } catch {
            snsResult = nil
            report(error)
            return nil
        }
    }

    func clearSNSResult() { snsResult = nil }

    // MARK: OpNS names

    /// The last OpNS lookup, so the sheet can show the exact name and the
    /// verified holder before anything is written to that address.
    var opnsResult: OpNSResolver.Resolved?
    var opnsBusy = false

    func inputLooksLikeOpNS(_ input: String) -> Bool { OpNS.looksLikeOpNS(input) }

    /// Resolved for payment on every call, never from a cache: opening a chat
    /// binds a dust output to the address, and a name can be sold between
    /// typing it and confirming it.
    @discardableResult
    func lookUpOpNS(_ input: String) async -> OpNSResolver.Resolved? {
        opnsBusy = true
        defer { opnsBusy = false }
        do {
            // Once per launch: confirm the index is serving the root this app
            // has pinned. The pin stays the pin — this only surfaces a
            // disagreement instead of quietly resolving against another tree.
            try await confirmOpNSRoot()
            let found = try await opns.resolve(input, forPayment: true)
            opnsResult = found
            return found
        } catch let failure as OpNS.Failure {
            opnsResult = nil
            show(failure.errorDescription ?? failure.code, kind: .error)
            return nil
        } catch {
            opnsResult = nil
            report(error)
            return nil
        }
    }

    func clearOpNSResult() { opnsResult = nil }

    // MARK: The names on this wallet

    /// What the two indexes say this address holds.
    ///
    /// Each side carries its own error, because a broken OpNS index must not
    /// take the SNS list down with it — and the other way round.
    struct NameHoldings {
        var sns: [String] = []
        var snsTruncated = false
        var snsError: String?
        var opns: [OpNS.Name] = []
        var opnsError: String?
        var loading = false
        /// Whether either index has actually been asked. Without it an empty
        /// list would be presented as "this address holds no names" before a
        /// single request had been made.
        var hasLoaded = false

        var isEmpty: Bool { sns.isEmpty && opns.isEmpty }
    }

    var myNames = NameHoldings()

    /// Neither list is signed. They say which names an index believes this
    /// address holds — useful, and not a verification. Tapping one runs the
    /// real check.
    func loadMyNames() async {
        guard !address.isEmpty else {
            // Nothing to ask about yet. Recorded as answered, or the sheet
            // would sit blank with neither a list, an empty state, nor an
            // error — and no way to tell which.
            myNames.hasLoaded = true
            return
        }
        // A pull-to-refresh landing on top of the first load would let whichever
        // finishes last win, regardless of which asked last.
        guard !myNames.loading else { return }
        myNames.loading = true
        defer { myNames.loading = false }

        var holdings = NameHoldings()

        do {
            let listing = try await sns.names(ownedBy: address)
            holdings.sns = listing.names
            holdings.snsTruncated = listing.more
        } catch let failure as SNS.Failure {
            holdings.snsError = failure.errorDescription ?? failure.code
        } catch {
            holdings.snsError = error.localizedDescription
        }

        do {
            holdings.opns = try await opnsIndex.names(ownedBy: address)
        } catch let failure as OpNS.Failure {
            holdings.opnsError = failure.errorDescription ?? failure.code
        } catch {
            holdings.opnsError = error.localizedDescription
        }

        holdings.hasLoaded = true
        myNames = holdings
    }

    /// The verified detail behind one of the listed names. Kept apart from
    /// `snsResult`/`opnsResult` on purpose: those two drive the confirm step of
    /// a payment, and a browsing screen must not be able to arm it.
    enum NameDetail {
        case sns(SNSResolved)
        case opns(OpNSResolver.Resolved)
        case failed(String)
    }

    func verify(name: String) async -> NameDetail {
        if OpNS.looksLikeOpNS(name) {
            do {
                // Display, not payment: the outpoint proof is reported rather
                // than required, so a name whose index entry is lagging still
                // shows instead of vanishing behind an error.
                return .opns(try await opns.resolve(name, forPayment: false))
            } catch let failure as OpNS.Failure {
                return .failed(failure.errorDescription ?? failure.code)
            } catch {
                return .failed(error.localizedDescription)
            }
        }
        do {
            return .sns(try await sns.resolve(name, assurance: .verify))
        } catch let failure as SNS.Failure {
            return .failed(failure.errorDescription ?? failure.code)
        } catch {
            return .failed(error.localizedDescription)
        }
    }

    // MARK: Blocked senders and reporting

    /// Sender hashes this device refuses to show. Mirrors the engine's list;
    /// `reload` keeps it current. Local only — nothing goes on chain and the
    /// other side is never told.
    var blockedSenders: Set<String> = []

    func isBlocked(_ sender: String) -> Bool { blockedSenders.contains(sender) }

    func setBlocked(_ sender: String, blocked: Bool) async {
        guard let engine else { return }
        do {
            try await engine.setBlocked(sender, blocked: blocked)
            blockedSenders = (try? await engine.blockedSenders()) ?? blockedSenders
            show(blocked ? "Blocked — their messages are hidden on this device."
                         : "Unblocked.")
            await reload()
        } catch {
            report(error)
        }
    }

    /// The prefilled "report a problem" mail. Identifiers only — the channel
    /// id and recent transaction ids — never message text: the report must
    /// not leak what the reporter was reading.
    func reportURL(channelId: String? = nil) -> URL? {
        var body = "Describe the problem:\n\n\n— details for the Spiek team —\n"
        if let channelId {
            body += "Channel: \(channelId)\n"
            if channelId == activeChannelId {
                let txids = messages.suffix(10).map(\.record.txid)
                if !txids.isEmpty {
                    body += "Recent transactions:\n\(txids.joined(separator: "\n"))\n"
                }
            }
        }
        let version = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "?"
        body += "App version: \(version)"

        var components = URLComponents()
        components.scheme = "mailto"
        components.path = "hello@spiek.me"
        components.queryItems = [URLQueryItem(name: "subject", value: "Spiek report"),
                                 URLQueryItem(name: "body", value: body)]
        return components.url
    }

    // MARK: Pinned messages

    /// Messages that have not landed yet, or that came back with an error. They
    /// sort after everything confirmed, so without a pin they sit at the very
    /// bottom of the chat — far away from where they were written.
    ///
    /// This used to wait two minutes before pinning anything, which was wrong
    /// twice over. It contradicted what was asked for — "not yet in a block"
    /// belongs at the top *now*, not once it has also become old — and it
    /// compared against `Date()`, which is not observable, so nothing told
    /// SwiftUI to re-evaluate when the clock crossed the threshold. The bar
    /// only ever appeared if some *other* observed change happened to redraw
    /// the view at the right moment. No clock is read here any more: the
    /// message's own state is the whole condition.
    var pinnedMessages: [ViewMessage] {
        messages.filter { message in
            // Only our own: there is nothing to do about someone else's
            // message that has not landed yet.
            guard message.record.mine else { return false }
            // Belt and braces with the engine, which clears the error when a
            // transaction reaches a block: whatever else is true, something in
            // a block is not an outstanding problem.
            guard message.record.status != .confirmed else { return false }
            // `.sent` is exactly "broadcast accepted, not in a block yet".
            // `.pending` is deliberately not pinned: the engine marks a record
            // pending and notifies the UI *before* the broadcast round-trip, so
            // pinning it would flash the bar on every send — and a tap on the x
            // during that flash would suppress the real pin a moment later.
            let unsettled = message.record.error != nil || message.record.status == .sent
            return unsettled && !dismissedPins.contains(Self.pinKey(message))
        }
    }

    /// Keyed by state as well as identity: waving away "not in a block yet"
    /// must not also hide the failure that may follow it.
    static func pinKey(_ message: ViewMessage) -> String {
        // `pending` and `sent` are one bucket on purpose: a broadcast flips
        // between them within milliseconds, and a dismissal must not be undone
        // by that. Only reaching a block, or picking up an error, is a change
        // worth showing again.
        let settled = message.record.status == .confirmed ? "confirmed" : "waiting"
        return "\(message.record.txid)|\(settled)|\(message.record.error ?? "")"
    }

    func dismissPin(_ message: ViewMessage) {
        dismissedPins.insert(Self.pinKey(message))
    }

    // MARK: Sending

    func sendDraft() async {
        // v1.21 (P0.2/P0.3): terms first, then — for a public group — the one-time
        // "permanent and public" disclosure, then the actual send.
        guard let channelId = activeChannelId else { return }
        let channel = channels.first { $0.channelId == channelId }
        let isPublicGroup = channel?.kind == .group && channel?.groupKey == nil
        requireTerms { [weak self] in
            guard let self else { return }
            Task {
                if isPublicGroup {
                    await self.requireDisclosure("publicGroup") { Task { await self.sendDraftNow() } }
                } else {
                    await self.sendDraftNow()
                }
            }
        }
    }

    private func sendDraftNow() async {
        let text = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty, let activeChannelId else { return }

        if let editingTxid {
            guard let ref = Hex.decode(editingTxid)?.reversedBytes else { return }
            self.editingTxid = nil
            draft = ""
            await send(.init(op: .edit,
                             payload: Codecs.encodeText(text),
                             ref: ref),
                       to: activeChannelId)
            return
        }

        // A reply is an ordinary message that carries a ref to the original.
        let replyRef = replyingTo.flatMap { Hex.decode($0.record.txid)?.reversedBytes }
        replyingTo = nil
        draft = ""
        // v1.20: optimistic echo — the bubble appears the moment send is
        // tapped; a poll holding the engine can no longer delay it. reload()
        // rebuilds the list, replacing this synthetic row with the real record
        // (or clearing it when sending failed).
        appendOptimistic(channelId: activeChannelId, text: text)
        await send(.init(op: .msg,
                         payload: Codecs.encodeText(text),
                         ref: replyRef),
                   to: activeChannelId)
    }

    /// v1.20: a synthetic pending row shown until `reload()` brings the real record.
    private func appendOptimistic(channelId: String, text: String) {
        guard activeChannelId == channelId,
              let channel = channels.first(where: { $0.channelId == channelId }) else { return }
        let kind = channel.kind
        // Show the lock the real record will get, so the bubble does not flash
        // "unencrypted" for a second in an encrypted chat.
        let willEncrypt: Bool
        switch kind {
        case .group: willEncrypt = channel.groupKey != nil
        case .note: willEncrypt = !channel.plain
        case .dm: willEncrypt = channel.peerPub != nil && !channel.plain
        }
        let record = MessageRecord(txid: "optimistic-\(UInt64(Date().timeIntervalSince1970 * 1_000_000))",
                                   channel: channelId,
                                   sender: myHash,
                                   senderPub: "",
                                   senderAddress: "",
                                   kind: kind,
                                   op: .msg,
                                   time: Int(Date().timeIntervalSince1970),
                                   // After every persisted sort key, so the bubble sits at the bottom.
                                   sort: .greatestFiniteMagnitude,
                                   status: .pending,
                                   mine: true)
        messages.append(ViewMessage(record: record,
                                    viewOp: .msg,
                                    viewPayload: Codecs.encodeText(text),
                                    encrypted: willEncrypt,
                                    unreadable: false))
    }

    // MARK: Trust & Safety (v1.21, P0.2)

    struct ReportEntry: Codable, Identifiable, Equatable {
        let id: String
        let token: String
        let category: String
        var status: String
        let at: Int
    }

    var reportLog: [ReportEntry] = []
    var termsAccepted = false
    var pendingTermsAction: (() -> Void)?
    var pendingDisclosure: (topic: String, action: () -> Void)?
    var feedStatus = "no feed accepted"

    private var moderationBase: String {
        var base = settings.moderationURL.trimmingCharacters(in: .whitespacesAndNewlines)
        while base.hasSuffix("/") { base = String(base.dropLast()) }
        return base
    }

    private func httpJSON(_ method: String, _ url: String, body: [String: Any]? = nil, token: String? = nil) async -> (Int, [String: Any]) {
        guard let target = URL(string: url) else { return (0, [:]) }
        var request = URLRequest(url: target, timeoutInterval: 10)
        request.httpMethod = method
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        if let token { request.setValue(token, forHTTPHeaderField: "X-Status-Token") }
        if let body {
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.httpBody = try? JSONSerialization.data(withJSONObject: body)
        }
        do {
            let (data, response) = try await URLSession.shared.data(for: request)
            let code = (response as? HTTPURLResponse)?.statusCode ?? 0
            let json = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] ?? [:]
            return (code, json)
        } catch {
            return (0, [:])
        }
    }

    func loadTrustState() async {
        guard let store else { return }
        termsAccepted = await Moderation.termsAccepted(store)
        reportLog = (try? await store.meta([ReportEntry].self, key: Moderation.reportsKey)) ?? []
        if let feed = try? await Moderation.accepted(store) {
            feedStatus = "feed seq \(feed.seq), \(feed.entries.count) entries, expires \(feed.expiresAt.prefix(10))"
        } else {
            feedStatus = "no feed accepted"
        }
    }

    /// Terms & Community Standards must be accepted before the first post (blocking).
    func requireTerms(_ action: @escaping () -> Void) {
        if termsAccepted || settings.mode == .demo { action() } else { pendingTermsAction = action }
    }

    func acceptTerms() async {
        guard let store else { return }
        try? await Moderation.acceptTerms(store)
        termsAccepted = true
        let action = pendingTermsAction
        pendingTermsAction = nil
        action?()
    }

    /// P0.3: one specific warning before the first public-group post / media upload.
    func requireDisclosure(_ topic: String, _ action: @escaping () -> Void) async {
        guard let store else { action(); return }
        if await Moderation.disclosed(store, topic: topic) { action() } else { pendingDisclosure = (topic, action) }
    }

    func confirmDisclosure() async {
        guard let store, let pending = pendingDisclosure else { return }
        try? await Moderation.markDisclosed(store, topic: pending.topic)
        pendingDisclosure = nil
        pending.action()
    }

    /// Sends a report to the moderation service. "Received" is only shown after
    /// the service answered with an id; otherwise it is logged as failed.
    func report(category: String, channelId: String, txid: String?, sender: String?, op: String?, plaintext: String?, note: String) async -> Bool {
        guard let store else { return false }
        var body: [String: Any] = ["category": category, "channelId": channelId, "note": String(note.prefix(2000)), "app": "ios/1.21.1"]
        if let txid { body["txid"] = txid }
        if let sender { body["sender"] = sender }
        if let op { body["op"] = op }
        if let plaintext { body["plaintext"] = plaintext; body["consentPlaintext"] = true }
        let (code, json) = await httpJSON("POST", "\(moderationBase)/reports", body: body)
        let now = Int(Date().timeIntervalSince1970)
        let entry: ReportEntry
        if code == 201, let id = json["id"] as? String, let token = json["statusToken"] as? String {
            entry = ReportEntry(id: id, token: token, category: category, status: "received", at: now)
        } else {
            entry = ReportEntry(id: "local-\(now)", token: "", category: category, status: "failed", at: now)
        }
        reportLog.append(entry)
        try? await store.putMeta(key: Moderation.reportsKey, value: reportLog)
        if entry.status == "received" {
            show("Report received — reference \(entry.id.prefix(8))…. Follow it under You → Reports.")
        } else {
            show("The report service could not be reached. The report is kept as failed; retry, or send it by e-mail (no receipt).", kind: .error)
        }
        return entry.status == "received"
    }

    func refreshReportStatuses() async {
        guard let store else { return }
        for index in reportLog.indices where !reportLog[index].token.isEmpty {
            let (code, json) = await httpJSON("GET", "\(moderationBase)/reports/\(reportLog[index].id)/status", token: reportLog[index].token)
            if code == 200, let status = json["status"] as? String { reportLog[index].status = status }
        }
        try? await store.putMeta(key: Moderation.reportsKey, value: reportLog)
    }

    func appealReport(_ entry: ReportEntry, reason: String) async {
        let (code, _) = await httpJSON("POST", "\(moderationBase)/reports/\(entry.id)/appeal", body: ["reason": String(reason.prefix(2000))], token: entry.token)
        show(code == 200 ? "Appeal filed." : "Appeal could not be sent.", kind: code == 200 ? .info : .error)
        await refreshReportStatuses()
    }

    /// Pulls the signed moderation feed; anything but a valid, newer feed is ignored.
    func refreshModerationFeed() async {
        guard let store, settings.mode != .demo, let url = URL(string: "\(moderationBase)/moderation/feed") else { return }
        guard let (data, response) = try? await URLSession.shared.data(from: url),
              (response as? HTTPURLResponse)?.statusCode == 200 else { return }
        if (try? await Moderation.accept(store, data: data)) == .ok {
            await loadTrustState()
            await reload()
        }
    }

    // MARK: Orphaned stores (v1.21, P0.5)

    /// Ids of quarantined stores on this device — names only, never contents.
    func orphanedStores() -> [String] { StoreQuarantine.orphans().map(\.id) }

    func deleteOrphanedStore(_ id: String) {
        StoreQuarantine.delete(id: id, liveDatabase: Store.defaultURL())
        show("Orphaned data deleted.")
    }

    // MARK: Storage protection (v1.21, P0.6)

    /// Applies backup exclusion + file protection to the Spiek folder. Fail-closed:
    /// a failure is reported as an error banner rather than ignored.
    func reapplyStorageProtection() {
        guard settings.mode != .demo else { return }
        do {
            try StorageProtection.apply(to: Store.defaultURL().deletingLastPathComponent())
        } catch {
            report(error)
        }
    }

    // MARK: BSV21 tokens (v1.20)

    /// One BSV21 balance row, straight from the shared token-index contract.
    struct TokenBalance: Identifiable, Equatable {
        let id: String
        let sym: String
        let amount: String
        let dec: Int
        let status: String

        /// `amount` scaled by `dec` without ever leaving integer math.
        var display: String {
            let negative = amount.hasPrefix("-")
            var digits = amount
            if negative || amount.hasPrefix("+") { digits = String(amount.dropFirst()) }
            guard !digits.isEmpty, digits.allSatisfy(\.isNumber) else { return amount }
            func grouped(_ text: String) -> String {
                var out = [Character](); var count = 0
                for character in text.reversed() {
                    if count != 0 && count % 3 == 0 { out.append(",") }
                    out.append(character); count += 1
                }
                return String(out.reversed())
            }
            guard dec > 0, dec <= 36 else { return (negative ? "-" : "") + grouped(digits) }
            let padded = String(repeating: "0", count: max(0, dec + 1 - digits.count)) + digits
            let whole = String(padded.dropLast(dec))
            var frac = String(padded.suffix(dec))
            while frac.hasSuffix("0") { frac = String(frac.dropLast()) }
            return (negative ? "-" : "") + grouped(whole) + (frac.isEmpty ? "" : "." + frac)
        }
    }

    enum TokenSection: Equatable {
        case off
        case loading
        case unreachable
        case loaded([TokenBalance])
    }

    var tokenSection: TokenSection = .off

    /// Fetches BSV21 balances from the configured token index —
    /// `GET {base}/address/{address}/balance` per the shared indexer contract.
    /// Display-only: amounts stay strings, and an unreachable index hides the
    /// section without losing anything (the tokens live on the chain).
    func refreshTokens() async {
        var base = settings.tokenURL.trimmingCharacters(in: .whitespacesAndNewlines)
        while base.hasSuffix("/") { base = String(base.dropLast()) }
        guard !base.isEmpty, settings.mode == .node, !myHash.isEmpty,
              let hashBytes = Hex.decode(myHash), hashBytes.count == 20 else {
            tokenSection = .off
            return
        }
        let address = Address.encode(hash160: hashBytes)
        guard let url = URL(string: "\(base)/address/\(address)/balance") else {
            tokenSection = .off
            return
        }
        tokenSection = .loading
        var request = URLRequest(url: url, timeoutInterval: 10)
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        do {
            let (data, response) = try await URLSession.shared.data(for: request)
            guard let http = response as? HTTPURLResponse, (200...299).contains(http.statusCode) else {
                tokenSection = .unreachable
                return
            }
            guard let balances = Self.parseTokenBalances(data) else {
                tokenSection = .unreachable
                return
            }
            tokenSection = .loaded(balances)
        } catch {
            tokenSection = .unreachable
        }
    }

    private static func parseTokenBalances(_ data: Data) -> [TokenBalance]? {
        let parsed = try? JSONSerialization.jsonObject(with: data)
        let items: [[String: Any]]
        if let array = parsed as? [[String: Any]] {
            items = array
        } else if let object = parsed as? [String: Any] {
            items = (object["balances"] as? [[String: Any]]) ?? (object["tokens"] as? [[String: Any]]) ?? []
        } else {
            return nil
        }
        func text(_ item: [String: Any], _ keys: [String]) -> String? {
            for key in keys {
                if let value = item[key] as? String, !value.isEmpty { return value }
                if let value = item[key] as? NSNumber { return value.stringValue }
            }
            return nil
        }
        return items.prefix(50).map { item in
            let id = text(item, ["id", "tokenId"]) ?? ""
            let symRaw = text(item, ["sym", "tick", "symbol"]).map { String($0.prefix(12)) }
            let fallback = id.count > 8 ? String(id.prefix(8)) + "…" : "token"
            return TokenBalance(id: id,
                                sym: (symRaw?.isEmpty == false ? symRaw! : fallback),
                                amount: text(item, ["amount", "balance", "confirmed"]) ?? "0",
                                dec: (item["dec"] as? Int) ?? (item["decimals"] as? Int) ?? 0,
                                status: (text(item, ["status", "validity"]) ?? "").lowercased())
        }
    }

    /// Coins straight to an address — no chat, no on-chain record.
    func payToAddress(_ address: String, satoshis: UInt64) async -> Bool {
        guard let engine else { return false }
        let trimmed = address.trimmingCharacters(in: .whitespacesAndNewlines)
        guard Address.isValid(trimmed) else {
            show("That is not a valid address.", kind: .error)
            return false
        }
        guard satoshis >= 1 else {
            show("Enter an amount.", kind: .error)
            return false
        }
        do {
            let built = try await engine.pay(address: trimmed, satoshis: satoshis)
            show("\(Format.sats(satoshis)) sats sent — fee \(Format.sats(built.fee)) sats.")
            await reload()
            return true
        } catch {
            report(error)
            return false
        }
    }

    func sendPayment(satoshis: UInt64, note: String) async {
        guard let activeChannelId else { return }
        let text = note.trimmingCharacters(in: .whitespacesAndNewlines)
        await send(.init(op: .msg,
                         payload: Codecs.encodeText(text),
                         paySats: satoshis),
                   to: activeChannelId)
    }

    func react(to message: ViewMessage, emoji: String) async {
        guard let activeChannelId,
              let ref = Hex.decode(message.record.txid)?.reversedBytes else { return }
        await send(.init(op: .react,
                         payload: Codecs.encodeText(emoji),
                         ref: ref),
                   to: activeChannelId)
    }

    func deleteMessage(_ message: ViewMessage) async {
        guard let activeChannelId,
              let ref = Hex.decode(message.record.txid)?.reversedBytes else { return }
        await send(.init(op: .del,
                         payload: [],
                         ref: ref),
                   to: activeChannelId)
    }

    func beginReply(to message: ViewMessage) {
        replyingTo = message
        editingTxid = nil
    }

    func cancelReply() {
        replyingTo = nil
    }

    /// The five-group fingerprint of this conversation's two keys.
    func keyFingerprint() async -> String? {
        guard let engine, let activeChannelId else { return nil }
        return try? await engine.keyFingerprint(channelId: activeChannelId)
    }

    func beginEditing(_ message: ViewMessage) {
        editingTxid = message.record.txid
        // An edit is not a reply. Leaving this set would keep the reply hint on
        // screen and quietly attach the old `ref` to the next plain message.
        replyingTo = nil
        draft = message.text
    }

    func cancelEditing() {
        editingTxid = nil
        draft = ""
    }

    // MARK: Images

    /// Stages a picked image so its size and quality can be tuned before it
    /// costs anything.
    func stageImage(_ image: UIImage, data: Data) {
        // v1.21 (P0.2/P0.3): terms, then the one-time "image bytes are public and
        // permanent" disclosure, before the image is staged.
        requireTerms { [weak self] in
            guard let self else { return }
            Task { await self.requireDisclosure("media") { self.pendingImage = PendingImage(original: image, originalData: data) } }
        }
    }

    func cancelPendingImage() {
        pendingImage = nil
    }

    /// The bytes that would actually be inscribed with the current choices.
    func renderPendingImage() -> Data? {
        guard let pending = pendingImage else { return nil }
        if pending.keepOriginal { return pending.originalData }
        return Self.encode(pending.original,
                           maxDimension: pending.maxDimension,
                           quality: pending.quality)
    }

    /// Inscribes the staged image and sends a message pointing at it.
    func sendPendingImage() async {
        guard let engine, let activeChannelId, let pending = pendingImage else { return }
        guard let data = renderPendingImage() else {
            show("That image could not be compressed.", kind: .error)
            return
        }
        guard data.count <= Media.maximumBytes else {
            report(Media.Failure.tooLarge(data.count))
            return
        }

        do {
            // Only the reference is encrypted; the picture itself is a public
            // inscription, so do not let the lock icon imply otherwise.
            show(chatIsEncrypted
                 ? "Inscribing — the picture itself is public."
                 : "Inscribing on chain…")

            // Inscribed to the recipient, so the satoshi carrying the image
            // ends up in their wallet rather than ours.
            let ownerHash = try await engine.peerHash(channelId: activeChannelId)
            let published = try await engine.publishMedia(bytes: data,
                                                          mime: pending.keepOriginal
                                                              ? Self.mime(forImageData: data)
                                                              : "image/jpeg",
                                                          ownerHash: ownerHash)
            guard let payload = Codecs.encodeMedia(.init(txid: published.txid,
                                                         vout: published.vout,
                                                         caption: pending.caption)) else { return }
            pendingImage = nil
            await send(.init(op: .media, payload: payload), to: activeChannelId)
            show("Image inscribed as a 1Sat Ordinal — fee \(Format.sats(published.fee)) sats.")
        } catch {
            report(error)
        }
    }

    /// What inscribing `byteCount` bytes would cost. The caller passes the size
    /// it already rendered: re-encoding here would run a full JPEG pass on
    /// every frame of the quality slider.
    func pendingImageFee(byteCount: Int) -> UInt64 {
        guard let engine else { return 0 }
        return engine.inscriptionFeeEstimate(byteCount: byteCount, settings: settings)
    }

    /// The media type of the bytes as they will actually be inscribed. Photos
    /// hands back whatever the library holds — HEIC, PNG or JPEG — so the
    /// "keep original" path has to look rather than assume.
    static func mime(forImageData data: Data) -> String {
        let head = [UInt8](data.prefix(12))
        if head.count >= 3, head[0] == 0xFF, head[1] == 0xD8, head[2] == 0xFF { return "image/jpeg" }
        if head.count >= 8, Array(head[0..<8]) == [0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A] {
            return "image/png"
        }
        if head.count >= 6, Array(head[0..<6]) == Array("GIF89a".utf8)
            || Array(head[0..<6]) == Array("GIF87a".utf8) { return "image/gif" }
        if head.count >= 12, Array(head[0..<4]) == Array("RIFF".utf8),
           Array(head[8..<12]) == Array("WEBP".utf8) { return "image/webp" }
        if head.count >= 12, Array(head[4..<8]) == Array("ftyp".utf8) { return "image/heic" }
        if head.count >= 2, Array(head[0..<2]) == Array("BM".utf8) { return "image/bmp" }
        if head.count >= 4, Array(head[0..<4]) == [0x49, 0x49, 0x2A, 0x00]
            || Array(head[0..<4]) == [0x4D, 0x4D, 0x00, 0x2A] { return "image/tiff" }
        // UIKit decodes more than this list — ICO and some RAW formats among
        // them. Falling through to a non-image type would make `publishMedia`
        // refuse a picture the picker already accepted, so an unknown container
        // is labelled generically rather than rejected.
        return "image/*"
    }

    private func send(_ request: Engine.SendRequest, to channelId: String) async {
        guard let engine else { return }
        do {
            let record = try await engine.send(channelId: channelId, request: request)
            // A failed broadcast does not throw — the engine records it on the
            // row and keeps it in the outbox to retry. A message or a picture
            // shows up in the pinned bar, which is what that bar is for; an
            // edit, a reaction or a deletion never reaches the message list at
            // all, so without this the tap looked like it had worked. Only the
            // second group gets a notice, or a failed message would be reported
            // twice.
            if let failure = record.error, request.op != .msg, request.op != .media {
                show(failure, kind: .error)
            }
            await reload()
        } catch {
            report(error)
            // The reload also clears any optimistic bubble for a message that
            // never made it into the store.
            await reload()
        }
    }

    /// Downscales to `maxDimension` (0 keeps the original size) and encodes as
    /// JPEG at the given quality. Every byte lands on chain, so this is what
    /// the composer lets the user tune.
    static func encode(_ image: UIImage, maxDimension: CGFloat, quality: Double) -> Data? {
        let longest = max(image.size.width, image.size.height)
        let scale = maxDimension > 0 ? min(1, maxDimension / longest) : 1
        guard scale < 1 else {
            return image.jpegData(compressionQuality: quality)
        }

        let size = CGSize(width: (image.size.width * scale).rounded(),
                          height: (image.size.height * scale).rounded())
        let format = UIGraphicsImageRendererFormat.default()
        format.scale = 1
        let renderer = UIGraphicsImageRenderer(size: size, format: format)
        let resized = renderer.image { _ in image.draw(in: CGRect(origin: .zero, size: size)) }
        return resized.jpegData(compressionQuality: quality)
    }

    func loadMedia(for reference: Codecs.MediaRef, txid: String? = nil, sender: String? = nil) async -> UIImage? {
        guard let engine else { return nil }
        // v1.21 (P0.2): a legal block means the bytes are never downloaded.
        if let txid, let sender, await engine.isFetchForbidden(txid: txid, sender: sender) { return nil }
        do {
            guard let stored = try await engine.loadMedia(txid: reference.txid,
                                                          vout: reference.vout,
                                                          mediaLimitMB: settings.mediaLimitMB) else {
                return nil
            }
            return UIImage(data: stored.bytes)
        } catch {
            return nil
        }
    }

    // MARK: Settings and account

    func saveSettings(_ updated: Settings) async {
        guard let store else { return }
        // Caught at save time, in words. App Transport Security silently
        // refuses plain http, and the alternative was an opaque transport
        // error on the next sync with no hint of why.
        if settings.mode == .node {
            for endpoint in [updated.getTxURL, updated.watchURL,
                             updated.broadcastURL, updated.utxoURL] {
                let trimmed = endpoint.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !trimmed.isEmpty else { continue }
                guard let url = URL(string: trimmed), url.scheme?.lowercased() == "https" else {
                    show("Endpoints must start with https:// — iOS blocks plain http (App Transport Security). Not saved.",
                         kind: .error)
                    return
                }
            }
        }
        do {
            var next = updated.normalized()
            next.mode = settings.mode
            settings = next
            try await store.putMeta(key: "settings", value: next)

            // Endpoints and the poll interval live inside the adapter and the
            // polling task, so both have to be rebuilt rather than just
            // stored. The cached account is used first: with the device lock
            // on, a Keychain read here would raise a Face ID prompt for
            // saving a fee setting.
            if let account = currentAccount ?? Keychain.json(StoredAccount.self, for: "account"),
               let mode = next.mode, mode != .demo {
                try await activate(account: account, mode: mode, store: store, fundDemoWallet: false)
            } else {
                await engine?.updateFeePolicy(feePerByte: next.feePerByte, dust: next.dust)
            }
            show("Settings saved.")
        } catch {
            report(error)
        }
    }

    /// A profile record goes to the notes channel, which every chat reads —
    /// so the name becomes visible to everyone you have ever written to.
    var profilePublishWarning: String {
        "This posts your name to all chats and groups. Tap again to publish."
    }

    func publishProfile(name: String, bio: String) async {
        // Stored on this device first, and whatever the broadcast does. What
        // was typed belongs to the person who typed it: a failed send is a
        // reason to try again, not a reason to lose the text.
        await saveMyProfile(name: name, bio: bio)

        guard let engine else { return }
        let trimmedName = name.trimmingCharacters(in: .whitespacesAndNewlines)
        let trimmedBio = bio.trimmingCharacters(in: .whitespacesAndNewlines)
        let profile = Codecs.Profile(name: trimmedName.isEmpty ? nil : trimmedName,
                                     bio: trimmedBio.isEmpty ? nil : trimmedBio)
        let payload = Codecs.encodeProfile(profile)
        do {
            let notes = try await engine.ensureNotesChannel()
            let record = try await engine.send(channelId: notes,
                                               request: .init(op: .profile, payload: payload))
            // A broadcast failure is recorded on the row rather than thrown,
            // and a PROFILE record never reaches the message list — so claiming
            // success here would be a straight lie about something that is
            // still sitting in the outbox.
            if let failure = record.error {
                show("Not published yet: \(failure) It will be retried.", kind: .error)
            } else {
                show("Profile published.")
            }
            await reload()
        } catch {
            report(error)
        }
    }

    func topUpDemo() async {
        guard settings.mode == .demo, let engine else { return }
        do {
            _ = try await engine.demoTopUp(satoshis: 500_000)
            show("500,000 demo sats added.")
            await reload()
        } catch {
            report(error)
        }
    }

    func signOut() async {
        await engine?.stop()
        // The price loop keeps running otherwise, polling a public API from
        // the onboarding screen of a wallet nobody is signed in to.
        stopPriceUpdates()
        price = nil
        priceError = nil
        engine = nil
        currentAccount = nil
        Keychain.remove("account")
        // The store is emptied, not just the key removed. Signing out and
        // importing a *different* phrase on the same phone must not hand the
        // next account the previous one's chats — including cached plaintext
        // of its encrypted sends. The chain keeps everything; signing back in
        // re-walks it, which is exactly what the warning on the button says.
        try? await store?.wipeEverything()
        await Notifier.setBadge(0)
        Notifier.clearDelivered()
        blockedSenders = []
        activeChannelId = nil
        messages = []
        channels = []
        profiles = [:]
        chatPhotos = [:]
        photosProbed = []
        dismissedPins = []
        // Names belong to the address that was just signed out of.
        myNames = NameHoldings()
        opnsRootChecked = false
        opnsRootRejected = nil
        opnsRootRejectionIsFinal = false
        opnsRootLastAttempt = nil
        opnsRootCheck?.cancel()
        opnsRootCheck = nil
        // So does the profile and the picture on it.
        myProfile = StoredProfile(name: nil, bio: nil, time: 0)
        myPhoto = nil
        myPhotoProbed = false
        phrase = nil
        address = ""
        publicKeyHex = ""
        myHash = ""
        balance = 0
        settings.mode = nil
        if let store { try? await store.putMeta(key: "settings", value: settings) }
        phase = .onboarding
    }

    /// Wipes the key and every chat from this device. The chain keeps the
    /// messages; only the recovery phrase brings them back.
    func wipeDevice() async {
        await engine?.stop()
        // Stopped *before* the wipe. A refresh landing a moment later would
        // write the cached rate straight back into the store that was just
        // emptied, which is not what "forget this device" means.
        stopPriceUpdates()
        price = nil
        priceError = nil
        engine = nil
        currentAccount = nil
        Keychain.remove("account")
        try? await store?.wipeEverything()
        await Notifier.setBadge(0)
        Notifier.clearDelivered()

        blockedSenders = []
        channels = []
        messages = []
        profiles = [:]
        chatPhotos = [:]
        photosProbed = []
        dismissedPins = []
        // Names belong to the address that was just signed out of.
        myNames = NameHoldings()
        opnsRootChecked = false
        opnsRootRejected = nil
        opnsRootRejectionIsFinal = false
        opnsRootLastAttempt = nil
        opnsRootCheck?.cancel()
        opnsRootCheck = nil
        myProfile = StoredProfile(name: nil, bio: nil, time: 0)
        myPhoto = nil
        myPhotoProbed = false
        activeChannelId = nil
        phrase = nil
        phraseScheme = nil
        address = ""
        publicKeyHex = ""
        myHash = ""
        balance = 0
        settings = Settings()
        try? await store?.putMeta(key: "settings", value: settings)
        isLocked = false
        phase = .onboarding
    }

    /// Called when the app is backgrounded or returns: keeps the icon badge in
    /// step and raises a notification for anything that came in meanwhile.
    func syncBadge(announceNew: Bool = false) async {
        let unread = totalUnread
        await Notifier.setBadge(unread)
        guard announceNew, unread > 0, settings.notifyOnNewMessages else { return }

        let newest = channels
            .filter { $0.unread > 0 }
            .max { $0.lastTime < $1.lastTime }
        await Notifier.announce(unreadCount: unread,
                                preview: newest.map { displayName(for: $0) })
    }

    func setNotifications(_ enabled: Bool) async {
        if enabled {
            let granted = await Notifier.requestAuthorization()
            guard granted else {
                show("Notifications are turned off for Spiek in iOS Settings.", kind: .error)
                return
            }
        }
        var next = settings
        next.notifyOnNewMessages = enabled
        await saveSettings(next)
        if !enabled { await Notifier.setBadge(0) }
    }

    /// `sensitive` is for secrets — the recovery phrase and the WIF key. Those
    /// go on the pasteboard local-only (never Universal Clipboard to other
    /// devices) and expire after a minute, so a secret does not sit around for
    /// whatever app is pasted into next week.
    func copyToPasteboard(_ text: String, label: String, sensitive: Bool = false) {
        if sensitive {
            UIPasteboard.general.setItems(
                [[UTType.utf8PlainText.identifier: text]],
                options: [.localOnly: true,
                          .expirationDate: Date().addingTimeInterval(60)]
            )
            show("\(label) copied — the clipboard clears itself in a minute.")
        } else {
            UIPasteboard.general.string = text
            show("\(label) copied.")
        }
    }

    // MARK: Helpers

    private func withEngine<T>(_ work: (Engine) async throws -> T) async -> T? {
        guard let engine else { return nil }
        do {
            return try await work(engine)
        } catch {
            report(error)
            return nil
        }
    }
}

// MARK: - Engine callbacks

extension AppModel: EngineDelegate {
    nonisolated func engineDidUpdate() async {
        await MainActor.run {
            self.refreshTask?.cancel()
            self.refreshTask = Task { [weak self] in
                try? await Task.sleep(nanoseconds: 120_000_000)
                guard !Task.isCancelled else { return }
                await self?.reload()
            }
        }
    }
}
