import SwiftUI
import StrandDesign
import StrandAnalytics
import WhoopStore
import Foundation

// MARK: - Coupled view (task #43), the optional classic coupled day read
//
// An optional, default-OFF day view that reads like the classic coupled home: one screen, three numbers,
// Recovery % / Day Strain on 0–21 / Sleep, for users who came across from another band and want the old
// glance back. NOOP's Today stays the default and is untouched.
//
// DISPLAY-ONLY, like the #268 Effort-scale toggle. This screen invents no score and stores nothing: it
// reads the SAME values Today already computes (recovery / Rest composite / Effort strain / readiness) and
// re-presents them in the coupled layout. The only new mapping is the OPTIMAL strain band, a pure
// display-only read of today's recovery to a suggested strain range (never fed back into scoring).
//
// It reuses the shipped StrandDesign gauges (RecoveryRing / StrainGauge / GlowRing) and routes every colour
// through StrandPalette ramps, so the Classic / Titanium appearance toggle carries automatically. The word
// "WHOOP" appears in NO shipped UI string here (legal posture); the screen is called "Coupled view".
//
// Tap-throughs, matching the sibling screens' deep-link/back behaviour: the hero ring opens the Charge
// breakdown ("What shaped it", the same shared ChargeBreakdownSection content the Today ring opens, hosted
// here because TodayView's own sheet is view-private); the sleep row pushes the Sleep screen.

struct CoupledView: View {
    @EnvironmentObject var repo: Repository

    // Effort is stored 0–100; the coupled read is always the 0–21 Day-Strain axis regardless of the user's
    // #268 display toggle, so the gauge reads like the classic coupled home. Display-only conversion.
    private let strainScale: EffortScale = .whoop

    /// The Charge breakdown sheet, the hero ring's tap target. Its body builds LAZILY on presentation
    /// (the #819 pattern), reading drivers derived from the same displayed row the ring shows.
    @State private var showChargeBreakdown = false

    /// The day the coupled read describes, today's resolved row (the same `resolveToday` #304/#144 boundary
    /// Today anchors on), never a second store read.
    private var day: DailyMetric? { repo.today }

    /// Today's day key, tracking the resolved row when one exists (the Today idiom).
    private var todayKey: String { day?.day ?? Repository.logicalDayKey(Date()) }

    /// Recovery cold-start: nights banked so far while the HRV baseline still seeds, nil once recovery
    /// exists. The SAME pure helper Today's ring reads, so the two screens can't disagree.
    private var calibrationNights: Int? {
        RecoveryScorer.calibrationNights(nightlyHrv: repo.days.map(\.avgHrv),
                                         hasRecovery: day?.recovery != nil)
    }

    /// The last strictly-prior scored recovery day, so a just-rolled-over morning carries yesterday's read
    /// rather than blanking, exactly the anchor Today uses for readiness (#543).
    private var carriedRecoveryDay: DailyMetric? {
        repo.days.last(where: { $0.recovery != nil && $0.day < todayKey })
    }

    /// The recovery value the ring shows: today's if scored, else the carried prior day's (never fabricated).
    private var recovery: Double? { day?.recovery ?? carriedRecoveryDay?.recovery }

    /// True when the hero is showing the CARRIED prior score rather than today's own, which drives the
    /// dimmed ring + the "Last night · <date>" stamp so an old number is never passed off as new (#543/#779).
    private var isCarryingRecovery: Bool { day?.recovery == nil && carriedRecoveryDay?.recovery != nil }

    /// Effort strain on NOOP's 0–100 axis for the day (stored row; no live recompute here, this is a
    /// glance screen, not the primary Today hero). nil when the day has no scored Effort.
    private var strain100: Double? { day?.strain }

    /// Day strain mapped onto the 0–21 coupled axis via the SHIPPED formatter (UnitFormatter.effortValue),
    /// so the number matches every other Effort read-out's conversion factor exactly.
    private var dayStrain21: Double? { strain100.map { UnitFormatter.effortValue($0, scale: strainScale) } }

    /// Sleep performance % for the day, the SAME single source of truth the Today Rest score and the Sleep
    /// detail graph read: the imported figure when the export carried one, else the resolved Rest composite.
    /// Never a local hours-vs-need approximation (keeps the coupled read in agreement with Today's Rest).
    private var sleepPerformance: Double? {
        guard let d = day else { return nil }
        if let p = repo.importedSleep[d.day]?.performancePct { return p }
        return AnalyticsEngine.Rest.composite(daily: d)
    }

    /// On-device readiness, computed EXACTLY as Today does (ReadinessEngine.evaluate over the same rows,
    /// anchored on the last scored day when carrying), so the one-word pill matches the home screen's read.
    private var readinessLevel: ReadinessEngine.Level {
        let anchor = carriedRecoveryDay?.day ?? day?.day ?? Repository.logicalDayKey(Date())
        return ReadinessEngine.evaluate(days: repo.days, today: anchor).level
    }

    var body: some View {
        ScreenScaffold(title: "Day", subtitle: subtitleText) {
            ViewThatFits(in: .horizontal) {
                // Regular width (macOS / iPad): hero left, strain + sleep stacked right in a 2-column grid.
                HStack(alignment: .top, spacing: NoopMetrics.gap) {
                    heroCard
                        .frame(maxWidth: .infinity)
                    VStack(spacing: NoopMetrics.gap) {
                        strainCard
                        sleepCard
                    }
                    .frame(maxWidth: .infinity)
                }
                // Compact (iPhone): the three cards stack full-width.
                VStack(spacing: NoopMetrics.gap) {
                    heroCard
                    strainCard
                    sleepCard
                }
            }
            footerCaption
        }
        .sheet(isPresented: $showChargeBreakdown) { chargeBreakdownSheet }
    }

    // MARK: Header subtitle, "Today, d MMM"

    private var subtitleText: LocalizedStringKey {
        let f = DateFormatter()
        f.locale = Locale.current
        f.setLocalizedDateFormatFromTemplate("d MMM")
        return LocalizedStringKey("Today, \(f.string(from: Date()))")
    }

    // MARK: 1. HERO, the recovery ring, coupled read (tap = the Charge breakdown)

    /// The recovery ring shown WITHOUT its built-in centre read-out (`showsLabel: false`), so the coupled
    /// centre stack (recovery % / RECOVERY overline / readiness pill) can layer over the bare sampled arc.
    /// The whole hero is a button opening the Charge breakdown, mirroring Today's Charge-ring tap (A1).
    private var heroCard: some View {
        NoopCard(padding: 20) {
            Button {
                showChargeBreakdown = true
            } label: {
                VStack(spacing: 12) {
                    ZStack {
                        if let r = recovery {
                            RecoveryRing(score: r, diameter: 232, lineWidth: 20,
                                         showsLabel: false, showsWordmark: false, showsHover: false)
                                // A carried (not-yet-rescored) morning reads dimmed, the Today #802 idiom.
                                .opacity(isCarryingRecovery ? 0.8 : 1)
                        } else {
                            // No scored recovery yet: a faint full track so the hero never reads as broken.
                            Circle()
                                .stroke(StrandPalette.textPrimary.opacity(0.10),
                                        style: StrokeStyle(lineWidth: 20, lineCap: .round))
                                .frame(width: 232, height: 232)
                        }
                        heroCentre
                    }
                    .frame(width: 232, height: 232)
                    heroCaption
                }
                .frame(maxWidth: .infinity)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel(heroAccessibilityLabel)
        .accessibilityHint("See what shaped your Charge")
    }

    /// The centre stack over the ring: the recovery % in the house numeral, a RECOVERY overline in the
    /// SAMPLED recovery colour, and the one-word readiness pill (Push / Maintain / Rest, #205 read).
    @ViewBuilder
    private var heroCentre: some View {
        let sampled = recovery.map { StrandPalette.recoveryColor($0) } ?? StrandPalette.textTertiary
        VStack(spacing: 4) {
            Text(recovery.map { "\(Int($0.rounded()))%" } ?? "—")
                .font(StrandFont.number(56))
                .foregroundStyle(StrandPalette.textPrimary)
                .monospacedDigit()
                .lineLimit(1)
                .minimumScaleFactor(0.5)
            Text("RECOVERY")
                .font(StrandFont.overline)
                .tracking(StrandFont.overlineTracking)
                .foregroundStyle(sampled)
            if let word = TodayView.readinessWord(readinessLevel) {
                readinessPill(word)
                    .padding(.top, 2)
            }
        }
        .padding(.horizontal, 24)
    }

    /// The honest state line under the ring: the "Last night · <date>" stamp when carrying a prior score
    /// (#543/#779, via the SAME pure caption Today uses), or the calibrating progress while the baseline
    /// seeds. Nothing when today's own score is showing.
    @ViewBuilder
    private var heroCaption: some View {
        if isCarryingRecovery, let prior = carriedRecoveryDay {
            Text(TodayView.carriedCaption(priorDayKey: prior.day, todayKey: todayKey))
                .font(StrandFont.footnote)
                .foregroundStyle(StrandPalette.textTertiary)
        } else if recovery == nil, let banked = calibrationNights {
            Text(ChargeBreakdownFormat.calibrationProgress(banked: banked, seed: Baselines.minNightsSeed))
                .font(StrandFont.footnote)
                .foregroundStyle(StrandPalette.textTertiary)
        }
    }

    private var heroAccessibilityLabel: String {
        if let r = recovery { return String(localized: "Recovery \(Int(r.rounded())) percent") }
        if let banked = calibrationNights {
            return String(localized: "Recovery calibrating, \(banked) of \(Baselines.minNightsSeed) nights")
        }
        return String(localized: "Recovery, no data yet")
    }

    /// The one-word readiness pill (Push / Maintain / Rest), tinted by the readiness level, matching the
    /// Today hero pill chrome. Reuses TodayView's word + level colour so the read stays consistent.
    private func readinessPill(_ word: String) -> some View {
        let tint = readinessTint(readinessLevel)
        return Text(word.uppercased())
            .font(StrandFont.overline)
            .tracking(StrandFont.overlineTracking)
            .foregroundStyle(tint)
            .padding(.horizontal, 12).padding(.vertical, 5)
            .background(Capsule(style: .continuous).fill(tint.opacity(0.12)))
            .overlay(Capsule(style: .continuous).stroke(tint.opacity(0.32), lineWidth: 1))
            .accessibilityLabel("Readiness: \(word)")
    }

    /// The readiness level's tint, the SAME mapping TodayView.readinessColor uses.
    private func readinessTint(_ l: ReadinessEngine.Level) -> Color {
        switch l {
        case .primed:       return StrandPalette.accent
        case .balanced:     return StrandPalette.statusPositive
        case .strained:     return StrandPalette.statusWarning
        case .rundown:      return StrandPalette.metricRose
        case .insufficient: return StrandPalette.textTertiary
        }
    }

    // MARK: 2. STRAIN ROW, the effort gauge + coupled stat stack

    private var strainCard: some View {
        NoopCard(padding: 20, tint: StrandPalette.effortColor) {
            HStack(alignment: .center, spacing: 16) {
                // Left: the shipped StrainGauge on the 0–21 axis (it draws the number + band-word overline
                // itself from the fill fraction, so LIGHT / MODERATE / STRENUOUS / HIGH read on 6/10/14/18).
                Group {
                    if let s = dayStrain21 {
                        StrainGauge(strain: s, outOf: 21, diameter: 168, lineWidth: 16, showsHover: false)
                    } else {
                        emptyGauge(diameter: 168, label: "No effort yet")
                    }
                }
                .frame(width: 168, height: 168)

                // Right: the coupled stat stack, DAY STRAIN, OPTIMAL range, calories, workouts.
                VStack(alignment: .leading, spacing: 14) {
                    heroStat("Day Strain",
                             dayStrain21.map { String(format: "%.1f", $0) } ?? "—",
                             tint: StrandPalette.effortColor)
                    heroStat("Optimal",
                             Self.optimalStrainRangeText(recovery: recovery),
                             tint: StrandPalette.chargeColor)
                    heroStat("Calories",
                             caloriesText,
                             tint: StrandPalette.metricAmber)
                    heroStat("Workouts",
                             (day?.exerciseCount).map { "\($0)" } ?? "0",
                             tint: StrandPalette.textPrimary)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .accessibilityElement(children: .combine)
    }

    /// The heroStat idiom (WorkoutsView.swift:500–509): an UPPERCASE tracked overline over a big tinted
    /// number. Reproduced here so the coupled stat stack reads identically to the Workouts hero stats.
    private func heroStat(_ title: String, _ value: String, tint: Color) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(title.uppercased())
                .font(StrandFont.overline).tracking(StrandFont.overlineTracking)
                .foregroundStyle(StrandPalette.textSecondary)
            Text(value).font(StrandFont.number(20))
                .foregroundStyle(tint).lineLimit(1).minimumScaleFactor(0.6)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    /// Active calories for the day from the stored whole-day estimate. Never fabricated, a day with no
    /// estimate reads a dash.
    private var caloriesText: String {
        guard let k = day?.activeKcalEst else { return "—" }
        return "\(Int(k.rounded())) kcal"
    }

    // MARK: 3. SLEEP ROW, the sleep-performance ring + hours-vs-need read (tap = Sleep)

    private var sleepCard: some View {
        NavigationLink {
            SleepView()
        } label: {
            NoopCard(padding: 20, tint: StrandPalette.restColor) {
                HStack(alignment: .center, spacing: 16) {
                    // Left: the SLEEP PERFORMANCE % ring (GlowRing, restColor). Draws its own centre number.
                    Group {
                        if let p = sleepPerformance {
                            GlowRing(fraction: p / 100, value: p, format: { "\(Int($0.rounded()))" },
                                     color: StrandPalette.restColor, diameter: 96, lineWidth: 10)
                        } else {
                            emptyGauge(diameter: 96, label: nil)
                        }
                    }
                    .frame(width: 96, height: 96)

                    // Right: the slept-vs-needed two-line read + last night's bed–wake span footnote.
                    VStack(alignment: .leading, spacing: 4) {
                        Text("SLEEP PERFORMANCE")
                            .font(StrandFont.overline).tracking(StrandFont.overlineTracking)
                            .foregroundStyle(StrandPalette.textSecondary)
                        if let asleep = day?.totalSleepMin, asleep > 0 {
                            Text("\(Self.hoursMinutes(asleep)) slept")
                                .font(StrandFont.headline)
                                .foregroundStyle(StrandPalette.textPrimary)
                            Text("\(Self.hoursMinutes(sleepNeedForDay)) needed")
                                .font(StrandFont.subhead)
                                .foregroundStyle(StrandPalette.textSecondary)
                        } else {
                            Text("No sleep tracked last night")
                                .font(StrandFont.subhead)
                                .foregroundStyle(StrandPalette.textSecondary)
                        }
                        if let span = bedWakeSpanText {
                            Text(span)
                                .font(StrandFont.footnote)
                                .foregroundStyle(StrandPalette.textTertiary)
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)

                    Image(systemName: "chevron.right")
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(StrandPalette.textTertiary)
                }
                .contentShape(Rectangle())
            }
        }
        .buttonStyle(.plain)
        .accessibilityElement(children: .combine)
        .accessibilityLabel(sleepAccessibilityLabel)
        .accessibilityHint("Open Sleep")
    }

    private var sleepAccessibilityLabel: String {
        guard let p = sleepPerformance else { return String(localized: "Sleep performance not available") }
        if let asleep = day?.totalSleepMin, asleep > 0 {
            return String(localized: "Sleep performance \(Int(p.rounded())) percent. \(Self.hoursMinutes(asleep)) slept, \(Self.hoursMinutes(sleepNeedForDay)) needed")
        }
        return String(localized: "Sleep performance \(Int(p.rounded())) percent")
    }

    /// The night's need (minutes) for the slept-vs-needed read: the imported per-day figure when the
    /// export carried one, else the shared ≥ 7.5h personal-mean floor (matches SleepView.sleepNeedMin).
    private var sleepNeedForDay: Double {
        if let need = day.flatMap({ repo.importedSleep[$0.day]?.needMin }), need > 0 { return need }
        return sleepNeedMin
    }

    /// The personal sleep need (minutes): the recent-mean total sleep, never below a 7.5h floor. Byte-for-byte
    /// the same rule as SleepView.sleepNeedMin so the two screens agree.
    private var sleepNeedMin: Double {
        let banked = repo.days.compactMap { $0.totalSleepMin }.filter { $0 > 0 }
        let mean = banked.isEmpty ? nil : banked.reduce(0, +) / Double(banked.count)
        return Swift.max(450, mean ?? 450)   // 450 min = 7.5h
    }

    /// Last night's bed → wake span, e.g. "23:41 – 07:23", from the freshest banked sleep session, only
    /// when that session actually touches today's window (a days-old import is not "last night").
    private var bedWakeSpanText: String? {
        let dayStart = Calendar.current.startOfDay(for: Repository.logicalDay(Date()))
        let windowStart = Int(dayStart.timeIntervalSince1970)
        guard let s = repo.sleeps.filter({ $0.endTs > windowStart }).max(by: { $0.endTs < $1.endTs }) else {
            return nil
        }
        return "\(clockString(s.effectiveStartTs)) - \(clockString(s.endTs))"
    }

    // MARK: Footer

    // The brief quotes the footer with the brand word, but the hard legal / anonymity rule ("the word
    // never appears in a shipped UI string") wins over the illustrative copy: this keeps the exact intent
    // (a coupled read of NOOP's OWN scores, same data, different lens) without the branding word. The
    // matching Android caption is byte-identical.
    private var footerCaption: some View {
        Text("A classic one-glance read of NOOP's own scores. Same data, different lens.")
            .font(StrandFont.footnote)
            .foregroundStyle(StrandPalette.textTertiary)
            .fixedSize(horizontal: false, vertical: true)
            .padding(.top, 4)
    }

    // MARK: Charge breakdown sheet (the hero tap target)
    //
    // The same "What shaped it" content the Today Charge ring opens: the shared ChargeBreakdownSection over
    // drivers DERIVED from the displayed row (never a second store scan), the honest calibrating countdown
    // while the baseline seeds, and the "How Charge is calculated" method link. TodayView's own sheet is
    // view-private, so this hosts the SAME shared components with the same derivations, no engine work.

    /// The row the breakdown reads, mirroring the hero: today's own when scored, else the carried
    /// last-scored day, so the sheet always matches the ring above it.
    private var breakdownRow: DailyMetric? {
        if let t = day, t.recovery != nil { return t }
        return carriedRecoveryDay
    }

    /// The ordered Charge drivers for the displayed ring, the exact TodayView derivation (pure engine
    /// scoring against the folded personal baselines). Empty for a calibrating / cold-start night, which
    /// gates the sheet through to the countdown instead.
    private var chargeDrivers: [ChargeDriver] {
        guard let row = breakdownRow, let hrv = row.avgHrv, let rhr = row.restingHr else { return [] }
        let hrvBase = Baselines.foldHistory(repo.days.map(\.avgHrv), cfg: Baselines.hrvCfg)
        guard hrvBase.usable else { return [] }
        let rhrBase = Baselines.foldHistory(repo.days.map { $0.restingHr.map(Double.init) },
                                            cfg: Baselines.restingHRCfg)
        let respBase = Baselines.foldHistory(repo.days.map(\.respRateBpm), cfg: Baselines.respCfg)
        // Rest-quality term = the same sleep performance the sleep row shows, ÷100 (AnalyticsEngine's form).
        let sleepPerf = sleepPerformance.map { $0 / 100.0 }
        return RecoveryScorer.chargeDrivers(
            hrv: hrv, rhr: Double(rhr), resp: row.respRateBpm,
            hrvBaseline: hrvBase,
            rhrBaseline: rhrBase.usable ? rhrBase : nil,
            respBaseline: respBase.usable ? respBase : nil,
            sleepPerf: sleepPerf, skinTempDev: row.skinTempDevC)
    }

    @ViewBuilder
    private var chargeBreakdownSheet: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: NoopMetrics.sectionGap) {
                    let drivers = chargeDrivers
                    if drivers.isEmpty {
                        if let banked = calibrationNights {
                            calibrationCard(banked: banked)
                        } else {
                            NoopCard(padding: 18, tint: StrandPalette.chargeColor) {
                                VStack(alignment: .leading, spacing: NoopMetrics.space2) {
                                    Text("No Charge breakdown yet")
                                        .font(StrandFont.headline)
                                        .foregroundStyle(StrandPalette.textPrimary)
                                    Text("Wear the strap overnight to score a night first.")
                                        .font(StrandFont.subhead)
                                        .foregroundStyle(StrandPalette.textSecondary)
                                        .fixedSize(horizontal: false, vertical: true)
                                }
                            }
                        }
                    } else {
                        let hrvBase = Baselines.foldHistory(repo.days.map(\.avgHrv), cfg: Baselines.hrvCfg)
                        NoopCard(padding: 18, tint: StrandPalette.chargeColor) {
                            ChargeBreakdownSection(
                                drivers: drivers,
                                confidence: ScoreConfidence.charge(recovery: breakdownRow?.recovery,
                                                                   hrvBaseline: hrvBase),
                                skinTempRel: RecoveryScorer.skinTempRelative(deviationC: breakdownRow?.skinTempDevC))
                        }
                    }

                    // The general METHOD behind the score, clearly separated from today's values, exactly
                    // the link the Today breakdown carries. Pushes within this sheet's own NavigationStack.
                    NavigationLink {
                        ScoringGuideView(initialSection: .charge, onClose: { showChargeBreakdown = false })
                    } label: {
                        HStack(spacing: 10) {
                            Image(systemName: "function")
                                .font(.system(size: 14, weight: .semibold))
                                .foregroundStyle(StrandPalette.chargeColor)
                            VStack(alignment: .leading, spacing: 1) {
                                Text("How Charge is calculated")
                                    .font(StrandFont.subhead).foregroundStyle(StrandPalette.textPrimary)
                                Text("The method behind the score, not today's values.")
                                    .font(StrandFont.caption).foregroundStyle(StrandPalette.textTertiary)
                            }
                            Spacer(minLength: 8)
                            Image(systemName: "chevron.right")
                                .font(.system(size: 12, weight: .semibold))
                                .foregroundStyle(StrandPalette.textTertiary)
                        }
                        .padding(14)
                        .background(RoundedRectangle(cornerRadius: 14).fill(StrandPalette.surfaceInset))
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("How Charge is calculated. The method behind the score.")
                }
                .padding(NoopMetrics.screenPadding)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .background(StrandPalette.surfaceBase.ignoresSafeArea())
            .navigationTitle("What shaped your Charge")
            #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
            #endif
            .toolbar {
                #if os(iOS)
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Done") { showChargeBreakdown = false }
                        .foregroundStyle(StrandPalette.accent)
                }
                #else
                ToolbarItem {
                    Button("Done") { showChargeBreakdown = false }
                        .foregroundStyle(StrandPalette.accent)
                }
                #endif
            }
        }
    }

    /// The calibrating countdown card, the same pure `ChargeBreakdownFormat` copy the Today sheet shows,
    /// so the two breakdowns read identically while the baseline seeds.
    private func calibrationCard(banked: Int) -> some View {
        let remaining = max(1, Baselines.minNightsSeed - banked)
        let countdown = ChargeBreakdownFormat.calibrationCountdown(nightsRemaining: remaining)
        let unlock = ChargeBreakdownFormat.calibrationUnlockCopy(scoreName: String(localized: "Charge"))
        let progress = ChargeBreakdownFormat.calibrationProgress(banked: banked, seed: Baselines.minNightsSeed)
        return NoopCard(padding: 14, tint: StrandPalette.chargeColor) {
            HStack(alignment: .top, spacing: 12) {
                Image(systemName: "gauge.with.dots.needle.bottom.50percent")
                    .font(.system(size: 16, weight: .semibold))
                    .foregroundStyle(StrandPalette.chargeColor)
                    .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 3) {
                    HStack(alignment: .firstTextBaseline, spacing: 8) {
                        Text(countdown)
                            .font(StrandFont.headline)
                            .foregroundStyle(StrandPalette.textPrimary)
                        Spacer(minLength: 0)
                        ConfidenceTierChip(confidence: .calibrating)
                    }
                    Text(unlock)
                        .font(StrandFont.subhead)
                        .foregroundStyle(StrandPalette.textSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                    Text(progress)
                        .font(StrandFont.footnote)
                        .foregroundStyle(StrandPalette.textTertiary)
                }
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Charge baseline calibrating. \(countdown), \(unlock). \(progress).")
    }

    // MARK: Shared helpers

    /// A faint full-circle track for a gauge with no value yet, with an optional centred label.
    @ViewBuilder
    private func emptyGauge(diameter: CGFloat, label: LocalizedStringKey?) -> some View {
        ZStack {
            Circle().stroke(StrandPalette.textPrimary.opacity(0.10),
                            style: StrokeStyle(lineWidth: diameter * 0.10, lineCap: .round))
            if let label {
                Text(label)
                    .font(StrandFont.footnote)
                    .foregroundStyle(StrandPalette.textTertiary)
                    .multilineTextAlignment(.center)
                    .padding(diameter * 0.12)
            }
        }
        .frame(width: diameter, height: diameter)
    }

    private func clockString(_ ts: Int) -> String {
        Self.clockFmt.string(from: Date(timeIntervalSince1970: TimeInterval(ts)))
    }

    private static let clockFmt: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale.current
        f.setLocalizedDateFormatFromTemplate("jmm")
        return f
    }()

    /// "6h 42m" from a minutes count, for the slept-vs-needed read. Mirror EXACTLY in Kotlin.
    static func hoursMinutes(_ minutes: Double) -> String {
        let total = Swift.max(0, Int(minutes.rounded()))
        return "\(total / 60)h \(total % 60)m"
    }

    // MARK: - OPTIMAL strain range (task #43), pure display-only recovery→strain mapping
    //
    // The classic coupled read suggests a Day-Strain target BAND from today's recovery: a green day earns a
    // higher optimal band, a red day a lower one. This is PRESENTATION ONLY, it is never fed back into any
    // score or engine; it just tells the user where a "matched" strain would sit on the 0–21 axis. The bands
    // are the APPROVED mapping and MUST stay byte-identical to the Android `optimalStrainRange`:
    //
    //   recovery ≥ 67 (green)       → 14–18 of 21
    //   34 ≤ recovery ≤ 66 (yellow) → 10–14
    //   recovery < 34 (red)         → 4–10
    //
    // nil recovery (calibrating / unscored day) → nil, the caller renders a dash, never a guessed band.

    /// The pure recovery→optimal-strain band. Returns nil when recovery is unknown. Bands per the doc above.
    static func optimalStrainRange(recovery: Double?) -> ClosedRange<Int>? {
        guard let r = recovery else { return nil }
        switch r {
        case 67...:   return 14...18
        case 34..<67: return 10...14
        default:      return 4...10
        }
    }

    /// The optimal band as display text ("14 to 18" / "—"). Byte-identical formatting to Android.
    static func optimalStrainRangeText(recovery: Double?) -> String {
        guard let band = optimalStrainRange(recovery: recovery) else { return "—" }
        return String(localized: "\(band.lowerBound) to \(band.upperBound)")
    }
}

#if DEBUG
#Preview("Coupled view") {
    let repo = Repository(deviceId: "preview")
    repo.days = [
        DailyMetric(
            day: Repository.logicalDayKey(Date()),
            totalSleepMin: 402, efficiency: 92,
            deepMin: 84, remMin: 96, lightMin: 222, disturbances: 6,
            restingHr: 51, avgHrv: 68, recovery: 74, strain: 62,
            exerciseCount: 2,
            spo2Pct: 97, skinTempDevC: 0.1, respRateBpm: 14.4,
            steps: 8200, activeKcalEst: 640
        )
    ]
    repo.loaded = true
    return NavigationStack { CoupledView() }
        .environmentObject(repo)
        .frame(width: 900, height: 820)
        .preferredColorScheme(.dark)
}
#endif
