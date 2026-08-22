import XCTest
@testable import SpiekCore

final class TransactionTests: XCTestCase {
    func testSerialisationRoundTrip() throws {
        for vector in Vectors.list("buildMessage") {
            let rawHex = vector.string("rawHex")
            let tx = try XCTUnwrap(Transaction.parse(hex: rawHex))
            XCTAssertEqual(tx.hex, rawHex)
            XCTAssertEqual(tx.txid, vector.string("txid"))
        }
    }

    func testParsedTransactionIsARecognisedSpiekRecord() throws {
        for vector in Vectors.list("buildMessage") {
            let parsed = try XCTUnwrap(ParsedSpiekTx.parse(rawHex: vector.string("rawHex")))
            XCTAssertEqual(parsed.txid, vector.string("txid"))
            XCTAssertEqual(parsed.senderAddress, vector.string("address"))
            XCTAssertEqual(parsed.envelope.channel.hex, vector.string("channelHex"))
            XCTAssertEqual(parsed.envelope.payload.hex, vector.string("payloadHex"))
            XCTAssertEqual(parsed.envelope.op.rawValue, UInt8(vector.int("op")))
        }
    }

    func testSignaturesInBuiltTransactionsVerify() throws {
        for vector in Vectors.list("buildMessage") {
            let key = try PrivateKey(hex: vector.string("privHex"))
            var tx = try XCTUnwrap(Transaction.parse(hex: vector.string("rawHex")))
            let script = Script.p2pkh(hash160: key.publicKey.hash160)

            let utxos = vector["utxos"] as? [[String: Any]] ?? []
            for index in tx.inputs.indices {
                // Matched on the outpoint, never on array position: the wallet
                // orders its inputs by its own selection (unconfirmed first,
                // then largest), not by the vector's listing. `sourceTxid` is
                // display order — the same form the vectors carry.
                let outpointTxid = tx.inputs[index].sourceTxid
                let outpointVout = tx.inputs[index].sourceOutputIndex
                guard let matched = utxos.first(where: {
                    $0.string("txid") == outpointTxid && UInt32($0.int("vout")) == outpointVout
                }) else {
                    XCTFail("no vector utxo matches input \(outpointTxid):\(outpointVout) of \(vector.string("txid"))")
                    continue
                }
                tx.inputs[index].sourceSatoshis = matched.uint64("satoshis")
                tx.inputs[index].sourceLockingScript = script
            }

            for index in tx.inputs.indices {
                let chunks = try XCTUnwrap(Script.parsePushes(tx.inputs[index].unlockingScript, from: 0))
                XCTAssertEqual(chunks.count, 2)
                let signatureBytes = Array(chunks[0].dropLast())
                XCTAssertEqual(chunks[0].last, 0x41, "SIGHASH_ALL | SIGHASH_FORKID")

                let signature = try XCTUnwrap(ECDSASignature.fromDER(signatureBytes))
                let digest = tx.sigHash(inputIndex: index, sigHashType: .allForkID)
                XCTAssertTrue(ECDSA.verify(digest: digest, signature: signature,
                                           publicKey: key.publicKey.point),
                              "input \(index) of \(vector.string("txid"))")
            }
        }
    }
}

final class WalletBuildTests: XCTestCase {
    /// The strongest check in the suite: rebuild each reference transaction
    /// from scratch and require an identical byte string, signatures included.
    func testBuildMessageReproducesReferenceBytes() throws {
        for vector in Vectors.list("buildMessage") {
            let key = try PrivateKey(hex: vector.string("privHex"))
            let wallet = Wallet(key: key,
                                dust: vector.uint64("dust"),
                                feePerByte: vector.double("feePerByte"),
                                minFee: vector.uint64("minFee"))
            XCTAssertEqual(wallet.address, vector.string("address"))

            for utxo in vector["utxos"] as? [[String: Any]] ?? [] {
                wallet.add(UTXO(txid: utxo.string("txid"),
                                vout: UInt32(utxo.int("vout")),
                                satoshis: utxo.uint64("satoshis"),
                                confirmed: utxo.bool("confirmed")))
            }

            let extraPayTo = (vector["extraPayTo"] as? [[String: Any]] ?? []).map {
                PayTarget(hash: $0.bytes("hashHex"), satoshis: $0.uint64("satoshis"))
            }

            let built = try wallet.buildMessage(
                kind: try XCTUnwrap(ChannelKind(rawValue: UInt8(vector.int("kind")))),
                channel: vector.bytes("channelHex"),
                prev: vector.bytes("prevHex"),
                op: try XCTUnwrap(SpiekOp(rawValue: UInt8(vector.int("op")))),
                payload: vector.bytes("payloadHex"),
                ref: nil,
                extraPayTo: extraPayTo
            )

            XCTAssertEqual(built.fee, vector.uint64("fee"), "fee for \(vector.string("txid"))")
            XCTAssertEqual(built.txid, vector.string("txid"))
            XCTAssertEqual(built.rawHex, vector.string("rawHex"),
                           "raw bytes for \(vector.string("txid"))")
        }
    }

    func testInsufficientFundsIsReported() throws {
        let key = try PrivateKey(hex: String(repeating: "0", count: 63) + "1")
        let wallet = Wallet(key: key)
        wallet.add(UTXO(txid: String(repeating: "11", count: 32), vout: 0, satoshis: 5))

        XCTAssertThrowsError(try wallet.buildMessage(kind: .note,
                                                     channel: [UInt8](repeating: 0x22, count: 20),
                                                     prev: Envelope.noPrev,
                                                     op: .msg,
                                                     payload: Array("hi".utf8))) { error in
            guard case TransactionError.insufficientFunds = error else {
                return XCTFail("expected insufficientFunds, got \(error)")
            }
        }
    }

    func testUnconfirmedChangeIsSpentFirst() throws {
        let key = try PrivateKey(hex: String(repeating: "0", count: 63) + "1")
        let wallet = Wallet(key: key)
        wallet.add(UTXO(txid: String(repeating: "aa", count: 32), vout: 0, satoshis: 100_000, confirmed: true))
        wallet.add(UTXO(txid: String(repeating: "bb", count: 32), vout: 0, satoshis: 900, confirmed: false))

        let selected = try wallet.selectInputs(target: 100)
        XCTAssertEqual(selected.first?.confirmed, false,
                       "our own unconfirmed change should be chained first")
    }

    func testAbsorbTracksOwnOutputsAndSpends() throws {
        let vector = Vectors.list("buildMessage")[0]
        let key = try PrivateKey(hex: vector.string("privHex"))
        let wallet = Wallet(key: key)
        for utxo in vector["utxos"] as? [[String: Any]] ?? [] {
            wallet.add(UTXO(txid: utxo.string("txid"),
                            vout: UInt32(utxo.int("vout")),
                            satoshis: utxo.uint64("satoshis"),
                            confirmed: utxo.bool("confirmed")))
        }
        let startingBalance = wallet.balance

        wallet.absorb(rawHex: vector.string("rawHex"), confirmed: false)
        XCTAssertTrue(wallet.balance < startingBalance, "the fee and dust left the wallet")
        XCTAssertEqual(wallet.balance, startingBalance - vector.uint64("fee") - 1)
        XCTAssertFalse(wallet.spent.isEmpty)

        wallet.release(rawHex: vector.string("rawHex"))
        XCTAssertTrue(wallet.spent.isEmpty, "releasing frees the inputs again")
        XCTAssertEqual(wallet.balance, startingBalance,
                       "a released transaction must give the inputs back, not just unmark them")
    }
}
