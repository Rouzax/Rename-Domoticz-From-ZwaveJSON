# Parameters

Full reference for every parameter the script accepts, verified against the
`param()` block in `Rename-Domoticz-From-ZwaveJSON.ps1`. For a task-oriented
walkthrough, see [Your first run](../getting-started/first-run.md) and
[Running the tool](../using/running.md). For whole commands you can copy and
adapt, jump to [Example command lines](#example-command-lines).

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

Both are mandatory and mutually exclusive: the script requires exactly one of
them. Both are declared at position 0, but only `-JsonFile` is usable
positionally. An unnamed first argument binds to the default parameter set,
which is `FromFile`, so a bare URL is read as a file path and the run stops
with `JSON file not found: http://host:8091`. Always name `-ZwaveJsUrl`.

### Live-mode only

These two only apply, and are only accepted, alongside `-ZwaveJsUrl`:

| Parameter | Type | Default | Description |
|-----------|------|---------|--------------|
| `-ZwaveJsUser` | String | Not set | zwave-js-ui username to log in as, for example `admin`. The password is prompted for, so it never reaches your shell history, the process list, the log, or the HTML report. This is the form to use from bash or zsh, where `(Get-Credential)` would be parsed by the shell rather than by PowerShell; see [Running from bash, zsh or a Pi terminal](../getting-started/input-modes.md#running-from-bash-zsh-or-a-pi-terminal). Needs a console to prompt at: with none, the run stops with exit code `1` rather than continuing. Cannot be combined with `-ZwaveJsCredential`. |
| `-ZwaveJsCredential` | PSCredential | Not set | Login for a zwave-js-ui with authentication enabled, for when you already hold a `PSCredential` or want to be prompted for the username too. The script logs in and uses the token it gets back, so you never obtain or store one and expiry stops mattering. Use `(Get-Credential)` to be prompted, or `Import-CliXml` for an unattended run. The password travels in cleartext over `http://` (allowed, with a warning); prefer `https://` off a trusted LAN. Preferred over `-ZwaveJsToken`; supplying both is an error. |
| `-ZwaveJsToken` | String | Not set | An existing zwave-js-ui auth token, for callers that already have one. `-ZwaveJsCredential` is preferred, since it obtains a fresh token per run. Sent in cleartext over `http://` (allowed, with a warning); prefer `https://` on an untrusted network, or an environment variable rather than an inline value. |
| `-SkipCertificateCheck` | Switch | `$false` | Skip TLS validation for a self-signed `https://` zwave-js-ui. Avoid combining with `-ZwaveJsCredential` or `-ZwaveJsToken`, since an unverified server could intercept whichever you send; prefer a trusted certificate instead. |

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

## Example command lines

Every example previews with `-DryRun` where a preview makes sense. Run a
preview first, read the report, and only then run the same command without it.
Before applying, stop Domoticz: it caches device rows in memory and can write
the old names back over your renames.

**Preview a live instance.** The shortest useful command, and the one to start
with:

```powershell
.\Rename-Domoticz-From-ZwaveJSON.ps1 -ZwaveJsUrl "http://zwave-host:8091" `
    -DbPath "domoticz.db" -DryRun
```

**Apply it.** The same command without `-DryRun`, which prompts for
confirmation before writing:

```powershell
.\Rename-Domoticz-From-ZwaveJSON.ps1 -ZwaveJsUrl "http://zwave-host:8091" `
    -DbPath "domoticz.db"
```

**A zwave-js-ui that requires login.** How you pass the login depends on where
you type the command, because a POSIX shell parses `(Get-Credential)` before
PowerShell ever sees it:

=== "PowerShell session"

    ```powershell
    .\Rename-Domoticz-From-ZwaveJSON.ps1 -ZwaveJsUrl "https://zwave-host:8091" `
        -DbPath "domoticz.db" -ZwaveJsCredential (Get-Credential) -DryRun
    ```

    Prompts for both the username and the password.

=== "bash, zsh or a Pi terminal"

    ```bash
    pwsh ./Rename-Domoticz-From-ZwaveJSON.ps1 -ZwaveJsUrl "https://zwave-host:8091" \
        -DbPath "/home/user/domoticz.db" -ZwaveJsUser admin -DryRun
    ```

    Prompts for the password only. See
    [Running from bash, zsh or a Pi terminal](../getting-started/input-modes.md#running-from-bash-zsh-or-a-pi-terminal).

**From a JSON export** instead of a live instance, for when zwave-js-ui is not
reachable from here:

```powershell
.\Rename-Domoticz-From-ZwaveJSON.ps1 -JsonFile "nodes_dump.json" `
    -DbPath "domoticz.db" -DryRun
```

`-JsonFile` and `-DbPath` are positional, in that order, so this is the same
command:

```powershell
.\Rename-Domoticz-From-ZwaveJSON.ps1 "nodes_dump.json" "domoticz.db" -DryRun
```

**With your own renaming rules:**

```powershell
.\Rename-Domoticz-From-ZwaveJSON.ps1 -ZwaveJsUrl "http://zwave-host:8091" `
    -DbPath "domoticz.db" -RulesFile "my_rules.json" -DryRun
```

**Leaving some devices alone.** `-ExcludeDeviceIds` takes exact DeviceIDs,
`-ExcludePattern` a regex; the two can be combined:

```powershell
.\Rename-Domoticz-From-ZwaveJSON.ps1 -ZwaveJsUrl "http://zwave-host:8091" `
    -DbPath "domoticz.db" `
    -ExcludeDeviceIds "zwavejs2mqtt_0xc15d8aa6_42-49-0-Air_temperature" `
    -ExcludePattern 'node\d+$' `
    -DryRun
```

Use single quotes around a regex: in a double-quoted PowerShell string, `$`
introduces variable expansion.

**Putting every output file where you want it.** Without these, each file
lands next to the database; see
[Where files land](../using/output.md#where-files-land):

```powershell
.\Rename-Domoticz-From-ZwaveJSON.ps1 -ZwaveJsUrl "http://zwave-host:8091" `
    -DbPath "domoticz.db" `
    -LogFile "reports/rename.log" `
    -CsvFile "reports/rename.csv" `
    -HtmlReport "reports/rename.html" `
    -UndoFile "reports/undo.sql"
```

`-CsvFile` is the only one of the four that changes what is produced: no CSV is
written unless you ask for one.

**A scheduled or unattended run.** `-Force` skips all three interactive prompts
(the database-in-use warning, the collision prompt, and the final
confirmation), and a saved credential avoids needing a console to type into:

```powershell
& .\Rename-Domoticz-From-ZwaveJSON.ps1 -ZwaveJsUrl "https://zwave-host:8091" `
    -DbPath "domoticz.db" `
    -ZwaveJsCredential (Import-CliXml ./zwave.cred) `
    -Force
switch ($LASTEXITCODE) {
    0 { "Renamed successfully" }
    2 { "Nothing to do" }
    default { "Rename run needs attention (exit $LASTEXITCODE)" }
}
```

Save the credential once, interactively, with
`Get-Credential | Export-CliXml ./zwave.cred`, and keep that file out of
version control. Do not use `-ZwaveJsUser` here: it has to prompt for a
password, and a run with no console to prompt at stops with exit code `1`. See
[Exit codes](exit-codes.md) for what each code means.
