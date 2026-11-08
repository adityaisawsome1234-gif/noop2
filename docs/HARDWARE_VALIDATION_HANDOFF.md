# Hardware validation handoff

The software side is done and tested in replay. Several facts that matter for your WHOOP 5.0 can only be settled on your band, so this is the exact sequence to run and what to send back.

## What is already verified (without your hardware)

| Area | Verification |
|---|---|
| Frame format and checksums | Catalogue CRC check values; byte-exact match with the published hello frame and three independently derived command frames |
| Decoder offsets | All 7 real WHOOP 5.0 payloads published by public research decode to the documented values (`Tools/verify-published-captures.sh`, 10/10) |
| Sync safety | Replay tests show that Forma persists before it acknowledges. It sends no acknowledgement on a failed save, on unmappable timestamps or on a missing token, and none when you disconnect mid-transfer. Re-downloads never duplicate. Only allowlisted commands are ever written |
| Storage, analytics, presentation | Unit tests on Linux with Swift 6.4.2 (see `TEST_REPORT.md`) |

## What needs your band (in order)

### Step 1: install and first capture (about 15 minutes)

1. Build and install (`BUILD_AND_INSTALL.md`). Note your **iOS version**: Settings → General → About.
2. Onboarding. Leave **Band history** set to **Off** for this first capture.
3. Wear the band. Open **Band → Choose band**, then select it.
4. **Band → Compatibility test and diagnostics**:
   - Turn on **Record raw capture**.
   - Tap **Run compatibility test**. It runs for up to 60 s.
   - Wait 5 more minutes with the band on your wrist.
5. **Export capture…** and save the file.
6. Note: firmware (shown in Diagnostics if the band reports it, otherwise from the official app's device settings), WHOOP membership state, and whether the official app was running.

### Step 2: history (only if you accept the trade-off)

The trade-off: once Forma acknowledges a history chunk, the band may free it, and the official app may then not receive that period.

1. Settings → History → **When I tap Sync**.
2. Take the band out of range for 1–2 hours (leave the phone elsewhere), then bring it back.
3. Turn on **Record raw capture**, tap **Sync now**, wait until it completes, then export the capture.
4. Look at **Today → Last 24 hours**: the gap should now be "recorded".
5. Run **Check band-history heart rate against live heart rate** in Diagnostics. It passes only if live standard heart rate overlapped with history for at least 10 minutes.

### Step 3: background and battery (one day and one night)

Follow `HARDWARE_TEST_CHECKLIST.md` T7–T8, and record results in its tables.

## What to send back

- The capture files (`forma-capture.jsonl`). They contain health data, so share them only with people you trust.
- Your filled-in tables from `HARDWARE_TEST_CHECKLIST.md`.
- The firmware and iOS versions.

## How each open question gets resolved from your capture

Run `cd FormaKit && swift run forma-replay <capture>` on your Mac. It prints frame validity, packet types, records and HR ranges.

| Open question | Where the answer appears | Code change if needed |
|---|---|---|
| Is `180D` present, and does it carry RR? | Diagnostics counters "Standard HR notifications … with beat intervals" | None: HRV turns on automatically when real RR exists |
| Do real band frames use the documented header (`AA 01 … 00 01`) and CRCs? | "Valid frames" vs "Malformed frames" | If malformed > 0, the frame codec in `Whoop5Adapter.swift` (`Whoop5Wire`) needs adjusting |
| Is history byte 17 really bpm? | The field-validation result (agreement with live HR) | None if it passes. If it fails, stop decoding that byte (`Whoop5Decoder.decodeDataRecord`) |
| Hello response layout, data-range response, end-marker token length | The `rx` entries after each `tx` in the capture | Extend the decoder and update `docs/COMPATIBILITY.md` |
| Does the band still record and offload **without membership**? | Step 2 with the membership inactive (`HARDWARE_TEST_CHECKLIST.md` T10) | None. This is documentation of the result |
| Advertised identifiers for AccessorySetupKit | Diagnostics → Advertisement | Info.plist keys (`BUILD_AND_INSTALL.md` §6) |
| Motion scale (counts per g) | Capture of a still band vs a moving band | If confirmed, mark motion validated for this firmware and make sleep candidates available without the opt-in |

## Definition of "device-verified"

Forma can call a capability **verified on your hardware** only after the matching checklist test passes on your band, with the firmware and iOS version recorded in `TEST_REPORT.md`. Until then the app and the docs say "unverified", and they should keep saying it.
