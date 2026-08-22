import Foundation

/// Points on secp256k1 (y² = x³ + 7) in Jacobian coordinates, where the affine
/// point is (X/Z², Y/Z³) and Z == 0 marks the point at infinity.
public struct ECPoint: Equatable, Sendable {
    public var x: Fp
    public var y: Fp
    public var z: Fp

    /// Compares the points themselves, not their Jacobian representation —
    /// the same point has infinitely many (X, Y, Z) triples.
    public static func == (lhs: ECPoint, rhs: ECPoint) -> Bool {
        if lhs.isInfinity || rhs.isInfinity { return lhs.isInfinity && rhs.isInfinity }
        let z1Squared = lhs.z.squared()
        let z2Squared = rhs.z.squared()
        guard lhs.x * z2Squared == rhs.x * z1Squared else { return false }
        return lhs.y * z2Squared * rhs.z == rhs.y * z1Squared * lhs.z
    }

    public static let infinity = ECPoint(x: Fp.one, y: Fp.one, z: Fp.zero)

    /// The standard generator G.
    public static let generator = ECPoint(
        x: Fp(U256(0x59F2_815B_16F8_1798, 0x029B_FCDB_2DCE_28D9,
                   0x55A0_6295_CE87_0B07, 0x79BE_667E_F9DC_BBAC)),
        y: Fp(U256(0x9C47_D08F_FB10_D4B8, 0xFD17_B448_A685_5419,
                   0x5DA4_FBFC_0E11_08A8, 0x483A_DA77_26A3_C465)),
        z: Fp.one
    )

    /// The curve constant b in y² = x³ + b.
    public static let b = Fp(U256(7))

    public init(x: Fp, y: Fp, z: Fp) {
        self.x = x; self.y = y; self.z = z
    }

    public init(affineX: Fp, affineY: Fp) {
        self.init(x: affineX, y: affineY, z: Fp.one)
    }

    public var isInfinity: Bool { z.isZero }

    /// Affine coordinates, or nil at infinity.
    public var affine: (x: Fp, y: Fp)? {
        guard !isInfinity else { return nil }
        let zInv = z.inverted()
        let zInv2 = zInv.squared()
        let zInv3 = zInv2 * zInv
        return (x * zInv2, y * zInv3)
    }

    public func isOnCurve() -> Bool {
        guard let (ax, ay) = affine else { return true }
        return ay.squared() == ax.squared() * ax + ECPoint.b
    }

    // MARK: Group law

    /// dbl-2009-l from the EFD, specialised for a == 0.
    public func doubled() -> ECPoint {
        if isInfinity || y.isZero { return .infinity }

        let a = x.squared()
        let bb = y.squared()
        let c = bb.squared()
        var d = (x + bb).squared() - a - c
        d = d.doubled()
        let e = a.tripled()
        let f = e.squared()

        let x3 = f - d.doubled()
        let y3 = e * (d - x3) - c.doubled().doubled().doubled()
        let z3 = (y * z).doubled()

        return ECPoint(x: x3, y: y3, z: z3)
    }

    /// add-2007-bl from the EFD.
    public static func + (lhs: ECPoint, rhs: ECPoint) -> ECPoint {
        if lhs.isInfinity { return rhs }
        if rhs.isInfinity { return lhs }

        let z1z1 = lhs.z.squared()
        let z2z2 = rhs.z.squared()
        let u1 = lhs.x * z2z2
        let u2 = rhs.x * z1z1
        let s1 = lhs.y * rhs.z * z2z2
        let s2 = rhs.y * lhs.z * z1z1
        let h = u2 - u1
        let rr = (s2 - s1).doubled()

        if h.isZero {
            // Same x: either a doubling or two points that cancel.
            return rr.isZero ? lhs.doubled() : .infinity
        }

        let i = h.doubled().squared()
        let j = h * i
        let v = u1 * i

        let x3 = rr.squared() - j - v.doubled()
        let y3 = rr * (v - x3) - (s1 * j).doubled()
        let z3 = ((lhs.z + rhs.z).squared() - z1z1 - z2z2) * h

        return ECPoint(x: x3, y: y3, z: z3)
    }

    public static prefix func - (operand: ECPoint) -> ECPoint {
        ECPoint(x: operand.x, y: -operand.y, z: operand.z)
    }

    /// Left-to-right double-and-add over a 4-bit window.
    ///
    /// Accepted trade-off: the branch on each window nibble makes this not
    /// constant-time, so a local attacker able to measure this process could
    /// in principle learn scalar bits. A hardened build would use a
    /// fixed-window ladder with constant-time table reads; this port keeps
    /// byte-compatibility with the reference implementation and zero
    /// dependencies. Signing nonces are deterministic (RFC 6979), so no
    /// randomness is at stake — only local side channels.
    public func multiplied(by scalar: Scalar) -> ECPoint {
        if scalar.isZero || isInfinity { return .infinity }

        // Precompute [0]P … [15]P.
        var table = [ECPoint](repeating: .infinity, count: 16)
        table[1] = self
        for i in 2..<16 {
            table[i] = i % 2 == 0 ? table[i / 2].doubled() : table[i - 1] + self
        }

        var result = ECPoint.infinity
        var started = false
        var nibbleIndex = 63
        while nibbleIndex >= 0 {
            if started {
                result = result.doubled().doubled().doubled().doubled()
            }
            let limb = scalar.value[limb: nibbleIndex >> 4]
            let shift = UInt64((nibbleIndex & 15) * 4)
            let nibble = Int((limb >> shift) & 0xF)
            if nibble != 0 {
                result = started ? result + table[nibble] : table[nibble]
                started = true
            }
            nibbleIndex -= 1
        }
        return result
    }

    public static func * (scalar: Scalar, point: ECPoint) -> ECPoint {
        point.multiplied(by: scalar)
    }

    // MARK: Encoding

    /// SEC1 encoding: 33 bytes compressed, 65 uncompressed.
    public func encoded(compressed: Bool) -> [UInt8]? {
        guard let (ax, ay) = affine else { return nil }
        let xBytes = ax.bigEndianBytes
        if compressed {
            return [ay.isOdd ? 0x03 : 0x02] + xBytes
        }
        return [0x04] + xBytes + ay.bigEndianBytes
    }

    public static func decode(_ bytes: [UInt8]) -> ECPoint? {
        switch bytes.count {
        case 33:
            guard bytes[0] == 0x02 || bytes[0] == 0x03,
                  let x = Fp(bigEndianBytes: Array(bytes[1...])) else { return nil }
            let ySquared = x.squared() * x + b
            guard var y = ySquared.squareRoot() else { return nil }
            let wantOdd = bytes[0] == 0x03
            if y.isOdd != wantOdd { y = -y }
            let point = ECPoint(affineX: x, affineY: y)
            return point.isOnCurve() ? point : nil

        case 65:
            guard bytes[0] == 0x04,
                  let x = Fp(bigEndianBytes: Array(bytes[1..<33])),
                  let y = Fp(bigEndianBytes: Array(bytes[33...])) else { return nil }
            let point = ECPoint(affineX: x, affineY: y)
            return point.isOnCurve() ? point : nil

        default:
            return nil
        }
    }
}

// MARK: - ECDSA

public struct ECDSASignature: Equatable, Sendable {
    public let r: Scalar
    public let s: Scalar

    public init(r: Scalar, s: Scalar) {
        self.r = r
        self.s = s
    }

    /// Strict DER: 0x30 len 0x02 rlen r 0x02 slen s, with minimal
    /// non-negative integers.
    public var derEncoded: [UInt8] {
        func derInteger(_ scalar: Scalar) -> [UInt8] {
            var bytes = scalar.bigEndianBytes
            while bytes.count > 1 && bytes[0] == 0 { bytes.removeFirst() }
            if bytes[0] & 0x80 != 0 { bytes.insert(0, at: 0) }
            return [0x02, UInt8(bytes.count)] + bytes
        }
        let body = derInteger(r) + derInteger(s)
        return [0x30, UInt8(body.count)] + body
    }

    public static func fromDER(_ der: [UInt8]) -> ECDSASignature? {
        var reader = ByteReader(der)
        guard reader.readUInt8() == 0x30,
              let totalLength = reader.readUInt8(),
              Int(totalLength) == reader.remaining,
              reader.readUInt8() == 0x02,
              let rLength = reader.readUInt8(),
              let rBytes = reader.read(Int(rLength)),
              reader.readUInt8() == 0x02,
              let sLength = reader.readUInt8(),
              let sBytes = reader.read(Int(sLength)) else { return nil }

        let rTrimmed = Array(rBytes.drop(while: { $0 == 0 }))
        let sTrimmed = Array(sBytes.drop(while: { $0 == 0 }))
        guard let r = U256(bigEndianBytes: rTrimmed),
              let s = U256(bigEndianBytes: sTrimmed),
              !r.isZero, r < Scalar.n,
              !s.isZero, s < Scalar.n else { return nil }
        return ECDSASignature(r: Scalar(r), s: Scalar(s))
    }
}

public enum ECDSA {
    /// Signs a 32-byte digest with an RFC 6979 deterministic nonce and returns
    /// a low-S signature, matching the reference JavaScript implementation.
    public static func sign(digest: [UInt8], privateKey: Scalar) -> ECDSASignature? {
        guard digest.count == 32, !privateKey.isZero else { return nil }

        // bits2octets: the digest is already 256 bits, so only a single
        // conditional subtraction of n is needed.
        guard var messageValue = U256(bigEndianBytes: digest) else { return nil }
        if messageValue >= Scalar.n {
            messageValue = messageValue.subtractingReportingBorrow(Scalar.n).0
        }
        let message = Scalar(messageValue)

        var drbg = HMACDRBG(entropy: privateKey.bigEndianBytes, nonce: message.bigEndianBytes)

        for _ in 0..<1000 {
            let candidate = drbg.generate(32)
            guard let kValue = U256(bigEndianBytes: candidate) else { continue }
            guard !kValue.isZero, kValue < Scalar.n else { continue }
            let k = Scalar(kValue)

            let point = ECPoint.generator.multiplied(by: k)
            guard let (px, _) = point.affine else { continue }

            let r = Scalar(reducing: px.value)
            if r.isZero { continue }

            let s = k.inverted() * (message + r * privateKey)
            if s.isZero { continue }

            return ECDSASignature(r: r, s: s.normalizedLow())
        }
        return nil
    }

    public static func verify(digest: [UInt8], signature: ECDSASignature, publicKey: ECPoint) -> Bool {
        guard digest.count == 32,
              !signature.r.isZero, !signature.s.isZero,
              let messageValue = U256(bigEndianBytes: digest) else { return false }

        let message = Scalar(reducing: messageValue)
        let sInv = signature.s.inverted()
        let u1 = message * sInv
        let u2 = signature.r * sInv

        let point = ECPoint.generator.multiplied(by: u1) + publicKey.multiplied(by: u2)
        guard let (px, _) = point.affine else { return false }
        return Scalar(reducing: px.value) == signature.r
    }

    /// ECDH as the reference implementation does it: the raw shared point,
    /// SEC1-compressed. Callers hash it themselves.
    public static func sharedSecret(privateKey: Scalar, publicKey: ECPoint) -> [UInt8]? {
        publicKey.multiplied(by: privateKey).encoded(compressed: true)
    }
}

/// HMAC-SHA256 deterministic random bit generator, per RFC 6979 §3.2.
struct HMACDRBG {
    private var k: [UInt8]
    private var v: [UInt8]

    init(entropy: [UInt8], nonce: [UInt8]) {
        k = [UInt8](repeating: 0x00, count: 32)
        v = [UInt8](repeating: 0x01, count: 32)
        update(entropy + nonce)
    }

    private mutating func update(_ seed: [UInt8]?) {
        k = Hash.hmacSHA256(key: k, message: v + [0x00] + (seed ?? []))
        v = Hash.hmacSHA256(key: k, message: v)
        if let seed {
            k = Hash.hmacSHA256(key: k, message: v + [0x01] + seed)
            v = Hash.hmacSHA256(key: k, message: v)
        }
    }

    mutating func generate(_ count: Int) -> [UInt8] {
        var out = [UInt8]()
        while out.count < count {
            v = Hash.hmacSHA256(key: k, message: v)
            out.append(contentsOf: v)
        }
        let result = Array(out.prefix(count))
        update(nil)
        return result
    }
}
