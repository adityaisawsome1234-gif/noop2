# Known limitations

These are listed honestly so nothing is mistaken for a capability Forma doesn't have yet.

## Not verified on your hardware yet

- No part of Forma has run against your WHOOP 5.0 or your iPhone. Everything that touches the band is tested by replaying synthetic frames and the bytes published by public projects (`TEST_REPORT.md`). See `HARDWARE_VALIDATION_HANDOFF.md`.
- **The iOS app target has never been compiled.** It covers the SwiftUI views, the Core Bluetooth layer, AccessorySetupKit and LocalAuthentication. This build environment is Linux, with no Apple SDK. Expect to fix small compile errors in Xcode 27 the first time you build. Everything below the app layer is compiled and unit-tested: parsing, sync, storage, analytics, and the app model with its screen logic.
- The Xcode project file was written by hand. If Xcode rejects it, regenerate it with XcodeGen from `project.yml`.

## Data available from WHOOP 5.0 (from public evidence)

- **HRV (RMSSD) is unavailable unless the band emits real beat-to-beat intervals.** No public source has a validated beat-interval field in the vendor protocol. If the band exposes the standard Heart Rate Service with RR intervals, HRV works. Otherwise it stays "unsupported", and Forma never derives intervals from bpm.
- **Live heart rate depends on the standard Heart Rate Service.** Forma sends the vendor real-time toggle (bytes from the public reference client) while you use the app. What the band then sends is not documented, so those values are kept as unvalidated evidence and shown only in Diagnostics. If the band doesn't expose `180D` (it may require "heart-rate broadcast" in the official app, or the toggle; checklist T3.4), there is no live heart rate. History, if enabled, still fills in heart rate after a sync once validated.
- **Band-history heart rate is unvalidated.** Public captures include values like 151 for what looks like rest. Forma keeps history heart rate out of all metrics until it agrees with live standard heart rate on your firmware: at least 10 overlapping minutes, a median difference ≤ 3 bpm, and ≥ 90 % of minutes within ±5 bpm. That needs the band's standard heart-rate service, which may not be available (T3).
- **Motion values are raw counts on an unpublished scale.** Sleep candidates from motion need your explicit opt-in in Diagnostics. Manual sleep windows always work.
- **History is downloaded but not acknowledged by default.** The acknowledgement's layout comes from public analysis and is unverified, and acknowledging may free the data on the band. So by default the band keeps its copy and sends it again on later syncs, and Forma skips the duplicates. Whether the band sends more than its first chunk without acknowledgements is unknown (checklist 5.1). An experimental setting enables acknowledgements. Even then, Forma acknowledges only chunks it requested, received intact, decoded completely and saved durably. Chunks that contain record kinds Forma does not decode yet (K21 and the history IMU stream appear in public captures) are never acknowledged. Running the official app and Forma's acknowledgements side by side may leave gaps in one of them.
- **Band clock.** Forma reads the band's clock but never sets it. If the band's clock is off by more than a day (for example after a reset), band history can't be placed in time and stays on the band until the clock is corrected (opening the official app once usually does this).
- **Subscription independence is untested.** Whether the band keeps recording and offloading without an active membership is unknown until checklist test T10 passes.
- Not available: skin temperature, SpO2, respiratory rate, steps, calories, stress, automatic workout detection and sleep stages (see `PRD.md` §6.3).

## iOS behavior

- Force-quitting Forma (swiping it away) stops background collection until you open it again. Toggling Bluetooth in Settings does the same. After a reboot, nothing resumes until the phone has been unlocked once. AccessorySetupKit may lift the force-quit limit on iOS 26+, but it is optional and not yet validated (`ARCHITECTURE.md` §7).
- A Personal Team build expires after 7 days (`BUILD_AND_INSTALL.md`).
- The behavior with Low Power Mode, after app updates and with revoked permissions is not documented by Apple. Forma records gaps honestly.
- Battery impact has not been measured yet (`HARDWARE_TEST_CHECKLIST.md` T8).

## Analytics

- Every derived value is a Forma-defined estimate with a documented method (`METHODOLOGY.md`). None is a clinical measure, and none reproduces WHOOP's proprietary scores.
- The readiness index is experimental, uses fixed default weights, and needs at least 14 eligible nights before it shows a value.
- The sleep-candidate thresholds are defaults that need calibration on real motion data.
- Max heart rate falls back to the Tanaka age formula when you haven't entered one, and is labeled as an estimate.

## Storage and portability

- With the default local-only setting, uninstalling Forma or replacing the iPhone loses unexported history. Use Settings → Your data → Export full backup.
- Backups from another phone don't move the band's sync position. This is deliberate, to avoid skipping history.
- Raw-frame diagnostics are bounded by age, row count and total size.
