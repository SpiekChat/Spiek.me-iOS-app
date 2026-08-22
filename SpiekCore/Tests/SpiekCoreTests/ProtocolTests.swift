import XCTest
@testable import SpiekCore

final class ScriptTests: XCTestCase {
    func testPushDataMatchesReference() {
        for vector in Vectors.list("pushData") {
            let input = vector.bytes("inputHex")
            XCTAssertEqual(Script.pushData(input).hex, vector.string("outputHex"),
                           "push of \(vector.int("len")) bytes")
        }
    }

    func testPushDataRoundTrip() throws {
        for length in [0, 1, 75, 76, 255, 256, 65535, 65536] {
            let payload = [UInt8](repeating: 0xab, count: length)
            let script = Script.pushData(payload)
            let chunks = try XCTUnwrap(Script.parsePushes(script, from: 0))
            XCTAssertEqual(chunks.count, 1)
            XCTAssertEqual(chunks[0], payload, "round trip at \(length) bytes")
        }
    }

    func testNonMinimalPushIsRejected() {
        // PUSHDATA1 carrying only 10 bytes should have used a direct push.
        XCTAssertNil(Script.parsePushes([0x4c, 0x0a] + [UInt8](repeating: 0, count: 10), from: 0))
        // A non-push opcode has no place in these scripts.
        XCTAssertNil(Script.parsePushes([0xac], from: 0))
        // Truncated data.
        XCTAssertNil(Script.parsePushes([0x05, 0x01, 0x02], from: 0))
    }

    func testP2PKHRecognition() {
        let hash = [UInt8](repeating: 0x11, count: 20)
        let script = Script.p2pkh(hash160: hash)
        XCTAssertEqual(Script.p2pkhHash(from: script), hash)
        XCTAssertNil(Script.p2pkhHash(from: Array(script.dropLast())))
    }
}

final class EnvelopeTests: XCTestCase {
    func testEncodingMatchesReference() throws {
        for vector in Vectors.list("envelopes") {
            let kind = try XCTUnwrap(ChannelKind(rawValue: UInt8(vector.int("kind"))))
            let op = try XCTUnwrap(SpiekOp(rawValue: UInt8(vector.int("op"))))
            let envelope = Envelope(kind: kind,
                                    channel: vector.bytes("channelHex"),
                                    prev: vector.bytes("prevHex"),
                                    op: op,
                                    payload: vector.bytes("payloadHex"),
                                    ref: vector.optionalString("refHex").flatMap(Hex.decode))
            XCTAssertEqual(try envelope.encoded().hex, vector.string("scriptHex"),
                           "envelope \(op.name)")
        }
    }

    func testDecodingRoundTrip() throws {
        for vector in Vectors.list("envelopes") {
            let script = vector.bytes("scriptHex")
            XCTAssertTrue(Envelope.hasMarker(script))
            let decoded = try XCTUnwrap(Envelope.decode(script), "decode \(vector.string("scriptHex").prefix(40))")
            XCTAssertEqual(decoded.kind.rawValue, UInt8(vector.int("kind")))
            XCTAssertEqual(decoded.op.rawValue, UInt8(vector.int("op")))
            XCTAssertEqual(decoded.channel.hex, vector.string("channelHex"))
            XCTAssertEqual(decoded.prev.hex, vector.string("prevHex"))
            XCTAssertEqual(decoded.payload.hex, vector.string("payloadHex"))
            XCTAssertEqual(decoded.ref?.hex, vector.optionalString("refHex"))
            XCTAssertEqual(try decoded.encoded().hex, vector.string("scriptHex"))
        }
    }

    func testInnerEnvelopeMatchesReference() throws {
        for vector in Vectors.list("innerEnvelopes") {
            let op = try XCTUnwrap(SpiekOp(rawValue: UInt8(vector.int("op"))))
            let inner = InnerEnvelope(op: op,
                                      payload: vector.bytes("payloadHex"),
                                      ref: vector.optionalString("refHex").flatMap(Hex.decode))
            XCTAssertEqual(try inner.encoded().hex, vector.string("bytesHex"))

            let decoded = try XCTUnwrap(InnerEnvelope.decode(vector.bytes("bytesHex")))
            XCTAssertEqual(decoded, inner)
        }
    }

    func testRefIsEnforced() {
        let channel = [UInt8](repeating: 0x11, count: 20)
        let envelope = Envelope(kind: .dm, channel: channel, prev: Envelope.noPrev, op: .react,
                                payload: Array("👍".utf8))
        XCTAssertThrowsError(try envelope.encoded())
    }

    func testWrongLengthsAreRejected() {
        let short = Envelope(kind: .dm, channel: [1, 2, 3], prev: Envelope.noPrev, op: .msg)
        XCTAssertThrowsError(try short.encoded())

        let badPrev = Envelope(kind: .dm, channel: [UInt8](repeating: 0, count: 20),
                               prev: [1, 2, 3], op: .msg)
        XCTAssertThrowsError(try badPrev.encoded())
    }

    func testAlienScriptIsNotAnEnvelope() {
        XCTAssertNil(Envelope.decode(Script.p2pkh(hash160: [UInt8](repeating: 1, count: 20))))
        XCTAssertFalse(Envelope.hasMarker([0x00, 0x6a, 0x05] + Array("spiel".utf8) + [0x01, 0x02]))
    }
}

final class CodecTests: XCTestCase {
    func testMediaCodecMatchesReference() throws {
        for vector in Vectors.dictionary("codecs")["media"] as? [[String: Any]] ?? [] {
            let ref = Codecs.MediaRef(txid: vector.string("txid"),
                                      vout: UInt32(vector.int("vout")),
                                      caption: vector.string("caption"))
            let encoded = try XCTUnwrap(Codecs.encodeMedia(ref))
            XCTAssertEqual(encoded.hex, vector.string("hex"))
            XCTAssertEqual(Codecs.decodeMedia(encoded), ref)
        }
    }

    func testInviteCodes() throws {
        let channelId = String(repeating: "ab", count: 20)
        XCTAssertEqual(InviteCode.encode(channelId: channelId, kind: .dm), "spiek:chat:\(channelId)")
        XCTAssertEqual(InviteCode.encode(channelId: channelId, kind: .group), "spiek:group:\(channelId)")

        let decoded = try XCTUnwrap(InviteCode.decode(" spiek:group:\(channelId) "))
        XCTAssertEqual(decoded.channelId, channelId)
        XCTAssertEqual(decoded.kind, .group)

        XCTAssertNil(InviteCode.decode("spiek:chat:nothex"))
        XCTAssertNil(InviteCode.decode("https://example.com"))
    }

    func testChannelAddressDerivation() throws {
        let channelId = String(repeating: "cd", count: 20)
        let address = try XCTUnwrap(ChannelID.address(for: channelId))
        XCTAssertEqual(Address.hash160(from: address)?.hex, channelId)
    }
}
