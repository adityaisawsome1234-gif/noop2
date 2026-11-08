# Hardware validation handoff

The software side is done and tested in replay. Several facts that matter for your WHOOP 5.0 can only be settled on your band, so this is the exact sequence to run and what to send back.

## What is already verified (without your hardware)

| Area | Verification |
|---|---|
| Frame format and checksums | Catalogue CRC check values; byte-exact match with the published hello frame and with command frames derived independently twice (research script and an adversarial test suite): range, request, acknowledgement, real-time toggle and clock read |
| Frame recovery | Hostile-input tests: truncated frames, bogus headers, garbage, every split position and seeded fuzz. Genuine frames are always recovered, and the result does not depend on how notifications are split |
| Decoder offsets | All 7 real WHOOP 5.0 payloads published by public research decode to the documented values (`Tools/verify-published-captures.sh`, 10/10) |
| Sync safety | Replay tests show that Forma acts only on history transfers it requested, and that acknowledgements are off unless you enable them. When enabled, Forma acknowledges only intact chunks that it has fully saved and flushed to storage. It never acknowledges after a damaged or truncated frame, a failed save, an unmappable timestamp, an undecoded record kind or a missing token, or when you disconnect mid-transfer. It never sends an abort. Re-downloads never duplicate. Only allowlisted, adapter-encoded commands can be written |
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

### Step 2: history download (safe: nothing is acknowledged)

By default Forma downloads band history without acknowledging it, so the band and the official app keep their copy.

1. Settings → History → **When I tap Sync**.
2. Take the band out of range for 1–2 hours (leave the phone elsewhere), then bring it back.
3. Turn on **Record raw capture**, tap **Sync now**, wait until it ends, then export the capture. Note whether it ended **complete** or **stopped without finishing** (`HARDWARE_TEST_CHECKLIST.md` 5.1).
4. Tap **Sync now** again: it should add 0 new records (5.2).
5. Look at **Today → Last 24 hours**: the gap should now be "recorded".
6. Run **Check band-history heart rate against live heart rate** in Diagnostics. It passes only if live standard heart rate overlapped with history for at least 10 minutes.

### Step 2b: acknowledgement (only if you accept the trade-off)

Once Forma acknowledges a history chunk, the band may free it, and the official app may then not receive that period. The acknowledgement's byte layout comes from public analysis of the official app and has not been confirmed on a band.

1. Diagnostics → turn on **Confirm saved history to the band**.
2. Run `HARDWARE_TEST_CHECKLIST.md` 5.6 with raw capture on, and export the capture.
3. If the band does not accept the acknowledgement, or re-sends acknowledged data, turn the setting off and send the capture back.

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
| Result code 0: success or failure? Does the band echo Forma's sequence byte? | Response lines in the frame log; "Response sequence mismatches" counter | Adjust `Whoop5Adapter.status(ofResult:)`; enable strict sequence matching if the echo is confirmed |
| Does the band send more than one chunk without acknowledgements, and finish the transfer? | Step 2 result: complete vs stopped without finishing; chunks saved | If it stalls after one chunk, history without acknowledgements only ever returns the oldest chunk. Document it, and decide whether to enable acknowledgements after 5.6 |
| Does the acknowledgement work, and what does the band do afterwards? | Step 2b (5.6): accepted counter; whether acknowledged chunks are re-sent | If confirmed, mark the acknowledgement verified for this firmware in `COMPATIBILITY.md` |
| What does TOGGLE_REALTIME_HR (cmd 3) start, and does `2A37` need it? | T3.4 and T4.3 | If real-time frames are confirmed and validated against `2A37`, extend field validation to the vendor live stream |
| Record kinds the decoder does not store (K21, type 52, …) | "content not decoded" counts in `forma-replay` | Decode them once their meaning is established; until then their chunks are never acknowledged |
| Does the band still record and offload **without membership**? | Step 2 with the membership inactive (`HARDWARE_TEST_CHECKLIST.md` T10) | None. This is documentation of the result |
| Advertised identifiers for AccessorySetupKit | Diagnostics → Advertisement | Info.plist keys (`BUILD_AND_INSTALL.md` §6) |
| Motion scale (counts per g) | Capture of a still band vs a moving band | If confirmed, mark motion validated for this firmware and make sleep candidates available without the opt-in |

## Definition of "device-verified"

Forma can call a capability **verified on your hardware** only after the matching checklist test passes on your band, with the firmware and iOS version recorded in `TEST_REPORT.md`. Until then the app and the docs say "unverified", and they should keep saying it.
