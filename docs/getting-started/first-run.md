# Your first run

!!! warning "Before you run this against a real database"
    This script writes directly to the Domoticz SQLite database.

    - **Stop Domoticz before applying changes.** Domoticz caches device rows
      in memory and periodically writes them back, so it can overwrite your
      renames while it is running, and renamed devices will not show their
      new names in the UI until Domoticz restarts anyway. `-DryRun` is safe
      to run at any time, including while Domoticz is running.
    - **Back up your database first.** The script creates its own backup
      automatically before making any change (skip it only with `-NoBackup`,
      which is not recommended), but keeping your own backup as well costs
      nothing and gives you a second line of defense.

    The script also does a best-effort, cross-platform check for whether
    another process still has the database open, and warns you if so, but
    that check is not a substitute for stopping Domoticz yourself.

This walkthrough assumes you have already completed
[Installation](installation.md) (`pwsh ./setup.ps1` has been run at least
once on this machine) and that you have a running Z-Wave JS UI instance the
script can reach. If your instance is not reachable, or you would rather
work from a frozen snapshot, see [Input modes](input-modes.md) for the JSON
export alternative; everything below applies the same way once you swap in
`-JsonFile`.

## 1. Preview the changes

Point the script at your Z-Wave JS UI instance and your Domoticz database,
and add `-DryRun` so nothing is written yet:

```powershell
.\Rename-Domoticz-From-ZwaveJSON.ps1 -ZwaveJsUrl "http://zwave-host:8091" -DbPath "domoticz.db" -DryRun
```

The script connects to `zwave-host` read-only, reads your node data, works
out the proposed name for every device, and writes a log, an HTML report,
and an undo SQL script, all without touching the database.

## 2. Read the report

Open the generated HTML report and check the proposed names before doing
anything else. Look for:

- Names that do not match what you expected for a room or device.
- Any collisions the script reports as unresolved (it will list these
  explicitly rather than silently skip them).

<!-- DEFERRED-LINK: restore the link to ../rules/naming.md once Task 4
     creates it. --strict fails the build on links to pages that do not
     exist yet.
If something looks wrong, adjust your Z-Wave JS UI room/device names, or add
a custom [renaming rule](../rules/naming.md), then run the `-DryRun` command
again until the report looks right. -->
If something looks wrong, adjust your Z-Wave JS UI room/device names, or add
a custom renaming rule, then run the `-DryRun` command again until the
report looks right.

## 3. Apply the changes

Once the report looks correct and Domoticz is stopped, run the same command
without `-DryRun`:

```powershell
.\Rename-Domoticz-From-ZwaveJSON.ps1 -ZwaveJsUrl "http://zwave-host:8091" -DbPath "domoticz.db"
```

Unless you pass `-Force`, the script asks you to confirm before writing
anything, so you get one more chance to back out.

## 4. Restart Domoticz

Start Domoticz again so it picks up the renamed devices. New names will not
appear in the UI until it restarts.

<!-- DEFERRED-LINK: restore the link to ../using/output.md once Task 3
     creates it. --strict fails the build on links to pages that do not
     exist yet.
For a full breakdown of every file the script writes and what each one
contains, see Understanding the output (`../using/output.md`). -->
For a full breakdown of every file the script writes and what each one
contains, see Understanding the output, covered in the next section of these
docs.
