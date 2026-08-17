import Foundation

// MetabolicSignalEngine.swift — a transparent 0–100 "Metabolic Signal" composite of how
// insulin-friendly the user's recovery patterns look. Pure, deterministic, DB-free.
//
// WHAT THIS IS NOT (read first): the engine does NOT measure insulin resistance. That requires
// fasting labs (HOMA-IR) or an OGTT — no wearable can do it. Like IllnessSignalEngine, it never
// names a condition; the surface copy is "how insulin-friendly your patterns look". What it does
// is re-derive, transparently and on-device, the five wearable-measurable behaviours/physiology
// the insulin-sensitivity literature keeps pointing at, each scored against published anchors:
//
//   • DEEP SLEEP (SWS) share of total sleep — the strongest causal wearable signal: 3 nights of
//     selective SWS suppression (total sleep unchanged) cut insulin sensitivity ~25% in healthy
//     adults (Tasali et al. 2008, PNAS 105(3):1044-1049). Normative SWS share ~13-23% of total
//     sleep in young adults, declining with age (Dijk 2009, PMC2824213).
//   • SLEEP DURATION — sleep restricted to 4-5 h/night for under 2 weeks reduced insulin
//     sensitivity ~25-40% in healthy adults (Spiegel et al. 1999, Lancet 354:1435-1439;
//     replicated by Buxton et al. 2010, Sci Transl Med). Optimum band 7-9 h, U-shaped penalty.
//   • NOCTURNAL HRV (RMSSD) vs the AGE NORM — lower RMSSD tracks higher HOMA-IR (Saito et al.
//     2015, Toon Health Study, PMID 26277879). Age norms reuse VitalityEngine.rmssdNorm.
//   • RESTING HR — elevated RHR tracks higher fasting insulin independent of other factors
//     (ARIC cohort; also Schroeder et al. 2005, Diabetes Care). Reference 65 bpm (house norm).
//   • ACTIVITY (HUNT PA-index) — exercise improves insulin sensitivity acutely and chronically;
//     the reference peer (PA-index 5, "moderately active") is the same anchor Fitness Age uses.
//
// Weights favour the causal sleep evidence (deep + duration = 0.55) over the observational
// autonomic correlates (HRV + RHR = 0.35) and the coarsest protective factor (activity = 0.10).
// Missing signals are skipped and the weights renormalised (≥ 3 factors required, sleep duration
// mandatory — a Metabolic Signal with no sleep data would be dishonest).
//
// WELLNESS ONLY — APPROXIMATE, NOT A DIAGNOSIS. The score is a pattern readout over a rolling
// 7-day window (the caller passes medians), never a medical measurement, and says nothing about
// diabetes, prediabetes or any condition.
public enum MetabolicSignalEngine {

    // MARK: - Tuning constants (pinned by test)

    /// Signal weights (sum 1.0): deep sleep 0.30, duration 0.25, HRV 0.20, RHR 0.15, activity 0.10.
    public static let weightDeepSleep = 0.30, weightSleepDuration = 0.25
    public static let weightHRV = 0.20, weightRestingHR = 0.15, weightActivity = 0.10

    /// Minimum distinct factors (of the five) before a score is produced. Below this → nil.
    public static let minFactors = 3

    /// Level thresholds on the 0–100 composite: ≥ favorableThreshold reads favorable,
    /// < watchThreshold reads watch, in between steady.
    public static let favorableThreshold = 65.0
    public static let watchThreshold = 40.0

    // Sleep-duration band: 7–9 h is the optimum (National Sleep Foundation); below it the penalty
    // is steep and linear to 4 h (the Spiegel/Buxton restriction zone); above it a gentle linear
    // decline to a 50 floor at 12 h (long-sleep harm is real but heavily confounded — never 0).
    public static let sleepOptimumLow = 7.0, sleepOptimumHigh = 9.0
    public static let sleepShortFloor = 4.0                       // hours; sub-score 0 at/below
    public static let sleepLongFloorScore = 50.0, sleepLongZeroAt = 12.0

    // Ratio-band sub-scores (deep sleep, HRV): ratio = value / age-norm. Full credit at ratio 1.0
    // (at/above your age norm), 0 at ratio 0.4, linear between. The 0.4 floor keeps a bad-but-not-
    // pathological week from zeroing out; the linear slope makes the "half your norm" case score 33.
    public static let ratioFull = 1.0, ratioFloor = 0.4

    /// Resting-HR band: 100 at ≤ 50 (athlete floor — no over-credit for bradycardia), 70 at the 65
    /// reference, 30 at 80, 0 at ≥ 90. Piecewise-linear between (ARIC gradient, deliberately gentle
    /// below 65 where the evidence is thin, steeper above).
    public static let rhrAthleteFloor = 50.0, rhrReference = 65.0
    public static let rhrReferenceScore = 70.0, rhrHighPoint = 80.0, rhrHighScore = 30.0
    public static let rhrZeroAt = 90.0

    /// Activity: full credit at PA-index ≥ 5 (the HUNT "moderately active" reference peer — the
    /// same anchor Fitness Age's paiReference uses), linear from 0.
    public static let activityFullAt = 5.0

    /// Normative deep-sleep (SWS) share of total sleep by age, piecewise-linear between decade
    /// anchors (young adults ~18-20% of total sleep, declining to ~9-10% in the elderly — Dijk
    /// 2009 PMC2824213; the 13-23% "healthy adult" band sits inside these anchors at its young end).
    public static func deepShareNorm(forAge age: Double) -> Double {
        let anchors: [(Double, Double)] = [(20, 0.19), (30, 0.17), (40, 0.15), (50, 0.135),
                                           (60, 0.12), (70, 0.105), (80, 0.09)]
        if age <= anchors[0].0 { return anchors[0].1 }
        if age >= anchors[anchors.count - 1].0 { return anchors[anchors.count - 1].1 }
        for i in 1..<anchors.count where age <= anchors[i].0 {
            let (a0, v0) = anchors[i - 1]; let (a1, v1) = anchors[i]
            return v0 + (v1 - v0) * (age - a0) / (a1 - a0)
        }
        return anchors[anchors.count - 1].1
    }

    // MARK: - Inputs

    /// Rolling-window aggregates (the orchestrator passes 7-day MEDIANS so one bad night can't
    /// swing the daily-stamped score). All factors but `age` are optional and skipped when absent.
    public struct Inputs: Equatable, Sendable {
        public var age: Double
        public var sleepHours: Double?        // median nightly total sleep (h)
        public var deepSleepShare: Double?    // median deep minutes / total sleep minutes (0–1)
        public var rmssd: Double?             // median nocturnal RMSSD (ms)
        public var restingHR: Double?         // median resting HR (bpm)
        public var paIndex: Double?           // HUNT PA-index 0–15 (reuse FitnessAgeEngine's)
        public init(age: Double, sleepHours: Double? = nil, deepSleepShare: Double? = nil,
                    rmssd: Double? = nil, restingHR: Double? = nil, paIndex: Double? = nil) {
            self.age = age; self.sleepHours = sleepHours; self.deepSleepShare = deepSleepShare
            self.rmssd = rmssd; self.restingHR = restingHR; self.paIndex = paIndex
        }
    }

    // MARK: - Output

    public enum Level: String, Equatable, Sendable, Codable {
        case favorable   // patterns look insulin-friendly
        case steady      // mixed — nothing alarming, room to improve
        case watch       // several signals in the unfavourable zone — worth attention
    }

    /// One factor's contribution: the engine exposes keys (never rendered labels — the caller
    /// localises, mirroring IllnessSignalEngine's firedLabels contract).
    public struct Contribution: Equatable, Sendable {
        public let key: String          // "deepSleep" | "sleepDuration" | "hrv" | "restingHR" | "activity"
        public let subScore: Double     // 0–100
        public let weight: Double       // effective (renormalised) weight
        public init(key: String, subScore: Double, weight: Double) {
            self.key = key; self.subScore = subScore; self.weight = weight
        }
    }

    public struct Result: Equatable, Sendable {
        public let score: Double                  // 0–100 composite
        public let level: Level
        public let contributions: [Contribution]  // for the "what's driving this" breakdown
        public let factorsUsed: Int
        public init(score: Double, level: Level, contributions: [Contribution], factorsUsed: Int) {
            self.score = score; self.level = level
            self.contributions = contributions; self.factorsUsed = factorsUsed
        }
    }

    /// Standing not-a-diagnosis tail (same shipped framing as IllnessSignalEngine).
    public static let disclaimerTail = "On-device estimate - not a diagnosis."

    /// Map a composite score onto its level. Public so a caller holding only the STORED score (e.g.
    /// the Health section reading metricSeries) renders the same level the engine produced.
    public static func level(forScore score: Double) -> Level {
        score >= favorableThreshold ? .favorable : (score < watchThreshold ? .watch : .steady)
    }

    // MARK: - Sub-scores (each exposed so tests and the UI can pin/explain them)

    private static func clamp01(_ v: Double) -> Double { min(100, max(0, v)) }

    /// Ratio-band sub-score shared by deep sleep and HRV: full at ratio ≥ ratioFull, 0 at ≤ ratioFloor.
    public static func ratioSubScore(ratio: Double) -> Double {
        clamp01((ratio - ratioFloor) / (ratioFull - ratioFloor) * 100)
    }

    /// Deep-sleep (SWS) share of total sleep vs the age norm. Tasali 2008.
    public static func deepSleepSubScore(deepSleepShare: Double, age: Double) -> Double {
        guard deepSleepShare > 0 else { return 0 }
        return ratioSubScore(ratio: deepSleepShare / deepShareNorm(forAge: age))
    }

    /// Sleep duration vs the 7–9 h optimum: steep below (Spiegel/Buxton), gentle above.
    public static func sleepDurationSubScore(hours: Double) -> Double {
        guard hours > 0 else { return 0 }
        if hours < sleepOptimumLow {
            return clamp01((hours - sleepShortFloor) / (sleepOptimumLow - sleepShortFloor) * 100)
        }
        if hours <= sleepOptimumHigh { return 100 }
        // Long side: linear 100 → 50 between 9 h and 12 h, floored at 50 (confounded evidence).
        let slope = (sleepLongFloorScore - 100) / (sleepLongZeroAt - sleepOptimumHigh)
        return max(sleepLongFloorScore, 100 + (hours - sleepOptimumHigh) * slope)
    }

    /// Nocturnal RMSSD vs the age norm (VitalityEngine.rmssdNorm). Saito 2015.
    public static func hrvSubScore(rmssd: Double, age: Double) -> Double {
        guard rmssd > 0 else { return 0 }
        let norm = VitalityEngine.rmssdNorm(forAge: age)
        guard norm > 0 else { return 0 }
        return ratioSubScore(ratio: rmssd / norm)
    }

    /// Resting HR vs the 65 reference (piecewise: 100@50, 70@65, 30@80, 0@90). ARIC.
    public static func restingHRSubScore(restingHR: Double) -> Double {
        guard restingHR > 0 else { return 0 }
        if restingHR <= rhrAthleteFloor { return 100 }
        if restingHR <= rhrReference {
            let slope = (rhrReferenceScore - 100) / (rhrReference - rhrAthleteFloor)
            return 100 + (restingHR - rhrAthleteFloor) * slope
        }
        if restingHR <= rhrHighPoint {
            let slope = (rhrHighScore - rhrReferenceScore) / (rhrHighPoint - rhrReference)
            return rhrReferenceScore + (restingHR - rhrReference) * slope
        }
        if restingHR <= rhrZeroAt {
            let slope = (0 - rhrHighScore) / (rhrZeroAt - rhrHighPoint)
            return rhrHighScore + (restingHR - rhrHighPoint) * slope
        }
        return 0
    }

    /// HUNT PA-index vs the reference peer (5 = full credit). Linear from 0.
    public static func activitySubScore(paIndex: Double) -> Double {
        guard paIndex > 0 else { return 0 }
        guard activityFullAt > 0 else { return 100 }
        return clamp01(paIndex / activityFullAt * 100)
    }

    // MARK: - Compute

    /// Composite Metabolic Signal. Returns nil (honesty gate) when age is unknown, sleep duration
    /// is absent (the score would be mostly fabrication), or fewer than `minFactors` factors are
    /// present. Weights renormalise over the present factors.
    public static func compute(_ inputs: Inputs) -> Result? {
        guard inputs.age > 0, let hours = inputs.sleepHours, hours > 0 else { return nil }

        var factors: [(key: String, sub: Double, weight: Double)] = []
        if let share = inputs.deepSleepShare, share > 0 {
            factors.append(("deepSleep", deepSleepSubScore(deepSleepShare: share, age: inputs.age), weightDeepSleep))
        }
        factors.append(("sleepDuration", sleepDurationSubScore(hours: hours), weightSleepDuration))
        if let hrv = inputs.rmssd, hrv > 0 {
            factors.append(("hrv", hrvSubScore(rmssd: hrv, age: inputs.age), weightHRV))
        }
        if let rhr = inputs.restingHR, rhr > 0 {
            factors.append(("restingHR", restingHRSubScore(restingHR: rhr), weightRestingHR))
        }
        if let pai = inputs.paIndex, pai > 0 {
            factors.append(("activity", activitySubScore(paIndex: pai), weightActivity))
        }
        guard factors.count >= minFactors else { return nil }

        let weightSum = factors.reduce(0) { $0 + $1.weight }
        guard weightSum > 0 else { return nil }
        let score = clamp01(factors.reduce(0) { $0 + $1.sub * $1.weight } / weightSum)
        let contributions = factors.map {
            Contribution(key: $0.key, subScore: $0.sub, weight: $0.weight / weightSum)
        }
        return Result(score: score, level: level(forScore: score),
                      contributions: contributions, factorsUsed: factors.count)
    }
}

// MARK: - Readiness checklist
//
// Transparency over a black-box number (FitnessAgeEngine idiom): show which inputs we have and a
// single confidence verdict. Sleep+stages is the required core (two of the five factors live there);
// HRV/RHR/activity deepen the read but never block it as long as the factor minimum is met.

public enum MetabolicReadinessStatus: String, Sendable { case satisfied, partial, missing }

public struct MetabolicReadinessItem: Equatable, Sendable {
    public let key: String
    public let label: String
    public let status: MetabolicReadinessStatus
    public let required: Bool
    public let detail: String        // short hint, e.g. "5 of last 7 nights"
    public init(key: String, label: String, status: MetabolicReadinessStatus,
                required: Bool, detail: String) {
        self.key = key; self.label = label; self.status = status
        self.required = required; self.detail = detail
    }
}

public enum MetabolicConfidence: String, Sendable {
    case ready      // good coverage across the board
    case estimate   // computes, but partial coverage — a softer claim
    case notReady   // can't compute yet (missing a required input)
}

public struct MetabolicReadiness: Equatable, Sendable {
    public let items: [MetabolicReadinessItem]
    public let confidence: MetabolicConfidence
    public var canCompute: Bool { confidence != .notReady }
    public init(items: [MetabolicReadinessItem], confidence: MetabolicConfidence) {
        self.items = items; self.confidence = confidence
    }
}

extension MetabolicSignalEngine {
    /// Minimum nights of sleep-with-stages before a score can be computed at all.
    public static let minCoverageDays = 4
    /// Coverage at/above which an input reads as fully satisfied (a "confident" week).
    public static let goodCoverageDays = 6

    private static func coverageStatus(_ days: Int, floor: Int) -> MetabolicReadinessStatus {
        if days >= goodCoverageDays { return .satisfied }
        if days >= floor || days > 0 { return .partial }
        return .missing
    }

    /// Build the readiness checklist + overall confidence. `sleepStageNights` counts nights with
    /// BOTH a total-sleep time and a stage breakdown (the deep-share factor needs both).
    public static func assessReadiness(hasAge: Bool, sleepStageNights: Int,
                                       hrvNights: Int, rhrNights: Int,
                                       activityDays: Int) -> MetabolicReadiness {
        let items: [MetabolicReadinessItem] = [
            MetabolicReadinessItem(key: "age", label: "Your age",
                status: hasAge ? .satisfied : .missing, required: true,
                detail: hasAge ? "Set" : "Add it in Settings"),
            MetabolicReadinessItem(key: "sleepStages", label: "Sleep with stages",
                status: coverageStatus(sleepStageNights, floor: minCoverageDays), required: true,
                detail: "\(sleepStageNights) of last 7 nights"),
            MetabolicReadinessItem(key: "hrv", label: "Nightly HRV",
                status: coverageStatus(hrvNights, floor: minCoverageDays), required: false,
                detail: "\(hrvNights) of last 7 nights"),
            MetabolicReadinessItem(key: "rhr", label: "Resting heart rate",
                status: coverageStatus(rhrNights, floor: minCoverageDays), required: false,
                detail: "\(rhrNights) of last 7 nights"),
            MetabolicReadinessItem(key: "activity", label: "Recent activity",
                status: coverageStatus(activityDays, floor: minCoverageDays), required: false,
                detail: "\(activityDays) of last 7 days"),
        ]
        // Compute gate mirrors the engine's: age + the sleep core, plus at least one of HRV/RHR so
        // the ≥3-factor minimum is reachable (sleep stages ⇒ deep share + duration).
        let hasAutonomic = hrvNights >= minCoverageDays || rhrNights >= minCoverageDays
        let confidence: MetabolicConfidence
        if !hasAge || sleepStageNights < minCoverageDays || !hasAutonomic {
            confidence = .notReady
        } else if sleepStageNights >= goodCoverageDays && hrvNights >= minCoverageDays
                    && rhrNights >= minCoverageDays && activityDays >= minCoverageDays {
            confidence = .ready
        } else {
            confidence = .estimate
        }
        return MetabolicReadiness(items: items, confidence: confidence)
    }
}
