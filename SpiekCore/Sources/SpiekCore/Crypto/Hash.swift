import Foundation

public enum Hash {
    public static func sha256<C: Collection>(_ data: C) -> [UInt8] where C.Element == UInt8 {
        SHA256Core.hash(data)
    }

    /// Double SHA-256 — Bitcoin's transaction and block digest.
    public static func sha256d<C: Collection>(_ data: C) -> [UInt8] where C.Element == UInt8 {
        SHA256Core.hash(SHA256Core.hash(data))
    }

    public static func ripemd160<C: Collection>(_ data: C) -> [UInt8] where C.Element == UInt8 {
        RIPEMD160.hash(data)
    }

    /// RIPEMD160(SHA256(x)) — the 20-byte identifier behind every address.
    public static func hash160<C: Collection>(_ data: C) -> [UInt8] where C.Element == UInt8 {
        RIPEMD160.hash(SHA256Core.hash(data))
    }

    public static func hmacSHA256(key: [UInt8], message: [UInt8]) -> [UInt8] {
        hmac(key: key, message: message, blockSize: 64, hash: SHA256Core.hash)
    }

    public static func hmacSHA512(key: [UInt8], message: [UInt8]) -> [UInt8] {
        hmac(key: key, message: message, blockSize: 128, hash: SHA512Core.hash)
    }

    private static func hmac(key: [UInt8],
                             message: [UInt8],
                             blockSize: Int,
                             hash: ([UInt8]) -> [UInt8]) -> [UInt8] {
        var k = key
        if k.count > blockSize { k = hash(k) }
        if k.count < blockSize { k += [UInt8](repeating: 0, count: blockSize - k.count) }

        var inner = [UInt8](repeating: 0, count: blockSize)
        var outer = [UInt8](repeating: 0, count: blockSize)
        for i in 0..<blockSize {
            inner[i] = k[i] ^ 0x36
            outer[i] = k[i] ^ 0x5c
        }
        return hash(outer + hash(inner + message))
    }
}
