# Equivalence, swappable pins and black boxes

These deck statements change what counts as the same circuit: which device pins trade places, which
names hold nets together, and which cells and devices the comparison leaves out. Without them, LVS
compares every device and pin as [Comparison checks](compare.md) describes.

## Interchangeable and fixed pins

### LVS-030: Swappable pins

**What it catches.** A device wired the other way round, where the way round matters. A transistor's
source and drain are the same diffusion, so a schematic and a layout often name them in opposite
order; that is no error. A diode, a MiM capacitor or a bipolar is not symmetric, and a swapped one
has the wrong polarity, plate parasitic or gain.

**How GPurify measures it.** Each device kind has pins that trade places by default and pins that
don't, as in Netgen. A transistor's source and drain are interchangeable, and so are the two ends of
a resistor or an inductor. A diode's anode and cathode, a capacitor's top and bottom plates and a
bipolar's base, emitter and collector are not: each pairs only with the same pin of its partner.
`lvs permute` makes two more pins of one model interchangeable. Permutations chain with the defaults and
with each other: permuting a transistor's `gate` with its `source` makes gate, source and drain all
interchangeable.

![Reference inverter with M1's source and drain swapped and the load capacitor's plates swapped, beside the layout; only the capacitor is boxed](../../diagrams/lvs-030.svg)

**In the deck.**

```text
lvs permute "<model>" <pin> <pin>
```

```text
lvs permute "cmim" top bottom
```

Added to [the example deck](README.md#the-example-deck). The pins are named by the device kind:
`gate`, `source`, `drain` and `bulk` for a `mos`; `base`, `emitter` and `collector` for a `bjt`;
`end_a` and `end_b` for a resistor or an inductor; `top` and `bottom` for a capacitor; `anode` and
`cathode` for a diode. See [LVS controls](../deck/lvs-controls.md).

**Example violation.** The layout is an inverter with a 5 µm by 5 µm `cmim` load from `Y` to `VSS`,
its top plate on `Y`. The reference writes `M1` with its source and drain swapped, and the
capacitor's plates swapped:

```text
.subckt inv A Y VDD VSS
M1 VSS A Y VSS nfet W=1u L=0.15u
M2 Y A VDD VDD pfet W=2u L=0.15u
C1 VSS Y cmim c=50f
.ends
```

```sh
gpurify lvs invcap.gds --deck example.deck --reference invcap_swap.spice
```

```text
violations: 14
...
lvs: Mismatch([UnpairedDevice { side: Layout, device: 0, model: "cmim" }, UnpairedDevice { side: Layout, device: 1, model: "nfet" }, UnpairedDevice { side: Layout, device: 2, model: "pfet" }, UnpairedNet { side: Layout, net: 0, name: Some("VSS") }, UnpairedNet { side: Layout, net: 1, name: Some("A") }, UnpairedNet { side: Layout, net: 2, name: Some("Y") }, UnpairedNet { side: Layout, net: 3, name: Some("VDD") }, UnpairedDevice { side: Reference, device: 0, model: "nfet" }, UnpairedDevice { side: Reference, device: 1, model: "pfet" }, UnpairedDevice { side: Reference, device: 2, model: "cmim" }, UnpairedNet { side: Reference, net: 0, name: Some("A") }, UnpairedNet { side: Reference, net: 1, name: Some("Y") }, UnpairedNet { side: Reference, net: 2, name: Some("VDD") }, UnpairedNet { side: Reference, net: 3, name: Some("VSS") }])
```

The capacitor's top plate is on `VSS` in the reference and on `Y` in the layout, so no device or net
pairs. With the plates written `C1 Y VSS`, the same run reports `lvs: Match`: `M1`'s swapped source
and drain pass. With `lvs permute "cmim" top bottom`, the run above also reports `lvs: Match`.

**Status and limits.** Implemented. Devices whose interchangeable pins are other than a transistor's
source and drain merge in parallel either way round, and never in series. The reference is compared
flat, so the pins of a subcircuit, which KLayout's `equivalent_pins` declares interchangeable, don't
exist here; a black box's pins pair by name (see [LVS-033](#lvs-033-black-boxes)). The deck is
refused when it permutes a pin with itself, or an asymmetric transistor's source with its drain.

**Sources.** Netgen `permute` (<http://opencircuitdesign.com/netgen/reference.html>); KLayout LVS
`equivalent_pins` (<https://www.klayout.de/doc/about/lvs_ref_netter.html>).

### LVS-031: Asymmetric devices

**What it catches.** An asymmetric transistor, such as an LDMOS or an extended-drain device, drawn or
written the wrong way round. Its drain stands the high voltage and its source does not. A swapped
device breaks down in use, while a symmetric comparison passes it.

**How GPurify measures it.** Under `lvs asymmetric`, the model's source pairs only with a source and
its drain only with a drain. That holds in pairing, in the terminal comparison and in a parallel
merge, which joins such transistors only source on source and drain on drain. A diffusion parameter
is compared at the end it is named for: `as` and `ps` at the source, `ad` and `pd` at the drain. In
the layout, the source is the terminal the `device` line lists second and the drain the one it lists
third.

![Reference inverter whose M1 has its source on Y, beside the layout's nfet with its source on VSS, both boxed](../../diagrams/lvs-031.svg)

**In the deck.**

```text
lvs asymmetric "<model>"
```

```text
lvs asymmetric "nfet"
```

Added to [the example deck](README.md#the-example-deck). The model must be a `mos`. See
[LVS controls](../deck/lvs-controls.md).

**Example violation.** The layout is the example inverter, `inv.gds`, its n-channel source on `VSS`.
The reference writes `M1` with its drain on `VSS` and its source on `Y`:

```text
.subckt inv A Y VDD VSS
M1 VSS A Y VSS nfet W=1u L=0.15u
M2 Y A VDD VDD pfet W=2u L=0.15u
.ends
```

```sh
gpurify lvs inv.gds --deck example.deck --reference inv_sd.spice
```

```text
violations: 12
...
lvs: Mismatch([UnpairedDevice { side: Layout, device: 0, model: "nfet" }, UnpairedDevice { side: Layout, device: 1, model: "pfet" }, UnpairedNet { side: Layout, net: 0, name: Some("VSS") }, UnpairedNet { side: Layout, net: 1, name: Some("A") }, UnpairedNet { side: Layout, net: 2, name: Some("Y") }, UnpairedNet { side: Layout, net: 3, name: Some("VDD") }, UnpairedDevice { side: Reference, device: 0, model: "nfet" }, UnpairedDevice { side: Reference, device: 1, model: "pfet" }, UnpairedNet { side: Reference, net: 0, name: Some("A") }, UnpairedNet { side: Reference, net: 1, name: Some("Y") }, UnpairedNet { side: Reference, net: 2, name: Some("VDD") }, UnpairedNet { side: Reference, net: 3, name: Some("VSS") }])
```

The `nfet`'s source is on `VSS` in the layout and on `Y` in the reference, so nothing pairs. Without
`lvs asymmetric`, the same run reports `lvs: Match`, and so does this deck against the reference
`inv.spice`, which writes `M1 Y A VSS VSS`.

**Status and limits.** Implemented. Asymmetric transistors never merge in series, so a stack of them
does not match one card of the summed length: a false mismatch, never a false match. In the example
deck, source and drain are both drawn on `nsd`, so nothing in the layout tells them apart, and
GPurify takes the diffusion it reads first as the source. Give an asymmetric model a drain layer of
its own, such as its drift region, so the layout says which end is which.

**Sources.** KLayout LVS `dmos3` and `dmos4` device classes
(<https://www.klayout.de/doc/about/lvs_device_extractors.html>); Netgen, a model given no `permute`
(<http://opencircuitdesign.com/netgen/reference.html>).

## Names that seed the pairing

### LVS-032: Net-name seeding

**What it catches.** A net the wiring alone cannot tell from another, paired with the wrong partner.
The two halves of a symmetric circuit look alike from every device, so a crossed layout matches by
structure. Holding named nets together makes LVS catch the crossing.

**How GPurify measures it.** By default, names only break ties: where the wiring and the diffusions
leave nets interchangeable, a layout net pairs first with the reference net its label names, as
KLayout's `consider_net_names` does. A name never forces a pairing the wiring contradicts.
`lvs same_nets "<layout>" "<reference>"` pairs the layout net with that label and the reference net of
that name, which need not match or be a port. The two start in a class of their own, so they pair
with each other or with nothing: a pair whose wiring disagrees is reported as `lvs.unpaired_net`.
`lvs ports_by_name` does the same for every port of the reference's top subcircuit and the layout
net its name labels (see [LVS-016](compare.md#lvs-016-pin-or-port-mismatch)).

![Two differential pairs; the layout's INP transistor drives OUTN, where the reference's P transistor drives X, so the same_nets pairs disagree](../../diagrams/lvs-032.svg)

**In the deck.**

```text
lvs same_nets "<layout label>" "<reference net>"
lvs ports_by_name
```

```text
lvs same_nets "INP" "P"
lvs same_nets "OUTP" "X"
```

Added to [the example deck](README.md#the-example-deck). Each net is named by one `same_nets` row at
most. Under `lvs ports_by_name`, a port's own name wins. See [LVS controls](../deck/lvs-controls.md).

**Example violation.** The layout is a differential pair of two 1 µm transistors on a tail `T`, drawn
crossed: the transistor on `INP` drives `OUTN`. The reference names its nets differently and wires
the transistor on `P` to `X`:

```text
.subckt pair P N X Z T
M1 X P T T nfet W=1u L=0.5u
M2 Z N T T nfet W=1u L=0.5u
.ends
```

```sh
gpurify lvs pair_crossed.gds --deck example.deck --reference pair.spice
```

```text
violations: 14
...
lvs: Mismatch([UnpairedDevice { side: Layout, device: 0, model: "nfet" }, UnpairedDevice { side: Layout, device: 1, model: "nfet" }, UnpairedNet { side: Layout, net: 0, name: Some("T") }, UnpairedNet { side: Layout, net: 1, name: Some("INP") }, UnpairedNet { side: Layout, net: 2, name: Some("OUTN") }, UnpairedNet { side: Layout, net: 3, name: Some("INN") }, UnpairedNet { side: Layout, net: 4, name: Some("OUTP") }, UnpairedDevice { side: Reference, device: 0, model: "nfet" }, UnpairedDevice { side: Reference, device: 1, model: "nfet" }, UnpairedNet { side: Reference, net: 0, name: Some("P") }, UnpairedNet { side: Reference, net: 1, name: Some("N") }, UnpairedNet { side: Reference, net: 2, name: Some("X") }, UnpairedNet { side: Reference, net: 3, name: Some("Z") }, UnpairedNet { side: Reference, net: 4, name: Some("T") }])
```

`INP` is held to `P` and `OUTP` to `X`, but `INP`'s transistor drives `OUTN`, so the seeds disagree
with the wiring and nothing pairs. Without the two `same_nets` lines the same run reports
`lvs: Match`: the crossed pair is the same circuit with two nets renamed. Against a reference that
wires `P`'s transistor to `Z` and `N`'s to `X`, the lines hold and the run reports `lvs: Match`.

**Status and limits.** Implemented. Every `same_nets` row is held: KLayout's plain `same_nets`, a
hint whose disagreement is not an error, has no separate form here. A row whose label names no layout
net leaves its reference net without a partner, which is a mismatch.

**Sources.** KLayout LVS `same_nets`, `same_nets!` and `consider_net_names`
(<https://www.klayout.de/doc/about/lvs_ref_netter.html>).

## Cells and devices left out

### LVS-033: Black boxes

**What it catches.** A cell to compare by its pins alone: a macro whose schematic you don't have, a
memory, or a foundry cell such as a SkyWater VPP capacitor. Its contents are verified elsewhere or
not at all, but how it is wired into the circuit around it still needs checking.

**How GPurify measures it.** `lvs blackbox "<pattern>"` names cells by whole-name pattern. On the
layout, each placement of a matching cell is one device of that cell's name. Its pins are the cell's
own text labels on a label layer, each on the net of the shape it sits on. Every device drawn wholly
inside the placement's extent leaves the comparison; the cell's wiring stays in the nets. In the
reference, each `X` call of a matching subcircuit is one device on the call's nets, and the
subcircuit's body is not read. A pin pairs only with the port of its name, and black boxes never
merge.

![Reference inverter driving a macro box on pin N, beside the layout whose Y reaches the box's pin P; the reference box is marked](../../diagrams/lvs-033.svg)

**In the deck.**

```text
lvs blackbox "<cell pattern>"
```

```text
lvs blackbox "macro"
```

Added to [the example deck](README.md#the-example-deck). `*` matches any run of characters and `?`
one, case included; give one statement per pattern. See [LVS controls](../deck/lvs-controls.md).

**Example violation.** The layout is an inverter whose output `Y` runs to pin `P` of a placed cell
`macro`, which holds a 3 kΩ poly resistor and labels its pins `P` and `N` on `li_label`. Pin `N` is
on net `Z`. The reference defines `macro` with no body and wires it the other way round:

```text
.subckt macro P N
.ends
.subckt top A Y Z VDD VSS
M1 Y A VSS VSS nfet W=1u L=0.15u
M2 Y A VDD VDD pfet W=2u L=0.15u
X1 Z Y macro
.ends
```

```sh
gpurify lvs bbox.gds --deck example.deck --reference bbox_swap.spice
```

```text
violations: 17
...
lvs unpaired instances:
  X1 (macro): none of its 1 devices has a partner in the layout
lvs: Mismatch([UnpairedDevice { side: Layout, device: 0, model: "nfet" }, UnpairedDevice { side: Layout, device: 1, model: "pfet" }, UnpairedDevice { side: Layout, device: 2, model: "macro" }, UnpairedNet { side: Layout, net: 0, name: Some("VSS") }, UnpairedNet { side: Layout, net: 1, name: Some("A") }, UnpairedNet { side: Layout, net: 2, name: Some("Y") }, UnpairedNet { side: Layout, net: 3, name: Some("VDD") }, UnpairedNet { side: Layout, net: 4, name: Some("Z") }, UnpairedDevice { side: Reference, device: 0, model: "nfet" }, UnpairedDevice { side: Reference, device: 1, model: "pfet" }, UnpairedDevice { side: Reference, device: 2, model: "macro" }, UnpairedNet { side: Reference, net: 0, name: Some("A") }, UnpairedNet { side: Reference, net: 1, name: Some("Y") }, UnpairedNet { side: Reference, net: 2, name: Some("Z") }, UnpairedNet { side: Reference, net: 3, name: Some("VDD") }, UnpairedNet { side: Reference, net: 4, name: Some("VSS") }])
```

The reference puts `Y` on the box's pin `N` and the layout on pin `P`, so the box and its nets don't
pair, and instance `X1` is named. With `X1 Y Z macro` the run reports `lvs: Match`, the resistor
inside the box left out. Without `lvs blackbox`, the layout's resistor has no partner in the empty
`macro`, and the run is a mismatch.

**Status and limits.** Partial. A pin needs a text label inside the cell: unlabelled pins are not
paired by position, as KLayout pairs them. A device belongs to a box when it lies wholly inside the
placement's extent, so a parent's device drawn inside that rectangle is taken for the box's. A
reference subcircuit that is called but not defined is refused (`UndefinedSubckt`); an empty
`.subckt` with its ports is enough. A box has at most 256 pins. See
[issue 9](https://github.com/OmarSiwy/GPurify/issues/9).

**Sources.** KLayout LVS `blank_circuit` (<https://www.klayout.de/doc/about/lvs_ref_netter.html>);
Netgen `model ... blackbox` (<http://opencircuitdesign.com/netgen/reference.html>).

### LVS-034: Ignored devices and parasitic filters

**What it catches.** Nothing on its own: it keeps devices out of the comparison that one side draws
and the other does not state. Fill, decap and tap cells sit in the layout and not in the schematic.
A very large resistor or a tiny capacitor is often a parasitic or a measurement structure, not part
of the circuit.

**How GPurify measures it.** `lvs ignore "<model>"` drops every device of the model on both sides
before reduction, as Netgen's `ignore class` does. A net only those devices reached is dropped with
them. A reference port or a labelled layout net stays, and must still pair. `lvs max_res` drops
each resistor above the resistance, and `lvs min_caps` each capacitor below the capacitance, on
both sides, as opens. The layout's value is the one the device line's `sheet`,
`area_cap` or `fringe_cap` gives; a device with no value to read stays.

![Reference inverter beside the layout inverter with an extra 50 fF cmim decap from VDD to VSS, boxed as an extra device](../../diagrams/lvs-034.svg)

**In the deck.**

```text
lvs ignore "<model>"
lvs max_res <resistance>
lvs min_caps <capacitance>
```

```text
lvs ignore "cmim"
```

Added to [the example deck](README.md#the-example-deck). The model of `lvs ignore` need not have a
`device` line. `lvs max_res` and `lvs min_caps` are stated once each, positive. See
[LVS controls](../deck/lvs-controls.md).

**Example violation.** The layout is an inverter with a 5 µm by 5 µm `cmim` decap between `VDD` and
`VSS`, 50 fF at 2 fF/µm². The reference is the inverter alone:

```text
.subckt inv A Y VDD VSS
M1 Y A VSS VSS nfet W=1u L=0.15u
M2 Y A VDD VDD pfet W=2u L=0.15u
.ends
```

```sh
gpurify lvs invdecap.gds --deck example.deck --reference inv.spice
```

Without the `lvs ignore` line:

```text
violations: 13
...
lvs: Mismatch([UnpairedDevice { side: Layout, device: 0, model: "cmim" }, UnpairedDevice { side: Layout, device: 1, model: "nfet" }, UnpairedDevice { side: Layout, device: 2, model: "pfet" }, UnpairedNet { side: Layout, net: 0, name: Some("VSS") }, UnpairedNet { side: Layout, net: 1, name: Some("A") }, UnpairedNet { side: Layout, net: 2, name: Some("Y") }, UnpairedNet { side: Layout, net: 3, name: Some("VDD") }, UnpairedDevice { side: Reference, device: 0, model: "nfet" }, UnpairedDevice { side: Reference, device: 1, model: "pfet" }, UnpairedNet { side: Reference, net: 0, name: Some("A") }, UnpairedNet { side: Reference, net: 1, name: Some("Y") }, UnpairedNet { side: Reference, net: 2, name: Some("VDD") }, UnpairedNet { side: Reference, net: 3, name: Some("VSS") }])
```

With it:

```text
violations: 0
lvs: Match
```

The layout's decap has no partner, and the comparison reports every device and net unpaired. With
`lvs ignore "cmim"`, or `lvs min_caps 100fF` in its place, the decap is left out and the run reports
`lvs: Match`; `lvs min_caps 40fF` keeps the 50 fF decap. Likewise, a 3 kΩ poly resistor from `VDD`
to `VSS` matches the inverter under `lvs max_res 1kohm` and not under `lvs max_res 5kohm`.

**Status and limits.** Implemented. The layout's own checks still see an ignored device. Magic's
`cthresh` filters parasitic capacitance at extraction; GPurify's LVS extracts no parasitic
capacitance, so there is none to filter.

**Sources.** Netgen `ignore class` (<http://opencircuitdesign.com/netgen/reference.html>); KLayout
LVS `same_device_classes` with `nil`, `max_res` and `min_caps`
(<https://www.klayout.de/doc/about/lvs_ref_netter.html>); Magic `ext2spice cthresh`
(<http://opencircuitdesign.com/magic/commandref/ext2spice.html>).

### LVS-035: Dummy device removal

**What it catches.** Nothing on its own: it keeps dummies out of the comparison. A dummy transistor
at the end of a row has its gate, source and drain tied to one net, for matching and etch uniformity.
It does nothing electrically, and a schematic seldom states it.

**How GPurify measures it.** `lvs ignore_shorted "<model>"` drops each device of the model whose
every compared terminal is on one net, on both sides before reduction, as Netgen's `ignore shorted`
does. Where the deck extracts no bulk, the reference's bulk is already dropped, so a transistor with
its gate, source and drain on one net is a dummy whatever its reference bulk is. A net only the
dummies reached is dropped with them unless it is a port.

![Reference inverter beside the layout inverter plus an nfet with gate, source and drain on VSS, boxed as a dummy](../../diagrams/lvs-035.svg)

**In the deck.**

```text
lvs ignore_shorted "<model>"
```

```text
lvs ignore_shorted "nfet"
```

Added to [the example deck](README.md#the-example-deck). See [LVS controls](../deck/lvs-controls.md).

**Example violation.** The layout is an inverter with a third, 1 µm `nfet` whose gate, source and
drain are all on `VSS`. The reference is the inverter alone, `inv.spice` as under
[LVS-034](#lvs-034-ignored-devices-and-parasitic-filters):

```sh
gpurify lvs invdummy.gds --deck example.deck --reference inv.spice
```

Without the `lvs ignore_shorted` line:

```text
violations: 13
...
lvs: Mismatch([UnpairedDevice { side: Layout, device: 0, model: "nfet" }, UnpairedDevice { side: Layout, device: 1, model: "nfet" }, UnpairedDevice { side: Layout, device: 2, model: "pfet" }, UnpairedNet { side: Layout, net: 0, name: Some("VSS") }, UnpairedNet { side: Layout, net: 1, name: Some("A") }, UnpairedNet { side: Layout, net: 2, name: Some("Y") }, UnpairedNet { side: Layout, net: 3, name: Some("VDD") }, UnpairedDevice { side: Reference, device: 0, model: "nfet" }, UnpairedDevice { side: Reference, device: 1, model: "pfet" }, UnpairedNet { side: Reference, net: 0, name: Some("A") }, UnpairedNet { side: Reference, net: 1, name: Some("Y") }, UnpairedNet { side: Reference, net: 2, name: Some("VDD") }, UnpairedNet { side: Reference, net: 3, name: Some("VSS") }])
```

With it:

```text
violations: 0
lvs: Match
```

The dummy is a third transistor the reference lacks, so the comparison fails;
`lvs ignore_shorted "nfet"` leaves it out and the inverter matches.

**Status and limits.** Implemented. No known limits.

**Sources.** Netgen `ignore shorted` (<http://opencircuitdesign.com/netgen/reference.html>).

## Split stacks

### LVS-077: Split gates

**What it catches.** A wide transistor stack drawn as fingers, each finger's stack with inner nets of
its own, where the schematic has one stack. Standard cells draw a wide NAND or AOI pull-down this
way. Without joining the fingers, a correct layout fails LVS with twice the transistors of the
schematic.

**How GPurify measures it.** Under `lvs split_gates`, before reduction and on both sides, GPurify
looks for chains: transistors in series from one net to another, through inner nets that each join
exactly two channel ends and nothing else. Two chains between the same two nets that agree position
by position in model, gate and bulk nets and `l` are fingers of one stack. Their inner nets are
joined, so the fingers then merge in parallel, and the widths add. An inner net that carries a
layout label, or is a port of the reference, is never joined.

![Before: two fingers of an A-over-B nfet stack, each 1 µm with its own inner net. After split_gates: one stack of 2 µm transistors, matching the reference](../../diagrams/lvs-077.svg)

**In the deck.**

```text
lvs split_gates
```

Added to [the example deck](README.md#the-example-deck). The shipped `asap7` deck states it. See
[LVS controls](../deck/lvs-controls.md).

**Example violation.** The layout draws an `nfet` stack from `Y` to `VSS`, gate `A` over gate `B`, as
two fingers side by side. Each finger is 1 µm wide with its own uncontacted inner net. The reference
writes one stack of 2 µm transistors:

```text
.subckt nand A B Y VSS
M1 Y A n1 VSS nfet W=2u L=0.15u
M2 n1 B VSS VSS nfet W=2u L=0.15u
.ends
```

```sh
gpurify lvs split.gds --deck example.deck --reference split.spice
```

Without the `lvs split_gates` line:

```text
violations: 17
...
lvs: Mismatch([UnpairedDevice { side: Layout, device: 0, model: "nfet" }, UnpairedDevice { side: Layout, device: 1, model: "nfet" }, UnpairedDevice { side: Layout, device: 2, model: "nfet" }, UnpairedDevice { side: Layout, device: 3, model: "nfet" }, UnpairedNet { side: Layout, net: 0, name: Some("Y") }, UnpairedNet { side: Layout, net: 1, name: Some("A") }, UnpairedNet { side: Layout, net: 2, name: Some("B") }, UnpairedNet { side: Layout, net: 3, name: Some("VSS") }, UnpairedNet { side: Layout, net: 4, name: None }, UnpairedNet { side: Layout, net: 5, name: None }, UnpairedDevice { side: Reference, device: 0, model: "nfet" }, UnpairedDevice { side: Reference, device: 1, model: "nfet" }, UnpairedNet { side: Reference, net: 0, name: Some("A") }, UnpairedNet { side: Reference, net: 1, name: Some("B") }, UnpairedNet { side: Reference, net: 2, name: Some("Y") }, UnpairedNet { side: Reference, net: 3, name: Some("VSS") }, UnpairedNet { side: Reference, net: 4, name: Some("n1") }])
```

With it:

```text
violations: 0
lvs merges:
  layout parallel: 2 devices of nfet (0, 2) are one
  layout parallel: 2 devices of nfet (1, 3) are one
lvs: Match
```

Without the line, four 1 µm transistors and two inner nets face two 2 µm transistors and one, and
nothing pairs. With it, the two inner nets are joined, layout devices 0 and 2 merge into the 2 µm
`A` transistor and 1 and 3 into the `B` one, and the run matches.

The ASAP7 cell `AOI21x1_ASAP7_75t_R` draws its 6-fin `A1`-`A2` stack as two 3-fin stacks. Against
its own CDL on the shipped deck:

```sh
gpurify lvs AOI21x1_ASAP7_75t_R.gds --deck asap7 --reference AOI21x1_ASAP7_75t_R.cdl
```

```text
violations: 0
lvs merges:
  layout parallel: 2 devices of nmos_rvt (0, 5) are one
  layout parallel: 2 devices of nmos_rvt (1, 4) are one
  layout parallel: 2 devices of nmos_rvt (2, 3) are one
  layout parallel: 2 devices of pmos_rvt (6, 11) are one
  layout parallel: 2 devices of pmos_rvt (7, 10) are one
  layout parallel: 2 devices of pmos_rvt (8, 9) are one
lvs: Match
```

The same run on a copy of the deck without `lvs split_gates` reports a mismatch.

**Status and limits.** Implemented. Fingers must be drawn in the same order: a finger stacked `B`
over `A` beside one stacked `A` over `B` is no finger of it, and the run reports a mismatch. The
same holds for ASAP7's `NAND3x2` and `OAI21x1`. A finger whose inner net a strap joins to another
finger's, so that it joins more than two channel ends, is no chain either.

**Sources.** KLayout LVS `split_gates` (<https://www.klayout.de/doc/about/lvs_ref_netter.html>);
ASAP7 standard-cell library `asap7sc7p5t_28`, cell `AOI21x1_ASAP7_75t_R`
(<https://github.com/The-OpenROAD-Project/asap7sc7p5t_28>).
