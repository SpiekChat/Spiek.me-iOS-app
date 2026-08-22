import Foundation

/// The ORDnet SNS resolver: turns a name like `ordnet.web3`, or a mailbox
/// address like `alexander@ordnet.web3`, into the on-chain holder — in one
/// *signed* answer.
///
/// The answer is never trusted, it is recomputed. The signature is checked
/// against a pinned public key, the freshness window is enforced, and the
/// address shown to the user is derived from the *signed* script rather than
/// read from the unsigned `holder_address` field.
///
/// Deliberately not written here: any private-key operation. This file only
/// ever verifies.
public enum SNS {
    public static let defaultBaseURL = "https://sns.ordnet.io"

    /// Pre-pinned resolver key. Rotation is proved through the deed chain at
    /// `/pubkey`; see `SNSResolver.adoptRotation`.
    public static let pinnedSigner =
        "03088f1da3bfc998c1bc7bbc1ffcb7d96c47e094624a52d78406f8c3105b0d0b46"

    /// Domain separation tags. The unit separator (0x1f) joins the fields.
    static let resolveTag = "ORDNS-RESOLVE"
    static let rotateTag = "ORDNS-KEYROTATE"
    static let unitSeparator: UInt8 = 0x1f

    // MARK: Wire types

    public struct Outpoint: Codable, Sendable, Equatable {
        public var txid: String
        public var vout: UInt32

        public init(txid: String, vout: UInt32) {
            self.txid = txid
            self.vout = vout
        }

        public var description: String { "\(txid):\(vout)" }
    }

    /// A signed resolution. Only the fields listed in `signedFields` are
    /// covered by `sig`; `input`, `source`, `holderAddress` and `signer` are
    /// not, which is why none of them may be shown as fact.
    public struct Resolution: Codable, Sendable, Equatable {
        public var v: Int
        public var input: String?
        public var name: String
        public var mailbox: String
        public var source: String?
        public var fallback: Bool
        /// NOT signed. Never display this — use `derivedAddress`.
        public var holderAddress: String?
        public var holderScript: String
        public var origin: Outpoint
        public var current: Outpoint
        public var asOfHeight: Int
        public var expires: Int
        public var sig: String
        public var signer: String

        enum CodingKeys: String, CodingKey {
            case v, input, name, mailbox, source, fallback
            case holderAddress = "holder_address"
            case holderScript = "holder_script"
            case origin, current
            case asOfHeight = "as_of_height"
            case expires, sig, signer
        }

        public init(v: Int, input: String?, name: String, mailbox: String, source: String?,
                    fallback: Bool, holderAddress: String?, holderScript: String,
                    origin: Outpoint, current: Outpoint, asOfHeight: Int, expires: Int,
                    sig: String, signer: String) {
            self.v = v
            self.input = input
            self.name = name
            self.mailbox = mailbox
            self.source = source
            self.fallback = fallback
            self.holderAddress = holderAddress
            self.holderScript = holderScript
            self.origin = origin
            self.current = current
            self.asOfHeight = asOfHeight
            self.expires = expires
            self.sig = sig
            self.signer = signer
        }

        /// Hand-written so an absent optional field cannot sink the whole
        /// answer. Everything the signature covers stays required — a missing
        /// signed field must fail loudly, not quietly default.
        public init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            v = try c.decode(Int.self, forKey: .v)
            input = try c.decodeIfPresent(String.self, forKey: .input)
            name = try c.decode(String.self, forKey: .name)
            mailbox = try c.decodeIfPresent(String.self, forKey: .mailbox) ?? ""
            source = try c.decodeIfPresent(String.self, forKey: .source)
            fallback = try c.decode(Bool.self, forKey: .fallback)
            holderAddress = try c.decodeIfPresent(String.self, forKey: .holderAddress)
            holderScript = try c.decode(String.self, forKey: .holderScript)
            origin = try c.decode(Outpoint.self, forKey: .origin)
            current = try c.decode(Outpoint.self, forKey: .current)
            asOfHeight = try c.decode(Int.self, forKey: .asOfHeight)
            expires = try c.decode(Int.self, forKey: .expires)
            sig = try c.decode(String.self, forKey: .sig)
            signer = try c.decode(String.self, forKey: .signer)
        }

        /// The fields the signature covers, in the order they are joined.
        public var signedFields: [String] {
            [
                String(v),
                name,
                mailbox,
                holderScript,
                origin.txid,
                String(origin.vout),
                current.txid,
                String(current.vout),
                String(asOfHeight),
                fallback ? "true" : "false",
                String(expires),
            ]
        }

        /// The address to show and to pay, derived from the *signed* script.
        public var derivedAddress: String? { SNS.address(fromScriptHex: holderScript) }
    }

    /// One link in the key-rotation deed chain.
    public struct Rotation: Codable, Sendable, Equatable {
        public var rv: Int
        public var seq: Int
        public var oldPub: String
        public var newPub: String
        public var validFrom: Int
        public var sig: String

        enum CodingKeys: String, CodingKey {
            case rv, seq
            case oldPub = "old_pub"
            case newPub = "new_pub"
            case validFrom = "valid_from"
            case sig
        }

        public var signedFields: [String] {
            [String(rv), String(seq), oldPub, newPub, String(validFrom)]
        }
    }

    public struct PubkeyResponse: Codable, Sendable {
        public var signer: String
        public var seq: Int
        public var rotations: [Rotation]
    }

    /// The names held by an address, as `/reverse` reports them.
    ///
    /// A flat list of strings — **not** signed, and carrying no outpoint or
    /// verification status. It is a directory listing, nothing more, and must
    /// be presented as such. Resolving an individual name is what produces a
    /// signed answer.
    public struct Listing: Codable, Sendable, Equatable {
        public var address: String?
        public var names: [String]
        public var limit: Int?
        public var offset: Int?
        /// True when the address holds more names than this page returned.
        public var more: Bool

        public init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            address = try c.decodeIfPresent(String.self, forKey: .address)
            names = try c.decodeIfPresent([String].self, forKey: .names) ?? []
            limit = try c.decodeIfPresent(Int.self, forKey: .limit)
            offset = try c.decodeIfPresent(Int.self, forKey: .offset)
            more = try c.decodeIfPresent(Bool.self, forKey: .more) ?? false
        }
    }

    public struct Health: Codable, Sendable {
        public var service: String?
        public var version: String?
        public var signer: String?
        public var tlds: [String]
        public var retiredTlds: [String]
        public var tipHeight: Int?

        enum CodingKeys: String, CodingKey {
            case service, version, signer, tlds
            case retiredTlds = "retired_tlds"
            case tipHeight = "tip_height"
        }

        public init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            service = try c.decodeIfPresent(String.self, forKey: .service)
            version = try c.decodeIfPresent(String.self, forKey: .version)
            signer = try c.decodeIfPresent(String.self, forKey: .signer)
            tlds = try c.decodeIfPresent([String].self, forKey: .tlds) ?? []
            retiredTlds = try c.decodeIfPresent([String].self, forKey: .retiredTlds) ?? []
            tipHeight = try c.decodeIfPresent(Int.self, forKey: .tipHeight)
        }

        /// Names under a retired TLD still resolve; only new ones are refused.
        public var allTlds: [String] { tlds + retiredTlds }
    }

    // MARK: Errors

    /// The resolver's own error codes, plus the ones this client raises. The
    /// two are kept apart on purpose: a *domain* status like `notVerified` says
    /// something about the name, while `signatureInvalid` says something about
    /// our check of the answer. Conflating those two has bitten this project
    /// once already.
    public enum Failure: Error, LocalizedError, Equatable {
        // Reported by the resolver.
        case invalidAddress(String?)
        case unknownTLD(String?)
        case notRegistered(String?)
        case notVerified(String?)
        case retiredTLD(String?)
        case noHolder(String?)
        case rateLimited(String?)
        case server(code: String, message: String?)

        // Raised here, about the answer rather than about the name.
        case signatureInvalid
        case untrustedSigner(String)
        case expired
        case malformedScript
        case addressMismatch
        case staleOutpoint
        case outpointUnverified
        case unreachable(String)

        public var code: String {
            switch self {
            case .invalidAddress: return "invalid_address"
            case .unknownTLD: return "unknown_tld"
            case .notRegistered: return "not_registered"
            case .notVerified: return "not_verified"
            case .retiredTLD: return "retired_tld"
            case .noHolder: return "no_holder"
            case .rateLimited: return "rate_limited"
            case let .server(code, _): return code
            case .signatureInvalid: return "signature_invalid"
            case .untrustedSigner: return "untrusted_signer"
            case .expired: return "expired"
            case .malformedScript: return "malformed_script"
            case .addressMismatch: return "address_mismatch"
            case .staleOutpoint: return "stale_outpoint"
            case .outpointUnverified: return "outpoint_unverified"
            case .unreachable: return "unreachable"
            }
        }

        /// True when trying again later could plausibly succeed. `notVerified`
        /// is deliberately *not* in here: it stands until the name is given the
        /// ORDnet mark.
        public var isTemporary: Bool {
            switch self {
            case .noHolder, .rateLimited, .unreachable, .expired, .staleOutpoint, .outpointUnverified:
                return true
            default:
                return false
            }
        }

        public var errorDescription: String? {
            switch self {
            case let .invalidAddress(message):
                return message ?? "That is not a valid SNS name."
            case let .unknownTLD(message):
                return message ?? "That extension is not an SNS extension."
            case let .notRegistered(message):
                return message ?? "That name is not registered."
            case let .notVerified(message):
                return message ?? "That name exists on chain but does not carry the ORDnet mark yet, so it cannot be resolved."
            case let .retiredTLD(message):
                return message ?? "That extension is retired — no new names under it."
            case let .noHolder(message):
                return message ?? "The registration is still being indexed. Try again in a few minutes."
            case let .rateLimited(message):
                return message ?? "Too many lookups. Wait a moment."
            case let .server(code, message):
                return message ?? "The resolver refused the lookup (\(code))."
            case .signatureInvalid:
                return "The resolver's answer failed its signature check — it was not left alone in transit."
            case let .untrustedSigner(signer):
                return "The answer was signed by a key this app has not accepted: \(String(signer.prefix(16)))…"
            case .expired:
                return "The answer is older than its freshness window. Look it up again."
            case .malformedScript:
                return "The holder script in the answer is not a standard payment script."
            case .addressMismatch:
                return "The address in the answer does not match its own signed script."
            case .staleOutpoint:
                return "The name changed hands while you were looking at it. Look it up again."
            case .outpointUnverified:
                return "Could not confirm that this name is still held by the same address. Nothing was sent — try again in a moment."
            case let .unreachable(reason):
                return "The SNS resolver could not be reached: \(reason)"
            }
        }

        static func from(code: String, message: String?) -> Failure {
            switch code {
            case "invalid_address": return .invalidAddress(message)
            case "unknown_tld": return .unknownTLD(message)
            case "not_registered": return .notRegistered(message)
            case "not_verified": return .notVerified(message)
            case "retired_tld": return .retiredTLD(message)
            case "no_holder": return .noHolder(message)
            case "rate_limited": return .rateLimited(message)
            default: return .server(code: code, message: message)
            }
        }
    }

    // MARK: Sighash

    static func canonical(tag: String, fields: [String]) -> [UInt8] {
        var bytes = Array(tag.utf8)
        for field in fields {
            bytes.append(unitSeparator)
            bytes += Array(field.utf8)
        }
        return bytes
    }

    /// Double SHA-256 over `TAG 0x1f field 0x1f field …`.
    public static func sighash(for resolution: Resolution) -> [UInt8] {
        Hash.sha256d(canonical(tag: resolveTag, fields: resolution.signedFields))
    }

    public static func sighash(for rotation: Rotation) -> [UInt8] {
        Hash.sha256d(canonical(tag: rotateTag, fields: rotation.signedFields))
    }

    /// Checks a DER signature over the sighash against a compressed public key.
    public static func isSignatureValid(digest: [UInt8], derHex: String, publicKeyHex: String) -> Bool {
        guard let der = Hex.decode(derHex),
              let signature = ECDSASignature.fromDER(der),
              let pubBytes = Hex.decode(publicKeyHex),
              let point = ECPoint.decode(pubBytes) else { return false }
        return ECDSA.verify(digest: digest, signature: signature, publicKey: point)
    }

    // MARK: Script and name helpers

    /// The address a signed P2PKH holder script pays to.
    public static func address(fromScriptHex hex: String) -> String? {
        guard let script = Hex.decode(hex), script.count == 25,
              script[0] == Opcode.OP_DUP, script[1] == Opcode.OP_HASH160, script[2] == 20,
              script[23] == Opcode.OP_EQUALVERIFY, script[24] == Opcode.OP_CHECKSIG
        else { return nil }
        return Address.encode(hash160: Array(script[3..<23]))
    }

    /// Lowercased and trimmed. Names are compared and looked up in this form.
    public static func normalize(_ input: String) -> String {
        input.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    }

    /// A cheap, offline check: does this look like an SNS address at all?
    /// A bare name with no dot is OpNS — a different service with different
    /// rules — and must never be sent here.
    public static func looksLikeSNS(_ input: String, tlds: [String]) -> Bool {
        let normalized = normalize(input)
        let domain = normalized.contains("@")
            ? String(normalized.split(separator: "@", maxSplits: 1).last ?? "")
            : normalized
        guard domain.contains("."), let tld = domain.split(separator: ".").last else { return false }
        return tlds.contains(String(tld))
    }

    /// The domain part of `mailbox@name.tld`, or the input itself.
    public static func domain(of input: String) -> String {
        let normalized = normalize(input)
        guard normalized.contains("@") else { return normalized }
        return String(normalized.split(separator: "@", maxSplits: 1).last ?? "")
    }

    // MARK: Look-alike detection

    public struct Warning: Sendable, Equatable, Identifiable {
        public enum Severity: String, Sendable { case low, high }
        public var severity: Severity
        public var text: String
        public var id: String { "\(severity.rawValue)-\(text)" }
    }

    /// Names that read as one thing and resolve to another. A `high` warning
    /// must be shown prominently and must block a one-tap action.
    public static func warnings(for input: String) -> [Warning] {
        var found = [Warning]()
        let name = normalize(input)

        let invisible: Set<Unicode.Scalar> = [
            "\u{200B}", "\u{200C}", "\u{200D}", "\u{2060}", "\u{FEFF}",
            "\u{00AD}", "\u{200E}", "\u{200F}",
        ]
        let hits = name.unicodeScalars.filter { invisible.contains($0) }
        if !hits.isEmpty {
            let points = hits.map { String(format: "U+%04X", $0.value) }.joined(separator: ", ")
            found.append(Warning(severity: .high,
                                 text: "Contains invisible characters (\(points))."))
        }

        // Mixing scripts is the classic homograph trick: аpple with a Cyrillic
        // а is a different name from apple.
        var scripts = Set<String>()
        for scalar in name.unicodeScalars where !scalar.properties.isWhitespace {
            switch scalar.value {
            case 0x0041...0x005A, 0x0061...0x007A: scripts.insert("latin")
            case 0x0400...0x04FF: scripts.insert("cyrillic")
            case 0x0370...0x03FF: scripts.insert("greek")
            case 0x0590...0x05FF: scripts.insert("hebrew")
            case 0x0600...0x06FF: scripts.insert("arabic")
            default: break
            }
        }
        if scripts.count > 1 {
            found.append(Warning(severity: .high,
                                 text: "Mixes \(scripts.sorted().joined(separator: " and ")) letters."))
        }

        // Digits standing in for letters read the same at a glance.
        let lookalikes: [Character: String] = ["0": "o", "1": "l", "5": "s", "3": "e"]
        let bare = domain(of: name).split(separator: ".").first.map(String.init) ?? name
        let swapped = bare.filter { lookalikes.keys.contains($0) }
        if !swapped.isEmpty, bare.contains(where: { $0.isLetter }) {
            found.append(Warning(severity: .low,
                                 text: "Contains \(swapped.map(String.init).joined(separator: ", ")) — easy to mistake for letters."))
        }

        return found
    }
}
