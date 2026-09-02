import Foundation
import SQLite3

private let SQLITE_TRANSIENT = unsafeBitCast(-1, to: sqlite3_destructor_type.self)

public enum StoreError: Error, LocalizedError {
    case cannotOpen(String)
    case query(String)

    public var errorDescription: String? {
        switch self {
        case let .cannotOpen(detail): return "Local storage could not be opened: \(detail)"
        case let .query(detail): return "Local storage failed: \(detail)"
        }
    }
}

/// Thin wrapper over the SQLite C API. Kept as a class rather than folded into
/// the actor so the connection can be opened and closed without fighting actor
/// isolation rules in `init`/`deinit`.
final class SQLiteDatabase: @unchecked Sendable {
    private var handle: OpaquePointer?

    init(path: String) throws {
        let flags = SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE | SQLITE_OPEN_FULLMUTEX
        var pointer: OpaquePointer?
        guard sqlite3_open_v2(path, &pointer, flags, nil) == SQLITE_OK, let pointer else {
            let message = pointer.map { String(cString: sqlite3_errmsg($0)) } ?? "unknown"
            if let pointer { sqlite3_close_v2(pointer) }
            throw StoreError.cannotOpen(message)
        }
        handle = pointer
    }

    deinit {
        if let handle { sqlite3_close_v2(handle) }
    }

    /// Closes the connection now (P0.5 quarantine moves the files afterwards).
    func close() {
        if let handle { sqlite3_close_v2(handle) }
        handle = nil
    }

    var lastErrorMessage: String {
        handle.map { String(cString: sqlite3_errmsg($0)) } ?? "no connection"
    }

    func execute(_ sql: String) throws {
        var errorPointer: UnsafeMutablePointer<CChar>?
        guard sqlite3_exec(handle, sql, nil, nil, &errorPointer) == SQLITE_OK else {
            let message = errorPointer.map { String(cString: $0) } ?? lastErrorMessage
            sqlite3_free(errorPointer)
            throw StoreError.query(message)
        }
    }

    func prepare(_ sql: String) throws -> Statement {
        var pointer: OpaquePointer?
        guard sqlite3_prepare_v2(handle, sql, -1, &pointer, nil) == SQLITE_OK, let pointer else {
            throw StoreError.query(lastErrorMessage)
        }
        return Statement(pointer: pointer, database: self)
    }

    /// Runs a statement that returns no rows.
    func run(_ sql: String, _ bind: (Statement) -> Void = { _ in }) throws {
        let statement = try prepare(sql)
        defer { statement.finalize() }
        bind(statement)
        let result = sqlite3_step(statement.pointer)
        guard result == SQLITE_DONE || result == SQLITE_ROW else {
            throw StoreError.query(lastErrorMessage)
        }
    }

    /// Collects the first text column of every row.
    func queryStrings(_ sql: String, _ bind: (Statement) -> Void = { _ in }) throws -> [String] {
        let statement = try prepare(sql)
        defer { statement.finalize() }
        bind(statement)

        var rows = [String]()
        while sqlite3_step(statement.pointer) == SQLITE_ROW {
            if let text = sqlite3_column_text(statement.pointer, 0) {
                rows.append(String(cString: text))
            }
        }
        return rows
    }

    final class Statement {
        let pointer: OpaquePointer
        private unowned let database: SQLiteDatabase

        init(pointer: OpaquePointer, database: SQLiteDatabase) {
            self.pointer = pointer
            self.database = database
        }

        func finalize() { sqlite3_finalize(pointer) }

        func bind(_ index: Int32, _ value: String) {
            sqlite3_bind_text(pointer, index, value, -1, SQLITE_TRANSIENT)
        }

        func bind(_ index: Int32, _ value: Double) {
            sqlite3_bind_double(pointer, index, value)
        }

        func bind(_ index: Int32, _ value: Int) {
            sqlite3_bind_int64(pointer, index, Int64(value))
        }

        func bind(_ index: Int32, blob: Data) {
            guard !blob.isEmpty else {
                // An empty Data has a nil baseAddress, which sqlite3_bind_blob
                // would store as NULL rather than a zero-length blob.
                sqlite3_bind_zeroblob(pointer, index, 0)
                return
            }
            _ = blob.withUnsafeBytes { raw in
                sqlite3_bind_blob(pointer, index, raw.baseAddress, Int32(blob.count), SQLITE_TRANSIENT)
            }
        }

        func string(_ column: Int32) -> String? {
            sqlite3_column_text(pointer, column).map { String(cString: $0) }
        }

        func int(_ column: Int32) -> Int {
            Int(sqlite3_column_int64(pointer, column))
        }

        func data(_ column: Int32) -> Data? {
            guard let blob = sqlite3_column_blob(pointer, column) else { return nil }
            return Data(bytes: blob, count: Int(sqlite3_column_bytes(pointer, column)))
        }

        func step() -> Int32 { sqlite3_step(pointer) }
    }
}

/// SQLite-backed replacement for the web app's IndexedDB cache.
///
/// v1.21 (P0.6): the whole Spiek folder — database, WAL/SHM sidecars, any
/// cache, log or export written beside them — is excluded from backups and
/// sealed with `completeUntilFirstUserAuthentication`. The class is deliberate:
/// the poll loop and WAL checkpoints must keep working after a reboot while
/// the phone is still in a pocket, which `complete` would break. Nothing here
/// ever holds the private key, seed or WIF; those live in the Keychain.
/// Fail-closed: an attribute we cannot set is thrown, never ignored, so a
/// production build refuses to run unprotected rather than silently degrade.
public enum StorageProtection {
    public struct Failure: Error, CustomStringConvertible {
        public let path: String
        public let underlying: Error
        public var description: String { "could not protect \(path): \(underlying)" }
    }

    /// Applies backup exclusion + file protection to `folder` and everything
    /// under it. Call after opening the store and again whenever sidecars may
    /// have been recreated (foreground, after a checkpoint).
    public static func apply(to folder: URL) throws {
        try applyOne(folder)
        guard let walker = FileManager.default.enumerator(at: folder,
                                                          includingPropertiesForKeys: [.isDirectoryKey],
                                                          options: []) else { return }
        for case let url as URL in walker { try applyOne(url) }
    }

    static func applyOne(_ url: URL) throws {
        #if canImport(Darwin)
        var target = url
        var values = URLResourceValues()
        values.isExcludedFromBackup = true
        do { try target.setResourceValues(values) } catch { throw Failure(path: url.path, underlying: error) }
        #if os(iOS)
        do {
            try FileManager.default.setAttributes(
                [.protectionKey: FileProtectionType.completeUntilFirstUserAuthentication],
                ofItemAtPath: url.path)
        } catch { throw Failure(path: url.path, underlying: error) }
        #endif
        #endif
    }

    /// For tests and self-checks: true when `url` is excluded from backup
    /// (and, on iOS, carries the expected protection class).
    public static func isProtected(_ url: URL) -> Bool {
        #if canImport(Darwin)
        guard let values = try? url.resourceValues(forKeys: [.isExcludedFromBackupKey]),
              values.isExcludedFromBackup == true else { return false }
        #if os(iOS)
        let attrs = (try? FileManager.default.attributesOfItem(atPath: url.path)) ?? [:]
        return (attrs[.protectionKey] as? FileProtectionType) == .completeUntilFirstUserAuthentication
        #else
        return true
        #endif
        #else
        return true
        #endif
    }
}

/// Records are stored as JSON blobs beside the few columns we actually query
/// on, which keeps the schema stable while record shapes evolve.
public actor Store {
    private let db: SQLiteDatabase
    private let encoder = JSONEncoder()
    private let decoder = JSONDecoder()

    public static func defaultURL() -> URL {
        // Protection class and backup exclusion are applied explicitly in
        // `init(url:)` via `StorageProtection` (v1.21) — see that type for
        // the reasoning. The wallet key itself never lives here, only in the
        // Keychain.
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSTemporaryDirectory())
        let folder = base.appendingPathComponent("Spiek", isDirectory: true)
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        return folder.appendingPathComponent("spiek.sqlite")
    }

    /// Pass nil for an in-memory store (used by demo mode and tests).
    public init(url: URL?) throws {
        db = try SQLiteDatabase(path: url?.path ?? ":memory:")
        try Store.migrate(db)
        // v1.21 (P0.6): seal the folder — database, -wal, -shm and whatever
        // else lives beside them — before anything is read into memory.
        if let url { try StorageProtection.apply(to: url.deletingLastPathComponent()) }
    }

    /// Closes the underlying connection so the files can be moved aside
    /// (v1.21, P0.5 quarantine). The store must not be used afterwards.
    public func close() {
        db.close()
    }

    /// Re-applies protection to the store's folder (sidecars can be recreated
    /// by SQLite after a checkpoint). No-op for in-memory stores.
    public func reapplyProtection(folder: URL?) throws {
        if let folder { try StorageProtection.apply(to: folder) }
    }

    // MARK: Schema

    private static func migrate(_ db: SQLiteDatabase) throws {
        try db.execute("PRAGMA journal_mode = WAL;")
        try db.execute("""
        CREATE TABLE IF NOT EXISTS messages (
            txid TEXT PRIMARY KEY,
            channel TEXT NOT NULL,
            sender TEXT NOT NULL,
            sort REAL NOT NULL,
            body TEXT NOT NULL
        );
        """)
        try db.execute("CREATE INDEX IF NOT EXISTS idx_messages_channel ON messages(channel, sort);")
        try db.execute("CREATE INDEX IF NOT EXISTS idx_messages_sender ON messages(channel, sender, sort);")
        try db.execute("CREATE TABLE IF NOT EXISTS channels (channelId TEXT PRIMARY KEY, body TEXT NOT NULL);")
        try db.execute("CREATE TABLE IF NOT EXISTS chains (key TEXT PRIMARY KEY, body TEXT NOT NULL);")
        try db.execute("CREATE TABLE IF NOT EXISTS outbox (txid TEXT PRIMARY KEY, body TEXT NOT NULL);")
        try db.execute("CREATE TABLE IF NOT EXISTS meta (key TEXT PRIMARY KEY, body TEXT NOT NULL);")
        try db.execute("""
        CREATE TABLE IF NOT EXISTS media (
            outpoint TEXT PRIMARY KEY,
            bytes BLOB NOT NULL,
            size INTEGER NOT NULL,
            lastUsed INTEGER NOT NULL,
            mime TEXT NOT NULL DEFAULT 'image/jpeg'
        );
        """)
    }

    // MARK: JSON helpers

    private func encodeJSON<T: Encodable>(_ value: T) throws -> String {
        String(decoding: try encoder.encode(value), as: UTF8.self)
    }

    private func decodeJSON<T: Decodable>(_ type: T.Type, _ json: String) -> T? {
        try? decoder.decode(type, from: Data(json.utf8))
    }

    // MARK: Messages

    public func putMessage(_ message: MessageRecord) throws {
        let body = try encodeJSON(message)
        try db.run("""
        INSERT INTO messages (txid, channel, sender, sort, body) VALUES (?, ?, ?, ?, ?)
        ON CONFLICT(txid) DO UPDATE SET channel = excluded.channel, sender = excluded.sender,
            sort = excluded.sort, body = excluded.body;
        """) { statement in
            statement.bind(1, message.txid)
            statement.bind(2, message.channel)
            statement.bind(3, message.sender)
            statement.bind(4, message.sort)
            statement.bind(5, body)
        }
    }

    /// Marks a message as successfully broadcast, in one indivisible step.
    ///
    /// Read-modify-write across an `await` is the trap this exists to avoid:
    /// `putMessage` upserts the whole row, so a caller that read the record,
    /// suspended, and wrote it back after the chain-walker had confirmed the
    /// same transaction would put `height` back to nil and drop a mined
    /// message to "not in a block yet" — permanently, because its outbox row
    /// is gone by then. Inside the store actor there is no suspension point,
    /// so nothing can interleave.
    ///
    /// Returns true when something actually changed.
    @discardableResult
    public func markBroadcast(txid: String) throws -> Bool {
        guard var message = try message(txid: txid) else { return false }
        // Anything already in a block outranks this. It is not an outstanding
        // send, and its height must not be written over.
        guard message.status != .confirmed, message.height == nil else { return false }
        guard message.error != nil || message.status == .pending else { return false }
        message.error = nil
        // Not `.confirmed`: that word is reserved for a block. This is exactly
        // "the network took it".
        if message.status == .pending { message.status = .sent }
        try putMessage(message)
        return true
    }

    public func message(txid: String) throws -> MessageRecord? {
        let rows = try db.queryStrings("SELECT body FROM messages WHERE txid = ? LIMIT 1;") {
            $0.bind(1, txid)
        }
        return rows.first.flatMap { decodeJSON(MessageRecord.self, $0) }
    }

    public func hasMessage(txid: String) throws -> Bool {
        try message(txid: txid) != nil
    }

    /// The newest `limit` messages in a channel that sort before `before`,
    /// returned oldest-first.
    public func messages(channel: String,
                         limit: Int = 50,
                         before: Double = .greatestFiniteMagnitude) throws -> [MessageRecord] {
        let rows = try db.queryStrings("""
        SELECT body FROM messages WHERE channel = ? AND sort < ? ORDER BY sort DESC LIMIT ?;
        """) { statement in
            statement.bind(1, channel)
            statement.bind(2, before)
            statement.bind(3, limit)
        }
        return rows.compactMap { decodeJSON(MessageRecord.self, $0) }.reversed()
    }

    /// Applies an edit or a withdrawal to a stored message, in one indivisible
    /// step — the same rule as `markBroadcast`: a read-modify-write across an
    /// `await` in the engine could overwrite a confirmation landing in the
    /// gap. Only the original author's modifier is applied; anything else is
    /// silently refused. Returns true when something actually changed.
    @discardableResult
    public func applyModifier(txid: String,
                              editedPayload: String?,
                              editedTime: Int?,
                              deleted: Bool?,
                              from sender: String) throws -> Bool {
        guard var message = try message(txid: txid) else { return false }
        guard message.sender == sender else { return false }

        var changed = false
        if let editedPayload, message.editedPayload != editedPayload {
            message.editedPayload = editedPayload
            message.editedTime = editedTime
            changed = true
        }
        if let deleted, (message.deleted ?? false) != deleted {
            message.deleted = deleted
            changed = true
        }
        guard changed else { return false }
        try putMessage(message)
        return true
    }

    public func messages(channel: String, sender: String) throws -> [MessageRecord] {
        let rows = try db.queryStrings("""
        SELECT body FROM messages WHERE channel = ? AND sender = ? ORDER BY sort ASC;
        """) { statement in
            statement.bind(1, channel)
            statement.bind(2, sender)
        }
        return rows.compactMap { decodeJSON(MessageRecord.self, $0) }
    }

    public func deleteChannel(_ channelId: String) throws {
        try db.run("DELETE FROM messages WHERE channel = ?;") { $0.bind(1, channelId) }
        try db.run("DELETE FROM chains WHERE key LIKE ? || '|%';") { $0.bind(1, channelId) }
        try db.run("DELETE FROM channels WHERE channelId = ?;") { $0.bind(1, channelId) }
        try deleteMeta(key: "seq:\(channelId)")
        // `myprev` is namespaced by wallet hash, which this store cannot
        // know — the engine's own deleteChannel removes it.
    }

    // MARK: Channels

    public func putChannel(_ channel: ChannelRecord) throws {
        let body = try encodeJSON(channel)
        try db.run("""
        INSERT INTO channels (channelId, body) VALUES (?, ?)
        ON CONFLICT(channelId) DO UPDATE SET body = excluded.body;
        """) { statement in
            statement.bind(1, channel.channelId)
            statement.bind(2, body)
        }
    }

    public func channel(_ channelId: String) throws -> ChannelRecord? {
        let rows = try db.queryStrings("SELECT body FROM channels WHERE channelId = ? LIMIT 1;") {
            $0.bind(1, channelId)
        }
        return rows.first.flatMap { decodeJSON(ChannelRecord.self, $0) }
    }

    public func allChannels() throws -> [ChannelRecord] {
        try db.queryStrings("SELECT body FROM channels;").compactMap { decodeJSON(ChannelRecord.self, $0) }
    }

    // MARK: Chains

    public func putChain(_ chain: ChainRecord) throws {
        let body = try encodeJSON(chain)
        try db.run("""
        INSERT INTO chains (key, body) VALUES (?, ?)
        ON CONFLICT(key) DO UPDATE SET body = excluded.body;
        """) { statement in
            statement.bind(1, chain.key)
            statement.bind(2, body)
        }
    }

    public func chain(_ key: String) throws -> ChainRecord? {
        let rows = try db.queryStrings("SELECT body FROM chains WHERE key = ? LIMIT 1;") { $0.bind(1, key) }
        return rows.first.flatMap { decodeJSON(ChainRecord.self, $0) }
    }

    public func chains(forChannel channelId: String) throws -> [ChainRecord] {
        try db.queryStrings("SELECT body FROM chains WHERE key LIKE ? || '|%';") { $0.bind(1, channelId) }
            .compactMap { decodeJSON(ChainRecord.self, $0) }
    }

    // MARK: Outbox

    public func putOutbox(_ item: OutboxItem) throws {
        let body = try encodeJSON(item)
        try db.run("""
        INSERT INTO outbox (txid, body) VALUES (?, ?)
        ON CONFLICT(txid) DO UPDATE SET body = excluded.body;
        """) { statement in
            statement.bind(1, item.txid)
            statement.bind(2, body)
        }
    }

    public func allOutbox() throws -> [OutboxItem] {
        try db.queryStrings("SELECT body FROM outbox;").compactMap { decodeJSON(OutboxItem.self, $0) }
    }

    public func deleteOutbox(txid: String) throws {
        try db.run("DELETE FROM outbox WHERE txid = ?;") { $0.bind(1, txid) }
    }

    // MARK: Meta

    public func putMeta<T: Encodable>(key: String, value: T) throws {
        let body = try encodeJSON(value)
        try db.run("""
        INSERT INTO meta (key, body) VALUES (?, ?)
        ON CONFLICT(key) DO UPDATE SET body = excluded.body;
        """) { statement in
            statement.bind(1, key)
            statement.bind(2, body)
        }
    }

    public func meta<T: Decodable>(_ type: T.Type, key: String) throws -> T? {
        let rows = try db.queryStrings("SELECT body FROM meta WHERE key = ? LIMIT 1;") { $0.bind(1, key) }
        return rows.first.flatMap { decodeJSON(type, $0) }
    }

    public func deleteMeta(key: String) throws {
        try db.run("DELETE FROM meta WHERE key = ?;") { $0.bind(1, key) }
    }

    // MARK: Media cache

    public func putMedia(outpoint: String, bytes: Data, mime: String, lastUsed: Int) throws {
        try db.run("""
        INSERT INTO media (outpoint, bytes, size, lastUsed, mime) VALUES (?, ?, ?, ?, ?)
        ON CONFLICT(outpoint) DO UPDATE SET bytes = excluded.bytes,
            size = excluded.size, lastUsed = excluded.lastUsed, mime = excluded.mime;
        """) { statement in
            statement.bind(1, outpoint)
            statement.bind(2, blob: bytes)
            statement.bind(3, bytes.count)
            statement.bind(4, lastUsed)
            statement.bind(5, mime)
        }
    }

    public func media(outpoint: String) throws -> (bytes: Data, mime: String)? {
        let statement = try db.prepare("SELECT bytes, mime FROM media WHERE outpoint = ? LIMIT 1;")
        defer { statement.finalize() }
        statement.bind(1, outpoint)
        guard statement.step() == SQLITE_ROW, let bytes = statement.data(0) else { return nil }
        return (bytes, statement.string(1) ?? "image/jpeg")
    }

    public func touchMedia(outpoint: String, at time: Int) throws {
        try db.run("UPDATE media SET lastUsed = ? WHERE outpoint = ?;") { statement in
            statement.bind(1, time)
            statement.bind(2, outpoint)
        }
    }

    /// Evicts least-recently-used blobs until the cache fits in `limitBytes`.
    public func trimMedia(toBytes limitBytes: Int) throws {
        var total = 0
        do {
            let statement = try db.prepare("SELECT COALESCE(SUM(size), 0) FROM media;")
            defer { statement.finalize() }
            guard statement.step() == SQLITE_ROW else { return }
            total = statement.int(0)
        }
        guard total > limitBytes else { return }

        var victims = [(outpoint: String, size: Int)]()
        do {
            let statement = try db.prepare("SELECT outpoint, size FROM media ORDER BY lastUsed ASC;")
            defer { statement.finalize() }
            while statement.step() == SQLITE_ROW {
                guard let outpoint = statement.string(0) else { continue }
                victims.append((outpoint, statement.int(1)))
            }
        }

        for victim in victims {
            guard total > limitBytes else { break }
            try db.run("DELETE FROM media WHERE outpoint = ?;") { $0.bind(1, victim.outpoint) }
            total -= victim.size
        }
    }

    // MARK: Wholesale reset

    public func wipeEverything() throws {
        for table in ["messages", "channels", "chains", "outbox", "media", "meta"] {
            try db.execute("DELETE FROM \(table);")
        }
    }
}
