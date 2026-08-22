import Foundation

/// Payload encodings for each operation, byte-compatible with the web app.
public enum Codecs {

    // MARK: Plain text (msg, react, edit)

    public static func encodeText(_ text: String) -> [UInt8] { Array(text.utf8) }

    public static func decodeText(_ bytes: [UInt8]) -> String {
        String(decoding: bytes, as: UTF8.self)
    }

    // MARK: Media

    public struct MediaRef: Equatable, Sendable {
        /// Transaction id of the media transaction, in display order.
        public var txid: String
        public var vout: UInt32
        public var caption: String

        public init(txid: String, vout: UInt32, caption: String) {
            self.txid = txid
            self.vout = vout
            self.caption = caption
        }

        public var outpoint: String { "\(txid):\(vout)" }
    }

    /// `<txid little-endian:32><vout:4 LE><caption utf8>`
    public static func encodeMedia(_ ref: MediaRef) -> [UInt8]? {
        guard let txidBytes = Hex.decode(ref.txid), txidBytes.count == 32 else { return nil }
        var writer = ByteWriter()
        writer.write(txidBytes.reversedBytes)
        writer.writeUInt32LE(ref.vout)
        writer.write(Array(ref.caption.utf8))
        return writer.bytes
    }

    public static func decodeMedia(_ bytes: [UInt8]) -> MediaRef? {
        guard bytes.count >= 36 else { return nil }
        let txid = Array(bytes[0..<32]).reversedBytes.hex
        let vout = UInt32(bytes[32]) | UInt32(bytes[33]) << 8
            | UInt32(bytes[34]) << 16 | UInt32(bytes[35]) << 24
        let caption = String(decoding: bytes[36...], as: UTF8.self)
        return MediaRef(txid: txid, vout: vout, caption: caption)
    }

    // MARK: Profile

    public struct Profile: Codable, Equatable, Sendable {
        public var name: String?
        public var bio: String?

        public init(name: String? = nil, bio: String? = nil) {
            self.name = name
            self.bio = bio
        }
    }

    public static func encodeProfile(_ profile: Profile) -> [UInt8] {
        let encoder = JSONEncoder()
        encoder.outputFormatting = []
        guard let data = try? encoder.encode(profile) else { return [] }
        return data.bytes
    }

    public static func decodeProfile(_ bytes: [UInt8]) -> Profile? {
        try? JSONDecoder().decode(Profile.self, from: Data(bytes))
    }

    // MARK: Open

    /// The `open` payload is the sender's compressed public key.
    public static func encodeOpen(publicKey: [UInt8]) -> [UInt8] { publicKey }

    public static func decodeOpen(_ bytes: [UInt8]) -> [UInt8]? {
        bytes.count == 33 ? bytes : nil
    }
}

public enum ChannelID {
    /// Channel ids are carried as 20 raw bytes and displayed as hex.
    public static func string(from bytes: [UInt8]) -> String { bytes.hex }

    public static func bytes(from string: String) -> [UInt8]? {
        guard let bytes = Hex.decode(string), bytes.count == 20 else { return nil }
        return bytes
    }

    public static func random() -> [UInt8] { SecureRandom.bytes(20) }

    /// The address a group or unclaimed DM channel is watched on.
    public static func address(for channelId: String) -> String? {
        guard let bytes = bytes(from: channelId) else { return nil }
        return Address.encode(hash160: bytes)
    }
}

/// The shareable invite codes the "New chat" screen produces and consumes.
public enum InviteCode {
    public static func encode(channelId: String, kind: ChannelKind) -> String {
        switch kind {
        case .group: return "spiek:group:\(channelId)"
        default: return "spiek:chat:\(channelId)"
        }
    }

    public static func decode(_ code: String) -> (channelId: String, kind: ChannelKind)? {
        let trimmed = code.trimmingCharacters(in: .whitespacesAndNewlines)
        let parts = trimmed.split(separator: ":", omittingEmptySubsequences: false).map(String.init)
        guard parts.count == 3, parts[0].lowercased() == "spiek" else { return nil }
        guard ChannelID.bytes(from: parts[2]) != nil else { return nil }
        switch parts[1].lowercased() {
        case "group": return (parts[2], .group)
        case "chat", "dm": return (parts[2], .dm)
        default: return nil
        }
    }
}
