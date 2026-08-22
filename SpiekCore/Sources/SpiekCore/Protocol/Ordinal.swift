import Foundation

/// The 1Sat Ordinals inscription envelope.
///
/// The output is an ordinary P2PKH lock followed by a data envelope that node
/// software skips over, so the single satoshi it carries stays spendable while
/// the payload rides along:
///
/// ```
/// <P2PKH> OP_FALSE OP_IF "ord" OP_1 <mime> OP_0 <bytes> OP_ENDIF
/// ```
///
/// Spiek inscribes images to the recipient's own hash, so the picture belongs
/// to them rather than to the sender.
public enum Ordinal {
    public static let tag: [UInt8] = Array("ord".utf8)

    private enum Op {
        static let falseOp: UInt8 = 0x00
        static let ifOp: UInt8 = 0x63
        static let one: UInt8 = 0x51
        static let endIf: UInt8 = 0x68
    }

    public struct Inscription: Sendable, Equatable {
        /// hash160 of the key that owns the inscribed satoshi.
        public let owner: [UInt8]
        public let mime: String
        public let bytes: Data

        public init(owner: [UInt8], mime: String, bytes: Data) {
            self.owner = owner
            self.mime = mime
            self.bytes = bytes
        }
    }

    public static func script(owner hash160: [UInt8], mime: String, bytes: Data) -> [UInt8] {
        var script = Script.p2pkh(hash160: hash160)
        script += [Op.falseOp, Op.ifOp]
        script += Script.pushData(tag)
        script += [Op.one]
        script += Script.pushData(Array(mime.utf8))
        script += [Op.falseOp]
        script += Script.pushData([UInt8](bytes))
        script += [Op.endIf]
        return script
    }

    public static func parse(script: [UInt8]) -> Inscription? {
        guard script.count > 25, let owner = Script.p2pkhHash(from: Array(script[0..<25])) else {
            return nil
        }
        var index = 25
        guard script.count > index + 1,
              script[index] == Op.falseOp, script[index + 1] == Op.ifOp else { return nil }
        index += 2

        guard let (tagBytes, afterTag) = readPush(script, at: index), tagBytes == tag else { return nil }
        index = afterTag

        guard index < script.count, script[index] == Op.one else { return nil }
        index += 1

        guard let (mimeBytes, afterMime) = readPush(script, at: index) else { return nil }
        index = afterMime

        guard index < script.count, script[index] == Op.falseOp else { return nil }
        index += 1

        guard let (payload, afterPayload) = readPush(script, at: index) else { return nil }
        index = afterPayload

        guard index < script.count, script[index] == Op.endIf else { return nil }

        return Inscription(owner: owner,
                           mime: String(decoding: mimeBytes, as: UTF8.self),
                           bytes: Data(payload))
    }

    /// Reads one data push, returning it plus the index just past it. Kept
    /// separate from `Script.parsePushes` because an inscription interleaves
    /// pushes with plain opcodes.
    private static func readPush(_ script: [UInt8], at index: Int) -> ([UInt8], Int)? {
        guard index < script.count else { return nil }
        let opcode = script[index]
        let length: Int
        let headerSize: Int

        switch opcode {
        case 1...75:
            length = Int(opcode); headerSize = 1
        case Opcode.OP_PUSHDATA1:
            guard index + 1 < script.count else { return nil }
            length = Int(script[index + 1]); headerSize = 2
        case Opcode.OP_PUSHDATA2:
            guard index + 2 < script.count else { return nil }
            length = Int(script[index + 1]) | Int(script[index + 2]) << 8
            headerSize = 3
        case Opcode.OP_PUSHDATA4:
            guard index + 4 < script.count else { return nil }
            length = Int(script[index + 1]) | Int(script[index + 2]) << 8
                | Int(script[index + 3]) << 16 | Int(script[index + 4]) << 24
            headerSize = 5
        default:
            return nil
        }

        let start = index + headerSize
        guard length >= 0, start + length <= script.count else { return nil }
        return (Array(script[start..<(start + length)]), start + length)
    }
}
