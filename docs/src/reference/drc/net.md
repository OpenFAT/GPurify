# Net-aware checks

These checks read the nets GPurify extracts from the deck's `connect` lines and the layout's text
labels, so a rule depends on which net a shape is on: same net or different nets, the voltage
between nets, or whether a net reaches a device at all.

Every layer a net rule reads must be a conductor in `connect conductors`, or a layer derived from
one. The rules that need supply voltages run under `gpurify erc` with `--intent`, a JSON file of
the design's supplies and their voltages.

## Spacing by net

### DRC-080: Same-net and different-net spacing

**What it catches.** Two shapes on one layer closer than the space their nets ask for. Wells and
wires on different nets need more space than shapes on one net, because the voltage between them
punches through or leaks; shapes on one net only need the printing space.

**How GPurify measures it.** GPurify extracts the nets, then measures each pair of shapes on the
layer as `space` does, edge to edge and Euclidean at corners. `nets: same` holds only pairs on one
net, `nets: different` only pairs on two nets. A derived layer takes the net of the conductor
shapes under each of its shapes.

![Two nwell regions on the nets VDD and VDDA, 1 µm apart, against a 1.4 µm different-net space](../../diagrams/drc-080.svg)

**In the deck.**

```text
rule <id> space(<layer>; nets: same) >= <length>
rule <id> space(<layer>; nets: different) >= <length>
```

```text
grid 5nm
layer nwell = gds(64, 20)
layer nwell_label = gds(64, 5)
connect conductors [nwell]
connect touch_within_layer
connect label nwell_label names nwell
rule NW.2b space(nwell; nets: different) >= 1.4um
```

**Example violation.**

```text
rules:
  NW.2b: ran, examined 1 shapes, found 1 violations
violations: 1
  NW.2b error layer nwell at (2500 nm, 1000 nm) measured 1000 nm against limit 1400 nm on shape 0 and shape 1
...
```

Two n-wells labelled `VDD` and `VDDA` are 1 µm apart, against 1.4 µm for different nets. The point
is midway across the gap.

**Options.**

| Parameter | Value | Meaning |
|---|---|---|
| `nets` | `same` or `different` | Which pairs the rule holds. |

**Status and limits.** Implemented. A derived shape over no net, or over two nets, refuses the rule.
The shipped gf180mcu deck does not carry NW.2b, because its wells are not conductors there.

**Sources.** GlobalFoundries GF180MCU rules NW.2a, NW.2b and DN.2a; IHP SG13G2 rule NW.b; LEF/DEF 5.8
`SPACING SAMENET`; KLayout `nets` with `props_eq` and `props_ne`; OpenROAD TritonRoute.

### DRC-081: Net spacing between two layers

**What it catches.** A shape on one layer too close to a shape on another layer on a different net,
such as a high-voltage n-well next to any other n-well. Wells on different nets at different
voltages break down if they come too close.

**How GPurify measures it.** GPurify measures each pair of an `A` shape and a `B` shape on different
nets, edge to edge, overlap included as 0. A derived layer, such as the n-well under the
high-voltage marker, takes the net of the conductor under it.

![An hv_nwell on VDDH 1.5 µm from an nwell on VDD, against a 2 µm space](../../diagrams/drc-081.svg)

**In the deck.**

```text
rule <id> space(<layer a>, <layer b>; nets: different) >= <length>
```

```text
grid 5nm
layer nwell = gds(64, 20)
layer hvi = gds(75, 20)
layer nwell_label = gds(64, 5)
layer hv_nwell = nwell.interacting(hvi)
connect conductors [nwell]
connect touch_within_layer
connect label nwell_label names nwell
rule hvnwell.8 space(hv_nwell, nwell; nets: different) >= 2um
```

**Example violation.**

```text
rules:
  hvnwell.8: ran, examined 1 shapes, found 1 violations
violations: 1
  hvnwell.8 error layer hv_nwell at (2750 nm, 1000 nm) measured 1500 nm against limit 2000 nm on shape 3 and shape 2
...
```

The high-voltage n-well on `VDDH` is 1.5 µm from an n-well on `VDD`, against 2 µm. The point is
midway across the gap.

**Status and limits.** Partial. `nets: same` is refused between two layers: one net's shapes on two
layers overlap wherever a cut joins them. sky130 nwell.7 and vhvi.8 need deep n-well and the
vhvi-tagged well as nets, which no shipped deck connects. sky130's text tags (`shv_nwell`) are not
read. The shipped sky130 deck does not carry hvnwell.8 yet.

**Sources.** [SkyWater SKY130](https://skywater-pdk.readthedocs.io/en/main/rules/periphery.html)
rules nwell.7, hvnwell.8, hv.nwell.1 and vhvi.8; IHP SG13G2 rules NW.b1 and NBL.c.

### DRC-082: Voltage-dependent spacing

**What it catches.** Two shapes on different nets closer than the space the voltage between them
needs. Higher voltage across a gap needs a wider gap to avoid breakdown and time-dependent
dielectric failure.

**How GPurify measures it.** GPurify reads each net's voltage range from the supplies in the intent
file, through every conducting device. The voltage between two nets is the worst case: the highest
one can reach minus the lowest the other can. The pair needs the space of the last step that
difference reaches, and is measured edge to edge.

![Two met1 wires on VDD5 and VSS, 0.20 µm apart, against the 0.60 µm a 5 V difference needs](../../diagrams/drc-082.svg)

**In the deck.**

```text
rule <id> voltage_space(<layer>; voltage: [<voltage>, ...], space: [<length>, ...])
rule <id> voltage_space(<layer a>, <layer b>; voltage: [<voltage>, ...], space: [<length>, ...])
```

```text
grid 5nm
layer met1 = gds(68, 20)
layer met1_label = gds(68, 5)
connect conductors [met1]
connect touch_within_layer
connect label met1_label names met1
rule m1.vs voltage_space(met1; voltage: [0V, 3.3V, 5V], space: [140nm, 300nm, 600nm])
```

The intent file states the supplies:

```json
{
  "domains": { "io": { "voltage_mv": 5000 } },
  "supplies": [
    { "net": "VDD5", "domain": "io", "role": "power" },
    { "net": "VSS", "domain": "io", "role": "ground" }
  ]
}
```

```sh
gpurify erc layout.gds --deck vs.deck --intent intent.json
```

**Example violation.**

```text
rules:
  m1.vs: ran, examined 1 shapes, found 1 violations
violations: 1
  m1.vs error layer met1 at (300 nm, 2000 nm) measured 200 nm against limit 600 nm on shape 0 and shape 1
...
```

Wires on `VDD5` and `VSS` are 5 V apart, so they need the 5 V step's 600 nm; they have 200 nm.

**Options.**

| Parameter | Value | Meaning |
|---|---|---|
| `voltage` | list of voltages | The steps, from 0 V or more, rising. A difference exactly at a step needs that step's space. |
| `space` | list of lengths | One space per step, never falling. A gap exactly at the space passes. |

**Status and limits.** Implemented. A pair with a net no supply reaches is not checked, and a pair
whose difference is below the first step needs nothing. Ranges are worst case, so two nets that
always move together read their whole swing apart. Tag layers, such as sky130's HV n-well marker,
cannot be named, because the layers must be conductors. No shipped deck carries a voltage table:
no open manual states one.

**Sources.** SkyWater SKY130 rules hvnwell.8 and hv.*; LEF58 `VOLTAGESPACING`; voltage-aware DRC in
Calibre, IC Validator and Pegasus.

### DRC-083: High-voltage tag propagation

**What it catches.** A conductor on a net that reaches a high voltage but lies outside the
high-voltage marker. Anything shorted to a high-voltage net through a conducting device is high
voltage too, and must carry the tag so the high-voltage rules apply to it.

**How GPurify measures it.** `hv_tag` finds each shape of the conductor whose net reaches the
voltage, directly or through conducting channels, and reports the area of it outside the tag
layer. `hv_domain` reports a device whose terminals reach supply domains more than `max_delta`
apart.

![A met1 wire on VDD5 half outside the hvtag marker](../../diagrams/drc-083.svg)

**In the deck.**

```text
rule <id> hv_tag(<conductor>, <tag>; voltage: <voltage>)
rule <id> hv_domain(; max_delta: <voltage>, isolation: <layer> | none)
```

```text
grid 5nm
layer met1 = gds(68, 20)
layer met1_label = gds(68, 5)
layer hvtag = gds(75, 20)
connect conductors [met1]
connect touch_within_layer
connect label met1_label names met1
rule hv.X.1 hv_tag(met1, hvtag; voltage: 3.3V)
```

Run with the intent file of [DRC-082](#drc-082-voltage-dependent-spacing), `VDD5` at 5 V:

```sh
gpurify erc layout.gds --deck hv.deck --intent intent.json
```

**Example violation.**

```text
rules:
  hv.X.1: ran, examined 1 shapes, found 1 violations
violations: 1
  hv.X.1 error layer met1 at (100 nm, 2000 nm) measured 400000 nm^2 against limit 0 nm^2 on shape 1
...
```

A wire on the 5 V net `VDD5` has 0.4 µm² outside the tag; the rule asks it all inside for any net
reaching 3.3 V.

**Options.**

| Parameter | Value | Meaning |
|---|---|---|
| `voltage` | voltage | A net that reaches this voltage or more is high voltage. |
| `max_delta` | voltage | `hv_domain`: the most two domains a device spans may differ. |
| `isolation` | layer or `none` | `hv_domain`: a layer that isolates the device. |

**Status and limits.** Implemented. sky130's text tags (`shv_nwell`, `hv_bb`, `hv_lv`) are not read.
No shipped deck carries `hv_tag` yet: the manual names no voltage for "high voltage".

**Sources.** SkyWater SKY130 rules hv.X.1 to hv.X.6 and hvnwell.11.

## Connection

### DRC-084: Floating interconnect and must-join ports

**What it catches.** A piece of wire that reaches no device, and a pin whose pieces the layout never
joins. Floating metal charges during processing and couples noise; a split pin is an open.

**How GPurify measures it.** `unconnected_pin` reports each shape on the listed layers whose net
reaches no device terminal. A label on two shapes the layout does not join is reported by an LVS
run (`gpurify lvs` with `--reference`) as `lvs.label_conflict`, an error. A name the deck declares
must-connect (`lvs connect_implicit`) is joined for the comparison and reported as a warning.

![A met1 wire whose net reaches no device](../../diagrams/drc-084.svg)

**In the deck.**

```text
rule <id> unconnected_pin(<layer>, ...)
```

```text
grid 5nm
layer met1 = gds(68, 20)
rule x.22 unconnected_pin(met1)
connect conductors [met1]
connect touch_within_layer
```

```sh
gpurify erc layout.gds --deck float.deck
```

**Example violation.**

```text
rules:
  x.22: ran, examined 1 shapes, found 1 violations
violations: 1
  x.22 error layer met1 at (0 nm, 0 nm) measured 0 against limit 1 on shape 0
...
```

A met1 wire touches no device: 0 device terminals against at least 1. The point is a corner of the
wire.

**Status and limits.** Partial. sky130 x.22's exemption labels (`poly_float` to `m5_tie`) and its
`areaid.stdcell` exclusion are not read; write the exclusion as a derived layer. LEF's own
`LEF58_MUSTJOINALLPORTS` is not read. Implicit joins are tracked in
[issue 7](https://github.com/OpenFAT/GPurify/issues/7).

**Sources.** SkyWater SKY130 rule x.22; LEF58 `MUSTJOINALLPORTS`.

### DRC-085: Tap presence per well

**What it catches.** A well with no tap in it. An untapped well floats, which invites latch-up and
leaves the transistors in it with an undefined body.

**How GPurify measures it.** `floating_well` reports each well shape that holds no shape of the tap
layer. The same check is `contains(<well>, <tap>) >= 1` in plain geometry.

![Two nwell regions, one holding an ntap and one with none](../../diagrams/drc-085.svg)

**In the deck.**

```text
rule <id> floating_well(<well>, <tap>)
rule <id> contains(<well>, <tap>) >= 1
```

```text
grid 5nm
layer nwell = gds(64, 20)
layer tap = gds(65, 44)
layer ntap = tap and nwell
rule floating_nwell floating_well(nwell, ntap)
```

```sh
gpurify erc layout.gds --deck taps.deck
```

**Example violation.**

```text
rules:
  floating_nwell: ran, examined 2 shapes, found 1 violations
violations: 1
  floating_nwell error layer nwell at (3000 nm, 0 nm) measured 0 against limit 1 on shape 1
...
```

The second n-well holds no tap: 0 against at least 1. The point is a corner of the well.

**Status and limits.** Implemented. No known limits.

**Sources.** SkyWater SKY130 rule nwell.4; GlobalFoundries GF180MCU rule DN.3; IHP SG13G2 rule
nmosi.d.

### DRC-086: Shorts between labelled nets

**What it catches.** Two differently labelled nets joined by the layout: a short. A short between
supplies or signals kills the circuit, and finding where it runs is the hard part.

**How GPurify measures it.** Every run reports two labels on one net as `lvs.net_seed_conflict`,
naming both labelled shapes. It then reports `lvs.short_path`: the fewest shapes joining the two
labelled ones, one row per step from shape to shape. A via joins the shapes it lands on and is no
step itself. Nothing in the deck turns this on.

![A met1 strap joining the VDD and VSS wires, with the two-step path between the labels](../../diagrams/drc-086.svg)

**In the deck.** Nothing to write beyond the `connect` lines that name the nets. Any rule, or none,
runs the check:

```text
grid 5nm
layer met1 = gds(68, 20)
layer met1_label = gds(68, 5)
connect conductors [met1]
connect touch_within_layer
connect label met1_label names met1
rule m1.1 width(met1) >= 140nm
```

**Example violation.**

```text
rules:
  m1.1: ran, examined 3 shapes, found 0 violations
  lvs.net_seed_conflict: ran, examined 2 shapes, found 1 violations
  lvs.short_path: ran, examined 1 shapes, found 2 violations
violations: 3
  lvs.net_seed_conflict error layer met1 at (0 nm, 0 nm) measured 2 against limit 1 on shape 0 and shape 2
  lvs.short_path error layer met1 at (0 nm, 0 nm) measured 1 against limit 2 on shape 0 and shape 1
  lvs.short_path error layer met1 at (200 nm, 1800 nm) measured 2 against limit 2 on shape 1 and shape 2
...
```

The wires labelled `VDD` and `VSS` are joined by a strap: 2 labels on one net against 1. The path
has two steps, wire to strap and strap to wire; each row gives its step number against the step
count.

**Status and limits.** Implemented. The path is the shortest one, not every route. A short is not
an abort: the run goes on. Short isolation is tracked in
[issue 8](https://github.com/OpenFAT/GPurify/issues/8).

**Sources.** OpenROAD TritonRoute short check.
