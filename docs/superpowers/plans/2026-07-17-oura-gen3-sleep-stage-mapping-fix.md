# Oura Gen 3 sleep detection fix — handoff plan

Status: **implementation complete, tests not yet run.** Only verification remains.

## Diagnosis (why)

User report: sleep "too short / fragmented" and "stages look wrong" on an Oura Ring 3 (iOS).

Root causes found:

1. **The 2-bit sleep-stage code mapping was wrong.** NOOP decoded `0=awake, 1=light,
   2=deep, 3=REM`. Two independent sources agree the correct mapping is
   **`0=deep, 1=light, 2=rem, 3=awake`**:
   - open_oura Rust toolkit, from the enum in Oura's own decompiled native parser
     (`SleepPhase_OSSAv1`): https://github.com/Th0rgal/open_oura —
     `crates/oura-protocol/src/events.rs` (`decode_sleep_phases`,
     `PHASE = ["deep","light","rem","awake"]`)
   - Oura cloud API hypnogram: `1=deep, 2=light, 3=REM, 4=awake` (same order, 1-indexed).
   Effect of the bug: deep sleep labeled "awake" (sleep short/fragmented, low
   efficiency, deep-heavy nights dropped by the all-awake guard), awake labeled "REM"
   (long awake runs looked all-REM and got flattened to all-light by the
   "pathological" repair — commits cb2b66c8, 9a12e33a, 10e150c0 were treating this
   symptom), REM labeled "deep".
2. **Tag `0x4B` (`sleep_phase_information`) was dropped** as a Tier-B "summary" instead
   of being decoded with the same 2-bit decoder as `0x4E`/`0x5A` (open_oura decodes all
   three identically).
3. **Session chaining was brittle**: `OuraSleepSessionMaterializer` split sessions on
   any gap ≠ exactly 300 s and dropped fragments < 20 min; near-duplicate epochs from
   history re-fetches (±1–2 s anchor jitter; dedupe key is exact ts) shattered nights
   into dropped shards.

## Already done (do not redo)

Swift:
- `Packages/OuraProtocol/Sources/OuraProtocol/OuraEvents.swift` — `OuraSleepStage`
  re-mapped to `deep=0, light=1, rem=2, awake=3` (+ comment).
- `Packages/OuraProtocol/Sources/OuraProtocol/EventTags.swift` — `sleepSummaryB (0x4B)`
  replaced by `sleepPhaseInfo = 0x4B`, Tier A, name `"SLEEP_PHASE_INFO"`.
- `Packages/OuraProtocol/Sources/OuraProtocol/OuraDriver.swift` — `0x4B` routed to
  `decodeSleepPhase`; removed from Tier-B summary case.
- `Packages/OuraProtocol/Sources/OuraProtocol/Decoders.swift` — doc comment corrected.
- `Packages/WhoopStore/Sources/WhoopStore/OuraSleepSessionMaterializer.swift`:
  - stage names 0=deep/1=light/2=rem/3=wake; asleep = phase != 3; has-asleep guard
    requires phase != 3; pathological thresholds keyed to phases 0/2 (deep/REM).
  - chaining rewritten: per-session 300 s slot grid; same-slot epochs deduped (first
    wins); splits only when slot gap > 12 epochs (60 min); smaller gaps stay in the
    session as stage-less holes; session start ts is never moved.
- `Packages/WhoopStore/Sources/WhoopStore/OuraStreamMapping.swift` — untouched:
  `sleepStateCode` switches on stage names so it is automatically correct; persisted
  `phase` payload = raw wire code, so no event-table migration needed.
- `Strand/BLE/OuraLiveSource.swift` — `OuraHistoryCursorStore.mappingRevision` 6 → 7
  (one-time replay to pick up previously dropped `0x4B` records).
- Tests updated: `Packages/OuraProtocol/Tests/OuraProtocolTests/DecoderGoldenTests.swift`
  (0x4E expectation now `[light, rem, awake, deep]` for byte 0x6C; new 0x4B golden
  test), `Packages/WhoopStore/Tests/WhoopStoreTests/OuraStreamMappingTests.swift`
  (payload ints 0/2/3; stage names; all-awake case uses phase 3; pathological all-REM
  uses phase 2; new tests `testOuraSleepMaterializerKeepsSmallHolesInsideSession` and
  `testOuraSleepMaterializerToleratesAnchorJitterDuplicates`).

Kotlin (parity twins):
- `android/app/src/main/java/com/noop/oura/OuraEvents.kt` — same enum re-map.
- `android/app/src/main/java/com/noop/oura/EventTags.kt` — `SLEEP_PHASE_INFO(0x4B)`,
  Tier A, name; removed `SLEEP_SUMMARY_B`.
- `android/app/src/main/java/com/noop/oura/OuraDriver.kt` — routes `SLEEP_PHASE_INFO`
  to `decodeSleepPhase`; Tier-B case no longer lists `SLEEP_SUMMARY_B`.
- `android/app/src/main/java/com/noop/oura/Decoders.kt` — doc comment corrected.
- Tests updated: `android/app/src/test/java/com/noop/oura/DecoderGoldenTest.kt`
  (0x4E expectation + new 0x4B test),
  `android/app/src/test/java/com/noop/data/OuraStreamMappingTest.kt`
  (phase payload ints now DEEP=0, REM=2).

Notes:
- Android has no cursor `mappingRevision` mechanism and no Oura sleep-session
  materializer (sessions are iOS-side in WhoopStore) — nothing to bump there.
- Docs also done: `docs/OURA_PROTOCOL.md` §6.12 (mapping corrected + `0x4B`
  reclassified as a phase record) and §7.3 trust-tier list (`0x4B/0x4E/0x5A` now Tier
  A, `0x4B` removed from Tier-B summaries); stale comments fixed in
  `Packages/WhoopStore/Sources/WhoopStore/OuraStreamMapping.swift` and
  `android/app/src/main/java/com/noop/data/OuraStreamMapping.kt`.

## Remaining steps

1. **Run tests — NOT POSSIBLE on this machine** (Linux, verified: no `swift`/`kotlinc`
   binaries, no Android SDK, `ANDROID_HOME` unset, `android/local.properties`
   missing). Run them where the toolchains live:
   - macOS: `swift test --package-path Packages/OuraProtocol` and
     `swift test --package-path Packages/WhoopStore`.
   - Android SDK machine: `cd android && ./gradlew :app:testFullDebugUnitTest --tests "com.noop.oura.*" --tests "com.noop.data.OuraStreamMappingTest"`
     (note: the app has Demo/Full flavors, plain `testDebugUnitTest` is ambiguous).
   - Fix any fallout; do not claim green unless actually run.
2. **Final sweep**: `grep -rn "0=awake\|sleepSummaryB\|SLEEP_SUMMARY_B" Packages/ android/ Strand/ docs/` should return only the "was wrong" correction notes; confirm.
3. **Sanity check the materializer edit** by re-reading
   `Packages/WhoopStore/Sources/WhoopStore/OuraSleepSessionMaterializer.swift`
   (`ouraSleepSessions(db:)`) — confirm per-session slot logic compiles
   (`sessionOrigin`/`lastSlot` types Int) and the `finishCurrent()` closure captures
   `current` by reference as before.
4. **Commit** only with the user's explicit approval (repo rule: no git mutations
   without asking).

## Manual validation (user, after build)

- Sync the Gen 3, then compare one night's stages/total time vs the Oura app.
- Expect: deep sleep present in first half of night; no all-light nights; previously
  flattened nights re-stage after the one-time history replay (mapping revision 7).

## Follow-ups (out of scope here; needs a real capture)

- Timestamp direction (forward vs backward walk from record ts) — no current evidence
  of error; if sessions land at odd times, capture a sync (`oura-decode` CLI in
  `Packages/OuraProtocol/Sources/oura-decode/`) and re-check.
- `0x4E/0x5A/0x4B` header-byte semantics / trailing padding (byte 6 may carry a
  valid-symbol count like `0x6B`'s). The pathological single-stage repair remains as
  the safety net.
