import Foundation
import XCTest
@testable import SpiekCore

/// P0.2 / P0.5 (v1.21): the signed moderation feed against operator-tooling
/// vectors (canonical bytes, signature under the pinned key, every refusal,
/// the three levels) and the wallet-bound storage rules.
final class TrustSafetyTests: XCTestCase {

    private static let root: [String: Any] = {
        guard let url = Bundle.module.url(forResource: "moderation_feed_vectors", withExtension: "json"),
              let data = try? Data(contentsOf: url),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            XCTFail("moderation_feed_vectors.json is missing from the test bundle"); return [:]
        }
        return object
    }()

    private func data(_ key: String, in parent: [String: Any]? = nil) throws -> Data {
        try JSONSerialization.data(withJSONObject: (parent ?? Self.root)[key]!)
    }

    func testFeedCanonicalAndSignature() throws {
        let pinned = Self.root["pinned"] as! [String: Any]
        let keyId = pinned["keyId"] as! String, pubkey = pinned["pubkey"] as! String
        let feed = try XCTUnwrap(Moderation.parse(try data("valid")))
        XCTAssertEqual(Moderation.canonical(feed).hex, Self.root["canonicalHex"] as? String, "canonical form matches the operator tooling")
        XCTAssertEqual(Moderation.keyId(of: pubkey), keyId)
        XCTAssertEqual(Moderation.verify(feed, pinnedKeyId: keyId, pinnedPubkey: pubkey, lastAcceptedSeq: 0), .ok)
        XCTAssertEqual(Moderation.verify(feed, pinnedKeyId: keyId, pinnedPubkey: pubkey, lastAcceptedSeq: 42), .stale)
        XCTAssertEqual(Moderation.verify(feed, pinnedKeyId: "", pinnedPubkey: "", lastAcceptedSeq: 0), .wrongKey, "empty pins fail closed")

        let negatives = Self.root["negatives"] as! [String: Any]
        for (name, expected) in [("tampered", Moderation.Verdict.badSignature), ("expired", .expired), ("older", .stale), ("wrongKey", .wrongKey)] {
            let negative = try XCTUnwrap(Moderation.parse(try data(name, in: negatives)), "\(name) parses")
            XCTAssertEqual(Moderation.verify(negative, pinnedKeyId: keyId, pinnedPubkey: pubkey, lastAcceptedSeq: 42), expected, name)
        }
    }

    func testLevelsAndAcceptance() async throws {
        let pinned = Self.root["pinned"] as! [String: Any]
        let keyId = pinned["keyId"] as! String, pubkey = pinned["pubkey"] as! String
        let feed = try XCTUnwrap(Moderation.parse(try data("valid")))
        XCTAssertEqual(feed.level(txid: String(repeating: "cd", count: 32), sender: nil), .legalBlock)
        XCTAssertEqual(feed.level(txid: nil, sender: String(repeating: "ef", count: 20)), .softHide)
        XCTAssertEqual(feed.level(txid: String(repeating: "ab", count: 32), sender: nil), .policyBlock)
        XCTAssertEqual(feed.level(txid: String(repeating: "cd", count: 32), sender: String(repeating: "ef", count: 20)), .legalBlock, "strictest wins")
        XCTAssertNil(feed.level(txid: String(repeating: "11", count: 32), sender: String(repeating: "22", count: 20)))

        // `XCTAssert*` takes an autoclosure, which cannot contain `await`:
        // every async result is bound first, then asserted.
        let store = try Store(url: nil)
        let accepted = try await Moderation.accept(store, data: try data("valid"), pinnedKeyId: keyId, pinnedPubkey: pubkey)
        XCTAssertEqual(accepted, .ok)
        let negatives = Self.root["negatives"] as! [String: Any]
        let refused = try await Moderation.accept(store, data: try data("tampered", in: negatives), pinnedKeyId: keyId, pinnedPubkey: pubkey)
        XCTAssertEqual(refused, .badSignature)
        let inForce = try await Moderation.accepted(store)?.seq
        XCTAssertEqual(inForce, 42, "the accepted feed stays in force after a refusal")

        let termsBefore = await Moderation.termsAccepted(store)
        XCTAssertFalse(termsBefore)
        try await Moderation.acceptTerms(store)
        let termsAfter = await Moderation.termsAccepted(store)
        XCTAssertTrue(termsAfter)
        let disclosedBefore = await Moderation.disclosed(store, topic: "media")
        XCTAssertFalse(disclosedBefore)
        try await Moderation.markDisclosed(store, topic: "media")
        let disclosedAfter = await Moderation.disclosed(store, topic: "media")
        XCTAssertTrue(disclosedAfter)
    }

    func testStoreOwnershipRules() async throws {
        let alice = try RecoveryPhrase.legacyKey(forPhrase: String(repeating: "alpha ", count: 11) + "one")
        let bob = try RecoveryPhrase.legacyKey(forPhrase: String(repeating: "beta ", count: 11) + "two")
        let aliceFp = StoreOwnership.fingerprint(compressedPublicKey: alice.publicKey.compressedBytes)
        let bobFp = StoreOwnership.fingerprint(compressedPublicKey: bob.publicKey.compressedBytes)
        let aliceHash = alice.publicKey.hash160.hex, bobHash = bob.publicKey.hash160.hex
        XCTAssertNotEqual(aliceFp, bobFp)
        XCTAssertNotEqual(aliceFp, Hash.sha256(alice.publicKey.compressedBytes).hex, "domain-separated")

        // empty → adopted; then bob → mismatch, owner untouched
        let empty = try Store(url: nil)
        let first = try await StoreOwnership.verify(store: empty, fingerprint: aliceFp, ownHash: aliceHash)
        XCTAssertEqual(first, .adoptedEmpty)
        let again = try await StoreOwnership.verify(store: empty, fingerprint: aliceFp, ownHash: aliceHash)
        XCTAssertEqual(again, .match)
        let intruder = try await StoreOwnership.verify(store: empty, fingerprint: bobFp, ownHash: bobHash)
        XCTAssertEqual(intruder, .mismatch)
        let recordedOwner = try await empty.meta(String.self, key: StoreOwnership.metaKey)
        XCTAssertEqual(recordedOwner, aliceFp)

        // legacy with alice's notes channel → adopted with proof; bob's → mismatch, nothing written
        let legacy = try Store(url: nil)
        try await legacy.putChannel(ChannelRecord(channelId: aliceHash, kind: .note, name: "Notes"))
        let adopted = try await StoreOwnership.verify(store: legacy, fingerprint: aliceFp, ownHash: aliceHash)
        XCTAssertEqual(adopted, .adoptedVerified)
        let foreign = try Store(url: nil)
        try await foreign.putChannel(ChannelRecord(channelId: bobHash, kind: .note, name: "Notes"))
        let refused = try await StoreOwnership.verify(store: foreign, fingerprint: aliceFp, ownHash: aliceHash)
        XCTAssertEqual(refused, .mismatch)
        let untouched = try await foreign.meta(String.self, key: StoreOwnership.metaKey)
        XCTAssertNil(untouched)
    }

    func testQuarantineNamesAreOpaqueAndJournaled() {
        let folder = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("spiek-q-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let live = folder.appendingPathComponent("spiek.sqlite")
        try? Data([1]).write(to: live)
        try? Data([2]).write(to: URL(fileURLWithPath: live.path + "-wal"))
        let defaults = UserDefaults(suiteName: "spiek-tests-\(UUID().uuidString)")!
        let id = StoreQuarantine.quarantine(liveDatabase: live, defaults: defaults)
        XCTAssertEqual(id.count, 32, "128-bit random id")
        XCTAssertFalse(FileManager.default.fileExists(atPath: live.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: folder.appendingPathComponent("spiek-orphan-\(id).sqlite").path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: folder.appendingPathComponent("spiek-orphan-\(id).sqlite-wal").path))
        XCTAssertEqual(StoreQuarantine.orphans(defaults: defaults).map(\.state), ["done"])
        StoreQuarantine.delete(id: id, liveDatabase: live, defaults: defaults)
        XCTAssertTrue(StoreQuarantine.orphans(defaults: defaults).isEmpty)
        XCTAssertFalse(FileManager.default.fileExists(atPath: folder.appendingPathComponent("spiek-orphan-\(id).sqlite").path))
    }
}
