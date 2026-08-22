import Foundation

/// Fixed-width 256-bit unsigned integer, stored as four little-endian 64-bit
/// limbs (`w0` is the least significant). Only what secp256k1 needs.
public struct U256: Equatable, Comparable, Hashable, Sendable {
    public var w0: UInt64
    public var w1: UInt64
    public var w2: UInt64
    public var w3: UInt64

    public static let zero = U256(0, 0, 0, 0)
    public static let one = U256(1, 0, 0, 0)

    @inline(__always)
    public init(_ w0: UInt64, _ w1: UInt64, _ w2: UInt64, _ w3: UInt64) {
        self.w0 = w0; self.w1 = w1; self.w2 = w2; self.w3 = w3
    }

    @inline(__always)
    public init(_ value: UInt64) { self.init(value, 0, 0, 0) }

    /// Big-endian bytes; accepts fewer than 32 bytes (left-padded with zero).
    public init?(bigEndianBytes bytes: [UInt8]) {
        guard bytes.count <= 32 else { return nil }
        var padded = [UInt8](repeating: 0, count: 32 - bytes.count)
        padded.append(contentsOf: bytes)
        var limbs = [UInt64](repeating: 0, count: 4)
        for i in 0..<4 {
            var v: UInt64 = 0
            for j in 0..<8 { v = v << 8 | UInt64(padded[i * 8 + j]) }
            limbs[3 - i] = v
        }
        self.init(limbs[0], limbs[1], limbs[2], limbs[3])
    }

    public var bigEndianBytes: [UInt8] {
        var out = [UInt8]()
        out.reserveCapacity(32)
        for limb in [w3, w2, w1, w0] {
            for i in (0..<8).reversed() { out.append(UInt8((limb >> (8 * UInt64(i))) & 0xff)) }
        }
        return out
    }

    public var isZero: Bool { w0 == 0 && w1 == 0 && w2 == 0 && w3 == 0 }
    public var isOdd: Bool { w0 & 1 == 1 }

    @inline(__always)
    public subscript(limb index: Int) -> UInt64 {
        get {
            switch index {
            case 0: return w0
            case 1: return w1
            case 2: return w2
            default: return w3
            }
        }
        set {
            switch index {
            case 0: w0 = newValue
            case 1: w1 = newValue
            case 2: w2 = newValue
            default: w3 = newValue
            }
        }
    }

    public static func < (lhs: U256, rhs: U256) -> Bool {
        if lhs.w3 != rhs.w3 { return lhs.w3 < rhs.w3 }
        if lhs.w2 != rhs.w2 { return lhs.w2 < rhs.w2 }
        if lhs.w1 != rhs.w1 { return lhs.w1 < rhs.w1 }
        return lhs.w0 < rhs.w0
    }

    public var bitWidth: Int {
        if w3 != 0 { return 256 - w3.leadingZeroBitCount }
        if w2 != 0 { return 192 - w2.leadingZeroBitCount }
        if w1 != 0 { return 128 - w1.leadingZeroBitCount }
        if w0 != 0 { return 64 - w0.leadingZeroBitCount }
        return 0
    }

    @inline(__always)
    public func bit(_ index: Int) -> Bool {
        guard index >= 0 && index < 256 else { return false }
        return (self[limb: index >> 6] >> UInt64(index & 63)) & 1 == 1
    }

    // MARK: Arithmetic

    /// Returns `self + other` truncated to 256 bits, plus the carry out.
    @inline(__always)
    public func addingReportingCarry(_ other: U256) -> (U256, UInt64) {
        var result = U256.zero
        var carry: UInt64 = 0
        for i in 0..<4 {
            let (s1, o1) = self[limb: i].addingReportingOverflow(other[limb: i])
            let (s2, o2) = s1.addingReportingOverflow(carry)
            result[limb: i] = s2
            carry = (o1 ? 1 : 0) + (o2 ? 1 : 0)
        }
        return (result, carry)
    }

    /// Returns `self - other` truncated to 256 bits, plus the borrow out.
    @inline(__always)
    public func subtractingReportingBorrow(_ other: U256) -> (U256, UInt64) {
        var result = U256.zero
        var borrow: UInt64 = 0
        for i in 0..<4 {
            let (d1, o1) = self[limb: i].subtractingReportingOverflow(other[limb: i])
            let (d2, o2) = d1.subtractingReportingOverflow(borrow)
            result[limb: i] = d2
            borrow = (o1 ? 1 : 0) + (o2 ? 1 : 0)
        }
        return (result, borrow)
    }

    /// Full 512-bit product, returned as eight little-endian limbs.
    public func multipliedFullWidth(by other: U256) -> [UInt64] {
        var out = [UInt64](repeating: 0, count: 8)
        for i in 0..<4 {
            var carry: UInt64 = 0
            let a = self[limb: i]
            if a == 0 { continue }
            for j in 0..<4 {
                let (high, low) = a.multipliedFullWidth(by: other[limb: j])
                // out[i+j] += low + carry, tracking overflow into `high`
                var hi = high
                let (s1, o1) = out[i + j].addingReportingOverflow(low)
                if o1 { hi &+= 1 }
                let (s2, o2) = s1.addingReportingOverflow(carry)
                if o2 { hi &+= 1 }
                out[i + j] = s2
                carry = hi
            }
            var k = i + 4
            while carry != 0 && k < 8 {
                let (s, o) = out[k].addingReportingOverflow(carry)
                out[k] = s
                carry = o ? 1 : 0
                k += 1
            }
        }
        return out
    }

    @inline(__always)
    public func shiftedRightByOne() -> U256 {
        U256(w0 >> 1 | w1 << 63,
             w1 >> 1 | w2 << 63,
             w2 >> 1 | w3 << 63,
             w3 >> 1)
    }

    @inline(__always)
    public func shiftedLeftByOne() -> (U256, UInt64) {
        let carry = w3 >> 63
        return (U256(w0 << 1,
                     w1 << 1 | w0 >> 63,
                     w2 << 1 | w1 >> 63,
                     w3 << 1 | w2 >> 63), carry)
    }

    // MARK: Generic modular reduction

    /// Reduce an arbitrary 512-bit value (eight little-endian limbs) modulo
    /// `modulus` using bitwise long division. Correct but not fast — used only
    /// on the rare paths (scalar reduction, RFC 6979) rather than in the field.
    public static func reduce512(_ value: [UInt64], modulo modulus: U256) -> U256 {
        precondition(value.count == 8)
        var remainder = U256.zero
        for bitIndex in stride(from: 511, through: 0, by: -1) {
            let limb = value[bitIndex >> 6]
            let bit = (limb >> UInt64(bitIndex & 63)) & 1

            var (shifted, overflow) = remainder.shiftedLeftByOne()
            shifted.w0 |= bit

            if overflow == 1 {
                // The shifted value is >= 2^256 > modulus, so one subtraction
                // brings it back into range (modulus > 2^255 for both p and n).
                let (reduced, borrow) = shifted.subtractingReportingBorrow(modulus)
                shifted = reduced
                overflow = borrow == 0 ? 1 : 0
            }
            if shifted >= modulus {
                let (reduced, _) = shifted.subtractingReportingBorrow(modulus)
                shifted = reduced
            }
            remainder = shifted
        }
        return remainder
    }

    public static func mod(_ value: U256, _ modulus: U256) -> U256 {
        var v = value
        while v >= modulus {
            let (r, _) = v.subtractingReportingBorrow(modulus)
            v = r
        }
        return v
    }
}
