import Foundation

public struct UTXO: Codable, Equatable, Hashable, Sendable {
    public var txid: String
    public var vout: UInt32
    public var satoshis: UInt64
    public var confirmed: Bool

    public init(txid: String, vout: UInt32, satoshis: UInt64, confirmed: Bool = true) {
        self.txid = txid
        self.vout = vout
        self.satoshis = satoshis
        self.confirmed = confirmed
    }

    public var outpoint: String { "\(txid):\(vout)" }
}

public struct PayTarget: Sendable {
    public var hash: [UInt8]
    public var satoshis: UInt64

    public init(hash: [UInt8], satoshis: UInt64) {
        self.hash = hash
        self.satoshis = satoshis
    }
}

public struct BuiltTransaction: Sendable {
    public let rawHex: String
    public let txid: String
    public let fee: UInt64
}

/// A single-key wallet that owns the UTXO set behind one address.
///
/// Spiek chains messages through its own change outputs, so the wallet must
/// track unconfirmed outputs it just created as spendable.
/// Marked `@unchecked Sendable` because every mutation happens inside the
/// `Engine` actor that owns it; nothing else holds a reference.
public final class Wallet: @unchecked Sendable {
    public let key: PrivateKey
    public let hash: [UInt8]
    public let address: String

    public var dust: UInt64
    public var feePerByte: Double
    public var minFee: UInt64

    /// Keyed by outpoint ("txid:vout").
    public private(set) var utxos: [String: UTXO] = [:]
    /// Outpoints already consumed by transactions we built.
    public private(set) var spent: Set<String> = []
    /// Insertion order for `spent`, so trimming really drops the oldest.
    private var spentOrder: [String] = []
    /// What each spent outpoint was worth, so a released transaction can put
    /// its inputs back rather than leaving the balance short.
    private var consumed: [String: UTXO] = [:]

    private static let spentHighWaterMark = 5000
    private static let spentTrimTo = 2500

    public init(key: PrivateKey, dust: UInt64 = 1, feePerByte: Double = 0.1, minFee: UInt64 = 10) {
        self.key = key
        self.hash = key.publicKey.hash160
        self.address = key.publicKey.address
        self.dust = dust
        self.feePerByte = feePerByte
        self.minFee = minFee
    }

    public convenience init(wif: String, dust: UInt64 = 1, feePerByte: Double = 0.1, minFee: UInt64 = 10) throws {
        self.init(key: try PrivateKey(wif: wif), dust: dust, feePerByte: feePerByte, minFee: minFee)
    }

    public var publicKeyBytes: [UInt8] { key.publicKey.compressedBytes }

    public var balance: UInt64 {
        utxos.values.reduce(0) { $0 + $1.satoshis }
    }

    public var confirmedBalance: UInt64 {
        utxos.values.filter(\.confirmed).reduce(0) { $0 + $1.satoshis }
    }

    // MARK: UTXO bookkeeping

    public func add(_ utxo: UTXO) {
        utxos[utxo.outpoint] = utxo
    }

    /// Applies a transaction to the UTXO set: its inputs are spent, and any
    /// output paying this wallet becomes spendable.
    @discardableResult
    public func absorb(rawHex: String, confirmed: Bool = false) -> String? {
        guard let tx = Transaction.parse(hex: rawHex) else { return nil }
        return absorb(transaction: tx, confirmed: confirmed)
    }

    @discardableResult
    public func absorb(transaction tx: Transaction, confirmed: Bool = false) -> String? {
        let txid = tx.txid

        for input in tx.inputs {
            let outpoint = "\(input.sourceTxid):\(input.sourceOutputIndex)"
            if let removed = utxos.removeValue(forKey: outpoint) {
                consumed[outpoint] = removed
            }
            if spent.insert(outpoint).inserted { spentOrder.append(outpoint) }
        }
        if spentOrder.count > Wallet.spentHighWaterMark {
            let dropped = spentOrder.prefix(spentOrder.count - Wallet.spentTrimTo)
            for outpoint in dropped {
                spent.remove(outpoint)
                consumed.removeValue(forKey: outpoint)
            }
            spentOrder.removeFirst(spentOrder.count - Wallet.spentTrimTo)
        }

        for (index, output) in tx.outputs.enumerated() {
            guard let outputHash = Script.p2pkhHash(from: output.lockingScript),
                  outputHash == hash else { continue }
            let utxo = UTXO(txid: txid, vout: UInt32(index), satoshis: output.satoshis, confirmed: confirmed)
            utxos[utxo.outpoint] = utxo
        }

        return txid
    }

    /// Replaces the set from a provider's answer, keeping locally-known outputs
    /// that belong to transactions still waiting in the outbox.
    public func replaceUTXOs(with list: [UTXO], keepingTxids pending: Set<String>) {
        var next = [String: UTXO]()
        for utxo in list {
            guard utxo.satoshis > 1 else { continue }
            let outpoint = utxo.outpoint
            guard !spent.contains(outpoint) else { continue }
            next[outpoint] = utxo
        }
        for (outpoint, utxo) in utxos
        where pending.contains(utxo.txid) && next[outpoint] == nil && !spent.contains(outpoint) {
            next[outpoint] = utxo
        }
        utxos = next
    }

    /// Undoes a transaction we built but that the network rejected: its inputs
    /// become spendable again and its outputs disappear.
    public func release(rawHex: String) {
        guard let tx = Transaction.parse(hex: rawHex) else { return }
        for input in tx.inputs {
            let outpoint = "\(input.sourceTxid):\(input.sourceOutputIndex)"
            spent.remove(outpoint)
            spentOrder.removeAll { $0 == outpoint }
            if let restored = consumed.removeValue(forKey: outpoint) {
                utxos[outpoint] = restored
            }
        }
        drop(txid: tx.txid)
    }

    public func markConfirmed(txid: String) {
        for (outpoint, var utxo) in utxos where utxo.txid == txid {
            utxo.confirmed = true
            utxos[outpoint] = utxo
        }
    }

    public func drop(txid: String) {
        for outpoint in utxos.keys where outpoint.hasPrefix(txid + ":") {
            utxos.removeValue(forKey: outpoint)
        }
    }

    public func restore(utxos: [UTXO], spent: Set<String>) {
        self.utxos = Dictionary(utxos.map { ($0.outpoint, $0) }, uniquingKeysWith: { _, latest in latest })
        self.spent = spent
        self.spentOrder = Array(spent)
        self.consumed = [:]
    }

    // MARK: Fees and selection

    /// No transaction the app builds may move more than the coin supply. A
    /// larger figure is a typo, and letting it into the arithmetic below would
    /// trap on a UInt64 overflow before coin selection could refuse it.
    public static let maximumSats: UInt64 = 2_100_000_000_000_000

    /// Same model as the reference wallet: 10 bytes of overhead, 148 per input,
    /// then 8 bytes of value plus the real varint length per output — a record
    /// or inscription script easily crosses the 252-byte varint boundary, and
    /// a flat 1-byte assumption under-fees exactly the largest transactions.
    func estimatedFee(inputCount: Int, outputScriptLengths: [Int]) -> UInt64 {
        var size = 10 + inputCount * 148
        for length in outputScriptLengths {
            let varint = length < 0xfd ? 1 : (length <= 0xffff ? 3 : 5)
            size += 8 + varint + length
        }
        let computed = UInt64(ceil(Double(size) * feePerByte))
        return max(minFee, computed)
    }

    /// Unconfirmed outputs first (they are our own change, and chaining keeps
    /// conversation order), then largest first.
    func selectInputs(target: UInt64) throws -> [UTXO] {
        let sorted = utxos.values.sorted { lhs, rhs in
            if lhs.confirmed != rhs.confirmed { return !lhs.confirmed && rhs.confirmed }
            return lhs.satoshis > rhs.satoshis
        }

        var selected = [UTXO]()
        var total: UInt64 = 0
        for utxo in sorted {
            selected.append(utxo)
            total += utxo.satoshis
            if total >= target { break }
        }
        guard total >= target else {
            throw TransactionError.insufficientFunds(available: total, required: target)
        }
        return selected
    }

    /// Selects inputs until they cover `payAmount` *plus the real fee* of the
    /// transaction those inputs would produce. Selecting against a fixed guess
    /// and checking the real fee afterwards — the old two-step — failed a
    /// wallet full of small coins even though it held plenty: every extra
    /// input raises the fee, and nothing went back for more coins.
    ///
    /// `outputScriptLengths` must describe every output the transaction will
    /// carry, change included, so the fee is computed against the real shape.
    func selectInputsCoveringFee(payAmount: UInt64,
                                 outputScriptLengths: [Int]) throws -> (selected: [UTXO], fee: UInt64) {
        let sorted = utxos.values.sorted { lhs, rhs in
            if lhs.confirmed != rhs.confirmed { return !lhs.confirmed && rhs.confirmed }
            return lhs.satoshis > rhs.satoshis
        }

        var selected = [UTXO]()
        var total: UInt64 = 0
        for utxo in sorted {
            selected.append(utxo)
            total += utxo.satoshis
            let fee = estimatedFee(inputCount: selected.count,
                                   outputScriptLengths: outputScriptLengths)
            if total >= payAmount, total - payAmount >= fee {
                return (selected, fee)
            }
        }
        // Report the whole spendable balance, never the subtotal that happened
        // to be selected — "you have 1,043 sats" from a wallet holding far
        // more was worse than no number at all.
        let fee = estimatedFee(inputCount: max(1, selected.count),
                               outputScriptLengths: outputScriptLengths)
        throw TransactionError.insufficientFunds(available: total, required: payAmount + fee)
    }

    // MARK: Building

    /// Builds, signs and absorbs a Spiek message transaction.
    ///
    /// Output order matters and matches the web app: the record first, then the
    /// dust payment to the channel, then any extra payments, then change.
    public func buildMessage(kind: ChannelKind,
                             channel: [UInt8],
                             prev: [UInt8],
                             op: SpiekOp,
                             payload: [UInt8],
                             ref: [UInt8]? = nil,
                             extraPayTo: [PayTarget] = []) throws -> BuiltTransaction {
        let recordScript = try Envelope(kind: kind, channel: channel, prev: prev,
                                        op: op, payload: payload, ref: ref).encoded()

        var payAmount = dust
        for target in extraPayTo {
            let (sum, overflow) = payAmount.addingReportingOverflow(target.satoshis)
            guard !overflow, sum <= Wallet.maximumSats else { throw TransactionError.amountTooLarge }
            payAmount = sum
        }

        let changeScript = Script.p2pkh(hash160: hash)
        // Every output the transaction will carry, change included: the
        // record, the dust to the channel, the extra payments, the change.
        let outputScriptLengths = [recordScript.count, changeScript.count]
            + [Int](repeating: changeScript.count, count: extraPayTo.count)
            + [changeScript.count]
        let (selected, fee) = try selectInputsCoveringFee(payAmount: payAmount,
                                                          outputScriptLengths: outputScriptLengths)

        var tx = Transaction()
        tx.inputs = try selected.map { utxo in
            guard let input = TxInput(sourceTxid: utxo.txid,
                                      sourceOutputIndex: utxo.vout,
                                      sequence: 0xFFFF_FFFF,
                                      sourceSatoshis: utxo.satoshis,
                                      sourceLockingScript: changeScript) else {
                throw TransactionError.malformed
            }
            return input
        }

        tx.outputs.append(TxOutput(satoshis: 0, lockingScript: recordScript))
        tx.outputs.append(TxOutput(satoshis: dust, lockingScript: Script.p2pkh(hash160: channel)))
        for target in extraPayTo {
            tx.outputs.append(TxOutput(satoshis: target.satoshis,
                                       lockingScript: Script.p2pkh(hash160: target.hash)))
        }
        tx.outputs.append(TxOutput(satoshis: 0, lockingScript: changeScript))

        // Selection guarantees the inputs cover payAmount plus this fee.
        let totalIn = selected.reduce(UInt64(0)) { $0 + $1.satoshis }
        let change = totalIn - payAmount - fee
        if change == 0 {
            tx.outputs.removeLast()
        } else {
            tx.outputs[tx.outputs.count - 1].satoshis = change
        }

        try tx.signAllInputs(with: key)

        let rawHex = tx.hex
        let txid = tx.txid
        absorb(transaction: tx, confirmed: false)
        return BuiltTransaction(rawHex: rawHex, txid: txid, fee: fee)
    }

    /// A plain payment: one P2PKH output to `hash160`, change back to us. No
    /// Spiek record attached, so it is just coins moving. `extraPayTo` carries
    /// additional outputs — the service fee uses it.
    public func buildPayment(to hash160: [UInt8], satoshis: UInt64,
                             extraPayTo: [PayTarget] = []) throws -> BuiltTransaction {
        guard hash160.count == 20 else { throw KeyError.invalidAddress }
        guard satoshis >= 1 else { throw TransactionError.insufficientFunds(available: 0, required: 1) }
        guard satoshis <= Wallet.maximumSats else { throw TransactionError.amountTooLarge }

        var payAmount = satoshis
        for target in extraPayTo {
            let (sum, overflow) = payAmount.addingReportingOverflow(target.satoshis)
            guard !overflow, sum <= Wallet.maximumSats else { throw TransactionError.amountTooLarge }
            payAmount = sum
        }
        let changeScript = Script.p2pkh(hash160: hash)
        // Destination, extras and change are all P2PKH.
        let outputScriptLengths = [changeScript.count]
            + [Int](repeating: changeScript.count, count: extraPayTo.count)
            + [changeScript.count]
        let (selected, fee) = try selectInputsCoveringFee(payAmount: payAmount,
                                                          outputScriptLengths: outputScriptLengths)

        var tx = Transaction()
        tx.inputs = try selected.map { utxo in
            guard let input = TxInput(sourceTxid: utxo.txid,
                                      sourceOutputIndex: utxo.vout,
                                      sequence: 0xFFFF_FFFF,
                                      sourceSatoshis: utxo.satoshis,
                                      sourceLockingScript: changeScript) else {
                throw TransactionError.malformed
            }
            return input
        }
        tx.outputs.append(TxOutput(satoshis: satoshis, lockingScript: Script.p2pkh(hash160: hash160)))
        for target in extraPayTo {
            tx.outputs.append(TxOutput(satoshis: target.satoshis,
                                       lockingScript: Script.p2pkh(hash160: target.hash)))
        }
        tx.outputs.append(TxOutput(satoshis: 0, lockingScript: changeScript))

        // Selection guarantees the inputs cover payAmount plus this fee.
        let totalIn = selected.reduce(UInt64(0)) { $0 + $1.satoshis }
        let change = totalIn - payAmount - fee
        if change == 0 {
            tx.outputs.removeLast()
        } else {
            tx.outputs[tx.outputs.count - 1].satoshis = change
        }

        try tx.signAllInputs(with: key)
        let rawHex = tx.hex
        let txid = tx.txid
        absorb(transaction: tx, confirmed: false)
        return BuiltTransaction(rawHex: rawHex, txid: txid, fee: fee)
    }

    /// Builds a funded, signed transaction whose output 0 is `script`, with
    /// change following it.
    ///
    /// Media uses this: a picture lives in its own transaction so several
    /// messages — and several chats — can point at the same outpoint without
    /// paying to store it twice. A 1Sat Ordinal inscription passes
    /// `satoshis: 1`, because the inscribed satoshi is what carries ownership.
    public func buildDataTransaction(script: [UInt8], satoshis: UInt64 = 0) throws -> BuiltTransaction {
        guard satoshis <= Wallet.maximumSats else { throw TransactionError.amountTooLarge }
        let changeScript = Script.p2pkh(hash160: hash)
        let outputScriptLengths = [script.count, changeScript.count]
        let (selected, fee) = try selectInputsCoveringFee(payAmount: satoshis,
                                                          outputScriptLengths: outputScriptLengths)

        var tx = Transaction()
        tx.inputs = try selected.map { utxo in
            guard let input = TxInput(sourceTxid: utxo.txid,
                                      sourceOutputIndex: utxo.vout,
                                      sequence: 0xFFFF_FFFF,
                                      sourceSatoshis: utxo.satoshis,
                                      sourceLockingScript: changeScript) else {
                throw TransactionError.malformed
            }
            return input
        }
        tx.outputs.append(TxOutput(satoshis: satoshis, lockingScript: script))
        tx.outputs.append(TxOutput(satoshis: 0, lockingScript: changeScript))

        // Selection guarantees the inputs cover the satoshis plus this fee.
        let totalIn = selected.reduce(UInt64(0)) { $0 + $1.satoshis }
        let change = totalIn - satoshis - fee
        if change == 0 {
            tx.outputs.removeLast()
        } else {
            tx.outputs[tx.outputs.count - 1].satoshis = change
        }

        try tx.signAllInputs(with: key)

        let rawHex = tx.hex
        let txid = tx.txid
        absorb(transaction: tx, confirmed: false)
        return BuiltTransaction(rawHex: rawHex, txid: txid, fee: fee)
    }
}
