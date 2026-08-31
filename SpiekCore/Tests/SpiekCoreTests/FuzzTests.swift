import Foundation
import XCTest
@testable import SpiekCore

/// Fuzzing the decoders with mutated inputs (v1.20). The contract under test
/// is the same on all three platforms: a decoder either returns a fully valid
/// result or rejects (nil / a thrown error) — it never crashes the process and
/// never silently accepts a corrupted ref-carrying record without its ref.
/// Deterministic: a fixed-seed generator, so a failure reproduces byte for byte.
final class FuzzTests: XCTestCase {

    /// xorshift64 — small, stable across platforms, no Foundation randomness.
    private struct Rng {
        var state: UInt64 = 0x5f3759df
        mutating func next() -> UInt64 {
            state ^= state << 13
            state ^= state >> 7
            state ^= state << 17
            return state
        }
        mutating func int(_ upper: Int) -> Int { upper <= 0 ? 0 : Int(next() % UInt64(upper)) }
        mutating func bytes(_ count: Int) -> [UInt8] { (0..<count).map { _ in UInt8(truncatingIfNeeded: next()) } }
        mutating func bool() -> Bool { next() & 1 == 1 }
    }

    private func isValid(_ inner: InnerEnvelope?) -> Bool {
        guard let inner else { return true }
        if inner.op == .emsg { return false }
        if let ref = inner.ref, ref.count != 32 { return false }
        if inner.op.requiresRef && inner.ref == nil { return false }
        return true
    }

    func testInnerDecoderSurvivesBitFlips() throws {
        var rng = Rng()
        let ops: [SpiekOp] = [.msg, .media, .react, .edit, .del, .profile, .open]
        for _ in 0..<4000 {
            let op = ops[rng.int(ops.count)]
            let inner = op.requiresRef
                ? InnerEnvelope(op: op, payload: rng.bytes(rng.int(48)), ref: rng.bytes(32))
                : InnerEnvelope(op: op, payload: rng.bytes(rng.int(120)))
            var mutated = try inner.encoded()
            for _ in 0..<(1 + rng.int(4)) {
                let index = rng.int(mutated.count)
                mutated[index] ^= UInt8(1 << rng.int(8))
            }
            XCTAssertTrue(isValid(InnerEnvelope.decode(mutated)),
                          "bit-flipped inner decoded into a malformed record")
        }
    }

    func testInnerDecoderSurvivesTruncationAndPadding() throws {
        var rng = Rng()
        for _ in 0..<2000 {
            let encoded = try InnerEnvelope(op: .edit, payload: rng.bytes(rng.int(80)), ref: rng.bytes(32)).encoded()
            let mutated = rng.bool()
                ? Array(encoded.prefix(rng.int(encoded.count)))
                : encoded + rng.bytes(1 + rng.int(8))
            XCTAssertTrue(isValid(InnerEnvelope.decode(mutated)),
                          "cut/padded inner decoded into a malformed record")
        }
    }

    func testPushDataReaderNeverOverreads() {
        var rng = Rng()
        for _ in 0..<4000 {
            let soup = rng.bytes(rng.int(300))
            if let chunks = Script.parsePushes(soup, from: 0) {
                let total = chunks.reduce(0) { $0 + $1.count }
                XCTAssertLessThanOrEqual(total, soup.count,
                                         "push-data reader claimed more bytes than the buffer holds")
            }
            XCTAssertTrue(isValid(InnerEnvelope.decode(soup)),
                          "byte soup decoded into a malformed record")
        }
    }

    func testLyingLengthPrefixesAreRejected() {
        var rng = Rng()
        for _ in 0..<1000 {
            let body = rng.bytes(rng.int(40))
            // OP_PUSHDATA1 claiming more bytes than follow.
            let lie: [UInt8] = [76, UInt8(min(255, body.count + 1 + rng.int(180)))] + body
            XCTAssertNil(Script.parsePushes(lie, from: 0), "an overlong length claim was accepted")
        }
    }

    func testCorruptedAddressesNeverDecode() {
        var rng = Rng()
        let alphabet = Array("123456789ABCDEFGHJKLMNPQRSTUVWXYZabcdefghijkmnopqrstuvwxyz")
        let address = "1ATEXPH6FSctbZdAz8MnXCfDpCvDnFrWma"
        XCTAssertEqual(Address.hash160(from: address)?.count, 20, "the genuine operator address must decode")
        var checked = 0
        var characters = Array(address)
        while checked < 1200 {
            let index = rng.int(characters.count)
            let substitute = alphabet[rng.int(alphabet.count)]
            if substitute == characters[index] { continue }
            checked += 1
            var mutated = characters
            mutated[index] = substitute
            XCTAssertNil(Address.hash160(from: String(mutated)),
                         "a corrupted address slipped past the checksum")
            characters = Array(address)
        }
        for _ in 0..<1000 {
            let length = 1 + rng.int(40)
            let garbage = String((0..<length).map { _ in Character(UnicodeScalar(33 + rng.int(90))!) })
            if let hash = Address.hash160(from: garbage) {
                XCTAssertEqual(hash.count, 20, "random text produced a malformed hash160")
            }
        }
    }

    func testGroupCipherRejectsEveryMutation() throws {
        var rng = Rng()
        let key = rng.bytes(32)
        let body = try InnerEnvelope(op: .msg, payload: rng.bytes(64)).encoded()
        let sealed = try AESGCM.seal(plaintext: body, key: key)
        for _ in 0..<800 {
            var mutated = sealed
            let index = rng.int(mutated.count)
            mutated[index] ^= UInt8(1 + rng.int(255))
            if mutated == sealed { continue }
            // Any changed byte — IV, ciphertext or tag — must break authentication.
            XCTAssertThrowsError(try AESGCM.open(sealed: mutated, key: key),
                                 "a mutated group ciphertext authenticated")
        }
        for _ in 0..<400 {
            let cut = Array(sealed.prefix(rng.int(sealed.count)))
            XCTAssertThrowsError(try AESGCM.open(sealed: cut, key: key),
                                 "a truncated group ciphertext opened")
        }
    }

    func testInviteCodesRejectMalformedKeys() {
        var rng = Rng()
        let hexChars = Array("0123456789abcdef")
        func hexString(_ length: Int) -> String { String((0..<length).map { _ in hexChars[rng.int(16)] }) }
        for _ in 0..<2000 {
            let kind = ["chat", "dm", "group"][rng.int(3)]
            let id = hexString(40)
            let key = hexString(64)
            var code = "spiek:\(kind):\(id)" + (rng.bool() ? ":\(key)" : "")
            switch rng.int(5) {
            case 0: code = String(code.dropLast(1 + rng.int(3)))
            case 1: code += String(hexChars[rng.int(16)])
            case 2:
                var characters = Array(code)
                characters[rng.int(characters.count)] = "G"
                code = String(characters)
            case 3:
                if let range = code.range(of: ":") { code = code.replacingCharacters(in: range, with: ";") }
            default: code = " x" + code
            }
            if let decoded = InviteCode.decode(code) {
                XCTAssertEqual(decoded.channelId.count, 40, "decoded channel id has the wrong shape")
                if let decodedKey = decoded.groupKey {
                    XCTAssertEqual(decodedKey.count, 64, "decoded key has the wrong shape")
                    XCTAssertEqual(decoded.kind, .group, "a non-group code carried a key")
                }
            }
        }
        // The canonical forms themselves must keep working.
        let id = String(repeating: "ab", count: 20)
        let key = String(repeating: "cd", count: 32)
        XCTAssertNil(InviteCode.decode("spiek:group:\(id)")?.groupKey)
        XCTAssertEqual(InviteCode.decode("spiek:group:\(id):\(key)")?.groupKey, key)
        XCTAssertNil(InviteCode.decode("spiek:chat:\(id):\(key)"))
    }
}
