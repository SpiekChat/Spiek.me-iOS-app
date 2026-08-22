import Foundation

/// Whether a particular output has been spent.
///
/// Three answers, not two. `unknown` is the one that matters: an indexer that
/// timed out has told us nothing, and turning that into "spent" would refuse a
/// perfectly good name. Only `spent` may ever be reported as spent.
public enum OutpointState: String, Sendable, Equatable {
    case unspent
    case spent
    case unknown
}

/// Asks a single question directly: has this outpoint been spent?
///
/// Deliberately *not* "is it in the holder address's unspent list". That
/// approach looks equivalent and is not: an address list is paginated and
/// truncates on a busy address, so a name held at one would come back as spent
/// when it is not. It also cannot answer for an outpoint whose script differs
/// from the address the name pays to, which is exactly the custody case in SNS.
/// One outpoint, one question, one answer.
public protocol OutpointOracle: Sendable {
    func state(txid: String, vout: UInt32) async -> OutpointState
}

/// The WhatsOnChain spent endpoint: `200` means the outpoint has a spending
/// transaction, `404` means it does not. Anything else — a timeout, a 5xx, a
/// rate limit that survived the retries — is `unknown`.
public struct WhatsOnChainOracle: OutpointOracle {
    private let baseURL: String
    private let session: URLSession
    private let attempts: Int

    public init(baseURL: String = "https://api.whatsonchain.com/v1/bsv/main",
                session: URLSession? = nil,
                attempts: Int = 3) {
        self.baseURL = baseURL
        self.attempts = max(1, attempts)
        if let session {
            self.session = session
        } else {
            let config = URLSessionConfiguration.default
            config.timeoutIntervalForRequest = 15
            config.requestCachePolicy = .reloadIgnoringLocalCacheData
            self.session = URLSession(configuration: config)
        }
    }

    public func state(txid: String, vout: UInt32) async -> OutpointState {
        guard let url = URL(string: "\(baseURL)/tx/\(txid)/\(vout)/spent") else { return .unknown }

        var backoff: UInt64 = 400_000_000
        for attempt in 0..<attempts {
            let isLast = attempt == attempts - 1

            // A dropped packet deserves the same budget as a rate limit: one
            // lost connection should not refuse a payment outright.
            guard let (_, response) = try? await session.data(from: url),
                  let http = response as? HTTPURLResponse else {
                if isLast { return .unknown }
                try? await Task.sleep(nanoseconds: backoff)
                backoff = min(backoff * 2, 4_000_000_000)
                continue
            }

            switch http.statusCode {
            case 200: return .spent
            case 404: return .unspent
            case 429, 500...599:
                // Worth waiting out, but only a few times — and never after the
                // last attempt, which would be latency for nothing.
                if isLast { return .unknown }
                try? await Task.sleep(nanoseconds: backoff)
                backoff = min(backoff * 2, 4_000_000_000)
            default:
                return .unknown
            }
        }
        return .unknown
    }
}

/// An oracle that answers from a fixed table. For tests, and for a demo wallet
/// that has no real chain behind it.
public struct StaticOutpointOracle: OutpointOracle {
    private let answers: [String: OutpointState]
    private let fallback: OutpointState

    public init(answers: [String: OutpointState] = [:], fallback: OutpointState = .unknown) {
        self.answers = answers
        self.fallback = fallback
    }

    public func state(txid: String, vout: UInt32) async -> OutpointState {
        answers["\(txid):\(vout)"] ?? fallback
    }
}
