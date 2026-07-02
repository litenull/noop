package com.noop.ui

import androidx.compose.foundation.background
import androidx.compose.foundation.border
import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.automirrored.filled.KeyboardArrowRight
import androidx.compose.material3.Icon
import androidx.compose.material3.Surface
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.alpha
import androidx.compose.ui.draw.clip
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.semantics.contentDescription
import androidx.compose.ui.semantics.semantics
import androidx.compose.ui.unit.dp
import androidx.compose.ui.window.Dialog
import androidx.compose.ui.window.DialogProperties
import androidx.lifecycle.compose.collectAsStateWithLifecycle
import com.noop.analytics.Baselines
import com.noop.analytics.ReadinessEngine
import com.noop.analytics.RestScorer
import com.noop.data.DailyMetric
import com.noop.data.SleepSession
import java.text.SimpleDateFormat
import java.util.Date
import java.util.Locale
import kotlin.math.roundToInt

// MARK: - Coupled view (task #43) — Kotlin twin of CoupledView.swift
//
// An optional, default-OFF day view that reads like the classic coupled home: one screen, three numbers,
// Recovery % / Day Strain on 0-21 / Sleep, for users who came across from another band and want the old
// glance back. NOOP's Today stays the default and is untouched.
//
// DISPLAY-ONLY, like the #268 Effort-scale toggle. It reads the SAME values Today already computes (recovery
// / Rest composite / Effort strain / readiness) and re-presents them in the coupled layout. The only new
// mapping is the OPTIMAL strain band, a pure display-only read of today's recovery to a suggested strain
// range (never fed back into scoring) that is byte-identical to the Swift [CoupledView.optimalStrainRange].
//
// Every colour routes through the [Palette] ramps, so the Classic / Titanium appearance carries automatically.
// The brand word never appears in a shipped UI string (legal posture); the screen is called "Coupled view".

/** The 0-21 Day-Strain axis the coupled read always uses, regardless of the user's #268 display toggle. */
private const val COUPLED_STRAIN_OUT_OF = 21.0

/** The missing-value placeholder, matching the app's shipped "No Data" token (TodayScreen.COUPLED_NO_DATA is
 *  file-private, so the coupled screen carries its own copy of the same string). */
private const val COUPLED_NO_DATA = "No Data"

@Composable
fun CoupledScreen(
    vm: AppViewModel,
    onOpenSleep: () -> Unit = {},
) {
    val today by vm.today.collectAsStateWithLifecycle()
    val days by vm.recentDays.collectAsStateWithLifecycle()

    // Last night's sleep sessions (imported + computed-only), the SAME resolution SleepScreen uses, keyed on
    // `days` so a sync/import reloads. Only needed for the bed-wake span footnote.
    var sleeps by remember { mutableStateOf<List<SleepSession>>(emptyList()) }
    LaunchedEffect(days) {
        sleeps = runCatching {
            val now = System.currentTimeMillis() / 1000L
            val imported = vm.repo.sleepSessions("my-whoop", 0L, now)
            val computed = vm.repo.sleepSessions(vm.repo.computedDeviceId("my-whoop"), 0L, now)
            val importedEnds = imported.map { it.endTs }.toHashSet()
            (imported + computed.filter { it.endTs !in importedEnds }).sortedBy { it.effectiveStartTs }
        }.getOrDefault(emptyList())
    }

    // Imported export-verbatim sleep figures (sleep_performance / need), preferred over the on-device
    // approximation, mirroring SleepScreen. Keyed on `days` (metricSeries has no Flow).
    var importedPerf by remember { mutableStateOf<Map<String, Double>>(emptyMap()) }
    var importedNeed by remember { mutableStateOf<Map<String, Double>>(emptyMap()) }
    LaunchedEffect(days) {
        suspend fun load(key: String) = runCatching {
            vm.repo.metricSeries("my-whoop", key, "0000-00-00", "9999-99-99")
        }.getOrDefault(emptyList()).associate { it.day to it.value }
        importedPerf = load("sleep_performance")
        importedNeed = load("sleep_need_min")
    }

    // The day the coupled read describes: today's resolved row, else the carried last-scored prior day, so a
    // just-rolled-over morning carries yesterday's read rather than blanking (mirrors Swift + widgetAnchor).
    val logicalKey = remember { logicalDayKeyNow() }
    val localKey = remember { java.time.LocalDate.now().toString() }
    val todayRow = remember(today, days, logicalKey, localKey) {
        resolveTodayRow(days, logicalKey, localKey) ?: today
    }
    val todayKey = todayRow?.day ?: logicalKey
    val carriedRecoveryDay = remember(days, todayKey) {
        days.lastOrNull { it.recovery != null && it.day < todayKey }
    }
    val recovery = todayRow?.recovery ?: carriedRecoveryDay?.recovery
    val isCarrying = todayRow?.recovery == null && carriedRecoveryDay?.recovery != null

    // Effort strain on NOOP's 0-100 axis (stored row), mapped to the 0-21 coupled axis via the shipped
    // formatter, so the number matches every other Effort read-out's conversion factor.
    val dayStrain21 = todayRow?.strain?.let { UnitFormatter.effortValue(it, EffortScale.WHOOP) }

    // Sleep performance %: the imported figure when the export carried one, else the resolved Rest composite
    // (RestScorer.restFromDaily), the SAME single source of truth the Today Rest score + Sleep graph read.
    val sleepPerformance = todayRow?.let { d ->
        importedPerf[d.day] ?: RestScorer.restFromDaily(d)
    }

    // On-device readiness, computed EXACTLY as Today does, so the one-word pill matches the home screen.
    val readinessLevel = remember(days, carriedRecoveryDay, todayRow) {
        val anchor = carriedRecoveryDay?.day ?: todayRow?.day ?: logicalKey
        ReadinessEngine.evaluate(days, anchor).level
    }

    // Recovery cold-start nights (the SAME pure helper Today's ring reads), for the honest calibrating
    // caption + accessibility copy while the HRV baseline still seeds.
    val calibrationNights = remember(days, todayRow) {
        recoveryCalibrationNights(days, hasRecovery = todayRow?.recovery != null)
    }

    // The Charge breakdown (the hero's tap target, the EXISTING Today sheet) + the scoring guide it
    // links on to. Both are full-screen Dialogs, TodayScreen's own presentation, built only when shown
    // (#819 lazy). Not persisted, so a return visit reopens closed.
    var showChargeBreakdown by remember { mutableStateOf(false) }
    var showGuide by remember { mutableStateOf(false) }

    ScreenScaffold(title = "Day", subtitle = subtitleToday()) {
        HeroCard(
            recovery = recovery,
            isCarrying = isCarrying,
            carriedDay = carriedRecoveryDay,
            todayKey = todayKey,
            calibrationNights = calibrationNights,
            readinessLevel = readinessLevel,
            onTap = { showChargeBreakdown = true },
        )
        StrainCard(
            dayStrain21 = dayStrain21,
            recovery = recovery,
            calories = todayRow?.activeKcalEst,
            workouts = todayRow?.exerciseCount ?: 0,
        )
        SleepCard(
            sleepPerformance = sleepPerformance,
            asleepMin = todayRow?.totalSleepMin,
            needMin = sleepNeedForDay(todayRow, days, importedNeed),
            bedWakeSpan = bedWakeSpan(sleeps),
            onOpenSleep = onOpenSleep,
        )
        Text(
            // The brief quotes the footer with the brand word, but the hard legal / anonymity rule wins over
            // the illustrative copy: this keeps the exact intent without the branding word. Byte-identical to
            // the Swift footer caption.
            "A classic one-glance read of NOOP's own scores. Same data, different lens.",
            style = NoopType.footnote,
            color = Palette.textTertiary,
            modifier = Modifier.padding(top = 4.dp),
        )
    }

    // The hero's tap target: the EXISTING Today Charge breakdown sheet (What shaped it + Contributors +
    // the folded Readiness card), reading the SAME carried/today row the hero ring shows, so the two
    // screens can never disagree. Same full-screen Dialog presentation TodayScreen uses.
    if (showChargeBreakdown) {
        Dialog(
            onDismissRequest = { showChargeBreakdown = false },
            properties = DialogProperties(usePlatformDefaultWidth = false),
        ) {
            ChargeBreakdownSheet(
                days = days,
                displayDay = todayRow,
                carriedDay = carriedRecoveryDay,
                showReadiness = true,
                onClose = { showChargeBreakdown = false },
                onHowCalculated = {
                    showChargeBreakdown = false
                    showGuide = true
                },
            )
        }
    }
    // "How Charge is calculated" from the breakdown opens the scoring guide at the Charge section, the
    // same target the Today per-ring info buttons use.
    if (showGuide) {
        Dialog(
            onDismissRequest = { showGuide = false },
            properties = DialogProperties(usePlatformDefaultWidth = false),
        ) {
            Surface(modifier = Modifier.fillMaxSize(), color = Palette.surfaceBase) {
                ScoringGuideScreen(
                    onClose = { showGuide = false },
                    initialSection = ScoreSection.CHARGE,
                )
            }
        }
    }
}

// MARK: 1. HERO — the recovery ring, coupled read (tap = the Charge breakdown)

@Composable
private fun HeroCard(
    recovery: Double?,
    isCarrying: Boolean,
    carriedDay: DailyMetric?,
    todayKey: String,
    calibrationNights: Int?,
    readinessLevel: ReadinessEngine.Level,
    onTap: () -> Unit,
) {
    val a11y = when {
        recovery != null -> "Recovery ${recovery.roundToInt()} percent. See what shaped your Charge"
        calibrationNights != null ->
            "Recovery calibrating, $calibrationNights of ${Baselines.minNightsSeed} nights"
        else -> "Recovery, no data yet"
    }
    // The whole hero is the breakdown's tap target, mirroring Today's Charge-ring tap (A1). The
    // clickable wraps the card so the ripple clips to the card shape.
    Box(
        modifier = Modifier
            .fillMaxWidth()
            .clip(RoundedCornerShape(Metrics.cardRadius))
            .clickable(onClickLabel = "See what shaped your Charge", onClick = onTap)
            .semantics { contentDescription = a11y },
    ) {
        NoopCard(padding = 20.dp) {
            Column(
                modifier = Modifier.fillMaxWidth(),
                horizontalAlignment = Alignment.CenterHorizontally,
                verticalArrangement = Arrangement.spacedBy(12.dp),
            ) {
                Box(modifier = Modifier.size(232.dp), contentAlignment = Alignment.Center) {
                    if (recovery != null) {
                        // The ring WITHOUT its built-in read-out, so the coupled centre stack layers over
                        // the arc. A carried (not-yet-rescored) morning reads dimmed, the Today #802 idiom.
                        RecoveryRing(
                            score = recovery,
                            diameter = 232.dp,
                            lineWidth = 20.dp,
                            showsLabel = false,
                            modifier = Modifier.alpha(if (isCarrying) 0.8f else 1f),
                        )
                    } else {
                        // No scored recovery yet: a faint full track so the hero never reads as broken.
                        GlowRing(
                            fraction = 0f, value = 0.0, color = Palette.chargeColor,
                            diameter = 232.dp, lineWidth = 20.dp, showsLabel = false,
                        )
                    }
                    HeroCentre(recovery = recovery, readinessLevel = readinessLevel)
                }
                // The honest state line under the ring: the "Last night · <date>" stamp when carrying a
                // prior score (#543/#779, the SAME caption Today uses), or the calibrating progress while
                // the baseline seeds. Nothing when today's own score is showing.
                if (isCarrying && carriedDay != null) {
                    Text(
                        carriedCaption(carriedDay.day, today = todayKey),
                        style = NoopType.footnote,
                        color = Palette.textTertiary,
                    )
                } else if (recovery == null && calibrationNights != null) {
                    Text(
                        "Calibrating, $calibrationNights of ${Baselines.minNightsSeed} nights",
                        style = NoopType.footnote,
                        color = Palette.textTertiary,
                    )
                }
            }
        }
    }
}

@Composable
private fun HeroCentre(recovery: Double?, readinessLevel: ReadinessEngine.Level) {
    val sampled = recovery?.let { Palette.recoveryColor(it) } ?: Palette.textTertiary
    Column(
        horizontalAlignment = Alignment.CenterHorizontally,
        verticalArrangement = Arrangement.spacedBy(4.dp),
    ) {
        if (recovery != null) {
            Text(
                "${recovery.roundToInt()}%",
                style = NoopType.number(56f),
                color = Palette.textPrimary,
                maxLines = 1,
            )
        } else {
            // The honest empty read at the ring-label size (never the 56sp numeral, "No Data" would
            // overflow the ring interior), matching the Today hero rings' RingNoData idiom.
            Text(COUPLED_NO_DATA, style = NoopType.headline, color = Palette.textSecondary)
        }
        Text("RECOVERY", style = NoopType.overline, color = sampled)
        val word = readinessWord(readinessLevel)
        if (word != null) ReadinessPill(word = word, level = readinessLevel)
    }
}

@Composable
private fun ReadinessPill(word: String, level: ReadinessEngine.Level) {
    val tint = readinessTint(level)
    Text(
        word.uppercase(),
        style = NoopType.overline,
        color = tint,
        modifier = Modifier
            .padding(top = 2.dp)
            .clip(RoundedCornerShape(999.dp))
            .background(tint.copy(alpha = 0.12f))
            .border(1.dp, tint.copy(alpha = 0.32f), RoundedCornerShape(999.dp))
            .padding(horizontal = 12.dp, vertical = 5.dp),
    )
}

/** Level -> tint, the SAME mapping TodayScreen.readinessColor uses (that one is private, so mirror it). */
private fun readinessTint(level: ReadinessEngine.Level): Color = when (level) {
    ReadinessEngine.Level.PRIMED -> Palette.accent
    ReadinessEngine.Level.BALANCED -> Palette.statusPositive
    ReadinessEngine.Level.STRAINED -> Palette.statusWarning
    ReadinessEngine.Level.RUNDOWN -> Palette.metricRose
    ReadinessEngine.Level.INSUFFICIENT -> Palette.textTertiary
}

// MARK: 2. STRAIN ROW — the effort gauge + coupled stat stack

@Composable
private fun StrainCard(dayStrain21: Double?, recovery: Double?, calories: Double?, workouts: Int) {
    NoopCard(padding = 20.dp, tint = Palette.effortColor) {
        Row(
            verticalAlignment = Alignment.CenterVertically,
            horizontalArrangement = Arrangement.spacedBy(16.dp),
        ) {
            // Left: the shipped StrainGauge on the 0-21 axis (number + "of 21"), with the band word as an
            // overline above it (the Android StrainGauge has no internal state word, so we add it here to
            // match the Swift StrainGauge's LIGHT/MODERATE/STRENUOUS/HIGH overline).
            Column(
                modifier = Modifier.size(168.dp),
                horizontalAlignment = Alignment.CenterHorizontally,
                verticalArrangement = Arrangement.Center,
            ) {
                if (dayStrain21 != null) {
                    Text(strainBandWord(dayStrain21 / COUPLED_STRAIN_OUT_OF), style = NoopType.overline, color = Palette.effortColor)
                    Spacer(Modifier.size(4.dp))
                    StrainGauge(strain = dayStrain21, outOf = COUPLED_STRAIN_OUT_OF, diameter = 148.dp, lineWidth = 14.dp)
                } else {
                    GlowRing(fraction = 0f, value = 0.0, color = Palette.effortColor, diameter = 148.dp, lineWidth = 14.dp, showsLabel = false)
                    Text("No effort yet", style = NoopType.footnote, color = Palette.textTertiary, modifier = Modifier.padding(top = 6.dp))
                }
            }

            // Right: the coupled stat stack.
            Column(
                modifier = Modifier.weight(1f),
                verticalArrangement = Arrangement.spacedBy(14.dp),
            ) {
                HeroStat("Day Strain", dayStrain21?.let { String.format(Locale.US, "%.1f", it) } ?: COUPLED_NO_DATA, Palette.effortColor)
                HeroStat("Optimal", optimalStrainRangeText(recovery), Palette.chargeColor)
                HeroStat("Calories", calories?.let { "${it.roundToInt()} kcal" } ?: COUPLED_NO_DATA, Palette.metricAmber)
                HeroStat("Workouts", workouts.toString(), Palette.textPrimary)
            }
        }
    }
}

/** The heroStat idiom (an UPPERCASE overline over a big tinted number), mirroring WorkoutsScreen/iOS heroStat. */
@Composable
private fun HeroStat(title: String, value: String, tint: Color) {
    Column(
        modifier = Modifier.fillMaxWidth(),
        verticalArrangement = Arrangement.spacedBy(2.dp),
    ) {
        Text(title.uppercase(), style = NoopType.overline, color = Palette.textSecondary)
        Text(value, style = NoopType.number(20f), color = tint)
    }
}

// MARK: 3. SLEEP ROW — the sleep-performance ring + hours-vs-need read (tap = Sleep)

@Composable
private fun SleepCard(
    sleepPerformance: Double?,
    asleepMin: Double?,
    needMin: Double,
    bedWakeSpan: String?,
    onOpenSleep: () -> Unit,
) {
    NoopCard(
        padding = 20.dp,
        tint = Palette.restColor,
        modifier = Modifier.clickable(onClickLabel = "Open Sleep", onClick = onOpenSleep),
    ) {
        Row(
            verticalAlignment = Alignment.CenterVertically,
            horizontalArrangement = Arrangement.spacedBy(16.dp),
        ) {
            Box(modifier = Modifier.size(96.dp), contentAlignment = Alignment.Center) {
                if (sleepPerformance != null) {
                    GlowRing(
                        fraction = (sleepPerformance / 100.0).toFloat(),
                        value = sleepPerformance,
                        color = Palette.restColor,
                        diameter = 96.dp, lineWidth = 10.dp,
                        format = { it.roundToInt().toString() },
                    )
                } else {
                    GlowRing(fraction = 0f, value = 0.0, color = Palette.restColor, diameter = 96.dp, lineWidth = 10.dp, showsLabel = false)
                }
            }

            Column(
                modifier = Modifier.weight(1f),
                verticalArrangement = Arrangement.spacedBy(4.dp),
            ) {
                Text("SLEEP PERFORMANCE", style = NoopType.overline, color = Palette.textSecondary)
                if (asleepMin != null && asleepMin > 0) {
                    Text("${hoursMinutes(asleepMin)} slept", style = NoopType.headline, color = Palette.textPrimary)
                    Text("${hoursMinutes(needMin)} needed", style = NoopType.subhead, color = Palette.textSecondary)
                } else {
                    Text("No sleep tracked last night", style = NoopType.subhead, color = Palette.textSecondary)
                }
                if (bedWakeSpan != null) {
                    Text(bedWakeSpan, style = NoopType.footnote, color = Palette.textTertiary)
                }
            }

            Icon(
                Icons.AutoMirrored.Filled.KeyboardArrowRight,
                contentDescription = null,
                tint = Palette.textTertiary,
                modifier = Modifier.size(18.dp),
            )
        }
    }
}

// MARK: - Pure helpers (byte-identical formatting to the Swift CoupledView)

/** The header subtitle "Today, d MMM". */
private fun subtitleToday(): String =
    "Today, " + SimpleDateFormat("d MMM", Locale.getDefault()).format(Date())

/** "6h 42m" from a minutes count, for the slept-vs-needed read. Mirrors CoupledView.hoursMinutes EXACTLY. */
internal fun hoursMinutes(minutes: Double): String {
    val total = minutes.roundToInt().coerceAtLeast(0)
    return "${total / 60}h ${total % 60}m"
}

/**
 * The strain band word for a 0..1 fill fraction, byte-identical to the Swift StrandDesign StrainGauge bands
 * (LIGHT/MODERATE/STRENUOUS/HIGH/ALL-OUT at 6/10/14/18 of 21). The Android StrainGauge has no internal state
 * word, so the coupled strain card computes it for the overline.
 */
internal fun strainBandWord(fraction: Double): String = when {
    fraction < 6.0 / 21 -> "LIGHT"
    fraction < 10.0 / 21 -> "MODERATE"
    fraction < 14.0 / 21 -> "STRENUOUS"
    fraction < 18.0 / 21 -> "HIGH"
    else -> "ALL-OUT"
}

/**
 * The night's need (minutes): the imported per-day figure when the export carried one, else the shared
 * >= 7.5h personal-mean floor (matches SleepScreen needMin / SleepView.sleepNeedMin).
 */
private fun sleepNeedForDay(day: DailyMetric?, days: List<DailyMetric>, importedNeed: Map<String, Double>): Double {
    day?.day?.let { key -> importedNeed[key]?.takeIf { it > 0 }?.let { return it } }
    val banked = days.mapNotNull { it.totalSleepMin }.filter { it > 0 }
    val mean = if (banked.isEmpty()) null else banked.sum() / banked.size
    return maxOf(450.0, mean ?: 450.0) // 450 min = 7.5h
}

/** Last night's bed -> wake span, only when the freshest session touches last night, not a days-old import. */
private fun bedWakeSpan(sleeps: List<SleepSession>): String? {
    val windowStart = System.currentTimeMillis() / 1000L - 36 * 3600L // within the last 36h counts as last night
    val s = sleeps.filter { it.endTs > windowStart }.maxByOrNull { it.endTs } ?: return null
    val fmt = SimpleDateFormat("HH:mm", Locale.getDefault())
    return "${fmt.format(Date(s.effectiveStartTs * 1000L))} - ${fmt.format(Date(s.endTs * 1000L))}"
}

// MARK: - OPTIMAL strain range (task #43) — pure display-only recovery->strain mapping
//
// The classic coupled read suggests a Day-Strain target BAND from today's recovery: a green day earns a
// higher optimal band, a red day a lower one. PRESENTATION ONLY, never fed back into any score. These are
// the APPROVED bands and MUST stay byte-identical to the Swift CoupledView.optimalStrainRange:
//   recovery >= 67 (green)        -> 14-18 of 21
//   34 <= recovery <= 66 (yellow) -> 10-14
//   recovery < 34 (red)           -> 4-10
// null recovery (calibrating / unscored day) -> null, the caller renders the no-data token, never a
// guessed band.

internal data class OptimalStrainRange(val low: Int, val high: Int)

/** The pure recovery->optimal-strain band, or null when recovery is unknown. */
internal fun optimalStrainRange(recovery: Double?): OptimalStrainRange? {
    val r = recovery ?: return null
    return when {
        r >= 67 -> OptimalStrainRange(14, 18)
        r >= 34 -> OptimalStrainRange(10, 14)
        else -> OptimalStrainRange(4, 10)
    }
}

/** The optimal band as display text ("14 to 18" / the no-data token). Byte-identical to the Swift twin. */
internal fun optimalStrainRangeText(recovery: Double?): String {
    val band = optimalStrainRange(recovery) ?: return COUPLED_NO_DATA
    return "${band.low} to ${band.high}"
}
