import Foundation

public enum KeyError: Error, LocalizedError {
    case invalidWIF
    case invalidPrivateKey
    case invalidPublicKey
    case invalidAddress
    case invalidPhrase

    public var errorDescription: String? {
        switch self {
        case .invalidWIF: return "This is not a valid WIF key."
        case .invalidPrivateKey: return "This private key is out of range."
        case .invalidPublicKey: return "This public key is not a point on the curve."
        case .invalidAddress: return "This is not a valid address."
        case .invalidPhrase: return "Enter 12 words, or a WIF key."
        }
    }
}

public struct PublicKey: Equatable, Hashable, Sendable {
    public let point: ECPoint
    public let compressedBytes: [UInt8]

    public init?(point: ECPoint) {
        guard !point.isInfinity, let encoded = point.encoded(compressed: true) else { return nil }
        self.point = point
        self.compressedBytes = encoded
    }

    public init?(bytes: [UInt8]) {
        guard let point = ECPoint.decode(bytes) else { return nil }
        self.init(point: point)
    }

    public var uncompressedBytes: [UInt8]? { point.encoded(compressed: false) }

    /// hash160 of the compressed encoding — the 20 bytes inside a P2PKH address.
    public var hash160: [UInt8] { Hash.hash160(compressedBytes) }

    public var address: String { Address.encode(hash160: hash160) }

    public static func == (lhs: PublicKey, rhs: PublicKey) -> Bool {
        lhs.compressedBytes == rhs.compressedBytes
    }

    public func hash(into hasher: inout Hasher) {
        hasher.combine(compressedBytes)
    }
}

public struct PrivateKey: Equatable, Sendable {
    public let scalar: Scalar
    public let publicKey: PublicKey

    public init(scalar: Scalar) throws {
        guard !scalar.isZero, scalar.value < Scalar.n else { throw KeyError.invalidPrivateKey }
        guard let pub = PublicKey(point: ECPoint.generator.multiplied(by: scalar)) else {
            throw KeyError.invalidPrivateKey
        }
        self.scalar = scalar
        self.publicKey = pub
    }

    public init(bytes: [UInt8]) throws {
        guard bytes.count == 32, let value = U256(bigEndianBytes: bytes) else {
            throw KeyError.invalidPrivateKey
        }
        try self.init(scalar: Scalar(value))
    }

    public init(hex: String) throws {
        guard let bytes = Hex.decode(hex) else { throw KeyError.invalidPrivateKey }
        try self.init(bytes: bytes)
    }

    public static func random() throws -> PrivateKey {
        for _ in 0..<64 {
            let candidate = SecureRandom.bytes(32)
            if let key = try? PrivateKey(bytes: candidate) { return key }
        }
        throw KeyError.invalidPrivateKey
    }

    public var bytes: [UInt8] { scalar.bigEndianBytes }
    public var hex: String { bytes.hex }
    public var address: String { publicKey.address }

    // MARK: WIF

    /// Mainnet WIF for a compressed key: base58check(0x80 || key || 0x01).
    public var wif: String {
        Base58.encodeCheck(payload: bytes + [0x01], prefix: [0x80])
    }

    public init(wif: String) throws {
        guard let decoded = Base58.decodeCheck(wif, prefixLength: 1),
              decoded.prefix == [0x80] || decoded.prefix == [0xef],
              decoded.payload.count == 33,
              decoded.payload[32] == 0x01 else { throw KeyError.invalidWIF }
        try self.init(bytes: Array(decoded.payload[0..<32]))
    }

    // MARK: Operations

    public func sign(digest: [UInt8]) -> ECDSASignature? {
        ECDSA.sign(digest: digest, privateKey: scalar)
    }

    /// The raw shared EC point with `other`, SEC1-compressed.
    public func sharedSecret(with other: PublicKey) -> [UInt8]? {
        ECDSA.sharedSecret(privateKey: scalar, publicKey: other.point)
    }

    /// The AES-256 key Spiek derives for a conversation: SHA256 of the
    /// compressed shared point.
    public func conversationKey(with other: PublicKey) -> [UInt8]? {
        guard let shared = sharedSecret(with: other) else { return nil }
        return Hash.sha256(shared)
    }
}

public enum Address {
    /// Mainnet P2PKH version byte.
    public static let mainnetVersion: UInt8 = 0x00

    public static func encode(hash160: [UInt8], version: UInt8 = mainnetVersion) -> String {
        Base58.encodeCheck(payload: hash160, prefix: [version])
    }

    public static func hash160(from address: String, version: UInt8 = mainnetVersion) -> [UInt8]? {
        // The version byte is checked, not just the checksum. Without it a
        // BTC P2SH address ("3…"), a Litecoin "L…" or a testnet address —
        // all valid Base58Check with a 20-byte payload — would be accepted
        // and paid as a mainnet P2PKH, burning the coins.
        guard let decoded = Base58.decodeCheck(address, prefixLength: 1),
              decoded.prefix == [version],
              decoded.payload.count == 20 else { return nil }
        return decoded.payload
    }

    public static func isValid(_ address: String) -> Bool {
        hash160(from: address) != nil
    }
}

// MARK: - Recovery phrase

/// How a twelve-word phrase becomes a private key.
///
/// New accounts use standard BIP-39: the words carry a checksum, and the key
/// comes out of the seed at m/44'/236'/0'/0/0. Accounts created before that
/// used a single SHA-256 over the phrase, so restoring falls back to that
/// scheme when the checksum does not hold — and can be forced to it, for a
/// phrase that happens to check out under both.
public enum PhraseScheme: String, Codable, Sendable {
    case bip39
    case legacy
}

public enum RecoveryPhrase {
    public static let wordCount = 12

    public struct Restored {
        public let key: PrivateKey
        /// Nil when a bare WIF key was pasted rather than a phrase.
        public let phrase: String?
        public let scheme: PhraseScheme?
        /// True when the words did not carry a valid BIP-39 checksum and the
        /// legacy scheme was used instead — worth telling the user.
        public let fellBackToLegacy: Bool
    }

    public enum PhraseError: Error, LocalizedError, Equatable {
        case wrongWordCount(Int)
        case unknownWords([String])

        public var errorDescription: String? {
            switch self {
            case let .wrongWordCount(count):
                return "A recovery phrase has 12 words — you entered \(count)."
            case let .unknownWords(words):
                let list = words.joined(separator: ", ")
                return words.count == 1
                    ? "Unknown word: \(list) — check for typos."
                    : "Unknown words: \(list) — check for typos."
            }
        }
    }

    /// A fresh BIP-39 mnemonic.
    public static func generate() -> String {
        BIP39.generate()
    }

    public static func normalize(_ phrase: String) -> String {
        phrase.trimmingCharacters(in: .whitespacesAndNewlines)
            .split(whereSeparator: { $0.isWhitespace })
            .joined(separator: " ")
    }

    public static func words(in phrase: String) -> [String] {
        normalize(phrase).split(separator: " ").map(String.init)
    }

    public static func isValidBIP39(_ phrase: String) -> Bool {
        BIP39.isValid(phrase)
    }

    /// Accepts either a 12-word phrase or a WIF key, mirroring the web app's
    /// single "restore" field.
    public static func restore(_ input: String, forceLegacy: Bool = false) throws -> Restored {
        let normalized = normalize(input)
        guard !normalized.isEmpty else { throw KeyError.invalidPhrase }

        let list = normalized.lowercased().split(separator: " ").map(String.init)
        if list.count == 1 {
            return Restored(key: try PrivateKey(wif: normalized),
                            phrase: nil,
                            scheme: nil,
                            fellBackToLegacy: false)
        }
        guard list.count == wordCount else {
            throw PhraseError.wrongWordCount(list.count)
        }

        let phrase = list.joined(separator: " ")
        let unknown = BIP39.unknownWords(in: phrase)
        guard unknown.isEmpty else { throw PhraseError.unknownWords(unknown) }

        if !forceLegacy, BIP39.isValid(phrase) {
            return Restored(key: try BIP39.privateKey(from: phrase),
                            phrase: phrase,
                            scheme: .bip39,
                            fellBackToLegacy: false)
        }

        return Restored(key: try legacyKey(forPhrase: phrase),
                        phrase: phrase,
                        scheme: .legacy,
                        fellBackToLegacy: !forceLegacy)
    }

    /// The key for a phrase under a known scheme.
    public static func key(forPhrase phrase: String, scheme: PhraseScheme) throws -> PrivateKey {
        switch scheme {
        case .bip39: return try BIP39.privateKey(from: phrase)
        case .legacy: return try legacyKey(forPhrase: phrase)
        }
    }

    /// The pre-BIP-39 scheme: a single SHA-256 over the lowercased phrase.
    public static func legacyKey(forPhrase phrase: String) throws -> PrivateKey {
        let lowercased = normalize(phrase).lowercased()
        return try PrivateKey(bytes: Hash.sha256(Array(lowercased.utf8)))
    }
}
