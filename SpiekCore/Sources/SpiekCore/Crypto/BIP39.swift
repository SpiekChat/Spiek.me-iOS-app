import Foundation

/// PBKDF2-HMAC-SHA512, the key stretch BIP-39 uses to turn a mnemonic into a
/// 64-byte seed.
public enum PBKDF2 {
    public static func deriveSHA512(password: [UInt8],
                                    salt: [UInt8],
                                    iterations: Int,
                                    keyLength: Int) -> [UInt8] {
        precondition(iterations > 0 && keyLength > 0)
        let hashLength = 64
        let blockCount = (keyLength + hashLength - 1) / hashLength

        var output = [UInt8]()
        output.reserveCapacity(blockCount * hashLength)

        for block in 1...blockCount {
            var counter = [UInt8]()
            for shift in [24, 16, 8, 0] { counter.append(UInt8((block >> shift) & 0xff)) }

            var u = Hash.hmacSHA512(key: password, message: salt + counter)
            var accumulator = u
            for _ in 1..<iterations {
                u = Hash.hmacSHA512(key: password, message: u)
                for i in 0..<hashLength { accumulator[i] ^= u[i] }
            }
            output.append(contentsOf: accumulator)
        }
        return Array(output.prefix(keyLength))
    }
}

/// BIP-32 private child key derivation, enough for one hardened/normal path.
public enum BIP32 {
    public struct ExtendedKey {
        public var key: Scalar
        public var chainCode: [UInt8]
    }

    public static let hardenedOffset: UInt32 = 0x8000_0000

    /// The master key: HMAC-SHA512 over the seed, keyed with "Bitcoin seed".
    public static func master(seed: [UInt8]) -> ExtendedKey? {
        let i = Hash.hmacSHA512(key: Array("Bitcoin seed".utf8), message: seed)
        guard let left = U256(bigEndianBytes: Array(i[0..<32])),
              !left.isZero, left < Scalar.n else { return nil }
        return ExtendedKey(key: Scalar(left), chainCode: Array(i[32...]))
    }

    /// CKDpriv. A hardened index commits to the private key, a normal index to
    /// the public one; an out-of-range result retries with the next index, as
    /// the specification requires.
    public static func child(_ parent: ExtendedKey, index: UInt32) -> ExtendedKey? {
        var index = index
        for _ in 0..<8 {
            var data = [UInt8]()
            if index >= hardenedOffset {
                data.append(0x00)
                data.append(contentsOf: parent.key.bigEndianBytes)
            } else {
                guard let pub = ECPoint.generator
                    .multiplied(by: parent.key)
                    .encoded(compressed: true) else { return nil }
                data.append(contentsOf: pub)
            }
            for shift in [24, 16, 8, 0] as [UInt32] {
                data.append(UInt8((index >> shift) & 0xff))
            }

            let i = Hash.hmacSHA512(key: parent.chainCode, message: data)
            guard let left = U256(bigEndianBytes: Array(i[0..<32])) else { return nil }

            if left >= Scalar.n {
                index = index &+ 1
                continue
            }
            let childKey = Scalar(left) + parent.key
            if childKey.isZero {
                index = index &+ 1
                continue
            }
            return ExtendedKey(key: childKey, chainCode: Array(i[32...]))
        }
        return nil
    }

    public static func derive(seed: [UInt8], path: [UInt32]) -> Scalar? {
        guard var node = master(seed: seed) else { return nil }
        for index in path {
            guard let next = child(node, index: index) else { return nil }
            node = next
        }
        return node.key
    }
}

/// BIP-39 mnemonics, 128 bits of entropy plus a 4-bit checksum — twelve words.
public enum BIP39 {
    public static let wordCount = 12
    private static let entropyBytes = 16

    /// Where Spiek's key lives: m/44'/236'/0'/0/0. 236 is BSV's registered
    /// coin type.
    public static let derivationPath: [UInt32] = [
        BIP32.hardenedOffset + 44,
        BIP32.hardenedOffset + 236,
        BIP32.hardenedOffset + 0,
        0,
        0,
    ]

    private static let indexByWord: [String: Int] = {
        var map = [String: Int](minimumCapacity: 2048)
        for (index, word) in Wordlist.english.enumerated() { map[word] = index }
        return map
    }()

    public static func words(in phrase: String) -> [String] {
        phrase.trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
            .split(whereSeparator: { $0.isWhitespace })
            .map(String.init)
    }

    /// Words that are not in the list at all — reported so the user can fix a
    /// typo rather than being told the whole phrase is wrong.
    public static func unknownWords(in phrase: String) -> [String] {
        words(in: phrase).filter { indexByWord[$0] == nil }
    }

    public static func isValid(_ phrase: String) -> Bool {
        let list = words(in: phrase)
        guard list.count == wordCount else { return false }

        var bits = [Bool]()
        bits.reserveCapacity(wordCount * 11)
        for word in list {
            guard let index = indexByWord[word] else { return false }
            for bit in stride(from: 10, through: 0, by: -1) {
                bits.append((index >> bit) & 1 == 1)
            }
        }

        var entropy = [UInt8](repeating: 0, count: entropyBytes)
        for i in 0..<(entropyBytes * 8) where bits[i] {
            entropy[i / 8] |= 1 << (7 - UInt8(i % 8))
        }

        var checksum: UInt8 = 0
        for i in 0..<4 where bits[entropyBytes * 8 + i] {
            checksum |= 1 << (3 - UInt8(i))
        }
        return Hash.sha256(entropy)[0] >> 4 == checksum
    }

    public static func generate() -> String {
        // `SecureRandom.bytes` always returns exactly the requested count, and
        // `phrase(fromEntropy:)` only returns nil on a length mismatch, so this
        // cannot fail. The old fallback returned `Wordlist.english[0]` — a
        // one-word "phrase" that is not recoverable and crashes the onboarding
        // quiz. Failing loudly is the only honest option left.
        let entropy = SecureRandom.bytes(entropyBytes)
        guard let phrase = phrase(fromEntropy: entropy) else {
            preconditionFailure("BIP-39: \(entropyBytes) bytes of entropy produced no phrase.")
        }
        return phrase
    }

    public static func phrase(fromEntropy entropy: [UInt8]) -> String? {
        guard entropy.count == entropyBytes else { return nil }

        var bits = [Bool]()
        bits.reserveCapacity(wordCount * 11)
        for byte in entropy {
            for bit in stride(from: 7, through: 0, by: -1) {
                bits.append((byte >> UInt8(bit)) & 1 == 1)
            }
        }
        let checksum = Hash.sha256(entropy)[0] >> 4
        for bit in stride(from: 3, through: 0, by: -1) {
            bits.append((checksum >> UInt8(bit)) & 1 == 1)
        }

        var result = [String]()
        for wordIndex in 0..<wordCount {
            var value = 0
            for bit in 0..<11 {
                value = value << 1 | (bits[wordIndex * 11 + bit] ? 1 : 0)
            }
            result.append(Wordlist.english[value])
        }
        return result.joined(separator: " ")
    }

    /// PBKDF2-HMAC-SHA512, 2048 rounds, salt "mnemonic" — no extra passphrase.
    public static func seed(from phrase: String, passphrase: String = "") -> [UInt8] {
        // BIP-39 specifies NFKD for both the mnemonic and the salt. It makes
        // no difference for the English list, but other languages need it.
        let normalized = words(in: phrase).joined(separator: " ")
        return PBKDF2.deriveSHA512(
            password: Array(normalized.decomposedStringWithCompatibilityMapping.utf8),
            salt: Array(("mnemonic" + passphrase).decomposedStringWithCompatibilityMapping.utf8),
            iterations: 2048,
            keyLength: 64
        )
    }

    public static func privateKey(from phrase: String, passphrase: String = "") throws -> PrivateKey {
        guard let scalar = BIP32.derive(seed: seed(from: phrase, passphrase: passphrase),
                                        path: derivationPath) else {
            throw KeyError.invalidPhrase
        }
        return try PrivateKey(scalar: scalar)
    }
}
