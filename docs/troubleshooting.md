# Troubleshooting

Organized by what you saw on screen. If your symptom is not here, the debug
log (see [Understanding the output](using/output.md#log-file)) usually has
more detail than the console summary.

| Symptom | What to do |
|---------|-------------|
| **"SQLite engine unavailable"** | Run `pwsh ./setup.ps1` to download the pinned SQLite assemblies into `lib/`. See [Installation](getting-started/installation.md). |
| **"No native SQLite for '\<rid\>'"** | Your platform is not in the pinned native package. Open an issue with the reported runtime identifier. |
| **"Database is open by ..."** | Stop Domoticz before applying changes; it caches device rows in memory and can overwrite renames written while it is running. `-DryRun` is always safe to run regardless. |
| **"Missing an argument for parameter 'ZwaveJsCredential'"** | `-ZwaveJsCredential` takes a `PSCredential`, and only switch parameters may stand alone. To be prompted for a password, use `-ZwaveJsUser admin` instead. |
| **"bash: syntax error near unexpected token"** | You launched the script from bash or zsh as `pwsh ./Rename-Domoticz-From-ZwaveJSON.ps1 ...`, so the shell, not PowerShell, tried to parse `(Get-Credential)`. Use `-ZwaveJsUser admin` instead, or wrap the whole command in `pwsh -c '...'`. See [Running from bash, zsh or a Pi terminal](getting-started/input-modes.md#running-from-bash-zsh-or-a-pi-terminal). |
| **"-ZwaveJsUser has to prompt for a password, and this run has no console to prompt at"** | The run has no usable console, typically because it is scheduled or its input is redirected. Save the credential once with `Get-Credential \| Export-CliXml ./zwave.cred` and pass `-ZwaveJsCredential (Import-CliXml ./zwave.cred)`. |
| **"zwave-js-ui rejected the connection: it requires authentication"** | Your instance has authentication enabled and no login was supplied. Add `-ZwaveJsUser <username>`. If the message instead says the token was not accepted, it has probably expired; logging in obtains a fresh one on every run. |
| **"TLS certificate not trusted for ..."** | Your zwave-js-ui instance is using a self-signed `https://` certificate. Add `-SkipCertificateCheck`, or install a certificate the machine trusts. Avoid combining `-SkipCertificateCheck` with `-ZwaveJsToken`, since an unverified server could intercept the token. |
| **"Could not reach zwave-js-ui at ..."** or **"Timed out talking to zwave-js-ui at ..."** | Confirm the `-ZwaveJsUrl` value, including the port, and that this machine can reach that host and port. If your instance is not reachable from where you run the script, use `-JsonFile` with an exported JSON dump instead; see [Input modes](getting-started/input-modes.md). |
| **"DeviceID not found"** | Check that the JSON IDs match the Domoticz database IDs (spaces become underscores). In live mode (`-ZwaveJsUrl`), this usually means Hass/MQTT discovery is not enabled in zwave-js-ui. |
| **"Base Identifier not found"** | In file mode, verify your JSON export has `identifiers` under `hassDevices`. In live mode, this means Hass/MQTT discovery must be enabled in zwave-js-ui, since the base identifier comes from the discovery payload. |
| **"Name collision detected"** | Collisions across different endpoints are auto-resolved with an endpoint suffix; unresolvable collisions (same endpoint, an endpoint that cannot be read from the DeviceID, or the disambiguated name is itself already taken) are reported and skipped rather than written. See [Name collisions](using/collisions.md). |
| **A device was renamed with an unexpected ` - EP0` suffix** | Another device already holds the clean name. Check **Names Disambiguated** in the HTML report: if the holder is marked "not in node source", it is a leftover Domoticz device, so delete it (Setup, Devices) and re-run. |
| **Logs, CSV, HTML report, or undo script not where expected** | Check the console output for the actual paths used; each file falls back in order: the path you gave it, then the database folder, then the system temp folder. See [Where files land](using/output.md#where-files-land). |
| **A device is never renamed, and the summary shows `Ambiguous`** | This only affects a multi-unit device (a Central Scene remote, say) whose Domoticz rows already disagree on a name; one whose rows agree is renamed together as before. The tool could not match every Domoticz `Unit` row to a Z-Wave key state, so it left every row exactly as it was rather than guessing. This happens when the Z-Wave value carries no `states` array, the number of Domoticz rows does not match the number of states reported, a state's value is missing or not a whole number, a state's label text is missing, empty, or whitespace-only, or one of the device's `Unit` numbers has no matching state value. See [Multi-unit devices](rules/naming.md#multi-unit-devices) and [Devices the tool refuses to touch](using/running.md#devices-the-tool-refuses-to-touch). |
| **My scene buttons were renamed and my dzVents stopped working** | As of v2.12 the tool names each `Unit` row of a Central Scene button individually instead of leaving multi-unit devices alone. If an automation looked a device up by name, that name may have changed. Check the undo script from the run that renamed them (see [Reverting changes](using/reverting.md)) to restore the previous names, then update the automation to reference the device by its `idx` instead, which does not change when the tool renames it. |

## Still stuck

Open an issue on the
[GitHub repository](https://github.com/Rouzax/Rename-Domoticz-From-ZwaveJSON)
with the relevant lines from the debug log and, if it is not sensitive, the
device entry from your JSON export or zwave-js-ui.
