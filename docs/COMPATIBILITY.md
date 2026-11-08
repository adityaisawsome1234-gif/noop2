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
| Stored history request / transfer | cmd 22 (request), cmd 34 (data range, read-only); data records arrive as packet type 47 on `…0005`; metadata (type 49) start/end/complete | Real history records published (K10, K21, K24) | See the record rows below | u32 Unix seconds at payload 7–10 (band RTC). The u16 sub-second field's unit is unknown | history | HW-public (records), Doc-consistent (commands) | Opt-in only (**History** setting). Records are persisted, then acknowledged |
| History acknowledgement | cmd 23, data `01` + 8-byte token from the end marker (payload 13–20) | From public app-behavior analysis. Conflicting evidence: one public test shows `00 00 00 00` | — | — | history | **Candidate** | Sent only after persistence succeeds, and only when the end marker carries a token and every record had a plausible band time. Its effect on band storage is unknown, which is why it is opt-in |
| Heart rate in history (K24/K9/K12 byte 17; K18 byte 14; K10 byte 17) | data `…0005` | Real K24 values 51 and 151; K10 135 and 150 | Byte = bpm *per public work* | Record time = band RTC | history | **Candidate**: 151 at rest is implausible | Stored with `unvalidatedField` and excluded from metrics until it agrees with live standard HR (median difference ≤ 3 bpm over ≥ 10 min) for this firmware |
| Motion (K10 accelerometer, 3 × 100 samples) | data `…0005` | Real K10: mean vector magnitude about 1,210 raw counts | Raw i16 counts. Scale (counts per g) and sample rate unpublished | Record time | history | **Candidate** | Converted to a scale-free activity value (mean absolute deviation of magnitude). Used for sleep candidates only if you allow unvalidated motion in Diagnostics |
| K21 grouped channels | data `…0005` | Real: all values large positive (about 14k–21k) | Unknown; doesn't behave like an accelerometer | Record time | history | Unsupported (meaning unknown) | Counted as a history record; no fields used |
| Beat-to-beat intervals (R17 candidates) | data `…0005` (K17) | Synthetic only; no real capture published | Unknown | — | — | **Unsupported** | Never decoded as RR. HRV is unavailable from the vendor path |
| Vendor real-time HR (cmd 3 toggle) | — | Toggle payload not documented | — | — | live | **Unsupported** | Not sent (not in the adapter's supported commands) |
| Band clock read (cmd 11) | — | Response layout not documented | — | — | — | **Unsupported** | Not sent. Band times are checked for plausibility (2020 to now + 1 day). Implausible records are left on the band and not acknowledged |
| Events (type 48) | `…0004` | Real event 17 (TEMPERATURE_LEVEL) published; its body doesn't fit the documented header | Unknown | The header timestamp is **not** trusted | live/history | Candidate (ids only) | Event ids are logged in diagnostics. RTC_LOST, SET_RTC and BOOT mark clock discontinuities |
| Skin temperature, SpO2, respiratory rate, steps, calories | — | Not decoded by any public source with validated units | — | — | — | **Unsupported** | Disabled, with an explanation |
| Battery | Standard Battery Service `180F`/`2A19` (if exposed) | SIG specification | % (0–100) | Phone receive time | live | Doc-consistent | Read once per connection; validated values only |

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
