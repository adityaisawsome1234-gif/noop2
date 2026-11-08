# Hardware test checklist: WHOOP 5.0 on iPhone 16 Pro, iOS 27

Nothing in Forma counts as *verified on hardware* until the matching test below has been run on the owner's band and phone and its result recorded. Results go in `docs/TEST_REPORT.md` §Hardware. Every test records the exact build, the band firmware and the iOS version.

**Record once per session**

| Field | Value |
|---|---|
| Date / tester | |
| iPhone model / iOS version (Settings → General → About) | iPhone 16 Pro / |
| Forma build (Settings → About) and git commit | |
| Band generation / firmware (Diagnostics → Band; or official app) | WHOOP 5.0 / |
| WHOOP membership state (active / inactive / unknown) | |
| Official WHOOP app: installed? running? Bluetooth permission on? | |
| Signing route (Personal Team / paid) | |

Conventions:

- **Pass** means the expected result happened exactly.
- **Partial** means it worked with deviations, which you note.
- **Fail** means the expected result did not happen.
- Attach the exported capture file (Diagnostics → Export capture) for every test that touches data.

## T1. Discovery and selection

| # | Step | Expected | Result |
|---|---|---|---|
| 1.1 | Band on wrist, official app **closed**. Open Forma → Choose band | The band appears within 30 s (filtered scan). Its name is shown | |
| 1.2 | Official app open and connected to the band | The band appears via "connected to this iPhone", or is not listed. Record which | |
| 1.3 | Turn on "Show all nearby devices" | The unfiltered list appears in the foreground only, and scanning stops after 30 s | |
| 1.4 | Diagnostics → Advertisement | Record the advertised service UUIDs, manufacturer data / company ID and name. **Needed for AccessorySetupKit** | |

## T2. Connection, services and pairing

| # | Step | Expected | Result |
|---|---|---|---|
| 2.1 | Select the band → run the compatibility test | "Connect without any account" passes and no account prompt appears anywhere | |
| 2.2 | Services list | Vendor service `FD4B0001-…` with characteristics `…0002` (write), `…0003`, `…0004`, `…0005` (notify), `…0007`. Record any extra services, such as `180D`, `180F` or `180A` | |
| 2.3 | Pairing | Record whether iOS shows a pairing prompt, and when. Forma must never attempt to bypass a declined pairing | |
| 2.4 | Airplane mode **on**, Bluetooth **on**, repeat 2.1 | Same results. Forma works with no internet (acceptance criterion 1) | |

## T3. Standard Heart Rate Service (if present)

| # | Step | Expected | Result |
|---|---|---|---|
| 3.1 | With the band worn, watch Diagnostics → "Standard HR notifications" | The counter increases at about 1 Hz, and the HR values look plausible against a manual pulse check | |
| 3.2 | "…with beat intervals" counter | Record whether the counter is **> 0**. If it is 0, the standard path carries no beat intervals and HRV from that path stays **unsupported** | |
| 3.3 | Whether HR broadcast must be enabled in the official app for `180D` to appear | Record yes / no / unknown | |
| 3.4 | Turn **Live heart rate while open** off, reconnect, wait 2 min; then turn it on (this sends TOGGLE_REALTIME_HR `01`) | Record whether "Standard HR notifications" increases **before** the toggle, only **after** it, or never. This settles whether `2A37` depends on the vendor toggle | |

## T4. Vendor data path

| # | Step | Expected | Result |
|---|---|---|---|
| 4.1 | Compatibility test → "Vendor data path" | Frames arrive, the header CRC-16/MODBUS and payload CRC-32 validate, and the malformed counter stays 0 or close to it | |
| 4.2 | "Identify band" (read-only hello) | A response arrives. Record its result code (public sources disagree whether 0 means success) and whether "Response sequence mismatches" stays 0 (does the band echo Forma's sequence byte?) | |
| 4.3 | **Live heart rate while open** on (TOGGLE_REALTIME_HR `01`) | Record which packet types now arrive (frame log), whether event `BLE_REALTIME_HR_ON` (33) appears, and the "vendor HR candidate" in Diagnostics against a manual pulse. It stays **unvalidated** either way. Turn it off (`00`): the frames stop and event 34 may appear. Disconnect while it is on, reconnect without touching anything: record whether real-time frames arrive before Forma sends a command (does the band keep streaming after a disconnect?) | |
| 4.4 | Band clock (GET_CLOCK, read once per connection) | Diagnostics shows the band–phone offset. Forma applies corrections greater than 2 s and records them on each record. Record the offset and the response's result code | |
| 4.5 | Unknown packet types counter | Record the count. Export the capture for parser follow-up | |

## T5. History sync (only with history sync enabled)

Acknowledgements are **off** for 5.1–5.5: Forma downloads and saves, and the band keeps its copy.

| # | Step | Expected | Result |
|---|---|---|---|
| 5.1 | Band off the phone for 2 h (phone away or Bluetooth off), then Sync now | The range request (cmd 34) is answered: record its result codes (any "pending"?) and body length from the frame log. History records arrive and the coverage gap is filled. Record the number of chunks saved, and whether the transfer ends **complete** or **stopped without finishing**. That tells whether the band sends more than one chunk without acknowledgements | |
| 5.2 | Sync again immediately | The band sends the same data again (it was not acknowledged): 0 new records, duplicates counted. Confirms the band keeps unacknowledged history | |
| 5.3 | Kill Forma (Xcode stop) **mid-transfer**, reopen, sync again | No duplicates (dedup keys). The previously interrupted chunk is transferred again | |
| 5.4 | Walk out of range mid-transfer | Sync is marked interrupted. On return it resumes. No data loss and no duplicates | |
| 5.5 | Field validation: history HR vs live HR for the same minutes | "Field validation" passes only if the values agree (median absolute difference ≤ 3 bpm over ≥ 10 min). Otherwise history HR stays **unvalidated** and is not used in metrics | |
| 5.6 | **Acknowledgement test** (experimental; only after 5.1–5.2). Diagnostics → turn on "Confirm saved history to the band", Sync now | Only intact, fully saved chunks are acknowledged. Diagnostics shows chunks acknowledged and the band's answers (accepted / not accepted). Then Sync again: acknowledged chunks are **not** sent again. If the band does not accept the acknowledgement, or sends acknowledged data again, turn the setting off and report it with the capture | |
| 5.7 | Coexistence: let the official app sync after Forma acknowledged a chunk | Record whether the official app still shows that period. This documents the trade-off described in Settings | |

## T6. Persistence and integrity

| # | Step | Expected | Result |
|---|---|---|---|
| 6.1 | Note the record counts (Settings → Your data). Force-quit and reopen | The counts are unchanged | |
| 6.2 | Export CSV and backup, then import the backup | The import reports 0 new and N duplicates | |
| 6.3 | Delete all data | All screens show empty states, and the database files are removed | |

## T7. Background behavior (record actual outcomes; iOS rules in ARCHITECTURE §7)

Turn on **Settings → Developer → Fast App Termination** for the relaunch tests.

| # | Scenario | Expectation per Apple's rules | Observed |
|---|---|---|---|
| 7.1 | Phone locked for 1 h, band worn, collection on | Notifications keep arriving, and the coverage timeline shows recorded data | |
| 7.2 | Forma backgrounded (another app in use) for 1 h | Same as 7.1 | |
| 7.3 | Bluetooth off and on in **Control Center** | Reconnects (plain Core Bluetooth on iOS 26+: may not relaunch if terminated) | |
| 7.4 | Bluetooth off and on in **Settings** | No relaunch if terminated. Reconnects after Forma is opened | |
| 7.5 | Out of range for 30 min, then back | Reconnects automatically (pending connect). The gap is "pending sync" until history sync | |
| 7.6 | Forma terminated by the system (Fast App Termination) | Relaunched on the next band event | |
| 7.7 | Forma **force-quit** by swiping | **Not** relaunched (plain Core Bluetooth). Record the outcome | |
| 7.8 | Phone reboot, then **no unlock** for 10 min, then unlock | No relaunch before the first unlock. Collection resumes after unlock | |
| 7.9 | Low Power Mode on for 2 h | Record any change in notification rate or reconnects | |
| 7.10 | Overnight (≥ 7 h) with the phone on the nightstand | Coverage ≥ 90 % recorded **or** recoverable by history sync. Record actual numbers | |

## T8. Battery

| # | Measurement | Method | Result |
|---|---|---|---|
| 8.1 | Phone battery drain, 8 h overnight, Forma connected | Settings → Battery → Forma share and total %. Compare to a night without Forma | |
| 8.2 | Band battery drain per 24 h with Forma vs without | Battery % from the band (Diagnostics / official app) at fixed times | |
| 8.3 | Live HR stream on for 1 h | Phone and band % change | |

## T9. Time

| # | Step | Expected | Result |
|---|---|---|---|
| 9.1 | Compare band timestamps of history records with phone time | The offset matches 4.4. No record is timestamped by arrival time | |
| 9.2 | Change the phone time zone | Stored UTC timestamps are unchanged, and day boundaries follow the new zone | |

## T10. Membership-independence check (required before claiming subscription-free operation)

| # | Step | Expected | Result |
|---|---|---|---|
| 10.1 | WHOOP membership **inactive**, official app not running (or uninstalled), phone in airplane mode with Bluetooth on | T2–T5 pass. Record exactly what works | |

Until T10 passes on the owner's hardware, Forma's documentation must describe subscription-free operation as **untested**.

## T11. Coexistence with the official app

| # | Step | Expected | Result |
|---|---|---|---|
| 11.1 | Both apps running and connected | Record whether Forma's stream or commands are disturbed, and whether the official app shows errors | |
| 11.2 | Both apps attempt history sync | Record behavior. Forma must not crash or duplicate records. Document any data the official app no longer receives | |
