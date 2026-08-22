import Foundation

// MARK: - Hex

public enum Hex {
    private static let table: [Character] = Array("0123456789abcdef")

    public static func encode<C: Collection>(_ bytes: C) -> String where C.Element == UInt8 {
        var out = String()
        out.reserveCapacity(bytes.count * 2)
        for b in bytes {
            out.append(table[Int(b >> 4)])
            out.append(table[Int(b & 0x0f)])
        }
        return out
    }

    public static func decode(_ string: String) -> [UInt8]? {
        let chars = Array(string.utf8)
        guard chars.count % 2 == 0 else { return nil }
        var out = [UInt8]()
        out.reserveCapacity(chars.count / 2)
        var i = 0
        while i < chars.count {
            guard let hi = nibble(chars[i]), let lo = nibble(chars[i + 1]) else { return nil }
            out.append(hi << 4 | lo)
            i += 2
        }
        return out
    }

    private static func nibble(_ c: UInt8) -> UInt8? {
        switch c {
        case 0x30...0x39: return c - 0x30
        case 0x61...0x66: return c - 0x61 + 10
        case 0x41...0x46: return c - 0x41 + 10
        default: return nil
        }
    }
}

public extension Array where Element == UInt8 {
    var hex: String { Hex.encode(self) }

    /// Reverses byte order — used to move between transaction-id display order
    /// (big endian) and wire order (little endian).
    var reversedBytes: [UInt8] { Array(self.reversed()) }

    init?(hex: String) {
        guard let b = Hex.decode(hex) else { return nil }
        self = b
    }
}

public extension Data {
    var bytes: [UInt8] { [UInt8](self) }
    var hex: String { Hex.encode(self) }
}

// MARK: - Little-endian writer

/// Minimal serialiser for Bitcoin wire format.
public struct ByteWriter {
    public private(set) var bytes: [UInt8] = []

    public init() {}
    public init(reserving capacity: Int) { bytes.reserveCapacity(capacity) }

    public mutating func write(_ byte: UInt8) { bytes.append(byte) }
    public mutating func write<C: Collection>(_ chunk: C) where C.Element == UInt8 { bytes.append(contentsOf: chunk) }

    public mutating func writeUInt16LE(_ v: UInt16) {
        bytes.append(UInt8(v & 0xff))
        bytes.append(UInt8((v >> 8) & 0xff))
    }

    public mutating func writeUInt32LE(_ v: UInt32) {
        bytes.append(UInt8(v & 0xff))
        bytes.append(UInt8((v >> 8) & 0xff))
        bytes.append(UInt8((v >> 16) & 0xff))
        bytes.append(UInt8((v >> 24) & 0xff))
    }

    public mutating func writeUInt64LE(_ v: UInt64) {
        for i in 0..<8 { bytes.append(UInt8((v >> (8 * UInt64(i))) & 0xff)) }
    }

    public mutating func writeVarInt(_ v: UInt64) {
        switch v {
        case ..<0xfd:
            bytes.append(UInt8(v))
        case ..<0x1_0000:
            bytes.append(0xfd); writeUInt16LE(UInt16(v))
        case ..<0x1_0000_0000:
            bytes.append(0xfe); writeUInt32LE(UInt32(v))
        default:
            bytes.append(0xff); writeUInt64LE(v)
        }
    }

    public mutating func writeVarBytes<C: Collection>(_ chunk: C) where C.Element == UInt8 {
        writeVarInt(UInt64(chunk.count))
        write(chunk)
    }
}

// MARK: - Little-endian reader

public struct ByteReader {
    public let bytes: [UInt8]
    public private(set) var offset: Int = 0

    public init(_ bytes: [UInt8]) { self.bytes = bytes }

    public var remaining: Int { bytes.count - offset }
    public var isAtEnd: Bool { offset >= bytes.count }

    public mutating func read(_ count: Int) -> [UInt8]? {
        guard count >= 0, remaining >= count else { return nil }
        defer { offset += count }
        return Array(bytes[offset..<(offset + count)])
    }

    public mutating func readUInt8() -> UInt8? {
        guard remaining >= 1 else { return nil }
        defer { offset += 1 }
        return bytes[offset]
    }

    public mutating func readUInt16LE() -> UInt16? {
        guard let b = read(2) else { return nil }
        return UInt16(b[0]) | UInt16(b[1]) << 8
    }

    public mutating func readUInt32LE() -> UInt32? {
        guard let b = read(4) else { return nil }
        return UInt32(b[0]) | UInt32(b[1]) << 8 | UInt32(b[2]) << 16 | UInt32(b[3]) << 24
    }

    public mutating func readUInt64LE() -> UInt64? {
        guard let b = read(8) else { return nil }
        var v: UInt64 = 0
        for i in (0..<8).reversed() { v = v << 8 | UInt64(b[i]) }
        return v
    }

    public mutating func readVarInt() -> UInt64? {
        guard let first = readUInt8() else { return nil }
        switch first {
        case 0xfd: return readUInt16LE().map(UInt64.init)
        case 0xfe: return readUInt32LE().map(UInt64.init)
        case 0xff: return readUInt64LE()
        default: return UInt64(first)
        }
    }

    public mutating func readVarBytes() -> [UInt8]? {
        guard let n = readVarInt(), n <= UInt64(Int.max) else { return nil }
        return read(Int(n))
    }
}

// MARK: - Constant-time compare

@inlinable
public func constantTimeEquals(_ a: [UInt8], _ b: [UInt8]) -> Bool {
    guard a.count == b.count else { return false }
    var diff: UInt8 = 0
    for i in 0..<a.count { diff |= a[i] ^ b[i] }
    return diff == 0
}

// MARK: - Secure random

public enum SecureRandom {
    public static func bytes(_ count: Int) -> [UInt8] {
        var out = [UInt8](repeating: 0, count: count)
        var rng = SystemRandomNumberGenerator()
        for i in 0..<count { out[i] = UInt8.random(in: 0...255, using: &rng) }
        return out
    }

    public static func uint32() -> UInt32 {
        var rng = SystemRandomNumberGenerator()
        return UInt32.random(in: 0...UInt32.max, using: &rng)
    }
}
