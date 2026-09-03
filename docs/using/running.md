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

## Devices with no Z-Wave value behind them

The tool builds its list of candidates from the values the node source reports.
A Domoticz device whose DeviceID matches none of them is never a candidate, so
it is never renamed. That is deliberate: nothing updates such a device any
more, and giving it a tidy name would only make a dead row look healthy.

It is reported rather than passed over in silence, because otherwise a device
that was never considered looks exactly like one the tool failed to rename:

```text
  !  2 Domoticz device(s) have no Z-Wave value behind them
     Nothing in the node source matches their DeviceID, so they were never considered.
       - zwavejs2mqtt_0xc15d8aa6_80-50-1-value-66048 (Used=0, last update 2026-09-02 15:27:35)
         'Woonkamer-Screen Links (Woonkamer - Screen Links - Electric [W])'
         zwave-js-ui still advertises a discovery entry for it, so Domoticz will keep
         re-creating it. Clear that entry in zwave-js-ui first, then delete the device.
```

Only devices carrying this Z-Wave installation's base identifier are counted.
Your Domoticz database holds devices from every hardware type it talks to, and
none of the others are this tool's concern.

Two causes are told apart, because the fix differs:

- **The discovery entry outlived its Z-Wave value.** zwave-js-ui still
  advertises a Home Assistant discovery entry for the DeviceID while the value
  behind it is gone, most often because the node was re-interviewed and its
  values came back on a different endpoint. Domoticz creates its devices from
  those discovery entries, so deleting the device alone will not stick: it
  reappears the next time zwave-js-ui republishes. Clear the stale discovery
  entry in zwave-js-ui first, then delete the device in Domoticz.
- **Not in the node source at all.** Neither a value nor a discovery entry
  carries the DeviceID any more. Nothing will bring it back, so it can simply
  be deleted in Domoticz (Setup, Devices) once you are satisfied the physical
  device is gone.

These appear in the summary as `Orphaned`, shown only when the count is above
zero, and in the HTML report under **Not in the node source**, which lists every
one of them with its current name, `Used` flag, and last update time. The debug
log records each as an `ORPHANED:` line.

Nothing is deleted for you. The tool only ever renames devices, and reporting
these does not change that.

### Keep the history and the idx: replace instead of delete

When the old device has a live successor, most often because a value moved to
another endpoint and Domoticz created a second device for it, deleting the old
one throws away its logged history, and the new device carries a new `idx` that
every automation referring to the old one will miss.

Domoticz can transfer one device onto another instead. Open the **new** device's
edit dialog and press **Replace**, then pick the old device from the list. The
button is on the device edit dialog of the Switches, Utilities, Temperature and
Weather tabs.

What Domoticz actually does, read from the source rather than from the UI
wording:

- The **old** row survives, keeping its `idx` **and its name**. It takes over the
  new device's `HardwareID`, `OrgHardwareID`, `DeviceID`, `Unit`, `Type`,
  `SubType` and `Options`.
- Log rows belonging to the new device that are **newer than the old device's
  last update** are moved onto the old `idx`, across the Rain, Temperature, UV,
  Wind, Meter, MultiMeter, Fan and Percentage tables and their `_Calendar`
  counterparts. Anything dated at or before that point stays with the new device.
- The **new** device row is then deleted.

So the surviving device keeps its identity and its graphs and starts receiving
data through the live DeviceID. Anything that looks the device up by `idx`, a
dzVents script or a scene, keeps working untouched.

Two constraints are worth knowing before you try:

- Only devices with the **same `Type` and `SubType`** are offered. A kWh counter
  cannot be replaced by a Watt usage device, even on the same node. The
  exceptions are Temp, Temp+Hum and Temp+Hum+Baro, which are interchangeable
  with one another, Rain with Rain, and a VOC air-quality sensor, which may also
  be replaced by a Custom sensor.
- The list holds **every matching device in the database**, sorted by name and
  not narrowed to the same node, hardware or room. On a large installation that
  can run to hundreds of entries, so know the old device's name before you open
  it.

For an orphan whose discovery entry outlived its Z-Wave value, the full sequence
is: clear the stale discovery entry in zwave-js-ui, let Domoticz create the
device for the value's new location, replace that new device onto the old one,
then re-run this tool. The surviving row still carries the old name, so the
rename you were expecting happens on that run.

Replacing is a Domoticz operation. This tool never performs it, and the undo
script from a run cannot reverse it, so take a database backup first.

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
