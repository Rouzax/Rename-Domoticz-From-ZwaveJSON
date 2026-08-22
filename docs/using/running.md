# Running the tool

This page covers the parameters and behaviour you need once you are past a
first successful run: previewing safely, excluding devices, what the
automatic backup does and does not cover, what happens if Domoticz is still
running, and using the script in an unattended pipeline.

It assumes you have completed [Installation](../getting-started/installation.md)
and [Your first run](../getting-started/first-run.md), and have a working
`-JsonFile` or `-ZwaveJsUrl` command already.

## Preview first

Add `-DryRun` to any command to see what the script would do without writing
anything to the database:

```powershell
.\Rename-Domoticz-From-ZwaveJSON.ps1 -ZwaveJsUrl "https://zwave-host:8091" -DbPath "domoticz.db" -DryRun
```

A dry run still does the full analysis: it reads your node data, works out
every proposed name, resolves collisions, and writes the log, the HTML
report, and (if you passed `-CsvFile`) the CSV summary. It does not create a
database backup and does not write an undo SQL script, because there is
nothing to undo. It also skips every interactive confirmation prompt, the
same as `-Force` does, since there is nothing to confirm.

`-DryRun` is safe to run at any time, including while Domoticz is running,
because it never opens a write transaction against the database.

## Excluding devices

Two ways to keep specific devices out of the rename entirely, applied before
any name is proposed for them.

**By exact DeviceID**, with `-ExcludeDeviceIds`:

```powershell
.\Rename-Domoticz-From-ZwaveJSON.ps1 -JsonFile "nodes_dump.json" -DbPath "domoticz.db" `
    -ExcludeDeviceIds @("zwavejs2mqtt_0xc15d8aa6_42-49-0-Air_temperature", "zwavejs2mqtt_0xc15d8aa6_50-1-value-66049")
```

**By pattern**, with `-ExcludePattern` (a regular expression matched against
the DeviceID):

```powershell
.\Rename-Domoticz-From-ZwaveJSON.ps1 -JsonFile "nodes_dump.json" -DbPath "domoticz.db" `
    -ExcludePattern "test_.*|debug_.*"
```

Both can be used together; a device matching either one is excluded. An
excluded device is counted separately from unchanged devices in the console
summary (`Excluded`), so you can confirm the count matches what you
expected. If `-ExcludePattern` is not a valid regular expression, the script
stops immediately with an error before touching the database or writing a
backup.

## Backups

Unless you pass `-DryRun` or `-NoBackup`, the script copies `domoticz.db`
before making any change:

- Stored in the same folder as the original database.
- Named `domoticz-yy.MM.dd-HH.mm.ss.db` (a timestamp matching the log,
  report, and undo files from the same run).
- Verified with a file-size check after the copy; a mismatch is logged as a
  warning rather than failing the run, since it is not proof of corruption
  on its own.

Skip the backup with `-NoBackup` only if you already have your own copy;
this is not recommended for routine use. See
[Reverting changes](reverting.md) for how to restore a backup or run the
undo script.

## If Domoticz is running

Before making any change, the script checks whether another process
(typically Domoticz itself) has the database open, and warns you with the
process name if so:

- **Linux** (including Raspberry Pi): scans `/proc` for a process holding
  the database or its `-wal`/`-journal` files open. No extra tools needed.
- **Windows**: attempts an exclusive open of the database file.
- **macOS**: uses `lsof` when it is available.

This check is best-effort, not a guarantee: SQLite locks are transient, and
on Linux it can only see handles owned by processes visible to the current
user. Treat it as a helpful warning, not a substitute for actually stopping
Domoticz.

**Always stop Domoticz before applying changes.** It caches device rows in
memory and periodically writes them back, which can silently overwrite your
renames, and renamed devices will not show their new names in the Domoticz
UI until it restarts anyway.

If the check finds the database in use, the script prompts you to continue
or cancel, unless you passed `-Force` or `-DryRun`, in which case it
proceeds (or previews) without asking.

## Devices the tool refuses to touch

A DeviceID is not unique in Domoticz. A multi-unit device, most commonly a
Central Scene remote, is stored as one DeviceID with several `Unit` rows, and
every write this tool makes targets a specific row.

The tool reads the Z-Wave value's `states` array (for example `KeyPressed`,
`KeyReleased`, `KeyHeldDown` on a Central Scene button) and, when it can match
every `Unit` row to a state, renames each row individually from its own state
label, even if the rows currently disagree on their name. See
[Multi-unit devices](../rules/naming.md#multi-unit-devices) for the naming
scheme and how to change the bundled labels.

A device whose rows already agree on a name is unaffected either way: it is
renamed together, as one entry covering every row, exactly as before this
mapping existed. Only a device whose rows disagree depends on the mapping,
and it is skipped entirely, leaving every row exactly as it was, when that
mapping cannot be established:

- the Z-Wave value carries no `states` array at all;
- the number of Domoticz rows does not match the number of states the value
  reports;
- a state's value is missing or is not a whole number;
- a state's label text is missing, empty, or whitespace-only; or
- one of the device's `Unit` numbers has no matching state value.

```text
  !  1 device(s) skipped: several Domoticz rows share the DeviceID and disagree
     Renaming would collapse them into one name, and the undo script could not restore them.
```

In that case it cannot do better: with no reliable way to tell which row
means what, renaming would either overwrite every row with the same name or
guess wrong, and the undo statement matches the same row, so a bad guess
could not be told apart from a correct one either.

These appear in the summary as `Ambiguous`, which is shown only when the count
is above zero, and in the HTML report under **Skipped: ambiguous devices**. If
you want them renamed, rename them in Domoticz, or check that your zwave-js-ui
export includes the value's `states` array.

## Automation

For unattended use, pass `-Force` to skip every interactive prompt the
script can show: the database-in-use warning, the "continue anyway" prompt
for unresolvable name collisions, and the final "proceed with these
changes" confirmation. Without `-Force`, any of those three will block a
non-interactive run waiting for input that never comes.

```powershell
# Returns an exit code you can branch on
& .\Rename-Domoticz-From-ZwaveJSON.ps1 -JsonFile "nodes_dump.json" -DbPath "domoticz.db" -Force
exit $LASTEXITCODE
```

The script always exits with a code you can check: 0 for success, 1 for an
error, 2 when nothing needed to change, 3 for partial success, and 4 if a
user cancelled an interactive prompt. See [Exit codes](../reference/exit-codes.md)
for the full list and what to do about each one.
