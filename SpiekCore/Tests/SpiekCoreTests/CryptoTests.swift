import XCTest
@testable import SpiekCore

final class HashTests: XCTestCase {
    func testHashesMatchReference() {
        for vector in Vectors.list("hashes") {
            let input = Array(vector.string("inputUtf8").utf8)
            XCTAssertEqual(Hash.sha256(input).hex, vector.string("sha256"),
                           "sha256 of \(vector.string("inputUtf8"))")
            XCTAssertEqual(Hash.ripemd160(input).hex, vector.string("ripemd160"),
                           "ripemd160 of \(vector.string("inputUtf8"))")
            XCTAssertEqual(Hash.hash160(input).hex, vector.string("hash160"),
                           "hash160 of \(vector.string("inputUtf8"))")
            XCTAssertEqual(Hash.hmacSHA256(key: Array("spiek".utf8), message: input).hex,
                           vector.string("sha256hmacKeySpiek"),
                           "hmac of \(vector.string("inputUtf8"))")
        }
    }

    func testSHA256HandlesBlockBoundaries() {
        // 55, 56, 63, 64 and 65 bytes exercise every padding branch.
        for length in [0, 1, 55, 56, 63, 64, 65, 119, 120, 128, 1000] {
            let input = [UInt8](repeating: 0x61, count: length)
            var streamed = SHA256Core()
            for chunk in stride(from: 0, to: length, by: 7) {
                streamed.update(input[chunk..<min(chunk + 7, length)])
            }
            XCTAssertEqual(streamed.finalize(), SHA256Core.hash(input),
                           "streaming vs one-shot at \(length) bytes")
        }
    }
}

final class Base58Tests: XCTestCase {
    func testAddressRoundTrip() {
        for vector in Vectors.list("addresses") {
            let address = vector.string("address")
            XCTAssertEqual(Address.hash160(from: address)?.hex, vector.string("hash160"))
            XCTAssertEqual(Address.encode(hash160: vector.bytes("hash160")), address)
            XCTAssertEqual(Script.p2pkh(hash160: vector.bytes("hash160")).hex,
                           vector.string("p2pkhScript"))
        }
    }

    func testChecksumRejectsTampering() {
        var address = Array("1BgGZ9tcN4rm9KBzDn7KprQz87SZ26SAMH")
        address[5] = address[5] == "9" ? "8" : "9"
        XCTAssertNil(Address.hash160(from: String(address)))
    }

    func testLeadingZeroesSurvive() {
        let payload = [UInt8](repeating: 0, count: 20)
        let encoded = Address.encode(hash160: payload)
        XCTAssertTrue(encoded.hasPrefix("11"))
        XCTAssertEqual(Address.hash160(from: encoded), payload)
    }
}

final class KeyTests: XCTestCase {
    func testWIFAndAddressDerivation() throws {
        for vector in Vectors.list("wifs") {
            let key = try PrivateKey(hex: vector.string("privHex"))
            XCTAssertEqual(key.wif, vector.string("wif"))
            XCTAssertEqual(key.address, vector.string("address"))
            XCTAssertEqual(key.publicKey.compressedBytes.hex, vector.string("pubCompressed"))

            let reimported = try PrivateKey(wif: vector.string("wif"))
            XCTAssertEqual(reimported.bytes, key.bytes)
        }
    }

    /// These vectors predate BIP-39 support, so they exercise the legacy path.
    func testLegacyRecoveryPhraseDerivation() throws {
        for vector in Vectors.list("phraseKeys") {
            let key = try RecoveryPhrase.key(forPhrase: vector.string("phrase"), scheme: .legacy)
            XCTAssertEqual(key.hex, vector.string("privHex"))
            XCTAssertEqual(key.wif, vector.string("wif"))
            XCTAssertEqual(key.address, vector.string("address"))
            XCTAssertEqual(key.publicKey.compressedBytes.hex, vector.string("pubCompressed"))
            XCTAssertEqual(key.publicKey.uncompressedBytes?.hex, vector.string("pubUncompressed"))
            XCTAssertEqual(key.publicKey.hash160.hex, vector.string("hash160"))
        }
    }

    func testRestoreIsCaseAndSpaceInsensitive() throws {
        let phrase = Vectors.list("phraseKeys")[0].string("phrase")
        let restored = try RecoveryPhrase.restore("  \(phrase.uppercased())   ", forceLegacy: true)
        XCTAssertEqual(restored.key.address, Vectors.list("phraseKeys")[0].string("address"))
        XCTAssertNotNil(restored.phrase)
    }

    func testGeneratedPhraseIsUsable() throws {
        let phrase = RecoveryPhrase.generate()
        XCTAssertEqual(RecoveryPhrase.words(in: phrase).count, 12)
        XCTAssertNoThrow(try RecoveryPhrase.key(forPhrase: phrase, scheme: .bip39))
    }

    func testWordlistIsComplete() {
        XCTAssertEqual(Wordlist.english.count, 2048)
        XCTAssertEqual(Wordlist.english.first, "abandon")
        XCTAssertEqual(Wordlist.english.last, "zoo")
        XCTAssertEqual(Set(Wordlist.english).count, 2048)
    }
}

final class ECDSATests: XCTestCase {
    func testDeterministicSignaturesMatchReference() throws {
        for vector in Vectors.list("signatures") {
            let key = try PrivateKey(hex: vector.string("privHex"))
            let message = Array(vector.string("msgUtf8").utf8)
            // The vector's `sha256` field is the *single* hash of the message…
            XCTAssertEqual(Hash.sha256(message).hex, vector.string("sha256"))

            // …but the reference signatures were produced over the DOUBLE
            // SHA-256 — Bitcoin's message digest. The Android suite documents
            // and passes the same fact; signing the single hash does not
            // reproduce `derHex`.
            let digest = Hash.sha256d(message)
            let signature = try XCTUnwrap(key.sign(digest: digest))
            XCTAssertEqual(signature.derEncoded.hex, vector.string("derHex"),
                           "signature for \(vector.string("msgUtf8"))")
            XCTAssertTrue(ECDSA.verify(digest: digest, signature: signature,
                                       publicKey: key.publicKey.point))
            XCTAssertFalse(signature.s.isHigh, "signatures must be low-S")
        }
    }

    func testDERRoundTrip() throws {
        for vector in Vectors.list("signatures") {
            let der = vector.bytes("derHex")
            let parsed = try XCTUnwrap(ECDSASignature.fromDER(der))
            XCTAssertEqual(parsed.derEncoded, der)
        }
    }

    func testVerifyRejectsWrongDigest() throws {
        let key = try PrivateKey(hex: "01".padded(to: 64))
        let digest = Hash.sha256(Array("hello".utf8))
        let signature = try XCTUnwrap(key.sign(digest: digest))
        let otherDigest = Hash.sha256(Array("hellp".utf8))
        XCTAssertFalse(ECDSA.verify(digest: otherDigest, signature: signature,
                                    publicKey: key.publicKey.point))
    }

    func testGeneratorIsOnCurve() {
        XCTAssertTrue(ECPoint.generator.isOnCurve())
        XCTAssertTrue((ECPoint.generator + ECPoint.generator).isOnCurve())
        XCTAssertTrue(ECPoint.generator.doubled().isOnCurve())
        XCTAssertEqual(ECPoint.generator.doubled().affine?.x,
                       (ECPoint.generator + ECPoint.generator).affine?.x)
    }

    func testPointEncodingRoundTrip() throws {
        for vector in Vectors.list("wifs") {
            let compressed = vector.bytes("pubCompressed")
            let point = try XCTUnwrap(ECPoint.decode(compressed))
            XCTAssertEqual(point.encoded(compressed: true), compressed)
            let uncompressed = try XCTUnwrap(point.encoded(compressed: false))
            XCTAssertEqual(ECPoint.decode(uncompressed)?.encoded(compressed: true), compressed)
        }
    }

    func testScalarMultiplicationAgreesWithRepeatedAddition() {
        var accumulated = ECPoint.infinity
        for multiplier in 1...20 {
            accumulated = accumulated + ECPoint.generator
            let direct = ECPoint.generator.multiplied(by: Scalar(U256(UInt64(multiplier))))
            XCTAssertEqual(direct.affine?.x, accumulated.affine?.x, "\(multiplier)·G")
            XCTAssertEqual(direct.affine?.y, accumulated.affine?.y, "\(multiplier)·G")
        }
    }
}

final class ECDHTests: XCTestCase {
    func testSharedSecretMatchesReference() throws {
        for vector in Vectors.list("ecdh") {
            let a = try PrivateKey(hex: vector.string("privA"))
            let b = try PrivateKey(hex: vector.string("privB"))
            XCTAssertEqual(a.publicKey.compressedBytes.hex, vector.string("pubA"))
            XCTAssertEqual(b.publicKey.compressedBytes.hex, vector.string("pubB"))

            let shared = try XCTUnwrap(a.sharedSecret(with: b.publicKey))
            XCTAssertEqual(shared.hex, vector.string("sharedPointCompressed"))
            // ECDH is symmetric.
            XCTAssertEqual(b.sharedSecret(with: a.publicKey)?.hex, shared.hex)

            let symmetric = try XCTUnwrap(a.conversationKey(with: b.publicKey))
            XCTAssertEqual(symmetric.hex, vector.string("symmetricKey"))
        }
    }
}

final class AESGCMTests: XCTestCase {
    func testOpensReferenceCiphertexts() throws {
        let key = Vectors.list("ecdh")[0].bytes("symmetricKey")
        for vector in Vectors.list("aesDecrypt") {
            let sealed = vector.bytes("ciphertextHex")
            let opened = try AESGCM.open(sealed: sealed, key: key)
            XCTAssertEqual(String(decoding: opened, as: UTF8.self), vector.string("plaintextUtf8"))
        }
    }

    func testSealThenOpen() throws {
        let key = Vectors.list("ecdh")[0].bytes("symmetricKey")
        for length in [0, 1, 15, 16, 17, 100, 1024] {
            let plaintext = [UInt8](repeating: 0x5a, count: length)
            let sealed = try AESGCM.seal(plaintext: plaintext, key: key)
            XCTAssertEqual(sealed.count, AESGCM.ivLength + length + AESGCM.tagLength)
            XCTAssertEqual(try AESGCM.open(sealed: sealed, key: key), plaintext)
        }
    }

    func testTamperingIsRejected() throws {
        let key = Vectors.list("ecdh")[0].bytes("symmetricKey")
        var sealed = try AESGCM.seal(plaintext: Array("hello".utf8), key: key)
        sealed[40] ^= 0x01
        XCTAssertThrowsError(try AESGCM.open(sealed: sealed, key: key))
    }

    func testKnownAnswerFromNISTVector() throws {
        // NIST SP 800-38D, AES-256/GCM, 96-bit IV, empty plaintext.
        let key = [UInt8](repeating: 0, count: 32)
        let iv = [UInt8](repeating: 0, count: 12)
        let sealed = try AESGCM.seal(plaintext: [], key: key, iv: iv)
        XCTAssertEqual(Array(sealed.suffix(16)).hex, "530f8afbc74536b9a963b4f1c4cb738b")
    }
}

private extension String {
    func padded(to length: Int) -> String {
        String(repeating: "0", count: max(0, length - count)) + self
    }
}
