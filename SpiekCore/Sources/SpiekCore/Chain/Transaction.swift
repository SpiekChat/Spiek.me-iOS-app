import Foundation

public struct TxInput: Sendable {
    /// Source transaction id in wire order (little endian), always 32 bytes.
    ///
    /// Stored as bytes rather than a hex string so a malformed id can never
    /// slip through and silently shift every following field of a signature
    /// preimage.
    public private(set) var sourceTxidLE: [UInt8]
    public var sourceOutputIndex: UInt32
    public var unlockingScript: [UInt8]
    public var sequence: UInt32

    /// Value of the output being spent — needed for the BIP-143 preimage.
    public var sourceSatoshis: UInt64
    /// Locking script of the output being spent (the "script code").
    public var sourceLockingScript: [UInt8]

    /// Source transaction id in display order (big endian).
    public var sourceTxid: String { sourceTxidLE.reversedBytes.hex }

    public init(sourceTxidLE: [UInt8],
                sourceOutputIndex: UInt32,
                unlockingScript: [UInt8] = [],
                sequence: UInt32 = 0xFFFF_FFFF,
                sourceSatoshis: UInt64 = 0,
                sourceLockingScript: [UInt8] = []) {
        precondition(sourceTxidLE.count == 32, "a transaction id is 32 bytes")
        self.sourceTxidLE = sourceTxidLE
        self.sourceOutputIndex = sourceOutputIndex
        self.unlockingScript = unlockingScript
        self.sequence = sequence
        self.sourceSatoshis = sourceSatoshis
        self.sourceLockingScript = sourceLockingScript
    }

    /// Fails when `sourceTxid` is not 64 hex characters.
    public init?(sourceTxid: String,
                 sourceOutputIndex: UInt32,
                 unlockingScript: [UInt8] = [],
                 sequence: UInt32 = 0xFFFF_FFFF,
                 sourceSatoshis: UInt64 = 0,
                 sourceLockingScript: [UInt8] = []) {
        guard let bytes = Hex.decode(sourceTxid), bytes.count == 32 else { return nil }
        self.init(sourceTxidLE: bytes.reversedBytes,
                  sourceOutputIndex: sourceOutputIndex,
                  unlockingScript: unlockingScript,
                  sequence: sequence,
                  sourceSatoshis: sourceSatoshis,
                  sourceLockingScript: sourceLockingScript)
    }
}

public struct TxOutput: Sendable {
    public var satoshis: UInt64
    public var lockingScript: [UInt8]

    public init(satoshis: UInt64, lockingScript: [UInt8]) {
        self.satoshis = satoshis
        self.lockingScript = lockingScript
    }
}

public struct Transaction: Sendable {
    public var version: UInt32 = 1
    public var inputs: [TxInput] = []
    public var outputs: [TxOutput] = []
    public var lockTime: UInt32 = 0

    public init() {}

    public init(version: UInt32, inputs: [TxInput], outputs: [TxOutput], lockTime: UInt32) {
        self.version = version
        self.inputs = inputs
        self.outputs = outputs
        self.lockTime = lockTime
    }

    // MARK: Serialisation

    public func serialized() -> [UInt8] {
        var writer = ByteWriter(reserving: 256)
        writer.writeUInt32LE(version)

        writer.writeVarInt(UInt64(inputs.count))
        for input in inputs {
            writer.write(input.sourceTxidLE)
            writer.writeUInt32LE(input.sourceOutputIndex)
            writer.writeVarBytes(input.unlockingScript)
            writer.writeUInt32LE(input.sequence)
        }

        writer.writeVarInt(UInt64(outputs.count))
        for output in outputs {
            writer.writeUInt64LE(output.satoshis)
            writer.writeVarBytes(output.lockingScript)
        }

        writer.writeUInt32LE(lockTime)
        return writer.bytes
    }

    public var hex: String { serialized().hex }

    /// Transaction id in display order.
    public var txid: String {
        Hash.sha256d(serialized()).reversedBytes.hex
    }

    public static func parse(hex: String) -> Transaction? {
        guard let bytes = Hex.decode(hex) else { return nil }
        return parse(bytes: bytes)
    }

    public static func parse(bytes: [UInt8]) -> Transaction? {
        var reader = ByteReader(bytes)
        guard let version = reader.readUInt32LE(),
              let inputCount = reader.readVarInt() else { return nil }

        var inputs = [TxInput]()
        for _ in 0..<inputCount {
            guard let txidLE = reader.read(32),
                  let vout = reader.readUInt32LE(),
                  let script = reader.readVarBytes(),
                  let sequence = reader.readUInt32LE() else { return nil }
            inputs.append(TxInput(sourceTxidLE: txidLE,
                                  sourceOutputIndex: vout,
                                  unlockingScript: script,
                                  sequence: sequence))
        }

        guard let outputCount = reader.readVarInt() else { return nil }
        var outputs = [TxOutput]()
        for _ in 0..<outputCount {
            guard let satoshis = reader.readUInt64LE(),
                  let script = reader.readVarBytes() else { return nil }
            outputs.append(TxOutput(satoshis: satoshis, lockingScript: script))
        }

        guard let lockTime = reader.readUInt32LE() else { return nil }
        return Transaction(version: version, inputs: inputs, outputs: outputs, lockTime: lockTime)
    }

    // MARK: Signing

    public struct SigHashType: OptionSet {
        public let rawValue: UInt32
        public init(rawValue: UInt32) { self.rawValue = rawValue }

        public static let all = SigHashType(rawValue: 0x01)
        public static let none = SigHashType(rawValue: 0x02)
        public static let single = SigHashType(rawValue: 0x03)
        public static let forkID = SigHashType(rawValue: 0x40)
        public static let anyoneCanPay = SigHashType(rawValue: 0x80)

        /// What Spiek always uses: SIGHASH_ALL | SIGHASH_FORKID.
        public static let allForkID: SigHashType = [.all, .forkID]
    }

    /// BIP-143 sighash preimage, as required post-fork on BSV.
    public func sigHashPreimage(inputIndex: Int, sigHashType: SigHashType) -> [UInt8] {
        guard inputs.indices.contains(inputIndex) else { return [] }
        let input = inputs[inputIndex]
        var writer = ByteWriter(reserving: 256)

        writer.writeUInt32LE(version)

        let anyoneCanPay = sigHashType.contains(.anyoneCanPay)
        let baseType = sigHashType.rawValue & 0x1f

        // hashPrevouts
        if anyoneCanPay {
            writer.write([UInt8](repeating: 0, count: 32))
        } else {
            var prevouts = ByteWriter()
            for i in inputs {
                prevouts.write(i.sourceTxidLE)
                prevouts.writeUInt32LE(i.sourceOutputIndex)
            }
            writer.write(Hash.sha256d(prevouts.bytes))
        }

        // hashSequence
        if anyoneCanPay || baseType == SigHashType.single.rawValue || baseType == SigHashType.none.rawValue {
            writer.write([UInt8](repeating: 0, count: 32))
        } else {
            var sequences = ByteWriter()
            for i in inputs { sequences.writeUInt32LE(i.sequence) }
            writer.write(Hash.sha256d(sequences.bytes))
        }

        // outpoint
        writer.write(input.sourceTxidLE)
        writer.writeUInt32LE(input.sourceOutputIndex)

        // scriptCode + value + sequence
        writer.writeVarBytes(input.sourceLockingScript)
        writer.writeUInt64LE(input.sourceSatoshis)
        writer.writeUInt32LE(input.sequence)

        // hashOutputs
        if baseType != SigHashType.single.rawValue && baseType != SigHashType.none.rawValue {
            var outs = ByteWriter()
            for o in outputs {
                outs.writeUInt64LE(o.satoshis)
                outs.writeVarBytes(o.lockingScript)
            }
            writer.write(Hash.sha256d(outs.bytes))
        } else if baseType == SigHashType.single.rawValue && inputIndex < outputs.count {
            var outs = ByteWriter()
            outs.writeUInt64LE(outputs[inputIndex].satoshis)
            outs.writeVarBytes(outputs[inputIndex].lockingScript)
            writer.write(Hash.sha256d(outs.bytes))
        } else {
            writer.write([UInt8](repeating: 0, count: 32))
        }

        writer.writeUInt32LE(lockTime)
        writer.writeUInt32LE(sigHashType.rawValue)

        return writer.bytes
    }

    public func sigHash(inputIndex: Int, sigHashType: SigHashType) -> [UInt8] {
        Hash.sha256d(sigHashPreimage(inputIndex: inputIndex, sigHashType: sigHashType))
    }

    /// Signs every input with `key`, assuming they are all P2PKH outputs
    /// belonging to that key.
    public mutating func signAllInputs(with key: PrivateKey,
                                       sigHashType: SigHashType = .allForkID) throws {
        for index in inputs.indices {
            let digest = sigHash(inputIndex: index, sigHashType: sigHashType)
            guard let signature = key.sign(digest: digest) else {
                throw TransactionError.signingFailed
            }
            let sigWithType = signature.derEncoded + [UInt8(sigHashType.rawValue & 0xff)]
            inputs[index].unlockingScript =
                Script.pushData(sigWithType) + Script.pushData(key.publicKey.compressedBytes)
        }
    }
}

public enum TransactionError: Error, LocalizedError {
    case signingFailed
    case insufficientFunds(available: UInt64, required: UInt64)
    case amountTooLarge
    case malformed

    public var errorDescription: String? {
        switch self {
        case .signingFailed:
            return "Signing this transaction failed."
        case let .insufficientFunds(available, required):
            return "Not enough balance — you have \(available) sats and this needs \(required). Top up under Wallet."
        case .amountTooLarge:
            return "That amount is larger than the coin supply — check the number."
        case .malformed:
            return "This transaction could not be read."
        }
    }
}
