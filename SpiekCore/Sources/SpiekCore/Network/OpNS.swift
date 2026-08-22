import Foundation

/// OpNS — bare names on 1Sat Ordinals, mined with proof of work.
///
/// A different namespace from SNS, and the two must never be confused: an OpNS
/// name has **no dot** and cannot have one, while an SNS name always does. That
/// single rule is what keeps a payment from being sent to the wrong service, so
/// it is enforced here rather than left to a UI check.
///
/// This file holds only what the protocol fixes: what a name may look like, how
/// to tell the two namespaces apart, and what may and may not be paid. The wire
/// format of the index API is deliberately absent — see `OpNSDirectory`.
public enum OpNS {
    /// Tree 0 — the root of the whole namespace, pinned here rather than taken
    /// from the index. The index reports the same value from `/status`, and a
    /// disagreement is worth surfacing, but a pin that the server can move is
    /// not a pin.
    ///
    /// Note this is *not* a name's own origin: every name carries its own mint
    /// outpoint, and none of them is this value.
    public static let genesis =
        "58b7558ea379f24266c7e2f5fe321992ad9a724fd7a87423ba412677179ccb25_0"
    public static let genesisHeight = 806_214

    /// The protocol allows only these. No dots, no emoji, no mixed scripts —
    /// so unlike SNS there is no look-alike problem to warn about, because the
    /// characters that would cause one cannot be minted in the first place.
    static let allowed = Set("abcdefghijklmnopqrstuvwxyz0123456789-")

    /// Outpoints are written both `txid_vout` and `txid:vout` in the wild.
    /// A fail-closed gate must compare the outpoint, not the punctuation.
    public static func sameOutpoint(_ lhs: String, _ rhs: String) -> Bool {
        // Trimmed once, up front: the fallback below must compare the same
        // strings the parser saw, or " abcd" and "ABCD" would differ while
        // " abcd_0" and "ABCD_0" match.
        let left0 = lhs.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let right0 = rhs.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()

        func parts(_ cleaned: String) -> (String, String)? {
            guard let separator = cleaned.lastIndex(where: { $0 == "_" || $0 == ":" }) else {
                return nil
            }
            return (String(cleaned[cleaned.startIndex..<separator]),
                    String(cleaned[cleaned.index(after: separator)...]))
        }
        guard let left = parts(left0), let right = parts(right0) else {
            return left0 == right0
        }
        // Both indices must actually parse. `Int("x") == Int("y")` is `nil ==
        // nil`, which is *true* — and would quietly match two outpoints whose
        // indices are both nonsense.
        guard let leftIndex = Int(left.1), let rightIndex = Int(right.1) else { return false }
        return left.0 == right.0 && leftIndex == rightIndex
    }

    public static func normalize(_ input: String) -> String {
        input.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    }

    public static func isValidName(_ input: String) -> Bool {
        let name = normalize(input)
        guard !name.isEmpty, name.count <= 64 else { return false }
        return name.allSatisfy { allowed.contains($0) }
    }

    /// A bare name with no dot. Anything containing a dot belongs to SNS and is
    /// refused here even if the rest of it is valid.
    ///
    /// A plain BSV address is refused too. Base58 is a subset of this character
    /// set, so `1NdU53DPAv7ftxoWDpM9c5P4nx1hFnJ6Ry` lowercases into a perfectly
    /// legal-looking name — and without this check, pasting an address would be
    /// answered with "that looks like an OpNS name". The checksum is what tells
    /// them apart, and an address is always an address.
    public static func looksLikeOpNS(_ input: String) -> Bool {
        let candidate = normalize(input)
        guard !candidate.contains(".") else { return false }
        guard !Address.isValid(input.trimmingCharacters(in: .whitespacesAndNewlines)) else {
            return false
        }
        // `name@host` is an OpNS paymail form. It is recognised so it can be
        // named, but it is never an address to pay — see `paymail`.
        guard candidate.contains("@") else { return isValidName(candidate) }
        return paymail(candidate) != nil
    }

    public struct Paymail: Sendable, Equatable {
        public var name: String
        public var host: String
    }

    /// Splits `name@host`. Any host may serve any name and the on-chain binding
    /// dies when the name is transferred, so this exists to *label* the form —
    /// never to resolve it into somewhere to send money.
    public static func paymail(_ input: String) -> Paymail? {
        let candidate = normalize(input)
        guard candidate.contains("@"), !candidate.contains(".@") else { return nil }
        let parts = candidate.split(separator: "@", maxSplits: 1)
        guard parts.count == 2, isValidName(String(parts[0])), !parts[1].isEmpty else { return nil }
        return Paymail(name: String(parts[0]), host: String(parts[1]))
    }

    /// The shorter names that exist as a by-product of pay-per-letter mining.
    /// `alexander` implies `a`, `al`, `ale`… each a separate name that may have
    /// a different owner — which is why a payment screen must always show the
    /// exact name it resolved next to the address.
    public static func intermediateNames(of input: String) -> [String] {
        let name = normalize(input)
        guard name.count > 1 else { return [] }
        return (1..<name.count).map { String(name.prefix($0)) }
    }

    /// A name as the index describes it. Only the fields a wallet actually
    /// needs; anything else the API returns is not this type's business.
    public struct Name: Sendable, Equatable {
        public var name: String
        /// The mint transaction of *this* name — its identity and the way to
        /// trace it. Not the tree-0 genesis: every name has a different one.
        public var originTxid: String?
        public var originVout: UInt32?
        public var currentTxid: String
        public var currentVout: UInt32
        /// What the index believes. Never paid to directly — the address is
        /// recomputed from the chain and must agree with this.
        public var ownerAddress: String
        public var height: Int?
        /// True when the index answered with a *different* name than the one
        /// asked for. Never a match.
        public var isFallback: Bool
        /// The index cannot decide who holds this name. Not safe to pay.
        public var ambiguous: Bool
        /// The index certifies that this name traces back through an unbroken
        /// chain of valid mints to the tree-0 genesis. It says nothing about
        /// who holds it now — that is `currentTxid`/`currentVout` plus the
        /// spent check. `false` is refused for payment, but it is not
        /// permanent: a freshly mined name can be certified on the next run.
        public var lineageVerified: Bool

        public init(name: String,
                    originTxid: String? = nil, originVout: UInt32? = nil,
                    currentTxid: String, currentVout: UInt32,
                    ownerAddress: String, height: Int? = nil, isFallback: Bool = false,
                    ambiguous: Bool = false, lineageVerified: Bool = false) {
            self.name = name
            self.originTxid = originTxid
            self.originVout = originVout
            self.currentTxid = currentTxid
            self.currentVout = currentVout
            self.ownerAddress = ownerAddress
            self.height = height
            self.isFallback = isFallback
            self.ambiguous = ambiguous
            self.lineageVerified = lineageVerified
        }

        /// The mint outpoint, when the index reported one.
        public var origin: String? {
            guard let originTxid, let originVout else { return nil }
            return "\(originTxid):\(originVout)"
        }

        public var outpoint: String { "\(currentTxid):\(currentVout)" }
    }

    /// `Sendable` because it is carried out of a `Task` — every payload here is
    /// a String or a struct of Strings.
    public enum Failure: Error, LocalizedError, Equatable, Sendable {
        case notAnOpNSName
        case notFound(String)
        /// The index answered with a near miss. This is the single most
        /// dangerous case: treating it as a hit sends money to a name the user
        /// never typed.
        case fallback(asked: String, got: String)
        case paymailNotPayable(OpNS.Paymail)
        case ambiguous(String)
        case lineageUnverified(String)
        case genesisMismatch(expected: String, reported: String)
        /// The index answered `/status` without saying which root it serves.
        /// Its own failure case, because "would not say" and "could not be
        /// reached" are different facts and only one of them may be waved
        /// through: an index that withholds the root is exactly what someone
        /// serving a *different* tree would look like.
        case rootNotReported
        case holderDisagrees(name: String, index: String, chain: String)
        case holderUnreadable(String)
        case outpointSpent(String)
        case outpointUnknown
        case directoryUnavailable(String)

        public var code: String {
            switch self {
            case .notAnOpNSName: return "not_an_opns_name"
            case .notFound: return "not_found"
            case .fallback: return "fallback"
            case .paymailNotPayable: return "paymail_not_payable"
            case .ambiguous: return "ambiguous"
            case .lineageUnverified: return "lineage_unverified"
            case .genesisMismatch: return "genesis_mismatch"
            case .rootNotReported: return "root_not_reported"
            case .holderDisagrees: return "holder_disagrees"
            case .holderUnreadable: return "holder_unreadable"
            case .outpointSpent: return "outpoint_spent"
            case .outpointUnknown: return "outpoint_unknown"
            case .directoryUnavailable: return "directory_unavailable"
            }
        }

        public var isTemporary: Bool {
            switch self {
            // A sold name is temporary in the sense that matters: looking it up
            // again gives the right answer. SNS classes the same fact the same
            // way, and the two namespaces must not disagree about what a spent
            // outpoint means.
            case .outpointSpent, .outpointUnknown, .directoryUnavailable, .lineageUnverified:
                return true
            default: return false
            }
        }

        public var errorDescription: String? {
            switch self {
            case .notAnOpNSName:
                return "An OpNS name has no dot and uses only a–z, 0–9 and a hyphen."
            case let .notFound(name):
                return "\u{201C}\(name)\u{201D} has not been mined."
            case let .fallback(asked, got):
                return "\u{201C}\(asked)\u{201D} does not exist. The closest mined name is \u{201C}\(got)\u{201D} — a different name, with possibly a different owner."
            case let .paymailNotPayable(paymail):
                return "\(paymail.name)@\(paymail.host) exists as a paymail, but any host can serve any name and the binding dies when the name is sold. Use the name on its own."
            case let .ambiguous(name):
                return "The index cannot say for certain who holds \u{201C}\(name)\u{201D}, so it is not safe to send anything there."
            case let .lineageUnverified(name):
                return "The index has not yet traced \u{201C}\(name)\u{201D} back to the root of the tree, so it cannot vouch that the name is canonical. Nothing was sent. This often clears once the indexer catches up \u{2014} try again later."
            case let .genesisMismatch(expected, reported):
                return "The index reports a different root for the namespace than this app has pinned (\(reported) instead of \(expected)). Refusing to resolve anything against it."
            case .rootNotReported:
                return "The index will not say which root of the namespace it serves, so nothing it answers can be trusted. Refusing to resolve anything against it."
            case let .holderDisagrees(name, index, chain):
                return "The index and the chain disagree about who holds \u{201C}\(name)\u{201D} — the index says \(index), the chain says \(chain). Nothing was sent."
            case let .holderUnreadable(name):
                return "Could not read the holder of \u{201C}\(name)\u{201D} from the chain — it may not be held in a standard payment script."
            case let .outpointSpent(outpoint):
                return "This name has changed hands since it was looked up (\(outpoint) is spent). Look it up again."
            case .outpointUnknown:
                return "Could not confirm who holds this name right now — the index either could not be reached or shows nothing at that address. Look it up again before sending anything."
            case let .directoryUnavailable(reason):
                return "The OpNS index could not be reached: \(reason)"
            }
        }
    }
}

/// The index that knows which names exist and who holds them.
///
/// A protocol with no shipped implementation on purpose. The endpoint given in
/// the briefing — `https://search.ordnet.io/api/opns/…` — answers 404, so the
/// wire format is not known and has not been guessed. Everything that does not
/// depend on it (validation, category separation, the fallback rule and the
/// outpoint proof) is finished and tested; filling this in is a small, isolated
/// piece once the real path and field names are confirmed.
public protocol OpNSDirectory: Sendable {
    /// Must query with an exact match. A near miss is returned with
    /// `isFallback` set, never silently as a hit.
    func lookUp(name: String) async throws -> OpNS.Name?
    /// Every OpNS name held by an address, for a portfolio view.
    func names(ownedBy address: String) async throws -> [OpNS.Name]
}

/// Turns a typed name into an address it is safe to write to.
///
/// The rules it enforces, in order: the input really is an OpNS name; the
/// answer is an exact match and not a fallback; and the outpoint the index
/// names is still unspent at the address it claims. Any of those failing stops
/// the flow — none of them is a warning.
///
/// Assumes SNS was ruled out first. `mailbox@naam.tld` and `naam@host` are
/// syntactically identical, and only the source they belong to tells them
/// apart, so the caller triages on SNS before reaching here.
public struct OpNSResolver: Sendable {
    private let directory: any OpNSDirectory
    private let oracle: (any OutpointOracle)?
    /// Fetches a raw transaction so the holder can be recomputed from the
    /// chain. Without it the index's word is all there is.
    private let rawTransaction: (@Sendable (String) async -> String?)?

    public init(directory: any OpNSDirectory,
                oracle: (any OutpointOracle)? = nil,
                rawTransaction: (@Sendable (String) async -> String?)? = nil) {
        self.directory = directory
        self.oracle = oracle
        self.rawTransaction = rawTransaction
    }

    public struct Resolved: Sendable, Equatable {
        public var name: OpNS.Name
        /// The address recomputed from the locking script of the current
        /// outpoint, when that was possible. This — not `name.ownerAddress` —
        /// is what may be paid.
        public var verifiedHolder: String?
        public var outpointState: OutpointState
        /// The shorter names that also exist as separate mints. Not an error —
        /// context, so the exact name being paid is unmistakable.
        public var intermediates: [String]

        /// The only address this resolution allows anything to be sent to.
        public var payableAddress: String? {
            outpointState == .unspent ? verifiedHolder : nil
        }
    }

    /// Looks a name up and checks everything that can be checked.
    ///
    /// - Parameter forPayment: when true the result must be safe to send to —
    ///   exact match, not ambiguous, holder recomputed from the chain and in
    ///   agreement with the index, and the outpoint proved unspent. Anything
    ///   short of that throws. When false the same checks run but only report.
    public func resolve(_ input: String, forPayment: Bool = true) async throws -> Resolved {
        if let paymail = OpNS.paymail(input) {
            throw OpNS.Failure.paymailNotPayable(paymail)
        }
        guard OpNS.looksLikeOpNS(input) else { throw OpNS.Failure.notAnOpNSName }

        let asked = OpNS.normalize(input)
        // Belt and braces: `looksLikeOpNS` already rejects the half-formed
        // paymails, and this restates the invariant right before the index is
        // touched. Nothing malformed may ever be queried, because a near-miss
        // answer to a malformed question is the wrong thing to show a user.
        guard OpNS.isValidName(asked) else { throw OpNS.Failure.notAnOpNSName }

        let found: OpNS.Name?
        do {
            found = try await directory.lookUp(name: asked)
        } catch let failure as OpNS.Failure {
            throw failure
        } catch {
            throw OpNS.Failure.directoryUnavailable(error.localizedDescription)
        }
        guard let name = found else { throw OpNS.Failure.notFound(asked) }

        // The rule that matters most: a near miss is a different name, with
        // possibly a different owner.
        guard !name.isFallback, OpNS.normalize(name.name) == asked else {
            throw OpNS.Failure.fallback(asked: asked, got: name.name)
        }
        guard !name.ambiguous else { throw OpNS.Failure.ambiguous(name.name) }

        // Fail closed on lineage. The index certifies that the name traces back
        // through unbroken mints to the root; without that certificate it
        // cannot vouch that this is the canonical name rather than something
        // that merely spells the same. The worst this costs is a false
        // negative on a freshly mined name — "try again later" — and never a
        // payment to the wrong party.
        if forPayment, !name.lineageVerified {
            throw OpNS.Failure.lineageUnverified(name.name)
        }

        // The index says who holds it; the chain decides. Read the locking
        // script of the current outpoint and derive the address from that.
        var verified: String?
        if let rawTransaction {
            if let hex = await rawTransaction(name.currentTxid),
               let address = OpNS.holderAddress(rawTxHex: hex, vout: name.currentVout) {
                verified = address
                guard address == name.ownerAddress else {
                    throw OpNS.Failure.holderDisagrees(name: name.name,
                                                       index: name.ownerAddress,
                                                       chain: address)
                }
            } else if forPayment {
                throw OpNS.Failure.holderUnreadable(name.name)
            }
        } else if forPayment {
            throw OpNS.Failure.holderUnreadable(name.name)
        }

        var state = OutpointState.unknown
        if let oracle {
            state = await oracle.state(txid: name.currentTxid, vout: name.currentVout)
        }
        if forPayment {
            switch state {
            case .spent: throw OpNS.Failure.outpointSpent(name.outpoint)
            case .unknown: throw OpNS.Failure.outpointUnknown
            case .unspent: break
            }
        }

        return Resolved(name: name,
                        verifiedHolder: verified,
                        outpointState: state,
                        intermediates: OpNS.intermediateNames(of: name.name))
    }
}

public extension OpNS {
    /// The address that owns an outpoint, read from the transaction itself.
    /// The raw hex is the authority; an index is only ever a hint.
    static func holderAddress(rawTxHex: String, vout: UInt32) -> String? {
        guard let transaction = Transaction.parse(hex: rawTxHex),
              vout < UInt32(transaction.outputs.count),
              let hash = Script.p2pkhHash(from: transaction.outputs[Int(vout)].lockingScript)
        else { return nil }
        return Address.encode(hash160: hash)
    }
}
