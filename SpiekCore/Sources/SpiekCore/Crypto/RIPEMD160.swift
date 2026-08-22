import Foundation

/// RIPEMD-160, the second half of Bitcoin's `hash160`.
public enum RIPEMD160 {
    private static let rIndex: [Int] = [
        0, 1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11, 12, 13, 14, 15,
        7, 4, 13, 1, 10, 6, 15, 3, 12, 0, 9, 5, 2, 14, 11, 8,
        3, 10, 14, 4, 9, 15, 8, 1, 2, 7, 0, 6, 13, 11, 5, 12,
        1, 9, 11, 10, 0, 8, 12, 4, 13, 3, 7, 15, 14, 5, 6, 2,
        4, 0, 5, 9, 7, 12, 2, 10, 14, 1, 3, 8, 11, 6, 15, 13,
    ]
    private static let rPrimeIndex: [Int] = [
        5, 14, 7, 0, 9, 2, 11, 4, 13, 6, 15, 8, 1, 10, 3, 12,
        6, 11, 3, 7, 0, 13, 5, 10, 14, 15, 8, 12, 4, 9, 1, 2,
        15, 5, 1, 3, 7, 14, 6, 9, 11, 8, 12, 2, 10, 0, 4, 13,
        8, 6, 4, 1, 3, 11, 15, 0, 5, 12, 2, 13, 9, 7, 10, 14,
        12, 15, 10, 4, 1, 5, 8, 7, 6, 2, 13, 14, 0, 3, 9, 11,
    ]
    private static let shift: [UInt32] = [
        11, 14, 15, 12, 5, 8, 7, 9, 11, 13, 14, 15, 6, 7, 9, 8,
        7, 6, 8, 13, 11, 9, 7, 15, 7, 12, 15, 9, 11, 7, 13, 12,
        11, 13, 6, 7, 14, 9, 13, 15, 14, 8, 13, 6, 5, 12, 7, 5,
        11, 12, 14, 15, 14, 15, 9, 8, 9, 14, 5, 6, 8, 6, 5, 12,
        9, 15, 5, 11, 6, 8, 13, 12, 5, 12, 13, 14, 11, 8, 5, 6,
    ]
    private static let shiftPrime: [UInt32] = [
        8, 9, 9, 11, 13, 15, 15, 5, 7, 7, 8, 11, 14, 14, 12, 6,
        9, 13, 15, 7, 12, 8, 9, 11, 7, 7, 12, 7, 6, 15, 13, 11,
        9, 7, 15, 11, 8, 6, 6, 14, 12, 13, 5, 14, 13, 13, 7, 5,
        15, 5, 8, 11, 14, 14, 6, 14, 6, 9, 12, 9, 12, 5, 15, 8,
        8, 5, 12, 9, 12, 5, 14, 6, 8, 13, 6, 5, 15, 13, 11, 11,
    ]
    private static let kConst: [UInt32] = [0x00000000, 0x5a827999, 0x6ed9eba1, 0x8f1bbcdc, 0xa953fd4e]
    private static let kPrimeConst: [UInt32] = [0x50a28be6, 0x5c4dd124, 0x6d703ef3, 0x7a6d76e9, 0x00000000]

    public static func hash<C: Collection>(_ data: C) -> [UInt8] where C.Element == UInt8 {
        var h: [UInt32] = [0x67452301, 0xefcdab89, 0x98badcfe, 0x10325476, 0xc3d2e1f0]

        var msg = Array(data)
        let bitLength = UInt64(msg.count) &* 8
        msg.append(0x80)
        while msg.count % 64 != 56 { msg.append(0) }
        for i in 0..<8 { msg.append(UInt8((bitLength >> (8 * UInt64(i))) & 0xff)) }

        var offset = 0
        while offset < msg.count {
            var x = [UInt32](repeating: 0, count: 16)
            for i in 0..<16 {
                let j = offset + i * 4
                x[i] = UInt32(msg[j]) | UInt32(msg[j + 1]) << 8 | UInt32(msg[j + 2]) << 16 | UInt32(msg[j + 3]) << 24
            }

            var a = h[0], b = h[1], c = h[2], d = h[3], e = h[4]
            var aP = h[0], bP = h[1], cP = h[2], dP = h[3], eP = h[4]

            for j in 0..<80 {
                let round = j / 16

                var t = a &+ f(round, b, c, d) &+ x[rIndex[j]] &+ kConst[round]
                t = rotl(t, shift[j]) &+ e
                a = e; e = d; d = rotl(c, 10); c = b; b = t

                var tP = aP &+ f(4 - round, bP, cP, dP) &+ x[rPrimeIndex[j]] &+ kPrimeConst[round]
                tP = rotl(tP, shiftPrime[j]) &+ eP
                aP = eP; eP = dP; dP = rotl(cP, 10); cP = bP; bP = tP
            }

            let temp = h[1] &+ c &+ dP
            h[1] = h[2] &+ d &+ eP
            h[2] = h[3] &+ e &+ aP
            h[3] = h[4] &+ a &+ bP
            h[4] = h[0] &+ b &+ cP
            h[0] = temp

            offset += 64
        }

        var out = [UInt8]()
        out.reserveCapacity(20)
        for word in h {
            out.append(UInt8(word & 0xff))
            out.append(UInt8((word >> 8) & 0xff))
            out.append(UInt8((word >> 16) & 0xff))
            out.append(UInt8((word >> 24) & 0xff))
        }
        return out
    }

    @inline(__always)
    private static func f(_ round: Int, _ x: UInt32, _ y: UInt32, _ z: UInt32) -> UInt32 {
        switch round {
        case 0: return x ^ y ^ z
        case 1: return (x & y) | (~x & z)
        case 2: return (x | ~y) ^ z
        case 3: return (x & z) | (y & ~z)
        default: return x ^ (y | ~z)
        }
    }

    @inline(__always)
    private static func rotl(_ x: UInt32, _ n: UInt32) -> UInt32 { (x << n) | (x >> (32 - n)) }
}
