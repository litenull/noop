import Foundation
import GRDB
import WhoopProtocol

extension WhoopStore {
    /// Materialize Oura's open 5-minute sleep-phase hypnogram into the `sleepSession` cache rows that the
    /// Sleep screen reads. This uses only `OURA_SLEEP_PHASE` events decoded from the ring's open history; it
    /// never reads or infers Oura readiness/sleep scores.
    @discardableResult
    public func materializeOuraSleepSessions(deviceId: String) async throws -> Int {
        let repaired = try repairPathologicalOuraSleepSessions(deviceId: deviceId)
        let sessions = try syncRead { db in
            try Self.ouraSleepSessions(db: db, deviceId: deviceId)
        }
        guard !sessions.isEmpty else { return repaired }
        return repaired + (try await upsertSleepSessions(sessions, deviceId: deviceId))
    }

    private struct OuraPhaseEpoch {
        let ts: Int
        let phase: Int
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
    private static let ouraMinimumPathologicalSessionSeconds = 2 * 60 * 60
    private static let ouraPathologicalDominantStageFraction = 0.95

    private func repairPathologicalOuraSleepSessions(deviceId: String) throws -> Int {
        try syncWrite { db in
            let rows = try Row.fetchAll(db, sql: """
                SELECT startTs, stagesJSON FROM sleepSession
                WHERE deviceId = ? AND userEdited = 0 AND stagesJSON IS NOT NULL
                """, arguments: [deviceId])

            var repaired = 0
            for row in rows {
                let startTs: Int = row["startTs"]
                let stagesJSON: String = row["stagesJSON"]
                guard Self.isPathologicalSingleStageTimeline(stagesJSON) else { continue }
                try db.execute(sql: """
                    UPDATE sleepSession SET stagesJSON = NULL
                    WHERE deviceId = ? AND startTs = ? AND userEdited = 0
                    """, arguments: [deviceId, startTs])
                repaired += db.changesCount
            }
            return repaired
        }
    }

    private static func ouraSleepSessions(db: Database, deviceId: String) throws -> [CachedSleepSession] {
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
        guard !epochs.isEmpty else { return [] }

        let epochSeconds = OuraStreamMapping.sleepPhaseEpochSeconds
        var sessions: [CachedSleepSession] = []
        var current: [OuraPhaseEpoch] = []

        func finishCurrent() {
            guard let session = ouraSession(from: current, epochSeconds: epochSeconds) else { return }
            sessions.append(session)
        }

        for epoch in epochs {
            if let last = current.last, epoch.ts - last.ts != epochSeconds {
                finishCurrent()
                current.removeAll(keepingCapacity: true)
            }
            current.append(epoch)
        }
        finishCurrent()
        return sessions
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
        guard epochs.contains(where: { $0.phase != 0 }) else { return nil }

        var segments: [OuraStageSegment] = []
        var asleepSeconds = 0
        var stageCounts: [Int: Int] = [:]
        for epoch in epochs {
            let stage = ouraStageName(phase: epoch.phase)
            if epoch.phase != 0 {
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
        // Long all-one-stage Oura BLE runs are decoder/padding failures; keep bounds, drop fake stages.
        let json = isPathologicalSingleStageSleep(stageCounts: stageCounts, asleepSeconds: asleepSeconds)
            ? nil
            : encodeOuraSegments(segments)
        let efficiency = min(100, Double(asleepSeconds) / Double(max(1, endTs - startTs)) * 100)
        return CachedSleepSession(startTs: startTs, endTs: endTs, efficiency: efficiency,
                                  restingHr: nil, avgHrv: nil, stagesJSON: json)
    }

    private static func ouraStageName(phase: Int) -> String {
        switch phase {
        case 0: return "wake"
        case 1: return "light"
        case 2: return "deep"
        case 3: return "rem"
        default: return "wake"
        }
    }

    private static func isPathologicalSingleStageSleep(stageCounts: [Int: Int], asleepSeconds: Int) -> Bool {
        guard asleepSeconds >= ouraMinimumPathologicalSessionSeconds else { return false }
        let total = stageCounts.values.reduce(0, +)
        guard total > 0, let dominant = stageCounts.values.max() else { return false }
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
        guard asleepSeconds >= ouraMinimumPathologicalSessionSeconds,
              let dominant = stageSeconds.values.max() else { return false }
        return Double(dominant) / Double(asleepSeconds) >= ouraPathologicalDominantStageFraction
    }

    private static func encodeOuraSegments(_ segments: [OuraStageSegment]) -> String? {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        guard let data = try? encoder.encode(segments) else { return nil }
        return String(decoding: data, as: UTF8.self)
    }
}
