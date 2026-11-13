import Foundation
import SQLite3

public enum SQLiteReaderError: Error {
    case openFailed(String)
    case prepareFailed(String)
}

public final class SQLiteReader {
    private var db: OpaquePointer?

    public init(path: String) throws {
        // Open strictly read-only. Avoid modifying WAL/SHM files on active databases.
        let encoded = path.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? path
        let uri = "file:\(encoded)?mode=ro"
        var handle: OpaquePointer?
        let rc = sqlite3_open_v2(uri, &handle, SQLITE_OPEN_READONLY | SQLITE_OPEN_URI, nil)
        if rc != SQLITE_OK {
            let msg = handle.flatMap { String(cString: sqlite3_errmsg($0)) } ?? "code \(rc)"
            if let handle { sqlite3_close(handle) }
            throw SQLiteReaderError.openFailed(msg)
        }
        self.db = handle
        sqlite3_busy_timeout(handle, 500)
    }

    deinit {
        if let db {
            sqlite3_close(db)
        }
    }

    public func query(_ sql: String, bind: [Any?] = [], rowHandler: (OpaquePointer) -> Void) throws {
        guard let db else { return }
        var stmt: OpaquePointer?
        let rc = sqlite3_prepare_v2(db, sql, -1, &stmt, nil)
        guard rc == SQLITE_OK, let stmt else {
            let msg = String(cString: sqlite3_errmsg(db))
            throw SQLiteReaderError.prepareFailed(msg)
        }
        defer { sqlite3_finalize(stmt) }

        for (idx, val) in bind.enumerated() {
            let col = Int32(idx + 1)
            if val == nil {
                sqlite3_bind_null(stmt, col)
            } else if let s = val as? String {
                sqlite3_bind_text(stmt, col, s, -1, unsafeBitCast(-1, to: sqlite3_destructor_type.self))
            } else if let i = val as? Int64 {
                sqlite3_bind_int64(stmt, col, i)
            } else if let i = val as? Int {
                sqlite3_bind_int64(stmt, col, Int64(i))
            } else if let d = val as? Double {
                sqlite3_bind_double(stmt, col, d)
            }
        }

        while true {
            let step = sqlite3_step(stmt)
            if step == SQLITE_ROW {
                rowHandler(stmt)
            } else if step == SQLITE_DONE {
                break
            } else {
                break
            }
        }
    }

    public static func text(_ stmt: OpaquePointer, _ col: Int32) -> String? {
        guard sqlite3_column_type(stmt, col) != SQLITE_NULL,
              let cstr = sqlite3_column_text(stmt, col) else {
            return nil
        }
        return String(cString: cstr)
    }

    public static func int64(_ stmt: OpaquePointer, _ col: Int32) -> Int64 {
        sqlite3_column_int64(stmt, col)
    }

    public static func double(_ stmt: OpaquePointer, _ col: Int32) -> Double? {
        guard sqlite3_column_type(stmt, col) != SQLITE_NULL else { return nil }
        return sqlite3_column_double(stmt, col)
    }
}
