# Metabolic Signal

**Status:** shipped. A daily number you can read at a glance.

## What it is

Metabolic Signal is a **pattern readout**, not a measurement. It answers one question:
*"Over the past week, how insulin-friendly did your recovery patterns look?"* — scored 0–100,
where higher means the behaviours and physiology that track insulin sensitivity in the published
literature are sitting in favourable ranges for you.

That is the whole claim. It is **not** a measure of insulin resistance: that requires fasting
labs (HOMA-IR) or an oral glucose tolerance test, and no wearable can do it. Like the Illness
heads-up, the feature never names a condition — the copy stays at "how insulin-friendly your
patterns look". It is computed **on-device** from data NOOP already records (Oura ring or WHOOP
strap), daily, on a rolling 7-day median window so a single bad night cannot swing it.

## Where the number comes from

Five factors, each scored 0–100 against published anchors (population references, not personal
baselines — this is a "where do I sit" read like Fitness Age, not a "vs your normal" read like
Charge), then combined with fixed weights. Weights favour the causal sleep evidence over the
observational autonomic correlates. Missing factors are skipped and the weights renormalise;
**at least 3 factors are required, and sleep duration is mandatory**.

| Factor | Weight | Reference / anchor | Evidence |
|---|---|---|---|
| Deep-sleep (SWS) share of total sleep | 0.30 | age-normed share (19% at 20 yr → 9% at 80 yr) | 3 nights of selective SWS suppression — total sleep unchanged — cut insulin sensitivity ~25% in healthy adults (Tasali 2008, PNAS). Normative share from Dijk 2009. |
| Sleep duration | 0.25 | optimum band 7–9 h; steep penalty to 4 h; gentle, floored penalty above | 4–5 h/night for under 2 weeks reduced insulin sensitivity ~25–40% in healthy adults (Spiegel 1999, Lancet; Buxton 2010). |
| Nightly HRV (RMSSD) | 0.20 | age-normed RMSSD (the Vitality norms) | Lower RMSSD tracks higher HOMA-IR (Saito 2015, Toon Health Study). |
| Resting heart rate | 0.15 | piecewise band: 100 @ ≤50 bpm, 70 @ 65, 30 @ 80, 0 @ ≥90 | Elevated RHR tracks higher fasting insulin independent of other factors (ARIC cohort). |
| Activity (HUNT PA-index) | 0.10 | full credit at PA-index 5 — the "moderately active" reference peer Fitness Age uses | Exercise improves insulin sensitivity acutely and chronically. |

Levels: **≥ 65 favorable · 40–65 steady · < 40 watch** — plain-language bands, never a diagnosis.

## Cadence and gating

- **Daily.** The value recomputes each night and is stamped on the day, so the trend line in
  Metric Explorer / Trends is continuous.
- **Rolling 7-day medians** for every input (sleep hours, deep share, RMSSD, RHR), so one bad
  night or one rest day doesn't swing the score.
- **Coverage gates.** The engine requires age (it norms deep sleep and HRV against it), sleep
  duration, and ≥ 3 present factors. The readiness checklist surfaces the same gates as
  ✓/⚠/○ rows; below them, the section shows the checklist instead of a number — no fake values.
- Best/worst drivers shown in the hero card come from the same recomputation the stored headline
  uses, so the "why" always reconciles with the number.

The daily results are stored in `metricSeries` under the computed `-noop` source:

| Key                | Unit  | Meaning                                     |
|--------------------|-------|---------------------------------------------|
| `metabolic_signal` | /100  | the headline score (drives the Health card) |

## Honesty disclaimer

- This is a **pattern readout**, not a diagnosis, a risk score, or a measurement of insulin
  resistance, prediabetes, or diabetes. It cannot replace lab tests.
- The strongest anchors here are *causal sleep studies on small healthy cohorts* plus
  *observational autonomic correlations in large cohorts*. Direction is well-supported; the
  composite's absolute scale is a transparent construction, not a validated clinical instrument.
- A low score is best read as "my sleep/recovery patterns this week look unfavourable" — usually
  the actionable version of that is more sleep, more deep sleep, or more activity, not worry.

## References

- **Tasali E, et al.** *Slow-wave sleep and the risk of type 2 diabetes in humans.* PNAS.
  2008;105(3):1044–1049 — selective SWS suppression → ~25% insulin-sensitivity loss.
- **Spiegel K, Leproult R, Van Cauter E.** *Impact of sleep debt on metabolic and endocrine
  function.* Lancet. 1999;354:1435–1439 — 4 h/night × 6 nights → marked glucose-tolerance
  impairment. Replicated by **Buxton OM, et al.** Sci Transl Med. 2010 (5 h/night × 1 week).
- **Saito I, et al.** *Heart rate variability, insulin resistance, and insulin sensitivity* —
  Toon Health Study (PMID 26277879): lower RMSSD/HF and higher LF:HF track higher HOMA-IR.
- **ARIC cohort** — resting heart rate and fasting insulin / insulin resistance (associations
  independent of other metabolic factors).
- **Dijk DJ.** *Regulation and functional correlates of slow wave sleep.* J Clin Sleep Med.
  2009 — normative SWS share by age.
