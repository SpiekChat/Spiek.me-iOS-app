import Foundation

/// What one BSV was worth in US dollars, and when this app learned it.
///
/// The timestamp is *ours*, not the feed's: it answers "how old is the number
/// on screen", which is the only question a stale rate raises. The feed's own
/// `time` field says when the quote was struck upstream and is not a substitute.
public struct BSVPrice: Codable, Equatable, Sendable {
    public var usd: Double
    public var fetched: Int

    public init(usd: Double, fetched: Int) {
        self.usd = usd
        self.fetched = fetched
    }

    /// Dollars for an amount in satoshis.
    public func dollars(sats: UInt64) -> Double {
        Double(sats) / 100_000_000 * usd
    }
}

/// The BSV/USD rate from WhatsOnChain.
///
///     GET https://api.whatsonchain.com/v1/bsv/main/exchangerate
///     -> {"currency":"USD","rate":12.845,"time":1785852199}
///
/// Deliberately its own client rather than a method on the chain adapter: this
/// is a price, not chain data, and a node in node-mode does not serve one. It
/// must never be able to take a wallet operation down with it — nothing here is
/// on the sending path, and every failure is returned rather than shown.
public actor PriceFeed {
    public enum Failure: LocalizedError, Sendable {
        case unreachable(String)
        /// Answered, but not with a US dollar rate we can use.
        case unusable(String)

        public var errorDescription: String? {
            switch self {
            case let .unreachable(detail): return "The price feed could not be reached: \(detail)."
            case let .unusable(detail): return "The price feed answered, but \(detail)."
            }
        }
    }

    private let url: URL
    private let session: URLSession

    public init(urlString: String = "https://api.whatsonchain.com/v1/bsv/main/exchangerate",
                session: URLSession? = nil) {
        // A constant known to parse; the fallback keeps the initialiser
        // non-failable without ever pointing somewhere else.
        self.url = URL(string: urlString)
            ?? URL(string: "https://api.whatsonchain.com/v1/bsv/main/exchangerate")!
        if let session {
            self.session = session
        } else {
            let config = URLSessionConfiguration.default
            config.timeoutIntervalForRequest = 12
            config.requestCachePolicy = .reloadIgnoringLocalCacheData
            self.session = URLSession(configuration: config)
        }
    }

    /// Hand-written, and forgiving about the *type* of the rate while being
    /// strict about its meaning.
    ///
    /// A number quoted as a JSON string is a real thing feeds do, and refusing
    /// one would be pedantry. Refusing a rate whose currency is not USD is not:
    /// printing a euro figure with a dollar sign is a wrong number, not a
    /// cosmetic problem.
    private struct Wire: Decodable {
        var rate: Double?
        var currency: String?

        enum CodingKeys: String, CodingKey { case rate, currency }

        init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            if let number = try? c.decodeIfPresent(Double.self, forKey: .rate) {
                rate = number
            } else if let text = try? c.decodeIfPresent(String.self, forKey: .rate) {
                rate = Double(text)
            } else {
                rate = nil
            }
            currency = try? c.decodeIfPresent(String.self, forKey: .currency)
        }
    }

    public func fetch(at now: Int = Int(Date().timeIntervalSince1970)) async throws -> BSVPrice {
        var request = URLRequest(url: url)
        request.setValue("application/json", forHTTPHeaderField: "Accept")

        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await session.data(for: request)
        } catch {
            throw Failure.unreachable(error.localizedDescription)
        }

        guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
            let code = (response as? HTTPURLResponse)?.statusCode ?? 0
            throw Failure.unreachable("HTTP \(code)")
        }
        guard let wire = try? JSONDecoder().decode(Wire.self, from: data) else {
            throw Failure.unusable("the answer could not be read")
        }
        // Absent is fine — this endpoint has always quoted dollars. Present and
        // something else is not.
        if let currency = wire.currency,
           currency.uppercased() != "USD" {
            throw Failure.unusable("it quoted \(currency.uppercased()), not US dollars")
        }
        guard let rate = wire.rate, rate.isFinite, rate > 0 else {
            throw Failure.unusable("it did not give a usable rate")
        }
        return BSVPrice(usd: rate, fetched: now)
    }
}
