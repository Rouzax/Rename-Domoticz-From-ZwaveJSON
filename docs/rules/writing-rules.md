# Writing your own rules

Renaming rules shorten labels and, optionally, fix a device's `SwitchType`
or `CustomImage` in Domoticz. This page covers the JSON format, how a rule
is matched against a device, and how to write your own. For where a
proposed name comes from before any rule touches it, see
[How naming works](naming.md).

## Bundled rules

The repository ships a `rename_rules.json` with 41 rules covering common
Z-Wave device types (smoke detectors, motion sensors, door contacts,
battery alerts, and more), including `switchType` and `customImage`
settings for the devices that need them.

When `rename_rules.json` sits next to the script itself and you do not pass
`-RulesFile`, it is loaded automatically. This is the script's own
directory, not your shell's current working directory: if you keep
`rename_rules.json` somewhere else and run the script from a different
folder, it will not be found, even though the current directory looks like
the natural place to look. If you downloaded only the `.ps1` file, there is
nothing next to it to find, and the script falls back to a small built-in
set that only shortens a handful of common labels; see
[Built-in label shortening](naming.md#built-in-label-shortening) for what
that fallback set covers.

To customize, copy `rename_rules.json`, edit it, and either keep the copy
next to the script (auto-loaded) or point to it explicitly:

```powershell
.\Rename-Domoticz-From-ZwaveJSON.ps1 -JsonFile "nodes_dump.json" -DbPath "domoticz.db" -RulesFile "my_rules.json"
```

### What a shipped rule looks like

These are the first three rules in the shipped file, unchanged apart from
trimmed `description` text. They are worth reading before you write your own,
because they show the one piece of rule behaviour that surprises people: three
rules can share a single `pattern` and all three still do useful work.

```json title="rename_rules.json (excerpt)"
{
  "rules": [
    {
      "name": "Central Scene KeyPressed",
      "pattern": "91-\\d+-scene-\\d+$", // (1)!
      "replace": " - KeyPressed$", // (2)!
      "with": " - Short",
      "description": "Central Scene: short press"
    },
    {
      "name": "Central Scene KeyReleased",
      "pattern": "91-\\d+-scene-\\d+$",
      "replace": " - KeyReleased$",
      "with": " - Released",
      "description": "Central Scene: key released after a hold"
    },
    {
      "name": "Central Scene KeyHeldDown", // (3)!
      "pattern": "91-\\d+-scene-\\d+$",
      "replace": " - KeyHeldDown$",
      "with": " - Held",
      "description": "Central Scene: key held down"
    }
  ]
}
```

1.  `91` is the Central Scene command class. All three rules carry the same
    `pattern` because Domoticz stores every key state of one button under a
    single DeviceID, so the DeviceID cannot tell a short press from a hold.
    See [Multi-unit devices](naming.md#multi-unit-devices).
2.  This is what actually separates the three, and it works because `replace`
    is matched against the name, which already carries the raw state text
    (`KeyPressed`, `KeyReleased`, `KeyHeldDown`) by the time rules run.
3.  Reaching the third rule is the normal path for a held key, not a fallback:
    a rule whose `pattern` matched but whose `replace` found nothing to change
    counts as having done nothing, so the next rule is tried. Only a rule that
    changes the name (or sets `switchType`/`customImage`) ends the search.

## Rule schema

```json
{
  "rules": [
    {
      "name": "Rule display name", // (1)!
      "pattern": "regex pattern to match DeviceID$", // (2)!
      "replace": "regex pattern to match in device name$", // (3)!
      "with": "replacement string", // (4)!
      "nodeMatch": { "productLabel": "regex to match product label" }, // (5)!
      "switchType": 5, // (6)!
      "customImage": 13, // (7)!
      "description": "Optional description" // (8)!
    }
  ]
}
```

1.  Written to the [run log](../using/output.md#log-file) whenever the rule
    actually changes a name, so it is how you tell which of several
    overlapping rules won. Give it a name you would recognise in a list of 41.
2.  Matched against the DeviceID, which is not the string you see in
    Domoticz's device list. Anchor it with `$`: without the anchor,
    `37-0-currentValue` also matches a DeviceID that merely contains that text,
    and the rule fires on devices you never meant to touch.
3.  This one is matched against the *name*, not the DeviceID, and the name at
    this point is the full `Room - Device - Label` string. Anchoring with `$`
    (as every bundled rule does) keeps the replacement to the trailing label,
    so it cannot chew into a room or device name that happens to contain the
    same words.
4.  An empty string deletes whatever `replace` matched. That is how the bundled
    rules drop ` - Current value` entirely, and it is also the fastest way to
    create [name collisions](../using/collisions.md), because two endpoints
    that differed only by that label now want the same name. PowerShell's
    replacement syntax applies here, so `$1` inserts the first capture group
    from `replace`.
5.  Checked *before* `pattern`, against the node rather than the device: if any
    key you list fails to match, the whole rule is skipped for that node. The
    values are regexes, not exact strings, so `FGRGBW` matches a
    `productLabel` of `FGRGBW-442`.
6.  Applied whenever `pattern` matches, even if `replace` changed nothing about
    the name, so a rule can exist purely to fix a device type. Values are in
    the [SwitchType reference](lookup-tables.md#switchtype-reference).
7.  Same again: a `pattern` match is enough. `switchType` and `customImage` are
    independent, so a rule may set either, both, or neither. Values are in the
    [CustomImage reference](lookup-tables.md#customimage-reference).
8.  Never read by the script. It is there for the next person to open
    `rename_rules.json` and wonder why the rule exists.

`name`, `pattern`, `replace`, and `with` are required on every rule.
`nodeMatch`, `switchType`, `customImage`, and `description` are optional and
can be left out entirely.

Use `\\[` and `\\]` to escape literal brackets inside a `pattern` or
`replace` string, since the file is JSON as well as regex.

## How matching works

1. Rules are tried in file order. The **first rule that actually does
   something wins**: the first whose `pattern` matches the DeviceID and
   that either changes the name or carries a `switchType` or
   `customImage`. No later rule is consulted for that device, even if it
   would also match. A rule whose `pattern` matches but that changes
   nothing is skipped over, so several rules may share one `pattern` and
   differ only in what they `replace` (the bundled Central Scene rules do
   exactly this, because one DeviceID covers several key states).
2. `pattern` is tested against the **DeviceID**, not the name. See
   [How the DeviceID is built](naming.md#how-the-deviceid-is-built) for
   what that string looks like, including the endpoint number it
   carries; see [Lookup tables](lookup-tables.md#endpoint-pattern-reference)
   for the endpoint patterns rules commonly use.
3. If `pattern` matches, `replace` is tested against the **device name**
   built from `Room - Device - Label`, and the matched portion is
   substituted with `with`. If `replace` does not match anything in the
   name, the rule still counts as matched **if** it carries a
   `switchType` or `customImage` (those still apply, and the name is left
   unchanged). If it carries neither, the rule had no effect at all and
   the next rule is tried.
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
  "pattern": "37-\\d+-currentValue$", // (1)!
  "replace": " - Current value$",
  "with": "" // (2)!
}
```

1.  `37` is the Binary Switch command class and `\d+` is the endpoint, so this
    matches every channel of a multi-channel switch, not just the first.
2.  With the label gone, a two-channel switch produces two devices both called
    `Room - Device`. The tool will not write a duplicate: it appends ` - EP2`
    where it safely can and skips the rest. See
    [Name collisions](../using/collisions.md).

**Remove a suffix from endpoint 0 only**:

```json
{
  "pattern": "37-0-currentValue$", // (1)!
  "replace": " - Current value$",
  "with": ""
}
```

1.  Pinning the endpoint to `0` is the safe version of the rule above: a
    single-endpoint switch is renamed, and the extra channels of a
    multi-channel device keep their label and stay distinguishable.

**Fix the Domoticz device type for a smoke sensor.** This is the actual
bundled rule for a Notification CC smoke sensor; it renames the label and
sets SwitchType so Domoticz shows a Reset button:

```json
{
  "name": "Smoke Alarm Sensor",
  "pattern": "113-\\d+-Smoke_Alarm-Sensor_status$", // (1)!
  "replace": " - Sensor status$",
  "with": " - Smoke Alarm",
  "switchType": 5, // (2)!
  "description": "Renames smoke detection sensor. Sets Smoke Detector type with Reset button."
}
```

1.  `113` is the Notification command class, which reports many alarm types
    under one class, so the property name (`Smoke_Alarm-Sensor_status`) is what
    narrows this to smoke rather than the class number.
2.  `5` is Domoticz's Smoke Detector type, and setting it is the whole point of
    the rule: it is what makes Domoticz show a Reset button on the device. It
    is applied on a `pattern` match whether or not the rename happens, so the
    device type gets fixed even on a re-run where the name is already correct.

**Scope a rule to a specific device type** with `nodeMatch`, so it only
touches nodes that report a particular product. This is the actual
bundled rule for one channel of a Fibaro RGBW controller:

```json
{
  "name": "RGBW Red Channel",
  "pattern": "38-2-currentValue$", // (1)!
  "replace": " - Current value$",
  "with": " - Red",
  "nodeMatch": { "productLabel": "FGRGBW" }, // (2)!
  "description": "Fibaro RGBW Controller red channel (endpoint 2)"
}
```

1.  Endpoint `2` is the red channel on this controller. The bundled file
    carries one such rule per channel (endpoints 2 to 5 for the colours, and
    four more for their voltage values), which is why colour names can be
    hard-coded at all.
2.  Without this, the rule would match endpoint 2 on every device with a
    Multilevel Switch value (dimmers, blinds, and more) and label it `Red`.
    `nodeMatch` restricts it to nodes whose `productLabel` matches the regex
    `FGRGBW`.

`nodeMatch` is checked against the node's own `productLabel`,
`productDescription`, and `manufacturer` fields, so it is the tool to reach for
whenever a rule is only correct for one make of device.
