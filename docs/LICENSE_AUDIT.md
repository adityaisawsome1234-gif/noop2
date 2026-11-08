# License and provenance audit of public interoperability projects

**Audited:** 2026-11-08, from local clones at the pinned commits below. Read-only: no code from these projects was built, run or imported. Detailed notes with file:line citations are in `docs/research/`.

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

*Completed from the my-whoop extraction (`docs/research/`).*
