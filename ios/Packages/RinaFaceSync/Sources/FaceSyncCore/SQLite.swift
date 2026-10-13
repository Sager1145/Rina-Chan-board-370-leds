import Foundation
import CSQLite

/// Used only synchronously from a single owning actor. FULLMUTEX is defense in
/// depth, not permission to share this connection across independent repositories.
final class SQLite: @unchecked Sendable {
    private var handle: OpaquePointer?
    init(_ path: String) throws {
        let code = sqlite3_open_v2(path, &handle, SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE | SQLITE_OPEN_FULLMUTEX, nil)
        guard code == SQLITE_OK else { let message = error; sqlite3_close(handle); handle = nil; throw message }
        sqlite3_busy_timeout(handle, 5000)
        try exec("PRAGMA journal_mode=DELETE")
        try exec("PRAGMA synchronous=EXTRA")
        try exec("CREATE TABLE IF NOT EXISTS metadata (key TEXT PRIMARY KEY, value BLOB NOT NULL)")
        try exec("CREATE TABLE IF NOT EXISTS operations (id TEXT PRIMARY KEY, body BLOB NOT NULL, pending INTEGER NOT NULL CHECK(pending IN(0,1)))")
    }
    deinit { sqlite3_close(handle) }
    var error: FaceSyncError { .sqlite(handle.map { String(cString: sqlite3_errmsg($0)) } ?? "Database closed") }
    func exec(_ sql: String) throws {
        guard sqlite3_exec(handle, sql, nil, nil, nil) == SQLITE_OK else { throw error }
    }
    func transaction<T>(_ body: () throws -> T) throws -> T {
        try exec("BEGIN IMMEDIATE")
        do { let result = try body(); try exec("COMMIT"); return result }
        catch { try? exec("ROLLBACK"); throw error }
    }
    private func statement(_ sql: String, _ values: [Data?]) throws -> OpaquePointer {
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(handle, sql, -1, &stmt, nil) == SQLITE_OK, let stmt else { throw error }
        do {
            for (index, value) in values.enumerated() {
                let code: Int32
                if let value {
                    code = value.withUnsafeBytes { raw in
                        // Keep an explicit zero-length blob rather than binding NULL.
                        if raw.isEmpty { return sqlite3_bind_zeroblob(stmt, Int32(index + 1), 0) }
                        return sqlite3_bind_blob(stmt, Int32(index + 1), raw.baseAddress, Int32(raw.count),
                                                 unsafeBitCast(-1, to: sqlite3_destructor_type.self))
                    }
                } else { code = sqlite3_bind_null(stmt, Int32(index + 1)) }
                guard code == SQLITE_OK else { throw error }
            }
            return stmt
        } catch { sqlite3_finalize(stmt); throw error }
    }
    func execute(_ sql: String, _ values: [Data?] = []) throws {
        let stmt = try statement(sql, values); defer { sqlite3_finalize(stmt) }
        guard sqlite3_step(stmt) == SQLITE_DONE else { throw error }
    }
    func rows(_ sql: String, _ values: [Data?] = []) throws -> [[Data]] {
        let stmt = try statement(sql, values); defer { sqlite3_finalize(stmt) }
        var rows: [[Data]] = []
        while true {
            let step = sqlite3_step(stmt)
            if step == SQLITE_DONE { return rows }
            guard step == SQLITE_ROW else { throw error }
            rows.append((0..<sqlite3_column_count(stmt)).map { column in
                let size = Int(sqlite3_column_bytes(stmt, column))
                guard size > 0, let pointer = sqlite3_column_blob(stmt, column) else { return Data() }
                return Data(bytes: pointer, count: size)
            })
        }
    }
    func metadata(_ key: String) throws -> Data? {
        try rows("SELECT value FROM metadata WHERE key=?", [Data(key.utf8)]).first?.first
    }
    func setMetadata(_ key: String, _ value: Data) throws {
        try execute("INSERT INTO metadata(key,value) VALUES(?,?) ON CONFLICT(key) DO UPDATE SET value=excluded.value", [Data(key.utf8), value])
    }
}
