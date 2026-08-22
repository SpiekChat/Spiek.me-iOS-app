import XCTest
@testable import SpiekCore

/// The acceptance criterion for the port is reproducing both test vectors from
/// the resolver's own spec, byte for byte. Everything else here is built on top
/// of that.
final class SNSSighashTests: XCTestCase {
    /// Vector 1 from skill.md §6 — a resolve answer.
    func testResolveSighashMatchesTheSpecVector() {
        let resolution = SNS.Resolution(
            v: 1,
            input: nil,
            name: "ordnet.web3",
            mailbox: "alexander",
            source: nil,
            fallback: true,
            holderAddress: nil,
            holderScript: "76a914e8e5f64b0c7943b93e58b24e3f82d533e70b3db188ac",
            origin: .init(txid: "367a0a1d553002f0f3427168a10f86835e2741c111df43262d35fb475400e3ee",
                          vout: 0),
            current: .init(txid: "dc54c20af97682eebf99dc8392c21b904908398d543aae6fabffe09a9b7780ac",
                           vout: 0),
            asOfHeight: 959941,
            expires: 1785312000,
            sig: "",
            signer: ""
        )
        XCTAssertEqual(SNS.sighash(for: resolution).hex,
                       "28a4252e92fdcdb70d6fd287cdb602cda504d288963e106b47a6d8d19420ec6b")
    }

    /// Vector 2 — a key-rotation deed.
    func testRotationSighashMatchesTheSpecVector() {
        let rotation = SNS.Rotation(
            rv: 1,
            seq: 1,
            oldPub: "034f355bdcb7cc0af728ef3cceb9615d90684bb5b2ca5f859ab0f0b704075871aa",
            newPub: "02466d7fcae563e5cb09a0d1870bb580344804617879a14949cf22285f1bae3f27",
            validFrom: 1785500000,
            sig: ""
        )
        XCTAssertEqual(SNS.sighash(for: rotation).hex,
                       "ddc9eefe6e0097a6312171f0dad76b6822e08f31498bd7f47f51ba163481cb31")
    }

    func testFieldsAreJoinedWithTheUnitSeparator() {
        let bytes = SNS.canonical(tag: "T", fields: ["a", "b"])
        XCTAssertEqual(bytes, [0x54, 0x1f, 0x61, 0x1f, 0x62])
    }
}

/// A real answer captured from the live resolver, kept as a fixture so the
/// signature path is exercised without a network.
private enum Live {
    static let signer = "03088f1da3bfc998c1bc7bbc1ffcb7d96c47e094624a52d78406f8c3105b0d0b46"

    static func resolution() -> SNS.Resolution {
        SNS.Resolution(
            v: 1,
            input: "ditiseentest.web3",
            name: "ditiseentest.web3",
            mailbox: "",
            source: "sns",
            fallback: false,
            holderAddress: "1NdU53DPAv7ftxoWDpM9c5P4nx1hFnJ6Ry",
            holderScript: "76a914ed403671607a9d077082219581c5328b8fa2d55088ac",
            origin: .init(txid: "5bebe49ade63904afd9ff4afb6b2562897b788c5680fba5f37cbbbe47897948f",
                          vout: 0),
            current: .init(txid: "5bebe49ade63904afd9ff4afb6b2562897b788c5680fba5f37cbbbe47897948f",
                           vout: 0),
            asOfHeight: 960687,
            expires: 1785764663,
            sig: "3045022100916f0d3855b83d045383ee1fe2d0b5c0719d3c956e35c00dc695c913677066cd02203d4614479e1d8704c682dc56507b1cee2fec6fd5dacb579679ffb8060b78092d",
            signer: signer
        )
    }

    /// The same name reached through an unknown mailbox: `fallback` is true and
    /// the holder script is identical.
    static func mailboxFallback() -> SNS.Resolution {
        var resolution = self.resolution()
        resolution.input = "typfout@ditiseentest.web3"
        resolution.mailbox = "typfout"
        resolution.fallback = true
        resolution.expires = 1785764674
        resolution.sig = "3045022100c75c5781eb871726c87a9d341454f727f598756f5c9a5c8262dcaacdc0575c8802203f40c373865ae671b57101bad97636e14be2d0a1e1f6eaac46d006a992b839b0"
        return resolution
    }
}

final class SNSSignatureTests: XCTestCase {
    func testLiveAnswerVerifiesAgainstThePinnedKey() {
        let resolution = Live.resolution()
        XCTAssertEqual(resolution.signer, SNS.pinnedSigner)
        XCTAssertTrue(SNS.isSignatureValid(digest: SNS.sighash(for: resolution),
                                           derHex: resolution.sig,
                                           publicKeyHex: resolution.signer))
    }

    func testMailboxFallbackVerifiesAndKeepsTheSameHolder() {
        let fallback = Live.mailboxFallback()
        XCTAssertTrue(fallback.fallback)
        XCTAssertEqual(fallback.holderScript, Live.resolution().holderScript)
        XCTAssertTrue(SNS.isSignatureValid(digest: SNS.sighash(for: fallback),
                                           derHex: fallback.sig,
                                           publicKeyHex: fallback.signer))
    }

    /// Changing any signed field must break the signature — one test per field,
    /// so a field silently dropped from the sighash cannot pass unnoticed.
    func testTamperingWithAnySignedFieldBreaksVerification() {
        let original = Live.resolution()
        let mutations: [(String, (inout SNS.Resolution) -> Void)] = [
            ("v", { $0.v = 2 }),
            ("name", { $0.name = "andere.web3" }),
            ("mailbox", { $0.mailbox = "iemand" }),
            ("holder_script", { $0.holderScript = "76a914" + String(repeating: "00", count: 20) + "88ac" }),
            ("origin.txid", { $0.origin.txid = String(repeating: "11", count: 32) }),
            ("origin.vout", { $0.origin.vout = 1 }),
            ("current.txid", { $0.current.txid = String(repeating: "22", count: 32) }),
            ("current.vout", { $0.current.vout = 7 }),
            ("as_of_height", { $0.asOfHeight = 960688 }),
            ("fallback", { $0.fallback = true }),
            ("expires", { $0.expires = 1785764664 }),
        ]

        XCTAssertEqual(mutations.count, original.signedFields.count,
                       "every signed field needs a tamper case")

        for (label, mutate) in mutations {
            var tampered = original
            mutate(&tampered)
            XCTAssertFalse(SNS.isSignatureValid(digest: SNS.sighash(for: tampered),
                                                derHex: tampered.sig,
                                                publicKeyHex: tampered.signer),
                           "changing \(label) must break the signature")
        }
    }

    func testAnswerSignedByAnotherKeyIsRejected() throws {
        let resolution = Live.resolution()
        let stranger = try PrivateKey(hex: String(repeating: "0", count: 63) + "7")
        XCTAssertFalse(SNS.isSignatureValid(digest: SNS.sighash(for: resolution),
                                            derHex: resolution.sig,
                                            publicKeyHex: stranger.publicKey.compressedBytes.hex))
    }
}

final class SNSScriptTests: XCTestCase {
    /// The address shown must come from the *signed* script, never from the
    /// unsigned `holder_address` field.
    func testAddressIsDerivedFromTheSignedScript() {
        let resolution = Live.resolution()
        XCTAssertEqual(resolution.derivedAddress, "1NdU53DPAv7ftxoWDpM9c5P4nx1hFnJ6Ry")
        XCTAssertEqual(resolution.derivedAddress, resolution.holderAddress)
    }

    func testNonStandardScriptsAreRefused() {
        XCTAssertNil(SNS.address(fromScriptHex: "6a0568656c6c6f"))
        XCTAssertNil(SNS.address(fromScriptHex: "76a914dead88ac"))
        XCTAssertNil(SNS.address(fromScriptHex: "not hex"))
        XCTAssertNil(SNS.address(fromScriptHex: ""))
    }
}

final class SNSNameTests: XCTestCase {
    private let tlds = ["web3", "bitcoin", "crypto", "blockchain", "ordnet", "bsv", "bitcoinsv"]

    func testRecognisesNamesAndMailboxes() {
        XCTAssertTrue(SNS.looksLikeSNS("ordnet.web3", tlds: tlds))
        XCTAssertTrue(SNS.looksLikeSNS("  ORDNET.WEB3 ", tlds: tlds))
        XCTAssertTrue(SNS.looksLikeSNS("alexander@ordnet.web3", tlds: tlds))
        XCTAssertTrue(SNS.looksLikeSNS("naam.bsv", tlds: tlds), "retired extensions still resolve")
    }

    /// A bare name with no dot is OpNS — a different service with different
    /// rules. Sending one here would be mixing two namespaces.
    func testBareNamesAndAddressesAreNotSNS() {
        XCTAssertFalse(SNS.looksLikeSNS("ordnet", tlds: tlds))
        XCTAssertFalse(SNS.looksLikeSNS("1NdU53DPAv7ftxoWDpM9c5P4nx1hFnJ6Ry", tlds: tlds))
        XCTAssertFalse(SNS.looksLikeSNS("iemand.com", tlds: tlds))
        XCTAssertFalse(SNS.looksLikeSNS("", tlds: tlds))
    }

    func testDomainOfStripsTheMailbox() {
        XCTAssertEqual(SNS.domain(of: "alexander@ordnet.web3"), "ordnet.web3")
        XCTAssertEqual(SNS.domain(of: "ordnet.web3"), "ordnet.web3")
    }

    func testInvisibleCharactersAreAHighWarning() {
        let warnings = SNS.warnings(for: "ord\u{200B}net.web3")
        XCTAssertTrue(warnings.contains { $0.severity == .high })
        XCTAssertTrue(warnings.contains { $0.text.contains("U+200B") })
    }

    func testMixedScriptsAreAHighWarning() {
        // "о" here is Cyrillic, not Latin.
        let warnings = SNS.warnings(for: "\u{043E}rdnet.web3")
        XCTAssertTrue(warnings.contains { $0.severity == .high })
    }

    func testAPlainNameHasNoHighWarning() {
        XCTAssertFalse(SNS.warnings(for: "ditiseentest.web3").contains { $0.severity == .high })
    }
}

final class SNSRotationTests: XCTestCase {
    private func deed(seq: Int, from old: PrivateKey, to new: PrivateKey, validFrom: Int = 1) throws -> SNS.Rotation {
        var rotation = SNS.Rotation(rv: 1,
                                    seq: seq,
                                    oldPub: old.publicKey.compressedBytes.hex,
                                    newPub: new.publicKey.compressedBytes.hex,
                                    validFrom: validFrom,
                                    sig: "")
        let signature = try XCTUnwrap(old.sign(digest: SNS.sighash(for: rotation)))
        rotation.sig = signature.derEncoded.hex
        return rotation
    }

    func testAClosingChainIsAccepted() throws {
        let first = try PrivateKey.random()
        let second = try PrivateKey.random()
        let third = try PrivateKey.random()

        let chain = [try deed(seq: 1, from: first, to: second),
                     try deed(seq: 2, from: second, to: third)]
        let walked = SNSResolver.walk(chain: chain, from: first.publicKey.compressedBytes.hex)
        XCTAssertEqual(walked?.signer, third.publicKey.compressedBytes.hex)
        XCTAssertEqual(walked?.seq, 2)
    }

    func testATamperedDeedIsRefused() throws {
        let first = try PrivateKey.random()
        let second = try PrivateKey.random()
        let attacker = try PrivateKey.random()

        var chain = [try deed(seq: 1, from: first, to: second)]
        chain[0].newPub = attacker.publicKey.compressedBytes.hex
        XCTAssertNil(SNSResolver.walk(chain: chain, from: first.publicKey.compressedBytes.hex),
                     "a deed rewritten after signing must not move the pin")
    }

    /// A deed signed by someone other than the key it replaces proves nothing.
    func testADeedSignedByAStrangerIsRefused() throws {
        let first = try PrivateKey.random()
        let second = try PrivateKey.random()
        let stranger = try PrivateKey.random()

        let forged = try deed(seq: 1, from: stranger, to: second)
        var chain = [forged]
        chain[0].oldPub = first.publicKey.compressedBytes.hex
        XCTAssertNil(SNSResolver.walk(chain: chain, from: first.publicKey.compressedBytes.hex))
    }

    func testAGapInTheChainIsRefused() throws {
        let first = try PrivateKey.random()
        let second = try PrivateKey.random()
        let third = try PrivateKey.random()
        let fourth = try PrivateKey.random()

        // seq 2 replaces a key we never reached.
        let chain = [try deed(seq: 1, from: first, to: second),
                     try deed(seq: 2, from: third, to: fourth)]
        XCTAssertNil(SNSResolver.walk(chain: chain, from: first.publicKey.compressedBytes.hex))
    }

    func testAnEmptyChainLeavesThePinAlone() {
        XCTAssertNil(SNSResolver.walk(chain: [], from: SNS.pinnedSigner))
    }

    /// Deeds from before our pin are history and must simply be skipped.
    func testDeedsOlderThanThePinAreSkipped() throws {
        let ancient = try PrivateKey.random()
        let first = try PrivateKey.random()
        let second = try PrivateKey.random()

        let chain = [try deed(seq: 1, from: ancient, to: first),
                     try deed(seq: 2, from: first, to: second)]
        let walked = SNSResolver.walk(chain: chain, from: first.publicKey.compressedBytes.hex)
        XCTAssertEqual(walked?.signer, second.publicKey.compressedBytes.hex)
    }
}

final class SNSCheckTests: XCTestCase {
    private func resolver(now: Int) -> SNSResolver {
        SNSResolver(configuration: .init(), pins: SNSMemoryPinStore(), now: { now })
    }

    func testAFreshAnswerPasses() async throws {
        let resolution = Live.resolution()
        let checked = try await resolver(now: resolution.expires - 60)
            .check(resolution, assurance: .verify)
        XCTAssertEqual(checked.address, "1NdU53DPAv7ftxoWDpM9c5P4nx1hFnJ6Ry")
        XCTAssertFalse(checked.fellBackToDomain)
    }

    func testAStaleAnswerIsRefused() async {
        let resolution = Live.resolution()
        do {
            _ = try await resolver(now: resolution.expires + 3600)
                .check(resolution, assurance: .verify)
            XCTFail("an expired answer must not pass")
        } catch let failure as SNS.Failure {
            XCTAssertEqual(failure, .expired)
            XCTAssertTrue(failure.isTemporary)
        } catch {
            XCTFail("unexpected error: \(error)")
        }
    }

    /// The unsigned `holder_address` disagreeing with the signed script is the
    /// exact shape of a swapped-payee attack.
    func testAnAddressThatContradictsTheScriptIsRefused() async {
        var resolution = Live.resolution()
        resolution.holderAddress = "1BgGZ9tcN4rm9KBzDn7KprQz87SZ26SAMH"
        do {
            _ = try await resolver(now: resolution.expires - 60)
                .check(resolution, assurance: .verify)
            XCTFail("a contradicting address must not pass")
        } catch let failure as SNS.Failure {
            XCTAssertEqual(failure, .addressMismatch)
        } catch {
            XCTFail("unexpected error: \(error)")
        }
    }

    func testTrustLevelSkipsTheSignatureButStillDerivesTheAddress() async throws {
        var resolution = Live.resolution()
        resolution.sig = "30450221" + String(repeating: "00", count: 32)
        let checked = try await resolver(now: resolution.expires + 999_999)
            .check(resolution, assurance: .trust)
        XCTAssertEqual(checked.address, "1NdU53DPAv7ftxoWDpM9c5P4nx1hFnJ6Ry")
    }

    func testProveWithoutAnUnspentCheckRefuses() async {
        let resolution = Live.resolution()
        do {
            _ = try await resolver(now: resolution.expires - 60)
                .check(resolution, assurance: .prove)
            XCTFail("prove without a way to check the outpoint must not pass")
        } catch let failure as SNS.Failure {
            XCTAssertEqual(failure, .outpointUnverified)
        } catch {
            XCTFail("unexpected error: \(error)")
        }
    }

    /// "Could not tell" is not a proof, so `prove` refuses — but it must not be
    /// reported as `spent`, which would accuse the name of having changed
    /// hands. Two different answers, two different words.
    func testUnknownSpentStatusRefusesWithoutClaimingSpent() async {
        let resolution = Live.resolution()
        let unsure = SNSResolver(configuration: .init(),
                                 pins: SNSMemoryPinStore(),
                                 unspentCheck: { _ in nil },
                                 now: { resolution.expires - 60 })
        do {
            _ = try await unsure.check(resolution, assurance: .prove)
            XCTFail("an unproved outpoint must not pass at prove")
        } catch let failure as SNS.Failure {
            XCTAssertEqual(failure, .outpointUnverified)
            XCTAssertNotEqual(failure, .staleOutpoint)
        } catch {
            XCTFail("unexpected error: \(error)")
        }
    }

    /// The same evidence must produce the same decision in both namespaces.
    func testUnknownIsStillFineBelowProve() async throws {
        let resolution = Live.resolution()
        let unsure = SNSResolver(configuration: .init(),
                                 pins: SNSMemoryPinStore(),
                                 unspentCheck: { _ in nil },
                                 now: { resolution.expires - 60 })
        let checked = try await unsure.check(resolution, assurance: .verify)
        XCTAssertEqual(checked.assurance, .verify)
    }

    func testAProvedOutpointPasses() async throws {
        let resolution = Live.resolution()
        let proved = SNSResolver(configuration: .init(),
                                 pins: SNSMemoryPinStore(),
                                 unspentCheck: { _ in true },
                                 now: { resolution.expires - 60 })
        let checked = try await proved.check(resolution, assurance: .prove)
        XCTAssertEqual(checked.assurance, .prove)
    }

    func testASpentOutpointIsRefused() async {
        let resolution = Live.resolution()
        let strict = SNSResolver(configuration: .init(),
                                 pins: SNSMemoryPinStore(),
                                 unspentCheck: { _ in false },
                                 now: { resolution.expires - 60 })
        do {
            _ = try await strict.check(resolution, assurance: .prove)
            XCTFail("a spent outpoint means the name changed hands")
        } catch let failure as SNS.Failure {
            XCTAssertEqual(failure, .staleOutpoint)
        } catch {
            XCTFail("unexpected error: \(error)")
        }
    }
}

final class SNSFailureTests: XCTestCase {
    /// A domain status and a signature status are different things and must
    /// never be shown with the same words.
    func testNotVerifiedIsPermanentAndNoHolderIsNot() {
        XCTAssertFalse(SNS.Failure.notVerified(nil).isTemporary)
        XCTAssertTrue(SNS.Failure.noHolder(nil).isTemporary)
    }

    func testCodesMapBackToThemselves() {
        for code in ["invalid_address", "unknown_tld", "not_registered",
                     "not_verified", "retired_tld", "no_holder", "rate_limited"] {
            XCTAssertEqual(SNS.Failure.from(code: code, message: nil).code, code)
        }
        XCTAssertEqual(SNS.Failure.from(code: "iets_nieuws", message: "x").code, "iets_nieuws")
    }

    func testTheResolverMessageIsPreferredOverOurs() {
        let message = "This name exists on-chain but is not (yet) ORDnet-verified."
        XCTAssertEqual(SNS.Failure.from(code: "not_verified", message: message).errorDescription,
                       message)
    }

    func testEveryFailureHasAReadableDescription() {
        let all: [SNS.Failure] = [
            .invalidAddress(nil), .unknownTLD(nil), .notRegistered(nil), .notVerified(nil),
            .retiredTLD(nil), .noHolder(nil), .rateLimited(nil), .server(code: "x", message: nil),
            .signatureInvalid, .untrustedSigner("03aa"), .expired, .malformedScript,
            .addressMismatch, .staleOutpoint, .outpointUnverified, .unreachable("offline"),
        ]
        for failure in all {
            XCTAssertFalse(failure.errorDescription?.isEmpty ?? true, "\(failure.code) needs a message")
        }
    }
}
