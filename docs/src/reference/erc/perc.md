# Programmable electrical checks

Programmable electrical checks look at the extracted transistor netlist for circuit patterns that
fail in silicon although every net is connected: leakage in a power state, mismatched analog
devices, long paths to a rail and heavy loads. You state the patterns in the deck and, where they
depend on the chip, in the [design intent](../design-intent.md) file.

## Power-state leakage

### ERC-H1: Static leakage from a floating gate in power-down

**What it catches.** A powered transistor whose gate floats in one of your power states. A
switched-off block leaves its outputs at no defined voltage, and the gates they drive in an
always-on block sit somewhere between the rails. Both transistors of such a stage then conduct a
little, and the chip leaks static current for as long as the state lasts.

**How GPurify measures it.** GPurify propagates the supply voltages through the layout once with
every supply on, then once for each power state in the intent file, with that state's supplies
off and its held inputs at their voltage. See
[how a voltage reaches a net](voltage.md#erc-f1-static-voltage-propagation). A transistor is
examined when some supply reaches its gate with every supply on. It is flagged when, in a power
state, no supply reaches its gate while a power supply still reaches its source or drain. The
measured value is the number of states in which that happens, against 0, at the transistor's
gate.

![A switched inverter off in sleep leaves net Y floating; both transistors of the always-on inverter it drives are flagged](../../diagrams/erc-h1.svg)

**In the deck.**

```text
rule <id> missing_isolation(; isolation: none)
```

```text
grid 5nm
layer nwell = gds(1, 0)
layer diff = gds(2, 0)
layer poly = gds(3, 0)
layer cont = gds(4, 0)
layer met1 = gds(5, 0)
layer text = gds(5, 1)
layer sd = diff not poly
layer ngate = (poly and diff) not nwell
layer pgate = poly and diff and nwell
connect conductors [sd, poly, met1]
connect touch_within_layer
connect via cont [sd, met1]
connect via cont [poly, met1]
connect label text names met1
device mos ngate model "nfet" terminals [poly, sd, sd]
device mos pgate model "pfet" terminals [poly, sd, sd]
rule leak.hiz missing_isolation(; isolation: none)
```

The layout holds two inverters. The first runs from the switched supplies `VDD_SW` and `VSS_SW`
and drives net `Y`. The second runs from the always-on `VDD` and `VSS`, with `Y` as its input. The
intent file declares the four supplies and a `sleep` state that turns off the switched pair:

```json
{
  "domains": { "aon": { "voltage_mv": 1800 }, "sw": { "voltage_mv": 1800 } },
  "supplies": [
    { "net": "VDD", "domain": "aon", "role": "power" },
    { "net": "VSS", "domain": "aon", "role": "ground" },
    { "net": "VDD_SW", "domain": "sw", "role": "power" },
    { "net": "VSS_SW", "domain": "sw", "role": "ground" }
  ],
  "states": [
    { "name": "sleep", "off": ["VDD_SW", "VSS_SW"] }
  ]
}
```

```sh
gpurify erc sleep.gds --deck leakage.deck --intent sleep.json
```

**Example violation.**

```text
rules:
  leak.hiz: ran, examined 2 shapes, found 2 violations
violations: 2
  leak.hiz error layer ngate at (6400 nm, 1000 nm) measured 1 against limit 0 on shape 44
  leak.hiz error layer pgate at (6400 nm, 4000 nm) measured 1 against limit 0 on shape 46
...
```

In `sleep`, `Y` floats, so both transistors of the always-on inverter at x = 6.4 µm are flagged
in 1 state against a limit of 0. The n-channel transistor counts because the p-channel one still
powers the shared output. The switched inverter's own transistors are not examined: no supply
reaches their input `A`.

**Options.**

| Parameter | Value | Meaning |
|---|---|---|
| `isolation` | model list or `none` | Models of isolation cells, which hold a floating input by design and are not flagged. |

**Status and limits.** Implemented. Only the power states the intent file declares are examined,
never every combination of inputs. The leakage is found, not quantified: no current is computed.
Without `--intent`, or with an intent file that declares no power states, the rule is skipped. The
same check with a list of isolation models is
[missing isolation at a switchable domain's outputs](voltage.md#erc-f7-missing-isolation-at-switchable-domain-outputs).

**Sources.** Siemens Calibre Insight Analyzer, public product material (high-impedance nodes in
power-down states); IEEE 1801 (UPF) power states.

## Analog constraints

### ERC-H2: Analog matching constraints

**What it catches.** Transistors meant to match, such as a differential pair or a current mirror,
that are drawn differently: units of another model, width or length, channels running at right
angles, or two devices whose centroids do not coincide. Matched devices only cancel process
gradients and mismatch when their units are identical, parallel and arranged round a common
centre. A pair that fails any of these drifts in offset with the gradient across it.

**How GPurify measures it.** You mark each matched group with a polygon on a marker layer. A
group's units are the transistors whose gate centre lies inside the polygon. Units with the same
model and the same gate, channel and bulk nets form one device. GPurify compares every unit with
the group's first unit:

- a different model, measured 1 against 0;
- a different width or length, measured as the difference against 0;
- a channel at right angles to the first unit's, measured 1 against 0.

It then takes each device's centroid, its units' gate centres weighted by area. A device whose
centroid lies further than `tolerance` from the first device's on either axis is flagged,
measured as the larger offset, rounded up.

![Fingers A A B B in one diffusion: the centroids of A and B lie 4.65 µm apart, and the last finger is 0.3 µm long instead of 0.2 µm](../../diagrams/erc-h2.svg)

**In the deck.**

```text
rule <id> matching(<group layer>; tolerance: <length>)
```

```text
grid 5nm
layer nwell = gds(1, 0)
layer diff = gds(2, 0)
layer poly = gds(3, 0)
layer cont = gds(4, 0)
layer met1 = gds(5, 0)
layer text = gds(5, 1)
layer group = gds(16, 0)
layer sd = diff not poly
layer ngate = (poly and diff) not nwell
layer pgate = poly and diff and nwell
connect conductors [sd, poly, met1]
connect touch_within_layer
connect via cont [sd, met1]
connect via cont [poly, met1]
connect label text names met1
device mos ngate model "nfet" terminals [poly, sd, sd]
device mos pgate model "pfet" terminals [poly, sd, sd]
rule mp.cc matching(group; tolerance: 100nm)
```

The layout is a differential pair in one diffusion, four fingers in the order A A B B. The A
fingers share drain `DA`, the B fingers drain `DB`, and all four share source `S`. The last B
finger is drawn 0.3 µm long, the others 0.2 µm. No intent file is needed.

```sh
gpurify erc pair.gds --deck matching.deck
```

**Example violation.**

```text
rules:
  mp.cc: ran, examined 4 shapes, found 2 violations
violations: 2
  mp.cc error layer ngate at (5400 nm, 2000 nm) measured 4650 nm against limit 100 nm on shape 40
  mp.cc error layer ngate at (7600 nm, 2000 nm) measured 100 nm against limit 0 nm on shape 41
...
```

The B device's centroid lies 4650 nm from the A device's, against a 100 nm tolerance. The finger at x = 7.6 µm is 100 nm longer than the first unit. The
count after `examined` is the number of units in groups.

**Options.**

| Parameter | Value | Meaning |
|---|---|---|
| `tolerance` | length | How far, on either axis, a device's centroid may lie from the first device's. |

**Status and limits.** Partial. Only MOS transistors are grouped. GPurify does not check
anti-parallel current in the channels, since source and drain come in extraction order and
fingers alternate them. It also does not check dummy devices, identical surroundings and shallow
trench isolation context, well-proximity distance, or symmetry about an axis. The deck's
`matching` statements, which give each model's mismatch coefficients, are not read by this or any
other check yet.

**Sources.** GlobalFoundries GF180MCU design manual section 10.6.2, matching rules MP.1, MP.2a and
MP.7; M. Karmokar et al., "Common-Centroid Layout for Active and Passive Devices: A Review and the
Road Ahead", ASP-DAC 2022; Sarhan and Arriordaz (Siemens), "Automated Analog Design Constraint
Checking", Semiconductor Engineering, 2019; US patent 10,216,888 (Cadence, constraint
validation).

## Netlist paths and loads

### ERC-H3: Netlist path checks

**What it catches.** A transistor gate that reaches ground (or power) only through a long chain of
devices, or not at all, and nets whose types and connections break a rule you write. A gate far
from its rail charges slowly and floats under leakage. Net types let you write checks such as "no
pad net may reach a transistor gate", the class of rule Calibre PERC programs.

**How GPurify measures it.** A path is the set of nets joined through MOS source and drain pins and
resistor pins. Gates, bulks, capacitors and diodes do not join a path.

`gate_path` counts, for each net with a MOS gate on it, the fewest devices a path passes from the
nearest declared ground (with `ground: true`) or power supply (with `ground: false`). A gate net
above `max_devices` is flagged, measured as that count. A gate net with no path at all is flagged,
measured 0 against 1. A supply does not end a path.

`net_type` reads the net types you declare in the intent file. A type picks nets by label, with
`?` matching any run of characters, or by the pins of a model's devices. A type set is any of its
member types. The rule flags a net whose own types meet `net` and whose path's types meet `path`.
A path stops at a net that meets `break`; the break net's types count toward the path, less those
in `exclude`. A finding measures 1 against 0, at the net's lowest shape.

![An inverter whose input A reaches VSS through two series transistors; A is flagged at 2 devices, and gate nets B and C have no path](../../diagrams/erc-h3.svg)

**In the deck.**

```text
rule <id> gate_path(; ground: true | false, max_devices: <count>)
rule <id> net_type(; net: <types> | none, path: <types> | none, break: <types> | none, exclude: <types> | none)
```

A list of types is written in quotes, `["pad", "gate"]`. Names after a `"!"` must be absent:
`["pad", "!", "esd"]` needs `pad` and not `esd`. `none` is always met.

```text
grid 5nm
layer nwell = gds(1, 0)
layer diff = gds(2, 0)
layer poly = gds(3, 0)
layer cont = gds(4, 0)
layer met1 = gds(5, 0)
layer text = gds(5, 1)
layer sd = diff not poly
layer ngate = (poly and diff) not nwell
layer pgate = poly and diff and nwell
connect conductors [sd, poly, met1]
connect touch_within_layer
connect via cont [sd, met1]
connect via cont [poly, met1]
connect label text names met1
device mos ngate model "nfet" terminals [poly, sd, sd]
device mos pgate model "pfet" terminals [poly, sd, sd]
rule gp.1 gate_path(; ground: true, max_devices: 1)
```

The layout is an inverter whose input `A` is pulled to `VSS` through two n-channel transistors in
series, with gates `B` and `C`. The intent file declares the supplies:

```json
{
  "domains": { "core": { "voltage_mv": 1800 } },
  "supplies": [
    { "net": "VDD", "domain": "core", "role": "power" },
    { "net": "VSS", "domain": "core", "role": "ground" }
  ]
}
```

```sh
gpurify erc stack.gds --deck gate_path.deck --intent intent.json
```

For `net_type`, the same deck ends instead with this rule, and the layout is one inverter whose
input is labelled `PAD_IN` and output `PAD_OUT`:

```text
rule pad.gate net_type(; net: ["pad"], path: ["gate"], break: none, exclude: none)
```

The intent file adds two net types: `pad`, every net labelled `PAD` and anything after, and
`gate`, every net on a gate pin of an `nfet` or `pfet`.

```json
{
  "domains": { "core": { "voltage_mv": 1800 } },
  "supplies": [
    { "net": "VDD", "domain": "core", "role": "power" },
    { "net": "VSS", "domain": "core", "role": "ground" }
  ],
  "net_types": [
    { "type": "pad", "nets": ["PAD?"] },
    { "type": "gate", "models": ["nfet", "pfet"], "pins": ["g"] }
  ]
}
```

```sh
gpurify erc pad.gds --deck net_type.deck --intent types.json
```

**Example violation.**

```text
rules:
  gp.1: ran, examined 3 shapes, found 3 violations
violations: 3
  gp.1 error layer met1 at (1200 nm, 4900 nm) measured 2 against limit 1 on shape 15
  gp.1 error layer met1 at (1200 nm, 8650 nm) measured 0 against limit 1 on shape 16
  gp.1 error layer met1 at (3200 nm, 8650 nm) measured 0 against limit 1 on shape 17
...
```

`A` reaches `VSS` through 2 devices against a limit of 1. `B` and `C`, the stack's gates, have no
path at all and measure 0 against 1. The count after `examined` is the number of gate nets.

```text
rules:
  pad.gate: ran, examined 4 shapes, found 1 violations
violations: 1
  pad.gate error layer met1 at (1200 nm, 4900 nm) measured 1 against limit 0 on shape 10
...
```

`PAD_IN` is a pad net with a gate on its path: it drives the inverter's gates directly. `PAD_OUT`
is a pad net too, but its path through the inverter's channels to the supplies holds no gate net.

**Options.**

| Parameter | Value | Meaning |
|---|---|---|
| `ground` | `true` or `false` | `gate_path`: count devices to a declared ground (`true`) or power supply (`false`). |
| `max_devices` | count | `gate_path`: the most devices a gate's shortest path may pass. |
| `net` | types or `none` | `net_type`: what the flagged net's own types must meet. |
| `path` | types or `none` | `net_type`: what the types on the net's path must meet. |
| `break` | types or `none` | `net_type`: a net meeting this ends a path. |
| `exclude` | types or `none` | `net_type`: types of a break net that do not count toward the path. |

In the intent file, a `net_types` entry gives a `type` and either `nets`, a list of label patterns,
or `models` with `pins`. A pattern may be `lvsPower` or `lvsGround`, the declared power or ground
supplies, or `lvsOutline`, every labelled net. Pins are `g`, `s`, `d` and `b` for a transistor,
`c`, `b` and `e` for a bipolar transistor, and `pos` and `neg` for two-pin devices; no pins means
every pin. Source and drain follow extraction order, so list both `s` and `d`. A `models` list
that starts with `"!"` means every model but those. A `type_sets` entry gives a `set` and its
member `types`. At most 64 types and sets may be declared together.

**Status and limits.** Partial. Paths run only through MOS source and drain pins and resistor
pins; you cannot define them through other device types or pins. Device property constraints,
per-cell types and checks, and checks on a device's pins against net types are not modelled. Both
rules are skipped without `--intent`; `gate_path` is skipped when the intent declares no supply,
and `net_type` when it declares no net type.

**Sources.** US patent application 2010/0306720 A1 (Mentor Graphics, programmable electrical rule
checking), paragraphs 0029, 0198 to 0263 and 0450 to 0462; US patent 9,262,574 (Siemens,
voltage-related analysis of layout data); US patent 6,367,062 (Hewlett-Packard), on series pass
transistors.

### ERC-H4: Fanout limits

**What it catches.** A net that drives more transistor gates than your limit. A heavily loaded net
switches slowly and with poor slopes, which costs timing margin and raises short-circuit power in
every stage it drives.

**How GPurify measures it.** GPurify counts the MOS gate terminals on each net and flags a net with
more than `max`. The finding sits at the net's lowest shape and measures the gate count.

![Net A feeds three inverters, six gates in all, against a maximum of 4](../../diagrams/erc-h4.svg)

**In the deck.**

```text
rule <id> fanout(; max: <count>)
```

```text
grid 5nm
layer nwell = gds(1, 0)
layer diff = gds(2, 0)
layer poly = gds(3, 0)
layer cont = gds(4, 0)
layer met1 = gds(5, 0)
layer text = gds(5, 1)
layer sd = diff not poly
layer ngate = (poly and diff) not nwell
layer pgate = poly and diff and nwell
connect conductors [sd, poly, met1]
connect touch_within_layer
connect via cont [sd, met1]
connect via cont [poly, met1]
connect label text names met1
device mos ngate model "nfet" terminals [poly, sd, sd]
device mos pgate model "pfet" terminals [poly, sd, sd]
rule fo.4 fanout(; max: 4)
```

The layout holds three inverters whose inputs are joined on net `A`. No intent file is needed.

```sh
gpurify erc fanout.gds --deck fanout.deck
```

**Example violation.**

```text
rules:
  fo.4: ran, examined 1 shapes, found 1 violations
violations: 1
  fo.4 error layer met1 at (1200 nm, 4900 nm) measured 6 against limit 4 on shape 22
...
```

Net `A`, reported at its first input pad, drives 6 gates against a maximum of 4. The count after
`examined` is the number of nets with a gate on them.

**Options.**

| Parameter | Value | Meaning |
|---|---|---|
| `max` | count, at least 1 | The most MOS gates a net may drive. |

**Status and limits.** Implemented. The load is a count of gates: gate area, wire capacitance and
the driver's strength are not weighed.

**Sources.** Synopsys IC Validator (public product material); GlobalFoundries GF180MCU design
manual section 14.1.4.1.
