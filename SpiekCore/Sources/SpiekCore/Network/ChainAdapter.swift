import Foundation

public struct ChainTx: Sendable {
    public let hex: String
    public let height: Int?
    public let pos: Int?

    public init(hex: String, height: Int?, pos: Int?) {
        self.hex = hex
        self.height = height
        self.pos = pos
    }
}

public struct AddressActivity: Sendable {
    public let txid: String
    public let height: Int?
    public let pos: Int?
    /// Monotonic cursor so polling only asks for what is new.
    public let seq: Int

    public init(txid: String, height: Int?, pos: Int?, seq: Int) {
        self.txid = txid
        self.height = height
        self.pos = pos
        self.seq = seq
    }
}

public enum AdapterError: Error, LocalizedError {
    case badURL
    case http(Int, String)
    case broadcastRejected(String)
    case notSupported

    public var errorDescription: String? {
        switch self {
        case .badURL:
            return "The endpoint address is not valid."
        case let .http(code, body):
            // 429 has its own line: it is the server rate-limiting a burst,
            // not something the user did wrong, and the app retries by itself.
            if code == 429 {
                return "The server is busy right now — trying again shortly."
            }
            let clean = AdapterError.readable(body)
            return clean.isEmpty ? "Server returned \(code)." : "Server returned \(code): \(clean)"
        case let .broadcastRejected(reason):
            return "The network rejected this transaction: \(reason)"
        case .notSupported:
            return "This provider does not support that."
        }
    }

    /// An error page is for browsers; a notice bar gets one readable line.
    /// Tags are stripped, whitespace collapsed, and the result capped, so an
    /// nginx HTML page reduces to its title instead of filling the screen.
    static func readable(_ body: String) -> String {
        var text = body
        while let open = text.firstIndex(of: "<"), let close = text[open...].firstIndex(of: ">") {
            text.replaceSubrange(open...close, with: " ")
        }
        let collapsed = text.split(whereSeparator: \.isWhitespace).joined(separator: " ")
        return String(collapsed.prefix(120))
    }
}

public protocol ChainAdapter: Actor {
    func getTx(_ txid: String) async throws -> ChainTx?
    func watchAddress(_ address: String, since: Int) async throws -> [AddressActivity]
    @discardableResult
    func broadcast(_ rawHex: String) async throws -> String
    func fetchUTXOs(_ address: String) async throws -> [UTXO]
    /// Whether `fetchUTXOs` will do anything useful. Non-isolated so callers can
    /// check it without an await.
    nonisolated var supportsUTXOFetch: Bool { get }
}
