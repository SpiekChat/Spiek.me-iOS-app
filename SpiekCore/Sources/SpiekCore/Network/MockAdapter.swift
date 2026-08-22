import Foundation

/// An in-memory chain for the demo playground. Nothing leaves the device.
public actor MockAdapter: ChainAdapter {
    private struct Entry {
        var hex: String
        var height: Int?
        var pos: Int?
        var seq: Int
    }

    private var transactions: [String: Entry] = [:]
    private var byAddress: [String: [String]] = [:]
    private var sequence = 0
    private var blockHeight = 800_000
    private var mempool: [String] = []

    public init() {}

    public nonisolated var supportsUTXOFetch: Bool { false }

    // MARK: ChainAdapter

    public func getTx(_ txid: String) async throws -> ChainTx? {
        guard let entry = transactions[txid] else { return nil }
        return ChainTx(hex: entry.hex, height: entry.height, pos: entry.pos)
    }

    public func watchAddress(_ address: String, since: Int) async throws -> [AddressActivity] {
        guard let txids = byAddress[address] else { return [] }
        return txids.compactMap { txid in
            guard let entry = transactions[txid], entry.seq > since else { return nil }
            return AddressActivity(txid: txid, height: entry.height, pos: entry.pos, seq: entry.seq)
        }
        .sorted { $0.seq < $1.seq }
    }

    @discardableResult
    public func broadcast(_ rawHex: String) async throws -> String {
        guard let tx = Transaction.parse(hex: rawHex) else {
            throw AdapterError.broadcastRejected("malformed transaction")
        }
        let txid = tx.txid
        if transactions[txid] != nil { return txid }

        sequence += 1
        transactions[txid] = Entry(hex: rawHex, height: nil, pos: nil, seq: sequence)
        mempool.append(txid)
        index(tx: tx, txid: txid)
        return txid
    }

    public func fetchUTXOs(_ address: String) async throws -> [UTXO] {
        throw AdapterError.notSupported
    }

    // MARK: Demo helpers

    /// Mints coins out of thin air so the playground has something to spend.
    @discardableResult
    public func faucet(to address: String, satoshis: UInt64) throws -> BuiltTransaction {
        guard let hash = Address.hash160(from: address) else {
            throw AdapterError.broadcastRejected("unknown address")
        }

        var tx = Transaction()
        // A coinbase-like input: no real source, unique per call so txids differ.
        tx.inputs = [TxInput(sourceTxidLE: [UInt8](repeating: 0, count: 32),
                             sourceOutputIndex: 0xFFFF_FFFF,
                             unlockingScript: Script.pushData(SecureRandom.bytes(16)),
                             sequence: 0xFFFF_FFFF)]
        tx.outputs = [TxOutput(satoshis: satoshis, lockingScript: Script.p2pkh(hash160: hash))]

        let txid = tx.txid
        sequence += 1
        transactions[txid] = Entry(hex: tx.hex, height: blockHeight, pos: 0, seq: sequence)
        index(tx: tx, txid: txid)
        return BuiltTransaction(rawHex: tx.hex, txid: txid, fee: 0)
    }

    /// Confirms everything currently in the mempool.
    public func mineBlock() {
        guard !mempool.isEmpty else { blockHeight += 1; return }
        blockHeight += 1
        for (position, txid) in mempool.enumerated() {
            transactions[txid]?.height = blockHeight
            transactions[txid]?.pos = position
        }
        mempool.removeAll()
    }

    private func index(tx: Transaction, txid: String) {
        for output in tx.outputs {
            guard let hash = Script.p2pkhHash(from: output.lockingScript) else { continue }
            let address = Address.encode(hash160: hash)
            byAddress[address, default: []].append(txid)
        }
    }
}
