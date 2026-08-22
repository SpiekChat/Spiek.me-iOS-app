import Foundation

/// Where a pinned resolver key is kept between launches. The app supplies a
/// Keychain-backed one; the tests use an in-memory one.
public protocol SNSPinStore: Sendable {
    func pinnedSigner() async -> String?
    func setPinnedSigner(_ signer: String, seq: Int) async
    func pinnedSequence() async -> Int
}

public actor SNSMemoryPinStore: SNSPinStore {
    private var signer: String?
    private var seq: Int = 0

    public init(signer: String? = nil, seq: Int = 0) {
        self.signer = signer
        self.seq = seq
    }

    public func pinnedSigner() async -> String? { signer }
    public func setPinnedSigner(_ signer: String, seq: Int) async {
        self.signer = signer
        self.seq = seq
    }
    public func pinnedSequence() async -> Int { seq }
}

/// How hard the caller wants the answer checked.
public enum SNSAssurance: String, Sendable, CaseIterable {
    /// Signature and freshness are not checked. Read-only lists only — never a
    /// payment, and never an address you are about to write to.
    case trust
    /// Signature against the pinned key, plus the freshness window. The minimum
    /// for showing a name anywhere.
    case verify
    /// Everything `verify` does, and the outpoint is proved unspent. Required
    /// before money moves.
    case prove
}

public struct SNSResolved: Sendable, Equatable {
    public var resolution: SNS.Resolution
    /// Derived from the signed script — this is the one to display and to pay.
    public var address: String
    public var assurance: SNSAssurance
    public var warnings: [SNS.Warning]
    /// True when the mailbox was unknown and the domain holder answered instead.
    public var fellBackToDomain: Bool { resolution.fallback }
}

/// Talks to the SNS resolver and checks everything it says.
///
/// Never trusts an answer: the signature is verified against a pinned key, the
/// freshness window is enforced, and the address is derived from the signed
/// script. A signer this app has not accepted is only adopted after the deed
/// chain from `/pubkey` closes back to the current pin.
public actor SNSResolver {
    public struct Configuration: Sendable {
        public var baseURL: String
        /// How far the device clock may run ahead of the resolver before a
        /// fresh answer looks expired.
        public var clockSkewSeconds: Int

        public init(baseURL: String = SNS.defaultBaseURL, clockSkewSeconds: Int = 120) {
            self.baseURL = baseURL
            self.clockSkewSeconds = clockSkewSeconds
        }
    }

    /// Returns true when unspent, false when spent, and **nil when unknown**.
    /// Unknown must never be read as spent — that would refuse a good name
    /// because an indexer was slow.
    public typealias UnspentCheck = @Sendable (SNS.Outpoint) async -> Bool?

    private let configuration: Configuration
    private let session: URLSession
    private let pins: any SNSPinStore
    private let unspentCheck: UnspentCheck?
    private let now: @Sendable () -> Int

    private var cachedTlds: [String]?
    private var tldsFetchedAt: Int = 0

    public init(configuration: Configuration = Configuration(),
                pins: any SNSPinStore = SNSMemoryPinStore(),
                session: URLSession? = nil,
                unspentCheck: UnspentCheck? = nil,
                now: @escaping @Sendable () -> Int = { Int(Date().timeIntervalSince1970) }) {
        self.configuration = configuration
        self.pins = pins
        self.unspentCheck = unspentCheck
        self.now = now
        if let session {
            self.session = session
        } else {
            let config = URLSessionConfiguration.default
            config.timeoutIntervalForRequest = 15
            config.waitsForConnectivity = false
            // The confirm tap re-resolves, and that must reach the resolver.
            // Served from URLCache it would compare a cached answer with
            // itself, and the freshness guarantee would rest on the server's
            // headers rather than on us.
            config.requestCachePolicy = .reloadIgnoringLocalCacheData
            self.session = URLSession(configuration: config)
        }
    }

    // MARK: Public surface

    /// The extensions the resolver currently serves, including retired ones —
    /// names already registered under those still resolve. Never hardcoded.
    public func tlds() async -> [String] {
        if let cachedTlds, now() - tldsFetchedAt < 3600 { return cachedTlds }
        guard let health = try? await health() else {
            // Falling back to whatever we last saw beats refusing every lookup
            // because /health hiccuped.
            return cachedTlds ?? []
        }
        cachedTlds = health.allTlds
        tldsFetchedAt = now()
        return health.allTlds
    }

    public func looksLikeSNS(_ input: String) async -> Bool {
        let known = await tlds()
        // With no TLD list yet, fall back to "has a dot and is not an address",
        // and let the resolver be the judge.
        guard !known.isEmpty else {
            let domain = SNS.domain(of: input)
            return domain.contains(".") && !domain.hasPrefix("1")
        }
        return SNS.looksLikeSNS(input, tlds: known)
    }

    /// Every SNS name held by an address.
    ///
    /// Informational only: the answer is a plain list, not a signed statement,
    /// so nothing here may be treated as verified. Resolving one of these names
    /// is what produces a signed answer.
    public func names(ownedBy address: String, limit: Int = 200, offset: Int = 0) async throws -> SNS.Listing {
        let encoded = address.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? address
        // The endpoint caps at 500.
        let capped = min(max(1, limit), 500)
        return try await get(SNS.Listing.self,
                             path: "/reverse/\(encoded)?limit=\(capped)&offset=\(max(0, offset))")
    }

    public func health() async throws -> SNS.Health {
        try await get(SNS.Health.self, path: "/health")
    }

    /// Resolves a name or mailbox address and checks the answer.
    public func resolve(_ input: String, assurance: SNSAssurance = .verify) async throws -> SNSResolved {
        let normalized = SNS.normalize(input)
        guard !normalized.isEmpty else { throw SNS.Failure.invalidAddress(nil) }

        let encoded = normalized.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed)
            ?? normalized
        let resolution = try await get(SNS.Resolution.self, path: "/resolve/\(encoded)")
        return try await check(resolution, assurance: assurance)
    }

    /// Runs the checks on an answer already in hand. Split out so the caller can
    /// re-check a cached answer at the moment it matters.
    public func check(_ resolution: SNS.Resolution,
                      assurance: SNSAssurance) async throws -> SNSResolved {
        guard let address = resolution.derivedAddress else { throw SNS.Failure.malformedScript }

        // The unsigned convenience field disagreeing with the signed script is
        // a red flag worth stopping for.
        if let claimed = resolution.holderAddress, claimed != address {
            throw SNS.Failure.addressMismatch
        }

        if assurance != .trust {
            guard try await isSignerAccepted(resolution.signer) else {
                throw SNS.Failure.untrustedSigner(resolution.signer)
            }
            guard SNS.isSignatureValid(digest: SNS.sighash(for: resolution),
                                       derHex: resolution.sig,
                                       publicKeyHex: resolution.signer) else {
                throw SNS.Failure.signatureInvalid
            }
            guard resolution.expires + configuration.clockSkewSeconds >= now() else {
                throw SNS.Failure.expired
            }
        }

        if assurance == .prove {
            guard let unspentCheck else { throw SNS.Failure.outpointUnverified }
            // `prove` means proved. "Could not tell" is reported as exactly
            // that — never as spent, which would accuse the name of having
            // changed hands — but it is still not a proof, so it does not pass.
            // OpNS takes the same position on identical evidence; letting the
            // two namespaces disagree here would be indefensible.
            switch await unspentCheck(resolution.current) {
            case true?: break
            case false?: throw SNS.Failure.staleOutpoint
            case nil: throw SNS.Failure.outpointUnverified
            }
        }

        return SNSResolved(resolution: resolution,
                           address: address,
                           assurance: assurance,
                           warnings: SNS.warnings(for: resolution.name))
    }

    // MARK: Key pinning and rotation

    private func currentPin() async -> String {
        await pins.pinnedSigner() ?? SNS.pinnedSigner
    }

    /// A signer is accepted when it is the pin, or when `/pubkey` hands us a
    /// chain of deeds that walks from the pin to it — each deed signed by the
    /// key it replaces.
    private func isSignerAccepted(_ signer: String) async throws -> Bool {
        let pinned = await currentPin()
        if signer.caseInsensitiveCompare(pinned) == .orderedSame { return true }

        guard let announced = try? await get(SNS.PubkeyResponse.self, path: "/pubkey") else {
            return false
        }
        guard announced.signer.caseInsensitiveCompare(signer) == .orderedSame else { return false }
        guard let proven = SNSResolver.walk(chain: announced.rotations, from: pinned),
              proven.signer.caseInsensitiveCompare(signer) == .orderedSame else { return false }

        await pins.setPinnedSigner(proven.signer, seq: proven.seq)
        return true
    }

    /// Walks the deed chain from `pin` and returns where it ends up — or nil if
    /// any link is missing, out of order, or not signed by the key it replaces.
    /// A broken chain leaves the pin untouched.
    static func walk(chain: [SNS.Rotation], from pin: String) -> (signer: String, seq: Int)? {
        let ordered = chain.sorted { $0.seq < $1.seq }
        var current = pin
        var reached: Int?

        for deed in ordered {
            let joins = deed.oldPub.caseInsensitiveCompare(current) == .orderedSame
            // Deeds that predate our pin are history — skip them until the
            // chain picks up at the key we actually hold.
            if reached == nil, !joins { continue }
            // From that point on every link must join, in increasing order, and
            // must be signed by the key it replaces.
            guard joins else { return nil }
            if let reached, deed.seq <= reached { return nil }
            guard SNS.isSignatureValid(digest: SNS.sighash(for: deed),
                                       derHex: deed.sig,
                                       publicKeyHex: deed.oldPub) else { return nil }
            current = deed.newPub
            reached = deed.seq
        }

        guard let reached else { return nil }
        return (current, reached)
    }

    // MARK: Transport

    private func get<T: Decodable>(_ type: T.Type, path: String) async throws -> T {
        guard let url = URL(string: configuration.baseURL + path) else {
            throw SNS.Failure.unreachable("bad URL")
        }
        var request = URLRequest(url: url)
        request.setValue("application/json", forHTTPHeaderField: "Accept")

        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await session.data(for: request)
        } catch {
            throw SNS.Failure.unreachable(error.localizedDescription)
        }

        // The resolver answers with JSON even when it refuses, so read the body
        // before deciding anything from the status code.
        if let envelope = try? JSONDecoder().decode(ErrorEnvelope.self, from: data),
           envelope.ok == false {
            throw SNS.Failure.from(code: envelope.error ?? "server_error", message: envelope.message)
        }

        if let http = response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
            throw SNS.Failure.unreachable("HTTP \(http.statusCode)")
        }

        do {
            return try JSONDecoder().decode(T.self, from: data)
        } catch {
            throw SNS.Failure.unreachable("unreadable answer")
        }
    }

    private struct ErrorEnvelope: Decodable {
        var ok: Bool?
        var error: String?
        var message: String?
    }
}
