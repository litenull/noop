package com.noop.ui

import android.content.Context
import android.net.Uri
import android.provider.DocumentsContract
import androidx.work.CoroutineWorker
import androidx.work.ExistingPeriodicWorkPolicy
import androidx.work.PeriodicWorkRequestBuilder
import androidx.work.WorkManager
import androidx.work.WorkerParameters
import com.noop.data.DataBackup
import java.text.SimpleDateFormat
import java.util.Date
import java.util.Locale
import java.util.TimeZone
import java.util.concurrent.TimeUnit

/**
 * Backup & Sync (Phase 1 - folder destination). Writes the full `.noopbak` snapshot (the existing
 * [DataBackup] whole-DB format) into a user-chosen folder (a SAF tree), on demand and on an opt-in
 * daily schedule. Point that folder at a desktop Google Drive / Dropbox sync client (or a phone sync
 * app) and you get off-device backup with NO in-app cloud account, no OAuth, no secrets - NOOP only
 * ever writes a local file; the user's own sync client does any upload.
 *
 * DESIGN
 * - Snapshots are timestamped and immutable. "Restore" REPLACES the live DB (whole-DB snapshot,
 *   newest-wins), exactly as [DataBackup.importFrom] already does - we add nothing to the restore
 *   safety path (magic-byte + Room/GRDB-origin validation, sidecar snapshot, rollback-on-failure).
 * - The pure filename/selection helpers are unit-tested byte-for-byte against the Apple twin so a
 *   `.noopbak` produced on either platform is named + selected identically.
 * - The daily schedule is opt-in (default OFF) and runs off the main thread (a whole-DB zip can be
 *   100MB+). The periodic write goes through WorkManager (survives reboot/app-kill, never the
 *   launch-critical path); the on-launch CATCH-UP is a deferred IO coroutine (see [catchUpIfDue]).
 */
object BackupSync {

    /** The two backup destinations Phase 1 is built to support (Drive lands in a later phase). */
    enum class Destination { FOLDER /* , GOOGLE_DRIVE */ }

    private const val PREFIX = "noop-backup-"
    private const val SUFFIX = ".noopbak"

    /** Generic binary MIME for the SAF createDocument call (the bytes are a ZIP container). */
    const val MIME = "application/octet-stream"

    /** Default snapshots kept by prune. Identical to the Apple `FolderBackup.keepCount`. */
    const val DEFAULT_KEEP = 10

    /** A day in ms - the catch-up cadence (mirrors the Apple `dayMs`). */
    private const val DAY_MS = 24L * 60L * 60L * 1000L

    // ── Pure helpers (unit-tested; mirror the Apple BackupSync) ─────────────────

    private fun fmt() = SimpleDateFormat("yyyyMMdd-HHmmss", Locale.US).apply {
        timeZone = TimeZone.getTimeZone("UTC")
        isLenient = false
    }

    /** Canonical snapshot filename for an instant: `noop-backup-YYYYMMDD-HHMMSS.noopbak` (UTC). */
    fun snapshotName(epochMs: Long): String = PREFIX + fmt().format(Date(epochMs)) + SUFFIX

    /** The UTC instant (ms) encoded in a snapshot filename, or null if [name] is not one of ours. */
    fun snapshotTimeMs(name: String): Long? {
        if (!name.startsWith(PREFIX) || !name.endsWith(SUFFIX)) return null
        val stamp = name.substring(PREFIX.length, name.length - SUFFIX.length)
        return runCatching { fmt().parse(stamp)?.time }.getOrNull()
    }

    fun isSnapshot(name: String): Boolean = snapshotTimeMs(name) != null

    /** Newest snapshot by encoded time among [names] (non-snapshots ignored), or null if none. */
    fun latestSnapshot(names: List<String>): String? =
        names.filter(::isSnapshot).maxByOrNull { snapshotTimeMs(it)!! }

    /** Snapshots to DELETE to keep only the [keep] newest (oldest-first). Empty when within budget. */
    fun snapshotsToPrune(names: List<String>, keep: Int): List<String> {
        val snaps = names.filter(::isSnapshot).sortedByDescending { snapshotTimeMs(it)!! }
        return if (snaps.size <= keep) emptyList() else snaps.drop(keep)
    }

    /** True when [nowMs] is at least a day past [lastBackupMs] (pure, so the catch-up gate is testable). */
    fun isCatchUpDue(lastBackupMs: Long, nowMs: Long): Boolean = nowMs - lastBackupMs >= DAY_MS

    // ── Folder destination I/O (SAF tree via DocumentsContract - no extra dep) ──

    /** Create + write one snapshot into the chosen [treeUri]; returns the new file Uri, or null on failure. */
    fun writeSnapshot(context: Context, treeUri: Uri, nowMs: Long = System.currentTimeMillis()): Uri? {
        val resolver = context.contentResolver
        val parentDoc = DocumentsContract.buildDocumentUriUsingTree(
            treeUri,
            DocumentsContract.getTreeDocumentId(treeUri),
        )
        val fileUri = runCatching {
            DocumentsContract.createDocument(resolver, parentDoc, MIME, snapshotName(nowMs))
        }.getOrNull() ?: return null
        // exportTo throws on failure; on a partial write delete the half-written doc so prune/latest
        // never picks up a corrupt snapshot.
        return runCatching {
            DataBackup.exportTo(context, fileUri)
            fileUri
        }.getOrElse {
            runCatching { DocumentsContract.deleteDocument(resolver, fileUri) }
            null
        }
    }

    /** Run one backup into the persisted folder, prune to [BackupSyncPrefs.keepCount], stamp last-backup. */
    fun backupNow(context: Context): Boolean {
        val treeUri = BackupSyncPrefs.treeUri(context) ?: return false
        writeSnapshot(context, treeUri) ?: return false
        BackupSyncPrefs.setLastBackupMs(context, System.currentTimeMillis())
        prune(context, treeUri)
        return true
    }

    /** Best-effort retention: delete snapshots beyond keepCount. Listing failures are ignored. */
    private fun prune(context: Context, treeUri: Uri) {
        val keep = BackupSyncPrefs.keepCount(context)
        val children = runCatching { listSnapshotDocs(context, treeUri) }.getOrDefault(emptyList())
        val toDelete = snapshotsToPrune(children.map { it.first }, keep).toSet()
        for ((name, docUri) in children) {
            if (name in toDelete) {
                runCatching { DocumentsContract.deleteDocument(context.contentResolver, docUri) }
            }
        }
    }

    /** (name, documentUri) for every snapshot in the tree, newest-first. Drives restore-from-folder. */
    fun listSnapshotDocs(context: Context, treeUri: Uri): List<Pair<String, Uri>> {
        val childrenUri = DocumentsContract.buildChildDocumentsUriUsingTree(
            treeUri,
            DocumentsContract.getTreeDocumentId(treeUri),
        )
        val out = ArrayList<Pair<String, Uri>>()
        context.contentResolver.query(
            childrenUri,
            arrayOf(
                DocumentsContract.Document.COLUMN_DOCUMENT_ID,
                DocumentsContract.Document.COLUMN_DISPLAY_NAME,
            ),
            null, null, null,
        )?.use { c ->
            while (c.moveToNext()) {
                val id = c.getString(0)
                val name = c.getString(1) ?: continue
                if (isSnapshot(name)) {
                    out.add(name to DocumentsContract.buildDocumentUriUsingTree(treeUri, id))
                }
            }
        }
        return out.sortedByDescending { snapshotTimeMs(it.first)!! }
    }

    // ── Scheduling (WorkManager - survives reboot/app-kill, mirrors DebugExportScheduler) ──

    private const val WORK = "noop_backup_sync_daily"

    /**
     * (Re)schedule (or cancel) the daily auto-backup from the persisted state. No-op + cancels when the
     * feature is off or no folder is chosen, so toggling off stops the writes. KEEP so re-enabling or a
     * reboot doesn't stack duplicate daily jobs. Wrap call sites so a WorkManager hiccup never throws.
     */
    fun reschedule(context: Context) {
        val wm = WorkManager.getInstance(context.applicationContext)
        if (!BackupSyncPrefs.autoEnabled(context) || BackupSyncPrefs.treeUri(context) == null) {
            wm.cancelUniqueWork(WORK)
            return
        }
        val req = PeriodicWorkRequestBuilder<BackupSyncWorker>(1, TimeUnit.DAYS).build()
        wm.enqueueUniquePeriodicWork(WORK, ExistingPeriodicWorkPolicy.KEEP, req)
    }

    /**
     * On-launch CATCH-UP backup. Must-fix #4: deferred off the launch-critical path and run fully off
     * the main thread by the CALLER (MainActivity launches this on Dispatchers.IO after the critical
     * startup work). Gated on the toggle being ON, a folder being set, and it being at least a day since
     * the last backup. Cheap to call when off (two SharedPreferences reads, no I/O). Returns true if it
     * actually wrote a backup.
     */
    fun catchUpIfDue(context: Context, nowMs: Long = System.currentTimeMillis()): Boolean {
        if (!BackupSyncPrefs.autoEnabled(context)) return false
        if (BackupSyncPrefs.treeUri(context) == null) return false
        if (!isCatchUpDue(BackupSyncPrefs.lastBackupMs(context), nowMs)) return false
        return backupNow(context)
    }
}

/**
 * The worker that performs one scheduled backup. Re-checks the toggle (a stale enqueued job from before
 * the user turned auto off must not fire) and writes one snapshot into the chosen folder. A transient
 * failure (e.g. the folder's sync app has the tree busy) returns retry rather than poisoning the chain.
 */
class BackupSyncWorker(appContext: Context, params: WorkerParameters) :
    CoroutineWorker(appContext, params) {
    override suspend fun doWork(): Result {
        if (!BackupSyncPrefs.autoEnabled(applicationContext)) return Result.success()
        return if (BackupSync.backupNow(applicationContext)) Result.success() else Result.retry()
    }
}

/**
 * Small SharedPreferences-backed store for the folder destination + schedule state. Mirrors the Apple
 * `FolderBackup` UserDefaults keys: a persisted SAF tree uri, the auto toggle (default OFF), the last
 * backup instant, and the keep-N (default [BackupSync.DEFAULT_KEEP]). Single-user, on-device.
 */
object BackupSyncPrefs {
    private const val FILE = "backup_sync"
    private fun p(c: Context) = c.applicationContext.getSharedPreferences(FILE, Context.MODE_PRIVATE)

    fun treeUri(c: Context): Uri? = p(c).getString("tree_uri", null)?.let(Uri::parse)
    fun setTreeUri(c: Context, uri: Uri?) = p(c).edit().apply {
        if (uri == null) remove("tree_uri") else putString("tree_uri", uri.toString())
    }.apply()

    /** Master enable for the daily auto-backup. Default OFF (every NOOP automation is opt-in). */
    fun autoEnabled(c: Context): Boolean = p(c).getBoolean("auto", false)
    fun setAutoEnabled(c: Context, on: Boolean) = p(c).edit().putBoolean("auto", on).apply()

    fun lastBackupMs(c: Context): Long = p(c).getLong("last_ms", 0L)
    fun setLastBackupMs(c: Context, ms: Long) = p(c).edit().putLong("last_ms", ms).apply()

    fun keepCount(c: Context): Int = p(c).getInt("keep", BackupSync.DEFAULT_KEEP)
    fun setKeepCount(c: Context, n: Int) = p(c).edit().putInt("keep", n.coerceIn(1, 100)).apply()
}
