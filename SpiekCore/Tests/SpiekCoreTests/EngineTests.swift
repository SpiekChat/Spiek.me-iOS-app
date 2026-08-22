import XCTest
@testable import SpiekCore

final class StoreTests: XCTestCase {
    func testMessagesAreOrderedAndPaged() async throws {
        let store = try Store(url: nil)
        for index in 0..<10 {
            let record = MessageRecord(txid: String(format: "%064x", index),
                                       channel: "aa", sender: "bb", senderPub: "cc",
                                       senderAddress: "1x", kind: .dm, op: .msg,
                                       time: 100 + index,
                                       sort: Double(index),
                                       status: .sent, mine: false)
            try await store.putMessage(record)
        }

        let page = try await store.messages(channel: "aa", limit: 4)
        XCTAssertEqual(page.count, 4)
        XCTAssertEqual(page.map(\.sort), [6, 7, 8, 9], "newest page, oldest first")

        let older = try await store.messages(channel: "aa", limit: 4, before: 6)
        XCTAssertEqual(older.map(\.sort), [2, 3, 4, 5])
    }

    func testChannelDeletionRemovesEverything() async throws {
        let store = try Store(url: nil)
        try await store.putChannel(ChannelRecord(channelId: "aa", kind: .dm))
        try await store.putMessage(MessageRecord(txid: "01", channel: "aa", sender: "bb",
                                                 senderPub: "cc", senderAddress: "1x",
                                                 kind: .dm, op: .msg, time: 1, sort: 1,
                                                 status: .sent, mine: false))
        try await store.putChain(ChainRecord(key: "aa|bb", oldestTxid: "01", oldestPrev: nil, oldestSort: 1))
        try await store.putMeta(key: "seq:aa", value: 42)

        try await store.deleteChannel("aa")

        // Hoisted rather than inlined: XCTAssert takes an autoclosure, and an
        // autoclosure cannot be async — `await` inside one does not compile.
        let deletedChannel = try await store.channel("aa")
        XCTAssertNil(deletedChannel)
        let remainingMessages = try await store.messages(channel: "aa")
        XCTAssertTrue(remainingMessages.isEmpty)
        let remainingChains = try await store.chains(forChannel: "aa")
        XCTAssertTrue(remainingChains.isEmpty)
        let cursor: Int? = try await store.meta(Int.self, key: "seq:aa")
        XCTAssertNil(cursor)
    }

    func testMediaCacheEvictsLeastRecentlyUsed() async throws {
        let store = try Store(url: nil)
        try await store.putMedia(outpoint: "a:0", bytes: Data(count: 600), mime: "image/png", lastUsed: 1)
        try await store.putMedia(outpoint: "b:0", bytes: Data(count: 600), mime: "image/png", lastUsed: 2)
        try await store.trimMedia(toBytes: 700)

        let evicted = try await store.media(outpoint: "a:0")
        XCTAssertNil(evicted, "oldest blob is evicted first")
        let kept = try await store.media(outpoint: "b:0")
        XCTAssertNotNil(kept)
    }
}

final class EngineTests: XCTestCase {
    /// Two wallets sharing one in-memory chain, as the demo playground does.
    private func makePair() async throws -> (alice: Engine, bob: Engine, chain: MockAdapter) {
        let chain = MockAdapter()

        let aliceKey = try PrivateKey.random()
        let bobKey = try PrivateKey.random()

        let alice = Engine(wallet: Wallet(key: aliceKey), adapter: chain, store: try Store(url: nil))
        let bob = Engine(wallet: Wallet(key: bobKey), adapter: chain, store: try Store(url: nil))

        for engine in [alice, bob] {
            _ = try await engine.demoTopUp(satoshis: 1_000_000)
            _ = try await engine.ensureNotesChannel()
        }
        return (alice, bob, chain)
    }

    func testNotesToSelfRoundTrip() async throws {
        let (alice, _, _) = try await makePair()
        let notes = try await alice.ensureNotesChannel()

        let sent = try await alice.send(channelId: notes,
                                        request: .init(op: .msg, payload: Codecs.encodeText("first note")))

        // A private note must not sit on a public chain in the clear.
        XCTAssertEqual(sent.op, .emsg, "notes-to-self must be encrypted")
        XCTAssertFalse(sent.payload.contains(Codecs.encodeText("first note").hex),
                       "the plaintext must not appear in the on-chain payload")

        let view = try await alice.viewChannel(notes)
        XCTAssertEqual(view.count, 1)
        XCTAssertEqual(view[0].text, "first note")
        XCTAssertTrue(view[0].record.mine)
        XCTAssertTrue(view[0].encrypted)
        XCTAssertFalse(view[0].unreadable)
    }

    /// The cached plaintext is a local convenience. What matters is that the
    /// self-ECDH still opens the record without it — the situation on a phone
    /// restored from the recovery phrase.
    func testNotesStayReadableWithoutTheDecryptedCache() async throws {
        let (alice, _, _) = try await makePair()
        let notes = try await alice.ensureNotesChannel()
        let sent = try await alice.send(channelId: notes,
                                        request: .init(op: .msg, payload: Codecs.encodeText("private")))

        let fetched = try await alice.store.message(txid: sent.txid)
        var stripped = try XCTUnwrap(fetched)
        stripped.decrypted = nil
        stripped.decryptedOp = nil
        stripped.decryptedRef = nil
        try await alice.store.putMessage(stripped)

        let view = try await alice.viewChannel(notes)
        let last = try XCTUnwrap(view.last)
        XCTAssertEqual(last.text, "private")
        XCTAssertFalse(last.unreadable)
    }

    /// The chain walker recreates a deleted channel with no key attached.
    /// `ensureNotesChannel` has to repair that row, or the notes already on
    /// chain turn unreadable and new ones drop to plaintext.
    func testNotesChannelIsRepairedWhenItLostItsKey() async throws {
        let (alice, _, _) = try await makePair()
        let notes = try await alice.ensureNotesChannel()

        let beforeBreak = try await alice.store.channel(notes)
        var broken = try XCTUnwrap(beforeBreak)
        broken.peerPub = nil
        broken.peerHash = nil
        try await alice.store.putChannel(broken)

        _ = try await alice.ensureNotesChannel()

        let afterRepair = try await alice.store.channel(notes)
        let repaired = try XCTUnwrap(afterRepair)
        XCTAssertEqual(repaired.kind, .note)
        XCTAssertEqual(repaired.peerPub, alice.publicKeyHex)
        XCTAssertEqual(repaired.peerHash, notes)

        let sent = try await alice.send(channelId: notes,
                                        request: .init(op: .msg, payload: Codecs.encodeText("after repair")))
        XCTAssertEqual(sent.op, .emsg)
    }

    /// Turning the lock off is allowed for notes as well, and must persist.
    func testNotesCanBeSwitchedToPlaintext() async throws {
        let (alice, _, _) = try await makePair()
        let notes = try await alice.ensureNotesChannel()

        _ = try await alice.setPlain(true, channelId: notes)
        let fetchedNotes = try await alice.store.channel(notes)
        let stored = try XCTUnwrap(fetchedNotes)
        XCTAssertTrue(stored.plain)
        XCTAssertFalse(Engine.encryptsByDefault(stored))

        let sent = try await alice.send(channelId: notes,
                                        request: .init(op: .msg, payload: Codecs.encodeText("in the open")))
        XCTAssertEqual(sent.op, .msg)
    }

    /// A safety number needs two parties. Notes have only one.
    func testFingerprintIsRefusedForNotes() async throws {
        let (alice, _, _) = try await makePair()
        let notes = try await alice.ensureNotesChannel()
        let fingerprint = try await alice.keyFingerprint(channelId: notes)
        XCTAssertNil(fingerprint)
    }

    func testMessageReachesTheOtherSide() async throws {
        let (alice, bob, chain) = try await makePair()

        let channelId = try await alice.openChat(peerAddressOrHash: bob.address, name: "Bob")
        _ = try await alice.send(channelId: channelId,
                                 request: .init(op: .msg, payload: Codecs.encodeText("hello Bob")))
        await chain.mineBlock()

        // Bob learns about the chat because Alice paid his address.
        _ = try await bob.pollOnce()

        let bobChannels = try await bob.store.allChannels()
        XCTAssertTrue(bobChannels.contains { $0.channelId == channelId },
                      "Bob should have discovered the channel")

        let bobView = try await bob.viewChannel(channelId)
        XCTAssertEqual(bobView.map(\.text), ["hello Bob"])
        XCTAssertFalse(bobView[0].record.mine)
        XCTAssertTrue(bobView[0].record.payIn > 0, "the message carried a dust payment")
    }

    func testEncryptedMessageOnlyOpensForTheRecipient() async throws {
        let (alice, bob, chain) = try await makePair()

        let channelId = try await alice.openChat(peerAddressOrHash: bob.address, name: "Bob")
        await chain.mineBlock()
        _ = try await bob.pollOnce()

        // Bob replies so Alice learns his public key.
        _ = try await bob.send(channelId: channelId,
                               request: .init(op: .msg, payload: Codecs.encodeText("hi")))
        await chain.mineBlock()
        _ = try await alice.pollOnce()

        _ = try await alice.send(channelId: channelId,
                                 request: .init(op: .msg,
                                                payload: Codecs.encodeText("this stays between us"),
                                                encrypt: true))
        await chain.mineBlock()
        _ = try await bob.pollOnce()

        let bobView = try await bob.viewChannel(channelId)
        let secret = try XCTUnwrap(bobView.last)
        XCTAssertEqual(secret.text, "this stays between us")
        XCTAssertTrue(secret.encrypted)
        XCTAssertFalse(secret.unreadable)

        // The record on chain must not contain the plaintext.
        let fetchedRecord = try await bob.store.message(txid: secret.record.txid)
        let stored = try XCTUnwrap(fetchedRecord)
        XCTAssertEqual(stored.op, .emsg)
        XCTAssertFalse(stored.payload.contains(Codecs.encodeText("this stays between us").hex))
    }

    /// A direct message encrypts on its own once the peer's key has arrived —
    /// the lock is an opt-out, not an opt-in.
    func testDirectMessagesEncryptByDefaultOnceTheKeyIsKnown() async throws {
        let (alice, bob, chain) = try await makePair()

        let channelId = try await alice.openChat(peerAddressOrHash: bob.address)
        await chain.mineBlock()
        _ = try await bob.pollOnce()

        // Before Bob has spoken, Alice has no key for him, so this goes plain.
        let early = try await alice.send(channelId: channelId,
                                         request: .init(op: .msg, payload: Codecs.encodeText("plain")))
        XCTAssertEqual(early.op, .msg)

        _ = try await bob.send(channelId: channelId,
                               request: .init(op: .msg, payload: Codecs.encodeText("hi")))
        await chain.mineBlock()
        _ = try await alice.pollOnce()

        let later = try await alice.send(channelId: channelId,
                                         request: .init(op: .msg, payload: Codecs.encodeText("automatic")))
        XCTAssertEqual(later.op, .emsg, "with the key known, encryption is the default")

        // Turning the lock off puts the chat back on plaintext.
        _ = try await alice.setPlain(true, channelId: channelId)
        let plain = try await alice.send(channelId: channelId,
                                         request: .init(op: .msg, payload: Codecs.encodeText("visible again")))
        XCTAssertEqual(plain.op, .msg)

        let fetchedChannel = try await alice.store.channel(channelId)
        let channel = try XCTUnwrap(fetchedChannel)
        XCTAssertTrue(channel.plain)
        XCTAssertFalse(Engine.encryptsByDefault(channel))
    }

    func testEncryptionRefusesBeforeThePeerIsKnown() async throws {
        let (alice, bob, _) = try await makePair()
        let channelId = try await alice.openChat(peerAddressOrHash: bob.address)

        do {
            _ = try await alice.send(channelId: channelId,
                                     request: .init(op: .msg,
                                                    payload: Codecs.encodeText("too early"),
                                                    encrypt: true))
            XCTFail("expected the send to be refused")
        } catch let error as Engine.EngineError {
            XCTAssertEqual(error, .peerKeyUnknown)
        }
    }

    func testEditDeleteAndReactionsAreApplied() async throws {
        let (alice, _, _) = try await makePair()
        let notes = try await alice.ensureNotesChannel()

        let original = try await alice.send(channelId: notes,
                                            request: .init(op: .msg, payload: Codecs.encodeText("typo heer")))
        let ref = try XCTUnwrap(Hex.decode(original.txid)?.reversedBytes)

        _ = try await alice.send(channelId: notes,
                                 request: .init(op: .edit, payload: Codecs.encodeText("typo here"), ref: ref))
        _ = try await alice.send(channelId: notes,
                                 request: .init(op: .react, payload: Codecs.encodeText("👍"), ref: ref))

        let view = try await alice.viewChannel(notes)
        let message = try XCTUnwrap(view.first { $0.record.txid == original.txid })
        XCTAssertEqual(message.text, "typo here")
        XCTAssertEqual(message.reactions.map(\.emoji), ["👍"])
        XCTAssertFalse(message.deleted)

        _ = try await alice.send(channelId: notes,
                                 request: .init(op: .del, payload: [], ref: ref))
        let afterDelete = try await alice.viewChannel(notes)
        XCTAssertTrue(try XCTUnwrap(afterDelete.first { $0.record.txid == original.txid }).deleted)
    }

    /// Concurrent sends must not fork the chain: every message has to point at
    /// the one before it, with no duplicate `prev` values.
    func testConcurrentSendsStayOnOneChain() async throws {
        let (alice, _, _) = try await makePair()
        let notes = try await alice.ensureNotesChannel()

        try await withThrowingTaskGroup(of: MessageRecord.self) { group in
            for index in 1...5 {
                group.addTask {
                    try await alice.send(channelId: notes,
                                         request: .init(op: .msg,
                                                        payload: Codecs.encodeText("concurrent \(index)")))
                }
            }
            var sent = [MessageRecord]()
            for try await record in group { sent.append(record) }

            let previous = sent.compactMap(\.prev)
            XCTAssertEqual(previous.count, 4, "only the very first message has no predecessor")
            XCTAssertEqual(Set(previous).count, 4, "no two messages may claim the same prev")
        }

        let view = try await alice.viewChannel(notes)
        XCTAssertEqual(view.count, 5)
    }

    func testMessagesChainThroughPrev() async throws {
        let (alice, _, _) = try await makePair()
        let notes = try await alice.ensureNotesChannel()

        let first = try await alice.send(channelId: notes, request: .init(op: .msg, payload: Codecs.encodeText("one")))
        let second = try await alice.send(channelId: notes, request: .init(op: .msg, payload: Codecs.encodeText("two")))

        XCTAssertNil(first.prev, "the first message in a channel has no predecessor")
        XCTAssertEqual(second.prev, first.txid, "each message points back at the previous one")
    }

    func testPaymentRidesAlongWithAMessage() async throws {
        let (alice, bob, chain) = try await makePair()
        let channelId = try await alice.openChat(peerAddressOrHash: bob.address)
        await chain.mineBlock()
        _ = try await bob.pollOnce()

        let balanceBefore = await bob.balance()
        _ = try await alice.send(channelId: channelId,
                                 request: .init(op: .msg,
                                                payload: Codecs.encodeText("here is 5000"),
                                                paySats: 5000))
        await chain.mineBlock()
        _ = try await bob.pollOnce()

        let balanceAfter = await bob.balance()
        XCTAssertEqual(balanceAfter - balanceBefore, 5001, "5000 sats plus the dust output")

        let view = try await bob.viewChannel(channelId)
        XCTAssertEqual(view.last?.record.payIn, 5001)
    }

    func testPaymentsAreRefusedInGroups() async throws {
        let (alice, _, _) = try await makePair()
        let groupId = try await alice.openChat(name: "Team", kind: .group)

        do {
            _ = try await alice.send(channelId: groupId,
                                     request: .init(op: .msg, payload: Codecs.encodeText("hi"), paySats: 100))
            XCTFail("expected the payment to be refused")
        } catch let error as Engine.EngineError {
            XCTAssertEqual(error, .paymentsOnlyInDM)
        }
    }

    func testUnreadCountAndMarkRead() async throws {
        let (alice, bob, chain) = try await makePair()
        let channelId = try await alice.openChat(peerAddressOrHash: bob.address)
        _ = try await alice.send(channelId: channelId, request: .init(op: .msg, payload: Codecs.encodeText("one")))
        _ = try await alice.send(channelId: channelId, request: .init(op: .msg, payload: Codecs.encodeText("two")))
        await chain.mineBlock()
        _ = try await bob.pollOnce()

        var fetchedChannel = try await bob.store.channel(channelId)
        var channel = try XCTUnwrap(fetchedChannel)
        XCTAssertEqual(channel.unread, 2)

        try await bob.markRead(channelId: channelId)
        fetchedChannel = try await bob.store.channel(channelId)
        channel = try XCTUnwrap(fetchedChannel)
        XCTAssertEqual(channel.unread, 0)
    }

    func testMediaRoundTripsThroughTheChain() async throws {
        let (alice, bob, chain) = try await makePair()
        let channelId = try await alice.openChat(peerAddressOrHash: bob.address)

        let picture = Data((0..<512).map { UInt8($0 % 251) })
        // Inscribed to Bob, so the satoshi carrying the image is his.
        let ownerHash = try await alice.peerHash(channelId: channelId)
        let published = try await alice.publishMedia(bytes: picture, mime: "image/png", ownerHash: ownerHash)

        let payload = try XCTUnwrap(Codecs.encodeMedia(
            .init(txid: published.txid, vout: published.vout, caption: "snapshot")))
        _ = try await alice.send(channelId: channelId, request: .init(op: .media, payload: payload))
        await chain.mineBlock()
        _ = try await bob.pollOnce()

        let view = try await bob.viewChannel(channelId)
        let mediaMessage = try XCTUnwrap(view.last)
        let ref = try XCTUnwrap(mediaMessage.mediaRef)
        XCTAssertEqual(ref.caption, "snapshot")

        let fetchedMedia = try await bob.loadMedia(txid: ref.txid, vout: ref.vout, mediaLimitMB: 200)
        let loaded = try XCTUnwrap(fetchedMedia)
        XCTAssertEqual(loaded.bytes, picture)
        XCTAssertEqual(loaded.mime, "image/png")
    }

    func testImagesAreRefusedWhenTooLargeOrNotImages() async throws {
        let (alice, _, _) = try await makePair()
        do {
            _ = try await alice.publishMedia(bytes: Data([1, 2, 3]), mime: "application/pdf")
            XCTFail("expected a non-image to be refused")
        } catch let error as Media.Failure {
            guard case .notAnImage = error else { return XCTFail("wrong failure: \(error)") }
        }

        do {
            _ = try await alice.publishMedia(bytes: Data(count: Media.maximumBytes + 1), mime: "image/jpeg")
            XCTFail("expected an oversized image to be refused")
        } catch let error as Media.Failure {
            guard case .tooLarge = error else { return XCTFail("wrong failure: \(error)") }
        }
    }

    func testReplyCarriesAQuoteOfTheOriginal() async throws {
        let (alice, _, _) = try await makePair()
        let notes = try await alice.ensureNotesChannel()

        let original = try await alice.send(channelId: notes,
                                            request: .init(op: .msg, payload: Codecs.encodeText("the question")))
        let ref = try XCTUnwrap(Hex.decode(original.txid)?.reversedBytes)

        // A reply is an ordinary message that carries a ref.
        _ = try await alice.send(channelId: notes,
                                 request: .init(op: .msg,
                                                payload: Codecs.encodeText("the answer"),
                                                ref: ref))

        let view = try await alice.viewChannel(notes)
        XCTAssertEqual(view.count, 2, "a reply is a message in its own right")
        let reply = try XCTUnwrap(view.last)
        XCTAssertEqual(reply.text, "the answer")
        let quote = try XCTUnwrap(reply.replyTo)
        XCTAssertEqual(quote.txid, original.txid)
        XCTAssertEqual(quote.preview, "the question")
        XCTAssertFalse(quote.isMissing)
        XCTAssertTrue(quote.mine)

        XCTAssertNil(view.first?.replyTo, "the original is not a reply")
    }

    func testReplyToAMessageWeDoNotHaveShowsAPlaceholder() async throws {
        let (alice, _, _) = try await makePair()
        let notes = try await alice.ensureNotesChannel()

        let absent = [UInt8](repeating: 0x5a, count: 32)
        _ = try await alice.send(channelId: notes,
                                 request: .init(op: .msg,
                                                payload: Codecs.encodeText("replying into the void"),
                                                ref: absent))

        let view = try await alice.viewChannel(notes)
        let quote = try XCTUnwrap(view.last?.replyTo)
        XCTAssertTrue(quote.isMissing)
        XCTAssertEqual(quote.preview, "earlier message")
    }

    func testWalkBackRecoversHistoryForALateJoiner() async throws {
        let (alice, bob, chain) = try await makePair()
        let channelId = try await alice.openChat(name: "Team", kind: .group)

        for index in 1...5 {
            _ = try await alice.send(channelId: channelId,
                                     request: .init(op: .msg, payload: Codecs.encodeText("message \(index)")))
        }
        await chain.mineBlock()

        // Bob joins with only the invite code and has to walk the chain back.
        _ = try await bob.openChat(name: "Team", kind: .group, channelId: channelId)
        _ = try await bob.pollOnce()

        let view = try await bob.viewChannel(channelId)
        XCTAssertEqual(view.map(\.text), (1...5).map { "message \($0)" })
    }

    // MARK: Peer hijack

    /// Channel ids travel in the clear inside every record, so anyone watching
    /// the chain can post an `open` into someone else's conversation. Once a
    /// chat has a peer, that has to be the peer — otherwise one transaction is
    /// enough to make this device encrypt everything afterwards to a stranger.
    func testAStrangerCannotTakeOverAnEstablishedChat() async throws {
        let (alice, bob, chain) = try await makePair()
        let mallory = Engine(wallet: Wallet(key: try PrivateKey.random()),
                             adapter: chain,
                             store: try Store(url: nil))
        _ = try await mallory.demoTopUp(satoshis: 1_000_000)

        let channelId = try await alice.openChat(peerAddressOrHash: bob.address, name: "Bob")
        await chain.mineBlock()
        _ = try await bob.pollOnce()
        // Bob answers, so Alice pins his key.
        _ = try await bob.send(channelId: channelId,
                               request: .init(op: .msg, payload: Codecs.encodeText("hi")))
        await chain.mineBlock()
        _ = try await alice.pollOnce()

        let stored = try await alice.store.channel(channelId)
        let pinned = try XCTUnwrap(stored)
        XCTAssertEqual(pinned.peerPub, bob.publicKeyHex, "Bob's key should be pinned")

        // Mallory announces her own key on the same channel, and pays Alice a
        // dust output so the record lands in Alice's own address watch. That
        // detail matters: once a DM has a peer, `watchedAddresses` stops
        // following the channel address, so paying the victim directly is what
        // makes the attack reach them at all.
        _ = try await mallory.openChat(peerAddressOrHash: alice.address,
                                       kind: .dm,
                                       channelId: channelId)
        await chain.mineBlock()
        _ = try await alice.pollOnce()

        let storedAfter = try await alice.store.channel(channelId)
        let after = try XCTUnwrap(storedAfter)
        XCTAssertEqual(after.peerPub, bob.publicKeyHex,
                       "an open from a stranger must not replace the pinned key")
        XCTAssertEqual(after.peerHash, bob.hashHex)
        XCTAssertNotNil(after.peerKeyConflict, "the refusal must be visible, not silent")
    }

    /// Nothing binds an OP_RETURN payload to its sender, so the announced key
    /// is only worth anything when it is the key that signed the record.
    func testAnAnnouncedKeyThatIsNotTheSendersIsRefused() async throws {
        let (alice, bob, chain) = try await makePair()
        let mallory = Engine(wallet: Wallet(key: try PrivateKey.random()),
                             adapter: chain,
                             store: try Store(url: nil))
        _ = try await mallory.demoTopUp(satoshis: 1_000_000)

        // A fresh chat with no peer yet — the easiest case to hijack.
        let channelId = try await alice.openChat(name: "someone")
        // A local row so Mallory can compose into that channel at all. Not via
        // `openChat`, which would announce her own key first and change what
        // this test is about.
        try await mallory.store.putChannel(ChannelRecord(channelId: channelId, kind: .dm))
        // Mallory writes an `open` carrying *Bob's* key rather than her own.
        let bobsKey = try XCTUnwrap(Hex.decode(bob.publicKeyHex))
        _ = try await mallory.send(channelId: channelId,
                                   request: .init(op: .open, payload: bobsKey))
        await chain.mineBlock()
        _ = try await alice.pollOnce()

        let stored = try await alice.store.channel(channelId)
        let channel = try XCTUnwrap(stored)
        // Neither Bob's key — which Mallory does not hold — nor Mallory's own:
        // announcing a forged key must not be a cheaper way of winning the
        // channel than saying nothing.
        XCTAssertNil(channel.peerPub,
                     "a key nobody proved they hold must never be adopted, and lying must not pay")
        XCTAssertNotNil(channel.peerKeyConflict)
    }

    // MARK: Reactions

    /// Every reaction is its own transaction and nothing on chain marks one as
    /// a repeat, so the same person tapping the same emoji twice used to stack
    /// it endlessly.
    func testTheSameReactionFromTheSamePersonCountsOnce() async throws {
        let (alice, _, chain) = try await makePair()
        let notes = try await alice.ensureNotesChannel()

        let target = try await alice.send(channelId: notes,
                                          request: .init(op: .msg,
                                                         payload: Codecs.encodeText("react to me")))
        let ref = try XCTUnwrap(Hex.decode(target.txid)?.reversedBytes)
        for _ in 0..<3 {
            _ = try await alice.send(channelId: notes,
                                     request: .init(op: .react,
                                                    payload: Codecs.encodeText("\u{1F44D}"),
                                                    ref: ref))
        }
        await chain.mineBlock()
        _ = try await alice.pollOnce()

        let view = try await alice.viewChannel(notes)
        let reacted = try XCTUnwrap(view.first { $0.record.txid == target.txid })
        XCTAssertEqual(reacted.reactions.count, 1, "one person, one emoji, one reaction")
    }
}
