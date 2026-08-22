import Foundation

/// AES block cipher, encryption direction only — GCM never needs decryption
/// because it is built on counter mode.
///
/// Accepted trade-off: the S-box below is a table lookup, which is not
/// constant-time in the cache-timing sense. A hardened build would bitslice
/// or use the hardware AES unit; this port stays byte-compatible with the
/// reference implementation and keeps zero dependencies instead. Tag
/// comparison, where timing is actually observable remotely, *is* constant
/// time — see `constantTimeEquals`.
struct AES {
    private static let sbox: [UInt8] = [
        0x63,0x7c,0x77,0x7b,0xf2,0x6b,0x6f,0xc5,0x30,0x01,0x67,0x2b,0xfe,0xd7,0xab,0x76,
        0xca,0x82,0xc9,0x7d,0xfa,0x59,0x47,0xf0,0xad,0xd4,0xa2,0xaf,0x9c,0xa4,0x72,0xc0,
        0xb7,0xfd,0x93,0x26,0x36,0x3f,0xf7,0xcc,0x34,0xa5,0xe5,0xf1,0x71,0xd8,0x31,0x15,
        0x04,0xc7,0x23,0xc3,0x18,0x96,0x05,0x9a,0x07,0x12,0x80,0xe2,0xeb,0x27,0xb2,0x75,
        0x09,0x83,0x2c,0x1a,0x1b,0x6e,0x5a,0xa0,0x52,0x3b,0xd6,0xb3,0x29,0xe3,0x2f,0x84,
        0x53,0xd1,0x00,0xed,0x20,0xfc,0xb1,0x5b,0x6a,0xcb,0xbe,0x39,0x4a,0x4c,0x58,0xcf,
        0xd0,0xef,0xaa,0xfb,0x43,0x4d,0x33,0x85,0x45,0xf9,0x02,0x7f,0x50,0x3c,0x9f,0xa8,
        0x51,0xa3,0x40,0x8f,0x92,0x9d,0x38,0xf5,0xbc,0xb6,0xda,0x21,0x10,0xff,0xf3,0xd2,
        0xcd,0x0c,0x13,0xec,0x5f,0x97,0x44,0x17,0xc4,0xa7,0x7e,0x3d,0x64,0x5d,0x19,0x73,
        0x60,0x81,0x4f,0xdc,0x22,0x2a,0x90,0x88,0x46,0xee,0xb8,0x14,0xde,0x5e,0x0b,0xdb,
        0xe0,0x32,0x3a,0x0a,0x49,0x06,0x24,0x5c,0xc2,0xd3,0xac,0x62,0x91,0x95,0xe4,0x79,
        0xe7,0xc8,0x37,0x6d,0x8d,0xd5,0x4e,0xa9,0x6c,0x56,0xf4,0xea,0x65,0x7a,0xae,0x08,
        0xba,0x78,0x25,0x2e,0x1c,0xa6,0xb4,0xc6,0xe8,0xdd,0x74,0x1f,0x4b,0xbd,0x8b,0x8a,
        0x70,0x3e,0xb5,0x66,0x48,0x03,0xf6,0x0e,0x61,0x35,0x57,0xb9,0x86,0xc1,0x1d,0x9e,
        0xe1,0xf8,0x98,0x11,0x69,0xd9,0x8e,0x94,0x9b,0x1e,0x87,0xe9,0xce,0x55,0x28,0xdf,
        0x8c,0xa1,0x89,0x0d,0xbf,0xe6,0x42,0x68,0x41,0x99,0x2d,0x0f,0xb0,0x54,0xbb,0x16,
    ]
    private static let rcon: [UInt8] = [0x01,0x02,0x04,0x08,0x10,0x20,0x40,0x80,0x1b,0x36,0x6c,0xd8,0xab,0x4d]

    private let roundKeys: [[UInt8]]
    private let rounds: Int

    /// - Parameter key: 16, 24 or 32 bytes.
    init?(key: [UInt8]) {
        let nk: Int
        switch key.count {
        case 16: nk = 4; rounds = 10
        case 24: nk = 6; rounds = 12
        case 32: nk = 8; rounds = 14
        default: return nil
        }

        let wordCount = 4 * (rounds + 1)
        var w = [[UInt8]](repeating: [0, 0, 0, 0], count: wordCount)
        for i in 0..<nk { w[i] = Array(key[(4 * i)..<(4 * i + 4)]) }

        for i in nk..<wordCount {
            var temp = w[i - 1]
            if i % nk == 0 {
                temp = [temp[1], temp[2], temp[3], temp[0]].map { AES.sbox[Int($0)] }
                temp[0] ^= AES.rcon[i / nk - 1]
            } else if nk > 6 && i % nk == 4 {
                temp = temp.map { AES.sbox[Int($0)] }
            }
            w[i] = (0..<4).map { w[i - nk][$0] ^ temp[$0] }
        }

        var keys = [[UInt8]]()
        keys.reserveCapacity(rounds + 1)
        for r in 0...rounds {
            var rk = [UInt8]()
            rk.reserveCapacity(16)
            for c in 0..<4 { rk.append(contentsOf: w[4 * r + c]) }
            keys.append(rk)
        }
        roundKeys = keys
    }

    /// Encrypts a single 16-byte block in place-ish (returns a new block).
    func encryptBlock(_ input: [UInt8]) -> [UInt8] {
        var state = input
        addRoundKey(&state, roundKeys[0])
        for round in 1..<rounds {
            subBytes(&state)
            shiftRows(&state)
            mixColumns(&state)
            addRoundKey(&state, roundKeys[round])
        }
        subBytes(&state)
        shiftRows(&state)
        addRoundKey(&state, roundKeys[rounds])
        return state
    }

    private func addRoundKey(_ state: inout [UInt8], _ key: [UInt8]) {
        for i in 0..<16 { state[i] ^= key[i] }
    }

    private func subBytes(_ state: inout [UInt8]) {
        for i in 0..<16 { state[i] = AES.sbox[Int(state[i])] }
    }

    private func shiftRows(_ state: inout [UInt8]) {
        // Column-major state: index = 4*column + row.
        var out = state
        for row in 1..<4 {
            for col in 0..<4 {
                out[4 * col + row] = state[4 * ((col + row) % 4) + row]
            }
        }
        state = out
    }

    private func mixColumns(_ state: inout [UInt8]) {
        for c in 0..<4 {
            let base = 4 * c
            let a0 = state[base], a1 = state[base + 1], a2 = state[base + 2], a3 = state[base + 3]
            state[base]     = xtime(a0) ^ (xtime(a1) ^ a1) ^ a2 ^ a3
            state[base + 1] = a0 ^ xtime(a1) ^ (xtime(a2) ^ a2) ^ a3
            state[base + 2] = a0 ^ a1 ^ xtime(a2) ^ (xtime(a3) ^ a3)
            state[base + 3] = (xtime(a0) ^ a0) ^ a1 ^ a2 ^ xtime(a3)
        }
    }

    @inline(__always)
    private func xtime(_ x: UInt8) -> UInt8 {
        (x << 1) ^ ((x & 0x80) != 0 ? 0x1b : 0x00)
    }
}

/// AES-GCM with an arbitrary-length IV — required because Spiek's reference
/// implementation uses a 32-byte IV, which CryptoKit's `AES.GCM.Nonce` rejects.
public enum AESGCM {
    public enum Failure: Error, LocalizedError {
        case badKey
        case ciphertextTooShort
        case authenticationFailed

        public var errorDescription: String? {
            switch self {
            case .badKey: return "Invalid encryption key."
            case .ciphertextTooShort: return "This message is truncated."
            case .authenticationFailed: return "This message could not be decrypted."
            }
        }
    }

    public static let ivLength = 32
    public static let tagLength = 16

    /// Encrypts and returns `iv || ciphertext || tag`, the layout the Spiek
    /// protocol puts on chain.
    public static func seal(plaintext: [UInt8], key: [UInt8], iv: [UInt8]? = nil) throws -> [UInt8] {
        guard let aes = AES(key: key) else { throw Failure.badKey }
        let nonce = iv ?? SecureRandom.bytes(ivLength)
        let h = aes.encryptBlock([UInt8](repeating: 0, count: 16))
        let ghash = GHASH(h: h)

        let j0 = initialCounter(nonce: nonce, ghash: ghash)
        let ciphertext = gctr(aes: aes, counter: increment(j0), input: plaintext)

        var lengths = [UInt8](repeating: 0, count: 16)
        writeUInt64BE(0, into: &lengths, at: 0)
        writeUInt64BE(UInt64(ciphertext.count) * 8, into: &lengths, at: 8)

        var s = ghash.digest(padded(ciphertext) + lengths)
        s = gctr(aes: aes, counter: j0, input: s)

        return nonce + ciphertext + Array(s.prefix(tagLength))
    }

    /// Opens `iv || ciphertext || tag`.
    ///
    /// `ivLength` must match what the message was sealed with; Spiek always
    /// uses 32 bytes, but the parameter keeps `seal`/`open` symmetric.
    public static func open(sealed: [UInt8], key: [UInt8], ivLength: Int = AESGCM.ivLength) throws -> [UInt8] {
        guard ivLength > 0, sealed.count >= ivLength + tagLength else {
            throw Failure.ciphertextTooShort
        }
        guard let aes = AES(key: key) else { throw Failure.badKey }

        let nonce = Array(sealed[0..<ivLength])
        let ciphertext = Array(sealed[ivLength..<(sealed.count - tagLength)])
        let tag = Array(sealed.suffix(tagLength))

        let h = aes.encryptBlock([UInt8](repeating: 0, count: 16))
        let ghash = GHASH(h: h)
        let j0 = initialCounter(nonce: nonce, ghash: ghash)

        var lengths = [UInt8](repeating: 0, count: 16)
        writeUInt64BE(0, into: &lengths, at: 0)
        writeUInt64BE(UInt64(ciphertext.count) * 8, into: &lengths, at: 8)

        var s = ghash.digest(padded(ciphertext) + lengths)
        s = gctr(aes: aes, counter: j0, input: s)
        guard constantTimeEquals(Array(s.prefix(tagLength)), tag) else {
            throw Failure.authenticationFailed
        }

        return gctr(aes: aes, counter: increment(j0), input: ciphertext)
    }

    // MARK: Internals

    private static func initialCounter(nonce: [UInt8], ghash: GHASH) -> [UInt8] {
        if nonce.count == 12 {
            return nonce + [0, 0, 0, 1]
        }
        var lengths = [UInt8](repeating: 0, count: 16)
        writeUInt64BE(0, into: &lengths, at: 0)
        writeUInt64BE(UInt64(nonce.count) * 8, into: &lengths, at: 8)
        return ghash.digest(padded(nonce) + lengths)
    }

    private static func padded(_ bytes: [UInt8]) -> [UInt8] {
        let remainder = bytes.count % 16
        guard remainder != 0 else { return bytes }
        return bytes + [UInt8](repeating: 0, count: 16 - remainder)
    }

    private static func increment(_ block: [UInt8]) -> [UInt8] {
        var out = block
        var i = 15
        while i >= 12 {
            out[i] = out[i] &+ 1
            if out[i] != 0 { break }
            i -= 1
        }
        return out
    }

    private static func gctr(aes: AES, counter: [UInt8], input: [UInt8]) -> [UInt8] {
        guard !input.isEmpty else { return [] }
        var out = [UInt8]()
        out.reserveCapacity(input.count)
        var block = counter
        var offset = 0
        while offset < input.count {
            let keystream = aes.encryptBlock(block)
            let chunk = min(16, input.count - offset)
            for i in 0..<chunk { out.append(input[offset + i] ^ keystream[i]) }
            offset += 16
            block = increment(block)
        }
        return out
    }

    private static func writeUInt64BE(_ value: UInt64, into buffer: inout [UInt8], at index: Int) {
        for i in 0..<8 { buffer[index + i] = UInt8((value >> (8 * UInt64(7 - i))) & 0xff) }
    }
}

/// GHASH over GF(2^128) with the GCM reduction polynomial R = 0xE1||0…0.
///
/// GCM numbers bits "backwards": bit 0 is the most significant bit of the
/// first byte, so multiplication walks X from its top bit down while shifting
/// V toward the least significant end.
struct GHASH {
    private let hHi: UInt64
    private let hLo: UInt64
    private static let reductionPolynomial: UInt64 = 0xE100_0000_0000_0000

    init(h: [UInt8]) {
        var hi: UInt64 = 0
        var lo: UInt64 = 0
        for i in 0..<8 { hi = hi << 8 | UInt64(h[i]) }
        for i in 8..<16 { lo = lo << 8 | UInt64(h[i]) }
        hHi = hi
        hLo = lo
    }

    /// `data` must already be a whole number of 16-byte blocks.
    func digest(_ data: [UInt8]) -> [UInt8] {
        var yHi: UInt64 = 0
        var yLo: UInt64 = 0

        var offset = 0
        while offset + 16 <= data.count {
            var bHi: UInt64 = 0
            var bLo: UInt64 = 0
            for i in 0..<8 { bHi = bHi << 8 | UInt64(data[offset + i]) }
            for i in 8..<16 { bLo = bLo << 8 | UInt64(data[offset + i]) }
            (yHi, yLo) = multiplyByH(hi: yHi ^ bHi, lo: yLo ^ bLo)
            offset += 16
        }

        var out = [UInt8](repeating: 0, count: 16)
        for i in 0..<8 { out[i] = UInt8((yHi >> (8 * UInt64(7 - i))) & 0xff) }
        for i in 0..<8 { out[8 + i] = UInt8((yLo >> (8 * UInt64(7 - i))) & 0xff) }
        return out
    }

    private func multiplyByH(hi xHi: UInt64, lo xLo: UInt64) -> (UInt64, UInt64) {
        var zHi: UInt64 = 0
        var zLo: UInt64 = 0
        var vHi = hHi
        var vLo = hLo

        for bit in 0..<128 {
            let isSet: Bool
            if bit < 64 {
                isSet = (xHi >> UInt64(63 - bit)) & 1 == 1
            } else {
                isSet = (xLo >> UInt64(127 - bit)) & 1 == 1
            }
            if isSet {
                zHi ^= vHi
                zLo ^= vLo
            }

            let lsb = vLo & 1
            vLo = vLo >> 1 | (vHi & 1) << 63
            vHi >>= 1
            if lsb == 1 { vHi ^= GHASH.reductionPolynomial }
        }
        return (zHi, zLo)
    }
}
