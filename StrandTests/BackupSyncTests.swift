import XCTest
@testable import Strand

/// Pure snapshot-naming / selection / prune logic behind Backup & Sync (the folder destination).
/// Mirror of the Android `BackupSyncTest` - same filename scheme, same newest-first selection, same
/// keep-N prune semantics - so the two platforms stay behaviourally identical (must-fix #6).
final class BackupSyncTests: XCTestCase {

    func testNameRoundTripsToUtcSecond() {
        let ms = 1_782_000_000_000 // a whole-second instant (UTC)
        let name = BackupSync.snapshotName(ms)
        XCTAssertTrue(name.hasPrefix("noop-backup-"))
        XCTAssertTrue(name.hasSuffix(".noopbak"))
        XCTAssertEqual(BackupSync.snapshotTimeMs(name), ms) // second-resolution round-trip
    }

    func testIsSnapshotRejectsNonBackups() {
        XCTAssertTrue(BackupSync.isSnapshot(BackupSync.snapshotName(1_782_000_000_000)))
        XCTAssertFalse(BackupSync.isSnapshot("photo.jpg"))
        XCTAssertFalse(BackupSync.isSnapshot("noop-backup-notadate.noopbak"))
        XCTAssertFalse(BackupSync.isSnapshot("noop-backup-20260627-123456.zip"))
        XCTAssertNil(BackupSync.snapshotTimeMs("random.txt"))
    }

    func testLatestPicksNewest() {
        let older = BackupSync.snapshotName(1_782_000_000_000)
        let newer = BackupSync.snapshotName(1_782_000_600_000) // +10 min
        XCTAssertEqual(BackupSync.latestSnapshot([older, "junk.txt", newer]), newer)
        XCTAssertNil(BackupSync.latestSnapshot(["a.txt", "b.bin"]))
    }

    func testSnapshotsNewestFirstSortsAndDropsNonSnapshots() {
        let a = BackupSync.snapshotName(1_782_000_000_000)
        let b = BackupSync.snapshotName(1_782_000_060_000)
        let c = BackupSync.snapshotName(1_782_000_120_000)
        let sorted = BackupSync.snapshotsNewestFirst([a, "x.txt", c, b])
        XCTAssertEqual(sorted, [c, b, a])
    }

    func testPruneKeepsNewestN() {
        let names = (0..<5).map { BackupSync.snapshotName(1_782_000_000_000 + $0 * 60_000) }
        let pruned = BackupSync.snapshotsToPrune(names + ["keepme.txt"], keep: 2)
        XCTAssertEqual(pruned.count, 3)
        XCTAssertTrue(pruned.contains(names[0]))    // oldest pruned
        XCTAssertFalse(pruned.contains(names[4]))   // newest kept
        XCTAssertFalse(pruned.contains("keepme.txt")) // non-snapshots never pruned
    }

    func testPruneNoOpWithinBudget() {
        XCTAssertTrue(BackupSync.snapshotsToPrune([BackupSync.snapshotName(1_782_000_000_000)], keep: 10).isEmpty)
    }
}
