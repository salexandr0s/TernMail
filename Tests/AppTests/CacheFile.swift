import Foundation
import SQLite3
import Testing

/// A cache file that a test breaks from a connection of its own, the way a
/// full disk or a damaged database would.
struct CacheFile {
    let url = FileManager.default.temporaryDirectory.appending(path: "TernTests-\(UUID().uuidString).sqlite")

    /// Makes every `operation`, such as UPDATE or DELETE, on `table` fail.
    func refuse(_ operation: String, on table: String) throws {
        try execute("""
            CREATE TRIGGER refuse\(operation)\(table) BEFORE \(operation) ON \(table)
            BEGIN SELECT RAISE(ABORT, 'refused by the test'); END
            """)
    }

    /// Lets `operation` on `table` work again.
    func allow(_ operation: String, on table: String) throws {
        try execute("DROP TRIGGER refuse\(operation)\(table)")
    }

    func execute(_ sql: String) throws {
        var connection: OpaquePointer?
        defer { sqlite3_close(connection) }
        try #require(sqlite3_open_v2(url.path(percentEncoded: false), &connection, SQLITE_OPEN_READWRITE, nil) == SQLITE_OK)
        sqlite3_busy_timeout(connection, 3_000)
        let result = sqlite3_exec(connection, sql, nil, nil, nil)
        try #require(result == SQLITE_OK, "\(String(cString: sqlite3_errmsg(connection)))")
    }
}
