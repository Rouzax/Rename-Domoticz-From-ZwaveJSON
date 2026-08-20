# Parameters

Full reference for every parameter the script accepts, verified against the
`param()` block in `Rename-Domoticz-From-ZwaveJSON.ps1`. For a task-oriented
walkthrough, see [Your first run](../getting-started/first-run.md) and
[Running the tool](../using/running.md).

```powershell
.\Rename-Domoticz-From-ZwaveJSON.ps1 -JsonFile "nodes_dump.json" -DbPath "domoticz.db"
```

## Node data source (pick one)

The script reads node data from a JSON export **or** live from a running
zwave-js-ui instance, never both. PowerShell enforces this with two
mutually exclusive parameter sets: `-JsonFile` belongs to the `FromFile`
set, `-ZwaveJsUrl` belongs to the `FromZwaveJs` set, and passing parameters
from both sets in the same command is rejected before the script runs.

| Parameter | Type | Parameter set | Description |
|-----------|------|----------------|--------------|
| `-JsonFile` | String | `FromFile` | Path to the exported JSON file from Z-Wave JS UI. |
| `-ZwaveJsUrl` | String | `FromZwaveJs` | Base URL of a running zwave-js-ui instance, for example `https://host:8091`. Reads node data live over its socket.io API instead of a file. |

Both are mandatory, positional (position 0), and mutually exclusive: the
script requires exactly one of them.

### Live-mode only

These two only apply, and are only accepted, alongside `-ZwaveJsUrl`:

| Parameter | Type | Default | Description |
|-----------|------|---------|--------------|
| `-ZwaveJsToken` | String | Not set | Auth token if zwave-js-ui has authentication enabled. Sent in cleartext over `http://` (allowed, with a warning); prefer `https://` on an untrusted network, or an environment variable rather than an inline value. |
| `-SkipCertificateCheck` | Switch | `$false` | Skip TLS validation for a self-signed `https://` zwave-js-ui. Avoid combining with `-ZwaveJsToken`, since an unverified server could intercept the token; prefer a trusted certificate instead. |

## Required for every run

| Parameter | Type | Description |
|-----------|------|--------------|
| `-DbPath` | String | Path to the Domoticz SQLite database. Mandatory, position 1. |

## Optional parameters

These apply regardless of which node data source you chose:

| Parameter | Type | Default | Description |
|-----------|------|---------|--------------|
| `-LogFile` | String | Not set (auto-generated in the DB folder; see [Where files land](../using/output.md#where-files-land)) | Path to save the debug log file. |
| `-CsvFile` | String | Not set (no CSV is written unless specified) | Path to save the renaming summary CSV. |
| `-RulesFile` | String | Not set (auto-loads `rename_rules.json` from the script's own directory if present, otherwise the built-in rules) | Path to a custom renaming rules JSON file. See [Writing your own rules](../rules/writing-rules.md). |
| `-HtmlReport` | String | Not set (auto-generated in the DB folder) | Path to save the HTML report. |
| `-UndoFile` | String | Not set (auto-generated in the DB folder) | Path to save the SQL undo script. |
| `-ExcludeDeviceIds` | String array | Empty array | DeviceIDs to exclude from renaming entirely. |
| `-ExcludePattern` | String | Not set | Regular expression matched against the DeviceID; a match excludes the device. |
| `-DryRun` | Switch | `$false` | Preview changes without modifying the database. |
| `-Force` | Switch | `$false` | Skip every interactive confirmation prompt. |
| `-NoBackup` | Switch | `$false` | Skip the automatic database backup. Not recommended for routine use. |

None of these are tied to a parameter set: they are accepted whether you
used `-JsonFile` or `-ZwaveJsUrl`.
