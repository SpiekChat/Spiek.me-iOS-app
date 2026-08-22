import Foundation

public enum ChannelKind: UInt8, Codable, CaseIterable, Sendable {
    case note = 0
    case dm = 1
    case group = 2
}

public enum SpiekOp: UInt8, Codable, CaseIterable, Sendable {
    case msg = 1
    case media = 2
    case react = 3
    case edit = 4
    case del = 5
    case profile = 6
    case open = 7
    case emsg = 8

    public var name: String {
        switch self {
        case .msg: return "msg"
        case .media: return "media"
        case .react: return "react"
        case .edit: return "edit"
        case .del: return "del"
        case .profile: return "profile"
        case .open: return "open"
        case .emsg: return "emsg"
        }
    }

    /// Operations that point at an earlier message and therefore require `ref`.
    public var requiresRef: Bool {
        switch self {
        case .react, .edit, .del: return true
        default: return false
        }
    }
}

public enum EnvelopeError: Error, LocalizedError {
    case badChannelLength
    case badPrevLength
    case badRefLength
    case refRequired(SpiekOp)
    case invalidInnerOperation

    public var errorDescription: String? {
        switch self {
        case .badChannelLength: return "A channel id must be 20 bytes."
        case .badPrevLength: return "The previous reference must be 32 bytes."
        case .badRefLength: return "A reference must be 32 bytes."
        case let .refRequired(op): return "\(op.name) needs a reference to another message."
        case .invalidInnerOperation: return "This operation cannot be nested inside an encrypted message."
        }
    }
}

/// The on-chain record Spiek writes into an `OP_FALSE OP_RETURN` output.
///
/// Layout (each element a minimal data push):
/// `OP_FALSE OP_RETURN "spiek" <version> <kind> <channel:20> <prev:32> <op> <payload> [<ref:32>]`
public struct Envelope: Equatable, Sendable {
    public static let prefix: [UInt8] = Array("spiek".utf8)
    public static let version: UInt8 = 2
    /// A 32-byte zero `prev` marks the first message a sender wrote in a channel.
    public static let noPrev = [UInt8](repeating: 0, count: 32)

    /// The fixed opening bytes every Spiek output starts with.
    public static let marker: [UInt8] = [0x00, Opcode.OP_RETURN, 5] + prefix + [1, version]

    public var kind: ChannelKind
    public var channel: [UInt8]
    public var prev: [UInt8]
    public var op: SpiekOp
    public var payload: [UInt8]
    public var ref: [UInt8]?

    public init(kind: ChannelKind,
                channel: [UInt8],
                prev: [UInt8],
                op: SpiekOp,
                payload: [UInt8] = [],
                ref: [UInt8]? = nil) {
        self.kind = kind
        self.channel = channel
        self.prev = prev
        self.op = op
        self.payload = payload
        self.ref = ref
    }

    public func encoded() throws -> [UInt8] {
        guard channel.count == 20 else { throw EnvelopeError.badChannelLength }
        guard prev.count == 32 else { throw EnvelopeError.badPrevLength }
        if op.requiresRef, ref == nil { throw EnvelopeError.refRequired(op) }
        if let ref, ref.count != 32 { throw EnvelopeError.badRefLength }

        var script: [UInt8] = [0x00, Opcode.OP_RETURN]
        script += Script.pushData(Envelope.prefix)
        script += Script.pushData([Envelope.version])
        script += Script.pushData([kind.rawValue])
        script += Script.pushData(channel)
        script += Script.pushData(prev)
        script += Script.pushData([op.rawValue])
        script += Script.pushData(payload)
        if let ref { script += Script.pushData(ref) }
        return script
    }

    public static func hasMarker(_ script: [UInt8]) -> Bool {
        guard script.count >= marker.count else { return false }
        for i in 0..<marker.count where script[i] != marker[i] { return false }
        return true
    }

    public static func decode(_ script: [UInt8]) -> Envelope? {
        guard script.count >= 2, script[0] == 0x00, script[1] == Opcode.OP_RETURN,
              let chunks = Script.parsePushes(script, from: 2),
              chunks.count == 7 || chunks.count == 8 else { return nil }

        let prefixChunk = chunks[0]
        let versionChunk = chunks[1]
        let kindChunk = chunks[2]
        let channelChunk = chunks[3]
        let prevChunk = chunks[4]
        let opChunk = chunks[5]
        let payloadChunk = chunks[6]
        let refChunk: [UInt8]? = chunks.count == 8 ? chunks[7] : nil

        guard prefixChunk == prefix,
              versionChunk.count == 1, versionChunk[0] == version,
              kindChunk.count == 1, let kind = ChannelKind(rawValue: kindChunk[0]),
              channelChunk.count == 20,
              prevChunk.count == 32,
              opChunk.count == 1, let op = SpiekOp(rawValue: opChunk[0]) else { return nil }

        if let refChunk, refChunk.count != 32 { return nil }
        if op.requiresRef, refChunk == nil { return nil }

        return Envelope(kind: kind,
                        channel: channelChunk,
                        prev: prevChunk,
                        op: op,
                        payload: payloadChunk,
                        ref: refChunk)
    }
}

/// The plaintext record hidden inside an `emsg` payload before encryption:
/// `<version> <op> <payload> [<ref:32>]`.
public struct InnerEnvelope: Equatable, Sendable {
    public var op: SpiekOp
    public var payload: [UInt8]
    public var ref: [UInt8]?

    public init(op: SpiekOp, payload: [UInt8] = [], ref: [UInt8]? = nil) {
        self.op = op
        self.payload = payload
        self.ref = ref
    }

    public func encoded() throws -> [UInt8] {
        guard op != .emsg else { throw EnvelopeError.invalidInnerOperation }
        if op.requiresRef, ref == nil { throw EnvelopeError.refRequired(op) }
        if let ref, ref.count != 32 { throw EnvelopeError.badRefLength }

        var bytes = Script.pushData([Envelope.version])
        bytes += Script.pushData([op.rawValue])
        bytes += Script.pushData(payload)
        if let ref { bytes += Script.pushData(ref) }
        return bytes
    }

    public static func decode(_ bytes: [UInt8]) -> InnerEnvelope? {
        guard let chunks = Script.parsePushes(bytes, from: 0),
              chunks.count == 3 || chunks.count == 4,
              chunks[0].count == 1, chunks[0][0] == Envelope.version,
              chunks[1].count == 1, let op = SpiekOp(rawValue: chunks[1][0]),
              op != .emsg else { return nil }

        let ref: [UInt8]? = chunks.count == 4 ? chunks[3] : nil
        if let ref, ref.count != 32 { return nil }
        if op.requiresRef, ref == nil { return nil }

        return InnerEnvelope(op: op, payload: chunks[2], ref: ref)
    }
}
