# Writing your own rules

Renaming rules shorten labels and, optionally, fix a device's `SwitchType`
or `CustomImage` in Domoticz. This page covers the JSON format, how a rule
is matched against a device, and how to write your own. For where a
proposed name comes from before any rule touches it, see
[How naming works](naming.md).

## Bundled rules

The repository ships a `rename_rules.json` with 38 rules covering common
Z-Wave device types (smoke detectors, motion sensors, door contacts,
battery alerts, and more), including `switchType` and `customImage`
settings for the devices that need them.

When you run the script from the repository directory and do not pass
`-RulesFile`, this file is loaded automatically. If you downloaded only
the `.ps1` file, `rename_rules.json` is not there to find, and the script
falls back to a small built-in set that only shortens a handful of common
labels; see [Built-in label shortening](naming.md#built-in-label-shortening)
for what that fallback set covers.

To customize, copy `rename_rules.json`, edit it, and either keep the copy
next to the script (auto-loaded) or point to it explicitly:

```powershell
.\Rename-Domoticz-From-ZwaveJSON.ps1 -JsonFile "nodes_dump.json" -DbPath "domoticz.db" -RulesFile "my_rules.json"
```

## Rule schema

```json
{
  "rules": [
    {
      "name": "Rule display name",
      "pattern": "regex pattern to match DeviceID$",
      "replace": "regex pattern to match in device name$",
      "with": "replacement string",
      "nodeMatch": { "productLabel": "regex to match product label" },
      "switchType": 5,
      "customImage": 13,
      "description": "Optional description"
    }
  ]
}
```

| Field | Required | Purpose |
|-------|----------|---------|
| `name` | Yes | Shown in logs when the rule fires. |
| `pattern` | Yes | Regex matched against the DeviceID. |
| `replace` | Yes | Regex matched against the device name. |
| `with` | Yes | Replacement text for whatever `replace` matched. |
| `nodeMatch` | No | Scopes the rule to nodes with matching properties. |
| `switchType` | No | Domoticz SwitchType to set on a match. See [Lookup tables](lookup-tables.md#switchtype-reference). |
| `customImage` | No | Domoticz CustomImage icon to set on a match. See [Lookup tables](lookup-tables.md#customimage-reference). |
| `description` | No | Not used by the script; documents intent for humans. |

Use `\\[` and `\\]` to escape literal brackets inside a `pattern` or
`replace` string, since the file is JSON as well as regex.

## How matching works

1. Rules are tried in file order. The **first rule whose `pattern`
   matches wins**; no later rule is consulted for that device, even if it
   would also match.
2. `pattern` is tested against the **DeviceID**, not the name. See
   [How the DeviceID is built](naming.md#how-the-deviceid-is-built) for
   what that string looks like, including the endpoint number it
   carries; see [Lookup tables](lookup-tables.md#endpoint-pattern-reference)
   for the endpoint patterns rules commonly use.
3. If `pattern` matches, `replace` is tested against the **device name**
   built from `Room - Device - Label`, and the matched portion is
   substituted with `with`. If `replace` does not match anything in the
   name, the rule still counts as matched (its `switchType`/`customImage`
   still apply); the name is just unchanged by this step.
4. `nodeMatch`, when present, is an object of regexes checked against the
   node's `productLabel`, `productDescription`, and `manufacturer`. Every
   key you include must match for the rule to apply; a rule with no
   `nodeMatch` applies to every device whose DeviceID matches `pattern`.
5. `switchType` and `customImage`, when present, are applied to the
   device regardless of whether `replace` changed the name.

## Examples

**Remove a suffix from every endpoint** (use with caution, this can cause
name collisions between endpoints; see
[Endpoint pattern reference](lookup-tables.md#endpoint-pattern-reference)):

```json
{
  "pattern": "37-\\d+-currentValue$",
  "replace": " - Current value$",
  "with": ""
}
```

**Remove a suffix from endpoint 0 only**:

```json
{
  "pattern": "37-0-currentValue$",
  "replace": " - Current value$",
  "with": ""
}
```

**Fix the Domoticz device type for a smoke sensor.** This is the actual
bundled rule for a Notification CC smoke sensor; it renames the label and
sets SwitchType so Domoticz shows a Reset button:

```json
{
  "name": "Smoke Alarm Sensor",
  "pattern": "113-\\d+-Smoke_Alarm-Sensor_status$",
  "replace": " - Sensor status$",
  "with": " - Smoke Alarm",
  "switchType": 5,
  "description": "Renames smoke detection sensor. Sets Smoke Detector type with Reset button."
}
```

**Scope a rule to a specific device type** with `nodeMatch`, so it only
touches nodes that report a particular product. This is the actual
bundled rule for one channel of a Fibaro RGBW controller:

```json
{
  "name": "RGBW Red Channel",
  "pattern": "38-2-currentValue$",
  "replace": " - Current value$",
  "with": " - Red",
  "nodeMatch": { "productLabel": "FGRGBW" },
  "description": "Fibaro RGBW Controller red channel (endpoint 2)"
}
```

Without `nodeMatch`, this rule would match endpoint 2 on every device that
has a Multilevel Switch value (dimmers, blinds, and more), not only RGBW
controllers. `nodeMatch` restricts it to nodes whose `productLabel`
matches the regex `FGRGBW`.
