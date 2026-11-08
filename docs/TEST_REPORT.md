# Test report

**Environment:** Linux x86_64 (Ubuntu 24.04), Swift 6.4.2 (`swift-6.4.2-RELEASE`, the toolchain shipped with Xcode 27.2), SQLite 3.45 (system). **No Apple SDK, no iPhone, no WHOOP band** were available in this environment.

**Date:** 2026-11-08.

## 1. Summary

| Area | Method | Result |
|---|---|---|
| FormaKit unit tests | `cd FormaKit && swift test` | _filled in by the final run (§2)_ |
| Real WHOOP 5.0 payload cross-check | `Tools/verify-published-captures.sh` (fetches goose @ ba9ae02 at run time) | 10/10 checks match |
| No-network audit | `Tools/audit-no-network.sh` | Clean |
| iOS app sources | `Tools/linux-app-typecheck/run.sh` (stand-in SDK modules plus real FormaKit) | All 24 files type-check. **Not compiled against Apple SDKs** |
| Hardware | `docs/HARDWARE_TEST_CHECKLIST.md` | **Not run.** No band or phone was available |

## 2. FormaKit unit tests (final run)

_Filled in by the final integration run._

## 3. What the tests establish

- **Protocol framing.**
  - CRC-16/MODBUS and CRC-32 match their catalogue check values.
  - Command frames match the published GET_HELLO frame and frames derived independently from the documented algorithm, byte for byte.
  - The deframer survives a split at every byte position, garbage, stray start bytes, corrupted headers and payloads, impossible lengths, and seeded fuzzing.
- **Decoding.** All 7 real WHOOP 5.0 payloads published by public research decode to the documented kind, counter, band time and candidate fields.
- **Sync safety.**
  - Records are persisted before any acknowledgement is sent.
  - No acknowledgement is sent after a failed save, with unmappable timestamps, with a missing token, or when history is off.
  - Disconnecting mid-chunk persists what arrived and sends no acknowledgement.
  - Repeated downloads never create duplicates.
  - Only allowlisted commands supported by the adapter are written.
  - Band time is used for history records, never arrival time.
  - The end-to-end WHOOP 5.0 replay reassembles 20-byte notifications.
- **Storage.**
  - Migrations, atomic ingest, dedup keys, retention bounds, sessions with correction audit, and derived-metric invalidation.
  - CSV export, NDJSON backup round trip with idempotent re-import, validation of malformed backups, and delete-all.
- **Analytics.** Hand-computed examples and artifact injection for every metric, plus checks for:
  - gap handling;
  - threshold boundaries;
  - calibration states;
  - the invariant that unavailable means no value.
- **Presentation and app model.** Over 35 days of demo data:
  - honest empty states;
  - no resting HR or HRV without a confirmed sleep window;
  - unvalidated band fields excluded;
  - HRV "unsupported" without beat intervals;
  - readiness calibration;
  - demo and live data isolated;
  - live heart rate flowing from a replayed link through the real engine into the store;
  - sleep corrections, backup import and delete-all.

## 4. Performance (debug build, this VM)

| Operation | Time |
|---|---|
| Generate 35 days of demo data (586k HR, 325k RR, 49k motion records) | 0.5 s |
| Ingest into file-backed SQLite | 5.3 s |
| Today screen, cold / warm cache | 1.3 s / 0.05 s |
| Sleep screen (14 nights) | 0.8 s |
| Trends, 90 days (resting HR / load) | 0.08 s / 1.4 s |
| Full backup export / import (960k records) | 5.8 s / 16.4 s |

## 5. Not tested (and why)

- **Anything on the real band or phone.** See `HARDWARE_VALIDATION_HANDOFF.md`, and record the results in §6.
- **Compilation of the iOS app target against Apple SDKs.** There is no Mac in this environment. Mitigations:
  - the stand-in type check;
  - independent API-correctness reviews;
  - Swift 5 language mode for the app target (concurrency diagnostics are warnings).
- **Background behavior, battery, coexistence with the official app, and membership independence.** These need hardware.

## 6. Hardware results

| Date | iPhone / iOS | Band firmware | Membership | Checklist tests run | Result | Capture file |
|---|---|---|---|---|---|---|
| _not yet run_ | | | | | | |
