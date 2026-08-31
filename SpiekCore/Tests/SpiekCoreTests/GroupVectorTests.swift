import Foundation
import XCTest
@testable import SpiekCore

/// The encrypted-group golden vectors (v1.20). The ciphertexts were produced
/// by an implementation independent of every client (Node/OpenSSL AES-256-GCM
/// with the Spiek wire layout: 32-byte IV ‖ ciphertext ‖ 16-byte tag), so
/// decrypting them here proves this core's group cipher interoperates rather
/// than merely agreeing with itself. The negative vectors must all fail.
final class GroupVectorTests: XCTestCase {

    private static let root: [String: Any] = {
        guard let url = Bundle.module.url(forResource: "group_vectors", withExtension: "json"),
              let data = try? Data(contentsOf: url),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            XCTFail("group_vectors.json is missing from the test bundle")
            return [:]
        }
        return object
    }()

    func testPositiveVectorsDecryptAndDecode() throws {
        let vectors = Self.root["vectors"] as? [[String: Any]] ?? []
        XCTAssertGreaterThanOrEqual(vectors.count, 8, "the vector set shrank")

        for vector in vectors {
            let name = vector.string("name")
            let key = vector.bytes("key")
            let sealed = vector.bytes("ciphertext")
            let expect = vector["expect"] as? [String: Any] ?? [:]

            let plaintext = try AESGCM.open(sealed: sealed, key: key)
            let inner = try XCTUnwrap(InnerEnvelope.decode(plaintext), "\(name): inner record does not decode")
            XCTAssertEqual(Int(inner.op.rawValue), expect.int("op"), "\(name): op")
            XCTAssertEqual(inner.payload.hex, expect.string("payload"), "\(name): payload")
            if let expectedRef = expect.optionalString("ref") {
                XCTAssertEqual(inner.ref?.hex, expectedRef, "\(name): ref")
            } else {
                XCTAssertNil(inner.ref, "\(name): no ref expected")
            }
        }
    }

    func testNegativeVectorsAreRejected() {
        let negatives = Self.root["negatives"] as? [[String: Any]] ?? []
        XCTAssertGreaterThanOrEqual(negatives.count, 4, "the negative set shrank")

        for negative in negatives {
            let name = negative.string("name")
            let key = negative.bytes("key")
            let sealed = negative.bytes("ciphertext")
            XCTAssertThrowsError(try AESGCM.open(sealed: sealed, key: key),
                                 "\(name) must be rejected (\(negative.string("note")))")
        }
    }

    func testOwnGroupSealReopens() throws {
        // What this core encrypts under a group key, this core opens — with a
        // vector key, so the round trip runs on the exact shared material.
        let key = try XCTUnwrap(Hex.decode("9e739ddd73ddb4f8fada38420a8f9a6144fa2d5e535bc9f79a7f6d8e9fd5e70e"))
        let body = try InnerEnvelope(op: .msg, payload: Codecs.encodeText("eigen rondje")).encoded()
        let sealed = try AESGCM.seal(plaintext: body, key: key)
        XCTAssertEqual(try AESGCM.open(sealed: sealed, key: key), body)
    }
}
