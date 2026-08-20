# Input modes

The script needs to know what rooms and devices you have configured in
Z-Wave JS UI. There are two ways to give it that data: read it live from a
running instance, or point it at a JSON file you exported earlier. Both
produce the same node data and drive the same renaming logic; only how the
script gets the data differs.

**Live mode is the primary way to use this tool** and needs no manual export
step. Reach for the JSON export instead when your zwave-js-ui instance is
not reachable from the machine running the script, or when you deliberately
want a frozen snapshot to test against (for example, comparing proposed
names before and after a Z-Wave JS UI configuration change).

=== "Live zwave-js-ui"

    Point the script at your running instance with `-ZwaveJsUrl`. It reads
    the node data over zwave-js-ui's socket.io API (the same protocol the
    zwave-js-ui web UI itself uses); nothing in zwave-js-ui is modified.

    ```powershell
    .\Rename-Domoticz-From-ZwaveJSON.ps1 -ZwaveJsUrl "https://zwave-host:8091" -DbPath "domoticz.db" -DryRun
    ```

    zwave-js-ui listens on port `8091` by default. Give the full base URL,
    including the scheme (`http://` or `https://`); the script rejects any
    other scheme.

    This mode requires Hass/MQTT discovery to be enabled in zwave-js-ui.
    That is already the case if Domoticz received these devices through MQTT
    Auto-Discovery in the first place, because the script needs the base
    device identifier from the discovery payload.

    **Authentication.** If your instance requires login, pass
    `-ZwaveJsToken` with a JWT obtained by logging into zwave-js-ui. The
    script never logs or stores the token. Prefer setting it from an
    environment variable rather than typing it inline, so it does not end up
    in your shell history or process list:

    ```powershell
    .\Rename-Domoticz-From-ZwaveJSON.ps1 -ZwaveJsUrl "http://zwave-host:8091" -ZwaveJsToken $env:ZWAVEJS_TOKEN -DbPath "domoticz.db" -DryRun
    ```

    The token is a credential. If you connect over `http://` (not `https://`)
    and supply `-ZwaveJsToken`, the script sends the token in cleartext. It
    allows this and prints a warning rather than refusing to run, because a
    trusted LAN or localhost connection is a common and reasonable case; use
    `https://` instead if the traffic could be observed by anyone else.

    **Self-signed HTTPS.** If zwave-js-ui uses a certificate your machine
    does not trust, add `-SkipCertificateCheck` to skip TLS validation.
    Avoid combining it with `-ZwaveJsToken`: an unverified server could
    intercept the token. The script warns when you combine the two. Prefer
    a trusted certificate over skipping validation when you can.

=== "JSON export"

    1. Open **Z-Wave JS UI**.
    2. Go to **General Actions**.
    3. Choose **Dump -> EXPORT** to download a full JSON export of all nodes.
    4. Save the file somewhere the script can read it.

    Then point the script at the file with `-JsonFile` instead of
    `-ZwaveJsUrl`:

    ```powershell
    .\Rename-Domoticz-From-ZwaveJSON.ps1 -JsonFile "nodes_dump.json" -DbPath "domoticz.db" -DryRun
    ```

    Nothing about the rest of the workflow changes: the same renaming
    logic, the same report, the same collision handling all apply to a JSON
    export exactly as they do to a live read.

## Choosing between them

`-JsonFile` and `-ZwaveJsUrl` are mutually exclusive; the script requires
exactly one of them (whichever you pass determines the parameter set it
runs under). You cannot mix a live read with a file in the same run.

Continue to [Your first run](first-run.md) for a full walkthrough using live
mode.
