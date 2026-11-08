# Compatibility matrix

**Owner's hardware:** WHOOP 5.0 band (firmware unknown until the first diagnostic capture) and iPhone 16 Pro on iOS 27.
**Status on 2026-11-08:** nothing in this matrix has been verified on the owner's hardware yet. Each row says where its evidence comes from.

Evidence levels used below:

- **HW-owner**: verified on the owner's band and phone. Currently none.
- **HW-public**: bytes captured from a real WHOOP 5.0 by a public project, with firmware not stated. Forma's decoder was cross-checked against them; see `Tools/verify-published-captures.sh`, 10/10 match.
- **Doc-consistent**: described consistently by public interoperability work, including independent re-derivation of frame bytes. Never seen on a real band.
- **Candidate**: decodable, but its meaning is not validated. Forma stores it as unvalidated evidence and keeps it out of metrics.
- **Unsupported**: not available to Forma on this hardware, or unknown.

Primary sources were read at the pinned commits listed in `docs/LICENSE_AUDIT.md`. Exact citations are in `docs/research/`.

## 1. Data paths on WHOOP 5.0 / MG (vendor service `FD4B0001-CCE1-4033-93CE-002D5875F58A`)

| Capability | Service / characteristic | Payload evidence | Units and scale | Timestamp semantics | Live / history | Evidence | Forma behavior |
|---|---|---|---|---|---|---|---|
| Frame transport | `…0002` write (commands); `…0003` notify (responses); `…0004` notify (events); `…0005` notify (data); `…0007` memfault (not subscribed) | Header `AA 01 LEN16 00 01 CRC16`, payload, `CRC32`. GET_HELLO frame `aa0108000001e67123019101363e5c8d` re-derived byte-for-byte | CRC-16/MODBUS over header bytes 0–5; CRC-32/ISO-HDLC over payload; little-endian | n/a | both | Doc-consistent | Implemented: reassembly validates the header CRC before trusting the length, then the payload CRC. Malformed frames are counted, never fatal |
| Identify (GET_HELLO, cmd 145) | `…0002` → response on `…0003` | Request bytes only; the response layout is not documented | — | — | n/a | Doc-consistent (request) | Sent once per connection (read-only). The response is recorded in the capture, not interpreted |
| Command responses (type 36) | `…0003` | `[1]` sequence, `[2]` command answered, `[3]` echoed sequence, `[4]` result, `[5…]` data. Result 1 = success and 2 = pending agree across sources; **0 is contested** (failure in the reference client, success in the reference emulator) | — | — | n/a | Doc-consistent | Matched to Forma's outstanding request by command id (the reference client does the same); an echoed-sequence mismatch is counted in diagnostics. Forma proceeds only on an explicit 1 |
| Stored history request / transfer | cmd 34 (data range, read-only) first, then cmd 22 (request); data records arrive as packet type 47 on `…0005`; metadata (type 49) start/end/complete | Real history records published (K10, K21, K24) | See the record rows below | u32 Unix seconds at payload 7–10 (band RTC). The u16 sub-second field's unit is unknown | history | HW-public (records), Doc-consistent (commands and order) | Opt-in only (**History** setting). As in the reference client, Forma waits for a success answer to cmd 34 (keeps waiting 25 s on each "pending", retries twice after a refusal, short answer or silence) before sending cmd 22. The range body is kept as evidence, not interpreted. Records are saved as they arrive. Forma acts only on a transfer it requested: history that another app triggers is never acknowledged and never moves Forma's sync position |
| History acknowledgement | cmd 23, data `01` + 8-byte token from the end marker (payload 13–20, only when the marker is longer than 21 bytes) | Mirrors the official Android app's acknowledgement builder according to public analysis. Conflicting evidence: a public test (fixture not published) expects `00 00 00 00` | — | — | history | **Candidate** | **Off by default** (experimental setting in Diagnostics). When on, a chunk is acknowledged only if Forma requested the transfer, saw the chunk's start marker, every frame arrived intact (no checksum failure, truncation or leftover partial frame), every record was of a kind Forma decodes and had a plausible band time, and everything was saved and flushed to storage. After any chunk fails these checks, nothing else in that transfer is acknowledged. The band's answer is recorded in diagnostics. With acknowledgements off, the band keeps its copy and may send it again; duplicates are skipped |
| Abort (ABORT_HISTORICAL_TRANSMITS, cmd 20) | — | Documented id; the reference client never sends it | — | — | history | — | **Never sent.** Forma stops a transfer by not acknowledging, so the band keeps the data |
| Heart rate in history (K24/K9/K12 byte 17; K18 byte 14; K10 byte 17) | data `…0005` | Real K24 values 51 and 151; K10 135 and 150 | Byte = bpm *per public work* | Record time = band RTC | history | **Candidate**: 151 at rest is implausible | Stored with `unvalidatedField` and excluded from metrics until it agrees with live standard HR (median difference ≤ 3 bpm over ≥ 10 min) for this firmware |
| Motion (K10 accelerometer, 3 × 100 samples) | data `…0005` | Real K10: mean vector magnitude about 1,210 raw counts | Raw i16 counts. Scale (counts per g) and sample rate unpublished | Record time | history | **Candidate** | Converted to a scale-free activity value (mean absolute deviation of magnitude). Used for sleep candidates only if you allow unvalidated motion in Diagnostics |
| K21 grouped channels | data `…0005` | Real: all values large positive (about 14k–21k) | Unknown; doesn't behave like an accelerometer | Record time | history | Unsupported (meaning unknown) | Counted as a history record whose content Forma does not store, so a chunk containing it is never acknowledged (the band keeps it) |
| History IMU stream (type 52) | data `…0005` | Documented packet type; no real capture | Unknown | Common data header | history | Unsupported | Not stored; a chunk containing it is never acknowledged |
| Beat-to-beat intervals (R17 candidates) | data `…0005` (K17) | Synthetic only; no real capture published | Unknown | — | — | **Unsupported** | Never decoded as RR. HRV is unavailable from the vendor path |
| Vendor real-time HR (TOGGLE_REALTIME_HR, cmd 3) | `…0002`, data `01` on / `00` off | Toggle bytes from the public reference client; which packets the band then sends is not documented | REALTIME frames (types 40/43) decoded with the record heart-rate byte | Band RTC when plausible, else phone receive time | live | Doc-consistent (toggle), **Candidate** (frames) | Sent only while **Live heart rate while open** is on and Forma is in use (foreground or recording a workout); switched off otherwise. Values are stored as unvalidated evidence, shown only in Diagnostics, and never used in metrics. Whether the toggle also starts standard `2A37` notifications is an open question (T3) |
| Band clock read (GET_CLOCK, cmd 11) | `…0002` → response on `…0003` | Response body u32 Unix seconds + u32 sub-seconds in 1/32768 s (public reference client) | s | Phone receive time of the response | n/a | Doc-consistent | Read once per connection and again after BOOT, SET_RTC or RTC_LOST events; history waits for it (up to 7 s). Offsets within 2 s are ignored. Larger offsets up to 24 h are applied and recorded on each record (`clockOffsetApplied`). A band clock before 2020 or off by more than 24 h is treated as wrong: history is left on the band. **Forma never sets the band's clock** |
| Events (type 48) | `…0004` | Real event 17 (TEMPERATURE_LEVEL) published; its body doesn't fit the documented header | Unknown | The header timestamp is **not** trusted | live/history | Candidate (ids only) | Event ids are logged in diagnostics. RTC_LOST, SET_RTC and BOOT mark clock discontinuities |
| Skin temperature, SpO2, respiratory rate, steps, calories | — | Not decoded by any public source with validated units | — | — | — | **Unsupported** | Disabled, with an explanation |
| Battery | Standard Battery Service `180F`/`2A19` (if exposed) | SIG specification | % (0–100) | Phone receive time | live | Doc-consistent | Read once per connection; validated values only |

### Commands Forma can send (compile-time allowlist)

| Command | WHOOP 5.0 id | Sent when |
|---|---|---|
| Identify | 145 GET_HELLO `01` | Once per connection |
| Read clock | 11 GET_CLOCK | Once per connection, and after clock events |
| Read history range | 34 GET_DATA_RANGE | Before each history request |
| Request history | 22 SEND_HISTORICAL_DATA | History setting on: after connecting (Automatic) or on **Sync now** |
| Acknowledge history | 23 HISTORICAL_DATA_RESULT `01` + token | Only with the experimental acknowledgement setting on, under the conditions above |
| Real-time HR on/off | 3 TOGGLE_REALTIME_HR `01`/`00` | Live heart rate while open |

Nothing else can be expressed: reset, reboot, erase, firmware update, clock write (10), alarms and haptics, persistent configuration (153/154), high-frequency sync (96/97) and history abort (20) are not representable or not supported.

## 2. Bluetooth SIG Heart Rate Service on the same band (`180D` / `2A37`)

| Item | Evidence | Forma behavior |
|---|---|---|
| Whether WHOOP 5.0 exposes `180D` by default, or only with "heart-rate broadcast" switched on in the official app | **Unknown**. A public iOS client discovers it, but no source says when it's present | The compatibility test reports what it sees. If it's present, Forma subscribes |
| HR format, sensor contact, energy expended, RR intervals in 1/1024 s | Bluetooth SIG Heart Rate Service specification (parser tested against spec examples) | HR samples stamped with **phone receive time** (`phoneReceiveTime` flag). RR intervals are used only if the RR flag is set, and are never derived from bpm |
| RR present on WHOOP 5.0's `2A37`? | **Unknown** | Diagnostics counts notifications with RR. HRV becomes available only if they exist |

## 3. Phone and OS

| Item | Status |
|---|---|
| iPhone 16 Pro, iOS 27 | Target. Deployment target iOS 26.0, built with Xcode 27.x (Swift 6.4) |
| Background collection | `bluetooth-central` with state restoration. Relaunch rules in `ARCHITECTURE.md` §7. Force-quit stops collection (plain Core Bluetooth) |
| AccessorySetupKit | Optional. Requires the band's advertised identifiers from a capture (`BUILD_AND_INSTALL.md` §6) |
| Pairing | Unknown whether the vendor characteristics are encrypted. Forma never bypasses pairing |

## 4. Other generations (not the owner's hardware)

| Band | Status in Forma |
|---|---|
| WHOOP 4.0 (`61080001-…`) | Not supported in v1. Public work documents a different framing (4-byte header with CRC-8). An adapter can be added without touching other modules |
| WHOOP MG | Public work groups it with the 5.0 family, but nothing confirms which device codename it is. Treat it as unverified |
| Any `180D` heart-rate strap | Supported via the standard adapter: live HR plus RR if the strap emits it. No history |

## 5. Membership independence

Whether a WHOOP 5.0 band keeps recording and offloading history to a third-party app **without an active WHOOP membership** is **untested**. No public source documents it. Until hardware test T10 passes (`HARDWARE_TEST_CHECKLIST.md`), Forma does not claim subscription-free operation for history. Live standard heart rate, if exposed, should not depend on membership. That is also unverified.
