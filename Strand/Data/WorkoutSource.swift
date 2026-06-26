import Foundation
import WhoopStore
import StrandAnalytics   // WorkoutsTrace: the dedup-decision line formatter for the Workouts test mode

/// Origin of a workout row, classified from its stored `source` column. The macOS read model
/// (`WorkoutRow`) carries no `deviceId`, so the row's origin has to be recovered from `source`.
/// Stored values today:
///   - "whoop"        — WhoopImporter (imported WHOOP session)
///   - "apple_health" / "apple-health" — AppleHealthImport
///   - "manual"       — AppModel.endWorkout (v1.67 live session) AND the retro add/edit sheet
///   - "my-whoop-noop"— IntelligenceEngine detected bouts (source == the computed deviceId, i.e.
///                       it ends in "-noop"). These are re-derived every analyzeRecent run.
///
/// Classification order matters: "-noop" is checked BEFORE "whoop" because the computed id
/// "my-whoop-noop" also contains the substring "whoop".
enum WorkoutSource: Equatable {
    case whoop, apple, detected, manual, lifting, activityFile

    /// Canonical Apple Health source id written by new imports. The early rows used the underscore
    /// spelling, so reads must accept both — see `isAppleHealth`.
    static let appleHealthSource = "apple-health"
    private static let legacyAppleHealthSource = "apple_health"

    static func classify(_ source: String) -> WorkoutSource {
        let s = source.lowercased()
        if s.hasSuffix("-noop") { return .detected }   // BEFORE whoop: "my-whoop-noop" contains "whoop"
        if s == "manual" { return .manual }
        if s == "lifting" { return .lifting }          // imported Hevy / Liftosaur strength session
        if s == "activity-file" { return .activityFile } // imported GPX / TCX / FIT activity file
        if isAppleHealth(s) { return .apple }          // both spellings → Apple Health
        if s.contains("whoop") { return .whoop }
        return .apple
    }

    /// True for an Apple Health workout row regardless of which spelling it was stored under —
    /// the canonical `apple-health` or the legacy `apple_health`. Case-insensitive. Counts that
    /// filter Apple-logged workouts (Today, the Apple Health page) MUST go through this so existing
    /// underscore rows still tally.
    static func isAppleHealth(_ source: String) -> Bool {
        let s = source.lowercased()
        return s == appleHealthSource || s == legacyAppleHealthSource
    }

    /// Sport-cell text. The detector stores the machine token "detected"; show it as a neutral
    /// "Activity" (we don't claim a sport we didn't actually classify). WHOOP sport names arrive as
    /// concatenated camelCase (e.g. "TraditionalStrengthTraining"), which reads as one long
    /// unbreakable word and truncates badly — split it into words on the lower→Upper boundary so it
    /// renders "Traditional Strength Training". Already-spaced labels (manual/edited) pass through. (#175)
    static func displaySport(_ sport: String) -> String {
        if sport == "detected" { return "Activity" }
        if sport.isEmpty || sport.contains(" ") { return sport }
        var out = ""
        var prev: Character?
        for ch in sport {
            if let p = prev, ch.isUppercase, !p.isUppercase { out.append(" ") }
            out.append(ch)
            prev = ch
        }
        return out
    }

    // MARK: - Dismissed detected bouts (durable across re-detection)
    //
    // The engine wipes + re-derives "detected" rows every run, so deleting a detected row from the
    // table would only hide it until the next analyzeRecent recreates the same (startTs, sport) PK.
    // The durable "this isn't a workout" record is a list of dismissed time spans persisted in
    // UserDefaults (the macOS WorkoutRow lives in the WhoopStore Journal file, which this layer must
    // not extend with a new column). A detected row overlapping any dismissed span stays hidden.
    // (#107)

    /// UserDefaults key holding the dismissed spans as "startTs:endTs" strings.
    static let dismissedDefaultsKey = "workouts.dismissedDetected"

    /// Parse "startTs:endTs" spans (UserDefaults string array). Malformed / non-positive-width
    /// entries are dropped so a corrupt value can never hide everything.
    static func parseDismissedSpans(_ raw: [String]) -> [(start: Int, end: Int)] {
        raw.compactMap { s in
            let parts = s.split(separator: ":")
            guard parts.count == 2, let a = Int(parts[0]), let b = Int(parts[1]), b > a else { return nil }
            return (a, b)
        }
    }

    /// The "startTs:endTs" token persisted for a dismissed row (caller appends it to the defaults list).
    static func dismissedToken(for row: WorkoutRow) -> String { "\(row.startTs):\(row.endTs)" }

    /// Read-time filter: a DETECTED row overlapping any dismissed span is hidden. Imported / manual
    /// rows are never auto-hidden (the user deletes those outright), so dismissal only applies to the
    /// re-derived detected source. Half-open overlap test: `row.start < span.end && span.start < row.end`.
    static func isDismissed(_ row: WorkoutRow, spans: [(start: Int, end: Int)]) -> Bool {
        classify(row.source) == .detected
            && spans.contains { row.startTs < $0.end && $0.start < row.endTs }
    }

    // MARK: - Cross-source dedup (#687)
    //
    // The SAME activity can land twice: once live, Bluetooth-tracked under the strap (rich — real HR
    // trace, strain, zones, route), and once imported from Health Connect / Apple Health for the same
    // window (thin — usually just duration + calories). They sit under different deviceIds/sources, so
    // the workout list shows both as separate sessions. Collapse a pair that is clearly the same bout
    // (overlapping time window + same sport) to a single richer entry.
    //
    // Pure + deterministic so both platforms and the unit test share one rule. Run AFTER the dismissed
    // filter, BEFORE the final sort, on the combined multi-source list.

    /// Normalised sport key for cross-source matching. Folds the WHOOP camelCase token and a
    /// human-readable import label to the same key ("TraditionalStrengthTraining" and
    /// "Traditional Strength Training" → "traditionalstrengthtraining"), case- and space-insensitive,
    /// so the same activity matches across sources. "detected"/"Activity" both fold to "activity".
    static func sportKey(_ sport: String) -> String {
        displaySport(sport).lowercased().filter { !$0.isWhitespace }
    }

    /// How many "rich" captured signals a row carries — the tiebreak for which duplicate to keep.
    /// A live-tracked strap session scores high (HR trace, peak, strain, zones, distance); a thin
    /// import scores low. Energy is the most commonly-present import field so it is weighted lowest.
    static func richness(_ row: WorkoutRow) -> Int {
        var n = 0
        if row.avgHr != nil { n += 1 }
        if row.maxHr != nil { n += 1 }
        if row.strain != nil { n += 1 }
        if let z = row.zonesJSON, !z.isEmpty { n += 1 }
        if let d = row.distanceM, d > 0 { n += 1 }
        if let k = row.energyKcal, k > 0 { n += 1 }
        return n
    }

    /// True when two rows are the SAME activity from different sources: same normalised sport AND their
    /// time windows overlap by more than half of the shorter session. The >50%-of-shorter test (not bare
    /// touching) keeps two genuinely back-to-back same-sport sessions distinct while still catching the
    /// small start/end drift between a live capture and its import.
    static func sameActivity(_ a: WorkoutRow, _ b: WorkoutRow) -> Bool {
        guard sportKey(a.sport) == sportKey(b.sport) else { return false }
        let overlap = min(a.endTs, b.endTs) - max(a.startTs, b.startTs)
        guard overlap > 0 else { return false }
        let shorter = max(1, min(a.endTs - a.startTs, b.endTs - b.startTs))
        return Double(overlap) > 0.5 * Double(shorter)
    }

    /// Of two same-activity rows, the one to KEEP. Prefer the richer (more captured signals); on a tie
    /// prefer the strap-native source (live/manual/detected/whoop carry the real trace) over a thin
    /// import (Apple Health / Health Connect); final tie → the longer session, then `a` (stable).
    static func preferred(_ a: WorkoutRow, _ b: WorkoutRow) -> WorkoutRow {
        let ra = richness(a), rb = richness(b)
        if ra != rb { return ra > rb ? a : b }
        let ia = classify(a.source) == .apple, ib = classify(b.source) == .apple
        if ia != ib { return ia ? b : a }   // keep the non-import on a richness tie
        let da = a.endTs - a.startTs, db = b.endTs - b.startTs
        if da != db { return da > db ? a : b }
        return a
    }

    /// Collapse cross-source duplicates of the same activity, keeping the richer row of each pair.
    /// Order-stable: walks the input once, and a row that duplicates one already kept is dropped (with
    /// the kept row swapped for the richer of the two). Single-source lists pass through unchanged.
    static func dedupCrossSource(_ rows: [WorkoutRow]) -> [WorkoutRow] {
        var kept: [WorkoutRow] = []
        kept.reserveCapacity(rows.count)
        outer: for row in rows {
            for i in kept.indices where sameActivity(kept[i], row) {
                kept[i] = preferred(kept[i], row)
                continue outer
            }
            kept.append(row)
        }
        return kept
    }

    /// A short, source-only descriptor of a row for the Workouts test-mode dedup trace ("strap" / "apple" /
    /// "detected" / "manual" / "lifting" / "activityFile"). No timestamps or free text.
    static func sourceLabel(_ row: WorkoutRow) -> String {
        switch classify(row.source) {
        case .whoop:        return "strap"
        case .apple:        return "apple"
        case .detected:     return "detected"
        case .manual:       return "manual"
        case .lifting:      return "lifting"
        case .activityFile: return "activityFile"
        }
    }

    /// Diagnostic twin of `dedupCrossSource(...)` for the Workouts & GPS test mode: returns the BYTE-IDENTICAL
    /// kept list (the SAME walk, the SAME `preferred` choice) plus a trace line per collapsed pair naming the
    /// kept vs dropped source and their richness. The kept output equals `dedupCrossSource(...)` exactly, so
    /// the trace can never diverge from the list the screen shows. Only called when the mode is on.
    static func dedupCrossSourceTrace(_ rows: [WorkoutRow]) -> (kept: [WorkoutRow], trace: [String]) {
        var kept: [WorkoutRow] = []
        kept.reserveCapacity(rows.count)
        var lines: [String] = []
        outer: for row in rows {
            for i in kept.indices where sameActivity(kept[i], row) {
                let winner = preferred(kept[i], row)
                // The winner is one of the two; the other is the dropped one.
                let loser = (winner.startTs == kept[i].startTs && winner.source == kept[i].source) ? row : kept[i]
                lines.append(WorkoutsTrace.dedupLine(
                    sportKey: sportKey(row.sport),
                    keptSource: sourceLabel(winner), droppedSource: sourceLabel(loser),
                    keptRichness: richness(winner), droppedRichness: richness(loser)))
                kept[i] = winner
                continue outer
            }
            kept.append(row)
        }
        return (kept, lines)
    }

    // MARK: - Building / preserving rows

    /// Carry the captured fields the add/edit sheet does NOT expose (maxHr, strain, distanceM,
    /// zonesJSON, notes) over from the row being edited. A v1.67 live-tracked session has real
    /// captured strain/maxHr; rebuilding the row from the sheet's inputs alone would silently wipe
    /// them on an edit. No-op for a fresh add (`old == nil`).
    static func preservingCaptured(_ row: WorkoutRow, from old: WorkoutRow?) -> WorkoutRow {
        guard let old else { return row }
        return WorkoutRow(startTs: row.startTs, endTs: row.endTs, sport: row.sport,
                          source: row.source, durationS: row.durationS,
                          energyKcal: row.energyKcal, avgHr: row.avgHr,
                          maxHr: old.maxHr, strain: old.strain, distanceM: old.distanceM,
                          zonesJSON: old.zonesJSON, notes: old.notes)
    }

    /// Build a retroactive manual workout (source "manual", persisted under the strap deviceId by the
    /// caller — where v1.67's live sessions live). Returns nil when the input can't make an honest row.
    /// strain/zones stay nil: with no captured HR window an APPROXIMATE strain is never fabricated.
    static func buildManualRow(start: Date, durationMin: Int, sport: String,
                               avgHr: Int?, energyKcal: Double?, now: Date = Date()) -> WorkoutRow? {
        guard durationMin > 0, durationMin <= 24 * 60 else { return nil }
        let trimmed = sport.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty, start <= now else { return nil }
        if let hr = avgHr, !(25...250).contains(hr) { return nil }
        if let k = energyKcal, k < 0 || k > 20_000 { return nil }
        let s = Int(start.timeIntervalSince1970)
        guard s > 0 else { return nil }
        return WorkoutRow(startTs: s, endTs: s + durationMin * 60, sport: trimmed, source: "manual",
                          durationS: Double(durationMin) * 60, energyKcal: energyKcal,
                          avgHr: avgHr, maxHr: nil, strain: nil, distanceM: nil,
                          zonesJSON: nil, notes: nil)
    }
}
