# Forma: product requirements

| | |
|---|---|
| Owner | Aatmunn (CEO) |
| Target hardware | The owner's own **WHOOP 5.0** band |
| Target phone | **iPhone 16 Pro on iOS 27** (single native implementation) |
| Status | Phases A–D implemented and replay-tested. Hardware validation is pending; see `HARDWARE_VALIDATION_HANDOFF.md`. |
| Last updated | 2026-11-08 |

Forma is a local-first iPhone app. It reads data directly from the owner's WHOOP band over Bluetooth Low Energy, stores it only on the phone, and computes **transparent, independent** wellness metrics on the device. It has no account, no server, and no cloud.

> **Independence statement.** Forma is not affiliated with, endorsed by, or connected to WHOOP, Inc. "WHOOP" appears only to identify the hardware Forma interoperates with. Forma's metrics are Forma's own documented estimates. They are **not** WHOOP Recovery, Strain, Sleep or any other proprietary score, and Forma does not claim to match them.

---

## 1. Goals

1. Read heart rate and other verified data from the owner's band **without** a WHOOP account, WHOOP cloud API, OAuth or subscription. All reads go directly over BLE.
2. Keep every byte of health data on the phone. Core features work with **no internet**, and only Bluetooth needs to be on.
3. Show **measured** values first: heart rate, its history with visible gaps, and workout heart-rate summaries. Add **estimates** (HRV, resting HR, sleep windows, training load) only when their inputs exist and pass documented quality gates.
4. Make every number explainable. Each metric shows its inputs, method, window, coverage, confidence, version and limitations.
5. Present a calm, clean, accessible interface that is clearly Forma's own design.

## 2. Non-goals (v1)

- Any WHOOP cloud integration, scraping or account login.
- Any server, sync service, analytics/telemetry SDK, ad SDK or remote AI coach.
- Firmware modification or updates, secret/key extraction, defeating pairing authentication, and destructive device commands (reset, erase, DFU, clock write).
- Sleep **stages** (REM/deep/light). They need a validated model and inputs Forma does not have (see §6.3).
- Medical claims, diagnosis or treatment/training prescriptions.
- Writing to Apple Health. Deferred until deduplication and validation rules exist.
- A second platform. Android is out of scope until the iOS app is device-validated.

## 3. Hard constraints and how they are enforced

| Constraint | Enforcement in code/process |
|---|---|
| No WHOOP cloud/account/OAuth | The app contains no networking code (`URLSession`, `Network`, sockets, web views). A CI-style audit script greps for networking APIs (`Tools/audit-no-network.sh`). |
| Offline operation | All parsing, storage, analytics and charts run on the device. The app's Info.plist declares no network usage. |
| No telemetry/ads/remote AI | There are no third-party runtime dependencies at all. FormaKit uses only Foundation and SQLite. |
| Own device only | The user explicitly selects a device. The app never auto-connects to unknown bands. The device identity is shown everywhere data appears. |
| No firmware changes / no destructive commands | A **compile-time command allowlist** in `FormaProtocol` cannot express reset, erase, DFU, haptics or clock-write. Every command sent is logged in diagnostics. |
| No defeating authentication | Forma uses only the link the band and iOS allow. If the band demands authentication Forma cannot legitimately satisfy, Forma reports "unsupported" instead of working around it. |
| Honest metrics | `MetricValue` cannot carry a value without availability. Unavailable means `nil` (never 0). Every metric has a `MetricSpec`, and the Methodology screen renders those specs. |
| Original branding | Name "Forma", with its own palette, icon and typography. No WHOOP logos, assets or copied UI. |

## 4. User and key scenarios

The single user is the band's owner, technically capable and privacy-conscious.

1. **First run.** Privacy explanation → Bluetooth permission → choose the band from a filtered list → compatibility test (diagnostic capture) → first sync → calibration explanation. No account is created.
2. **Morning check.** Open Today and see last night's measured values (overnight HR range, resting-HR estimate, HRV if beat intervals exist) with coverage. Also see the last device sample, last sync and connection status, each shown separately.
3. **Workout.** Start a workout in Activity and watch live HR and zones. Stop it and get the duration, average and maximum HR, time in zones, and Forma Load.
4. **Correct sleep.** Accept, adjust or reject a candidate sleep window, or enter one manually. Derived metrics recompute.
5. **Review trends.** View 7/30/90-day values with gaps, baseline coverage and simple comparisons. A table view is always available.
6. **Own the data.** Export CSV/JSON or a versioned backup to a location the user picks, import a backup, or delete everything.

## 5. Platform decision

**Native iOS: Swift 6, SwiftUI, Swift Charts, Core Bluetooth and SQLite.** The deployment target is iOS 26.0, built with Xcode 27.x, which ships Swift 6.4. The single phone is an iPhone 16 Pro on iOS 27, so one excellent iOS implementation beats two partial apps.

- **No PWA or browser layer**, because Web Bluetooth is not available in iOS Safari, and a web layer cannot use Core Bluetooth background modes or state restoration.
- **Installation** uses developer signing from Xcode: a free Personal Team (re-sign every 7 days) or a paid Apple Developer Program membership (profiles valid for a year). Neither is an app subscription, and Forma itself has no subscription. Details are in `BUILD_AND_INSTALL.md`.

## 6. Features by release

Every metric below has a `MetricSpec` in code (`FormaAnalytics/MetricCatalog.swift`) and an entry in `METHODOLOGY.md`. That entry lists the required inputs, quality gates, method, windowing, units, baseline, version and limitations.

### 6.1 Release 1: measured data and quality-gated basics

| Feature | Status class | Requirement |
|---|---|---|
| Live heart rate | measured | Shows the source (vendor stream or standard HR service) and the time of the last sample. When nothing is arriving, the screen says so instead of showing a stale number as live. |
| HR history | measured | Device-timestamped band history is preferred over live samples. Gaps stay visible in charts and tables. |
| Workout sessions | measured + estimate | Duration, time-weighted average HR, max HR, configurable zones (%HRmax or heart-rate reserve), time in zones and coverage. |
| Resting HR (overnight) | estimate | Lowest 5-minute mean HR within a confirmed sleep window, with ≥80% window coverage and ≥3 h covered. Labeled a personal overnight estimate, not a clinical measurement. |
| HRV (RMSSD) | estimate | Computed **only** from beat intervals the band itself emits. Artifact rules, 5-minute windows and minimum valid windows apply. It is never computed across gaps or from `60/BPM`. Raw and filtered series are kept separate. |
| Trends 7/30/90 d | descriptive | Shown only when minimum days are met (4/7, 14/30, 45/90). No causal language. |

### 6.2 Release 2: after reliable overnight data exists

| Feature | Status class | Requirement |
|---|---|---|
| Sleep/wake candidates | estimate | Require motion data from the band. They are candidates until the user confirms them, they carry confidence and are editable, and manual windows are always available. They are never inferred from HR alone. |
| Forma Load | estimate | Edwards TRIMP (zone-weighted minutes). Banister TRIMP is optional and needs HRrest, HRmax and sex. It is named as Forma's own load and is not "Strain". |
| Readiness index | experimental | A baseline-relative composite of HRV, RHR and sleep duration z-scores. The weights are exposed, and the result is shown in SD units with a band. Calibration progress is shown. It never gives advice. |

### 6.3 Deferred and conditional

- **Sleep stages: deferred.** No validated, licensed staging model exists with inputs Forma can measure. Heart rate alone cannot establish REM or deep sleep. Forma ships sleep duration and continuity only.
- **Temperature, SpO2, respiratory rate, steps, calories, stress, workout auto-detection: conditional.** Each needs (1) a confirmed data path on this band and firmware, (2) validated units and semantics, and (3) a documented method. Until all three hold, the feature stays disabled with an explanation. Decoded but unvalidated fields are stored as raw evidence with `validated = false` and never shown as health values.

## 7. Experience

- **Visual direction.** Warm off-white background, charcoal type and a restrained teal accent, with generous spacing, subtle borders and precise units. No gradients, no decorative rings and no tiny labels. Dark mode is accessible.
- **Navigation.** Four tabs: Today, Sleep, Activity and Trends. Device, sync and settings sit behind a persistent connection control in the top bar.
- **States.** Every view supports disconnected, syncing, partial data, calibrating, insufficient quality, unsupported sensor, empty history and error. Each state has specific copy and, where possible, a next action.
- **Demo data.** It lives in a separate database file and carries a persistent, non-dismissable "Demo data" label. It is never mixed with live records.
- **Accessibility.** Dynamic Type through accessibility sizes, VoiceOver labels with units, chart audio-graph/accessible table alternatives, high contrast and reduced motion. Color is never the only signal.

## 8. Data, privacy and portability

- **Storage.** SQLite with versioned migrations and indexed tables for devices, ingest batches, HR samples, beat intervals, motion epochs, auxiliary measurements, raw frames, sync cursors/runs, sessions, corrections, derived metrics and settings. Raw measurements are kept separate from derived estimates.
- **Protection.** The database lives in Application Support with `NSFileProtectionCompleteUntilFirstUserAuthentication`, which background BLE writes need while the phone is locked. The data is encrypted at rest whenever the phone has not been unlocked since boot. An optional Face ID/passcode app lock is available.
- **Backups.** The default is **local-only**: the database is excluded from iCloud and computer backups. The user can opt in to OS backups in Settings, with a clear explanation. Settings and onboarding warn that deleting the app deletes all unexported history.
- **Export and import.** CSV per table, a versioned NDJSON backup with validation and deduplication on import, and a destination the user chooses. Derived metrics are recomputed after import or corrections.
- **Retention and deletion.** Raw-frame capture is off by default and bounded by age, rows and bytes when on. "Delete all data" erases the database files.
- **Logging.** General logs carry no health payloads. Raw frames go only to the bounded diagnostic table.

## 9. Reliability expectations (honest)

- iOS can keep a Core Bluetooth central connected and relaunch the app for BLE events in many but not all situations. Force-quitting, rebooting before the first unlock, revoking Bluetooth permission and Low Power Mode all affect collection. `ARCHITECTURE.md` §Background lists the exact current rules.
- Forma recovers missed periods from the band's own stored history **where the band provides it**. Coverage views distinguish data **pending sync** (may still be on the band) from data **not recorded** (permanently unavailable).
- Battery impact must be measured on the real phone and band before any claim is made. The test report records measurements, not estimates.

## 10. Phases and acceptance

| Phase | Deliverables | Exit criterion |
|---|---|---|
| A | PRD, compatibility matrix, architecture, hardware test checklist, license audit | All reused material has a verified license or is facts-only |
| B | BLE diagnostic screen, protocol parsers and tests, persistence, history recovery | **A real capture from the owner's band.** Until then: replay-tested and marked *unverified* |
| C | Measured-metric dashboard, workout recorder, trends, export/delete, all states | Works offline, and every state is reachable in previews/tests |
| D | Quality-gated HRV, sleep/wake candidates, Forma Load, experimental readiness | Unsupported metrics are disabled with explanations |
| E | Tests, build checks, visual QA, device reliability tests, no-network verification | Test report lists exact band firmware and iOS version. Nothing is claimed beyond what was tested |

Acceptance criteria (verification method in brackets):

1. The band connects directly without WHOOP credentials or cloud calls. [Hardware test with the phone in airplane mode and Bluetooth on, plus the static no-network audit.]
2. Valid samples survive app restart and interrupted sync without duplicates. [Unit tests on dedup keys and atomic ingest, plus a hardware interruption test.]
3. Live and history capture work to the extent demonstrated on the exact hardware, with honest coverage and unsupported states. [Hardware checklist.]
4. Core screens, calculations, export and deletion work offline. [Unit tests plus a device test in airplane mode.]
5. HRV uses real beat intervals and quality gates, and sleep and readiness are clearly independent estimates. [Analytics tests and Methodology screen review.]
6. Background collection and history recovery have a documented test report, including failures and battery observations. [Hardware checklist §Background.]
7. No fabricated sensors, scores, sleep stages or parity claims. [Code review and copy audit.]
8. All reused code has verified licensing and attribution, and build instructions identify signing requirements. [`LICENSE_AUDIT.md`, `THIRD_PARTY_NOTICES.md`, `BUILD_AND_INSTALL.md`.]
9. Delivery includes source, setup instructions, methodology, tests, known limitations and a hardware-validation handoff.

## 11. Risks

| Risk | Impact | Mitigation |
|---|---|---|
| The WHOOP 5.0 protocol differs on the owner's firmware from what public work describes | Vendor data path fails | Adapter isolation, a diagnostics capture/export flow, replay tooling, and the standard HR service as a fallback |
| The band requires authentication Forma cannot legitimately perform | Vendor path unavailable | Report unsupported and fall back to the standard HR service if the band broadcasts it. No circumvention |
| The official WHOOP app competes for the connection or the band's history pointer | Missing or duplicated history | Document coexistence, use dedup keys, and acknowledge history only after durable persistence |
| iOS background limits | Gaps | Backfill from band history, honest coverage, documented relaunch rules |
| Optical beat-interval quality | Noisy HRV | Artifact rules, minimum valid windows, coverage and confidence labels, overnight-only default |
