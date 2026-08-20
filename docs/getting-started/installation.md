# Installation

By the end of this page you will have PowerShell 7 installed, the tool on disk,
its SQLite assemblies provisioned, and the path to your Domoticz database in
hand. That is everything [Your first run](first-run.md) needs.

The tool runs on Windows, macOS and Linux, on x64 and on ARM. Running it on a
Raspberry Pi works and is a well-trodden path: install PowerShell 7 first, and
`setup.ps1` handles the architecture-specific parts for you.

## What you need

- **PowerShell 7.0 or newer.** Step 1 installs it. Windows PowerShell 5.1, the
  blue `powershell.exe` that ships with Windows, will **not** work.
- **git**, to fetch and update the tool. There is a no-git route in step 2 if
  you would rather not install it.
- **Internet access once**, so step 3 can download the SQLite assemblies. Normal
  use afterwards needs no internet.
- **A Z-Wave JS UI data source**: a running instance the script can read from,
  or a JSON export. See [Input modes](input-modes.md).
- **Read and write access to your Domoticz database file.** Step 4 finds it.

You do **not** need a system-wide SQLite install, and you do not need the older
PSSQLite PowerShell module.

## Step 1: Install PowerShell 7

=== "Windows"

    ```powershell
    winget install --id Microsoft.PowerShell --source winget
    ```

    This installs alongside the built-in Windows PowerShell rather than
    replacing it. Afterwards, use the **`pwsh`** command, not `powershell`.

=== "macOS"

    ```bash
    brew install --cask powershell
    ```

=== "Debian, Ubuntu"

    The simplest route is the snap:

    ```bash
    sudo snap install powershell --classic
    ```

    If you would rather use apt, Microsoft publishes a repository; follow their
    current instructions for your release, since the package URLs change with
    each Debian and Ubuntu version.

=== "Raspberry Pi, other ARM Linux"

    This is a supported and regularly used route. Microsoft's apt repository
    carries no ARM builds, so install from the release tarball.

    First, check which build you need:

    ```bash
    uname -m
    ```

    `aarch64` means use `linux-arm64`. `armv7l` means use `linux-arm32`.

    Then, substituting the current version from the PowerShell releases page
    and the architecture you just determined:

    ```bash
    VER=7.6.5                      # check the releases page for the current one
    ARCH=linux-arm64               # or linux-arm32 on a 32-bit OS

    sudo apt update
    sudo apt install -y wget

    wget "https://github.com/PowerShell/PowerShell/releases/download/v${VER}/powershell-${VER}-${ARCH}.tar.gz"
    sudo mkdir -p /opt/microsoft/powershell/7
    sudo tar zxf "powershell-${VER}-${ARCH}.tar.gz" -C /opt/microsoft/powershell/7
    sudo chmod +x /opt/microsoft/powershell/7/pwsh
    sudo ln -sf /opt/microsoft/powershell/7/pwsh /usr/bin/pwsh
    ```

    If `pwsh` then fails to start with a missing-library error, install the
    library it names; the exact prerequisites differ between Raspberry Pi OS
    releases, and recent PowerShell versions need fewer of them.

    `setup.ps1` in step 3 then picks the matching native SQLite build for your
    Pi automatically, which is what makes the tool work here at all.

=== "Fedora, RHEL"

    Microsoft publishes an RPM repository; follow their current instructions for
    your release, then:

    ```bash
    sudo dnf install powershell
    ```

Whichever route you took, confirm it worked:

```bash
pwsh --version
```

That must print `7.0` or higher. If the command is not found, PowerShell 7 is
not on your path yet.

## Step 2: Get the tool

**Use the `dist` branch unless you have a reason not to.** It is the recommended
route for anyone who wants to *run* the tool rather than work on it, for three
reasons:

- **It only ever holds released states.** The branch is re-synced when a release
  is published, so whatever you pull has been through a release. `main` moves
  continuously and can contain work that is not in any release yet.
- **It contains only what runs.** The script, `setup.ps1`, the rules file, the
  two modules, the readme and the licence. No test suite, no documentation
  source, no CI configuration to sift through or accidentally edit.
- **Updating is one command** that is always a fast-forward, because the sync
  history is linear.

Choose the full clone instead if you want to run the Pester tests, change the
code, or read this documentation offline.

=== "Runtime only (recommended)"

    ```bash
    git clone -b dist https://github.com/Rouzax/Rename-Domoticz-From-ZwaveJSON.git
    cd Rename-Domoticz-From-ZwaveJSON
    ```

    To move to a newer release later:

    ```bash
    git pull
    ```

    You do not need to re-run `setup.ps1` after a pull. The update leaves `lib/`
    alone.

=== "Full clone"

    ```bash
    git clone https://github.com/Rouzax/Rename-Domoticz-From-ZwaveJSON.git
    cd Rename-Domoticz-From-ZwaveJSON
    ```

    Tracks `main`, and adds the documentation source, the Pester tests and the
    workflow files alongside the runtime files.

=== "No git"

    On the repository page, use the **Code** button and download a zip. Switch
    to the `dist` branch first if you want only the runtime files.

    Updating then means downloading a fresh zip and re-extracting, rather than
    pulling, so prefer git if you expect to update.

## Step 3: Provision the SQLite assemblies

From inside the folder you just created:

```bash
pwsh ./setup.ps1
```

On Windows you can write `.\setup.ps1` instead; PowerShell accepts both slash
directions, so `./setup.ps1` works everywhere.

This is a **per-machine** step, not a per-run step. Run it once on each machine
that will run the tool. Re-run it only when the pinned package versions change,
or pass `-Force` to redownload even when `lib/` already looks complete.

`setup.ps1` detects your operating system and CPU architecture, downloads the
matching packages from nuget.org, verifies each one against a pinned SHA-256
checksum, and extracts what the script needs into a local `lib/` folder. If a
checksum does not match, setup stops with an error rather than using the file.

### What lands in lib/

`lib/` is **not committed to git**, so each machine provisions its own copy. It
holds:

- Three managed assemblies, identical on every platform:
  `SQLitePCLRaw.core.dll`, `SQLitePCLRaw.provider.e_sqlite3.dll` and
  `Microsoft.Data.Sqlite.dll`.
- One native SQLite library matched to **this machine**: `e_sqlite3.dll` on
  Windows, `libe_sqlite3.dylib` on macOS, `libe_sqlite3.so` on Linux.
- `provisioned.json`, recording which package versions were installed.

Choosing the native library per machine, down to the CPU architecture, is what
lets the tool run on ARM as well as x64 and Apple Silicon. If no native build
exists for your exact OS and CPU combination, setup stops and names the runtime
identifier it looked for, rather than installing something that cannot load.

## Step 4: Find your Domoticz database

The file is called `domoticz.db` and lives in Domoticz's **userdata folder**.
That folder defaults to the application folder, so unless Domoticz was started
with `-userdata` or `-dbase`, the database sits next to the Domoticz binary.

=== "Windows"

    Typically:

    ```text
    C:\Program Files (x86)\Domoticz\domoticz.db
    ```

    To confirm what the service actually uses, inspect its command line:

    ```powershell
    Get-CimInstance Win32_Service -Filter "Name like '%omoticz%'" |
        Select-Object Name, PathName
    ```

    A `-userdata` or `-dbase` argument in `PathName` overrides the default.

=== "Linux"

    Depends how Domoticz was installed. Common locations:

    ```text
    ~/domoticz/domoticz.db
    /opt/domoticz/domoticz.db
    /home/pi/domoticz/domoticz.db
    ```

    To confirm, look at the running process:

    ```bash
    ps -eo args | grep -i '[d]omoticz'
    ```

    Watch for `-userdata` or `-dbase`; either one overrides the default.

=== "Docker"

    Inside the container the userdata folder is usually `/opt/domoticz/userdata`,
    but what matters is the **host** path you bind-mounted there, because that is
    the path you pass to the script.

    ```bash
    docker inspect --format '{{range .Mounts}}{{.Source}} -> {{.Destination}}{{println}}{{end}}' <container>
    ```

    The host side of the mount holding `domoticz.db` is your `-DbPath`.

!!! warning "Work on a copy first if you are unsure"

    The script backs the database up automatically before applying changes, and
    `-DryRun` never writes at all. Even so, if you are not certain you have the
    right file, copy it somewhere and point `-DbPath` at the copy for your first
    run.

## Step 5: Know how to stop Domoticz

You do not need to stop Domoticz to **preview** changes, and `-DryRun` is always
safe. You do need to stop it before **applying** them: Domoticz caches device
rows in memory and can write them back on shutdown, silently undoing renames.

The script warns you if it detects the database is held open by another process,
but that check is best effort. Stopping Domoticz first is the real rule.

=== "Windows"

    ```powershell
    Stop-Service Domoticz
    # ... apply the rename, then:
    Start-Service Domoticz
    ```

=== "Linux (systemd)"

    ```bash
    sudo systemctl stop domoticz
    # ... apply the rename, then:
    sudo systemctl start domoticz
    ```

=== "Docker"

    ```bash
    docker compose stop domoticz
    # ... apply the rename, then:
    docker compose start domoticz
    ```

    Service and container names vary; use whatever yours is called.

## Next

You now have everything you need. Continue to
[Your first run](first-run.md).
