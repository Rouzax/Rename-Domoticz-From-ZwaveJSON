# Changelog

All notable changes to this project are documented in this file.

## [2.8] - 2026-07-09

**Read directly from zwave-js-ui**: new `-ZwaveJsUrl` mode fetches node data live over zwave-js-ui's socket.io API (engine.io v4 WebSocket, no dependency), so a manual `nodes_dump.json` export is no longer required. `-ZwaveJsToken` supports authenticated instances (https only); `-SkipCertificateCheck` for self-signed HTTPS. Read-only; the fetch runs before any backup so a failure changes nothing.

## [2.7]

**ARM / Raspberry Pi support**: replaced the PSSQLite module with Microsoft.Data.Sqlite + SQLitePCLRaw, provisioned by a new pinned, checksum-verified `setup.ps1` that selects the native SQLite for your platform (`linux-arm64`, `linux-arm`, `linux-x64`, `win-x64`, `osx-arm64`, ...). Extracted the data layer into a `DomoticzSqlite` module with Pester tests. **Cross-platform database-in-use detection** (Linux `/proc` scan, Windows exclusive-open, macOS `lsof`) replaces the previous Windows-only lock check and names the holding process. **Collision detection** now checks a proposed name against the full end state (including devices that keep their name), so it can no longer silently create a duplicate.

## [2.6] - 2026-05-30

**Node-scoped rules**: New optional `nodeMatch` field lets rules target specific device types by matching Z-Wave node properties (`productLabel`, `productDescription`, `manufacturer`). Added RGBW color channel rules for Fibaro FGRGBW-442 using `nodeMatch` to avoid affecting regular dimmers.

## [2.5] - 2026-05-30

**UX improvements**: Summary box fields now display in consistent order. Log file defaults to DB folder with timestamp (matching other output files). Malformed rules files now error instead of silently falling back to defaults. `rename_rules.json` is auto-loaded from script directory when present (29 rules vs 7 built-in). Exit code now considers TypeChanged/ImageChanged. Removed non-actionable "Missing" count from summary. Consolidated MISSING log entries into one summary line. Confirmation prompt now shows actual change counts after analysis.

## [2.4]

**Collision auto-resolution**: Multi-endpoint collisions are now resolved automatically by appending endpoint numbers (EP2, EP3, etc.) instead of being skipped. **Robustness fixes**: Cross-platform temp directory support (Linux/macOS), removed WhatIf parameter (use DryRun instead), early ExcludePattern regex validation, transaction failure reporting, explicit error handling on all database calls.

## [2.3]

**HTML report now default**: Interactive HTML report generated automatically in DB folder. **CSV now optional**: Only generated when `-CsvFile` is specified. **Improved HTML readability**: Device cards now show sensor type suffix (e.g., "› Heat Alarm") for easy identification; human-readable SwitchType/CustomImage descriptions; search and filter functionality.

## [2.2]

**ImageChanged tracking**: Now shows CustomImage changes separately in stats and reports.

## [2.1]

**SwitchType/CustomImage support**: Rules can now optionally set `switchType` and `customImage` to configure correct device types (e.g., Smoke Detector with Reset button, Motion Sensor, Door Contact).

## [2.0]

Major rewrite: DryRun mode, external rules config, exclusions, collision detection, undo scripts, HTML reports, ETA progress, exit codes, database lock detection, backup verification.

## [1.7]

Atomic transactions, fallback paths, whitespace normalization.

## [1.0]

Initial release.
