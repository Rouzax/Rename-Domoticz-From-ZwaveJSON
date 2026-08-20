# Reverting changes

Two ways to undo a run, depending on how much you want to undo and how much
else has changed since.

## Restore the backup

Copy the backup file (see [Backups](running.md#backups)) over the current
database, replacing it entirely:

```powershell
Copy-Item -Path "domoticz/domoticz-25.01.30-14.30.45.db" -Destination "domoticz/domoticz.db" -Force
```

This reverses **everything** that happened to the database since the
backup was taken, not just the rename, including any unrelated changes
made through the Domoticz UI or by other tools in the meantime. Use this
when you want to go back to exactly how things were before the run, or when
something went wrong partway through and you would rather start over than
work out what changed.

Stop Domoticz before restoring a backup, for the same reason you stop it
before applying a rename: it caches device rows in memory and will not
notice the file underneath it changed until it restarts.

## Run the undo script

Run the generated undo SQL script against the current database:

```bash
sqlite3 domoticz.db < undo_rename-25.01.30-14.30.45.sql
```

This reverses **only what that specific run changed**: the names, switch
types, and custom images it actually updated, restored to their previous
values field by field. Anything else you have done to the database since,
including later runs of this script, is left alone. Use this when you want
to back out one run precisely without touching unrelated changes made
after it.

Each run writes its own undo script, so if you have applied the tool more
than once, run the undo scripts in reverse chronological order (most recent
first) to unwind them cleanly.
