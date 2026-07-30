import Foundation
import SQLite3


enum HistoryStatus: String, Sendable {
    case completed
    case failed
}
struct HistoryEntry: Sendable {
    let id: Int64
    let text: String
    let audioPath: String
    let durationMilliseconds: Int?
    let source: String?
    let status: HistoryStatus
    let errorMessage: String?
    let createdAt: String
}

enum HistoryStoreError: LocalizedError {
    case open(String)
    case execute(String)

    var errorDescription: String? {
        switch self {
        case .open(let message): return "Could not open transcription history: \(message)"
        case .execute(let message): return "Could not update transcription history: \(message)"
        }
    }
}

actor HistoryStore {
    static let shared: HistoryStore = {
        do { return try HistoryStore() }
        catch { fatalError(error.localizedDescription) }
    }()

    private var database: OpaquePointer?
    private let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)

    init(databaseURL: URL = Paths.database) throws {
        guard sqlite3_open(databaseURL.path, &database) == SQLITE_OK else {
            let message = database.map { String(cString: sqlite3_errmsg($0)) } ?? "unknown SQLite error"
            sqlite3_close(database)
            database = nil
            throw HistoryStoreError.open(message)
        }
        sqlite3_busy_timeout(database, 2_000)
        try Self.execute(database, sql: "PRAGMA journal_mode = WAL")
        try Self.execute(
            database,
            sql:
            """
            CREATE TABLE IF NOT EXISTS transcriptions (
                id INTEGER PRIMARY KEY AUTOINCREMENT,
                audio_path TEXT NOT NULL,
                text TEXT NOT NULL,
                duration_ms INTEGER,
                created_at TEXT DEFAULT (datetime('now'))
            )
            """
        )
        if try !Self.columnNames(database).contains("source") {
            try Self.execute(database, sql: "ALTER TABLE transcriptions ADD COLUMN source TEXT")
        }
        let columns = try Self.columnNames(database)
        if !columns.contains("status") {
            try Self.execute(
                database,
                sql: "ALTER TABLE transcriptions ADD COLUMN status TEXT NOT NULL DEFAULT 'completed'"
            )
        }
        if !columns.contains("error_message") {
            try Self.execute(database, sql: "ALTER TABLE transcriptions ADD COLUMN error_message TEXT")
        }
    }

    deinit {
        sqlite3_close(database)
    }

    @discardableResult
    func save(
        audioPath: String,
        text: String,
        durationMilliseconds: Int?,
        source: String
    ) throws -> Int64 {
        let sql = "INSERT INTO transcriptions (audio_path, text, duration_ms, source, status) VALUES (?, ?, ?, ?, 'completed')"
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(database, sql, -1, &statement, nil) == SQLITE_OK else {
            throw currentError()
        }
        defer { sqlite3_finalize(statement) }

        sqlite3_bind_text(statement, 1, audioPath, -1, transient)
        sqlite3_bind_text(statement, 2, text, -1, transient)
        if let durationMilliseconds {
            sqlite3_bind_int64(statement, 3, Int64(durationMilliseconds))
        } else {
            sqlite3_bind_null(statement, 3)
        }
        sqlite3_bind_text(statement, 4, source, -1, transient)

        guard sqlite3_step(statement) == SQLITE_DONE else { throw currentError() }
        return sqlite3_last_insert_rowid(database)
    }

    @discardableResult
    func saveFailure(
        audioPath: String,
        durationMilliseconds: Int?,
        source: String,
        errorMessage: String
    ) throws -> Int64 {
        let sql = """
        INSERT INTO transcriptions
            (audio_path, text, duration_ms, source, status, error_message)
        VALUES (?, '', ?, ?, 'failed', ?)
        """
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(database, sql, -1, &statement, nil) == SQLITE_OK else {
            throw currentError()
        }
        defer { sqlite3_finalize(statement) }

        sqlite3_bind_text(statement, 1, audioPath, -1, transient)
        if let durationMilliseconds {
            sqlite3_bind_int64(statement, 2, Int64(durationMilliseconds))
        } else {
            sqlite3_bind_null(statement, 2)
        }
        sqlite3_bind_text(statement, 3, source, -1, transient)
        sqlite3_bind_text(statement, 4, errorMessage, -1, transient)

        guard sqlite3_step(statement) == SQLITE_DONE else { throw currentError() }
        return sqlite3_last_insert_rowid(database)
    }

    func resolveFailure(
        id: Int64,
        text: String,
        durationMilliseconds: Int?,
        source: String
    ) throws {
        let sql = """
        UPDATE transcriptions
        SET text = ?, duration_ms = COALESCE(?, duration_ms), source = ?,
            status = 'completed', error_message = NULL
        WHERE id = ? AND status = 'failed'
        """
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(database, sql, -1, &statement, nil) == SQLITE_OK else {
            throw currentError()
        }
        defer { sqlite3_finalize(statement) }

        sqlite3_bind_text(statement, 1, text, -1, transient)
        if let durationMilliseconds {
            sqlite3_bind_int64(statement, 2, Int64(durationMilliseconds))
        } else {
            sqlite3_bind_null(statement, 2)
        }
        sqlite3_bind_text(statement, 3, source, -1, transient)
        sqlite3_bind_int64(statement, 4, id)

        guard sqlite3_step(statement) == SQLITE_DONE else { throw currentError() }
        guard sqlite3_changes(database) == 1 else {
            throw HistoryStoreError.execute("failed recording no longer exists")
        }
    }

    func history(limit: Int = 100) throws -> [HistoryEntry] {
        let sql = """
        SELECT id, text, audio_path, duration_ms, source, status, error_message, created_at
        FROM transcriptions
        ORDER BY id DESC
        LIMIT ?
        """
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(database, sql, -1, &statement, nil) == SQLITE_OK else {
            throw currentError()
        }
        defer { sqlite3_finalize(statement) }
        sqlite3_bind_int(statement, 1, Int32(min(max(limit, 1), 200)))

        var entries: [HistoryEntry] = []
        while sqlite3_step(statement) == SQLITE_ROW {
            entries.append(HistoryEntry(
                id: sqlite3_column_int64(statement, 0),
                text: text(statement, column: 1),
                audioPath: text(statement, column: 2),
                durationMilliseconds: sqlite3_column_type(statement, 3) == SQLITE_NULL
                    ? nil : Int(sqlite3_column_int64(statement, 3)),
                source: sqlite3_column_type(statement, 4) == SQLITE_NULL
                    ? nil : text(statement, column: 4),
                status: HistoryStatus(rawValue: text(statement, column: 5)) ?? .completed,
                errorMessage: sqlite3_column_type(statement, 6) == SQLITE_NULL
                    ? nil : text(statement, column: 6),
                createdAt: text(statement, column: 7)
            ))
        }
        if sqlite3_errcode(database) != SQLITE_OK && sqlite3_errcode(database) != SQLITE_DONE {
            throw currentError()
        }
        return entries
    }

    private static func columnNames(_ database: OpaquePointer?) throws -> Set<String> {
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(database, "PRAGMA table_info(transcriptions)", -1, &statement, nil) == SQLITE_OK else {
            throw databaseError(database)
        }
        defer { sqlite3_finalize(statement) }
        var names: Set<String> = []
        while sqlite3_step(statement) == SQLITE_ROW {
            guard let value = sqlite3_column_text(statement, 1) else { continue }
            names.insert(String(cString: value))
        }
        return names
    }

    private static func execute(_ database: OpaquePointer?, sql: String) throws {
        var message: UnsafeMutablePointer<CChar>?
        guard sqlite3_exec(database, sql, nil, nil, &message) == SQLITE_OK else {
            let detail = message.map { String(cString: $0) }
                ?? databaseError(database).localizedDescription
            sqlite3_free(message)
            throw HistoryStoreError.execute(detail)
        }
    }

    private static func databaseError(_ database: OpaquePointer?) -> HistoryStoreError {
        HistoryStoreError.execute(database.map { String(cString: sqlite3_errmsg($0)) } ?? "unknown SQLite error")
    }

    private func currentError() -> HistoryStoreError {
        HistoryStoreError.execute(database.map { String(cString: sqlite3_errmsg($0)) } ?? "unknown SQLite error")
    }

    private func text(_ statement: OpaquePointer?, column: Int32) -> String {
        guard let value = sqlite3_column_text(statement, column) else { return "" }
        return String(cString: value)
    }
}
