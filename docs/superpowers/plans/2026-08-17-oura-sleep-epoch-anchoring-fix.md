# Oura sleep epoch-anchoring fix — handoff plan

Status: **implementation complete, tests not yet run** (Linux box: no Swift/Kotlin toolchains —
same situation as the 2026-07-17 fix handoff). Only verification remains.

## Diagnosis (why)

User report (2026-08-17): "the Oura ring integration is a bit buggy, especially the sleep
feature — it doesn't record it correctly," a month after the Gen 3 stage-mapping fix
(commit c72b44bb / plan 2026-07-17). That plan's own **Follow-ups (out of scope; needs a real
capture)** section listed exactly the assumption this fix corrects: *"Timestamp direction
(forward vs backward walk from record ts) — no current evidence of error."*

**Root cause: the sleep-phase epoch walk ran FORWARD from the record time, contradicting every
documented batched-event convention in the protocol.** Three independent lines of evidence all
say a record's event time anchors its LAST sample, with earlier samples stepping backward:

1. **NOOP's own spec** (docs/OURA_PROTOCOL.md, sourced from [ringverse], the Tier-A-verified
   dictionary): s6.1 IBI — "Per-sample timestamp: walk backward from event UTC"; s6.8 0x75
   sleep-temp — "timestamps walk backward from event UTC"; s6.9 0x5D HRV — "timestamps walk
   backward from event UTC". The sleep-phase mapping (`ts + index·300`) was the odd one out.
2. **The decompiled native parser** (Oura's own `libringeventparser.so`, documented in
   open_oura's `docs/native-decoder.md`): "Batched events carry N samples sharing one event
   time; the first sample is `utc_time_ms − (n−1)×interval`, stepping by interval" — verified
   there for five batched families (HRV/ambient 5 min, sleep-temp 30 s, meas-quality 3 min,
   SpO2 1 s, AOHR 1920 ms). Sleep-phase records are structurally the same batched family.
3. NOOP's shipped symptom profile is consistent: nights internally coherent but mis-timed
   against the clock — every record's epochs placed (n−1)·5 min too late (a 19 B record = 72
   epochs ≈ 6 h late), fragmenting/mis-dating sessions at day boundaries.

Secondary same-class defect fixed alongside: **0x75 sleep-temp batches** decoded N samples but
persisted them ALL at the record (end) time — now spread backward at their verified 30 s
spacing. The 0x46 temp_event batch cadence remains UNVERIFIED (interval unknown), so its
samples deliberately stay at the record time (no guessed placement — honest-data invariant).

## What changed (do not redo)

Swift:
- `Packages/OuraProtocol/Sources/OuraProtocol/OuraEvents.swift` — `OuraSleepPhase` gains
  `countInRecord` (explicit, no default — construction sites must acknowledge the batch);
  `OuraTemp` gains `index`/`countInRecord`/`sampleIntervalSeconds` (defaults keep single-sample
  and unverified-batch decoders unchanged).
- `Packages/OuraProtocol/Sources/OuraProtocol/Decoders.swift` — `decodeSleepPhase` fills
  `countInRecord`; `decodeSleepTemp` fills batch position + verified 30 s spacing.
- `Packages/WhoopStore/Sources/WhoopStore/OuraStreamMapping.swift` — sleep-phase epochs now
  `ts − (count−1−index)·300` (backward); sleep-temp batches spread backward when the interval
  is verified, stay at record ts otherwise. Event payloads unchanged (raw wire facts only), so
  no event-table migration is needed.
- `Strand/BLE/OuraLiveSource.swift` — `OuraHistoryCursorStore.mappingRevision` 7 → 8: one-time
  history replay so still-banked phase/temp records re-decode under the corrected placement;
  re-materialization rewrites the affected sleep sessions.
- Tests: `DecoderGoldenTests` (phase goldens carry countInRecord; NEW 0x75 batch golden),
  `OuraDriverTests` (countInRecord on the 0x4B ingest golden),
  `OuraStreamMappingTests` (phase placement now backward: ts−600/ts−300/ts; NEW single-phase
  anchor test; NEW payload wire-facts pin; NEW sleep-temp backward-spread + unspaced-batch
  tests). The materializer tests hand-place event ts values and remain valid unchanged.

Kotlin parity twins:
- `OuraEvents.kt` (struct fields), `Decoders.kt` (batch fill), `OuraStreamMapping.kt`
  (backward placement, both streams), `DecoderGoldenTest.kt` / `OuraDriverTest.kt` /
  `OuraStreamMappingTest.kt` updated + new tests mirroring the Swift ones.

Docs:
- `docs/OURA_PROTOCOL.md` §6.12 — EPOCH PLACEMENT note (backward anchoring, evidence, formula).

## Not touched (deliberately)

- `OuraSleepSessionMaterializer` — placement-agnostic (it slot-snaps whatever epochs arrive);
  its tests hand-place ts and stay green.
- Stage code mapping (0=deep…) — verified by three sources; unchanged.
- The header-byte semantics question (possible valid-code count / trailing padding) — still
  open, still needs a real capture; the pathological single-stage repair remains the net.
- `0x76 bedtime_period` (verified sleep window per open_oura's real-bytes capture) — the
  stronger long-term fix (pin session boundaries to the ring's own window) remains a follow-up.

## Remaining steps

1. **Run tests where the toolchains live** (NOT possible on this machine):
   - macOS: `swift test --package-path Packages/OuraProtocol` and
     `swift test --package-path Packages/WhoopStore`.
   - Android: `cd android && ./gradlew :app:testFullDebugUnitTest --tests "com.noop.oura.*" --tests "com.noop.data.OuraStreamMappingTest"`.
   - Fix fallout; do not claim green unless actually run.
2. **Manual validation** (user, after build): connect the Gen 3, let the revision-8 replay
   re-bank history, then compare one night's bedtime/wake time and stage timeline against the
   Oura app. Expect sessions to now sit at their true clock times (they previously ran late by
   up to (n−1)·5 min per record).
3. **If a session STILL lands late** after this fix: capture one sync
   (`Packages/OuraProtocol/Sources/oura-decode/`) and check the 0x4B/0x4E record cadence —
   that capture also resolves the header-byte question.

## Commit rule

Commit only with the user's explicit approval (repo rule).
