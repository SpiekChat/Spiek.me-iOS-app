import Foundation

public enum Opcode {
    public static let OP_0: UInt8 = 0x00
    public static let OP_FALSE: UInt8 = 0x00
    public static let OP_PUSHDATA1: UInt8 = 0x4c
    public static let OP_PUSHDATA2: UInt8 = 0x4d
    public static let OP_PUSHDATA4: UInt8 = 0x4e
    public static let OP_RETURN: UInt8 = 0x6a
    public static let OP_DUP: UInt8 = 0x76
    public static let OP_EQUALVERIFY: UInt8 = 0x88
    public static let OP_HASH160: UInt8 = 0xa9
    public static let OP_CHECKSIG: UInt8 = 0xac
}

public enum Script {
    /// Encodes a single data push exactly as the reference implementation does,
    /// including its quirk of emitting a bare `OP_0` for empty data.
    public static func pushData(_ data: [UInt8]) -> [UInt8] {
        let count = data.count
        if count == 0 { return [0x00] }
        if count <= 75 { return [UInt8(count)] + data }
        if count <= 255 { return [Opcode.OP_PUSHDATA1, UInt8(count)] + data }
        if count <= 65535 {
            return [Opcode.OP_PUSHDATA2, UInt8(count & 0xff), UInt8((count >> 8) & 0xff)] + data
        }
        return [Opcode.OP_PUSHDATA4,
                UInt8(count & 0xff),
                UInt8((count >> 8) & 0xff),
                UInt8((count >> 16) & 0xff),
                UInt8((count >> 24) & 0xff)] + data
    }

    /// Splits a script into its data pushes, rejecting any non-push opcode and
    /// any non-minimal PUSHDATA encoding.
    public static func parsePushes(_ script: [UInt8], from start: Int) -> [[UInt8]]? {
        var chunks = [[UInt8]]()
        var index = start

        while index < script.count {
            let opcode = script[index]
            let length: Int
            let headerSize: Int

            switch opcode {
            case 0:
                length = 0
                headerSize = 1
            case 1...75:
                length = Int(opcode)
                headerSize = 1
            case Opcode.OP_PUSHDATA1:
                guard index + 1 < script.count else { return nil }
                length = Int(script[index + 1])
                headerSize = 2
                if length <= 75 { return nil }
            case Opcode.OP_PUSHDATA2:
                guard index + 2 < script.count else { return nil }
                length = Int(script[index + 1]) | Int(script[index + 2]) << 8
                headerSize = 3
                if length <= 255 { return nil }
            case Opcode.OP_PUSHDATA4:
                guard index + 4 < script.count else { return nil }
                length = Int(script[index + 1]) | Int(script[index + 2]) << 8
                    | Int(script[index + 3]) << 16 | Int(script[index + 4]) << 24
                headerSize = 5
                if length <= 65535 { return nil }
            default:
                return nil
            }

            let dataStart = index + headerSize
            guard dataStart + length <= script.count else { return nil }
            chunks.append(Array(script[dataStart..<(dataStart + length)]))
            index = dataStart + length
        }

        return chunks
    }

    // MARK: P2PKH

    public static func p2pkh(hash160: [UInt8]) -> [UInt8] {
        [Opcode.OP_DUP, Opcode.OP_HASH160, 20] + hash160 + [Opcode.OP_EQUALVERIFY, Opcode.OP_CHECKSIG]
    }

    /// Returns the 20-byte hash if `script` is exactly a standard P2PKH output.
    public static func p2pkhHash(from script: [UInt8]) -> [UInt8]? {
        guard script.count == 25,
              script[0] == Opcode.OP_DUP,
              script[1] == Opcode.OP_HASH160,
              script[2] == 20,
              script[23] == Opcode.OP_EQUALVERIFY,
              script[24] == Opcode.OP_CHECKSIG else { return nil }
        return Array(script[3..<23])
    }
}
