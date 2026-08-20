# Name collisions

Two devices can end up wanting the same name, most often when a multisensor
exposes the same measurement on more than one endpoint, or when a device
moved endpoint after Domoticz already created a row for it under the old
one. This page explains how the script detects that, what it does about it
automatically, and the one case that needs you to act.

## How collisions are detected

Before proposing a rename, the script builds a table of every name that
will exist once the run finishes: every device that is keeping its current
name, plus every device that is about to be renamed. A collision is
anything that would put two devices on the same name in that end state.

This matters because it catches more than a clash between two pending
renames. A device you are not touching at all, one that already has the
name another device is about to be renamed to, still counts. The script
checks the full end state, not just the set of changes it is about to make.

## Automatic disambiguation

When the two devices sit on different Z-Wave endpoints, the script resolves
the collision on its own by appending an endpoint suffix, ` - EPn`, to the
name of whichever device would otherwise not get it. Both devices still
change (or keep) whatever else was pending; only the contested name is
adjusted. If both sides of the collision are themselves pending renames on
different endpoints, both get a suffix, so neither silently loses ground to
the other.

This is not treated as a failure. It is reported for visibility, because an
unexplained ` - EP0` on a device name is otherwise a mystery: the HTML
report's **Names Disambiguated** section lists every automatic resolution,
naming both the device that wanted the name and the device holding it, plus
whether the node source (your Z-Wave JS UI export or live connection) still
reports the device holding it, and that device's Domoticz `Used` flag and
`LastUpdate`.

## When a stale device blocks a name

Domoticz never deletes a `DeviceStatus` row on its own. If a Z-Wave value
moves to a different endpoint (or a device is replaced and re-included),
the old row stays in the database, keeps its name, and blocks the live
device that would now like that name. The endpoint suffix in the previous
section is what you see when this happens: it is not a bug, it is the
script refusing to overwrite a name it cannot yet prove is safe to reuse.

**Worked example.** A power meter used to report on endpoint 0. Domoticz
still has a device from when it also reported on endpoint 1; that endpoint
is gone from the current Z-Wave configuration, but Domoticz kept the row.
Both devices would propose the same name, `Living Room - Meter [W]`. The
console output calls this out:

```
  ✓ 1 name collision(s) auto-resolved with endpoint numbers
     1 of those blocked by a device no longer in the node source:
       - 'Living Room - Meter [W]' → Endpoint suffix EP0 appended
         held by zwavejs2mqtt_0xc15d8aa6_24-50-1-value-66049 (Used=0, last update 2026-05-14 00:06)
       Delete those in Domoticz to free the name, then re-run.
```

The HTML report shows the same event with both devices identified:

```
Living Room - Meter [W]                Endpoint suffix EP0 appended
  WANTED BY  zwavejs2mqtt_0xc15d8aa6_24-50-0-value-66049  [in node source]
  HELD BY    zwavejs2mqtt_0xc15d8aa6_24-50-1-value-66049  [not in node source, Used=0, last update 2026-05-14 00:06]
```

The live endpoint-0 device (`WANTED BY`, still in the node source) gets
`Living Room - Meter [W] - EP0` instead of the clean name, because the
stale endpoint-1 device (`HELD BY`, not in the node source) still owns it.
Deleting that stale device in Domoticz (**Setup → Devices**) and re-running
the script gives the live device the clean name.

Treat "not in node source" as a strong hint, not proof of death on its own.
zwave-js only creates notification, battery, and smoke sub-values after a
node first reports them, so a healthy but quiet device can be legitimately
absent from a node dump or a live read. `Used` and `LastUpdate` are shown
alongside it so you can judge each case rather than deleting on the
strength of one signal.

## Unresolvable collisions

Some collisions cannot be auto-resolved:

- Both devices are on the same endpoint, so a suffix would not tell them
  apart.
- An endpoint number could not be read from one of the DeviceIDs at all.
  This happens for some notification-type sub-values (battery, smoke,
  tamper) whose DeviceID does not carry an explicit endpoint segment.
- The disambiguated name, with the suffix already appended, is itself taken
  by a third device.

These are reported as unresolvable, and both devices are skipped entirely
for that run, not just the name: if either device also had a pending switch
type or custom image change, that change is dropped along with the rename,
and it will be proposed again on your next run.

The console lists up to five unresolvable collisions before continuing (or
prompting you to confirm, unless you passed `-Force` or `-DryRun`):

```
  ⚠️  WARNING: 1 unresolvable name collision(s) detected!
     The following names would be assigned to multiple devices:
       - 'Kitchen - Sensor - Tamper'
         → zwavejs2mqtt_0xc15d8aa6_71-notification-tamper
         → zwavejs2mqtt_0xc15d8aa6_72-notification-tamper
```

Here neither DeviceID carries a parseable endpoint segment, so the script
cannot tell the two devices apart with a suffix and reports the collision
instead of guessing.

An unresolvable collision means both devices keep their previous names for
this run. Fix the underlying cause (usually a stale device that also lacks
a usable endpoint, or a genuine naming clash from a renaming rule) and
run again.
