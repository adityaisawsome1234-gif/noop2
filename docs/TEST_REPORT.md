# Test report

**Environment.**
- Linux x86_64 cloud container (Ubuntu 24.04), with SQLite 3.45 (system).
- Swift 6.4.2 (`swift-6.4.2-RELEASE`, the toolchain shipped with Xcode 27.2). The container's network policy blocked `download.swift.org`, so the toolchain came from the official `swift:6.4.2-noble` image layers on Docker Hub.
- **No Apple SDK, no Mac, no iPhone and no WHOOP band** were available.

**Date:** 2026-11-08.

## 1. Summary

| Area | Method | Result |
|---|---|---|
| FormaKit unit, adversarial and regression tests | `cd FormaKit && swift test` | **821 tests in 5 targets, all pass**. One of them, the benchmark, is skipped unless `FORMA_BENCH=1` |
| Real WHOOP 5.0 payload cross-check | `Tools/verify-published-captures.sh` (fetches goose @ `ba9ae02` at run time) | **10/10** checks match |
| No-network audit | `Tools/audit-no-network.sh` | **Clean** (12 checks) |
| iOS app sources | `Tools/linux-app-typecheck/run.sh` (stand-in SDK modules plus the real FormaKit) | Every App/Forma source type-checks with **0 errors and 0 warnings**. **Not compiled against Apple SDKs** |
| Independent review | Adversarial reviewers, breaker test suites and fixers, per area (§3) | 271 findings handled across 8 reviewed areas; 403 hostile tests written, of which 68 failed against the code at the time. The integrated tree then had a final review |
| Hardware | `docs/HARDWARE_TEST_CHECKLIST.md` | **Not run.** No band or phone was available |

## 2. FormaKit tests by target (final run)

| Target | Tests | Suites | What it covers |
|---|---|---|---|
| FormaProtocolTests | 81 | 12 | Area-specific coverage: |
| | | | • WHOOP 5.0 wire format: CRCs and command vectors re-derived twice |
| | | | • Deframer: split-point independence, truncation, bogus headers, fuzzing |
| | | | • Decoder: record kinds, real-time candidates, clock responses, sanitizer |
| | | | • Standard heart-rate parsing; the command allowlist |
| | | | • Adversarial adapter suite and review regressions |
| FormaSyncTests | 148 | 29 | Sync engine: |
| | | | • Owned transfers, range-first flow with pending and retries, clock wait |
| | | | • Acknowledgement eligibility, save → durable → acknowledge order |
| | | | • Re-entrancy generations, sequence echo, timeouts on the engine clock |
| | | | • Run status, gaps |
| | | | Also: clock mapping, discontinuities, captures and replay; WHOOP end-to-end replay; adversarial, breaker and review-fix suites |
| FormaStoreTests | 234 | 30 | Storage: |
| | | | • Migrations including v2 raw-identity dedup, atomic ingest, dedup across clock offsets |
| | | | • Durability (`ensureDurable`), retention, sessions and corrections, derived cache |
| | | | • CSV export; backup round trip, re-import and validation |
| | | | • Delete-all, concurrency; adversarial and hardening suites |
| FormaAnalyticsTests | 252 | 29 | Analytics: |
| | | | • Hand-computed examples, artifact injection and gap handling |
| | | | • Threshold boundaries, calibration, Gregorian and DST day maths |
| | | | • Flag exclusions (unvalidated, clock discontinuity) |
| | | | • The invariant that unavailable means no value; adversarial and regression suites |
| FormaFeaturesTests | 106 | 17 | App model and screens over 35 days of demo data: |
| | | | • Honest empty states, demo isolation, imports that cannot set consent |
| | | | • Per-batch field validation; cache invalidation on backfill |
| | | | • Live versus stale heart rate; delete-all; background deferral |
| | | | Adversarial suite (62 tests), regression tests, and the benchmark |

## 3. How the code was reviewed

Each area got the same treatment:
- two independent reviewers with different lenses;
- a **test breaker** that wrote hostile tests from the documented contract (not from the implementation);
- a **fixer** that checked every finding, fixed the real ones, and made the failing hostile tests pass without weakening them.

The sync engine was redesigned after its first review and then reviewed again from scratch.

| Area | Review findings (critical / major / minor) | Hostile tests (failing when written) | Outcome |
|---|---|---|---|
| WHOOP 5.0 adapter | 18 (3 / 6 / 9) | 44 (5) | Fixed during the sync redesign; suite kept |
| Sync engine, first review | 29 (4 / 10 / 15) | 55 (24) | Engine redesigned: owned transfers, opt-in acknowledgements, intact-chunk rule |
| Sync engine and adapter, second review | 47 (3 / 14 / 30) | 38 (10) | 29 fixes |
| Storage | 36 (0 / 7 / 29) | 101 (3) | Fixed; 21 hardening tests added |
| Analytics | 26 (0 / 9 / 17) | 103 (5) | Fixed; 35 regression tests added |
| App model | 44 (2 / 21 / 21) | 62 (21) | 37 fixes; 24 regression tests |
| iOS UI | 40 (2 / 15 / 23) | not testable here | 28 fixes |
| iOS Bluetooth and platform | 31 (0 / 9 / 22) | not testable here | 16 fixes; 22 behavioural tests in a private Core Bluetooth simulation |
| Final integration pass | see §3.1 | | |

### 3.1 Final integration review

The integrated tree was reviewed from three angles:
- the integration glue: merges, schema v2, durability plumbing, real-time gating;
- every documented claim checked against the code;
- the owner's requirements traced to code and tests.

The result is recorded in the commit that follows this report's first version.

## 4. What the tests establish

- **Protocol framing.**
  - CRC-16/MODBUS and CRC-32 match their catalogue check values.
  - Command frames match the published GET_HELLO frame. They also match frames derived independently twice from the documented algorithm: range, request, acknowledgement, real-time toggle and clock read.
  - The deframer recovers every genuine frame after truncated or bogus frames, gives the same result however notifications are split, and survives seeded fuzzing.
- **Decoding.**
  - All 7 real WHOOP 5.0 payloads published by public research decode to the documented kind, counter, band time and candidate fields.
  - K10 motion is summarised only from real samples (zero vectors are absent data).
  - Record kinds Forma does not decode are marked as such.
- **Sync safety.**
  - Forma acts only on history transfers it requested, and never sends an abort.
  - Acknowledgements are off by default. When on, they are sent only after the chunk was saved and made durable, and only for an intact chunk: its start was seen; no damaged, truncated, lost or undecoded frame; every time mappable; no time collision.
  - No acknowledgement goes out after a failed save, with a missing token, for history another app requested, or after a sequence mismatch or a rejected acknowledgement.
  - Re-downloads never duplicate, even when the band's clock offset changed between them.
  - Only allowlisted, adapter-encoded commands can be written.
- **Storage.**
  - Migrations; atomic ingest; dedup keys including the raw device-time identity; retention bounds.
  - Sessions with a correction audit; derived-metric invalidation.
  - CSV export; NDJSON backup round trip with idempotent re-import; validation of malformed backups; delete-all.
- **Analytics.**
  - Hand-computed examples and artifact injection for every metric.
  - Gap handling and threshold boundaries; calibration states.
  - Exclusion of unvalidated and clock-uncertain records.
  - The invariant that unavailable means no value.
- **App model.**
  - Demo data never reaches live data, exports or backups, and imports cannot switch on history sync or acknowledgements.
  - Band-history heart rate is used only from batches whose adapter and firmware passed field validation.
  - Cached past days are recomputed when history arrives.
  - "Live" heart rate is never shown for a stale value.
  - Delete-all removes both databases.

## 5. Performance (debug build, this VM)

Measured with `FORMA_BENCH=1 swift test --filter BenchmarkTests`. These are debug-build numbers on a shared cloud VM, so they show scale, not targets. A release build on an iPhone 16 Pro will differ.

| Operation | Time |
|---|---|
| Generate 35 days of demo data (580,800 HR, 319,641 beat intervals, 48,400 motion records, 50 sessions) | 0.46 s |
| Ingest into file-backed SQLite | 6.1 s |
| Today screen, cold / warm cache | 2.55 s / 0.05 s |
| Sleep screen (14 nights) | 1.33 s |
| Trends, 90 days (resting HR / load) | 0.07 s / 1.86 s |
| Full backup export / import into an empty store / re-import (all duplicates) | 6.5 s / 19.1 s / 14.3 s |

## 6. Not tested (and why)

- **Anything on the real band or phone.** See `HARDWARE_VALIDATION_HANDOFF.md`, and record the results in §7. That includes:
  - whether the band exposes standard heart rate;
  - what the real-time toggle starts;
  - result-code and sequence-echo semantics;
  - whether the band sends more than one chunk without acknowledgements;
  - what an acknowledgement does.
- **Compilation of the iOS app target against Apple SDKs.** There is no Mac in this environment. Mitigations:
  - the stand-in type check, run after every change;
  - three independent iOS reviews (UI, Bluetooth/platform, compile risk);
  - Swift 5 language mode for the app target, with complete concurrency checking as warnings.
- **Background behaviour, battery, coexistence with the official app, and membership independence.** These need hardware.

## 7. Hardware results

| Date | iPhone / iOS | Band firmware | Membership | Checklist tests run | Result | Capture file |
|---|---|---|---|---|---|---|
| _not yet run_ | | | | | | |
