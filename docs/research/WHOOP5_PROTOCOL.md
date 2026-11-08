# WHOOP 5.0 / MG Bluetooth protocol: the facts Forma uses

This page restates interoperability **facts** in Forma's own words: identifiers, layouts, numbers and observed behavior. It contains no code from any source. Citations point to files at the pinned commits audited in `docs/LICENSE_AUDIT.md`; `goose:` is `b-nnett/goose @ ba9ae02`.

Confidence labels:

- **real bytes**: checked against payloads captured from a real band by a public project (`Tools/verify-published-captures.sh`).
- **documented**: described by public work, re-derived independently, never seen on the owner's band.
- **contested**: sources disagree.
- **open**: unknown until a hardware test runs (`HARDWARE_TEST_CHECKLIST.md`).

## 1. GATT

| Role | UUID | Source | Confidence |
|---|---|---|---|
| Vendor service | `FD4B0001-CCE1-4033-93CE-002D5875F58A` | goose:Rust/core/src/openwhoop_reference.rs:71 | documented |
| Commands to the band (write) | `…0002…` | openwhoop_reference.rs:79 | documented |
| Command responses (notify) | `…0003…` | openwhoop_reference.rs:80 | documented |
| Events (notify) | `…0004…` | openwhoop_reference.rs:81 | documented |
| Data (notify) | `…0005…` | openwhoop_reference.rs:82 | documented |
| Memfault (notify) | `…0007…` | openwhoop_reference.rs:83 | documented |
| Standard `180D`/`2A37`, `180F`/`2A19`, `180A` | Bluetooth SIG | goose:GooseSwift/GooseBLEClient.swift:391-418 (discovered alongside) | **open**: presence on 5.0 is second-hand only |

`…0002…` stands for `FD4B0002-CCE1-4033-93CE-002D5875F58A`, and so on.

## 2. Frame

```
AA 01 LEN(u16 LE) 00 01 HCRC(u16 LE) | PAYLOAD | PCRC(u32 LE)
```

- `LEN` is the payload length plus 4 (the trailing CRC). Total frame = 8 + `LEN`. Frames Forma builds pad the payload with zeros to a multiple of 4. Whether frames from the band are always padded is **open**: the 162-byte "live identity" K24 payload comes from the same extraction as a K10 and a K21 that are cut off mid-sample at 168 bytes, so it is most likely truncated, not evidence of unpadded framing. Forma accepts unpadded frames anyway (harmless: the declared length decides).
- `HCRC` is CRC-16/MODBUS (poly 0x8005 reflected, init 0xFFFF, no final XOR) over bytes 0–5. `PCRC` is CRC-32/ISO-HDLC (zlib) over the payload.
- Source: goose:Rust/core/src/protocol.rs (frame builder and parser); GET_HELLO frame `aa0108000001e67123019101363e5c8d` re-derived byte for byte (**documented**). Whether real band frames validate under both CRCs is **open**: every published owned capture is payload-only (`goose.payload.hex.v1`) and is wrapped in a frame by goose's own builder at test time, the published frame fixtures are synthetic, and goose's live client does not check either CRC. Hardware check 4.1 settles it.
- The fixed header bytes `[1] = 01` and `[4…5] = 00 01` are not checked separately (the header CRC covers them); like the reference parser, Forma has not verified them on real frames (**open**).
- The only bound on the length is the u16 field itself. goose accepts truncated data frames, so Forma treats a frame that never completes as damaged and recovers the frames that follow it.

## 3. Payload layouts

| Packet type (byte 0) | Layout | Confidence |
|---|---|---|
| 35 COMMAND | `[1]` sequence, `[2]` command id, `[3…]` data | documented |
| 36 COMMAND_RESPONSE | `[1]` sequence, `[2]` command answered, `[3]` echoed sequence, `[4]` result, `[5…]` data. The reference client matches an answer on command id **and** echoed sequence (goose:GooseSwift/GooseBLEClient+HistoricalHandlers.swift:372-375; clock: 163-164) | documented (goose:Rust/core/src/protocol.rs:445-462) |
| 38 PUFFIN_COMMAND_RESPONSE | Handled by the reference client exactly like 36 (HistoricalHandlers.swift:23) | documented; **not decoded by Forma** (open whether the 5.0 band sends it) |
| 47 HISTORICAL_DATA, 40 REALTIME_DATA, 43 REALTIME_RAW_DATA, 51/52 IMU streams | `[1]` record kind K, `[2]` status, `[3…6]` u32 counter, `[7…10]` u32 Unix seconds, `[11…12]` u16 sub-seconds (unit unknown), body from 13 | real bytes (type 47, K10/K21/K24) |
| 48 EVENT | `[2…3]` u16 event id. The timestamp layout in the header is **not** trusted: a real TEMPERATURE_LEVEL event doesn't fit it | contested |
| 49 METADATA | `[2]` kind: 1 history start, 2 history end, 3 history complete (goose:GooseSwift HistoricalHandlers.swift:518-591) | documented |
| 56 PUFFIN_METADATA | u16 kind at `[2…3]`, same kinds as 49; the reference client handles it like 49 (HistoricalHandlers.swift:41, 518-524) | documented; **not decoded by Forma**: inside a chunk it blocks that chunk's acknowledgement (open whether the 5.0 band sends it) |

**Result codes** (byte 4 of a response):

- 1 = success and 2 = pending are agreed.
- 0 is **contested**. The reference iOS client names it FAILURE (`3` UNSUPPORTED). The reference emulator counts 0 and 1 as success (goose:Rust/core/src/commands.rs:2466-2471).
- A published synthetic GET_HELLO response carries 0.
- Forma proceeds only on 1.

## 4. Commands Forma sends

| Id | Name | Data | Source | Notes |
|---|---|---|---|---|
| 145 | GET_HELLO | `01` | goose fixtures | Read-only identify |
| 11 | GET_CLOCK | none | goose:GooseSwift/GooseBLEClient.swift:460-494 | Response body: u32 Unix seconds + u32 sub-seconds in 1/32768 s (GooseBLEClient+Parsing.swift:815-821) |
| 34 | GET_DATA_RANGE | none | GooseBLEClient.swift:422-453 | Read-only. A success answer carries at least 25 body bytes; the reference client treats a shorter one as invalid |
| 22 | SEND_HISTORICAL_DATA | none | same | Starts a transfer |
| 23 | HISTORICAL_DATA_RESULT | `01` + payload bytes 13–20 of the history-end marker (only when the marker is longer than 21 bytes) | GooseBLEClient+Parsing.swift:833-842, where a comment says it mirrors the official Android app's builder | **contested**: an unpublished fixture expects `00 00 00 00`. Its effect on band storage is **open** |
| 3 | TOGGLE_REALTIME_HR | `01` on, `00` off | GooseBLEClient.swift:529-547 | What the band then sends is **open**. The reference client always sends it together with cmd 63 SEND_R10_R11_REALTIME_ON (same lines); Forma sends only cmd 3 (63 is not in its allowlist), so whether cmd 3 alone starts a stream is **open** (hardware tests T3.4 and T4.3) |

Command frames re-derived independently twice (Forma's tests and an adversarial suite):

- range, seq 7: `aa0108000001e67123072200698f3e31`
- request, seq 8: `aa0108000001e67123081600a33b4881`
- toggle on, seq 180: `aa0108000001e67123b4030155eabe0d`
- toggle off, seq 182: `aa0108000001e67123b60300ad0e3d79`
- clock, seq 96: `aa0108000001e67123600b0027cde038`
- acknowledgement with a zero token, seq 59: `aa0110000001e0d1233b17010000000000000000ed8d38cd`

**Never sent by Forma:**

- ABORT_HISTORICAL_TRANSMITS (20). The reference client never sends it.
- SET_CLOCK (10).
- Persistent sensor configuration (153/154). The reference client sends these automatically; goose's own command table classifies them as critical (goose:Rust/core/src/commands.rs:1018-1031).
- High-frequency sync (96/97), alarms and haptics (66–69).
- Anything classified as critical: firmware, reboot, trim, configuration.

## 5. History transfer (reference client order)

1. Write GET_DATA_RANGE. On "pending" keep waiting, 25 s per pending answer. On a refusal, a short answer or no answer within 7 s, retry, at most twice, 1 s apart (GooseBLEClient.swift:292-296; DebugAndSync.swift:432-471).
2. On success write SEND_HISTORICAL_DATA.
3. The band sends history start, data records on `…0005`, history end, possibly more chunks, then history complete.
4. The reference client acknowledges at each end marker without waiting for any database commit. Forma waits for a durable commit and, by default, does not acknowledge at all (see `docs/COMPATIBILITY.md`).

**Open:**

- Whether the band sends more than one chunk without acknowledgements.
- What the acknowledgement does to band storage.
- Whether a transfer ends with "complete" when nothing is acknowledged.

## 6. Record kinds Forma decodes

| Kind | Fields used | Confidence |
|---|---|---|
| K24, K9, K12 | Heart-rate candidate at byte 17 | real bytes for K24 (values 51 and 151). **Unvalidated**: 151 at rest is implausible |
| K18 | Heart-rate candidate at byte 14 | documented |
| K7 | Heart-rate candidate at byte 27 | documented |
| K10 | Heart-rate candidate at byte 17; byte 18 = 100 (sample count: **inferred** from the two published payloads — goose assumes a fixed 100 and never reads byte 18); accelerometer 100 × i16 per axis at 85 / 285 / 485 (gyroscope at 688 / 888 / 1088 is not used). A (0, 0, 0) vector is an absent sample, never stillness | real bytes (byte 17 = 135 in history, 150 in a live-labelled capture; in the one published history K10 the vector magnitude averages about 1,210 counts, range about 950–1,610, posture unknown). Scale and sample rate **open** |
| K21 | Header only; channel meaning unknown | real bytes |
| Type 52 | Header only | documented |

The record counter is shared across kinds: in one real capture K21 is 3861, K10 3863 and K24 3871. Byte 0 of the heart-rate field means "no reading".

## 7. Clock and events

- Data records carry band RTC Unix seconds. The sub-second field's unit is **open**: goose's Rust code treats it as milliseconds, while clock and alarm fields use 1/32768 s.
- Event ids used for clock discontinuities: 13 RTC_LOST, 15 BOOT, 16 SET_RTC (goose event table). Event 33 and 34 report real-time HR on and off.
- The reference client sets the band clock when it drifts more than 5 s. Forma never does.

## 8. Not established anywhere public

- Whether the vendor characteristics require pairing on 5.0.
- Whether `2A37` is active by default.
- Beat-to-beat intervals in the vendor protocol (K17 is a candidate with synthetic evidence only).
- Skin temperature, SpO2 and respiration fields.
- Behavior without an active membership.
