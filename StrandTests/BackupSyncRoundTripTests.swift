import XCTest
import SQLite3
@testable import Strand

/// Real file-I/O tests for the Backup & Sync restore path - not string logic (must-fix #5).
///
/// These exercise the SAME hardened core the picker import uses, via the injectable
/// `DataBackup.restore(from:toDatabaseAt:)` seam (a throwaway DB path, never the user's live store):
///  - a `.noopbak` ZIP backup round-trips: `writeBackupForTesting` then `restore` returns the same rows;
///  - a foreign-but-valid SQLite (Room / no `grdb_migrations`) is REJECTED and the live DB is intact;
///  - a corrupt (non-SQLite) file is REJECTED and the live DB is intact;
///  - a folder prune actually deletes the oldest files past keep-N (pure selection, applied to real files).
final class BackupSyncRoundTripTests: XCTestCase {

    private var tmp: URL!

    override func setUpWithError() throws {
        tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("backupsync-test-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: tmp)
    }

    // MARK: - Round trip: backupNow → restore returns the same rows

    func testBackupThenRestoreReturnsTheSameRows() throws {
        // A valid GRDB-origin source DB (carries `grdb_migrations`) with one data table + known rows.
        let sourceDB = tmp.appendingPathComponent("source.sqlite")
        try makeNoopDatabase(at: sourceDB, deviceRows: ["my-whoop", "watch"])

        // Write it into a `.noopbak` ZIP exactly as the folder/auto path does.
        let backup = tmp.appendingPathComponent(BackupSync.snapshotName(1_782_000_000_000))
        try DataBackup.writeBackupForTesting(databaseAt: sourceDB, to: backup)
        XCTAssertTrue(isZip(backup), "Backup should be a ZIP container (.noopbak)")

        // Restore into a DIFFERENT, throwaway live-DB path (so the user's real store is never touched).
        let liveDB = tmp.appendingPathComponent("live.sqlite")
        let result = DataBackup.restore(from: backup, toDatabaseAt: liveDB.path)

        guard case .imported = result else {
            return XCTFail("Restore should succeed for a valid NOOP backup, got \(result)")
        }
        XCTAssertEqual(try deviceRows(in: liveDB), ["my-whoop", "watch"],
                       "Restored DB should hold exactly the backed-up rows")
    }

    // MARK: - Foreign SQLite is rejected, live DB untouched

    func testForeignSqliteIsRejectedAndLiveDbIntact() throws {
        // A Room/Android-flavoured DB: valid SQLite, but no `grdb_migrations`. It DOES hold a `device`
        // table, so the origin gate must refuse it (would otherwise strand the GRDB migrator).
        let foreign = tmp.appendingPathComponent("foreign.sqlite")
        try makeForeignDatabase(at: foreign)

        // Seed an existing live DB so we can prove it survives a rejected restore.
        let liveDB = tmp.appendingPathComponent("live.sqlite")
        try makeNoopDatabase(at: liveDB, deviceRows: ["original"])
        let before = try Data(contentsOf: liveDB)

        let result = DataBackup.restore(from: foreign, toDatabaseAt: liveDB.path)
        guard case .failure = result else {
            return XCTFail("A foreign SQLite must be rejected, got \(result)")
        }
        XCTAssertEqual(try Data(contentsOf: liveDB), before,
                       "The live DB must be byte-for-byte unchanged after a rejected restore")
        XCTAssertEqual(try deviceRows(in: liveDB), ["original"])
    }

    // MARK: - Corrupt file is rejected, live DB untouched

    func testCorruptFileIsRejectedAndLiveDbIntact() throws {
        let corrupt = tmp.appendingPathComponent("corrupt.noopbak")
        try Data("this is not a database or a zip".utf8).write(to: corrupt)

        let liveDB = tmp.appendingPathComponent("live.sqlite")
        try makeNoopDatabase(at: liveDB, deviceRows: ["original"])
        let before = try Data(contentsOf: liveDB)

        let result = DataBackup.restore(from: corrupt, toDatabaseAt: liveDB.path)
        guard case .failure = result else {
            return XCTFail("A corrupt file must be rejected, got \(result)")
        }
        XCTAssertEqual(try Data(contentsOf: liveDB), before,
                       "The live DB must be unchanged after a rejected restore")
    }

    // MARK: - Prune deletes the oldest files past keep-N (real files)

    func testPruneDeletesOldestRealFilesPastKeepN() throws {
        let folder = tmp.appendingPathComponent("folder", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)

        // Five real snapshot files + one unrelated file.
        var names: [String] = []
        for i in 0..<5 {
            let name = BackupSync.snapshotName(1_782_000_000_000 + i * 60_000)
            names.append(name)
            try Data("backup \(i)".utf8).write(to: folder.appendingPathComponent(name))
        }
        try Data("keep".utf8).write(to: folder.appendingPathComponent("notes.txt"))

        // Apply the pure prune selection to the real directory listing, then delete (the same two
        // steps `FolderBackup.prune` performs internally).
        let listing = try FileManager.default.contentsOfDirectory(atPath: folder.path)
        let toDelete = Set(BackupSync.snapshotsToPrune(listing, keep: 2))
        for name in listing where toDelete.contains(name) {
            try FileManager.default.removeItem(at: folder.appendingPathComponent(name))
        }

        let after = Set(try FileManager.default.contentsOfDirectory(atPath: folder.path))
        XCTAssertTrue(after.contains(names[4]), "Newest snapshot kept")
        XCTAssertTrue(after.contains(names[3]), "2nd-newest snapshot kept")
        XCTAssertFalse(after.contains(names[0]), "Oldest snapshot pruned")
        XCTAssertFalse(after.contains(names[1]))
        XCTAssertFalse(after.contains(names[2]))
        XCTAssertTrue(after.contains("notes.txt"), "Non-snapshot files are never pruned")
    }

    // MARK: - SQLite fixtures (system SQLite3)

    /// Build a minimal valid GRDB-origin NOOP DB: a `grdb_migrations` bookkeeping table (so the origin
    /// gate accepts it as this app's backup) plus a `device` table holding the given identifiers.
    private func makeNoopDatabase(at url: URL, deviceRows: [String]) throws {
        var db: OpaquePointer?
        guard sqlite3_open(url.path, &db) == SQLITE_OK else {
            throw TestError("open failed: \(url.path)")
        }
        defer { sqlite3_close(db) }
        try exec(db, "CREATE TABLE grdb_migrations (identifier TEXT NOT NULL PRIMARY KEY)")
        try exec(db, "INSERT INTO grdb_migrations (identifier) VALUES ('v1')")
        try exec(db, "CREATE TABLE device (id TEXT NOT NULL PRIMARY KEY)")
        for id in deviceRows {
            try exec(db, "INSERT INTO device (id) VALUES ('\(id)')")
        }
    }

    /// Build a valid SQLite file that is NOT a NOOP/GRDB backup: it carries the Room marker and a
    /// `device` table but no `grdb_migrations`, so the origin gate must reject it.
    private func makeForeignDatabase(at url: URL) throws {
        var db: OpaquePointer?
        guard sqlite3_open(url.path, &db) == SQLITE_OK else {
            throw TestError("open failed: \(url.path)")
        }
        defer { sqlite3_close(db) }
        try exec(db, "CREATE TABLE room_master_table (id INTEGER PRIMARY KEY, identity_hash TEXT)")
        try exec(db, "CREATE TABLE device (id TEXT NOT NULL PRIMARY KEY)")
        try exec(db, "INSERT INTO device (id) VALUES ('android-strap')")
    }

    private func deviceRows(in url: URL) throws -> [String] {
        var db: OpaquePointer?
        guard sqlite3_open_v2(url.path, &db, SQLITE_OPEN_READONLY, nil) == SQLITE_OK else {
            throw TestError("open (read) failed: \(url.path)")
        }
        defer { sqlite3_close(db) }
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, "SELECT id FROM device ORDER BY id", -1, &stmt, nil) == SQLITE_OK else {
            throw TestError("prepare failed")
        }
        defer { sqlite3_finalize(stmt) }
        var rows: [String] = []
        while sqlite3_step(stmt) == SQLITE_ROW {
            if let c = sqlite3_column_text(stmt, 0) { rows.append(String(cString: c)) }
        }
        return rows.sorted()
    }

    private func exec(_ db: OpaquePointer?, _ sql: String) throws {
        var err: UnsafeMutablePointer<CChar>?
        guard sqlite3_exec(db, sql, nil, nil, &err) == SQLITE_OK else {
            let message = err.map { String(cString: $0) } ?? "unknown"
            sqlite3_free(err)
            throw TestError("exec failed (\(message)): \(sql)")
        }
    }

    private func isZip(_ url: URL) -> Bool {
        guard let head = try? FileHandle(forReadingFrom: url).read(upToCount: 4), head.count >= 4 else { return false }
        return Array(head).prefix(4) == [0x50, 0x4B, 0x03, 0x04]
    }

    private struct TestError: Error { let message: String; init(_ m: String) { message = m } }
}
