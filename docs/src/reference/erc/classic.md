# Connectivity checks

These checks read how devices, nets and supplies connect: floating gates and wells, nets with
several drivers or none, shorts between tap kinds, and paths to power and ground. Four of them
read the supplies from the [design intent](../design-intent.md) file and report `skipped` without
it.

## Undriven nodes

### ERC-G1: Floating gate

**What it catches.** A transistor gate on a net that nothing drives: a net whose only device
terminals are gates. A floating gate settles at an unknown voltage. Both transistors of a stage
can then conduct at once, which wastes current and gives an undefined logic level.

**How GPurify measures it.** GPurify looks at every net that carries a gate. It flags the net when
no transistor source or drain, resistor, diode or bipolar pin lands on it. A capacitor plate or a
transistor bulk does not drive a net, so a gate joined only to them still floats. With
`labels_are_ports: true`, a net with a text label counts as a cell input, driven from outside, and
is not flagged. The check reads no design intent.

![An inverter whose input net reaches only the two gates and carries no label, marked as floating](../../diagrams/erc-g1.svg)

**In the deck.**

```text
rule <id> floating_gate(; labels_are_ports: <true|false>)
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
rule fg floating_gate(; labels_are_ports: true)
```

```sh
gpurify erc float_gate.gds --deck g1.deck
```

**Example violation.**

```text
rules:
  fg: ran, examined 1 shapes, found 1 violations
violations: 1
  fg error layer met1 at (1200 nm, 4900 nm) measured 0 against limit 1 on shape 10
...
```

The inverter's unlabelled input net, reported at the corner of its met1 pad, has 0 driving
terminals against the 1 it needs. `examined` counts the nets that carry a gate.

**Options.**

| Parameter | Value | Meaning |
|---|---|---|
| `labels_are_ports` | `true` or `false` | `true` spares a labelled net, as an input driven from outside the cell. |

**Status and limits.** Implemented. A violation sits at the first corner of the net's lowest
shape, not at the gate. The check does not follow a gate through a resistor to see whether the
resistor's far end is driven.

**Sources.** Siemens white paper 81822 (Calibre PERC), floating gates;
[Yosys `check`](https://yosyshq.readthedocs.io/projects/yosys/en/latest/cmd/index_passes_status.html),
undriven wires.

### ERC-G2: Floating well

**What it catches.** A well with no tap in it. A well that no tap ties to a supply floats. The
transistors in it then see an undefined body voltage, and the well is exposed to latch-up.

**How GPurify measures it.** GPurify merges the well layer, so touching well shapes form one well.
A well is tied when some shape of the tap layer lies entirely inside it. A tap that only overlaps
the well's edge does not tie it. The check does not ask which net the tap is on: the voltage the
well sits at is [ERC-F12](voltage.md#erc-f12-well-and-body-bias)'s concern.

![Two 4 µm n-wells from above, the left one holding a tap and the right one, with none, marked floating](../../diagrams/erc-g2.svg)

**In the deck.**

```text
rule <id> floating_well(<well layer>, <tap layer>)
```

```text
grid 5nm
layer nwell = gds(1, 0)
layer tap = gds(6, 0)
rule nwell.4 floating_well(nwell, tap)
```

```sh
gpurify erc wells.gds --deck g2.deck
```

**Example violation.**

```text
rules:
  nwell.4: ran, examined 2 shapes, found 1 violations
violations: 1
  nwell.4 error layer nwell at (6000 nm, 0 nm) measured 0 against limit 1 on shape 1
...
```

The right-hand well, reported at its corner (6 µm, 0 µm), holds 0 taps against the 1 it needs.

**Status and limits.** Implemented. Both layers must be rectilinear; a well or tap layer with an
angled edge makes the rule `refused`. Use a layer of tap contacts, as the sky130 deck does, when a
tap without a contact must not count.

**Sources.** [SkyWater SKY130 rule nwell.4](https://skywater-pdk.readthedocs.io/en/main/rules/periphery.html).

## Nets, drivers and supplies

### ERC-G3: Multiple drivers

**What it catches.** A net that two or more separate pull networks drive. Two drivers that disagree
fight: a large current flows from supply to ground, and the net settles at neither level.

**How GPurify measures it.** The declared supplies of the [design intent](../design-intent.md) are
the rails. For each net, GPurify walks from every transistor channel on it through further
channels until it reaches a rail; the transistors walked form one pull network. Networks that share
a gate net are one driver, so an inverter's pull-up and pull-down, or a NAND's, count once. A pass
gate whose walk reaches no rail drives nothing by itself. Which end of a channel is the source does
not matter.

![Two inverters with inputs A and B whose outputs are joined on net Y, marked as two drivers](../../diagrams/erc-g3.svg)

**In the deck.**

```text
rule <id> multiple_drivers(; max: <count>)
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
rule drivers multiple_drivers(; max: 1)
```

The supplies the example needs, in `intent.json`:

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
gpurify erc two_drivers.gds --deck g3.deck --intent intent.json
```

**Example violation.**

```text
rules:
  drivers: ran, examined 1 shapes, found 1 violations
violations: 1
  drivers error layer met1 at (2300 nm, 300 nm) measured 2 against limit 1 on shape 16
...
```

Net Y, where the inverters on A and B meet, has 2 drivers against a limit of 1. `examined`
counts the nets, supplies aside, that a channel ends on.

**Options.**

| Parameter | Value | Meaning |
|---|---|---|
| `max` | count | The most drivers a net may have. |

**Status and limits.** Implemented. Without `--intent`, or with an intent file that declares no
supply, the rule reports `skipped`. A tristate bus, where enables make sure only one driver is on
at a time, is flagged all the same: the check does not read the enable logic.

**Sources.** [Yosys `check`](https://yosyshq.readthedocs.io/projects/yosys/en/latest/cmd/index_passes_status.html),
conflicting drivers.

### ERC-G4: Supply short between tap kinds

**What it catches.** A net that touches both an n-tap and a p-tap. An n-tap ties an n-well to the
power rail and a p-tap ties the substrate to ground, so one net holding both shorts power to
ground, or biases a well wrongly.

**How GPurify measures it.** GPurify marks every net that holds a shape of the first tap layer and
every net that holds a shape of the second. A net marked by both is flagged. With a third layer,
`within`, a first-layer tap counts only when the centre of its bounding box lies in a `within`
shape. The sky130 deck uses this to count only n-taps in a well that holds a PMOS, so that a
bipolar transistor's base contact is not a short. Both tap layers must be conductors in the deck's
`connect` lines, so that their shapes are on nets.

![An n-tap and a p-tap, each with a contact, joined by one met1 strip labelled VDD, marked as one net holding both tap kinds](../../diagrams/erc-g4.svg)

**In the deck.**

```text
rule <id> supply_short(<tap layer>, <other tap layer>)
rule <id> supply_short(<tap layer>, <other tap layer>, <within>)
```

```text
grid 5nm
layer cont = gds(4, 0)
layer met1 = gds(5, 0)
layer text = gds(5, 1)
layer tap = gds(6, 0)
layer nimp = gds(7, 0)
layer pimp = gds(8, 0)
layer ntap = tap and nimp
layer ptap = tap and pimp
connect conductors [ntap, ptap, met1]
connect touch_within_layer
connect via cont [ntap, met1]
connect via cont [ptap, met1]
connect label text names met1
rule short supply_short(ntap, ptap)
```

```sh
gpurify erc taps.gds --deck g4.deck
```

**Example violation.**

```text
rules:
  short: ran, examined 2 shapes, found 1 violations
violations: 1
  short error layer met1 at (200 nm, 200 nm) measured 2 against limit 1 on shape 2
...
```

Net VDD, reported at the corner of its met1 strip, holds 2 tap kinds against a limit of 1.
`examined` counts the shapes on both tap layers.

**Status and limits.** Implemented. The check reads no design intent, so it does not know which
net is a supply: any net with both tap kinds is flagged.

**Sources.** Siemens Calibre public material (supply shorts); no standards body defines the check.

### ERC-G5: Soft connection through a high-resistance layer

**What it catches.** A net held together only through a high-resistance layer, such as a well or a
lightly doped diffusion. Two metal pieces joined only through a well look like one net, but the
well's resistance drops voltage and couples noise. A tap on one side does not hold the other
side's well at the supply.

**How GPurify measures it.** GPurify takes every net with a shape on a listed layer. It joins the
net's shapes again without the listed layers, without every global layer (`connect global`, the
substrate), and without every `connect via` line that touches either. The substrate is resistive
too, so it counts as a listed layer whether you list it or not. When the rest falls into two or
more pieces, those layers were holding the net together, and the net is flagged. The violation
names one shape in each of two pieces.

A supply strap tied to the substrate through its own tap is one piece and passes. Two straps of
one net that meet only through their taps and the substrate are two pieces and are flagged.

![Left, two met1 pieces on n-taps joined only through the n-well, flagged; right, one met1 strap on a p-tap over the global substrate, which passes](../../diagrams/erc-g5.svg)

**In the deck.**

```text
rule <id> soft_connection(<layer>, ...)
```

```text
grid 5nm
layer nwell = gds(1, 0)
layer cont = gds(4, 0)
layer met1 = gds(5, 0)
layer text = gds(5, 1)
layer tap = gds(6, 0)
layer nimp = gds(7, 0)
layer ntap = tap and nimp
layer nwell_tie = ntap and nwell
connect conductors [ntap, nwell, met1]
connect touch_within_layer
connect via cont [ntap, met1]
connect via nwell_tie [ntap, nwell]
connect label text names met1
rule soft soft_connection(nwell)
```

```sh
gpurify erc soft.gds --deck g5.deck
```

**Example violation.**

```text
rules:
  soft: ran, examined 1 shapes, found 1 violations
violations: 1
  soft error layer met1 at (1200 nm, 700 nm) measured 2 against limit 1 on shape 2 and shape 3
...
```

Net VDD falls into 2 pieces against 1 without the n-well; shape 2 is the left met1 piece and
shape 3 the right one. `examined` counts the nets with a shape on a listed layer.

With a substrate, the deck lists the p-tap and declares the substrate global, as the sky130 deck
does:

```text
grid 5nm
layer nwell = gds(1, 0)
layer cont = gds(4, 0)
layer met1 = gds(5, 0)
layer text = gds(5, 1)
layer tap = gds(6, 0)
layer pimp = gds(8, 0)
layer ptap = tap and pimp
layer psub = tap not nwell
connect conductors [ptap, met1]
connect global psub
connect touch_within_layer
connect via cont [ptap, met1]
connect via ptap [ptap, psub]
connect label text names met1
rule soft soft_connection(ptap)
```

```sh
gpurify erc sub_one.gds --deck g5s.deck
gpurify erc sub_two.gds --deck g5s.deck
```

One VSS strap on one p-tap (`sub_one.gds`) passes:

```text
rules:
  soft: ran, examined 1 shapes, found 0 violations
violations: 0
...
```

Two VSS straps 6.4 µm apart, each on its own p-tap and joined by no metal (`sub_two.gds`), are
flagged:

```text
rules:
  soft: ran, examined 1 shapes, found 1 violations
violations: 1
  soft error layer met1 at (1200 nm, 1000 nm) measured 2 against limit 1 on shape 2 and shape 3
...
```

The two straps of VSS are 2 pieces against 1 once the p-taps and the substrate are left out.

**Status and limits.** Implemented. The listed layers must be conductors in the deck's `connect`
lines, so that their shapes are on nets. A net joined through the listed
layers and also through metal is not flagged. A net with no shape on a listed layer is not
examined, even when only the substrate joins it: list the tap layer, as above.

**Sources.** [KLayout `soft_connect`](https://www.klayout.de/doc-qt5/about/lvs_ref_netter.html);
Siemens Calibre `SOFTCHK` statement (its name only is public).

### ERC-G6: Unconnected pin or dangling conductor

**What it catches.** A shape on a routing layer that reaches no device: a pin or wire left
unconnected, or a stub left over from an edit. A dangling conductor is often an open in
disguise, where the wire that should have reached a device stops short.

**How GPurify measures it.** GPurify checks every drawn polygon on the listed layers. A polygon is
flagged when its net holds no device terminal, or when it is on no net at all because its layer is
not a conductor.

![An inverter and, beside it, a met1 stub that touches nothing, marked as reaching no device](../../diagrams/erc-g6.svg)

**In the deck.**

```text
rule <id> unconnected_pin(<layer>, ...)
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
rule x.22 unconnected_pin(poly, met1)
```

```sh
gpurify erc stub.gds --deck g6.deck
```

**Example violation.**

```text
rules:
  x.22: ran, examined 7 shapes, found 1 violations
violations: 1
  x.22 error layer met1 at (5000 nm, 0 nm) measured 0 against limit 1 on shape 11
...
```

The met1 stub at (5 µm, 0 µm) reaches 0 devices against the 1 it needs. `examined` counts the
drawn polygons on poly and met1.

**Status and limits.** Implemented. A shape on a net that reaches any device terminal passes, even
when the net does nothing useful there. A block's top-level pin that is meant to connect at the
next level up is flagged; leave its layer out, or mark the rule `warning`.

**Sources.** [OpenROAD `check_power_grid`](https://openroad.readthedocs.io/en/latest/main/src/psm/README.html),
unconnected shapes.

### ERC-G7: Gate tied directly to a rail

**What it catches.** A transistor gate wired straight to a supply. A gate on the rail with no tie
cell takes the full supply transient and any electrostatic discharge on the rail across its thin
oxide. Foundries ask for a tie-high or tie-low cell between them.

**How GPurify measures it.** GPurify flags every net declared as a supply in the
[design intent](../design-intent.md) that carries a transistor gate. A gate behind a tie cell sits
on the tie cell's output net, which is no supply, so it passes.

![An inverter whose input is wired straight to VDD, marked as a gate on the rail](../../diagrams/erc-g7.svg)

**In the deck.**

```text
rule <id> tie_high_low()
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
rule tie tie_high_low()
```

The supplies the example needs, in `intent.json`:

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
gpurify erc tied.gds --deck g7.deck --intent intent.json
```

**Example violation.**

```text
rules:
  tie: ran, examined 1 shapes, found 1 violations
violations: 1
  tie error layer met1 at (-1000 nm, 3300 nm) measured 0 against limit 1 on shape 8
...
```

Supply VDD, reported at the corner of its met1, carries the inverter's gates with 0 tie cells
between them against the 1 needed. `examined` counts the nets that carry a gate.

**Status and limits.** Implemented. Without `--intent`, the rule reports `skipped`. The sky130,
gf180mcu and ihp_sg13g2 decks carry it as a `warning` row.

**Sources.** Siemens Calibre public material (weak-sourcing checks).

## Loops and paths

### ERC-G8: Combinational loops

**What it catches.** A cycle of logic: a stage whose output reaches, through other stages, a gate
of its own input. An unintended loop oscillates or latches up into a fixed state, and timing
analysis cannot break it.

**How GPurify measures it.** GPurify groups nets into stages: nets joined through transistor
source and drain, never through a declared supply, form one stage. A stage drives another when one
of its nets is the gate of a transistor in the other. A loop is a set of stages that drive each
other in a cycle, or one stage that drives itself. The supplies come from the
[design intent](../design-intent.md); they stop the grouping, so every stage tied to VDD and VSS
does not merge into one.

![An inverter whose output Y is wired back to its own input, marked as a loop](../../diagrams/erc-g8.svg)

**In the deck.**

```text
rule <id> combinational_loop()
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
rule loop combinational_loop()
```

The supplies the example needs, in `intent.json`:

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
gpurify erc loop.gds --deck g8.deck --intent intent.json
```

**Example violation.**

```text
rules:
  loop: ran, examined 1 shapes, found 1 violations
violations: 1
  loop error layer met1 at (2300 nm, 300 nm) measured 1 against limit 0 on shape 9
...
```

Net Y forms a loop of 1 stage against a limit of 0; the measured value is the number of stages
in the loop. Each loop is one violation, at its lowest net. `examined` counts the stages.

**Status and limits.** Implemented. Without `--intent`, the rule reports `skipped`. Latches,
keepers, SRAM cells and diode-connected transistors are loops by this definition, as Yosys
reports a latch built from gates. Waive them, or keep the rule off cells that hold state.

**Sources.** [Yosys `check`](https://yosyshq.readthedocs.io/projects/yosys/en/latest/cmd/index_passes_status.html),
logic loops; R. E. Bryant, "Extraction of Gate Level Models from Transistor Circuits by Four-Valued
Symbolic Analysis", ICCAD 1991, channel-connected components
([author's copy](https://www.cs.cmu.edu/~bryant/pubdir/iccad91.pdf)).

### ERC-G9: Nets with no path to power or ground

**What it catches.** A net with no path through devices to a supply. A node that cannot reach
ground stays high once charged, and one that cannot reach power never rises: either is a stuck or
floating node.

**How GPurify measures it.** A path runs from net to net through transistor sources and drains
and through resistor pins; gates, capacitors, diodes and bipolar transistors stop it. A declared
supply in the [design intent](../design-intent.md) ends a path and gives it a role, power or
ground. With `both: false`, a net is flagged when its path reaches no supply. With `both: true`, it
is flagged when its path misses power or misses ground. With `labels_are_ports: true`, a labelled
net is a top-cell port: a path stops there, as at a supply, but gains no role. A path walks every
channel whatever its gate, unlike
[how a voltage reaches a net](voltage.md#erc-f1-static-voltage-propagation).

![An inverter whose pull-down source is cut off from VSS: its output reaches power only, and input A and the source reach no supply](../../diagrams/erc-g9.svg)

**In the deck.**

```text
rule <id> supply_path(; both: <true|false>, labels_are_ports: <true|false>)
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
rule path supply_path(; both: true, labels_are_ports: false)
```

The supplies the example needs, in `intent.json`:

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
gpurify erc no_ground.gds --deck g9.deck --intent intent.json
```

**Example violation.**

```text
rules:
  path: ran, examined 3 shapes, found 3 violations
violations: 3
  path error layer met1 at (2300 nm, 300 nm) measured 1 against limit 2 on shape 8
  path error layer met1 at (1200 nm, 4900 nm) measured 0 against limit 2 on shape 9
  path error layer sd at (0 nm, 1000 nm) measured 1 against limit 2 on shape 13
...
```

Output Y and the pull-down's source reach 1 supply role, power, against the 2 needed. Input A
reaches none, since a gate stops a path. `examined` counts the nets, supplies aside, that a device
terminal lands on.

> [!NOTE]
> A net that only gates land on has no path, so a cell's inputs are flagged too. With
> `labels_are_ports: true` they still are: a port stops other nets' paths but is not a supply.

**Options.**

| Parameter | Value | Meaning |
|---|---|---|
| `both` | `true` or `false` | `true` needs a path to power and a path to ground; `false` needs a path to either. |
| `labels_are_ports` | `true` or `false` | `true` ends a path at a labelled net, as at a top-cell port. |

**Status and limits.** Implemented. Without `--intent`, the rule reports `skipped`. Calibre's own
breaking rules for `PATHCHK` are not public; this check follows the path definition of the
programmable ERC patent below. A labelled net as a path source, Calibre's `LABELED`, is written
with `net_type` ([ERC-H3](perc.md#erc-h3-netlist-path-checks)).

**Sources.** Siemens Calibre `ERC PATHCHK` and `LVS PATHCHK` statements; the
[ICsprout 55 nm open PDK's Calibre LVS deck](https://github.com/openecos-projects/icsprout55-pdk/blob/main/pv/LVS/ICsprout_CalLVS_55LLULP1233_REV1_0_OS.lvs),
whose `PATHCHK` lines state their meaning;
[US patent application 2010/0306720 A1](https://patents.google.com/patent/US20100306720A1)
(programmable electrical rule checking), paragraphs [0262] and following.
