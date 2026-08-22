import Foundation

/// Bitcoin's Base58 alphabet, plus the 4-byte double-SHA256 checksum wrapper
/// used for addresses and WIF keys.
public enum Base58 {
    private static let alphabet = Array("123456789ABCDEFGHJKLMNPQRSTUVWXYZabcdefghijkmnopqrstuvwxyz".utf8)
    private static let decodeMap: [Int8] = {
        var map = [Int8](repeating: -1, count: 128)
        for (i, c) in alphabet.enumerated() { map[Int(c)] = Int8(i) }
        return map
    }()

    public static func encode(_ input: [UInt8]) -> String {
        guard !input.isEmpty else { return "" }

        // Count leading zero bytes — each becomes a literal '1'.
        var zeros = 0
        while zeros < input.count && input[zeros] == 0 { zeros += 1 }

        // Base-256 -> base-58 by repeated division.
        var digits = [UInt8](repeating: 0, count: (input.count - zeros) * 138 / 100 + 1)
        var length = 0
        for i in zeros..<input.count {
            var carry = Int(input[i])
            var j = 0
            var k = digits.count - 1
            while k >= 0 && (carry != 0 || j < length) {
                carry += 256 * Int(digits[k])
                digits[k] = UInt8(carry % 58)
                carry /= 58
                j += 1
                k -= 1
            }
            length = j
        }

        var out = [UInt8](repeating: alphabet[0], count: zeros)
        var start = digits.count - length
        while start < digits.count {
            out.append(alphabet[Int(digits[start])])
            start += 1
        }
        return String(decoding: out, as: UTF8.self)
    }

    public static func decode(_ input: String) -> [UInt8]? {
        guard !input.isEmpty else { return [] }
        let chars = Array(input.utf8)

        var zeros = 0
        while zeros < chars.count && chars[zeros] == alphabet[0] { zeros += 1 }

        var bytes = [UInt8](repeating: 0, count: chars.count * 733 / 1000 + 1)
        var length = 0
        for i in zeros..<chars.count {
            let c = Int(chars[i])
            guard c < 128 else { return nil }
            let digit = decodeMap[c]
            guard digit >= 0 else { return nil }

            var carry = Int(digit)
            var j = 0
            var k = bytes.count - 1
            while k >= 0 && (carry != 0 || j < length) {
                carry += 58 * Int(bytes[k])
                bytes[k] = UInt8(carry % 256)
                carry /= 256
                j += 1
                k -= 1
            }
            length = j
        }

        var out = [UInt8](repeating: 0, count: zeros)
        out.append(contentsOf: bytes[(bytes.count - length)...])
        return out
    }

    // MARK: Checked

    public static func encodeCheck(payload: [UInt8], prefix: [UInt8]) -> String {
        let body = prefix + payload
        let checksum = Array(Hash.sha256d(body).prefix(4))
        return encode(body + checksum)
    }

    public struct Checked {
        public let prefix: [UInt8]
        public let payload: [UInt8]
    }

    /// - Parameter prefixLength: how many leading bytes are version bytes.
    public static func decodeCheck(_ string: String, prefixLength: Int = 1) -> Checked? {
        guard let raw = decode(string), raw.count >= prefixLength + 4 else { return nil }
        let body = Array(raw[0..<(raw.count - 4)])
        let checksum = Array(raw[(raw.count - 4)...])
        let expected = Array(Hash.sha256d(body).prefix(4))
        guard constantTimeEquals(checksum, expected) else { return nil }
        return Checked(prefix: Array(body[0..<prefixLength]),
                       payload: Array(body[prefixLength...]))
    }
}
