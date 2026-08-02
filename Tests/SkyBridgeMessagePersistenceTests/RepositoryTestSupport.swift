import Foundation
import SQLite3

/// One isolated on-disk repository location per test. Everything lives under
/// a unique temporary directory so parallel tests never share a sidecar lock.
struct RepositoryTestFixture {
    let rootURL: URL
    let databaseURL: URL

    init() throws {
        rootURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("skybridge-message-repository-\(UUID().uuidString)")
        databaseURL = rootURL.appendingPathComponent("messages.sqlite3")
        try FileManager.default.createDirectory(
            at: rootURL,
            withIntermediateDirectories: true
        )
    }

    func remove() {
        try? FileManager.default.removeItem(at: rootURL)
    }
}

struct RawSQLiteFixtureFailure: Error {
    let operation: String
    let code: Int32
}

/// Executes raw SQL against a repository database without the repository,
/// for building historical fixtures and for corrupting state deliberately.
func executeRawSQLiteScript(at databaseURL: URL, sql: String) throws {
    var database: OpaquePointer?
    let openCode = sqlite3_open_v2(
        databaseURL.path,
        &database,
        SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE | SQLITE_OPEN_FULLMUTEX,
        nil
    )
    guard openCode == SQLITE_OK, let database else {
        if let database { sqlite3_close_v2(database) }
        throw RawSQLiteFixtureFailure(operation: "open", code: openCode)
    }
    defer { sqlite3_close_v2(database) }

    var errorMessage: UnsafeMutablePointer<CChar>?
    let executeCode = sqlite3_exec(database, sql, nil, nil, &errorMessage)
    if let errorMessage { sqlite3_free(errorMessage) }
    guard executeCode == SQLITE_OK else {
        throw RawSQLiteFixtureFailure(operation: "execute", code: executeCode)
    }
}

/// Reads one scalar integer from the database with an independent read-only
/// connection, so tests can verify on-disk state the repository committed.
func rawSQLiteScalar(at databaseURL: URL, sql: String) throws -> Int {
    var database: OpaquePointer?
    let openCode = sqlite3_open_v2(
        databaseURL.path,
        &database,
        SQLITE_OPEN_READONLY | SQLITE_OPEN_FULLMUTEX,
        nil
    )
    guard openCode == SQLITE_OK, let database else {
        if let database { sqlite3_close_v2(database) }
        throw RawSQLiteFixtureFailure(operation: "open", code: openCode)
    }
    defer { sqlite3_close_v2(database) }
    var statement: OpaquePointer?
    guard sqlite3_prepare_v2(database, sql, -1, &statement, nil) == SQLITE_OK,
          let statement else {
        throw RawSQLiteFixtureFailure(
            operation: "prepare",
            code: sqlite3_errcode(database)
        )
    }
    defer { sqlite3_finalize(statement) }
    guard sqlite3_step(statement) == SQLITE_ROW else {
        throw RawSQLiteFixtureFailure(operation: "step", code: sqlite3_errcode(database))
    }
    return Int(sqlite3_column_int64(statement, 0))
}

/// Reads one scalar text value with an independent read-only connection.
func rawSQLiteText(at databaseURL: URL, sql: String) throws -> String? {
    var database: OpaquePointer?
    let openCode = sqlite3_open_v2(
        databaseURL.path,
        &database,
        SQLITE_OPEN_READONLY | SQLITE_OPEN_FULLMUTEX,
        nil
    )
    guard openCode == SQLITE_OK, let database else {
        if let database { sqlite3_close_v2(database) }
        throw RawSQLiteFixtureFailure(operation: "open", code: openCode)
    }
    defer { sqlite3_close_v2(database) }
    var statement: OpaquePointer?
    guard sqlite3_prepare_v2(database, sql, -1, &statement, nil) == SQLITE_OK,
          let statement else {
        throw RawSQLiteFixtureFailure(
            operation: "prepare",
            code: sqlite3_errcode(database)
        )
    }
    defer { sqlite3_finalize(statement) }
    guard sqlite3_step(statement) == SQLITE_ROW else {
        throw RawSQLiteFixtureFailure(operation: "step", code: sqlite3_errcode(database))
    }
    guard let raw = sqlite3_column_text(statement, 0) else { return nil }
    return String(cString: raw)
}
