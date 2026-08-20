# How naming works

This page explains where a proposed name comes from: the pieces the script
combines, how it builds the DeviceID it matches rules against, and the two
special cases (node-level devices and the `$` prefix) that change the
usual pattern. For the mechanics of writing your own rules, see
[Writing your own rules](writing-rules.md).

## The naming scheme

Every proposed name is built from three pieces of Z-Wave JS UI data, joined
with ` - `:

```
Room - Device - Label
```

- **Room** comes from the node's `loc` (location) field.
- **Device** comes from the node's `name` field.
- **Label** comes from the Z-Wave value's `label` field, for example
  `Air temperature` or `Current Value`.

If any piece is empty, it is dropped rather than leaving a stray ` - ` in
the name. Renaming rules can then shorten or drop the label further; see
[Bundled rules](writing-rules.md#bundled-rules) for what ships with the
tool by default.

## How the DeviceID is built

The script does not match rules against the name; it matches them against
the DeviceID, which is built independently:

```
{BaseIdentifier}_{PropertyID}
```

`BaseIdentifier` is read once per run, from the `identifiers` field of the
first Home Assistant discovery payload found in the node data
(`hassDevices[].discovery_payload.device.identifiers`). It looks like
`zwavejs2mqtt_0xc15d8aa6`. `PropertyID` is the Z-Wave value's own `id`, for
example `42-49-0-Air_temperature`.

Two substitutions are then applied to the combined string, matching what
Domoticz itself does to DeviceID values:

- Spaces become underscores.
- Forward slashes become hyphens.

So a room named `Living Room/Hall` combined with a property ID that
contains a space ends up as a single DeviceID with no spaces or slashes,
for example `zwavejs2mqtt_0xc15d8aa6_42-49-0-Air_temperature`.

## Built-in label shortening

Before any custom rule file is even considered, a small set of built-in
shortenings is available as a fallback: if you downloaded only the `.ps1`
script and have no `rename_rules.json` next to it, these are the only
rules applied. They trim a handful of long Z-Wave labels down to
something readable:

- `Current Value` is dropped entirely from dimmer (Multilevel Switch) and
  binary switch labels on endpoint 0 or 1.
- `Electric Consumption [W]` and `Electric Consumption [kWh]` shorten to
  `[W]` and `[kWh]`.
- `Air temperature` shortens to `Temp`.
- `Illuminance` shortens to `Lux`.
- `Motion sensor status` shortens to `Motion`.

The full rule set that ships with the repository (`rename_rules.json`)
covers far more device types than this fallback; see
[Bundled rules](writing-rules.md#bundled-rules) for how it is loaded and
[Writing your own rules](writing-rules.md) for how to extend it.

## Node-level devices (combined Temp+Humidity)

Some multisensors report temperature and humidity as separate Z-Wave
values, but Domoticz merges them into a single device (Domoticz Type 82,
Temp+Humidity, or Type 84, Temp+Humidity+Baro) with a DeviceID like
`{BaseIdentifier}_node<id>` that has no individual Z-Wave value behind it.

The script renames these too, using a shorter form of the same scheme:

- Temp+Humidity or Temp+Humidity+Baro devices become `Room - Device - Climate`.
- Any other node-level device becomes `Room - Device`, with no label.

This runs through the same dry-run, rules, and collision detection as
every other device. If you would rather leave node-level devices
untouched, exclude them by pattern, since their DeviceID always ends in
`node<id>`:

```powershell
.\Rename-Domoticz-From-ZwaveJSON.ps1 -JsonFile "nodes_dump.json" -DbPath "domoticz.db" `
    -ExcludePattern 'node\d+$'
```

See [Excluding devices from a run](../using/running.md#excluding-devices)
for the other ways to exclude devices.

## The `$` prefix is preserved

If a device's current name in Domoticz already starts with `$`, the
proposed name keeps that prefix, even though nothing in the Z-Wave data
mentions it. The script only prepends it (it never strips one that a
matched rule already restored), so a `$`-prefixed device stays
`$`-prefixed across renames.
