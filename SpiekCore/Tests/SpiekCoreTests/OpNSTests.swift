import XCTest
@testable import SpiekCore

final class OpNSNameTests: XCTestCase {
    func testGenesisIsTreeZero() {
        XCTAssertEqual(OpNS.genesis,
                       "58b7558ea379f24266c7e2f5fe321992ad9a724fd7a87423ba412677179ccb25_0")
        XCTAssertEqual(OpNS.genesisHeight, 806_214)
    }

    func testAcceptsTheProtocolCharacterSet() {
        XCTAssertTrue(OpNS.isValidName("alexander"))
        XCTAssertTrue(OpNS.isValidName("test-net-1"))
        XCTAssertTrue(OpNS.isValidName("t"))
        XCTAssertTrue(OpNS.isValidName("  ALEXANDER "))
    }

    /// A dot is impossible in this namespace, and everything outside a–z 0–9 -
    /// cannot be mined — which is why there is no look-alike warning here.
    func testRefusesAnythingOutsideIt() {
        XCTAssertFalse(OpNS.isValidName("alexander.web3"))
        XCTAssertFalse(OpNS.isValidName("alex ander"))
        XCTAssertFalse(OpNS.isValidName("alexander!"))
        XCTAssertFalse(OpNS.isValidName("\u{0430}lexander"), "Cyrillic cannot be mined")
        XCTAssertFalse(OpNS.isValidName("\u{1F600}"))
        XCTAssertFalse(OpNS.isValidName(""))
        XCTAssertFalse(OpNS.isValidName(String(repeating: "a", count: 65)))
    }

    /// The one rule that keeps the two namespaces apart.
    func testANameWithADotIsNeverOpNS() {
        XCTAssertFalse(OpNS.looksLikeOpNS("ordnet.web3"))
        XCTAssertFalse(OpNS.looksLikeOpNS("alexander@ordnet.web3"))
        XCTAssertTrue(OpNS.looksLikeOpNS("ordnet"))
    }

    func testTheTwoNamespacesDoNotOverlap() {
        let snsTlds = ["web3", "bitcoin", "crypto", "blockchain", "ordnet", "bsv"]
        for candidate in ["ordnet", "alexander", "t", "test-1", "ordnet.web3",
                          "alexander@ordnet.web3", "iemand@host", "1NdU53DPAv7ftxoWDpM9c5P4nx1hFnJ6Ry"] {
            let isSNS = SNS.looksLikeSNS(candidate, tlds: snsTlds)
            let isOpNS = OpNS.looksLikeOpNS(candidate)
            XCTAssertFalse(isSNS && isOpNS, "\(candidate) must not be claimed by both")
        }
        // An address belongs to neither namespace.
        XCTAssertFalse(SNS.looksLikeSNS("1NdU53DPAv7ftxoWDpM9c5P4nx1hFnJ6Ry", tlds: snsTlds))
        XCTAssertFalse(OpNS.looksLikeOpNS("1NdU53DPAv7ftxoWDpM9c5P4nx1hFnJ6Ry"))
    }

    func testPaymailFormIsRecognisedButNeverAnAddress() throws {
        // XCTUnwrap already strips one level of optionality, so this is a
        // plain Paymail — not a Paymail??.
        let paymail = try XCTUnwrap(OpNS.paymail("alexander@example.com"))
        XCTAssertEqual(paymail.name, "alexander")
        XCTAssertEqual(paymail.host, "example.com")
        XCTAssertNil(OpNS.paymail("alexander"))
        XCTAssertNil(OpNS.paymail("@host"))
        XCTAssertNil(OpNS.paymail("alexander@"))
    }

    /// Base58 is a subset of the OpNS character set, so a lowercased address
    /// reads as a valid name. Only the checksum tells them apart, and getting
    /// this wrong would answer every pasted address with "that looks like an
    /// OpNS name".
    func testARealAddressIsNotMistakenForAName() {
        XCTAssertFalse(OpNS.looksLikeOpNS("1NdU53DPAv7ftxoWDpM9c5P4nx1hFnJ6Ry"))
        XCTAssertFalse(OpNS.looksLikeOpNS("1BgGZ9tcN4rm9KBzDn7KprQz87SZ26SAMH"))
        // A near-miss with a broken checksum is not an address, so it is a name.
        XCTAssertTrue(OpNS.looksLikeOpNS("1ndu53dpav7ftxowdpm9c5p4nx1hfnj6ry"))
    }

    func testHalfFormedPaymailsAreNotNames() {
        XCTAssertFalse(OpNS.looksLikeOpNS("alexander@"))
        XCTAssertFalse(OpNS.looksLikeOpNS("@host"))
    }

    func testIntermediateNamesAreEveryPrefix() {
        XCTAssertEqual(OpNS.intermediateNames(of: "testnet"),
                       ["t", "te", "tes", "test", "testn", "testne"])
        XCTAssertEqual(OpNS.intermediateNames(of: "t"), [])
    }
}

/// A directory that answers from a script, so the rules can be exercised
/// without inventing a wire format for an endpoint that is not reachable.
private actor ScriptedDirectory: OpNSDirectory {
    var answer: OpNS.Name?
    var failure: Error?
    var owned: [OpNS.Name] = []

    init(answer: OpNS.Name? = nil, failure: Error? = nil) {
        self.answer = answer
        self.failure = failure
    }

    func lookUp(name: String) async throws -> OpNS.Name? {
        if let failure { throw failure }
        return answer
    }

    func names(ownedBy address: String) async throws -> [OpNS.Name] { owned }
}

final class OpNSResolverTests: XCTestCase {
    private let holder = "1NdU53DPAv7ftxoWDpM9c5P4nx1hFnJ6Ry"
    private let txid = "5bebe49ade63904afd9ff4afb6b2562897b788c5680fba5f37cbbbe47897948f"

    /// A real transaction paying the holder address at vout 0, so the holder
    /// can be recomputed from the chain exactly as the resolver does it.
    private var rawTx: String {
        let hash = Address.hash160(from: holder) ?? []
        let script = Script.p2pkh(hash160: hash)
        var bytes: [UInt8] = [0x01, 0x00, 0x00, 0x00]          // version
        bytes += [0x00]                                        // 0 inputs
        bytes += [0x01]                                        // 1 output
        bytes += [0x01, 0, 0, 0, 0, 0, 0, 0]                   // 1 satoshi
        bytes += [UInt8(script.count)] + script
        bytes += [0x00, 0x00, 0x00, 0x00]                      // locktime
        return bytes.hex
    }

    private func name(_ value: String, fallback: Bool = false,
                      ambiguous: Bool = false, owner: String? = nil,
                      lineage: Bool = true) -> OpNS.Name {
        OpNS.Name(name: value,
                  originTxid: String(repeating: "de", count: 32),
                  originVout: 2,
                  currentTxid: txid,
                  currentVout: 0,
                  ownerAddress: owner ?? holder,
                  height: 900_000,
                  isFallback: fallback,
                  ambiguous: ambiguous,
                  lineageVerified: lineage)
    }

    private func resolver(_ answer: OpNS.Name?,
                          outpoint: OutpointState = .unspent,
                          chainReadable: Bool = true) -> OpNSResolver {
        let hex = rawTx
        return OpNSResolver(
            directory: ScriptedDirectory(answer: answer),
            oracle: StaticOutpointOracle(fallback: outpoint),
            rawTransaction: chainReadable ? { _ in hex } : { _ in nil }
        )
    }

    func testAnExactMatchWithAnUnspentOutpointResolves() async throws {
        let resolved = try await resolver(name("testnet")).resolve("testnet")
        XCTAssertEqual(resolved.name.name, "testnet")
        XCTAssertEqual(resolved.outpointState, .unspent)
        XCTAssertEqual(resolved.verifiedHolder, holder)
        XCTAssertEqual(resolved.payableAddress, holder)
        XCTAssertEqual(resolved.intermediates, ["t", "te", "tes", "test", "testn", "testne"])
    }

    /// The most important rule in the whole briefing: a near miss is a
    /// different name and must never be paid silently.
    func testAFallbackAnswerIsRefused() async {
        await assertFails(resolver(name("testnet", fallback: true)), "testne", expecting: "fallback")
    }

    /// Even without the flag, an answer for a different name is a fallback.
    func testAnAnswerForAnotherNameIsRefused() async {
        await assertFails(resolver(name("testnet")), "testne", expecting: "fallback")
    }

    /// The index saying it cannot decide is not a maybe.
    func testAnAmbiguousNameIsRefused() async {
        await assertFails(resolver(name("testnet", ambiguous: true)), "testnet", expecting: "ambiguous")
    }

    /// The chain is the authority. If the index names a different holder than
    /// the locking script does, nothing is sent.
    func testAHolderTheChainDisagreesWithIsRefused() async {
        let liar = name("testnet", owner: "1BgGZ9tcN4rm9KBzDn7KprQz87SZ26SAMH")
        await assertFails(resolver(liar), "testnet", expecting: "holder_disagrees")
    }

    func testAnUnreadableChainRefusesPaymentButNotDisplay() async throws {
        let unreadable = resolver(name("testnet"), chainReadable: false)
        await assertFails(unreadable, "testnet", expecting: "holder_unreadable")

        let shown = try await unreadable.resolve("testnet", forPayment: false)
        XCTAssertNil(shown.verifiedHolder)
        XCTAssertNil(shown.payableAddress, "nothing may be paid without a verified holder")
    }

    /// Fail closed on lineage: without the index's certificate that the name
    /// traces back to the root, it cannot vouch that this is the canonical name
    /// rather than something that merely spells the same.
    func testAnUnverifiedLineageIsRefusedForPayment() async {
        await assertFails(resolver(name("testnet", lineage: false)),
                          "testnet", expecting: "lineage_unverified")
    }

    /// It is a refusal, not a verdict — the indexer runs periodically and a
    /// freshly mined name can be certified on the next pass.
    func testAnUnverifiedLineageIsTemporaryAndStillDisplayable() async throws {
        XCTAssertTrue(OpNS.Failure.lineageUnverified("x").isTemporary)
        let shown = try await resolver(name("testnet", lineage: false))
            .resolve("testnet", forPayment: false)
        XCTAssertFalse(shown.name.lineageVerified)
        XCTAssertEqual(shown.name.name, "testnet")
    }

    /// A name's origin is its own mint transaction, never the tree-0 genesis.
    func testOriginIsTheNameSOwnMintOutpoint() {
        let record = name("benn")
        XCTAssertEqual(record.origin, String(repeating: "de", count: 32) + ":2")
        XCTAssertNotEqual(record.origin, OpNS.genesis)
    }

    func testASpentOutpointIsRefused() async {
        await assertFails(resolver(name("testnet"), outpoint: .spent),
                          "testnet", expecting: "outpoint_spent")
    }

    /// An oracle that could not answer has told us nothing. It must not read as
    /// "spent", and it must not wave a payment through either.
    func testAnUnknownSpentStatusIsRefusedWithoutClaimingSpent() async {
        await assertFails(resolver(name("testnet"), outpoint: .unknown),
                          "testnet", expecting: "outpoint_unknown")
    }

    func testDisplayOnlyResolutionSkipsTheOutpointRequirement() async throws {
        let resolved = try await resolver(name("testnet"), outpoint: .unknown)
            .resolve("testnet", forPayment: false)
        XCTAssertEqual(resolved.outpointState, .unknown)
        XCTAssertNil(resolved.payableAddress)
    }

    func testAPaymailIsNeverResolvedToAnAddress() async {
        await assertFails(resolver(name("alexander")), "alexander@example.com",
                          expecting: "paymail_not_payable")
    }

    func testAnSNSNameIsRefusedOutright() async {
        await assertFails(resolver(name("ordnet")), "ordnet.web3", expecting: "not_an_opns_name")
    }

    func testAnUnminedNameIsNotFound() async {
        await assertFails(resolver(nil), "bestaatniet", expecting: "not_found")
    }

    func testEveryFailureHasAReadableDescription() {
        let all: [OpNS.Failure] = [
            .notAnOpNSName, .notFound("x"), .fallback(asked: "a", got: "b"),
            .paymailNotPayable(.init(name: "a", host: "h")), .ambiguous("x"),
            .lineageUnverified("x"),
            .genesisMismatch(expected: "a", reported: "b"), .rootNotReported,
            .holderDisagrees(name: "x", index: "1a", chain: "1b"), .holderUnreadable("x"),
            .outpointSpent("t:0"), .outpointUnknown, .directoryUnavailable("offline"),
        ]
        for failure in all {
            XCTAssertFalse(failure.errorDescription?.isEmpty ?? true, "\(failure.code) needs a message")
        }
        // A withheld root is a refusal, not a hiccup: it must never be
        // classified as something that clears itself by waiting.
        XCTAssertFalse(OpNS.Failure.rootNotReported.isTemporary)
        XCTAssertTrue(OpNS.Failure.outpointUnknown.isTemporary)
        // Looking a sold name up again gives the right answer, so it counts as
        // temporary — exactly as SNS classes the same fact.
        XCTAssertTrue(OpNS.Failure.outpointSpent("t:0").isTemporary)
        XCTAssertTrue(SNS.Failure.staleOutpoint.isTemporary)
        XCTAssertFalse(OpNS.Failure.fallback(asked: "a", got: "b").isTemporary,
                       "a near miss does not become the right name by waiting")
        XCTAssertFalse(OpNS.Failure.ambiguous("x").isTemporary)
        // A non-standard script stays unreadable, and a stale index keeps
        // disagreeing — neither is fixed by waiting.
        XCTAssertFalse(OpNS.Failure.holderUnreadable("x").isTemporary)
        XCTAssertFalse(OpNS.Failure.holderDisagrees(name: "x", index: "1a", chain: "1b").isTemporary)
    }

    func testHolderIsReadFromTheLockingScript() {
        XCTAssertEqual(OpNS.holderAddress(rawTxHex: rawTx, vout: 0), holder)
        XCTAssertNil(OpNS.holderAddress(rawTxHex: rawTx, vout: 7), "no such output")
        XCTAssertNil(OpNS.holderAddress(rawTxHex: "not hex", vout: 0))
    }

    private func assertFails(_ resolver: OpNSResolver,
                             _ input: String,
                             expecting code: String,
                             file: StaticString = #filePath,
                             line: UInt = #line) async {
        do {
            _ = try await resolver.resolve(input)
            XCTFail("expected \(code)", file: file, line: line)
        } catch let failure as OpNS.Failure {
            XCTAssertEqual(failure.code, code, file: file, line: line)
        } catch {
            XCTFail("unexpected error: \(error)", file: file, line: line)
        }
    }
}

final class OutpointOracleTests: XCTestCase {
    func testAStaticOracleAnswersFromItsTable() async {
        let oracle = StaticOutpointOracle(answers: ["aa:0": .spent, "bb:1": .unspent],
                                          fallback: .unknown)
        var state = await oracle.state(txid: "aa", vout: 0)
        XCTAssertEqual(state, .spent)
        state = await oracle.state(txid: "bb", vout: 1)
        XCTAssertEqual(state, .unspent)
        state = await oracle.state(txid: "cc", vout: 0)
        XCTAssertEqual(state, .unknown, "an outpoint nobody asked about is unknown, not unspent")
    }

    /// The three states must stay distinct: collapsing unknown into either of
    /// the others is how a good name gets refused or a sold one gets paid.
    func testTheThreeStatesAreDistinct() {
        XCTAssertNotEqual(OutpointState.unknown, .spent)
        XCTAssertNotEqual(OutpointState.unknown, .unspent)
        XCTAssertNotEqual(OutpointState.spent, .unspent)
    }
}

/// A stub transport, so the index's own transport rules can be exercised
/// without a network — including the ones that must fail closed.
private final class StubProtocol: URLProtocol {
    nonisolated(unsafe) static var status = 200
    nonisolated(unsafe) static var body = Data()

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        let response = HTTPURLResponse(url: request.url!,
                                       statusCode: Self.status,
                                       httpVersion: nil,
                                       headerFields: nil)!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Self.body)
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}
}

final class OpNSIndexStatusTests: XCTestCase {
    private func index(status: Int, json: String) -> OpNSIndex {
        StubProtocol.status = status
        StubProtocol.body = Data(json.utf8)
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [StubProtocol.self]
        return OpNSIndex(session: URLSession(configuration: configuration))
    }

    func testAMatchingRootPasses() async throws {
        let json = "{\"ok\":true,\"genesis\":\"\(OpNS.genesis)\",\"names\":14170,\"ambiguous\":90}"
        let status = try await index(status: 200, json: json).status()
        XCTAssertEqual(status.names, 14170)
        XCTAssertEqual(status.ambiguous, 90)
    }

    /// The same outpoint written with a different separator is the same tree.
    /// A fail-closed gate must not trip over punctuation.
    func testASeparatorDifferenceIsNotAMismatch() async throws {
        let punctuated = OpNS.genesis.replacingOccurrences(of: "_", with: ":")
        let json = "{\"ok\":true,\"genesis\":\"\(punctuated)\"}"
        _ = try await index(status: 200, json: json).status()
    }

    func testADifferentRootIsRefused() async {
        let json = "{\"ok\":true,\"genesis\":\"\(String(repeating: "ff", count: 32))_0\"}"
        await assertStatusFails(index(status: 200, json: json), expecting: "genesis_mismatch")
    }

    /// The important one: an index that says nothing about its root has
    /// confirmed nothing, and silence must not read as agreement.
    ///
    /// Its own code, not `directory_unavailable`, and that distinction is
    /// load-bearing: the app waves transport failures through so one unreachable
    /// status endpoint cannot take every lookup down, and a withheld root must
    /// not be able to ride in on that exemption.
    func testAMissingRootIsRefusedRatherThanAssumed() async {
        await assertStatusFails(index(status: 200, json: "{\"ok\":true}"),
                                expecting: "root_not_reported")
    }

    /// `last_run` is a string timestamp. Decoding it as a number threw, and a
    /// synthesised decoder fails the whole envelope on one bad field — which is
    /// how a cosmetic counter took every OpNS lookup down with it. Nothing here
    /// except the root may fail the decode, whatever type it arrives as.
    func testACosmeticFieldCannotFailTheStatusCheck() async throws {
        let json = """
        {"ok":true,"genesis":"\(OpNS.genesis)","last_run":"2026-08-04 08:02:20",\
        "names":"14170","ambiguous":null}
        """
        let status = try await index(status: 200, json: json).status()
        XCTAssertEqual(status.lastRun, "2026-08-04 08:02:20")
    }

    /// SQL-backed indexes serialise booleans as 0/1 and numbers as strings.
    /// One of those in one record must not turn an existing name into
    /// "the index could not be reached".
    func testARecordSurvivesLooselyTypedFields() async throws {
        let json = """
        {"ok":true,"results":[{"name":"benn","owner_address":"1abc",\
        "current_txid":"aa","current_vout":"1","ambiguous":0,"lineage_verified":1,"height":"806214"}]}
        """
        let found = try await index(status: 200, json: json).lookUp(name: "benn")
        XCTAssertEqual(found?.currentVout, 1)
        XCTAssertEqual(found?.lineageVerified, true)
        XCTAssertEqual(found?.ambiguous, false)
    }

    /// One unusable record must not wipe the other names in the list.
    func testOneBadRecordDoesNotTakeTheListWithIt() async throws {
        let json = """
        {"ok":true,"results":[{"owner_address":"1abc","current_txid":"aa","current_vout":0},\
        {"name":"benn","owner_address":"1abc","current_txid":"bb","current_vout":0}]}
        """
        let held = try await index(status: 200, json: json).names(ownedBy: "1abc")
        XCTAssertEqual(held.map(\.name), ["benn"])
    }

    /// And when nothing survives, that is reported as an unreadable answer —
    /// never as "the name does not exist", which is a claim about the chain.
    func testAnUnreadableAnswerIsNotReportedAsAMissingName() async {
        let json = "{\"ok\":true,\"results\":[{\"owner_address\":\"1abc\"}]}"
        do {
            _ = try await index(status: 200, json: json).lookUp(name: "benn")
            XCTFail("expected directory_unavailable")
        } catch let failure as OpNS.Failure {
            XCTAssertEqual(failure.code, "directory_unavailable")
        } catch {
            XCTFail("unexpected error: \(error)")
        }
    }

    /// Every field of the envelope is optional, so an error body decodes
    /// perfectly well. The status code and `ok` are what stop it.
    func testAnErrorBodyIsNotMistakenForAnAnswer() async {
        await assertStatusFails(index(status: 404, json: "{\"ok\":false,\"error\":\"not found\"}"),
                                expecting: "directory_unavailable")
    }

    func testARefusalWithA200IsStillARefusal() async {
        await assertStatusFails(index(status: 200, json: "{\"ok\":false,\"error\":\"nope\"}"),
                                expecting: "directory_unavailable")
    }

    private func assertStatusFails(_ index: OpNSIndex,
                                   expecting code: String,
                                   file: StaticString = #filePath,
                                   line: UInt = #line) async {
        do {
            _ = try await index.status()
            XCTFail("expected \(code)", file: file, line: line)
        } catch let failure as OpNS.Failure {
            XCTAssertEqual(failure.code, code, file: file, line: line)
        } catch {
            XCTFail("unexpected error: \(error)", file: file, line: line)
        }
    }
}

final class OpNSOutpointComparisonTests: XCTestCase {
    func testSeparatorAndCaseAreIgnored() {
        XCTAssertTrue(OpNS.sameOutpoint("ABCD_0", "abcd:0"))
        XCTAssertTrue(OpNS.sameOutpoint("abcd_00", "abcd:0"), "leading zeroes are the same output")
        XCTAssertFalse(OpNS.sameOutpoint("abcd_0", "abcd_1"))
        XCTAssertFalse(OpNS.sameOutpoint("abcd_0", "efgh_0"))
        // `Int("x") == Int("y")` is nil == nil, which is true — two nonsense
        // indices must not compare equal.
        XCTAssertFalse(OpNS.sameOutpoint("abcd_x", "abcd_y"))
        XCTAssertFalse(OpNS.sameOutpoint("abcd_x", "abcd_0"))
    }

    /// Without a separator there is nothing to parse, so it falls back to a
    /// plain comparison rather than declaring a match.
    func testAMalformedOutpointFallsBackToEquality() {
        XCTAssertTrue(OpNS.sameOutpoint("abcd", "ABCD"))
        XCTAssertFalse(OpNS.sameOutpoint("abcd", "abcd_0"))
        // The fallback must see the same trimming the parser does.
        XCTAssertTrue(OpNS.sameOutpoint("  abcd  ", "ABCD"))
        XCTAssertTrue(OpNS.sameOutpoint("  abcd_0 ", "ABCD:0"))
    }
}
