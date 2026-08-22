import Foundation

/// Talks to the Spiek REST endpoints (or whatever the user pointed the app at
/// in "own node" mode). The URL templates carry `{txid}`, `{address}` and
/// `{since}` placeholders, exactly like the web version.
public actor RestAdapter: ChainAdapter {
    public struct Configuration: Sendable {
        public var getTxURL: String
        public var watchURL: String
        public var broadcastURL: String
        public var utxoURL: String
        public var mirrorBroadcastURL: String?
        public var headers: [String: String]

        public init(getTxURL: String,
                    watchURL: String,
                    broadcastURL: String,
                    utxoURL: String,
                    mirrorBroadcastURL: String? = "https://api.whatsonchain.com/v1/bsv/main/tx/raw",
                    headers: [String: String] = [:]) {
            self.getTxURL = getTxURL
            self.watchURL = watchURL
            self.broadcastURL = broadcastURL
            self.utxoURL = utxoURL
            self.mirrorBroadcastURL = mirrorBroadcastURL
            self.headers = headers
        }

        public static func from(settings: Settings) -> Configuration {
            let resolved = settings.resolvedEndpoints()
            return Configuration(getTxURL: resolved.getTxURL,
                                 watchURL: resolved.watchURL,
                                 broadcastURL: resolved.broadcastURL,
                                 utxoURL: resolved.utxoURL,
                                 mirrorBroadcastURL: settings.mirrorBroadcast
                                     ? "https://api.whatsonchain.com/v1/bsv/main/tx/raw"
                                     : nil)
        }
    }

    private let configuration: Configuration
    private let session: URLSession

    public init(configuration: Configuration, session: URLSession? = nil) {
        self.configuration = configuration
        if let session {
            self.session = session
        } else {
            let config = URLSessionConfiguration.default
            config.timeoutIntervalForRequest = 20
            config.waitsForConnectivity = true
            self.session = URLSession(configuration: config)
        }
    }

    public nonisolated var supportsUTXOFetch: Bool { true }

    // MARK: Requests

    private func request(_ urlString: String, method: String = "GET", body: Data? = nil,
                         contentType: String? = nil) throws -> URLRequest {
        guard let url = URL(string: urlString) else { throw AdapterError.badURL }
        var request = URLRequest(url: url)
        request.httpMethod = method
        request.httpBody = body
        if let contentType { request.setValue(contentType, forHTTPHeaderField: "Content-Type") }
        for (field, value) in configuration.headers { request.setValue(value, forHTTPHeaderField: field) }
        return request
    }

    /// `session.data(for:)` with a short backoff on 429.
    ///
    /// The sync fires a burst — one watch call per followed address, a getTx
    /// per new transaction, plus the UTXO fetch — and nginx on the endpoint
    /// rate-limits bursts. A 429 is the server saying "not right now", so the
    /// answer is to wait briefly and ask again, not to surface a page of HTML.
    /// Two retries with growing pauses ride out the window; a 429 that
    /// survives both is returned to the caller as a normal response.
    private func data(retrying request: URLRequest) async throws -> (Data, URLResponse) {
        let pauses: [UInt64] = [1_200_000_000, 2_500_000_000]  // 1.2 s, 2.5 s
        var attempt = 0
        while true {
            let (data, response) = try await session.data(for: request)
            guard let http = response as? HTTPURLResponse, http.statusCode == 429,
                  attempt < pauses.count else {
                return (data, response)
            }
            try await Task.sleep(nanoseconds: pauses[attempt])
            attempt += 1
        }
    }

    public func getTx(_ txid: String) async throws -> ChainTx? {
        let urlString = configuration.getTxURL.replacingOccurrences(of: "{txid}", with: txid)
        let (data, response) = try await self.data(retrying: try request(urlString))
        guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
            return nil
        }

        // The endpoint may answer with JSON or a bare hex string.
        if let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
            let hex = (object["hex"] ?? object["rawtx"] ?? object["raw"]) as? String
            guard let hex else { return nil }
            let height = (object["height"] ?? object["blockheight"]) as? Int
            let pos = object["pos"] as? Int
            return ChainTx(hex: hex, height: height, pos: pos)
        }

        let text = String(decoding: data, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return nil }
        return ChainTx(hex: text, height: nil, pos: nil)
    }

    public func watchAddress(_ address: String, since: Int) async throws -> [AddressActivity] {
        let urlString = configuration.watchURL
            .replacingOccurrences(of: "{address}", with: address)
            .replacingOccurrences(of: "{since}", with: String(since))
        let (data, response) = try await self.data(retrying: try request(urlString))
        guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
            return []
        }

        let root = try? JSONSerialization.jsonObject(with: data)
        let list: [[String: Any]]
        if let array = root as? [[String: Any]] {
            list = array
        } else if let object = root as? [String: Any], let txs = object["txs"] as? [[String: Any]] {
            list = txs
        } else {
            return []
        }

        return list.enumerated().compactMap { index, entry in
            guard let txid = (entry["txid"] ?? entry["tx_hash"]) as? String else { return nil }
            let height = (entry["height"] ?? entry["blockheight"]) as? Int
            let pos = entry["pos"] as? Int
            let seq = (entry["seq"] as? Int) ?? height ?? (since + index + 1)
            return AddressActivity(txid: txid, height: height, pos: pos, seq: seq)
        }
    }

    @discardableResult
    public func broadcast(_ rawHex: String) async throws -> String {
        let request = try request(configuration.broadcastURL,
                                  method: "POST",
                                  body: Data(rawHex.utf8),
                                  contentType: "text/plain")
        let (data, response) = try await self.data(retrying: request)
        let text = String(decoding: data, as: UTF8.self)
        guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
            throw AdapterError.broadcastRejected(String(text.prefix(200)))
        }

        // Best-effort second delivery path; failures here are not fatal.
        if let mirror = configuration.mirrorBroadcastURL, let mirrorURL = URL(string: mirror) {
            // Built as a `let` so it can be captured by the detached task
            // without tripping the "captured var in concurrent code" rule.
            let mirrorRequest: URLRequest = {
                var request = URLRequest(url: mirrorURL)
                request.httpMethod = "POST"
                request.setValue("application/json", forHTTPHeaderField: "Content-Type")
                request.httpBody = try? JSONSerialization.data(withJSONObject: ["txhex": rawHex])
                return request
            }()
            Task.detached { [session, mirrorRequest] in
                _ = try? await session.data(for: mirrorRequest)
            }
        }

        if let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
           let txid = object["txid"] as? String {
            return txid
        }
        return text.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    public func fetchUTXOs(_ address: String) async throws -> [UTXO] {
        let template = configuration.utxoURL.isEmpty
            ? Settings.defaultEndpoints.utxo
            : configuration.utxoURL
        let urlString = template.replacingOccurrences(of: "{address}", with: address)
        let (data, response) = try await self.data(retrying: try request(urlString))
        guard let http = response as? HTTPURLResponse else { throw AdapterError.badURL }
        guard (200..<300).contains(http.statusCode) else {
            throw AdapterError.http(http.statusCode, String(decoding: data, as: UTF8.self).prefix(200).description)
        }

        let root = try? JSONSerialization.jsonObject(with: data)
        let list: [[String: Any]]
        if let array = root as? [[String: Any]] {
            list = array
        } else if let object = root as? [String: Any], let result = object["result"] as? [[String: Any]] {
            list = result
        } else {
            return []
        }

        return list.compactMap { entry in
            guard let txid = (entry["tx_hash"] ?? entry["txid"]) as? String else { return nil }
            // `UInt32(exactly:)`, never `UInt32(_:)`: a negative or oversized
            // index from a hostile or buggy endpoint would trap and crash the
            // sync loop on every launch. One malformed entry is skipped, not
            // fatal — the same rule the OpNS index decoder follows.
            let voutValue = (entry["tx_pos"] ?? entry["vout"]) as? Int ?? 0
            guard let vout = UInt32(exactly: voutValue) else { return nil }
            let satoshis = (entry["value"] ?? entry["satoshis"]) as? Int ?? 0
            let height = entry["height"] as? Int ?? 0
            return UTXO(txid: txid,
                        vout: vout,
                        satoshis: UInt64(max(0, satoshis)),
                        confirmed: height > 0)
        }
    }
}
