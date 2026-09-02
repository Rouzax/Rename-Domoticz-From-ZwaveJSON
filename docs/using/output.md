# Understanding the output

Every run writes a handful of files so you can see what happened, or undo
it, after the fact. This page covers each one: when it is written, where it
lands, and whether it is always generated or something you opt into.

## Where files land

The log, HTML report, and undo SQL script each try up to three locations,
in order, and use the first one that succeeds:

1. **The path you gave it**, if you passed `-LogFile`, `-HtmlReport`, or
   `-UndoFile`. If you did not, this is the same as the next location, so
   in the common case there is effectively one attempt.
2. **The database folder**, the same directory as `-DbPath`.
3. **The system temp directory**, if the database folder is not writable
   for some reason.

Each file's name includes a timestamp shared across the whole run
(`yy.MM.dd-HH.mm.ss`), so the log, HTML report, undo script, CSV, and
database backup from the same run all sort together.

## Console output

Always shown, never written to a file on its own. A run ends with a summary
box and, on success, the paths of every file that was actually written:

```
╔═══════════════════════════════════════════╗
║              Summary                      ║
╠═══════════════════════════════════════════╣
║   Renamed:         75                     ║
║   TypeChanged:     23                     ║
║   ImageChanged:    18                     ║
║   Unchanged:       454                    ║
║   Excluded:        12                     ║
║   Collisions:      0                      ║
║   Errors:          0                      ║
╚═══════════════════════════════════════════╝

  Total time: 2.3s
  📄 Log:  domoticz/rename_log-25.01.30-14.30.45.txt
  ↩️  Undo: domoticz/undo_rename-25.01.30-14.30.45.sql
  🌐 HTML: domoticz/rename_report-25.01.30-14.30.45.html
```

During a dry run, the title reads "Summary (DRY RUN)" instead. A `📊 CSV:`
line appears in the same block whenever a CSV was written.

## HTML report

**Always written**, in the database folder by default (see
[Where files land](#where-files-land) for the fallback order), as
`rename_report-<timestamp>.html`. There is no flag to turn it off; pass
`-HtmlReport` if you want it saved somewhere other than the default.

It is a self-contained, interactive page: expandable device cards with the
before/after details, search and filtering, and colour-coded badges for
name, switch type, and custom image changes. It also carries content that
is not in the console output or the log: the full **Names Disambiguated**
section explaining every automatic collision resolution. See
[Name collisions](collisions.md) for what that section shows and how to
read it.

A **Not in the node source** section appears whenever the run found Domoticz
devices whose DeviceID matches no Z-Wave value, listing every one of them
rather than the first five the console shows. See
[Devices with no Z-Wave value behind them](running.md#devices-with-no-z-wave-value-behind-them).

## Log file

**Always written**, in the database folder by default, as
`rename_log-<timestamp>.txt`. A plain-text, timestamped line per event:

```
[2025-01-30 14:30:45] [INFO] SQLite engine initialised from ./lib
[2025-01-30 14:30:45] [SUCCESS] Connected to SQLite database: domoticz/domoticz.db
[2025-01-30 14:30:46] [SUCCESS] Loaded 529 DeviceStatus rows into memory
[2025-01-30 14:30:46] [INFO] Using Base Identifier: zwavejs2mqtt_0xc15d8aa6
[2025-01-30 14:30:47] [INFO] RENAMING: zwavejs2mqtt_0xc15d8aa6_42-49-0-Air_temperature | Old: 'Outdoor - Sensor - Air temperature' -> New: 'Outdoor - Sensor - Temp'
[2025-01-30 14:30:47] [SUCCESS] Updated zwavejs2mqtt_0xc15d8aa6_42-49-0-Air_temperature to 'Outdoor - Sensor - Temp'
```

This is the most detailed record of a run, including entries the console
output summarises or omits, so it is the first place to look when a
particular device did not do what you expected.

## CSV summary

**Opt-in.** Written only when you pass `-CsvFile`, and only if the analysis
found at least one device with a change; if nothing changed, no file is
written even if you asked for one. It lands wherever `-CsvFile` points, with
the same database-folder-then-temp fallback as the other files if that
location is not writable.

The CSV lists one row per changed Domoticz `DeviceStatus` row, whether that
change is a name, a switch type, a custom image, or a combination.
`NewName` is blank on a row where only the switch type or custom image
changed. This includes runs made with `-DryRun`: because the file lists
what the analysis proposed rather than what was written to the database, a
dry run with `-CsvFile` still produces a CSV of the changes it would have
made.

A single-unit device contributes one row, with its `Unit` column holding
that row's Domoticz `Unit` number (usually `0`). A multi-unit device (see
[Multi-unit devices](../rules/naming.md#multi-unit-devices)) contributes
one row per `Unit` when each row could be named individually, each with
its own `Unit` number, or a single row with a blank `Unit` when the rows
still share one name and were renamed together.

```csv
DeviceID,Unit,OldName,NewName,OldSwitchType,NewSwitchType,OldCustomImage,NewCustomImage,NameChanged,SwitchTypeChanged,CustomImageChanged
zwavejs2mqtt_0xc15d8aa6_42-49-0-Air_temperature,0,"Outdoor - Sensor - Air temperature","Outdoor - Sensor - Temp",0,,0,,True,False,False
```

## Undo SQL

Written whenever changes were actually applied, that is, the run was not a
dry run and at least one device was updated. It is not written on a dry run
(there is nothing to undo yet) or on a run where nothing changed. It lands
in the database folder by default, as `undo_rename-<timestamp>.sql`, with
the same fallback order as the log and HTML report.

It contains one `UPDATE` statement per changed Domoticz `DeviceStatus` row,
each scoped to that row with `WHERE DeviceID = ... AND Unit = ...` rather
than to the DeviceID alone, wrapped in a single transaction. A multi-unit
device whose rows were renamed individually (see
[Multi-unit devices](../rules/naming.md#multi-unit-devices)) therefore
produces one statement per row, each restoring that row's own previous
name rather than overwriting every row with a single captured name:

```sql
-- Undo script generated by Rename-Domoticz-From-ZwaveJSON.ps1
-- Generated: 2025-01-30 14:30:45
-- Database: domoticz/domoticz.db
-- To revert changes, run: sqlite3 domoticz.db < undo_rename-25.01.30-14.30.45.sql

BEGIN TRANSACTION;

UPDATE DeviceStatus SET Name = 'Outdoor - Sensor - Air temperature' WHERE DeviceID = 'zwavejs2mqtt_0xc15d8aa6_42-49-0-Air_temperature' AND Unit = 0;

COMMIT;
```

See [Reverting changes](reverting.md) for when to use this instead of
restoring the database backup.
