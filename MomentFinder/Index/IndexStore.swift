import Foundation
import SQLite3

enum IndexStoreError: LocalizedError {
    case sqlite(String)

    var errorDescription: String? {
        switch self {
        case .sqlite(let message): "인덱스 DB 오류: \(message)"
        }
    }
}

/// 에셋 메타데이터와 임베딩을 저장하는 SQLite 저장소. 모든 호출은 내부 락으로 직렬화됩니다.
final class IndexStore: @unchecked Sendable {
    private var db: OpaquePointer?
    private let lock = NSLock()
    private static let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)

    static func openDefault() throws -> IndexStore {
        let directory = try FileManager.default
            .url(for: .applicationSupportDirectory, in: .userDomainMask, appropriateFor: nil, create: true)
            .appending(path: "MomentFinder", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return try IndexStore(url: directory.appending(path: "index.sqlite"))
    }

    init(url: URL) throws {
        guard sqlite3_open_v2(url.path, &db, SQLITE_OPEN_CREATE | SQLITE_OPEN_READWRITE | SQLITE_OPEN_FULLMUTEX, nil) == SQLITE_OK else {
            throw IndexStoreError.sqlite("열기 실패: \(url.path)")
        }
        try execute("""
            PRAGMA journal_mode = WAL;
            CREATE TABLE IF NOT EXISTS assets (
                id TEXT PRIMARY KEY,
                kind INTEGER NOT NULL,
                created REAL,
                duration REAL NOT NULL DEFAULT 0,
                model TEXT NOT NULL,
                indexed_at REAL NOT NULL,
                detail INTEGER NOT NULL DEFAULT 1
            );
            CREATE TABLE IF NOT EXISTS vectors (
                asset_id TEXT NOT NULL,
                time REAL NOT NULL,
                embedding BLOB NOT NULL
            );
            CREATE INDEX IF NOT EXISTS vectors_asset ON vectors(asset_id);
            """)
        try migrateDetailColumn()
    }

    /// detail 열이 없던 DB 는 열을 추가하고, 0초 프레임 하나뿐인 동영상(장면 대신 대표 이미지로 분석된 것)을 preview 로 표시합니다.
    private func migrateDetailColumn() throws {
        var columns = Set<String>()
        try query("PRAGMA table_info(assets)") { row in
            columns.insert(String(cString: sqlite3_column_text(row, 1)))
        }
        guard !columns.contains("detail") else { return }
        try execute("""
            ALTER TABLE assets ADD COLUMN detail INTEGER NOT NULL DEFAULT 1;
            UPDATE assets SET detail = 0 WHERE kind = \(MediaKind.video.rawValue) AND id IN (
                SELECT asset_id FROM vectors GROUP BY asset_id HAVING COUNT(*) = 1 AND MAX(time) = 0
            );
            """)
    }

    deinit {
        sqlite3_close(db)
    }

    func indexedAssetIDs(model: String) throws -> Set<String> {
        try locked {
            var ids = Set<String>()
            try query("SELECT id FROM assets WHERE model = ?", bind: { sqlite3_bind_text($0, 1, model, -1, Self.transient) }) { row in
                ids.insert(String(cString: sqlite3_column_text(row, 0)))
            }
            return ids
        }
    }

    func previewAssetIDs(model: String) throws -> Set<String> {
        try locked {
            var ids = Set<String>()
            let sql = "SELECT id FROM assets WHERE model = ? AND detail = \(IndexDetail.preview.rawValue)"
            try query(sql, bind: { sqlite3_bind_text($0, 1, model, -1, Self.transient) }) { row in
                ids.insert(String(cString: sqlite3_column_text(row, 0)))
            }
            return ids
        }
    }

    func allAssetIDs() throws -> Set<String> {
        try locked {
            var ids = Set<String>()
            try query("SELECT id FROM assets") { row in
                ids.insert(String(cString: sqlite3_column_text(row, 0)))
            }
            return ids
        }
    }

    func save(
        assetID: String,
        kind: MediaKind,
        created: Date?,
        duration: Double,
        model: String,
        detail: IndexDetail = .complete,
        frames: [FrameEmbedding]
    ) throws {
        try locked {
            try execute("BEGIN IMMEDIATE")
            do {
                try run("DELETE FROM vectors WHERE asset_id = ?") { sqlite3_bind_text($0, 1, assetID, -1, Self.transient) }
                let sql = "INSERT OR REPLACE INTO assets (id, kind, created, duration, model, indexed_at, detail) VALUES (?, ?, ?, ?, ?, ?, ?)"
                try run(sql) { stmt in
                    sqlite3_bind_text(stmt, 1, assetID, -1, Self.transient)
                    sqlite3_bind_int(stmt, 2, Int32(kind.rawValue))
                    if let created { sqlite3_bind_double(stmt, 3, created.timeIntervalSince1970) } else { sqlite3_bind_null(stmt, 3) }
                    sqlite3_bind_double(stmt, 4, duration)
                    sqlite3_bind_text(stmt, 5, model, -1, Self.transient)
                    sqlite3_bind_double(stmt, 6, Date().timeIntervalSince1970)
                    sqlite3_bind_int(stmt, 7, Int32(detail.rawValue))
                }
                for frame in frames {
                    try run("INSERT INTO vectors (asset_id, time, embedding) VALUES (?, ?, ?)") { stmt in
                        sqlite3_bind_text(stmt, 1, assetID, -1, Self.transient)
                        sqlite3_bind_double(stmt, 2, frame.time)
                        frame.vector.withUnsafeBytes { raw in
                            _ = sqlite3_bind_blob(stmt, 3, raw.baseAddress, Int32(raw.count), Self.transient)
                        }
                    }
                }
                try execute("COMMIT")
            } catch {
                try? execute("ROLLBACK")
                throw error
            }
        }
    }

    func delete(assetIDs: Set<String>) throws {
        guard !assetIDs.isEmpty else { return }
        try locked {
            try execute("BEGIN IMMEDIATE")
            for id in assetIDs {
                try run("DELETE FROM vectors WHERE asset_id = ?") { sqlite3_bind_text($0, 1, id, -1, Self.transient) }
                try run("DELETE FROM assets WHERE id = ?") { sqlite3_bind_text($0, 1, id, -1, Self.transient) }
            }
            try execute("COMMIT")
        }
    }

    func deleteAll() throws {
        try locked {
            try execute("DELETE FROM vectors; DELETE FROM assets;")
        }
    }

    func loadVectors(model: String, dimension: Int) throws -> [StoredVector] {
        try locked {
            var vectors: [StoredVector] = []
            let sql = """
                SELECT v.asset_id, a.kind, v.time, v.embedding
                FROM vectors v JOIN assets a ON a.id = v.asset_id
                WHERE a.model = ?
                """
            try query(sql, bind: { sqlite3_bind_text($0, 1, model, -1, Self.transient) }) { row in
                let byteCount = Int(sqlite3_column_bytes(row, 3))
                guard byteCount == dimension * MemoryLayout<Float>.size,
                      let blob = sqlite3_column_blob(row, 3),
                      let kind = MediaKind(rawValue: Int(sqlite3_column_int(row, 1))) else { return }
                let vector = Array(UnsafeBufferPointer(start: blob.assumingMemoryBound(to: Float.self), count: dimension))
                vectors.append(StoredVector(
                    assetID: String(cString: sqlite3_column_text(row, 0)),
                    kind: kind,
                    time: sqlite3_column_double(row, 2),
                    vector: vector
                ))
            }
            return vectors
        }
    }

    // MARK: - SQLite helpers

    private func locked<T>(_ body: () throws -> T) rethrows -> T {
        lock.lock()
        defer { lock.unlock() }
        return try body()
    }

    private func execute(_ sql: String) throws {
        guard sqlite3_exec(db, sql, nil, nil, nil) == SQLITE_OK else { throw lastError() }
    }

    private func run(_ sql: String, bind: (OpaquePointer?) -> Void) throws {
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { throw lastError() }
        defer { sqlite3_finalize(stmt) }
        bind(stmt)
        guard sqlite3_step(stmt) == SQLITE_DONE else { throw lastError() }
    }

    private func query(_ sql: String, bind: (OpaquePointer?) -> Void = { _ in }, row: (OpaquePointer?) -> Void) throws {
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { throw lastError() }
        defer { sqlite3_finalize(stmt) }
        bind(stmt)
        while true {
            let result = sqlite3_step(stmt)
            if result == SQLITE_ROW {
                row(stmt)
            } else if result == SQLITE_DONE {
                break
            } else {
                throw lastError()
            }
        }
    }

    private func lastError() -> IndexStoreError {
        .sqlite(String(cString: sqlite3_errmsg(db)))
    }
}
