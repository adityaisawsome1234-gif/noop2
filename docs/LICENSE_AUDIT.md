# License and provenance audit of public interoperability projects

**Audited:** 2026-11-08, from local clones at the pinned commits below. Read-only: no code from these projects was built, run or imported. The facts Forma uses, each with a file:line citation, are restated in Forma's own words in `docs/research/WHOOP5_PROTOCOL.md`.

**Result:** Forma contains **no code** from any of these projects. Forma uses only interoperability **facts** described by the sources: identifiers, frame layouts, checksum parameters, command numbers, byte offsets and observed bytes on the wire. Facts are not copyrightable. All parsing, sync, storage, analytics and UI code in Forma is original. The test vectors in Forma's suite are frames that Forma's own builder derives from the documented algorithm. Published third-party captures are only fetched at run time by `Tools/verify-published-captures.sh`; they are never committed.

*This is an engineering audit, not legal advice.*

## Summary

| Project | Commit (date) | License found | What exists (verified from the tree) | Forma's use |
|---|---|---|---|---|
| **b-nnett/goose** | `ba9ae0280c9b5b9a1545baab8e944cb3b7563c62` (2026-06-02) | **None.** `Rust/core/Cargo.toml` says `license = "UNLICENSED"`, and there is no LICENSE file anywhere in the history | Rust protocol, validation and metrics core, plus an **alpha iOS app (GooseSwift) for WHOOP 5.0**. The README says it is "not ready to use as an app for tracking personal health data yet". It includes a remote AI coach (OpenAI/ChatGPT OAuth) | **Facts only**: the WHOOP 5.0 GATT table, frame format, CRC parameters, command numbers, metadata kinds, ack token rule, and record offsets (K24/K10/K21). No code. Its 7 real payload captures are cross-checked at run time, not copied |
| **muftiarfan/noop** | `7be90e0af86ba2c6545dbf7d051bacd370350c67` (2026-06-07) | **None** (only the Gradle wrapper's own Apache-2.0 header) | A stale 3-commit snapshot of wwsqhf/Whoop (same author, identical tree at that commit). macOS app "Strand" and an Android app (its README calls the Android app full, but its own docs say it was "not compiled or device-tested"). **iOS: no target, plan only.** WHOOP 5.0 support is framing only, explicitly "NOT verified on real MG hardware". Optional AI coach that calls OpenAI/Anthropic APIs | Platform-status check only. Its WHOOP 5.0 facts are ported from goose, so they add no independent evidence. No code |
| **wwsqhf/Whoop** | `0ef0a96f38ecd36843bbde8cc7efad698fcd9ec0` (2026-06-07) | **None** | The same project as noop, 17 commits newer. It adds an experimental WHOOP 5.0 connect (hello plus standard HR) | As noop: facts cross-check only |
| **andyguzmaneth/whoop4-ble** | `a76ad4576bda9ec76cc6347ff9ad18fbcad1cd88` (2026-05-11) | **MIT**, Copyright (c) 2026 Andy Guzman | Python library for **WHOOP 4.0** | WHOOP 4.0 facts for the compatibility matrix only. No code is used. If WHOOP 4.0 support is added later, the MIT license would allow reuse with attribution |
| **johnmiddleton12/my-whoop** | `890e0c96beb817ab0cec3aaf7d9a06c530025355` (2026-05-30) | See the my-whoop section below | WHOOP 4.0 reverse engineering, an iOS collector and a server | WHOOP 4.0 facts only |
| bWanShiTong/openwhoop | `55c5c1e2…` (cited by goose) | goose states that this snapshot had **no license file** | Original source of the GATT table and history flow according to goose | Not consulted directly |

## Notes that affect Forma

1. **Provenance of WHOOP 5.0 facts.** goose attributes several record offsets to decompiled classes of the official WHOOP Android app, and states that its command evidence came from making the official app talk to a peripheral emulator. Forma did neither. It relies only on the published facts and verifies them against its own decoding of published payloads. Whether reverse engineering for interoperability is permitted depends on the jurisdiction; the projects cite 17 U.S.C. §1201(f).
2. **No independent second source for WHOOP 5.0.** noop and wwsqhf port their WHOOP 5.0 facts from goose. The GooseSwift app uses goose's own Rust core. Agreement among them is therefore **not** independent confirmation. Forma's own checks are the catalogue CRCs, frames re-derived byte for byte, and decoding of the real payloads. They show the framing and offsets are self-consistent and match real bytes. They don't prove the meaning of fields. That is why Forma's field validation exists.
3. **No existing iPhone app could be reused.** goose's iOS app is unlicensed and alpha, and noop has no iOS target. A native implementation was the only licensed path.
4. **Behaviors deliberately not copied:**
   - goose acknowledges history without waiting for a database commit, and sends persistent-configuration commands (153/154) automatically. Forma persists before acknowledging and never sends configuration commands.
   - goose exposes a URL scheme that can send BLE commands without confirmation. Forma has no URL scheme.
5. **Device imagery** in goose appears to be WHOOP product photography. Forma uses only its own original icon and SF Symbols.

## my-whoop

`johnmiddleton12/my-whoop` at `890e0c96beb817ab0cec3aaf7d9a06c530025355` (2026-05-30). The history is a single squashed commit.

- **License: none.**
  - There is no LICENSE, COPYING or NOTICE file, no SPDX tag and no copyright header.
  - The Swift packages and the Python `pyproject.toml` declare no license.
  - The README calls the project "open-source", but the repository grants no license, and the disclaimer limits it to personal and educational use.
  - So all rights are reserved: Forma may record facts from it and must not reuse its code.
- **Provenance concerns.**
  - The README says its HRV and strain modules were "ported" from `bWanShiTong/openwhoop-algos`, while one source file calls its strain code an independent implementation.
  - Its `.gitignore` excludes a decompiled official-app directory, so some of its facts trace back to the official Android app.
- **What it covers.** WHOOP **4.0** only (the README says other generations use different protocols): reverse-engineering notes, an iOS collector and a server.
- **Forma's use.** WHOOP 4.0 facts for the compatibility matrix only. Nothing from it is used in the WHOOP 5.0 adapter. No code, no algorithms. Forma's analytics are its own published methods (`METHODOLOGY.md`).

## whoop4-ble

`andyguzmaneth/whoop4-ble` at `a76ad4576bda9ec76cc6347ff9ad18fbcad1cd88` (2026-05-11).

- **License: MIT**, "Copyright (c) 2026 Andy Guzman". The `LICENSE` file and `pyproject.toml` agree.
- Its runtime dependencies (bleak, websockets, and Chart.js loaded from a CDN) state no license in the repository. Forma needs none of them.
- **Forma's use.** WHOOP 4.0 facts only (framing and CRC parameters for the compatibility matrix). No code is included. If a WHOOP 4.0 adapter is ever written from it, the MIT terms allow reuse provided the copyright and permission notice is kept in `THIRD_PARTY_NOTICES.md`.

## How this audit was done

- Each repository was cloned at the commit above.
- Its license files, package manifests and README were read directly, and the git history was inspected.
- Every protocol fact Forma uses was traced to a file and line (see `docs/research/`).
- Forma's implementation was written from those facts, then checked against real published payloads (`Tools/verify-published-captures.sh`) and independently re-derived frames. Nothing was copied.
