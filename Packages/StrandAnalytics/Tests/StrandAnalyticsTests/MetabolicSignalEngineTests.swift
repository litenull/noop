import XCTest
@testable import StrandAnalytics

final class MetabolicSignalEngineTests: XCTestCase {

    // MARK: - Age norms

    func testDeepShareNormAnchorsAndInterpolation() {
        // Decade anchors (Dijk 2009 young ~19% → elderly ~9%).
        XCTAssertEqual(MetabolicSignalEngine.deepShareNorm(forAge: 20), 0.19, accuracy: 1e-9)
        XCTAssertEqual(MetabolicSignalEngine.deepShareNorm(forAge: 40), 0.15, accuracy: 1e-9)
        XCTAssertEqual(MetabolicSignalEngine.deepShareNorm(forAge: 80), 0.09, accuracy: 1e-9)
        // Clamp + mid-decade interpolation: 45 y → 0.15 + (0.135−0.15)·(5/10) = 0.1425.
        XCTAssertEqual(MetabolicSignalEngine.deepShareNorm(forAge: 45), 0.1425, accuracy: 1e-9)
        XCTAssertEqual(MetabolicSignalEngine.deepShareNorm(forAge: 15), 0.19, accuracy: 1e-9)
        XCTAssertEqual(MetabolicSignalEngine.deepShareNorm(forAge: 90), 0.09, accuracy: 1e-9)
    }

    // MARK: - Sub-scores

    func testRatioSubScoreBand() {
        XCTAssertEqual(MetabolicSignalEngine.ratioSubScore(ratio: 1.0), 100, accuracy: 1e-9)
        XCTAssertEqual(MetabolicSignalEngine.ratioSubScore(ratio: 1.5), 100, accuracy: 1e-9)
        XCTAssertEqual(MetabolicSignalEngine.ratioSubScore(ratio: 0.7), 50, accuracy: 1e-9)
        XCTAssertEqual(MetabolicSignalEngine.ratioSubScore(ratio: 0.4), 0, accuracy: 1e-9)
        XCTAssertEqual(MetabolicSignalEngine.ratioSubScore(ratio: 0.3), 0, accuracy: 1e-9)
    }

    func testDeepSleepSubScoreVsAgeNorm() {
        // At the age norm (40 y → 0.15) the ratio is 1.0 → full credit.
        XCTAssertEqual(MetabolicSignalEngine.deepSleepSubScore(deepSleepShare: 0.15, age: 40), 100, accuracy: 1e-9)
        // 0.10 share at 40: ratio 0.6667 → (0.6667−0.4)/0.6·100 = 44.444.
        XCTAssertEqual(MetabolicSignalEngine.deepSleepSubScore(deepSleepShare: 0.10, age: 40), 44.444, accuracy: 0.001)
        // Same 0.10 share at 60 (norm 0.12): ratio 0.8333 → 72.222 — the age adjustment credits
        // an older user for the same deep share, matching the SWS age decline.
        XCTAssertEqual(MetabolicSignalEngine.deepSleepSubScore(deepSleepShare: 0.10, age: 60), 72.222, accuracy: 0.001)
        // Severely suppressed (Tasali zone) → 0.
        XCTAssertEqual(MetabolicSignalEngine.deepSleepSubScore(deepSleepShare: 0.05, age: 40), 0, accuracy: 1e-9)
    }

    func testSleepDurationSubScore() {
        // Optimum band 7–9 h.
        XCTAssertEqual(MetabolicSignalEngine.sleepDurationSubScore(hours: 7.5), 100, accuracy: 1e-9)
        XCTAssertEqual(MetabolicSignalEngine.sleepDurationSubScore(hours: 9.0), 100, accuracy: 1e-9)
        // Short side steep-linear to the 4 h restriction zone: 5.5 h → 50, 6 h → 66.667.
        XCTAssertEqual(MetabolicSignalEngine.sleepDurationSubScore(hours: 5.5), 50, accuracy: 1e-9)
        XCTAssertEqual(MetabolicSignalEngine.sleepDurationSubScore(hours: 6.0), 66.667, accuracy: 0.001)
        XCTAssertEqual(MetabolicSignalEngine.sleepDurationSubScore(hours: 4.0), 0, accuracy: 1e-9)
        XCTAssertEqual(MetabolicSignalEngine.sleepDurationSubScore(hours: 3.0), 0, accuracy: 1e-9)
        // Long side gentle: 9.5 h → 91.667, floored at 50 from 12 h.
        XCTAssertEqual(MetabolicSignalEngine.sleepDurationSubScore(hours: 9.5), 91.667, accuracy: 0.001)
        XCTAssertEqual(MetabolicSignalEngine.sleepDurationSubScore(hours: 12.0), 50, accuracy: 1e-9)
        XCTAssertEqual(MetabolicSignalEngine.sleepDurationSubScore(hours: 14.0), 50, accuracy: 1e-9)
    }

    func testHRVSubScoreVsAgeNorm() {
        // 40 y RMSSD norm is 33 (VitalityEngine anchors): at norm → 100.
        XCTAssertEqual(MetabolicSignalEngine.hrvSubScore(rmssd: 33, age: 40), 100, accuracy: 1e-9)
        // Half-ish the norm (19.8): ratio 0.6 → 33.333.
        XCTAssertEqual(MetabolicSignalEngine.hrvSubScore(rmssd: 19.8, age: 40), 33.333, accuracy: 0.001)
        // Above norm clamps at 100.
        XCTAssertEqual(MetabolicSignalEngine.hrvSubScore(rmssd: 50, age: 30), 100, accuracy: 1e-9)
    }

    func testRestingHRSubScoreBand() {
        XCTAssertEqual(MetabolicSignalEngine.restingHRSubScore(restingHR: 45), 100, accuracy: 1e-9)
        XCTAssertEqual(MetabolicSignalEngine.restingHRSubScore(restingHR: 50), 100, accuracy: 1e-9)
        // 55 → 100 + 5·(−2) = 90.
        XCTAssertEqual(MetabolicSignalEngine.restingHRSubScore(restingHR: 55), 90, accuracy: 1e-9)
        // Reference 65 → 70.
        XCTAssertEqual(MetabolicSignalEngine.restingHRSubScore(restingHR: 65), 70, accuracy: 1e-9)
        // 78 → 70 − 13·(40/15) = 35.333.
        XCTAssertEqual(MetabolicSignalEngine.restingHRSubScore(restingHR: 78), 35.333, accuracy: 0.001)
        XCTAssertEqual(MetabolicSignalEngine.restingHRSubScore(restingHR: 80), 30, accuracy: 1e-9)
        // 85 → 30 − 5·3 = 15.
        XCTAssertEqual(MetabolicSignalEngine.restingHRSubScore(restingHR: 85), 15, accuracy: 1e-9)
        XCTAssertEqual(MetabolicSignalEngine.restingHRSubScore(restingHR: 95), 0, accuracy: 1e-9)
    }

    func testActivitySubScore() {
        XCTAssertEqual(MetabolicSignalEngine.activitySubScore(paIndex: 0), 0, accuracy: 1e-9)
        XCTAssertEqual(MetabolicSignalEngine.activitySubScore(paIndex: 2.5), 50, accuracy: 1e-9)
        // PA-index 5 = the HUNT "moderately active" reference peer → full credit, clamped above.
        XCTAssertEqual(MetabolicSignalEngine.activitySubScore(paIndex: 5), 100, accuracy: 1e-9)
        XCTAssertEqual(MetabolicSignalEngine.activitySubScore(paIndex: 10), 100, accuracy: 1e-9)
    }

    // MARK: - Compute (composite + gates)

    func testComputeInsulinFriendlyProfile() {
        // Age 40, all five factors at/near their favourable anchors.
        let r = MetabolicSignalEngine.compute(MetabolicSignalEngine.Inputs(
            age: 40, sleepHours: 7.5, deepSleepShare: 0.15, rmssd: 33, restingHR: 65, paIndex: 5))
        XCTAssertNotNil(r)
        // 0.30·100 + 0.25·100 + 0.20·100 + 0.15·70 + 0.10·100 = 95.5.
        XCTAssertEqual(r!.score, 95.5, accuracy: 1e-9)
        XCTAssertEqual(r!.level, .favorable)
        XCTAssertEqual(r!.factorsUsed, 5)
        XCTAssertEqual(r!.contributions.count, 5)
        // Full-weight run: every contribution weight equals its raw weight (sum 1).
        XCTAssertEqual(r!.contributions.reduce(0) { $0 + $1.weight }, 1.0, accuracy: 1e-9)
    }

    func testComputeStrainedProfile() {
        // Age 40: 5.5 h sleep, deep 0.10, RMSSD 19.8, RHR 78, PA 2.5.
        let r = MetabolicSignalEngine.compute(MetabolicSignalEngine.Inputs(
            age: 40, sleepHours: 5.5, deepSleepShare: 0.10, rmssd: 19.8, restingHR: 78, paIndex: 2.5))
        XCTAssertNotNil(r)
        // 0.30·44.444 + 0.25·50 + 0.20·33.333 + 0.15·35.333 + 0.10·50 = 42.8.
        XCTAssertEqual(r!.score, 42.8, accuracy: 0.001)
        XCTAssertEqual(r!.level, .steady)
    }

    func testComputeWatchProfile() {
        // Age 40: 4.5 h sleep, deep 0.05, RMSSD 10, RHR 85, PA 0.5.
        let r = MetabolicSignalEngine.compute(MetabolicSignalEngine.Inputs(
            age: 40, sleepHours: 4.5, deepSleepShare: 0.05, rmssd: 10, restingHR: 85, paIndex: 0.5))
        XCTAssertNotNil(r)
        // 0.25·16.667 + 0.15·15 + 0.10·10 = 4.167 + 2.25 + 1 = 7.417 (deep + HRV floored at 0).
        XCTAssertEqual(r!.score, 7.417, accuracy: 0.001)
        XCTAssertEqual(r!.level, .watch)
    }

    func testComputeRenormalisesWhenFactorsMissing() {
        // Three factors all at full credit → composite 100 even though only 0.75 of the weight is
        // present (deep 0.30 + duration 0.25 + HRV 0.20).
        let r = MetabolicSignalEngine.compute(MetabolicSignalEngine.Inputs(
            age: 40, sleepHours: 7.5, deepSleepShare: 0.15, rmssd: 33))
        XCTAssertNotNil(r)
        XCTAssertEqual(r!.score, 100, accuracy: 1e-9)
        XCTAssertEqual(r!.level, .favorable)
        XCTAssertEqual(r!.factorsUsed, 3)
        // Renormalised weights: deep 0.30/0.75 = 0.4.
        let deep = r!.contributions.first { $0.key == "deepSleep" }!
        XCTAssertEqual(deep.weight, 0.4, accuracy: 1e-9)
        // Same three factors mid-band: (0.30·44.444 + 0.25·50 + 0.20·33.333)/0.75 = 43.333.
        let r2 = MetabolicSignalEngine.compute(MetabolicSignalEngine.Inputs(
            age: 40, sleepHours: 5.5, deepSleepShare: 0.10, rmssd: 19.8))
        XCTAssertEqual(r2!.score, 43.333, accuracy: 0.001)
        XCTAssertEqual(r2!.level, .steady)
    }

    func testComputeGates() {
        // No age → the norms are unknowable → nil.
        XCTAssertNil(MetabolicSignalEngine.compute(MetabolicSignalEngine.Inputs(
            age: 0, sleepHours: 7.5, deepSleepShare: 0.15, rmssd: 33, restingHR: 65, paIndex: 5)))
        // Sleep duration is mandatory — a metabolic read with no sleep data would be dishonest.
        XCTAssertNil(MetabolicSignalEngine.compute(MetabolicSignalEngine.Inputs(
            age: 40, sleepHours: nil, deepSleepShare: 0.15, rmssd: 33, restingHR: 65, paIndex: 5)))
        XCTAssertNil(MetabolicSignalEngine.compute(MetabolicSignalEngine.Inputs(
            age: 40, sleepHours: 0, deepSleepShare: 0.15, rmssd: 33, restingHR: 65, paIndex: 5)))
        // Fewer than minFactors (3) → nil.
        XCTAssertNil(MetabolicSignalEngine.compute(MetabolicSignalEngine.Inputs(
            age: 40, sleepHours: 7.5, deepSleepShare: 0.15)))
        XCTAssertNil(MetabolicSignalEngine.compute(MetabolicSignalEngine.Inputs(age: 40, sleepHours: 7.5)))
    }

    func testComputeClampsAt100() {
        // Every factor over-credited input still caps at 100 (never > 100).
        let r = MetabolicSignalEngine.compute(MetabolicSignalEngine.Inputs(
            age: 40, sleepHours: 8.0, deepSleepShare: 0.30, rmssd: 60, restingHR: 45, paIndex: 15))
        XCTAssertNotNil(r)
        XCTAssertEqual(r!.score, 100, accuracy: 1e-9)
    }

    // MARK: - Readiness checklist

    func testReadinessAllPresentIsReady() {
        let r = MetabolicSignalEngine.assessReadiness(hasAge: true, sleepStageNights: 7,
                                                      hrvNights: 7, rhrNights: 7, activityDays: 7)
        XCTAssertEqual(r.confidence, .ready)
        XCTAssertTrue(r.canCompute)
        XCTAssertTrue(r.items.allSatisfy { $0.status == .satisfied })
        XCTAssertEqual(r.items.count, 5)
    }

    func testReadinessMissingAgeIsNotReady() {
        let r = MetabolicSignalEngine.assessReadiness(hasAge: false, sleepStageNights: 7,
                                                      hrvNights: 7, rhrNights: 7, activityDays: 7)
        XCTAssertEqual(r.confidence, .notReady)
        XCTAssertFalse(r.canCompute)
    }

    func testReadinessSparseSleepStagesIsNotReady() {
        let r = MetabolicSignalEngine.assessReadiness(hasAge: true, sleepStageNights: 3,
                                                      hrvNights: 7, rhrNights: 7, activityDays: 7)
        XCTAssertEqual(r.confidence, .notReady)
        XCTAssertEqual(r.items.first { $0.key == "sleepStages" }!.status, .partial)
    }

    func testReadinessNoAutonomicFactorIsNotReady() {
        // Sleep core fine but neither HRV nor RHR has enough nights → the ≥3-factor minimum is
        // unreachable → not ready.
        let r = MetabolicSignalEngine.assessReadiness(hasAge: true, sleepStageNights: 7,
                                                      hrvNights: 0, rhrNights: 2, activityDays: 7)
        XCTAssertEqual(r.confidence, .notReady)
    }

    func testReadinessPartialCoverageIsEstimate() {
        // Computes (age + sleep core + autonomic present) but activity is thin → estimate.
        let r = MetabolicSignalEngine.assessReadiness(hasAge: true, sleepStageNights: 6,
                                                      hrvNights: 4, rhrNights: 5, activityDays: 3)
        XCTAssertEqual(r.confidence, .estimate)
        XCTAssertTrue(r.canCompute)
        XCTAssertEqual(r.items.first { $0.key == "sleepStages" }!.status, .satisfied)
        XCTAssertEqual(r.items.first { $0.key == "activity" }!.status, .partial)
        // Required flags: only age + the sleep core are hard requirements.
        XCTAssertTrue(r.items.first { $0.key == "hrv" }!.notRequired)
        XCTAssertFalse(r.items.first { $0.key == "age" }!.notRequired)
        XCTAssertFalse(r.items.first { $0.key == "sleepStages" }!.notRequired)
    }
}

private extension MetabolicReadinessItem {
    /// Test-side negation so the assert reads naturally.
    var notRequired: Bool { !required }
}
