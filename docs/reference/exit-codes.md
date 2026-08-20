# Exit codes

The script always exits with a code you can check in a calling process,
taken from `$Script:ExitCodes` in `Rename-Domoticz-From-ZwaveJSON.ps1`:

| Code | Meaning |
|------|---------|
| `0` | Success |
| `1` | Error |
| `2` | No changes needed |
| `3` | Partial success (some errors occurred) |
| `4` | User cancelled |

## What each one means

- **`0` Success.** The run completed and, if any devices needed changes,
  they were applied (or previewed, on `-DryRun`) without errors.
- **`1` Error.** Something stopped the run before it could complete: a
  missing prerequisite, an unreadable JSON file or database, an invalid
  `-ExcludePattern`, or a fatal error partway through. No partial write is
  left in this state; database updates only happen inside a single
  transaction that rolls back entirely on error.
- **`2` No changes needed.** The run completed successfully, but every
  device already had the name, switch type, and custom image the analysis
  would have set, so nothing was written.
- **`3` Partial success.** Some devices were updated and others were not,
  either because of unresolved name collisions or per-device errors during
  the apply phase. Check the log and HTML report for which devices were
  skipped and why.
- **`4` User cancelled.** An interactive confirmation prompt (the
  database-in-use warning, the collision "continue anyway" prompt, or the
  final "proceed with these changes" prompt) was declined. Pass `-Force`
  to skip these prompts in an unattended run; see
  [Automation](../using/running.md#automation).

## Using it in a script

```powershell
& .\Rename-Domoticz-From-ZwaveJSON.ps1 -JsonFile "nodes_dump.json" -DbPath "domoticz.db" -Force
switch ($LASTEXITCODE) {
    0 { Write-Host "Renamed successfully" }
    2 { Write-Host "Nothing to do" }
    default { Write-Host "Rename run needs attention (exit $LASTEXITCODE)" }
}
```
