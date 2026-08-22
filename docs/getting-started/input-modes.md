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

    **Authentication.** If your instance requires login, pass `-ZwaveJsUser`
    with your zwave-js-ui username (`admin` on a default install). The script
    prompts for the password and logs in for you:

    ```powershell
    .\Rename-Domoticz-From-ZwaveJSON.ps1 -ZwaveJsUrl "https://zwave-host:8091" -ZwaveJsUser admin -DbPath "domoticz.db" -DryRun
    ```

    The password is prompted for rather than typed on the command line, so it
    never reaches your shell history or the process list, and it is not written
    to the log or the HTML report. The script exchanges it for a session token
    itself, so you never obtain, paste or store a token, and token expiry stops
    mattering because each run logs in fresh.

    `-ZwaveJsUser` needs a console to prompt at. Given none, the run stops with
    an error instead of continuing, so a scheduled run can never look like a
    success that renamed nothing. For unattended use, pass a saved credential
    instead (below).

    `-ZwaveJsCredential` takes a `PSCredential`, for when you already hold one
    or want to be prompted for the username too:

    ```powershell
    .\Rename-Domoticz-From-ZwaveJSON.ps1 -ZwaveJsUrl "https://zwave-host:8091" -ZwaveJsCredential (Get-Credential) -DbPath "domoticz.db" -DryRun
    ```

    That form only works from inside a PowerShell session. See
    [Running from bash, zsh or a Pi terminal](#running-from-bash-zsh-or-a-pi-terminal)
    below if you launch the script with `pwsh ./Rename-Domoticz-From-ZwaveJSON.ps1`.
    Supplying both `-ZwaveJsUser` and `-ZwaveJsCredential` is an error.

    For an unattended run, save the credential once and read it back:

    ```powershell
    Get-Credential | Export-CliXml ./zwave.cred      # once, interactively
    .\Rename-Domoticz-From-ZwaveJSON.ps1 -ZwaveJsUrl "https://zwave-host:8091" -ZwaveJsCredential (Import-CliXml ./zwave.cred) -DbPath "domoticz.db"
    ```

    `Export-CliXml` encrypts the password so only the same user on the same
    machine can read it back. Keep the file out of version control.

    **If you already have a token**, `-ZwaveJsToken` still works and is
    unchanged. Supplying both a credential and a token is an error rather than a
    silent preference. Prefer setting a token from an environment variable
    rather than typing it inline:

    ```powershell
    .\Rename-Domoticz-From-ZwaveJSON.ps1 -ZwaveJsUrl "http://zwave-host:8091" -ZwaveJsToken $env:ZWAVEJS_TOKEN -DbPath "domoticz.db" -DryRun
    ```

    Either way the secret is a credential. Over `http://` rather than `https://`
    it travels in cleartext, and the script warns rather than refusing, because a
    trusted LAN or localhost is a common and reasonable case. The warning is
    sharper for a password than for a token: a captured token expires, a captured
    password works until you change it. Use `https://` if the traffic could be
    observed.

    **Self-signed HTTPS.** If zwave-js-ui uses a certificate your machine
    does not trust, add `-SkipCertificateCheck` to skip TLS validation.
    Avoid combining it with `-ZwaveJsCredential` or `-ZwaveJsToken`: an
    unverified server could intercept whichever you send. The script warns when
    you combine them. Prefer a trusted certificate over skipping validation.

    #### Running from bash, zsh or a Pi terminal

    If you start the script from a POSIX shell rather than from inside
    PowerShell, the shell parses the command line first, and
    `-ZwaveJsCredential (Get-Credential)` fails before PowerShell ever sees it:

    ```console
    $ pwsh ./Rename-Domoticz-From-ZwaveJSON.ps1 -ZwaveJsUrl "http://localhost:8091" -ZwaveJsCredential (Get-Credential) ...
    bash: syntax error near unexpected token `('
    ```

    Use `-ZwaveJsUser` instead. It takes a plain username, needs no
    sub-expression, and so reaches PowerShell untouched:

    ```bash
    pwsh ./Rename-Domoticz-From-ZwaveJSON.ps1 -ZwaveJsUrl "http://localhost:8091" \
        -DbPath "/home/user/docker/data/domoticz/config/domoticz.db" \
        -ZwaveJsUser admin -DryRun
    ```

    If you would rather be prompted for the username too, hand the whole command
    to PowerShell in single quotes so the shell leaves the parentheses alone:

    ```bash
    pwsh -c './Rename-Domoticz-From-ZwaveJSON.ps1 -ZwaveJsUrl "http://localhost:8091" -DbPath "/home/user/domoticz.db" -ZwaveJsCredential (Get-Credential) -DryRun'
    ```

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
