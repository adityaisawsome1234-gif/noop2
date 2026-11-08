# Privacy, storage and data portability

## What Forma stores, and where

All data lives in `Application Support/Forma/` inside Forma's app container on the iPhone. Nothing is sent anywhere. The app contains no networking code; `Tools/audit-no-network.sh` checks this statically.

| File | Contents |
|---|---|
| `forma.sqlite` (+ `-wal`, `-shm`) | Live data from your band, plus your sessions, corrections, settings and cached derived metrics |
| `forma-demo.sqlite` | Synthetic demo data. It is used only in Demo mode, labelled on every screen, and never mixed with live data. Exports and backups always contain live data only (also in Demo mode), and an import refuses any file that contains demo records |

Database tables (schema v2; full definitions in `FormaKit/Sources/FormaStore`):

| Table | Purpose |
|---|---|
| `device` | Bands you selected: local identifier, family, name, firmware |
| `ingest_batch` | Provenance of every batch of records: adapter, parser version, firmware, source, sync run |
| `hr_sample`, `beat_interval`, `motion_epoch`, `aux_measurement` | **Raw measurements** as decoded, each with its UTC time and quality flags. Heart-rate rows also keep the band's raw time, the phone's receive time and the clock correction; motion rows the band's raw time; beat intervals the receive time (details in `ARCHITECTURE.md` §3) |
| `raw_frame` | Optional raw bytes for diagnostics. Off by default and bounded by age, rows and bytes |
| `connection_event`, `sync_run`, `sync_cursor` | Connection history and history-sync progress |
| `session`, `user_correction` | Workouts and sleep windows, plus an audit trail of every edit |
| `derived_metric` | Cached **estimates**, kept separate from raw measurements. Recomputed after corrections, imports or newly stored records |
| `setting` | Profile (optional birth year, max and resting HR), preferences, history-sync choices and field-validation results |

## Protection on the device

- **Encryption at rest.** The folder and the database files use iOS Data Protection class *Complete Until First User Authentication*. After a restart the files stay encrypted and unreadable until you unlock the iPhone once. From then on they are readable while the phone is locked. That access is needed because iOS wakes Forma in the background to save Bluetooth data while the screen is locked.
- **App Lock** (optional, Settings → Privacy). Face ID or the passcode is required to view Forma. This is a privacy screen on top of the file encryption, not an additional encryption layer.
- **Logs.** Forma's logs contain no health values. Raw bytes are only stored in the opt-in diagnostics capture.

## Backups: local-only by default

- **Default.** The Forma folder is excluded from iCloud Backup and computer (Finder) backups. Forma re-applies the exclusion each time it opens the database. Apple documents exclusion as a hint rather than a guarantee, so Forma does not rely on it for anything else.
- **Consequence.** If you delete Forma, reset the iPhone, or move to a new iPhone without exporting, **your history is lost**. Whether excluded files survive a direct iPhone-to-iPhone transfer is not documented by Apple; assume they don't.
- **Opt in.** Settings → Data → Export, import and delete → *Include in iCloud and computer backups* removes the exclusion. Your health data then follows your normal iOS backups (for example to iCloud), under Apple's backup protections.

## Export and import (you choose the destination)

| Export | Format |
|---|---|
| CSV | One file per table (`hr_samples.csv`, `beat_intervals.csv`, `motion_epochs.csv`, `aux_measurements.csv`, `sessions.csv`, `derived_metrics.csv`, `devices.csv`), zipped. Header rows carry units. Timestamps are in UTC as both ISO 8601 and epoch ms. Unknown values are empty cells, never 0 |
| Backup | Versioned NDJSON (`forma-backup`, `formatVersion` 1). The first line is a header and each following line is one record; measurement lines also name the adapter and firmware that decoded them, so restored band history keeps its field-validation key. Forma writes the file as a stream and hands it to the save dialog memory-mapped instead of reading it into memory, so a long history does not have to fit in RAM (the CSV zip is handled the same way) |
| Diagnostics capture | `forma-capture` JSON Lines: raw bytes per notification and per command, with timestamps. It contains health data, so share it deliberately |

Importing a backup:

1. The header is validated. A backup from a newer, unknown format version is refused.
2. Every record is validated (types, ranges, finite numbers). Invalid lines are skipped and counted; the message after the import names the first three (line number and reason).
3. Records go in through the same deduplication keys as live data, so importing the same file twice adds nothing.
4. Sync cursors from a backup are **not** applied to your band's sync state. Another phone's cursor could make Forma skip history still stored on your band.
5. Choices only the person using this iPhone makes — band history download, the experimental history acknowledgement, unvalidated motion — and field-validation results are **never** applied from a backup. They are filtered out while the file is read, so not even an import that stops midway, or one run again, applies them. Other settings (profile, zone method, readiness) are added only where this iPhone has none.
6. Derived metrics for the imported period are recalculated. If an import stops midway (for example when storage is full), what it saved so far stays and every cached value is recalculated; importing the same file again is safe.

## Deletion

- **Delete all data** (Settings → Data → Export, import and delete) removes the live and demo database files — every table, including sessions, settings, the capture and the connection history — and starts with an empty database. It keeps the selected band (its name and identifier are written into the new database so Forma still recognises it; **Forget band** removes it) and the app preferences stored outside the database: appearance, App Lock, collection and live heart-rate choices, backup inclusion, raw-capture retention and onboarding state. None of these hold health data.
- **Forget band** stops Forma from connecting and keeps recorded data. It doesn't touch the iOS Bluetooth bond, which iOS manages in Settings → Bluetooth. If AccessorySetupKit is enabled, Forma still never calls the system-wide "remove accessory", because that could also unpair the band from the official app.

## Things Forma does not do

- No accounts, analytics, crash-reporting SDKs, ads or remote AI.
- No writing to Apple Health in v1. This is deferred until deduplication and validation rules exist.
- No sharing unless you export a file yourself.
