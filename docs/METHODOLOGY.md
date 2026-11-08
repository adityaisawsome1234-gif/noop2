# Methodology

How Forma turns raw measurements into what you see, and what each number can and can't tell you.

The per-metric specifications (inputs, quality gates, method, windows, units, baselines, limitations, references) are compiled into the app and rendered in **Settings → Methodology**. The same text is generated into `METHODOLOGY_SPECS.md` with `cd FormaKit && swift run forma-docs`, so the documentation cannot drift from the code.

## 1. Principles

1. **Measured first, estimated second.** Heart rate (and beat-to-beat intervals, if the band emits them) are *measurements*. Everything else is a Forma *estimate* with a published method. The readiness index is *experimental*. Every value carries one of these three labels.
2. **No value without a reason.** Every metric returns a value **and** an availability:
   - available
   - insufficient data
   - calibrating
   - unsupported sensor
   - low quality
   - not yet synced
   - disabled

   When it isn't available the value is `nil` and the screen says why. Forma never substitutes 0, an average or an interpolation.
3. **Nothing invented.**
   - Beat-to-beat intervals are never derived from bpm (no `60 000 / bpm`).
   - Sleep is never inferred from heart rate alone.
   - Sleep stages are not estimated.
   - Decoded but unvalidated device fields are stored as evidence and kept out of metrics.
4. **Coverage and confidence are shown with every derived value.**
5. **Independent.** These are Forma's own methods. They don't reproduce any proprietary score and make no claim of equivalence.

## 2. Time

- **Band-history records** use the band's own clock (Unix seconds), never the moment the phone received them.
  - Forma reads the band's clock once per connection (and again after a clock event). If the band is more than 2 s off, the offset (whole seconds, up to 24 h) is applied and recorded on each record (`clockOffsetApplied`, with the offset).
  - A band clock before 2020 or off by more than 24 h is treated as wrong. Forma never sets the band's clock, so history then stays on the band until the clock is fixed.
  - Records with implausible times (before 2020 or more than a day in the future) cannot be placed in time. They are not stored as measurements, and that history chunk is **not** acknowledged, so the band keeps it.
  - Records next to clock resets or device restarts are flagged and excluded from analytics. Restart detection runs per record kind and starts fresh with every transfer.
- **Standard heart-rate service** data carries no timestamps. Forma stamps it with the phone's receive time and flags it as such. Beat intervals from it are placed backwards from the receive time.
- Days, nights and trends use the phone's current time zone. Stored times are always UTC.

## 3. Heart-rate series and coverage

- Samples flagged out of range (outside 25–240 bpm), no sensor contact, device-invalid, unmapped clock or unvalidated are excluded.
- When sources overlap, band history wins, then the vendor live stream, then the standard service. One sample per second is kept.
- Each sample counts as coverage for up to 5 s. *Coverage* is the covered fraction of a window.
- Charts break the line at gaps longer than 10 s (60 s for overview charts). Gaps are never interpolated.
- Coverage views separate three cases:
  - **recorded**
  - **pending sync**: missing now, but the band may still hold it
  - **not recorded**: no backfill is possible, or a sync has already passed this period

## 4. Field validation

Decoded fields whose meaning public evidence hasn't confirmed are stored with `unvalidatedField` and excluded from every metric.

- **Band-history heart rate** is validated per adapter and firmware. It passes when it agrees with **live standard heart rate** for the same minutes: median absolute difference ≤ 3 bpm over at least 10 overlapping minutes. If it disagrees, it stays excluded and the reason is shown.
- **Motion counts** have an unpublished scale. They are used for sleep candidates only if you allow it in Diagnostics.

## 5. Metrics at a glance

| Metric | Class | Core method | Needs |
|---|---|---|---|
| Heart rate | measured | Source-merged series with gaps | HR samples |
| Max HR | estimate | Your entry; otherwise the Tanaka formula (208 − 0.7 × age), labeled as estimated | Profile |
| Zones | estimate | % of max HR (50/60/70/80/90) or % of HR reserve (Karvonen) | Max HR (and resting HR for Karvonen) |
| Workout summary | measured + estimate | Duration, time-weighted mean HR, max HR, time in zones | ≥ 50 % HR coverage |
| Resting HR (overnight) | estimate | Lowest 5-min mean in a confirmed sleep window (windows ≥ 80 % covered) | ≥ 3 h covered |
| HRV (RMSSD) | estimate | Artifact-filtered, gap-segmented RMSSD per 5-min window; median of valid windows | Real beat intervals; ≥ 6 valid windows |
| Trends | descriptive | 7/30/90-day statistics; last 7 days vs prior 28 | ≥ 4/7, 14/30, 45/90 days with data |
| Sleep candidate | estimate | Motion-based quiet periods with an adaptive threshold; you confirm | Motion data |
| Sleep summary | estimate | Window length; with motion, wake bouts and continuity | Confirmed window |
| Forma Load | estimate | Edwards TRIMP: minutes in %HRmax zones × weights 1–5 | Max HR; ≥ 30 % day coverage |
| Readiness (experimental) | experimental | Weighted z-scores vs your previous 28 days (HRV 0.5, RHR 0.3, sleep 0.2), in SD units with a band | ≥ 14 eligible nights |

## 6. Limitations

- Optical wrist sensors are less accurate during movement, poor fit, cold skin and arrhythmias. Pulse-to-pulse intervals from PPG aren't ECG RR intervals.
- Overnight resting HR is a personal estimate, not a clinical resting heart rate.
- Sleep candidates are heuristics that need your confirmation. They aren't polysomnography.
- The readiness index is not validated against any outcome. Its weights are fixed defaults and are shown with every value.
- None of this is medical advice. Forma gives no training or treatment recommendations.
