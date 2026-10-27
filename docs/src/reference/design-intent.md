# Design intent file

Some ERC rules need facts about the chip that no process deck can know: its supply voltages, its
power states, and the limits each net must meet. You state them in a JSON file and pass it with
`--intent`. This page lists every field of that file.

```sh
gpurify erc layout.gds --deck process.deck --intent intent.json
```

## A complete file

```json
{
  "temperature_c": 105,
  "domains": {
    "core": { "voltage_mv": 1800 },
    "io":   { "voltage_mv": 3300 }
  },
  "supplies": [
    { "net": "VDD",    "domain": "core", "role": "power" },
    { "net": "VSS",    "domain": "core", "role": "ground" },
    { "net": "VDDIO",  "domain": "io",   "role": "power" },
    { "net": "VDD_SW", "domain": "core", "role": "power" }
  ],
  "limits": [
    { "net": "VDD", "max_drop_mv": 90, "max_drop_fraction": 0.05,
      "max_overvoltage_mv": 100, "budget_current_ua": 2000,
      "rms_current_ua": 1500, "peak_current_ua": 4000, "frequency_mhz": 100,
      "dynamic": { "max_drop_mv": 180, "toggle_rate": 0.2,
                   "clock_period_ps": 2000, "rise_time_ps": 100,
                   "decap_pf": 50 } }
  ],
  "states": [
    { "name": "sleep",   "off": ["VDD_SW"] },
    { "name": "disable", "inputs": [{ "net": "EN", "voltage_mv": 0 }] }
  ],
  "net_types": [
    { "type": "pad",      "nets": ["PAD?"] },
    { "type": "gates",    "models": ["nfet", "pfet"], "pins": ["g"] },
    { "type": "not_nfet", "models": ["!", "nfet"] }
  ],
  "type_sets": [
    { "set": "io_nets", "types": ["pad", "gates"] }
  ]
}
```

Every section is optional. Each field's unit is in its name: `_mv` millivolts, `_ua` microamperes,
`_ps` picoseconds, `_pf` picofarads, `_mhz` megahertz, `_c` degrees Celsius. Numbers are plain
JSON numbers.

GPurify reads the file strictly. An unknown key, a key given twice, or a value of the wrong type
refuses the file with its line and column, so a misspelt limit cannot silently switch a rule off:

```text
error: intent bad_intent.json: Malformed
  malformed intent file: UnknownField at line 1 column 132
```

## Nets

Every net in the file is named by the text labels of the layout (see
[Connectivity](deck/connectivity.md#labels)). A net the file names that the layout has no label for
is not in the run. When none of the file's supplies and limited nets is in the layout, the rules
that need intent report `skipped`, as if no file had been given.

## temperature_c

The junction temperature, in °C, that the `electromigration`, `em_thermal` and `reliability` rules
derate to. It must be above absolute zero. Without it, those rules use the deck's
[`temperature`](deck/extraction.md#temperature) line; with neither, they are refused.

## domains

```json
"domains": { "core": { "voltage_mv": 1800 } }
```

An object of named voltage domains, each with its nominal voltage in mV, `voltage_mv`, any finite
number. A file declares at most 64 domains, and every domain needs at least one supply net.

## supplies

```json
"supplies": [{ "net": "VDD", "domain": "core", "role": "power" }]
```

The supply nets. Each names its net, its domain (declared in `domains`) and its role:

| Role | Voltage | Drop |
|---|---|---|
| `power` | Its domain's voltage | How far it falls |
| `ground` | 0 V | How far it rises (ground bounce) |

A net is listed once. Give every separately powered supply its own domain: each power net's domain
is the power domain of the signals it drives.

The supplies set the voltages the overstress and domain rules check. Every other net can reach
anything between the lowest and highest supply connected to it through transistor channels,
resistors, diodes and bipolar transistors; gates and capacitors pass nothing. A transistor whose
`device` row states `on_gate_min` or `on_gate_max` passes voltage only while its gate can turn it
on (see [Devices](deck/devices.md#gate-conditions)). The supplies also orient each transistor
channel for `multiple_drivers` and `tie_high_low`.

## limits

```json
"limits": [{ "net": "VDD", "max_drop_mv": 90, "budget_current_ua": 2000 }]
```

The limits each net must meet, one entry per net. Every field but `net` is optional, and every
stated value is a positive, finite number. A limit left out means that net is not checked for it,
never that it is unlimited.

| Field | Unit | Meaning | Read by |
|---|---|---|---|
| `max_drop_mv` | mV | The largest static drop allowed at any node: for a power net how far it falls, for a ground how far it rises | `ir_drop` |
| `max_drop_fraction` | fraction | The same, as a fraction of the domain's voltage, for either role | `ir_drop` |
| `max_overvoltage_mv` | mV | How far a node may rise above its supply | `ir_drop` |
| `budget_current_ua` | µA | The net's total current, shared evenly by its loads | The power-grid and electromigration rules |
| `rms_current_ua` | µA | The net's RMS current, shared among its loads as the budget is | `em_rms` |
| `peak_current_ua` | µA | The net's peak current, shared the same way | `em_peak` |
| `frequency_mhz` | MHz | The frequency the net switches at, which picks the row of a table that states several | `em_rms`, `em_peak` |
| `dynamic` | object | The net's worst clock cycle (below) | `dynamic_ir_drop` |

Each limit is checked on its own: a net with both `max_drop_mv` and `max_drop_fraction` must meet
both. With `max_drop_fraction 0.05` on a 1800 mV domain, a drop above 90 mV fails. The loads of the
RMS and peak currents are taken to draw one waveform in phase. A current budget on a net that no
device terminal reaches is refused rather than ignored, because zero current would pass every
limit.

### dynamic

```json
"dynamic": { "max_drop_mv": 180, "toggle_rate": 0.2, "clock_period_ps": 2000,
             "rise_time_ps": 100, "decap_pf": 50 }
```

What `dynamic_ir_drop` simulates on the net: in its worst clock cycle every load switches at once,
each drawing its share of `budget_current_ua` over the fraction of cycles it switches in, as a
triangular pulse, while the decoupling capacitance holds the net up.

| Field | Unit | Meaning |
|---|---|---|
| `max_drop_mv` | mV | The limit on the static drop plus the cycle's dynamic drop. Required. |
| `toggle_rate` | fraction | The fraction of cycles a load switches in, above 0 and at most 1. Required. |
| `clock_period_ps` | ps | The clock period. Required. |
| `rise_time_ps` | ps | The width of each current pulse, at most the clock period. Required. |
| `decap_pf` | pF | Decoupling capacitance on the net, zero or more. Defaults to 0. |

A `dynamic` entry needs the net's `budget_current_ua` beside it, since that is the charge it
switches.

## states

```json
"states": [
  { "name": "sleep",   "off": ["VDD_SW"] },
  { "name": "disable", "inputs": [{ "net": "EN", "voltage_mv": 0 }] }
]
```

The power states `undriven_gate`, `missing_isolation` and `power_switch` read. Each state has a
unique `name`, and lists the supplies switched `off` and the `inputs` held at a voltage while it
lasts. Every supply not in `off` stays on.

- In a state, a switched-off supply holds no voltage, and a held input is a supply at its voltage
  (a ground when it is 0 mV).
- Voltages are propagated again for each state, gate conditions included, so a disabled tristate
  driver leaves its output floating.
- A state turns off only declared supplies, and holds an input once.

## net_types

```json
"net_types": [
  { "type": "pad",      "nets": ["PAD?"] },
  { "type": "gates",    "models": ["nfet", "pfet"], "pins": ["g"] },
  { "type": "not_nfet", "models": ["!", "nfet"] }
]
```

Net types for the `net_type` rule, after the net types of Mentor's PERC patent (US 2010/0306720 A1).
Each entry names a `type` and assigns it one of two ways:

- **By name:** `nets` lists net names, each matched against the whole of a net's label. `?` matches
  any run of characters. `lvsPower` and `lvsGround` stand for the declared power and ground
  supplies, and `lvsOutline` for every labelled net.
- **By device:** `models` lists device models, and the type goes to the nets on those devices'
  `pins`, or on every pin when `pins` is left out. A leading `"!"` in `models` means every model
  but the ones listed. Pins are `g`, `s`, `d`, `b` (MOS), `c`, `b`, `e` (bipolar), and `pos`,
  `neg`.

An entry states `nets` or `models`, never both and never neither. A net can have several types.

## type_sets

```json
"type_sets": [{ "set": "io_nets", "types": ["pad", "gates"] }]
```

A type set is the union of its types, for the `net_type` rule's conditions. A set may name types
and earlier sets, and its own name may not repeat a type's or another set's. A file declares at
most 64 types and sets together.

## Which rules need intent

The ERC rules that read voltages, currents or power states report `skipped` without a usable
intent file, never clean. Among them are the voltage rules (`gate_oxide`, `drain_source`,
`well_bias`, `hv_domain`, `missing_level_shifter`, `domain_crossing`, `voltage_space`,
`dielectric_field`, `hv_tag`), the power-grid and electromigration rules (`ir_drop`,
`dynamic_ir_drop`, `em_current_density`, `electromigration`, `em_rms`, `em_peak`, `em_thermal`,
`reliability`), and the state rules (`undriven_gate`, `missing_isolation`, `power_switch`). Each
rule's entry on the [ERC checks](erc/README.md) page says what it reads.

With `rule TIE tie_high_low()` and `rule OX gate_oxide(; models: ["nfet"], max: 1.98V)` in the
deck of the [Devices example](deck/devices.md#example), run without `--intent`:

```text
rules:
  TIE: skipped, no design intent was supplied, examined 0 shapes, found 0 violations
  OX: skipped, no design intent was supplied, examined 0 shapes, found 0 violations
...
```

> [!WARNING]
> A rule reported `skipped` for want of intent looked at nothing, and the run fails. Check that
> the file's net names match the layout's labels exactly.

## Refusals

GPurify refuses the file, and the run, with the reason:

| Refusal | Cause |
|---|---|
| `Malformed` | Not JSON of this schema; more than 64 domains; a voltage, temperature or held input that is not a finite number; a supply naming an undeclared domain; two `limits` entries for one net; a `dynamic` entry without a budget, with a toggle rate above 1 or a rise longer than the period; a state repeating a name, turning off an undeclared supply or holding an input twice; a net type with both or neither of `nets` and `models`, an unknown pin, or no model; a type set naming an unknown type; more than 64 types and sets |
| `DomainConflict` | A net listed more than once in `supplies` |
| `DomainWithoutSupply` | A declared domain with no supply net |
| `BadLimit` | A stated limit that is zero, negative or not finite |

```text
error: intent bad2.json: DomainWithoutSupply
  domain io has no supply net
```
