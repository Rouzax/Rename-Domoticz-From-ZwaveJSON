# Lookup tables

Reference values for the `switchType`, `customImage`, and endpoint-pattern
fields used in [renaming rules](writing-rules.md#rule-schema).

## SwitchType reference

Values a rule's `switchType` field can set, and what the script's HTML
report labels them as.

| Value | Type |
|-------|------|
| 0 | On/Off |
| 1 | Doorbell |
| 2 | Contact |
| 3 | Blinds |
| 4 | X10 Siren |
| 5 | Smoke Detector |
| 6 | Blinds Inverted |
| 7 | Dimmer |
| 8 | Motion Sensor |
| 9 | Push On Button |
| 10 | Push Off Button |
| 11 | Door Contact |
| 12 | Dusk Sensor |
| 13 | Blinds Percentage |
| 14 | Venetian Blinds US |
| 15 | Venetian Blinds EU |
| 16 | Blinds Percentage Inverted |
| 17 | Media Player |
| 18 | Selector |
| 19 | Door Lock |
| 20 | Door Lock Inverted |

## CustomImage reference

Values a rule's `customImage` field can set, and what the script's HTML
report labels them as. To find values for icons not listed here, query
your own database: `SELECT DISTINCT CustomImage, Name FROM DeviceStatus WHERE CustomImage > 0;`

| Value | Icon |
|-------|------|
| 0 | Default |
| 1 | Light |
| 2 | Fan |
| 9 | Computer |
| 10 | Phone |
| 13 | Alarm |
| 17 | Speaker |

## Endpoint pattern reference

Z-Wave devices use endpoints to distinguish channels; the endpoint number
appears in the DeviceID (for example `37-0-currentValue`,
`37-1-currentValue`, `37-2-currentValue`). These are the patterns rules
commonly use in `pattern` to target one or more endpoints.

| Pattern | Matches | Use case |
|---------|---------|----------|
| `[01]` | Endpoint 0 or 1 | Primary channel(s) only, the default in bundled rules |
| `\d+` | Any endpoint | All channels; may cause name collisions on multi-channel devices |
| `0` | Endpoint 0 only | Single-endpoint devices only |
| `1` | Endpoint 1 only | First channel of multi-endpoint devices |
| `[012]` | Endpoints 0, 1, or 2 | First three channels |
