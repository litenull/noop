package com.noop.testcentre

import android.content.Context
import android.content.SharedPreferences
import org.json.JSONObject

/**
 * The Test Centre orchestration surface (Kotlin twin of the Swift TestCentre).
 *
 * Backed by a SINGLE SharedPreferences file "noop_testcentre" for all NEW Test Centre flags,
 * consolidating what used to be scattered across noop_prefs / noop_experiments / noop_debug_export and
 * ~10 non-reactive mutableStateOf mirrors in SettingsScreen. The legacy experiment + debug-export keys
 * are PRESERVED in their own files (read through their existing accessors), so migration never loses a
 * setting (spec section 10). [active] is the zero-cost gate engines check before emitting a tagged line.
 *
 * The constructor takes a [SharedPreferences] directly so the surface is exercisable on the plain JVM
 * (no Robolectric, matching the rest of the suite, see DeviceRegistryTest / MoodStoreTest); production
 * uses [from] to bind the real "noop_testcentre" file.
 */
class TestCentre internal constructor(private val prefs: SharedPreferences) {

    /** The zero-cost gate. `if (testCentre.active(TestDomain.SLEEP)) client.log(line, TestDomain.SLEEP)`. */
    fun active(d: TestDomain): Boolean {
        if (d == TestDomain.UNIVERSAL) return anyActive()        // universal rides whatever mode is on
        if (prefs.getBoolean(ACTIVE_PREFIX + TestDomain.MASTER.id, false)) return true  // master = all on
        return prefs.getBoolean(ACTIVE_PREFIX + d.id, false)
    }

    /** True when ANY non-universal mode is on (drives the testing-on banner plus the universal traces). */
    fun anyActive(): Boolean = TestDomain.values().any {
        it != TestDomain.UNIVERSAL && prefs.getBoolean(ACTIVE_PREFIX + it.id, false)
    }

    fun activate(d: TestDomain) {
        prefs.edit()
            .putBoolean(ACTIVE_PREFIX + d.id, true)
            .putLong(STARTED_PREFIX + d.id, System.currentTimeMillis() / 1000L)
            .apply()
    }

    fun deactivate(d: TestDomain) {
        prefs.edit().putBoolean(ACTIVE_PREFIX + d.id, false).apply()
    }

    /** Unix seconds the mode was last activated, or null if never. */
    fun startedAt(d: TestDomain): Long? {
        val t = prefs.getLong(STARTED_PREFIX + d.id, 0L)
        return if (t > 0L) t else null
    }

    fun answers(d: TestDomain): Map<String, String> {
        val raw = prefs.getString(ANSWERS_PREFIX + d.id, null) ?: return emptyMap()
        return runCatching {
            val o = JSONObject(raw)
            buildMap { for (k in o.keys()) put(k, o.getString(k)) }
        }.getOrDefault(emptyMap())
    }

    fun setAnswers(d: TestDomain, m: Map<String, String>) {
        val o = JSONObject()
        for ((k, v) in m) o.put(k, v)
        prefs.edit().putString(ANSWERS_PREFIX + d.id, o.toString()).apply()
    }

    /**
     * One-time migration. Idempotent, guarded by the v1 bool. Phase 1 has no domain-activation state to
     * seed from the legacy toggles (those are advanced experimental flags, gathered by the IA but not
     * domain activations), so this only stamps the guard. The legacy PuffinExperiment (noop_experiments)
     * and DebugExportSettings (noop_debug_export) keys are read in place through their existing
     * accessors; nothing is moved or renamed.
     */
    fun migrate() {
        if (prefs.getBoolean(MIGRATED_KEY, false)) return
        prefs.edit().putBoolean(MIGRATED_KEY, true).apply()
    }

    companion object {
        private const val PREFS = "noop_testcentre"
        private const val ACTIVE_PREFIX = "testcentre.active."
        private const val STARTED_PREFIX = "testcentre.startedAt."
        private const val ANSWERS_PREFIX = "testcentre.answers."
        private const val MIGRATED_KEY = "testcentre.migrated.v1"

        fun from(context: Context): TestCentre =
            TestCentre(context.getSharedPreferences(PREFS, Context.MODE_PRIVATE))
    }
}
