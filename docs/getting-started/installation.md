# Installation

## Requirements

Before you run the script, make sure you have:

- **PowerShell 7.0+**. The script requires it (emoji support and
  `System.Web.HttpUtility`); Windows PowerShell 5.1 will not work.
- **Internet access on first setup**, so `setup.ps1` can download the SQLite
  assemblies once. No internet access is needed for normal use afterward.
- **A Z-Wave JS UI data source**: either a running instance the script can
  read from directly, or a JSON export of your nodes. See
  [Input modes](input-modes.md) for the difference and when to use each.

You do **not** need a system-wide SQLite install, and you do not need the
older PSSQLite PowerShell module. `setup.ps1` provisions everything the
script needs.

## One-time setup

Run the setup script once on each machine you plan to use the tool from:

```powershell
pwsh ./setup.ps1
```

This is a **per-machine** step, not a per-clone or per-run step: run it again
after pulling a fresh copy of the repository onto a machine that has never
run it, but you do not need to re-run it every time you use the script.
Re-run it (or `setup.ps1 -Force` to redownload even if `lib/` already looks
complete) only after the pinned package versions change.

`setup.ps1` detects your machine's operating system and CPU architecture,
downloads the matching packages from nuget.org, verifies each download
against a pinned SHA-256 checksum, and extracts the files the script needs
into a local `lib/` folder next to the script. If a checksum does not match,
setup refuses to use that download and stops with an error instead of
silently continuing.

## What setup.ps1 installs

Everything lands in `./lib`, which is **not committed to git** (it is listed
in `.gitignore`). Each machine provisions its own copy. `lib/` contains:

- Three managed assemblies that are the same on every platform:
  `SQLitePCLRaw.core.dll`, `SQLitePCLRaw.provider.e_sqlite3.dll`, and
  `Microsoft.Data.Sqlite.dll`.
- One native SQLite library, chosen to match **this specific machine's**
  operating system and CPU architecture: `e_sqlite3.dll` on Windows,
  `libe_sqlite3.dylib` on macOS, or `libe_sqlite3.so` on Linux.
- A `provisioned.json` manifest recording which package versions were
  installed, for diagnostics.

Picking the native library per machine, down to the CPU architecture, is
what lets the tool run on ARM (including a 64-bit Raspberry Pi) as well as
x64 and Apple Silicon. If `setup.ps1` cannot find a native SQLite build for
your machine's exact combination of OS and CPU, it stops with an error
naming the runtime identifier it was looking for, rather than installing
something that will not load.

Once setup has finished, continue to [Your first run](first-run.md).
