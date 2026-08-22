import Foundation

/// Arithmetic in F_p, where p = 2^256 - 2^32 - 977 (the secp256k1 prime).
///
/// Reduction exploits the shape of p: because 2^256 ≡ 2^32 + 977 (mod p), a
/// 512-bit product is folded down by multiplying its high half by the 33-bit
/// constant 0x1000003D1 and adding it back, repeating until nothing carries
/// past the 256-bit boundary.
public struct Fp: Equatable, Sendable {
    /// p = 2^256 - 2^32 - 977
    public static let p = U256(0xFFFF_FFFE_FFFF_FC2F, 0xFFFF_FFFF_FFFF_FFFF,
                               0xFFFF_FFFF_FFFF_FFFF, 0xFFFF_FFFF_FFFF_FFFF)
    /// 2^256 mod p
    private static let foldConstant: UInt64 = 0x1_0000_03D1
    /// p - 2, the exponent for a multiplicative inverse via Fermat's little theorem.
    private static let inverseExponent = U256(0xFFFF_FFFE_FFFF_FC2D, 0xFFFF_FFFF_FFFF_FFFF,
                                              0xFFFF_FFFF_FFFF_FFFF, 0xFFFF_FFFF_FFFF_FFFF)
    /// (p + 1) / 4 = 2^254 - 2^30 - 244, the exponent for a square root
    /// (valid because p ≡ 3 mod 4).
    private static let sqrtExponent = U256(0xFFFF_FFFF_BFFF_FF0C, 0xFFFF_FFFF_FFFF_FFFF,
                                           0xFFFF_FFFF_FFFF_FFFF, 0x3FFF_FFFF_FFFF_FFFF)

    public var value: U256

    public static let zero = Fp(U256.zero)
    public static let one = Fp(U256.one)

    @inline(__always)
    public init(_ value: U256) { self.value = value }

    @inline(__always)
    public init(reducing value: U256) { self.value = U256.mod(value, Fp.p) }

    public init?(bigEndianBytes bytes: [UInt8]) {
        guard let v = U256(bigEndianBytes: bytes), v < Fp.p else { return nil }
        self.value = v
    }

    public var bigEndianBytes: [UInt8] { value.bigEndianBytes }
    public var isZero: Bool { value.isZero }
    public var isOdd: Bool { value.isOdd }

    // MARK: Ring operations

    public static func + (lhs: Fp, rhs: Fp) -> Fp {
        var (sum, carry) = lhs.value.addingReportingCarry(rhs.value)
        if carry == 1 || sum >= p {
            let (reduced, borrow) = sum.subtractingReportingBorrow(p)
            sum = reduced
            // With carry set, the borrow cancels the 2^256 we dropped.
            _ = borrow
        }
        return Fp(sum)
    }

    public static func - (lhs: Fp, rhs: Fp) -> Fp {
        let (diff, borrow) = lhs.value.subtractingReportingBorrow(rhs.value)
        if borrow == 1 {
            let (wrapped, _) = diff.addingReportingCarry(p)
            return Fp(wrapped)
        }
        return Fp(diff)
    }

    public static prefix func - (operand: Fp) -> Fp {
        operand.isZero ? operand : Fp(p.subtractingReportingBorrow(operand.value).0)
    }

    public static func * (lhs: Fp, rhs: Fp) -> Fp {
        Fp(reduce(lhs.value.multipliedFullWidth(by: rhs.value)))
    }

    public func squared() -> Fp { self * self }

    public func doubled() -> Fp { self + self }

    public func tripled() -> Fp { self + self + self }

    // MARK: Reduction

    /// Fold a 512-bit value (eight little-endian limbs) into [0, p).
    static func reduce(_ product: [UInt64]) -> U256 {
        precondition(product.count == 8)
        var acc = product

        while acc[4] != 0 || acc[5] != 0 || acc[6] != 0 || acc[7] != 0 {
            // high = acc >> 256, low = acc mod 2^256
            let high = [acc[4], acc[5], acc[6], acc[7]]
            var next = [acc[0], acc[1], acc[2], acc[3], 0, 0, 0, 0]

            // next += high * foldConstant
            var carry: UInt64 = 0
            for i in 0..<4 {
                let (hi, lo) = high[i].multipliedFullWidth(by: foldConstant)
                var upper = hi
                let (s1, o1) = next[i].addingReportingOverflow(lo)
                if o1 { upper &+= 1 }
                let (s2, o2) = s1.addingReportingOverflow(carry)
                if o2 { upper &+= 1 }
                next[i] = s2
                carry = upper
            }
            var k = 4
            while carry != 0 && k < 8 {
                let (s, o) = next[k].addingReportingOverflow(carry)
                next[k] = s
                carry = o ? 1 : 0
                k += 1
            }
            acc = next
        }

        var result = U256(acc[0], acc[1], acc[2], acc[3])
        while result >= p {
            let (reduced, _) = result.subtractingReportingBorrow(p)
            result = reduced
        }
        return result
    }

    // MARK: Exponentiation

    public func power(_ exponent: U256) -> Fp {
        var result = Fp.one
        var base = self
        var bit = 0
        let width = exponent.bitWidth
        while bit < width {
            if exponent.bit(bit) { result = result * base }
            base = base.squared()
            bit += 1
        }
        return result
    }

    /// Multiplicative inverse; returns zero for zero.
    public func inverted() -> Fp {
        isZero ? Fp.zero : power(Fp.inverseExponent)
    }

    /// A square root if one exists, else nil.
    public func squareRoot() -> Fp? {
        let candidate = power(Fp.sqrtExponent)
        return candidate.squared() == self ? candidate : nil
    }
}

/// Arithmetic modulo n, the order of the secp256k1 group. Used for private
/// keys, nonces and signature scalars.
public struct Scalar: Equatable, Sendable {
    /// n, the curve order.
    public static let n = U256(0xBFD2_5E8C_D036_4141, 0xBAAE_DCE6_AF48_A03B,
                               0xFFFF_FFFF_FFFF_FFFE, 0xFFFF_FFFF_FFFF_FFFF)
    /// n / 2, the low-S boundary.
    public static let halfN = U256(0xDFE9_2F46_681B_20A0, 0x5D57_6E73_57A4_501D,
                                   0xFFFF_FFFF_FFFF_FFFF, 0x7FFF_FFFF_FFFF_FFFF)
    private static let inverseExponent = U256(0xBFD2_5E8C_D036_413F, 0xBAAE_DCE6_AF48_A03B,
                                              0xFFFF_FFFF_FFFF_FFFE, 0xFFFF_FFFF_FFFF_FFFF)

    public var value: U256

    public static let zero = Scalar(U256.zero)
    public static let one = Scalar(U256.one)

    @inline(__always)
    public init(_ value: U256) { self.value = value }

    @inline(__always)
    public init(reducing value: U256) { self.value = U256.mod(value, Scalar.n) }

    public init(reducing512 limbs: [UInt64]) {
        self.value = U256.reduce512(limbs, modulo: Scalar.n)
    }

    /// Reduce arbitrary big-endian bytes (any length) modulo n.
    public init(reducingBigEndianBytes bytes: [UInt8]) {
        var limbs = [UInt64](repeating: 0, count: 8)
        let trimmed = bytes.count > 64 ? Array(bytes.suffix(64)) : bytes
        var padded = [UInt8](repeating: 0, count: 64 - trimmed.count)
        padded.append(contentsOf: trimmed)
        for i in 0..<8 {
            var v: UInt64 = 0
            for j in 0..<8 { v = v << 8 | UInt64(padded[i * 8 + j]) }
            limbs[7 - i] = v
        }
        self.value = U256.reduce512(limbs, modulo: Scalar.n)
    }

    public var bigEndianBytes: [UInt8] { value.bigEndianBytes }
    public var isZero: Bool { value.isZero }
    public var isHigh: Bool { Scalar.halfN < value }

    public static func + (lhs: Scalar, rhs: Scalar) -> Scalar {
        var (sum, carry) = lhs.value.addingReportingCarry(rhs.value)
        if carry == 1 || sum >= n {
            let (reduced, _) = sum.subtractingReportingBorrow(n)
            sum = reduced
        }
        return Scalar(sum)
    }

    public static func - (lhs: Scalar, rhs: Scalar) -> Scalar {
        let (diff, borrow) = lhs.value.subtractingReportingBorrow(rhs.value)
        if borrow == 1 {
            let (wrapped, _) = diff.addingReportingCarry(n)
            return Scalar(wrapped)
        }
        return Scalar(diff)
    }

    public static prefix func - (operand: Scalar) -> Scalar {
        operand.isZero ? operand : Scalar(n.subtractingReportingBorrow(operand.value).0)
    }

    public static func * (lhs: Scalar, rhs: Scalar) -> Scalar {
        Scalar(reducing512: lhs.value.multipliedFullWidth(by: rhs.value))
    }

    public func power(_ exponent: U256) -> Scalar {
        var result = Scalar.one
        var base = self
        var bit = 0
        let width = exponent.bitWidth
        while bit < width {
            if exponent.bit(bit) { result = result * base }
            base = base * base
            bit += 1
        }
        return result
    }

    public func inverted() -> Scalar {
        isZero ? Scalar.zero : power(Scalar.inverseExponent)
    }

    /// Flip to the low-S form required by Bitcoin's canonical signature rules.
    public func normalizedLow() -> Scalar {
        isHigh ? -self : self
    }
}
