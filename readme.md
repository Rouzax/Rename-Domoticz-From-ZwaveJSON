# Domoticz Device Renamer for Z-Wave JS

Automatically rename your Domoticz devices based on the room and device names configured in Z-Wave JS UI.

**The problem:** When Z-Wave JS creates devices in Domoticz via MQTT Auto-Discovery, they get generic names like `zwavejs2mqtt_0xc15d8aa6_42-49-0-Air_temperature`. Finding the right device becomes a nightmare.

**The solution:** This script reads your Z-Wave JS node data, either from a JSON export or directly from a running zwave-js-ui instance, and renames devices to friendly names like `Living Room - Motion Sensor - Motion`, matching your Z-Wave JS configuration. It can also fix device types (so smoke detectors get a Reset button, motion sensors show the right icon, etc.).

<img width="987" height="830" alt="image" src="https://github.com/user-attachments/assets/5cba8a2c-f18f-4c16-8404-54a58ab996e0" />

---

## 🚀 Quick Start

1. **Run setup once per machine** to download the required SQLite assemblies:

   ```powershell
   pwsh ./setup.ps1
   ```

2. **Preview the changes** without touching the database:

   ```powershell
   .\Rename-Domoticz-From-ZwaveJSON.ps1 -JsonFile "nodes_dump.json" -DbPath "domoticz.db" -DryRun
   ```

3. **Review the HTML report**, then apply the changes for real:

   ```powershell
   .\Rename-Domoticz-From-ZwaveJSON.ps1 -JsonFile "nodes_dump.json" -DbPath "domoticz.db"
   ```

---

## 📥 Requirements

* **PowerShell 7.0+** (required for emoji support and System.Web.HttpUtility)
* **SQLite assemblies** provisioned by `setup.ps1`. No system SQLite or PSSQLite module is needed.
* **Z-Wave JS UI**, with either a JSON export or a live instance the script can read from directly; a manual export is no longer required
* **Internet access on first setup** (to download the SQLite assemblies once)

---

## 📚 Documentation

Full documentation: **<https://rouzax.github.io/Rename-Domoticz-From-ZwaveJSON/>**

- [Installation](https://rouzax.github.io/Rename-Domoticz-From-ZwaveJSON/getting-started/installation/)
- [Your first run](https://rouzax.github.io/Rename-Domoticz-From-ZwaveJSON/getting-started/first-run/)
- [Renaming rules](https://rouzax.github.io/Rename-Domoticz-From-ZwaveJSON/rules/naming/)
- [Troubleshooting](https://rouzax.github.io/Rename-Domoticz-From-ZwaveJSON/troubleshooting/)

---

## 📜 Changelog

See [CHANGELOG.md](CHANGELOG.md) for the full version history, or the
[GitHub Releases page](https://github.com/Rouzax/Rename-Domoticz-From-ZwaveJSON/releases)
for release notes.

---

⚠️ **DISCLAIMER:** This script modifies your database. Use it at your own risk! Always keep a backup of your Domoticz database before running. 🚀

---

## ❤️ Support

Building tools that solve my own problems and sharing them in the hope they solve yours too. Renaming a few hundred Z-Wave devices by hand in the Domoticz UI is an afternoon you do not get back.

[![ko-fi](https://ko-fi.com/img/githubbutton_sm.svg)](https://ko-fi.com/O0W221GBUG)
