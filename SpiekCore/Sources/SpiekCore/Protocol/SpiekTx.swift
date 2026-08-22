import Foundation

/// A transaction recognised as carrying a Spiek record.
public struct ParsedSpiekTx: Sendable {
    public struct OutputInfo: Sendable {
        public let vout: Int
        public let satoshis: UInt64
        /// P2PKH hash160, or nil for non-P2PKH outputs such as the record itself.
        public let hash: [UInt8]?
    }

    public let txid: String
    public let envelope: Envelope
    /// Compressed public key recovered from the first input's unlocking script.
    public let senderPub: [UInt8]
    public let senderHash: [UInt8]
    public let senderAddress: String
    /// Every P2PKH hash paid by this transaction.
    public let payTargets: [[UInt8]]
    public let outputs: [OutputInfo]
    public let transaction: Transaction

    /// Parses a raw transaction, returning nil when it is not a Spiek record.
    ///
    /// A record is only accepted when the transaction also pays the channel's
    /// own address, which is what makes channels discoverable by watching a
    /// single address.
    public static func parse(rawHex: String) -> ParsedSpiekTx? {
        guard let tx = Transaction.parse(hex: rawHex) else { return nil }
        return parse(transaction: tx)
    }

    public static func parse(transaction tx: Transaction) -> ParsedSpiekTx? {
        var envelope: Envelope?
        var outputs = [OutputInfo]()
        var payTargets = [[UInt8]]()

        for (index, output) in tx.outputs.enumerated() {
            let hash = Script.p2pkhHash(from: output.lockingScript)
            if let hash { payTargets.append(hash) }
            outputs.append(OutputInfo(vout: index, satoshis: output.satoshis, hash: hash))
            if envelope == nil, Envelope.hasMarker(output.lockingScript) {
                envelope = Envelope.decode(output.lockingScript)
            }
        }

        guard let envelope else { return nil }
        guard payTargets.contains(where: { $0 == envelope.channel }) else { return nil }
        guard let firstInput = tx.inputs.first, !firstInput.unlockingScript.isEmpty else { return nil }

        // The unlocking script of a P2PKH input ends with the public key.
        guard let chunks = Script.parsePushes(firstInput.unlockingScript, from: 0),
              let last = chunks.last,
              last.count == 33 || last.count == 65,
              let point = ECPoint.decode(last),
              let publicKey = PublicKey(point: point) else { return nil }

        let senderHash = publicKey.hash160
        return ParsedSpiekTx(txid: tx.txid,
                             envelope: envelope,
                             senderPub: publicKey.compressedBytes,
                             senderHash: senderHash,
                             senderAddress: Address.encode(hash160: senderHash),
                             payTargets: payTargets,
                             outputs: outputs,
                             transaction: tx)
    }
}
