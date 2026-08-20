# Troubleshooting

Organized by what you saw on screen. If your symptom is not here, the debug
log (see [Understanding the output](using/output.md#log-file)) usually has
more detail than the console summary.

| Symptom | What to do |
|---------|-------------|
| **"SQLite engine unavailable"** | Run `pwsh ./setup.ps1` to download the pinned SQLite assemblies into `lib/`. See [Installation](getting-started/installation.md). |
| **"No native SQLite for '\<rid\>'"** | Your platform is not in the pinned native package. Open an issue with the reported runtime identifier. |
| **"Database is open by ..."** | Stop Domoticz before applying changes; it caches device rows in memory and can overwrite renames written while it is running. `-DryRun` is always safe to run regardless. |
| **"TLS certificate not trusted for ..."** | Your zwave-js-ui instance is using a self-signed `https://` certificate. Add `-SkipCertificateCheck`, or install a certificate the machine trusts. Avoid combining `-SkipCertificateCheck` with `-ZwaveJsToken`, since an unverified server could intercept the token. |
| **"Could not reach zwave-js-ui at ..."** or **"Timed out talking to zwave-js-ui at ..."** | Confirm the `-ZwaveJsUrl` value, including the port, and that this machine can reach that host and port. If your instance is not reachable from where you run the script, use `-JsonFile` with an exported JSON dump instead; see [Input modes](getting-started/input-modes.md). |
| **"DeviceID not found"** | Check that the JSON IDs match the Domoticz database IDs (spaces become underscores). In live mode (`-ZwaveJsUrl`), this usually means Hass/MQTT discovery is not enabled in zwave-js-ui. |
| **"Base Identifier not found"** | In file mode, verify your JSON export has `identifiers` under `hassDevices`. In live mode, this means Hass/MQTT discovery must be enabled in zwave-js-ui, since the base identifier comes from the discovery payload. |
| **"Name collision detected"** | Collisions across different endpoints are auto-resolved with an endpoint suffix; unresolvable collisions (same endpoint, an endpoint that cannot be read from the DeviceID, or the disambiguated name is itself already taken) are reported and skipped rather than written. See [Name collisions](using/collisions.md). |
| **A device was renamed with an unexpected ` - EP0` suffix** | Another device already holds the clean name. Check **Names Disambiguated** in the HTML report: if the holder is marked "not in node source", it is a leftover Domoticz device, so delete it (Setup, Devices) and re-run. |
| **Logs, CSV, HTML report, or undo script not where expected** | Check the console output for the actual paths used; each file falls back in order: the path you gave it, then the database folder, then the system temp folder. See [Where files land](using/output.md#where-files-land). |
| **A device is never renamed, and the summary shows `Ambiguous`** | Several Domoticz rows share that DeviceID and disagree, which happens when the units of a multi-unit device (a Central Scene remote, say) were named individually. One Z-Wave value cannot supply several names, so the tool leaves them alone rather than collapsing them. Rename them in Domoticz if you want them changed. |

## Still stuck

Open an issue on the
[GitHub repository](https://github.com/Rouzax/Rename-Domoticz-From-ZwaveJSON)
with the relevant lines from the debug log and, if it is not sensitive, the
device entry from your JSON export or zwave-js-ui.
