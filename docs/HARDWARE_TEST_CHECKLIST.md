# Hardware test checklist: WHOOP 5.0 on iPhone 16 Pro, iOS 27

Nothing in Forma counts as *verified on hardware* until the matching test below has been run on the owner's band and phone and its result recorded. Results go in `docs/TEST_REPORT.md` §Hardware. Every test records the exact build, the band firmware and the iOS version.

**Record once per session**

| Field | Value |
|---|---|
| Date / tester | |
| iPhone model / iOS version (Settings → General → About) | iPhone 16 Pro / |
| Forma build (Settings → About → About Forma: "Version …") and git commit | |
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
| 1.3 | Turn on "Show all nearby Bluetooth devices" | The unfiltered list appears in the foreground only, and scanning stops after 30 s | |
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
| 3.4 | Turn **Request live heart-rate stream** (Band → Collection) off, reconnect, wait 2 min; then turn it on with Forma in the foreground (this sends TOGGLE_REALTIME_HR `01`) | Record whether "Standard HR notifications" increases **before** the toggle, only **after** it, or never. This settles whether `2A37` depends on the vendor toggle | |

## T4. Vendor data path

| # | Step | Expected | Result |
|---|---|---|---|
| 4.1 | Compatibility test → "Vendor data path" | Frames arrive, the header CRC-16/MODBUS and payload CRC-32 validate, and the malformed counter stays 0 or close to it | |
| 4.2 | "Identify band" (read-only hello) | A response arrives. Record its result code (public sources disagree whether 0 means success) and whether "Response sequence mismatches" stays 0 (does the band echo Forma's sequence byte?) | |
| 4.3 | **Request live heart-rate stream** on, Forma in the foreground (TOGGLE_REALTIME_HR `01`) | Record which packet types now arrive (frame log), whether event `BLE_REALTIME_HR_ON` (33) appears, and **Latest real-time value (unvalidated)** in Diagnostics against a manual pulse. It stays **unvalidated** either way. Turn it off (`00`): the frames stop and event 34 may appear. Disconnect while it is on, reconnect without touching anything: record whether real-time frames arrive before Forma sends a command (does the band keep streaming after a disconnect?). With the setting off on reconnect, Forma sends `00` once when it may have left the stream on | |
| 4.4 | Band clock (GET_CLOCK, read once per connection) | The compatibility test's **Band clock** row shows the band–phone offset (also when the test runs on a band that was already connected; if no reading arrived it says so — reconnect and run it again). Forma applies corrections greater than 2 s and records them on each record. Record the offset and the response's result code | |
| 4.5 | Unknown packet types counter | Record the count. Export the capture for parser follow-up | |

## T5. History sync (only with history sync enabled)

Acknowledgements are **off** for 5.1–5.5: Forma downloads and saves, and the band is expected to keep its copy (5.2 checks it). Turn band history on first: Band → History → Band history → **When I tap Sync**.

| # | Step | Expected | Result |
|---|---|---|---|
| 5.1 | Band off the phone for 2 h (phone away or Bluetooth off), then Sync now | The range request (cmd 34) is answered: record its result codes (any "pending"?) and body length from the frame log. History records arrive. Record, from Diagnostics → Vendor stream and history, **Chunks received**, **Chunks saved intact**, **Transfers the band finished** and **Records Forma does not decode yet**, and the status text under Band. A chunk holding a record Forma does not decode (K21) is saved but not intact, so the status reads "Last sync failed …: The band finished the transfer (N chunks), but it is not complete for Forma: …" even when the band finished; "The band stopped sending without finishing" means it did not. Together they tell whether the band sends more than one chunk without acknowledgements. On Today → Last 24 hours the downloaded period shows **Saved, not validated** until 5.5 passes | |
| 5.2 | Sync again immediately | The band sends the same data again (it was not acknowledged): Diagnostics → Counters **History records saved (new)** does not grow while **History records already stored** grows by about the number of records. Confirms the band keeps unacknowledged history | |
| 5.3 | Kill Forma (Xcode stop) **mid-transfer**, reopen, sync again | No duplicates (dedup keys). The previously interrupted chunk is transferred again | |
| 5.4 | Walk out of range mid-transfer | The status reads "Last sync failed …: Disconnected during history transfer; unacknowledged data stays on the band". On return, tap **Sync now** (with **Automatically**, it starts by itself after reconnecting). No data loss and no duplicates | |
| 5.5 | Field validation: history HR vs live HR for the same minutes (Diagnostics → Field validation → Check band-history heart rate against live heart rate; it also runs after each download while there is no result) | "Field validation" passes only if the values agree (≥ 10 overlapping minutes of live standard heart rate, median absolute difference ≤ 3 bpm, ≥ 90 % of minutes within ±5 bpm); without `180D` it cannot pass. Otherwise history HR stays **unvalidated** and is not used in metrics. After a pass, Today shows the downloaded period as **Recorded** | |
| 5.6 | **Acknowledgement test** (experimental; only after 5.1–5.2). Diagnostics → turn on "Confirm saved history to the band", Sync now | Only intact, fully saved chunks are acknowledged. Diagnostics shows chunks acknowledged and the band's answers (accepted / not accepted). Then Sync again: acknowledged chunks are **not** sent again. If the band does not accept the acknowledgement, or sends acknowledged data again, turn the setting off and report it with the capture | |
| 5.7 | Coexistence: let the official app sync after Forma acknowledged a chunk | Record whether the official app still shows that period. This documents the trade-off described in Diagnostics → History acknowledgement | |

## T6. Persistence and integrity

| # | Step | Expected | Result |
|---|---|---|---|
| 6.1 | Note the record counts (Settings → Data → Export, import and delete → Stored on this iPhone). Force-quit and reopen | The counts are unchanged | |
| 6.2 | Export CSV and backup, then import the backup | The import reports "Imported 0 records; N were already present" | |
| 6.3 | Delete all data | All screens show empty states and the record counts are 0; the band stays selected (Forget band removes it) | |

## T7. Background behavior (record actual outcomes; iOS rules in ARCHITECTURE §7)

Turn on **Settings → Developer → Fast App Termination** for the relaunch tests.

| # | Scenario | Expectation per Apple's rules | Observed |
|---|---|---|---|
| 7.1 | Phone locked for 1 h, band worn, collection on | Notifications keep arriving, and the coverage timeline shows recorded data | |
| 7.2 | Forma backgrounded (another app in use) for 1 h | Same as 7.1 | |
| 7.3 | Bluetooth off and on in **Control Center** | Reconnects (plain Core Bluetooth on iOS 26+: may not relaunch if terminated) | |
| 7.4 | Bluetooth off and on in **Settings** | No relaunch if terminated. Reconnects after Forma is opened | |
| 7.5 | Out of range for 30 min, then back | Reconnects automatically (pending connect). The gap is "pending sync" until history sync, then "saved, not validated" until band-history heart rate passes validation | |
| 7.6 | Forma terminated by the system (Fast App Termination) | Relaunched on the next band event | |
| 7.7 | Forma **force-quit** by swiping | **Not** relaunched (plain Core Bluetooth). Record the outcome | |
| 7.8 | Phone reboot, then **no unlock** for 10 min, then unlock | No relaunch before the first unlock. Collection resumes after unlock | |
| 7.9 | Low Power Mode on for 2 h | Record any change in notification rate or reconnects | |
| 7.10 | Overnight (≥ 7 h) with the phone on the nightstand | Coverage ≥ 90 % recorded **or** recoverable by history sync. Record actual numbers | |

## T8. Battery

| # | Measurement | Method | Result |
|---|---|---|---|
| 8.1 | Phone battery drain, 8 h overnight, Forma connected | Settings → Battery → Forma share and total %. Compare to a night without Forma | |
| 8.2 | Band battery drain per 24 h with Forma vs without | Battery % from the band (Diagnostics → Band → Battery (reported by the band), if the band exposes the Battery Service; otherwise the official app) at fixed times | |
| 8.3 | **Request live heart-rate stream** on and Forma in the foreground for 1 h | Phone and band % change | |

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
