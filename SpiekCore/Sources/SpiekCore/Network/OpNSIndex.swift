import Foundation

/// The live OpNS index.
///
/// Endpoints and field names taken from a working integration rather than
/// guessed:
///
///     GET /api/opns/names?q=<name>     search, defaults to match=exact
///     GET /api/opns/name/<name>        one name
///     GET /api/opns/owner/<address>    every name held by an address
///     GET /api/opns/status             root of the tree, counts, last run
///
/// The envelope is `{ ok, fallback?, match?, results: [...] }` and a record
/// carries `name`, `owner_address`, `current_txid`, `current_vout`,
/// `origin_txid`, `origin_vout`, `ambiguous` and `lineage_verified`.
///
/// `origin_*` is the mint transaction of *that name* — every record has a
/// different one, and none of them is the tree-0 genesis. It is identity, not
/// lineage: `current_*` is what a payment follows.
public actor OpNSIndex: OpNSDirectory {
    public struct Configuration: Sendable {
        public var baseURL: String

        public init(baseURL: String = "https://search.ordnet.io/api/opns") {
            self.baseURL = baseURL
        }
    }

    private let configuration: Configuration
    private let session: URLSession

    public init(configuration: Configuration = Configuration(), session: URLSession? = nil) {
        self.configuration = configuration
        if let session {
            self.session = session
        } else {
            let config = URLSessionConfiguration.default
            config.timeoutIntervalForRequest = 15
            config.requestCachePolicy = .reloadIgnoringLocalCacheData
            self.session = URLSession(configuration: config)
        }
    }

    // MARK: Wire shapes

    private struct Envelope: Decodable {
        var ok: Bool?
        var fallback: Bool?
        var match: String?
        var results: [Record]?
        var error: String?
        /// How many records the index actually sent, before any were skipped.
        /// Without it, an answer this app could not read would be reported as
        /// "that name does not exist" — a different and much worse claim.
        var rawResultCount = 0

        enum CodingKeys: String, CodingKey {
            case ok, fallback, match, results, error
        }

        /// Hand-written for the same reason as `StatusEnvelope`: a synthesised
        /// decoder fails the *whole* answer over one unexpected field, and this
        /// index is SQL-backed — `last_run` arriving as "2026-08-04 08:02:20"
        /// proves that — so a boolean coming back as 0/1 or a number as a
        /// quoted string is a live possibility, not a hypothetical.
        ///
        /// One bad record must also not take the other 199 with it, which is
        /// what `[Record]` did: the array decode threw before `name(from:)`
        /// ever got to skip the unusable one.
        init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            ok = try? Loose.bool(c, .ok)
            fallback = try? Loose.bool(c, .fallback)
            match = try? c.decodeIfPresent(String.self, forKey: .match)
            error = try? c.decodeIfPresent(String.self, forKey: .error)
            let tolerant = try? c.decodeIfPresent([FailableRecord].self, forKey: .results)
            results = tolerant?.compactMap(\.record)
            rawResultCount = tolerant?.count ?? 0
        }
    }

    /// Swallows one unusable element instead of failing the array.
    private struct FailableRecord: Decodable {
        var record: Record?
        init(from decoder: Decoder) throws {
            record = try? Record(from: decoder)
        }
    }

    /// Number- and boolean-shaped fields, read whichever way the index writes
    /// them. Strict about *meaning*, forgiving about JSON type — a name that
    /// exists must never read as "the index could not be reached".
    private enum Loose {
        static func bool<K: CodingKey>(_ c: KeyedDecodingContainer<K>, _ key: K) throws -> Bool? {
            if let value = try? c.decodeIfPresent(Bool.self, forKey: key) { return value }
            if let value = try? c.decodeIfPresent(Int.self, forKey: key) { return value != 0 }
            if let text = try? c.decodeIfPresent(String.self, forKey: key) {
                switch text.lowercased() {
                case "true", "1", "yes", "t": return true
                case "false", "0", "no", "f": return false
                default: return nil
                }
            }
            return nil
        }

        static func int<K: CodingKey>(_ c: KeyedDecodingContainer<K>, _ key: K) throws -> Int? {
            if let value = try? c.decodeIfPresent(Int.self, forKey: key) { return value }
            if let text = try? c.decodeIfPresent(String.self, forKey: key) { return Int(text) }
            if let value = try? c.decodeIfPresent(Double.self, forKey: key) {
                // Only a whole number is a block height or an output index.
                guard value.isFinite, value == value.rounded() else { return nil }
                return Int(value)
            }
            return nil
        }

        static func vout<K: CodingKey>(_ c: KeyedDecodingContainer<K>, _ key: K) throws -> UInt32? {
            guard let value = try int(c, key), value >= 0, value <= Int(UInt32.max) else { return nil }
            return UInt32(value)
        }

        static func string<K: CodingKey>(_ c: KeyedDecodingContainer<K>, _ key: K) throws -> String? {
            if let text = try? c.decodeIfPresent(String.self, forKey: key) { return text }
            if let value = try? c.decodeIfPresent(Int.self, forKey: key) { return String(value) }
            return nil
        }
    }

    private struct Record: Decodable {
        var name: String
        var ownerAddress: String
        var currentTxid: String
        var currentVout: UInt32?
        var originTxid: String?
        var originVout: UInt32?
        var ambiguous: Bool?
        var lineageVerified: Bool?
        var height: Int?

        enum CodingKeys: String, CodingKey {
            case name
            case ownerAddress = "owner_address"
            case currentTxid = "current_txid"
            case currentVout = "current_vout"
            case originTxid = "origin_txid"
            case originVout = "origin_vout"
            case ambiguous
            case lineageVerified = "lineage_verified"
            case height
        }

        /// Only the three fields a payment cannot be made without may fail the
        /// record: which name this is, who holds it, and in which transaction.
        /// Everything else is read leniently and defaults to the cautious value
        /// — `ambiguous` and `lineageVerified` both to false, which makes the
        /// panel say "not certified" rather than claim a proof.
        init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            guard let name = try Loose.string(c, .name),
                  let owner = try Loose.string(c, .ownerAddress),
                  let current = try Loose.string(c, .currentTxid) else {
                throw DecodingError.dataCorrupted(
                    .init(codingPath: decoder.codingPath,
                          debugDescription: "record without a name, holder or transaction"))
            }
            self.name = name
            ownerAddress = owner
            currentTxid = current
            currentVout = try Loose.vout(c, .currentVout)
            originTxid = try Loose.string(c, .originTxid)
            originVout = try Loose.vout(c, .originVout)
            ambiguous = try Loose.bool(c, .ambiguous)
            lineageVerified = try Loose.bool(c, .lineageVerified)
            height = try Loose.int(c, .height)
        }
    }

    /// Returns nil for a record that cannot be used. A missing `current_vout`
    /// is the important one: "the index did not say which output" is not the
    /// same fact as "output 0", and inventing it would point both the holder
    /// recompute and the spent check at the wrong outpoint — which can pass
    /// both when output 0 happens to be change back to the same address.
    private func name(from record: Record, isFallback: Bool) -> OpNS.Name? {
        guard let vout = record.currentVout else { return nil }
        return OpNS.Name(name: record.name,
                         originTxid: record.originTxid,
                         originVout: record.originVout,
                         currentTxid: record.currentTxid,
                         currentVout: vout,
                         ownerAddress: record.ownerAddress,
                         height: record.height,
                         isFallback: isFallback,
                         ambiguous: record.ambiguous ?? false,
                         lineageVerified: record.lineageVerified ?? false)
    }

    // MARK: OpNSDirectory

    public func lookUp(name wanted: String) async throws -> OpNS.Name? {
        let asked = OpNS.normalize(wanted)
        let encoded = asked.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? asked
        let envelope = try await get(path: "/names?q=\(encoded)")

        guard let results = envelope.results, !results.isEmpty else {
            // Records came back but none survived. "Could not read the answer"
            // is the truth; "no such name" would be a claim about the chain
            // that nothing here supports.
            if envelope.rawResultCount > 0 {
                throw OpNS.Failure.directoryUnavailable(
                    "the index sent \(envelope.rawResultCount) record(s) this app could not read")
            }
            return nil
        }

        // A record carrying the exact name asked for is not a near miss, even
        // when the envelope's `fallback`/`match` flags say the *query* was
        // broadened. Those flags describe the search, not the record — stamping
        // them onto an exact hit would refuse a real, mined name and tell the
        // user it "does not exist" while showing that same name back.
        if let exact = results.first(where: { OpNS.normalize($0.name) == asked }) {
            guard let usable = name(from: exact, isFallback: false) else {
                // The name exists; the index just did not say which output
                // holds it. Reporting that as "never mined" would be a lie.
                throw OpNS.Failure.directoryUnavailable(
                    "the index did not say which output holds \u{201C}\(asked)\u{201D}")
            }
            return usable
        }
        // Only near misses came back. Hand the closest one over *marked*, so
        // the caller refuses it and can still say "did you mean".
        return name(from: results[0], isFallback: true)
    }

    public func names(ownedBy address: String) async throws -> [OpNS.Name] {
        let encoded = address.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? address
        let envelope = try await get(path: "/owner/\(encoded)")
        return (envelope.results ?? []).compactMap { name(from: $0, isFallback: false) }
    }

    /// What the index says about itself: the root it indexes, how many names it
    /// can resolve, and when the lineage pass last ran.
    public struct Status: Sendable {
        public var genesis: String?
        public var names: Int?
        public var ambiguous: Int?
        /// A timestamp string as the index writes it, e.g. "2026-08-04 08:02:20".
        public var lastRun: String?
    }

    private struct StatusEnvelope: Decodable {
        var ok: Bool?
        var genesis: String?
        var names: Int?
        var ambiguous: Int?
        var lastRun: String?
        var error: String?

        enum CodingKeys: String, CodingKey {
            case ok, genesis, names, ambiguous, error
            case lastRun = "last_run"
        }

        /// Hand-written and forgiving about everything except `genesis`.
        ///
        /// `last_run` is a *string* timestamp, not an epoch number — decoding it
        /// as an Int threw, and because the synthesised decoder fails the whole
        /// envelope on one bad field, a cosmetic counter took every OpNS lookup
        /// down with it. Nothing here except the root is load-bearing, so
        /// nothing here except the root may fail the decode.
        init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            ok = try? Loose.bool(c, .ok)
            // Read as leniently as everything else. A root written in some
            // other JSON shape is still a root the app can compare against —
            // and refusing to read it would turn a formatting difference into
            // "this index will not say", which is a refusal.
            genesis = try? Loose.string(c, .genesis)
            names = try? Loose.int(c, .names)
            ambiguous = try? Loose.int(c, .ambiguous)
            error = try? c.decodeIfPresent(String.self, forKey: .error)
            lastRun = try? Loose.string(c, .lastRun)
        }
    }

    public func status() async throws -> Status {
        let envelope: StatusEnvelope = try await get(StatusEnvelope.self, path: "/status")

        // Absence of evidence is not agreement. An index that does not say
        // which root it serves has not confirmed anything, and letting that
        // pass would turn the once-per-launch pin check into a no-op.
        // Its own case, not `directoryUnavailable`: the caller waves transport
        // failures through — it has to, or one unreachable status endpoint
        // takes the whole feature down — and a withheld root must not be able
        // to ride in on that exemption.
        guard let reported = envelope.genesis else {
            throw OpNS.Failure.rootNotReported
        }
        // Compared on the outpoint itself, not on how it is punctuated: an
        // index that writes `txid:0` instead of `txid_0` is not a different
        // tree, and a fail-closed gate must not trip over a separator.
        guard OpNS.sameOutpoint(reported, OpNS.genesis) else {
            throw OpNS.Failure.genesisMismatch(expected: OpNS.genesis, reported: reported)
        }

        return Status(genesis: reported,
                      names: envelope.names,
                      ambiguous: envelope.ambiguous,
                      lastRun: envelope.lastRun)
    }

    // MARK: Transport

    private func get(path: String) async throws -> Envelope {
        try await get(Envelope.self, path: path)
    }

    private func get<T: Decodable>(_ type: T.Type, path: String) async throws -> T {
        guard let url = URL(string: configuration.baseURL + path) else {
            throw OpNS.Failure.directoryUnavailable("bad URL")
        }
        var request = URLRequest(url: url)
        request.setValue("application/json", forHTTPHeaderField: "Accept")

        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await session.data(for: request)
        } catch {
            throw OpNS.Failure.directoryUnavailable(error.localizedDescription)
        }

        guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
            let code = (response as? HTTPURLResponse)?.statusCode ?? 0
            throw OpNS.Failure.directoryUnavailable("HTTP \(code)")
        }

        // `ok: false` can arrive with a 200, so the body is read before the
        // status code is trusted either way.
        if let refusal = try? JSONDecoder().decode(Refusal.self, from: data), refusal.ok == false {
            throw OpNS.Failure.directoryUnavailable(refusal.error ?? "the index refused the lookup")
        }
        guard let decoded = try? JSONDecoder().decode(T.self, from: data) else {
            throw OpNS.Failure.directoryUnavailable("unreadable answer")
        }
        return decoded
    }

    /// The refusal check, and therefore the one field in this file that most
    /// needs to be read leniently.
    ///
    /// It was the last strict `Bool` left. An index that writes `{"ok":0}` —
    /// which is exactly what an SQL-backed one does — made this decode throw,
    /// the refusal go unnoticed, and an empty envelope be read as a successful
    /// answer. On a lookup that surfaces as "this name has not been mined",
    /// which is a claim about the chain that a refusal does not support.
    private struct Refusal: Decodable {
        var ok: Bool?
        var error: String?

        enum CodingKeys: String, CodingKey { case ok, error }

        init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            ok = try? Loose.bool(c, .ok)
            error = try? Loose.string(c, .error)
        }
    }
}
