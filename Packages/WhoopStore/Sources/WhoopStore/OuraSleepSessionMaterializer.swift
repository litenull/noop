import Foundation
import GRDB
import WhoopProtocol

extension WhoopStore {
    /// Materialize Oura's open 5-minute sleep-phase hypnogram into the `sleepSession` cache rows that the
    /// Sleep screen reads. This uses only `OURA_SLEEP_PHASE` events decoded from the ring's open history; it
    /// never reads or infers Oura readiness/sleep scores.
    @discardableResult
    public func materializeOuraSleepSessions(deviceId: String) async throws -> Int {
        try syncWrite { db in
            let repaired = try Self.repairPathologicalOuraSleepSessions(db: db, deviceId: deviceId)
            let materialization = try Self.ouraSleepMaterialization(db: db, deviceId: deviceId)
            guard !materialization.epochs.isEmpty else { return repaired }

            let upserted = try Self.upsertSleepSessions(materialization.sessions, deviceId: deviceId, db: db)
            try Self.repairOuraSleepStates(materialization.epochs, deviceId: deviceId, db: db)
            return repaired + upserted
        }
    }

    private struct OuraPhaseEpoch {
        let ts: Int
        let phase: Int
    }

    private struct OuraSleepMaterialization {
        let epochs: [OuraPhaseEpoch]
        let sessions: [CachedSleepSession]
    }

    private struct OuraStageSegment: Encodable {
        var start: Int
        var end: Int
        var stage: String
    }

    private struct OuraDecodedStageSegment: Decodable {
        var start: Int
        var end: Int
        var stage: String
    }

    private static let ouraSleepPayloadDecoder = JSONDecoder()
    private static let ouraStageSegmentDecoder = JSONDecoder()
    private static let ouraMinimumSleepSessionSeconds = 20 * 60
    private static let ouraMinimumPathologicalRemOrDeepSessionSeconds = 30 * 60
    private static let ouraMinimumPathologicalLightSessionSeconds = 2 * 60 * 60
    private static let ouraPathologicalDominantStageFraction = 0.95
    /// Session split threshold in 5-min epochs (12 = 60 min). Smaller gaps stay inside the session as
    /// stage-less holes; bigger ones mark two separate sleeps.
    private static let ouraMaxSessionHoleEpochs = 12

    private static func repairPathologicalOuraSleepSessions(db: Database, deviceId: String) throws -> Int {
        let rows = try Row.fetchAll(db, sql: """
            SELECT startTs, endTs, stagesJSON FROM sleepSession
            WHERE deviceId = ? AND userEdited = 0 AND stagesJSON IS NOT NULL
            """, arguments: [deviceId])

        var repaired = 0
        for row in rows {
            let startTs: Int = row["startTs"]
            let endTs: Int = row["endTs"]
            let stagesJSON: String = row["stagesJSON"]
            guard isPathologicalSingleStageTimeline(stagesJSON) else { continue }
            let fallbackJSON = fallbackStageJSON(startTs: startTs, endTs: endTs)
            try db.execute(sql: """
                UPDATE sleepSession SET stagesJSON = ?
                WHERE deviceId = ? AND startTs = ? AND userEdited = 0
                """, arguments: [fallbackJSON, deviceId, startTs])
            repaired += db.changesCount
        }
        return repaired
    }

    private static func ouraSleepMaterialization(db: Database, deviceId: String) throws -> OuraSleepMaterialization {
        let rows = try Row.fetchAll(db, sql: """
            SELECT ts, payloadJSON FROM event
            WHERE deviceId = ? AND kind = ?
            ORDER BY ts ASC
            """, arguments: [deviceId, OuraStreamMapping.sleepPhaseEventKind])

        let epochs = rows.compactMap { row -> OuraPhaseEpoch? in
            let ts: Int = row["ts"]
            let payload: String = row["payloadJSON"]
            guard let phase = ouraSleepPhase(fromPayloadJSON: payload), (0...3).contains(phase) else {
                return nil
            }
            return OuraPhaseEpoch(ts: ts, phase: phase)
        }
        guard !epochs.isEmpty else {
            return OuraSleepMaterialization(epochs: [], sessions: [])
        }

        let epochSeconds = OuraStreamMapping.sleepPhaseEpochSeconds
        var sessions: [CachedSleepSession] = []
        var current: [OuraPhaseEpoch] = []

        func finishCurrent() {
            guard let session = ouraSession(from: current, epochSeconds: epochSeconds) else { return }
            sessions.append(session)
        }

        // Snap epochs onto a 5-min cadence anchored at each session's OWN first epoch. History
        // re-fetches (cursor reset, mapping-revision replay) re-anchor the SAME banked record to a ts a
        // few seconds off, so the raw stream holds near-duplicate epochs ±jitter; an exact-300s chain
        // shatters on every one of them and the <20-min shard filter then drops the whole night.
        // Slot-snapping collapses those duplicates (first wins) without moving the session's recorded
        // start: only cadence WITHIN a session is normalised, which is reconstruction of the ring's
        // 300s-epoch sequence, not a guess at new timestamps.
        var sessionOrigin = 0
        var lastSlot = 0
        for epoch in epochs {
            if current.isEmpty {
                sessionOrigin = epoch.ts
                lastSlot = 0
                current.append(epoch)
                continue
            }
            let slot = (epoch.ts - sessionOrigin + epochSeconds / 2) / epochSeconds
            if slot == lastSlot { continue }   // duplicate of the same epoch under a shifted anchor
            if slot - lastSlot > Self.ouraMaxSessionHoleEpochs {
                finishCurrent()
                current.removeAll(keepingCapacity: true)
                sessionOrigin = epoch.ts
                lastSlot = 0
                current.append(epoch)
                continue
            }
            current.append(OuraPhaseEpoch(ts: sessionOrigin + slot * epochSeconds, phase: epoch.phase))
            lastSlot = slot
        }
        finishCurrent()
        return OuraSleepMaterialization(epochs: epochs, sessions: sessions)
    }

    private static func repairOuraSleepStates(_ epochs: [OuraPhaseEpoch], deviceId: String,
                                              db: Database) throws {
        // sleepStateSample is derived from the stage enum, unlike the raw phase event. Correct rows
        // written under older mappings, including exact-timestamp conflicts that history replay keeps.
        let stateStatement = try db.cachedStatement(sql: """
            INSERT INTO sleepStateSample (deviceId, ts, state) VALUES (?, ?, ?)
            ON CONFLICT(deviceId, ts) DO UPDATE SET state = excluded.state
            WHERE sleepStateSample.state <> excluded.state
            """)
        for epoch in epochs {
            try stateStatement.execute(arguments: [deviceId, epoch.ts, epoch.phase == 3 ? 0 : 2])
        }
    }

    private static func ouraSleepPhase(fromPayloadJSON json: String) -> Int? {
        guard let data = json.data(using: .utf8),
              let payload = try? ouraSleepPayloadDecoder.decode([String: ParsedValue].self, from: data) else {
            return nil
        }
        return payload["phase"]?.intValue
    }

    private static func ouraSession(from epochs: [OuraPhaseEpoch], epochSeconds: Int) -> CachedSleepSession? {
        guard let first = epochs.first, let last = epochs.last else { return nil }
        let startTs = first.ts
        let endTs = last.ts + epochSeconds
        guard endTs - startTs >= ouraMinimumSleepSessionSeconds else { return nil }
        guard epochs.contains(where: { $0.phase != 3 }) else { return nil }   // need some asleep epoch (3 = awake)

        var segments: [OuraStageSegment] = []
        var asleepSeconds = 0
        var stageCounts: [Int: Int] = [:]
        for epoch in epochs {
            let stage = ouraStageName(phase: epoch.phase)
            if epoch.phase != 3 {   // 3 = awake; deep(0)/light(1)/rem(2) are asleep
                asleepSeconds += epochSeconds
                stageCounts[epoch.phase, default: 0] += 1
            }
            if var lastSegment = segments.last, lastSegment.stage == stage, lastSegment.end == epoch.ts {
                lastSegment.end = epoch.ts + epochSeconds
                segments[segments.count - 1] = lastSegment
            } else {
                segments.append(OuraStageSegment(start: epoch.ts, end: epoch.ts + epochSeconds, stage: stage))
            }
        }
        // All-REM/deep Oura BLE runs are decoder/padding failures; keep duration, drop fake stages.
        let json = isPathologicalSingleStageSleep(stageCounts: stageCounts, asleepSeconds: asleepSeconds)
            ? fallbackStageJSON(startTs: startTs, endTs: endTs)
            : encodeOuraSegments(segments)
        let efficiency = min(100, Double(asleepSeconds) / Double(max(1, endTs - startTs)) * 100)
        return CachedSleepSession(startTs: startTs, endTs: endTs, efficiency: efficiency,
                                  restingHr: nil, avgHrv: nil, stagesJSON: json)
    }

    /// Stage names for the 2-bit wire codes: 0=deep, 1=light, 2=rem, 3=wake (per the native
    /// `SleepPhase_OSSAv1` enum / cloud-API hypnogram order; see OuraSleepStage).
    private static func ouraStageName(phase: Int) -> String {
        switch phase {
        case 0: return "deep"
        case 1: return "light"
        case 2: return "rem"
        case 3: return "wake"
        default: return "wake"
        }
    }

    private static func isPathologicalSingleStageSleep(stageCounts: [Int: Int], asleepSeconds: Int) -> Bool {
        let total = stageCounts.values.reduce(0, +)
        guard total > 0,
              let dominantEntry = stageCounts.max(by: { $0.value < $1.value }) else { return false }
        guard asleepSeconds >= pathologicalMinimumSeconds(forPhase: dominantEntry.key) else { return false }
        let dominant = dominantEntry.value
        return Double(dominant) / Double(total) >= ouraPathologicalDominantStageFraction
    }

    private static func isPathologicalSingleStageTimeline(_ json: String) -> Bool {
        guard let data = json.data(using: .utf8),
              let segments = try? ouraStageSegmentDecoder.decode([OuraDecodedStageSegment].self, from: data) else {
            return false
        }

        var stageSeconds: [String: Int] = [:]
        var asleepSeconds = 0
        for segment in segments {
            let seconds = max(0, segment.end - segment.start)
            guard seconds > 0 else { continue }
            switch segment.stage {
            case "wake", "awake":
                continue
            case "light", "deep", "rem":
                asleepSeconds += seconds
                stageSeconds[segment.stage, default: 0] += seconds
            default:
                continue
            }
        }
        guard let dominantEntry = stageSeconds.max(by: { $0.value < $1.value }) else { return false }
        guard asleepSeconds >= pathologicalMinimumSeconds(forStage: dominantEntry.key) else { return false }
        let dominant = dominantEntry.value
        return Double(dominant) / Double(asleepSeconds) >= ouraPathologicalDominantStageFraction
    }

    private static func pathologicalMinimumSeconds(forPhase phase: Int) -> Int {
        switch phase {
        case 0, 2: return ouraMinimumPathologicalRemOrDeepSessionSeconds   // deep / REM
        default: return ouraMinimumPathologicalLightSessionSeconds
        }
    }

    private static func pathologicalMinimumSeconds(forStage stage: String) -> Int {
        switch stage {
        case "deep", "rem": return ouraMinimumPathologicalRemOrDeepSessionSeconds
        default: return ouraMinimumPathologicalLightSessionSeconds
        }
    }

    private static func encodeOuraSegments(_ segments: [OuraStageSegment]) -> String? {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        guard let data = try? encoder.encode(segments) else { return nil }
        return String(decoding: data, as: UTF8.self)
    }

    private static func fallbackStageJSON(startTs: Int, endTs: Int) -> String {
        let lightMin = max(0, Double(endTs - startTs) / 60.0)
        let stages: [String: Double] = ["awake": 0, "light": lightMin, "deep": 0, "rem": 0]
        guard let data = try? JSONSerialization.data(withJSONObject: stages, options: [.sortedKeys]) else {
            return "{\"awake\":0,\"deep\":0,\"light\":\(lightMin),\"rem\":0}"
        }
        return String(decoding: data, as: UTF8.self)
    }
}
