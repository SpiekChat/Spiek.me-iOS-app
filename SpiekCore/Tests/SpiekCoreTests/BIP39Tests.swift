import XCTest
@testable import SpiekCore

/// Reference values generated from the spiek_13 JavaScript, plus the official
/// BIP-39 test vector, so a phrase written down in the browser opens the same
/// account here.
enum Vectors13 {
    static let root: [String: Any] = {
        guard let url = Bundle.module.url(forResource: "vectors13", withExtension: "json"),
              let data = try? Data(contentsOf: url),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            XCTFail("vectors13.json is missing from the test bundle")
            return [:]
        }
        return object
    }()

    static func list(_ key: String) -> [[String: Any]] {
        root[key] as? [[String: Any]] ?? []
    }
}

final class BIP39Tests: XCTestCase {
    func testSeedMatchesTheOfficialVector() {
        // BIP-39 English test vector #1, empty passphrase.
        let mnemonic = "abandon abandon abandon abandon abandon abandon abandon abandon abandon abandon abandon about"
        let expected = "5eb00bbddcf069084889a8ab9155568165f5c453ccb85e70811aaed6f6da5fc1"
            + "9a5ac40b389cd370d086206dec8aa6c43daea6690f20ad3d8d48b2d2ce9e38e4"
        XCTAssertEqual(BIP39.seed(from: mnemonic).hex, expected)
    }

    func testSeedsAndKeysMatchReference() throws {
        for vector in Vectors13.list("bip39") {
            let mnemonic = vector.string("mnemonic")
            XCTAssertEqual(BIP39.isValid(mnemonic), vector.bool("valid"), mnemonic)
            XCTAssertEqual(BIP39.seed(from: mnemonic).hex, vector.string("seed"), "seed for \(mnemonic)")

            let key = try BIP39.privateKey(from: mnemonic)
            XCTAssertEqual(key.hex, vector.string("privHex"), "key for \(mnemonic)")
            XCTAssertEqual(key.wif, vector.string("wif"))
            XCTAssertEqual(key.address, vector.string("address"))
        }
    }

    func testChecksumRejectsBadPhrases() {
        for vector in Vectors13.list("bip39Invalid") {
            XCTAssertFalse(BIP39.isValid(vector.string("mnemonic")),
                           "should fail the checksum: \(vector.string("mnemonic"))")
        }
    }

    func testDerivationPathIsBSV() {
        // m/44'/236'/0'/0/0 — 236 is BSV's registered coin type.
        XCTAssertEqual(BIP39.derivationPath,
                       [0x8000_002C, 0x8000_00EC, 0x8000_0000, 0, 0])
    }

    func testGeneratedPhrasesAlwaysValidate() throws {
        for _ in 0..<25 {
            let phrase = BIP39.generate()
            XCTAssertEqual(BIP39.words(in: phrase).count, 12)
            XCTAssertTrue(BIP39.isValid(phrase), "generated phrase failed its own checksum: \(phrase)")
            XCTAssertNoThrow(try BIP39.privateKey(from: phrase))
        }
        // Reference-generated phrases must validate here too.
        for vector in Vectors13.list("generated") {
            XCTAssertTrue(BIP39.isValid(vector.string("mnemonic")))
        }
    }

    func testEntropyRoundTrip() throws {
        let entropy = [UInt8](repeating: 0, count: 16)
        let phrase = try XCTUnwrap(BIP39.phrase(fromEntropy: entropy))
        XCTAssertEqual(phrase,
                       "abandon abandon abandon abandon abandon abandon abandon abandon abandon abandon abandon about")
        XCTAssertNil(BIP39.phrase(fromEntropy: [1, 2, 3]))
    }

    func testPBKDF2MultiBlockOutput() {
        // Two blocks of SHA-512 output exercises the block counter.
        let long = PBKDF2.deriveSHA512(password: Array("password".utf8),
                                       salt: Array("salt".utf8),
                                       iterations: 2,
                                       keyLength: 128)
        XCTAssertEqual(long.count, 128)
        let short = PBKDF2.deriveSHA512(password: Array("password".utf8),
                                        salt: Array("salt".utf8),
                                        iterations: 2,
                                        keyLength: 64)
        XCTAssertEqual(Array(long.prefix(64)), short, "the first block must not depend on the requested length")
    }
}

final class RecoveryPhraseTests: XCTestCase {
    func testRestoreMatchesReference() throws {
        for vector in Vectors13.list("restore") {
            let restored = try RecoveryPhrase.restore(vector.string("input"),
                                                      forceLegacy: vector.bool("forceLegacy"))
            XCTAssertEqual(restored.scheme?.rawValue, vector.optionalString("ptype"),
                           "scheme for \(vector.string("input"))")
            XCTAssertEqual(restored.key.hex, vector.string("privHex"))
            XCTAssertEqual(restored.key.address, vector.string("address"))
        }
    }

    func testLegacyPhrasesStillOpenTheSameAccount() throws {
        // Phrases from before BIP-39 support have no valid checksum, so they
        // must fall back rather than fail.
        for vector in Vectors.list("phraseKeys") {
            let phrase = vector.string("phrase")
            guard !BIP39.isValid(phrase) else { continue }
            let restored = try RecoveryPhrase.restore(phrase)
            XCTAssertEqual(restored.scheme, .legacy)
            XCTAssertTrue(restored.fellBackToLegacy)
            XCTAssertEqual(restored.key.hex, vector.string("privHex"),
                           "legacy account must still open: \(phrase)")
        }
    }

    func testForcingLegacyOnAValidBIP39Phrase() throws {
        let mnemonic = "abandon abandon abandon abandon abandon abandon abandon abandon abandon abandon abandon about"
        let asBIP39 = try RecoveryPhrase.restore(mnemonic)
        let asLegacy = try RecoveryPhrase.restore(mnemonic, forceLegacy: true)
        XCTAssertEqual(asBIP39.scheme, .bip39)
        XCTAssertEqual(asLegacy.scheme, .legacy)
        XCTAssertNotEqual(asBIP39.key.hex, asLegacy.key.hex,
                          "the two schemes must produce different keys")
        XCTAssertFalse(asLegacy.fellBackToLegacy, "forced, not fallen back")
    }

    func testWIFStillAccepted() throws {
        let wif = Vectors.list("wifs")[0].string("wif")
        let restored = try RecoveryPhrase.restore(wif)
        XCTAssertNil(restored.phrase)
        XCTAssertNil(restored.scheme)
        XCTAssertEqual(restored.key.address, Vectors.list("wifs")[0].string("address"))
    }

    func testTyposAreReportedPrecisely() {
        do {
            _ = try RecoveryPhrase.restore("abandon abadon abandon abandon abandon abandon abandon abandon abandon abandon abandon about")
            XCTFail("expected the unknown word to be rejected")
        } catch let error as RecoveryPhrase.PhraseError {
            XCTAssertEqual(error, .unknownWords(["abadon"]))
        } catch {
            XCTFail("wrong error: \(error)")
        }

        do {
            _ = try RecoveryPhrase.restore("abandon abandon abandon")
            XCTFail("expected the word count to be rejected")
        } catch let error as RecoveryPhrase.PhraseError {
            XCTAssertEqual(error, .wrongWordCount(3))
        } catch {
            XCTFail("wrong error: \(error)")
        }
    }
}

final class OrdinalTests: XCTestCase {
    func testInscriptionScriptMatchesReference() throws {
        for vector in Vectors13.list("ordinals") {
            let script = Ordinal.script(owner: vector.bytes("pkhHex"),
                                        mime: vector.string("mime"),
                                        bytes: Data(vector.bytes("dataHex")))
            XCTAssertEqual(script.hex, vector.string("scriptHex"),
                           "script for \(vector.string("mime"))")

            let parsed = try XCTUnwrap(Ordinal.parse(script: script))
            XCTAssertEqual(parsed.mime, vector.string("parsedMime"))
            XCTAssertEqual(parsed.owner.hex, vector.string("parsedOwner"))
            XCTAssertEqual(parsed.bytes.hex, vector.string("parsedBytes"))
        }
    }

    func testMediaReadsBothFormats() throws {
        let bytes = Data([9, 8, 7, 6, 5])
        let hash = [UInt8](repeating: 0x33, count: 20)

        let inscription = Ordinal.script(owner: hash, mime: "image/png", bytes: bytes)
        let fromOrdinal = try XCTUnwrap(Media.decode(script: inscription))
        XCTAssertEqual(fromOrdinal.bytes, bytes)
        XCTAssertEqual(fromOrdinal.mime, "image/png")

        let legacy = Media.legacyScript(bytes: bytes, mime: "image/gif")
        let fromLegacy = try XCTUnwrap(Media.decode(script: legacy))
        XCTAssertEqual(fromLegacy.bytes, bytes)
        XCTAssertEqual(fromLegacy.mime, "image/gif")
    }

    func testAlienScriptsAreRejected() {
        XCTAssertNil(Ordinal.parse(script: Script.p2pkh(hash160: [UInt8](repeating: 1, count: 20))))
        XCTAssertNil(Ordinal.parse(script: []))
        XCTAssertNil(Media.decode(script: [0x00, 0x6a, 0x01, 0x02]))
    }

    func testTheInscribedOutputIsSpendableByItsOwner() throws {
        let hash = [UInt8](repeating: 0x44, count: 20)
        let script = Ordinal.script(owner: hash, mime: "image/jpeg", bytes: Data([1, 2, 3]))
        // The first 25 bytes are an ordinary P2PKH lock, which is what keeps
        // the satoshi spendable by the recipient.
        XCTAssertEqual(Script.p2pkhHash(from: Array(script[0..<25])), hash)
    }
}

final class FingerprintTests: XCTestCase {
    func testFingerprintMatchesReference() async throws {
        for vector in Vectors13.list("fingerprints") {
            let chain = MockAdapter()
            let key = try PrivateKey(hex: String(repeating: "0", count: 63) + "1")
            let engine = Engine(wallet: Wallet(key: key), adapter: chain, store: try Store(url: nil))

            let channelId = String(repeating: "ab", count: 20)
            try await engine.store.putChannel(ChannelRecord(channelId: channelId,
                                                            kind: .dm,
                                                            peerPub: vector.string("pubB")))
            XCTAssertEqual(key.publicKey.compressedBytes.hex, vector.string("pubA"))

            let fingerprint = try await engine.keyFingerprint(channelId: channelId)
            XCTAssertEqual(fingerprint, vector.string("fingerprint"))
        }
    }

    func testFingerprintIsSymmetric() async throws {
        let a = try PrivateKey(hex: String(repeating: "0", count: 63) + "1")
        let b = try PrivateKey(hex: "c0ffee00c0ffee00c0ffee00c0ffee00c0ffee00c0ffee00c0ffee00c0ffee00")
        let channelId = String(repeating: "cd", count: 20)

        let fromA = Engine(wallet: Wallet(key: a), adapter: MockAdapter(), store: try Store(url: nil))
        try await fromA.store.putChannel(ChannelRecord(channelId: channelId, kind: .dm,
                                                       peerPub: b.publicKey.compressedBytes.hex))
        let fromB = Engine(wallet: Wallet(key: b), adapter: MockAdapter(), store: try Store(url: nil))
        try await fromB.store.putChannel(ChannelRecord(channelId: channelId, kind: .dm,
                                                       peerPub: a.publicKey.compressedBytes.hex))

        let one = try await fromA.keyFingerprint(channelId: channelId)
        let other = try await fromB.keyFingerprint(channelId: channelId)
        XCTAssertNotNil(one)
        XCTAssertEqual(one, other, "both sides must read the same fingerprint")
    }
}
