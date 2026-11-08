# Forma

A local-first iPhone app that reads **your own WHOOP band** directly over Bluetooth, keeps every measurement on your phone, and computes **transparent, independent** wellness estimates. There's no account, no server, no cloud and no telemetry.

> Forma is not affiliated with WHOOP, Inc. Its metrics are Forma's own documented estimates. They are not WHOOP Recovery, Strain or Sleep scores, and Forma isn't a medical device.

**Target:** iPhone 16 Pro on iOS 27 and a WHOOP 5.0 band. The app is native Swift 6, SwiftUI, Core Bluetooth and SQLite.

## Status

| Part | State |
|---|---|
| FormaKit (protocol, sync, storage, analytics, app model) | Implemented. Compiled and unit-tested with Swift 6.4.2 (see `docs/TEST_REPORT.md`) |
| WHOOP 5.0 decoding | Cross-checked against every real WHOOP 5.0 payload published by public research (`Tools/verify-published-captures.sh`). **Not yet run against your band** |
| iOS app (SwiftUI, Core Bluetooth) | Written and reviewed, **not yet compiled** (no Apple SDK in this build environment). Build in Xcode 27 |
| Hardware validation | Pending. Follow `docs/HARDWARE_VALIDATION_HANDOFF.md` |

## Repository layout

```
App/Forma/            iOS app target: SwiftUI views, Core Bluetooth, iOS platform services
FormaKit/             Swift package, platform-independent and tested on Linux and macOS
  FormaCore           shared value types (measurements, provenance, metric results)
  FormaProtocol       WHOOP 5.0 adapter, standard heart-rate adapter, command allowlist
  FormaSync           sync engine (owned transfers, durable save before any opt-in acknowledgement), clock mapping, captures, replay
  FormaStore          SQLite storage, migrations, export/import/backup/delete
  FormaAnalytics      metrics with specifications (HR, zones, RHR, RMSSD, trends, sleep, load, readiness)
  FormaFeatures       app model and screen state (used by the SwiftUI views)
  forma-replay        CLI: decode an exported capture offline
  forma-docs          CLI: render metric specifications from code
Forma.xcodeproj       Xcode project (folder-synchronized; regenerate from project.yml if needed)
Tools/                no-network audit, published-capture cross-check
docs/                 PRD, architecture, compatibility, methodology, privacy, build, tests, handoff
```

## Quick start

On a Mac with Xcode 27:

```bash
open Forma.xcodeproj
```

Set your Team and a unique bundle identifier, then run on your iPhone. See `docs/BUILD_AND_INSTALL.md` for signing (a free team re-signs every 7 days; the paid program lasts a year).

Core tests (macOS or Linux, Swift 6.4):

```bash
cd FormaKit && swift test
```

Static check that the app and package contain no networking code:

```bash
Tools/audit-no-network.sh
```

## Documents

| Document | What it covers |
|---|---|
| `docs/PRD.md` | Product requirements, constraints, phases and acceptance criteria |
| `docs/COMPATIBILITY.md` | Compatibility matrix: every data path with its evidence level |
| `docs/ARCHITECTURE.md` | Modules, data flow, time handling, storage, and iOS background rules |
| `docs/METHODOLOGY.md` | Exactly how every metric is computed, and its limits |
| `docs/PRIVACY_AND_DATA.md` | Storage, encryption at rest, backups, export, deletion |
| `docs/BUILD_AND_INSTALL.md` | Xcode, signing routes, Developer Mode, AccessorySetupKit |
| `docs/HARDWARE_TEST_CHECKLIST.md` | Tests to run on your band and phone |
| `docs/HARDWARE_VALIDATION_HANDOFF.md` | What to capture, what to send back, how open questions get resolved |
| `docs/KNOWN_LIMITATIONS.md` | What doesn't work or isn't verified yet |
| `docs/LICENSE_AUDIT.md` | Audit of the public interoperability projects. Forma reuses facts only, no code |
| `docs/research/WHOOP5_PROTOCOL.md` | The WHOOP 5.0 protocol facts Forma relies on, in its own words, with source citations and open questions |
| `docs/research/IOS_BLE_RULES.md` | Current iOS Core Bluetooth background, restoration and AccessorySetupKit rules |
| `docs/TEST_REPORT.md` | What was tested, how, and the results |

## License

No license has been chosen for Forma yet. All rights are reserved by the owner until one is added. Forma contains no third-party code (`THIRD_PARTY_NOTICES.md`).
