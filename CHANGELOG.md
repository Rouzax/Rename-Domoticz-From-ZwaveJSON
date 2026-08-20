# Changelog

All notable changes to this project are documented in this file.

## [2.11] - 2026-08-20

**Fixes a data-loss bug.** A DeviceID is not unique in Domoticz: a multi-unit device, most commonly a Central Scene remote, is stored as one DeviceID with several `Unit` rows. The tool read only one of those rows but wrote with `WHERE DeviceID = ...`, hitting all of them. If you had named the units individually, a rename silently collapsed every one of them to the same name, reported `Collisions: 0`, and wrote an undo statement that also matched on DeviceID alone, so the undo script overwrote all the rows with a single name rather than restoring the originals. The recovery path destroyed the evidence.

Such devices are now detected and skipped, because the tool cannot do better: one Z-Wave value yields one label, so there is no information available to give several units several names. They are reported on the console, in a **Skipped: ambiguous devices** section of the HTML report, and as an `Ambiguous` count in the summary that appears only when it is above zero. Collision detection also now treats every distinct name in `DeviceStatus` as taken, not just one name per DeviceID, closing a second hole where another device could be renamed onto a name held by a non-primary row.

Devices whose rows agree are unaffected and rename exactly as before.


**Documentation site**: the reference and task content moved out of the README into a Zensical site published at <https://rouzax.github.io/Rename-Domoticz-From-ZwaveJSON/>, and `readme.md` dropped from 616 lines to 78. Reading live from zwave-js-ui with `-ZwaveJsUrl` is now the documented primary route, with the JSON export presented as the alternative. Writing the pages against the script rather than the README surfaced several long-standing errors, now corrected: CustomImage value 9 was labelled "Fire" but is "Computer"; the SwitchType and CustomImage tables held only 7 of 21 and 3 of 7 rows; undo SQL is not written on dry runs or no-change runs while CSV is; an unresolvable collision drops every pending change for that device, not just the name; and `rename_rules.json` is loaded from the script's own directory, not the working directory.

**Runtime-only `dist` branch**: publishing a release now syncs a `dist` branch containing just the files needed to run the tool, so `git clone -b dist` and `git pull` skip the docs, tests and CI config. Installation covers both routes; neither the README nor the docs previously said how to obtain the files at all, they simply began at `setup.ps1`.

**Comment-based help**: removed a documented `-WhatIf` alias for `-DryRun` that never existed (no `[Alias]` attribute, no `SupportsShouldProcess`), and reordered the help so the preferred `-ZwaveJsUrl` route leads. Help text only; parameters and behaviour are unchanged, and `-JsonFile` remains the default parameter set so positional invocation still binds to it.

**Ko-fi support links**: added a Support section to the README and a `.github/FUNDING.yml` so GitHub can show a Sponsor button. Documentation only; running the script is unchanged, and it never prompts for anything.

## [2.10] - 2026-08-20

**The report now explains itself.** Two changes, both about making the rename list readable:

- **Full names in the HTML report.** The Name change previously showed only the text after the last `" - "` on each side of the arrow, so a device going from `Living Room-Lamp (Living Room - Lamp - Electric Consumption [W])` to `Living Room - Lamp [W] - EP0` rendered as `Electric Consumption [W]) → EP0`, which reads as if the device is being renamed to `EP0`. Both names are now shown in full, long names wrap, and the collapsed header carries the full new name as a tooltip.
- **Collisions say who is to blame.** Auto-resolved collisions were counted but never reported, so an endpoint suffix appeared in the rename list with nothing anywhere explaining it. The report gained a **Names Disambiguated** section naming, for each collision, the device that wanted the name and the device holding it, whether the node source still reports that device, and its `Used` flag and `LastUpdate`. A device that Domoticz kept after a Z-Wave value moved endpoint (or disappeared) still owns its name and blocks the live device; that is now called out on the console and in the report, with the fix (delete the stale device and re-run). Unresolvable collisions gained the same detail.

Note that "not in node source" is a strong hint, not proof: zwave-js only creates notification, battery and smoke sub-values once a node first reports them, so a healthy but quiet device can be absent. `Used` and `LastUpdate` are shown alongside so the call stays yours.

Internally, `DeviceStatus` is now read with `Used` and `LastUpdate` in addition to the existing columns. Both are standard Domoticz columns and are used only for reporting; nothing about which devices get renamed has changed.

## [2.9] - 2026-07-09

**Node-level device renaming**: the tool now also renames the node-level device Domoticz creates for a node (for example the combined Temp+Humidity device it builds from a multisensor, Domoticz Type 82/84), which has no Z-Wave value behind it and was previously never matched. These become `{location} - {name} - Climate` for Temp+Humidity (and Temp+Humidity+Baro) devices, and `{location} - {name}` for any other node-level device. It runs through the normal dry-run, rules, and collision detection, and can be excluded with `-ExcludePattern 'node\d+$'`.

## [2.8.1] - 2026-07-09

**`-ZwaveJsToken` over http**: the token is now allowed over `http://` with a cleartext warning instead of being refused. A zwave-js-ui instance is usually on a trusted LAN or localhost, so the previous https-only requirement was too strict. `https://` is still recommended on untrusted networks. The token stays in the connect payload and is never logged.

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
