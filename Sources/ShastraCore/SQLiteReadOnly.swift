import Foundation
import SQLite3

final class SQLiteReadOnly {
    private var connection: OpaquePointer?
    init(path: String) throws {
        let flags = SQLITE_OPEN_READONLY | SQLITE_OPEN_FULLMUTEX
        guard sqlite3_open_v2(path, &connection, flags, nil) == SQLITE_OK else {
            let message = connection.map { String(cString: sqlite3_errmsg($0)) } ?? "Cannot open SQLite store"
            if let connection { sqlite3_close(connection) }
            throw ShastraError.invalidResponse(message)
        }
        sqlite3_busy_timeout(connection, 2000)
    }
    deinit { if let connection { sqlite3_close(connection) } }

    func rows(_ sql: String, bindings: [String] = [], visit: (OpaquePointer) throws -> Void) throws {
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(connection, sql, -1, &statement, nil) == SQLITE_OK else {
            throw ShastraError.invalidResponse(String(cString: sqlite3_errmsg(connection)))
        }
        defer { sqlite3_finalize(statement) }
        for (offset, value) in bindings.enumerated() {
            let code = value.withCString { sqlite3_bind_text(statement, Int32(offset + 1), $0, -1, unsafeBitCast(-1, to: sqlite3_destructor_type.self)) }
            guard code == SQLITE_OK else { throw ShastraError.invalidResponse("Could not bind SQLite query") }
        }
        var status = sqlite3_step(statement)
        while status == SQLITE_ROW {
            try visit(statement!)
            status = sqlite3_step(statement)
        }
        guard status == SQLITE_DONE else {
            throw ShastraError.invalidResponse(String(cString: sqlite3_errmsg(connection)))
        }
    }

    static func text(_ statement: OpaquePointer, _ column: Int32) -> String? {
        guard let pointer = sqlite3_column_text(statement, column) else { return nil }
        return String(cString: pointer)
    }

    static func data(_ statement: OpaquePointer, _ column: Int32) -> Data? {
        guard let pointer = sqlite3_column_blob(statement, column) else { return nil }
        return Data(bytes: pointer, count: Int(sqlite3_column_bytes(statement, column)))
    }

    static func int(_ statement: OpaquePointer, _ column: Int32) -> Int64 {
        sqlite3_column_int64(statement, column)
    }
}
