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
(CoreBluetoothLink                               │  per-characteristic FrameAssembler (adapter codec)
 or ReplayLink)                                  │  adapter decoder → DecodedEvent
                                                 │  ClockMapper: device time → UTC, flags
                                                 │  Normalizer → FormaCore records (+ provenance)
                                                 ▼
                                          IngestSink.ingest(batch)   ← one SQLite transaction
                                                 │
                                   (only after success) history acknowledgement command
```

- **Same code path.** `CoreBluetoothLink` (app) and `ReplayLink` (FormaSync, fed by a `CaptureFile`) implement the same `PeripheralLink` protocol. Tests, the `forma-replay` CLI and the app all run the identical `SyncEngine` → adapter → normalizer → `IngestSink` pipeline.
- **Persist before acknowledge.** History acknowledgements that may advance or discard the band's stored history are sent only after `IngestSink.ingest` returns. If persistence throws, no acknowledgement is sent. The band keeps the data and the next sync re-requests it, and the dedup keys absorb any repeat.
- **Dedup keys** (unique indexes, `INSERT OR IGNORE`):
  - HR: `(device, source, ts)`
  - Beat intervals: `(device, source, record_key, index)`
  - Motion: `(device, source, ts, epoch)`
  - Aux: `(device, source, kind, ts)`

  Re-downloads, overlapping live and history data, and re-imported backups therefore never duplicate. Live and history samples for the same moment are kept as separate sources, and analytics pick the canonical series (band history wins).
- **Provenance.** Every record references an `ingest_batch` row with the adapter ID, parser version, firmware, source and sync run. Each record keeps its raw device time, phone receive time, applied clock offset and quality flags.

## 2. Protocol layer and device adapters

- `FrameAssembler<Codec>` reassembles frames across BLE notifications, one assembler per characteristic. It validates header and payload checksums, resyncs after garbage, bounds its buffer and reports malformed or discarded bytes instead of throwing them away silently.
- A `DeviceAdapter` holds everything family-specific:
  - the GATT profile (service and characteristic UUIDs and roles)
  - the frame codec
  - the decoder (bytes → `DecodedEvent`)
  - the command encoder

  Adding WHOOP 4.0 or another band means adding an adapter. Nothing else changes.
- **Command allowlist.** Commands are an `enum AllowedCommand` that can only express verified read, stream-toggle and acknowledge operations. Reset, reboot, erase, firmware/DFU, haptics, config writes and clock writes are **not representable**. Each adapter also keeps a runtime set of commands verified for its firmware. Every command written is logged to the diagnostics capture.
- **Unknown or malformed data.** Unknown packet types are surfaced as `DecodedEvent.unknown` and counted, and are kept as raw evidence when capture is enabled. Malformed frames are rejected without crashing. Decoded fields whose meaning is unvalidated are stored with `validated = false` and never shown as health values.

## 3. Time

- Every stored record carries **source time** (raw device clock value), **receive time** (phone clock) and the **normalized UTC timestamp**, plus the clock offset applied.
- `ClockMapper` builds the device→UTC mapping from clock reads and packet timestamps, and flags records:
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
- **State restoration.** There is one `CBCentralManager`, created at process start with a constant restore identifier. iOS 27 SDK apps must use the scene life cycle, where launch options are `nil`, so the identifier is never read from launch options. `willRestoreState` re-attaches delegates and reuses already-discovered characteristics.
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
