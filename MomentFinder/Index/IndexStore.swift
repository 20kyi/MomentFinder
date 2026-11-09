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
            CREATE TABLE IF NOT EXISTS subject_scans (
                asset_id TEXT PRIMARY KEY,
                model TEXT NOT NULL
            );
            CREATE TABLE IF NOT EXISTS subjects (
                id INTEGER PRIMARY KEY AUTOINCREMENT,
                asset_id TEXT NOT NULL,
                species INTEGER NOT NULL,
                box_x REAL NOT NULL,
                box_y REAL NOT NULL,
                box_w REAL NOT NULL,
                box_h REAL NOT NULL,
                quality REAL NOT NULL,
                embedding BLOB NOT NULL,
                cluster_id INTEGER,
                assignment INTEGER NOT NULL DEFAULT 0
            );
            CREATE INDEX IF NOT EXISTS subjects_asset ON subjects(asset_id);
            CREATE INDEX IF NOT EXISTS subjects_cluster ON subjects(cluster_id);
            CREATE TABLE IF NOT EXISTS clusters (
                id INTEGER PRIMARY KEY AUTOINCREMENT,
                species INTEGER NOT NULL,
                name TEXT
            );
            CREATE TABLE IF NOT EXISTS subject_rejections (
                subject_id INTEGER NOT NULL,
                cluster_id INTEGER NOT NULL,
                PRIMARY KEY (subject_id, cluster_id)
            );
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
                try deleteSubjects(assetID: id)
                try run("DELETE FROM subject_scans WHERE asset_id = ?") { sqlite3_bind_text($0, 1, id, -1, Self.transient) }
            }
            try execute("COMMIT")
        }
    }

    func deleteAll() throws {
        try locked {
            try execute("""
                DELETE FROM vectors; DELETE FROM assets;
                DELETE FROM subject_scans; DELETE FROM subjects; DELETE FROM clusters; DELETE FROM subject_rejections;
                """)
        }
    }

    // MARK: - Subjects

    func subjectScannedAssetIDs(model: String) throws -> Set<String> {
        try locked {
            var ids = Set<String>()
            try query("SELECT asset_id FROM subject_scans WHERE model = ?", bind: { sqlite3_bind_text($0, 1, model, -1, Self.transient) }) { row in
                ids.insert(String(cString: sqlite3_column_text(row, 0)))
            }
            return ids
        }
    }

    /// 에셋의 이전 분석 결과를 지우고 새로 저장합니다. 감지된 것이 없어도 분석 완료로 기록합니다.
    @discardableResult
    func saveSubjects(assetID: String, model: String, subjects: [DetectedSubject]) throws -> [StoredSubject] {
        try locked {
            try execute("BEGIN IMMEDIATE")
            do {
                try deleteSubjects(assetID: assetID)
                var stored: [StoredSubject] = []
                let sql = """
                    INSERT INTO subjects (asset_id, species, box_x, box_y, box_w, box_h, quality, embedding)
                    VALUES (?, ?, ?, ?, ?, ?, ?, ?)
                    """
                for subject in subjects {
                    try run(sql) { stmt in
                        sqlite3_bind_text(stmt, 1, assetID, -1, Self.transient)
                        sqlite3_bind_int(stmt, 2, Int32(subject.species.rawValue))
                        sqlite3_bind_double(stmt, 3, subject.box.minX)
                        sqlite3_bind_double(stmt, 4, subject.box.minY)
                        sqlite3_bind_double(stmt, 5, subject.box.width)
                        sqlite3_bind_double(stmt, 6, subject.box.height)
                        sqlite3_bind_double(stmt, 7, Double(subject.quality))
                        subject.vector.withUnsafeBytes { raw in
                            _ = sqlite3_bind_blob(stmt, 8, raw.baseAddress, Int32(raw.count), Self.transient)
                        }
                    }
                    stored.append(StoredSubject(
                        id: sqlite3_last_insert_rowid(db),
                        assetID: assetID,
                        species: subject.species,
                        box: subject.box,
                        quality: subject.quality,
                        clusterID: nil,
                        assignment: .auto
                    ))
                }
                try run("INSERT OR REPLACE INTO subject_scans (asset_id, model) VALUES (?, ?)") { stmt in
                    sqlite3_bind_text(stmt, 1, assetID, -1, Self.transient)
                    sqlite3_bind_text(stmt, 2, model, -1, Self.transient)
                }
                try execute("COMMIT")
                return stored
            } catch {
                try? execute("ROLLBACK")
                throw error
            }
        }
    }

    /// 군집 중심을 다시 만들 때 쓰려고 벡터와 함께 하나씩 넘겨줍니다. 전부 배열로 들고 있지 않아 메모리를 아낍니다.
    func forEachSubject(dimension: Int, _ body: (StoredSubject, [Float]) -> Void) throws {
        try locked {
            let sql = "SELECT id, asset_id, species, box_x, box_y, box_w, box_h, quality, cluster_id, assignment, embedding FROM subjects"
            try query(sql) { row in
                guard let subject = Self.subject(from: row),
                      let vector = Self.vector(from: row, column: 10, dimension: dimension) else { return }
                body(subject, vector)
            }
        }
    }

    func subjectVectors(ids: [Int64], dimension: Int) throws -> [Int64: [Float]] {
        try locked {
            var vectors: [Int64: [Float]] = [:]
            for id in ids {
                try query("SELECT embedding FROM subjects WHERE id = ?", bind: { sqlite3_bind_int64($0, 1, id) }) { row in
                    vectors[id] = Self.vector(from: row, column: 0, dimension: dimension)
                }
            }
            return vectors
        }
    }

    func loadClusters() throws -> [StoredCluster] {
        try locked {
            var clusters: [StoredCluster] = []
            try query("SELECT id, species, name FROM clusters") { row in
                guard let species = Species(rawValue: Int(sqlite3_column_int(row, 1))) else { return }
                let name = sqlite3_column_text(row, 2).map { String(cString: $0) }
                clusters.append(StoredCluster(id: sqlite3_column_int64(row, 0), species: species, name: name))
            }
            return clusters
        }
    }

    func loadRejections() throws -> [(subjectID: Int64, clusterID: Int64)] {
        try locked {
            var rejections: [(Int64, Int64)] = []
            try query("SELECT subject_id, cluster_id FROM subject_rejections") { row in
                rejections.append((sqlite3_column_int64(row, 0), sqlite3_column_int64(row, 1)))
            }
            return rejections
        }
    }

    func createCluster(species: Species, name: String? = nil) throws -> Int64 {
        try locked {
            try run("INSERT INTO clusters (species, name) VALUES (?, ?)") { stmt in
                sqlite3_bind_int(stmt, 1, Int32(species.rawValue))
                if let name { sqlite3_bind_text(stmt, 2, name, -1, Self.transient) } else { sqlite3_bind_null(stmt, 2) }
            }
            return sqlite3_last_insert_rowid(db)
        }
    }

    func assignSubjects(_ ids: [Int64], to clusterID: Int64?, assignment: SubjectAssignment) throws {
        guard !ids.isEmpty else { return }
        try locked {
            try execute("BEGIN IMMEDIATE")
            do {
                for id in ids {
                    try run("UPDATE subjects SET cluster_id = ?, assignment = ? WHERE id = ?") { stmt in
                        if let clusterID { sqlite3_bind_int64(stmt, 1, clusterID) } else { sqlite3_bind_null(stmt, 1) }
                        sqlite3_bind_int(stmt, 2, Int32(assignment.rawValue))
                        sqlite3_bind_int64(stmt, 3, id)
                    }
                }
                try execute("COMMIT")
            } catch {
                try? execute("ROLLBACK")
                throw error
            }
        }
    }

    func addRejection(subjectID: Int64, clusterID: Int64) throws {
        try locked {
            try run("INSERT OR IGNORE INTO subject_rejections (subject_id, cluster_id) VALUES (?, ?)") { stmt in
                sqlite3_bind_int64(stmt, 1, subjectID)
                sqlite3_bind_int64(stmt, 2, clusterID)
            }
        }
    }

    func renameCluster(id: Int64, name: String?) throws {
        try locked {
            try run("UPDATE clusters SET name = ? WHERE id = ?") { stmt in
                if let name { sqlite3_bind_text(stmt, 1, name, -1, Self.transient) } else { sqlite3_bind_null(stmt, 1) }
                sqlite3_bind_int64(stmt, 2, id)
            }
        }
    }

    /// source 의 구성원과 거절 기록을 target 으로 옮기고 source 를 지웁니다.
    func mergeCluster(_ source: Int64, into target: Int64) throws {
        try locked {
            try execute("BEGIN IMMEDIATE")
            do {
                try run("UPDATE subjects SET cluster_id = ? WHERE cluster_id = ?") { stmt in
                    sqlite3_bind_int64(stmt, 1, target)
                    sqlite3_bind_int64(stmt, 2, source)
                }
                try run("INSERT OR IGNORE INTO subject_rejections (subject_id, cluster_id) SELECT subject_id, ? FROM subject_rejections WHERE cluster_id = ?") { stmt in
                    sqlite3_bind_int64(stmt, 1, target)
                    sqlite3_bind_int64(stmt, 2, source)
                }
                try run("DELETE FROM subject_rejections WHERE cluster_id = ?") { sqlite3_bind_int64($0, 1, source) }
                try run("DELETE FROM clusters WHERE id = ?") { sqlite3_bind_int64($0, 1, source) }
                try execute("COMMIT")
            } catch {
                try? execute("ROLLBACK")
                throw error
            }
        }
    }

    func deleteClusters(_ ids: Set<Int64>) throws {
        guard !ids.isEmpty else { return }
        try locked {
            try execute("BEGIN IMMEDIATE")
            for id in ids {
                try run("DELETE FROM subject_rejections WHERE cluster_id = ?") { sqlite3_bind_int64($0, 1, id) }
                try run("DELETE FROM clusters WHERE id = ?") { sqlite3_bind_int64($0, 1, id) }
            }
            try execute("COMMIT")
        }
    }

    private func deleteSubjects(assetID: String) throws {
        try run("DELETE FROM subject_rejections WHERE subject_id IN (SELECT id FROM subjects WHERE asset_id = ?)") {
            sqlite3_bind_text($0, 1, assetID, -1, Self.transient)
        }
        try run("DELETE FROM subjects WHERE asset_id = ?") { sqlite3_bind_text($0, 1, assetID, -1, Self.transient) }
    }

    private static func subject(from row: OpaquePointer?) -> StoredSubject? {
        guard let species = Species(rawValue: Int(sqlite3_column_int(row, 2))) else { return nil }
        return StoredSubject(
            id: sqlite3_column_int64(row, 0),
            assetID: String(cString: sqlite3_column_text(row, 1)),
            species: species,
            box: CGRect(
                x: sqlite3_column_double(row, 3),
                y: sqlite3_column_double(row, 4),
                width: sqlite3_column_double(row, 5),
                height: sqlite3_column_double(row, 6)
            ),
            quality: Float(sqlite3_column_double(row, 7)),
            clusterID: sqlite3_column_type(row, 8) == SQLITE_NULL ? nil : sqlite3_column_int64(row, 8),
            assignment: SubjectAssignment(rawValue: Int(sqlite3_column_int(row, 9))) ?? .auto
        )
    }

    private static func vector(from row: OpaquePointer?, column: Int32, dimension: Int) -> [Float]? {
        guard Int(sqlite3_column_bytes(row, column)) == dimension * MemoryLayout<Float>.size,
              let blob = sqlite3_column_blob(row, column) else { return nil }
        return Array(UnsafeBufferPointer(start: blob.assumingMemoryBound(to: Float.self), count: dimension))
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
