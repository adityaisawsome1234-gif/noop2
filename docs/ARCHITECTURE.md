# Forma architecture

Forma is one iOS app target on top of one Swift package, **FormaKit**. Everything that can be platform-independent lives in FormaKit and is compiled and unit-tested on Linux and macOS. The app target adds only what needs Apple frameworks: SwiftUI views, Core Bluetooth, file protection, LocalAuthentication and Swift Charts.

```
┌──────────────────────────── iOS app target (App/Forma) ────────────────────────────┐
│ SwiftUI views (Today · Sleep · Activity · Trends · Device/Diagnostics · Settings)  │
│ AppModel (@MainActor) — composition root, dependency injection, live vs demo store │
│ BLE: CentralController (CBCentralManager, restoration, scan/connect/backoff)       │
│      CoreBluetoothLink (implements PeripheralLink for one peripheral)              │
│ Platform: StorageLocation (file protection, backup exclusion), AppLock             │
└───────────────┬────────────────────────────────────────────────────────────────────┘
                │ imports
┌───────────────▼──────────────────────── FormaKit (Swift package) ───────────────────┐
│ FormaFeatures  screen-state logic, coverage timeline, demo generator, formatting     │
│ FormaSync      SyncEngine (persist-before-ack), clock mapping, capture files, replay │
│ FormaProtocol  bytes, CRCs, frame reassembly, device adapters, command allowlist,    │
│                Bluetooth SIG Heart Rate Service parser                               │
│ FormaStore     SQLite wrapper, migrations, ingest (atomic, dedup), queries,          │
│                export (CSV/NDJSON backup), import, delete                            │
│ FormaAnalytics HR series/coverage, zones, workouts, RHR, RMSSD, trends, baselines,   │
│                sleep candidates, Edwards TRIMP, experimental readiness, MetricCatalog│
│ FormaCore      value types shared by all modules (no logic beyond invariants)        │
└──────────────────────────────────────────────────────────────────────────────────────┘
```

Dependency rules, enforced by `Package.swift`:

- `FormaCore` depends on nothing.
- `FormaProtocol`, `FormaAnalytics` and `FormaStore` depend only on `FormaCore`.
- `FormaSync` depends on `FormaCore` and `FormaProtocol`. It persists through the `IngestSink` protocol from `FormaCore` and never imports `FormaStore`.
- `FormaFeatures` composes everything for the UI. The app target is the only place that touches Core Bluetooth.

## 1. Data flow: one pipeline for live and replay

```
BLE notification ──► PeripheralLink.events ──► SyncEngine
(CoreBluetoothLink                               │  adapter decoder: per-characteristic frame reassembly → DecodedEvent
 or ReplayLink)                                  │  ClockMapper: device time → UTC, flags
                                                 │  normalize → FormaCore records (+ provenance)
                                                 ▼
                                          IngestSink.ingest(batch)   ← one SQLite transaction
                                                 │
                                          IngestSink.ensureDurable() ← WAL checkpoint with full fsync
                                                 │
                   (only if enabled, and only for an intact chunk) history acknowledgement command
```

- **Same code path.** `CoreBluetoothLink` (app) and `ReplayLink` (FormaSync, fed by a `CaptureFile`) implement the same `PeripheralLink` protocol. Tests, the `forma-replay` CLI and the app all run the identical `SyncEngine` → adapter → normalizer → `IngestSink` pipeline.
- **Persist before acknowledge.** History acknowledgements that may advance or discard the band's stored history are sent only after `IngestSink.ingest` returned and `IngestSink.ensureDurable()` returned. If either throws, no acknowledgement is sent. The band keeps the data and the next sync re-requests it, and the dedup keys absorb any repeat.
- **Durability.** `ensureDurable()` has no default: every sink must implement it. `FormaStore` commits band-history and cursor batches with `synchronous=FULL`. Its `ensureDurable()` then runs a full WAL checkpoint with `checkpoint_fullfsync` (on Apple platforms that is `F_FULLFSYNC`, which also flushes the drive cache), and throws if the checkpoint cannot complete. The app's sink wrapper forwards the call inside its protected-execution window. An acknowledgement is therefore sent only for data that survives power loss.
- **History transfers are owned.** The engine acts only on a transfer it requested, in this order: read the band clock (wait up to 7 s for the answer; after a clock event, for the fresh reading), read the history range (cmd 34; wait for an explicit success, 25 s more on each "pending", two retries), then request history (cmd 22; anything but an explicit success, including the contested 0, fails the transfer). Records and markers that arrive outside such a transfer (for example when another app on the same phone syncs) are saved if history is enabled, but never acknowledged, never counted in a chunk and never move Forma's sync cursor; a failed save of such records is retried, because the other app may acknowledge them.
- **Re-entrancy.** Settings, "Sync now" and the timer run on the engine actor while it waits for a write (an acknowledgement can take up to the 30 s ATT timeout). Every transfer start and end bumps a generation number; work resumed after a write re-checks it, so a write that returns never revives an ended transfer, overwrites a newer transfer's state or acknowledges for it. A chunk is closed before its acknowledgement is written. Command sequences are registered before the write, the clock read is marked outstanding before it is written (one read at a time), and the real-time toggle re-reads the setting after every write.
- **When a chunk may be acknowledged.** Acknowledgements are off by default (`SyncOptions.acknowledgeHistory`). When on, a chunk is acknowledged only if its start marker was seen; no frame on a vendor characteristic (declared by the adapter, `GATTProfile.framedCharacteristics`) was malformed, truncated, left partial or lost by the link (`LinkEvent.gap`) while it was open; no frame inside it was of a type Forma does not decode (unknown packet or metadata types, events — they may be stored band data); every record was fully decoded (`HistoryRecord.contentDecoded`: a known kind with every field Forma reads present and understood) and had a mappable time; no two records of the transfer mapped to the same stored time (the store would keep only one); and the save and the sink's durability call succeeded. The first failing chunk blocks acknowledgements for the rest of that transfer. Acknowledgements also stop, without affecting what was saved, when the band's clock changes during the transfer, a history-command answer echoes a sequence Forma did not send (another app may be driving the band's history), or the band refuses an acknowledgement. Forma never sends an abort.
- **Timeouts.** A timer task enforces command, pending and idle deadlines against the engine's clock: the later of the time source and the newest receive time (receive times more than a day ahead of the time source are ignored), each made monotonic so a phone clock set back pauses the clock instead of freezing every timeout until it catches up. Deadlines are also checked before each notification is handled, so a replayed capture with a manual time source reproduces a silent band: an answer or chunk that arrives after its deadline is judged as the live timer would have judged it. Option durations are clamped to 1 h and deadline arithmetic saturates. A transfer that goes quiet after some chunks ends as *interrupted*, never as *complete*. `lastCompleteSyncAt` is written only when the band's completion marker arrived, every chunk was saved intact, and nothing in the transfer arrived damaged, lost or incomplete (also between chunks).
- **Dedup keys** (unique indexes, `INSERT OR IGNORE`):
  - HR: `(device, source, ts)`
  - Beat intervals: `(device, source, record_key, index)`
  - Motion: `(device, source, ts, epoch)`
  - Aux: `(device, source, kind, ts)`

  Re-downloads, overlapping live and history data, and re-imported backups therefore never duplicate, as long as a re-sent band record maps to the same time. The engine helps by rounding clock corrections to whole seconds measured with the band's sub-second field, so a steady band clock gives the same correction on every connection. **Known limitation (store):** when the correction really changes between downloads (the band clock drifted across a half second, or was set) a re-sent record maps to a new time and is stored again; keying band-history rows on their raw device time in `FormaStore` is the fix. Within one transfer the engine detects distinct records that would collapse onto one row and does not acknowledge their chunk. Live and history samples for the same moment are kept as separate sources, and analytics pick the canonical series (band history wins).
- **Provenance.** Every record references an `ingest_batch` row with the adapter ID, parser version, firmware, source and sync run. Each record keeps its raw device time, phone receive time, applied clock offset and quality flags.

## 2. Protocol layer and device adapters

- Each adapter's decoder reassembles frames across BLE notifications, one reassembler per characteristic (WHOOP 5.0: `Whoop5Deframer`). It validates the header checksum before trusting a length, then the payload checksum. On a failure it drops only the start byte and rescans, so genuine frames inside a bogus or truncated span are recovered. A frame still arriving is abandoned as soon as a complete valid frame appears inside its span. Each frame keeps the receive time of the notification that carried its first byte. Malformed or discarded bytes are reported, never silently dropped. Work is linear in the bytes received on any input (each position is examined once; payload checksums come from running prefix checksums). The outcome does not depend on how notifications split the stream, with one documented exception: a checksum-valid frame nested inside another checksum-valid frame can make the outer frame look truncated when the split delivers the inner one first; the outer frame is then reported as malformed and the inner one delivered.
- A `DeviceAdapter` holds everything family-specific:
  - the GATT profile (service and characteristic UUIDs and roles)
  - the frame codec
  - the decoder (bytes → `DecodedEvent`)
  - the command encoder

  Adding WHOOP 4.0 or another band means adding an adapter. Nothing else changes.
- **Command allowlist.** Commands are an `enum AllowedCommand` that can only express read, stream-toggle, history request and acknowledge operations. Reset, reboot, erase, firmware/DFU, haptics, config writes and clock writes are **not representable**. Each adapter declares which of them it supports (`supports(_:)`). Its `encode` returns an `EncodedCommand`, which only code inside FormaProtocol can create, and `PeripheralLink.write` accepts nothing else. So no module can push hand-built bytes to a band. Every successful write is logged to the diagnostics capture, and failed writes are logged as failures.
- **Unknown or malformed data.** Unknown packet types are surfaced as `DecodedEvent.unknownPacket` and counted; inside a history chunk they make it ineligible for acknowledgement. With capture enabled, notifications that produced unknown, malformed or discarded bytes are also kept in the bounded raw-frame table. Malformed frames are rejected without crashing. Decoded fields whose meaning is unvalidated carry the `unvalidatedField` quality flag and are never shown as health values. Device-information strings are reduced to printable ASCII with visible `\xNN` escapes (never deleted, so distinct values never merge); an empty or unprintable value is reported as malformed.

## 3. Time

- Every stored record carries **source time** (raw device clock value), **receive time** (phone clock) and the **normalized UTC timestamp**, plus the clock offset applied.
- `ClockMapper` builds the device→UTC mapping from clock reads (GET_CLOCK, once per connection and after clock events; history waits for the fresh reading). Offsets are measured with the band's sub-second field when its unit is known and the engine rounds the applied correction to whole seconds. Offsets within 2 s are ignored; larger offsets up to 24 h are applied. A band clock before 2020 or off by more than 24 h makes every record unmappable (left on the band), because Forma never sets the clock. A transfer's records use the mapping in force when history was requested: a clock event during the transfer flags them and stops acknowledgements instead of shifting the rest of the transfer, and a first reading that arrives only after history started is used from then on (flagged, acknowledgements stopped). The plausibility bound ("phone now + 1 day") is taken at each record's receive time, so a replay judges a record as the live engine did. It flags records:
  - `.clockOffsetApplied` when an offset was used
  - `.nearClockDiscontinuity` near jumps, resets or reboots
  - `.clockUnmapped` when the mapping is uncertain (such records are excluded from analytics)
- Historical samples are **never** timestamped by arrival time. Standard HR service data, which carries no timestamps, is marked `.phoneReceiveTime`.
- Day boundaries use the phone's current calendar and time zone at analysis time. Stored timestamps are always UTC.

## 4. Storage

- One SQLite database per mode: `forma.sqlite` (live) and `forma-demo.sqlite` (demo), both in `Application Support/Forma/`. The two never mix.
- Settings: WAL, `foreign_keys`, `busy_timeout`, `synchronous=NORMAL`. Migrations are versioned through `PRAGMA user_version`. A newer-than-known schema refuses to open instead of downgrading.
- All access goes through one serialized connection, which is fine at these data rates: about 1 Hz HR and roughly 1–2 beat intervals per second. Ingest is a single transaction per batch.
- **Protection.** The directory is created with `NSFileProtectionCompleteUntilFirstUserAuthentication`, so the WAL and SHM side files inherit it. Background BLE events can then write while the phone is locked, and the data stays encrypted until the first unlock after boot.
- **Backups.** Excluded from backups by default (`isExcludedFromBackup`), with a user opt-in in Settings.
- **Raw frames.** Opt-in diagnostics only, bounded by age, rows and bytes.

## 5. Analytics

Pure functions over FormaCore values. Each result is a `MetricValue` carrying:

- value, or `nil` (never 0)
- `Availability` reason
- coverage and confidence
- window
- spec ID and version
- inputs used

`MetricCatalog` holds a `MetricSpec` per metric (inputs, gates, method, windowing, units, baseline, limitations, references), and the Methodology screen renders it directly. Corrections (sleep window edits) and imports invalidate derived-metric cache rows whose windows overlap, and those rows recompute on next view.

## 6. Presentation

- `AppModel` (`@MainActor`, `@Observable`) is the composition root. It owns the active store (live or demo), the central controller, the sync engine and settings. It exposes a `ConnectionSummary`, which keeps link state, last device sample and last sync separate.
- Screen models in `FormaFeatures` compute display state from the store and analytics. They are testable off-device, and SwiftUI views are thin renderers.
- Every card renders from `Availability`, so these states all have explicit copy: disconnected, syncing, partial, calibrating, insufficient quality, unsupported sensor, empty and error.

## 7. Background operation on iOS 27: what is and is not guaranteed

The primary sources are Apple's TN3115 (revised 2025-09-15 for iOS 26), the Core Bluetooth background guide, the AccessorySetupKit documentation and WWDC24 10203, the Accessory Design Guidelines (R32 Update 1), and Apple-staff forum answers from 2025–2026. The full notes with quotes and URLs are in `docs/research/IOS_BLE_RULES.md`.

**What Forma relies on**
- **`bluetooth-central` mode.** Subscribed notifications, connects and disconnects wake a suspended Forma. Each wake has about 10 s of runtime. Forma parses the frames, commits one short SQLite transaction inside `beginBackgroundTask`, and returns. This avoids `0xdead10cc` kills from locks held during suspension. Analytics never run on a background wake.
- **Pending `connect()` never times out.** After any disconnect, Forma immediately calls `connect()` again on the remembered peripheral, so iOS reconnects when the band comes back into range. At launch Forma first uses `retrievePeripherals(withIdentifiers:)`. It also uses `retrieveConnectedPeripherals(withServices:)`, which finds the band when another app, such as the official app, already holds the link.
- **State restoration.** There is one `CBCentralManager`, created at process start with a constant restore identifier, with one exception. On a first launch, while Bluetooth permission is still undetermined, it is created only when onboarding asks for it, so the permission prompt never appears before the explanation. iOS 27 SDK apps must use the scene life cycle, where launch options are `nil`, so the identifier is never read from launch options. On restoration:
  - `willRestoreState` adopts only the saved band; any other restored peripheral is cancelled.
  - It re-attaches delegates and reuses already-discovered characteristics.
  - Notifications that arrive before the link exists are buffered, not dropped.
  - A scan iOS restored is stopped.
  - Setup completes when Bluetooth reports powered on, without waiting for the model.
- **Bluetooth power and bonds.** In any state other than powered on or off (for example `.resetting`), every peripheral object is treated as invalid and the band is retrieved again once powered on. A lost bond (`peerRemovedPairingInformation`) is reported once, and reconnecting pauses until the user acts.
- **Reconnect backoff.** The wait between attempts holds a protected background-execution assertion. If iOS refuses or ends it, the pending connect is issued at once, so a suspended Forma always has a connect pending. A connection that does not stay up for 30 s counts as a failure, so a band that drops during setup cannot cause a hot reconnect loop.
- **Link buffering.** Each connection's event stream holds at most 10,000 events and keeps the oldest. On overflow the stream ends, the engine sees a gap-free prefix followed by a disconnect (nothing is acknowledged), and the connection restarts as a failure. Command writes go through one ordered channel per connection, with flow control for writes without response.
- **Background wakes.** A Bluetooth relaunch starts Forma in the background. The model is told before its first refresh and computes no screens until the scene is active. The engine keeps saving what the band sends.
- **Background scanning.** It only works with a service-UUID filter, and only on UUIDs in the primary advertising PDU. Forma prefers pending connects over scanning. It scans only in the foreground during device selection, filtered and time-boxed.

**When iOS relaunches a terminated Forma (TN3115)**

| Situation | Relaunched? |
|---|---|
| Removed from memory / crashed | Yes, if a connect, notification or scan was pending |
| Device restarted | Yes, but **only after the first unlock** when a passcode is set |
| Airplane Mode toggled | Yes, unless Airplane Mode also turns Bluetooth off |
| Bluetooth toggled in **Settings** | **No**. Open Forma again |
| **Force-quit by the user** (swiped away) | **No** for plain Core Bluetooth apps. iOS 26+ relaunches only apps that set the accessory up with **AccessorySetupKit**, and field reports about that are mixed |
| Control Center Bluetooth button | Per TN3115 note 5, guaranteed only for AccessorySetupKit apps on iOS 26+ |
| App update, Low Power Mode, permission revoked | Not documented. Treat as **not guaranteed**. Forma records these states next to gaps |

**AccessorySetupKit (ASK) decision.** ASK gives per-accessory consent and is the documented way to survive force-quit on iOS 26+. However, Apple staff state that ASK and generic Core Bluetooth use are mutually exclusive within an app. ASK also needs the band to advertise a matching service UUID or company identifier in its primary advertising packet, and that is not yet verified for WHOOP 5.0. So **v1 ships with plain Core Bluetooth**, and the diagnostics screen records the band's advertisement (service UUIDs, manufacturer data, company ID, name). With those values, ASK can be turned on through Info.plist keys (`NSAccessorySetupKitSupports` and friends). `docs/BUILD_AND_INSTALL.md` describes that step. Forma never calls `removeAccessory`, because that would unpair the band system-wide, including from the official app.

**Bonding.** Bonds are system-level: an app cannot unpair, and an existing bond made by the official app is expected to be reused. If the band demands pairing, the first subscribe happens in the foreground so the system prompt can appear. `insufficientAuthentication` or `insufficientEncryption` responses are reported as "pairing needed or declined", and Forma never works around them.

**Coexistence.** Several apps can hold the same peripheral at once. Whether the band tolerates two GATT clients sending commands, especially during a history transfer, must be verified on hardware (`HARDWARE_TEST_CHECKLIST.md` T11).

**What this means for coverage.** Gaps from disconnects, force-quits or Bluetooth toggles are recovered from the band's own history on the next sync, **if** the band still holds it. The coverage timeline marks such periods "pending sync" until then, and "not recorded" once a sync has passed them.

## 8. Testing strategy

| Layer | How it is tested here |
|---|---|
| Bytes/CRC/framing | Catalogue CRC check values, every-byte split points, garbage/corruption resync, seeded fuzz |
| Adapters | Synthetic frames built from the verified spec, and an out-of-repo check against published third-party captures (`Tools/verify-published-captures.sh`) |
| Sync engine | `ReplayLink` scripts: interruption mid-transfer, persistence failure (no ack sent), repeated downloads, out-of-order and partial frames, sequence wraparound |
| Store | Atomicity, dedup, migrations, retention, export/import round trips, malformed backups |
| Analytics | Hand-computed examples, artifact injection, gap handling, threshold boundaries, invariants |
| Features | Coverage timeline, connection summary, demo generator, screen-state models |
| App (iOS) | SwiftUI previews for every state. Device tests follow `HARDWARE_TEST_CHECKLIST.md` |
