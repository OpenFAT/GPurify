# Netlist reduction

Before it compares, LVS reduces both sides, so that fingers, stacks and parallel groups become the one device a schematic writes. Each entry gives one reduction rule and its conditions, and the report lists every merge under `lvs merges:` (see [How a mismatch is reported](README.md#how-a-mismatch-is-reported)).

## Transistors

### LVS-040: Parallel MOS

**What it catches.** A transistor drawn as several devices side by side, where the schematic writes one wide device. Without reduction, two 1 µm transistors never pair with one 2 µm card, and LVS reports a correct layout as a mismatch. Fingers of different lengths stay apart: they are a different circuit.

**How GPurify measures it.** Transistors of one model merge in parallel when their gates, bulks and source/drain pairs land on the same nets. Source and drain are interchangeable, so a finger drawn the other way round still merges. The merged device's `w`, `nf` and `nfin` are the sums of its members'. `as`, `ad`, `ps` and `pd` are summed end by end. Every other parameter, `l` included, must be identical; the comparison's tolerance plays no part. A transistor with no `w` merges only by counting `m`.

![Two 1 µm nfets on G, S, D reduce to one 2 µm nfet matching the reference; a second pair with lengths 0.15 µm and 0.3 µm does not merge](../../diagrams/lvs-040.svg)

**In the deck.** Nothing to write in the deck beyond its `device` lines. Run LVS with a reference netlist.

**Example violation.** The layout draws two 1 µm n-channel transistors apart, both on `G`, `S` and `D`. The reference writes one of 2 µm:

```text
.subckt pair G S D
M1 D G S S nfet W=2u L=0.15u
.ends
```

```sh
gpurify lvs nfet_pair.gds --deck example.deck --reference pair_w2.spice
```

```text
violations: 0
lvs merges:
  layout parallel: 2 devices of nfet (0, 1) are one
lvs: Match
```

The two drawn transistors merge into one 2 µm device, which pairs with the card. In a second layout the second transistor is 0.3 µm long:

```sh
gpurify lvs pair_l.gds --deck example.deck --reference pair_w2.spice
```

```text
violations: 9
...
lvs: Mismatch([UnpairedDevice { side: Layout, device: 0, model: "nfet" }, UnpairedDevice { side: Layout, device: 1, model: "nfet" }, UnpairedNet { side: Layout, net: 0, name: Some("S") }, UnpairedNet { side: Layout, net: 1, name: Some("G") }, UnpairedNet { side: Layout, net: 2, name: Some("D") }, UnpairedDevice { side: Reference, device: 0, model: "nfet" }, UnpairedNet { side: Reference, net: 0, name: Some("G") }, UnpairedNet { side: Reference, net: 1, name: Some("S") }, UnpairedNet { side: Reference, net: 2, name: Some("D") }])
```

The lengths differ, so nothing merges and no `lvs merges:` line is printed. Two layout transistors face one reference card, and every device and net is unpaired.

**Status and limits.** Implemented. Lengths must be identical, not within the tolerance: Netgen's `l critical` merges nearly equal lengths, GPurify does not. A transistor declared with `lvs asymmetric` merges only source on source and drain on drain (see [Equivalence, swappable pins and black boxes](equivalence.md)).

**Sources.** KLayout LVS device combination (<https://www.klayout.de/doc/about/lvs_ref_netter.html>); Netgen `property` parallel combination (<http://opencircuitdesign.com/netgen/reference.html>); Magic `ext2spice merge`; Siemens Calibre `LVS REDUCE PARALLEL MOS`.

### LVS-041: Series MOS

**What it catches.** A long transistor drawn as a stack of short ones through an uncontacted node, where the schematic writes one device of the summed length. Analog designers stack transistors for long channels; without reduction the stack never pairs with the card.

**How GPurify measures it.** Two transistors of one model merge in series when they meet at a net that holds only their two channel ends. That net must be no port, and carry no layout label: a label makes it a port, on both sides. Their gates and bulks must be on the same nets, and both must state `l`. The merged device's `l` is the sum; every other parameter must be identical. Series merging is on by default. Parallel and series merges repeat, parallel first, until nothing more merges. A transistor that states `as`, `ad`, `ps` or `pd`, or `sa` or `sb`, never merges in series.

![Two nfets of 0.15 µm in series through an unlabelled node reduce to one of 0.3 µm; with the inner node labelled M they stay two](../../diagrams/lvs-041.svg)

**In the deck.** Nothing to write in the deck beyond its `device` lines. Run LVS with a reference netlist.

**Example violation.** The layout draws one diffusion strip crossed by two 0.15 µm gates, both on `G`, with no contact between them. The reference writes one 0.3 µm transistor:

```text
.subckt stack G S D
M1 D G S S nfet W=1u L=0.3u
.ends
```

```sh
gpurify lvs stack2.gds --deck example.deck --reference stack_l03.spice
```

```text
violations: 0
lvs merges:
  layout series: 2 devices of nfet (0, 1) are one
lvs: Match
```

The stack merges into one 0.3 µm device. In a second layout the inner node is contacted and labelled `M`:

```sh
gpurify lvs stack_m.gds --deck example.deck --reference stack_l03.spice
```

```text
violations: 10
...
lvs: Mismatch([UnpairedDevice { side: Layout, device: 0, model: "nfet" }, UnpairedDevice { side: Layout, device: 1, model: "nfet" }, UnpairedNet { side: Layout, net: 0, name: Some("D") }, UnpairedNet { side: Layout, net: 1, name: Some("G") }, UnpairedNet { side: Layout, net: 2, name: Some("M") }, UnpairedNet { side: Layout, net: 3, name: Some("S") }, UnpairedDevice { side: Reference, device: 0, model: "nfet" }, UnpairedNet { side: Reference, net: 0, name: Some("G") }, UnpairedNet { side: Reference, net: 1, name: Some("S") }, UnpairedNet { side: Reference, net: 2, name: Some("D") }])
```

The label makes `M` a port, so the stack stays two transistors against one card.

**Status and limits.** Implemented. Netgen merges no transistors in series, so a stack that matches here mismatches under Netgen. Transistors on different gates, a NAND's stack for example, merge only under `lvs recognize_gates` ([LVS-047](#lvs-047-logic-gate-recognition)).

**Sources.** Siemens Calibre `LVS REDUCE SERIES MOS`; Netgen `property` series combination (<http://opencircuitdesign.com/netgen/reference.html>).

### LVS-042: Semi-series MOS

**What it catches.** Calibre names a third transistor reduction, `LVS REDUCE SEMI SERIES MOS`, apart from series MOS and from split gates. No public source defines which topology it reduces or what device it yields.

**Status and limits.** Missing. GPurify has no semi-series reduction and no deck statement for one. The sources searched are Siemens's public pages, published Calibre rule decks and LVS reports, US 2010/0306720 A1, the KLayout and Netgen sources, and the SubGemini paper; none defines it. The Calibre manual is not public.

**Sources.** Siemens Calibre `LVS REDUCE SEMI SERIES MOS` (statement name only).

## Passives

### LVS-043: Resistor series and parallel

**What it catches.** A resistor drawn as several segments in series, or several in parallel, where the schematic writes one resistor of the combined value. Long poly resistors are often drawn as segments joined by metal. Without reduction, their segments never pair with the card.

**How GPurify measures it.** Under the default `lvs topology strict`, resistors of one model on the same two nets merge in parallel. The merged device keeps its `r` and counts the members in `m`: it matches one card with `m=2`. Resistors never merge in series under strict. Under `lvs topology relaxed`, a resistor whose card states `r` combines by value. In parallel, `r` combines harmonically, \\( 1 / \sum 1/r \\), while `w`, `area` and `perim` add and `l` must agree. In series, through a net only the two touch and that is no port, `r`, `l`, `area` and `perim` add and `w` must agree.

![Two 3 kΩ rpoly resistors in series through M reduce under relaxed to one 6 kΩ resistor matching the reference; under strict they stay two](../../diagrams/lvs-043.svg)

**In the deck.**

```text
lvs topology strict
lvs topology relaxed
```

```text
lvs topology relaxed
```

Added to [the example deck](README.md#the-example-deck), saved as `relaxed.deck`. See [LVS controls](../deck/lvs-controls.md).

**Example violation.** The layout draws two 0.5 µm by 5 µm poly resistors, 3 kΩ each at 300 Ω per square, in series from `A` through an unlabelled net to `B`. The reference writes one of 6 kΩ:

```text
.subckt rs A B
R1 A B rpoly r=6k w=0.5u
.ends
```

```sh
gpurify lvs res_series.gds --deck relaxed.deck --reference res_6k.spice
```

```text
violations: 0
lvs merges:
  layout series: 2 devices of rpoly (0, 1) are one
lvs: Match
```

The two segments add to 6 kΩ, with `w` 0.5 µm on both. On the example deck, strict by default:

```sh
gpurify lvs res_series.gds --deck example.deck --reference res_6k.spice
```

```text
violations: 8
...
lvs: Mismatch([UnpairedDevice { side: Layout, device: 0, model: "rpoly" }, UnpairedDevice { side: Layout, device: 1, model: "rpoly" }, UnpairedNet { side: Layout, net: 0, name: Some("A") }, UnpairedNet { side: Layout, net: 1, name: None }, UnpairedNet { side: Layout, net: 2, name: Some("B") }, UnpairedDevice { side: Reference, device: 0, model: "rpoly" }, UnpairedNet { side: Reference, net: 0, name: Some("A") }, UnpairedNet { side: Reference, net: 1, name: Some("B") }])
```

Strict, the segments stay two resistors with an unnamed net between them, against one card.

**Status and limits.** Implemented. A resistor whose card states no `r` keeps its count under relaxed too.

**Sources.** KLayout LVS resistor combination (<https://www.klayout.de/doc/about/lvs_ref_netter.html>); Netgen `property` series and parallel, as the SkyWater SKY130 Netgen setup states them (<http://opencircuitdesign.com/netgen/reference.html>).

### LVS-044: Capacitor, diode and bipolar parallel

**What it catches.** A capacitor, diode or bipolar transistor drawn as several in parallel, where the schematic writes one of the combined size or value, or one with `m`. A MiM capacitor is often drawn as an array of unit plates.

**How GPurify measures it.** Devices of one model whose terminals land on the same nets, pin for pin, merge in parallel. Under the default `lvs topology strict`, the merged device keeps its value and counts the members in `m`: two 50 fF capacitors match one card `c=50f m=2`. Under `lvs topology relaxed`, a device whose card states its value combines by adding it: `c` for a capacitor, `area` for a diode, `ae` for a bipolar, with `area`, `perim` and `pe` adding along. Under relaxed, capacitors chained plate to plate through a net only the two touch and that is no port also merge in series, \\( 1 / \sum 1/c \\). A card's `m` folds into its value first.

![Two 50 fF cmim capacitors on T and B reduce under relaxed to one 100 fF capacitor; with the second one's plates reversed they stay two](../../diagrams/lvs-044.svg)

**In the deck.**

```text
lvs topology strict
lvs topology relaxed
```

```text
lvs topology relaxed
```

Added to [the example deck](README.md#the-example-deck), saved as `relaxed.deck`. See [LVS controls](../deck/lvs-controls.md).

**Example violation.** The layout draws two 5 µm by 5 µm MiM capacitors, 50 fF each at 2 fF/µm², both with the top plate on `T` and the bottom on `B`. The reference writes one of 100 fF:

```text
.subckt cp T B
C1 T B cmim c=100f
.ends
```

```sh
gpurify lvs cap_pair.gds --deck relaxed.deck --reference cap_100f.spice
```

```text
violations: 0
lvs merges:
  layout parallel: 2 devices of cmim (0, 1) are one
lvs: Match
```

The two capacitors add to 100 fF. In a second layout the second capacitor's top plate is on `B`:

```sh
gpurify lvs cap_rev.gds --deck relaxed.deck --reference cap_100f.spice
```

```text
violations: 7
...
lvs: Mismatch([UnpairedDevice { side: Layout, device: 0, model: "cmim" }, UnpairedDevice { side: Layout, device: 1, model: "cmim" }, UnpairedNet { side: Layout, net: 0, name: Some("B") }, UnpairedNet { side: Layout, net: 1, name: Some("T") }, UnpairedDevice { side: Reference, device: 0, model: "cmim" }, UnpairedNet { side: Reference, net: 0, name: Some("T") }, UnpairedNet { side: Reference, net: 1, name: Some("B") }])
```

The plates are not on the same nets pin for pin, so the two capacitors stay apart against one card.

**Status and limits.** Implemented. Plates wired either way merge once `lvs permute "cmim" top bottom` makes them interchangeable. Diodes wired in opposite directions never merge, and diodes and bipolars never merge in series; neither KLayout nor Netgen merges them so.

**Sources.** KLayout LVS capacitor combination (<https://www.klayout.de/doc/about/lvs_ref_netter.html>); Netgen `property` parallel combination (<http://opencircuitdesign.com/netgen/reference.html>); Magic `ext2spice merge`; Siemens Calibre `LVS REDUCE SERIES CAPACITORS`.

## Merge conditions and counts

### LVS-045: Bulk equality for merges

**What it catches.** Two transistors that sit side by side on the same gate, source and drain but in wells tied to different nets. They are not one device: each well sets its own threshold and leakage. Merging them would hide a well wired to the wrong supply.

**How GPurify measures it.** A parallel merge needs every terminal on the same net, the bulk included; a series merge needs the same gate and bulk nets. The bulk counts only when the deck's `device` line extracts one, as a fourth `mos` terminal. When the deck extracts no bulk, as the example deck does, the reference's bulk terminals are dropped before reduction and play no part.

![Two pfets on G, S, D with wells on VB reduce to one 2 µm pfet; with the second well on VB2 they stay two](../../diagrams/lvs-045.svg)

**In the deck.**

```text
device mos <marker> model "<model>" terminals [<gate>, <source>, <drain>, <bulk>]
```

```text
device mos pgate model "pfet" terminals [poly_c, psd, psd, nwell]
```

In place of the `pfet` line of [the example deck](README.md#the-example-deck), saved as `bulk.deck`.

**Example violation.** The layout draws two 1 µm p-channel transistors on `G`, `S` and `D`, each in a well of its own with a tap tied to `VB`. The reference writes one of 2 µm:

```text
.subckt pp G S D VB
M1 D G S VB pfet W=2u L=0.15u
.ends
```

```sh
gpurify lvs ppair.gds --deck bulk.deck --reference pfet_w2.spice
```

```text
violations: 0
lvs merges:
  layout parallel: 2 devices of pfet (0, 1) are one
lvs: Match
```

In a second layout the second well's tap is tied to `VB2`:

```sh
gpurify lvs ppair_split.gds --deck bulk.deck --reference pfet_w2.spice
```

```text
violations: 12
...
lvs: Mismatch([UnpairedDevice { side: Layout, device: 0, model: "pfet" }, UnpairedDevice { side: Layout, device: 1, model: "pfet" }, UnpairedNet { side: Layout, net: 0, name: Some("S") }, UnpairedNet { side: Layout, net: 1, name: Some("G") }, UnpairedNet { side: Layout, net: 2, name: Some("D") }, UnpairedNet { side: Layout, net: 3, name: Some("VB") }, UnpairedNet { side: Layout, net: 4, name: Some("VB2") }, UnpairedDevice { side: Reference, device: 0, model: "pfet" }, UnpairedNet { side: Reference, net: 0, name: Some("G") }, UnpairedNet { side: Reference, net: 1, name: Some("S") }, UnpairedNet { side: Reference, net: 2, name: Some("D") }, UnpairedNet { side: Reference, net: 3, name: Some("VB") }])
```

The bulks differ, so the two transistors stay apart against one card. A reference that writes two 1 µm cards on `VB` and `VB2` matches this layout one to one.

**Status and limits.** Implemented. No known limits.

**Sources.** KLayout LVS device combination, which compares every terminal (<https://www.klayout.de/doc/about/lvs_ref_netter.html>).

### LVS-046: Fingers, nf and m folding

**What it catches.** A transistor drawn as fingers on one diffusion, against a card that states its size with `nf` or `m`. The schematic's `W=0.5u m=4` and the layout's two 1 µm fingers are the same 2 µm of channel; LVS must see them as one device and still catch a wrong finger count.

**How GPurify measures it.** On each side, a transistor stating `w` or `nfin` has its `m` folded in first: `w`, `nfin`, `as`, `ad`, `ps` and `pd` are multiplied by `m`, and `m` is dropped. Every other device, and a transistor with neither, keeps `m` as its count, and a parallel merge adds the counts; under `lvs topology relaxed`, a passive stating its value folds `m` into it instead. A card without `m` counts 1. The layout measures `nf` 1 on each transistor, and a parallel merge adds it. The counts `m`, `nf` and `nfin` are compared exactly, never within the tolerance.

![Two 1 µm fingers sharing S reduce to one nfet of W 2 µm, nf 2, matching a W 0.5 µm m=4 card; against nf=3 the count differs](../../diagrams/lvs-046.svg)

**In the deck.** Nothing to write in the deck beyond its `device` lines. Run LVS with a reference netlist.

**Example violation.** The layout draws one diffusion strip crossed by two 1 µm wide gates on `G`: drain, gate, source, gate, drain. The reference writes four 0.5 µm devices with `m=4`:

```text
.subckt fingers G S D
M1 D G S S nfet W=0.5u L=0.15u m=4
.ends
```

```sh
gpurify lvs fingers.gds --deck example.deck --reference fingers_m4.spice
```

```text
violations: 0
lvs merges:
  layout parallel: 2 devices of nfet (0, 1) are one
lvs: Match
```

The fingers merge into 2 µm, and the card's `m=4` folds into the same 2 µm. Against a card stating `W=2u L=0.15u nf=3`:

```sh
gpurify lvs fingers.gds --deck example.deck --reference fingers_nf3.spice
```

```text
violations: 1
...
lvs merges:
  layout parallel: 2 devices of nfet (0, 1) are one
lvs: Mismatch([ParameterMismatch { layout_device: 0, ref_device: 0, param: "nf", layout_value: 2.0, ref_value: 3.0 }])
```

The merged device has two fingers against the card's three, a count that must agree exactly.

**Status and limits.** Implemented. No known limits.

**Sources.** KLayout LVS (<https://www.klayout.de/doc/about/lvs_ref_netter.html>); Netgen `property` (<http://opencircuitdesign.com/netgen/reference.html>); Magic `ext2spice`; BSIM4 `nf`.

## Logic gates and unused devices

### LVS-047: Logic-gate recognition

**What it catches.** A logic gate whose inputs are wired in another order than the schematic's: a NAND2 whose n-channel stack has `A` at the top in the layout and `B` at the top in the schematic. Logically the gate is the same, and a digital designer expects it to match. Without recognition the two stacks differ device by device.

**How GPurify measures it.** With `lvs recognize_gates`, once nothing else merges, transistors of one model with identical parameters become one device with interchangeable gates. They must be plain transistors, each on a gate net of its own, and either stacked in series or set in parallel. A stack runs through nets only its two neighbours touch, that are no port and carry no label. A parallel group sits on one source and drain pair. A NAND's or NOR's stack then matches in any input order.

![A NAND2's nfet stack with A over B in the layout and B over A in the reference; both reduce to one nfet whose gates A and B are interchangeable](../../diagrams/lvs-047.svg)

**In the deck.**

```text
lvs recognize_gates
```

```text
lvs ports_by_name
lvs recognize_gates
```

Added to [the example deck](README.md#the-example-deck), saved as `gates.deck`; the same deck without `lvs recognize_gates` is `ports.deck`. See [LVS controls](../deck/lvs-controls.md). Without `lvs ports_by_name`, LVS pairs nets by structure, pairs layout `A` with reference `B`, and the two orders match anyway.

**Example violation.** The layout is a NAND2 whose n-channel stack runs from `Y` through gate `A`, then gate `B`, to `VSS`. The reference stacks `B` above `A`:

```text
.subckt nand2 A B Y VDD VSS
M1 Y B n1 VSS nfet W=1u L=0.15u
M2 n1 A VSS VSS nfet W=1u L=0.15u
M3 Y A VDD VDD pfet W=1u L=0.15u
M4 Y B VDD VDD pfet W=1u L=0.15u
.ends
```

Without the line:

```sh
gpurify lvs nand2.gds --deck ports.deck --reference nand_swap.spice
```

```text
violations: 20
...
lvs: Mismatch([UnpairedDevice { side: Layout, device: 0, model: "nfet" }, UnpairedDevice { side: Layout, device: 1, model: "nfet" }, UnpairedDevice { side: Layout, device: 2, model: "pfet" }, UnpairedDevice { side: Layout, device: 3, model: "pfet" }, UnpairedNet { side: Layout, net: 0, name: Some("Y") }, UnpairedNet { side: Layout, net: 1, name: Some("A") }, UnpairedNet { side: Layout, net: 2, name: Some("B") }, UnpairedNet { side: Layout, net: 3, name: Some("VSS") }, UnpairedNet { side: Layout, net: 4, name: Some("VDD") }, UnpairedNet { side: Layout, net: 5, name: None }, UnpairedDevice { side: Reference, device: 0, model: "nfet" }, UnpairedDevice { side: Reference, device: 1, model: "nfet" }, UnpairedDevice { side: Reference, device: 2, model: "pfet" }, UnpairedDevice { side: Reference, device: 3, model: "pfet" }, UnpairedNet { side: Reference, net: 0, name: Some("A") }, UnpairedNet { side: Reference, net: 1, name: Some("B") }, UnpairedNet { side: Reference, net: 2, name: Some("Y") }, UnpairedNet { side: Reference, net: 3, name: Some("VDD") }, UnpairedNet { side: Reference, net: 4, name: Some("VSS") }, UnpairedNet { side: Reference, net: 5, name: Some("n1") }])
```

With `lvs recognize_gates`:

```sh
gpurify lvs nand2.gds --deck gates.deck --reference nand_swap.spice
```

```text
violations: 0
lvs merges:
  layout parallel: 2 devices of pfet (2, 3) are one
  layout series: 2 devices of nfet (0, 1) are one
  reference parallel: 2 devices of pfet (2, 3) are one
  reference series: 2 devices of nfet (0, 1) are one
lvs: Match
```

Each side's two n-channel transistors become one stack with interchangeable gates, and each side's two p-channel transistors one parallel group, so the input order no longer matters.

**Status and limits.** Partial. A device already merged from a gate is not merged again, so an AOI or OAI gate wired in another order still mismatches. Transistors of different sizes never merge. Calibre's `LVS RECOGNIZE GATES` with its `ALL`, `SIMPLE` and `NONE` options is named publicly but not defined, so GPurify follows Silvaco Guardian LVS's published series and parallel rules instead. It is off by default: in an analog circuit a stack's order is part of the design.

**Sources.** Silvaco Guardian LVS application note "Logic Gate Recognition in Guardian LVS" (2020); SubGemini (Ohlrich et al., DAC 1993); Siemens Calibre `LVS RECOGNIZE GATES`.

### LVS-048: Filter unused devices

**What it catches.** Transistors drawn in the layout that do nothing: dummies at the end of a row, tie-offs with a floating drain, devices with every pin on one net. The schematic leaves them out, so without filtering every such transistor is an extra device.

**How GPurify measures it.** With `lvs filter_unused`, each layout transistor an option matches leaves the comparison before reduction, with the nets only it reached. A pin floats when its net holds no other terminal and carries no label. Each transistor is judged once, as drawn, and the reference is never filtered. The `c` option reads the supply nets that `lvs supply` names by layout label.

![An inverter and a tie-off nfet, gate and source on VSS, drain floating; filter_unused c leaves it out and the inverter matches the reference](../../diagrams/lvs-048.svg)

**In the deck.**

```text
lvs filter_unused <option> ...
lvs supply "<net>" ...
```

```text
lvs filter_unused c
lvs supply "VSS"
```

Added to [the example deck](README.md#the-example-deck), saved as `filter_c.deck`; `filter_u.deck` adds `lvs filter_unused u` alone. See [LVS controls](../deck/lvs-controls.md).

**Example violation.** The layout draws an inverter and, beside it, an n-channel tie-off with its gate and source on `VSS` and its drain contacted to nothing. The reference is the inverter:

```text
.subckt inv A Y VDD VSS
M1 Y A VSS VSS nfet W=1u L=0.15u
M2 Y A VDD VDD pfet W=2u L=0.15u
.ends
```

With option `u`:

```sh
gpurify lvs dummy.gds --deck filter_u.deck --reference inv.spice
```

```text
violations: 14
...
lvs: Mismatch([UnpairedDevice { side: Layout, device: 0, model: "nfet" }, UnpairedDevice { side: Layout, device: 1, model: "nfet" }, UnpairedDevice { side: Layout, device: 2, model: "pfet" }, UnpairedNet { side: Layout, net: 0, name: Some("VSS") }, UnpairedNet { side: Layout, net: 1, name: Some("A") }, UnpairedNet { side: Layout, net: 2, name: Some("Y") }, UnpairedNet { side: Layout, net: 3, name: Some("VDD") }, UnpairedNet { side: Layout, net: 4, name: None }, UnpairedDevice { side: Reference, device: 0, model: "nfet" }, UnpairedDevice { side: Reference, device: 1, model: "pfet" }, UnpairedNet { side: Reference, net: 0, name: Some("A") }, UnpairedNet { side: Reference, net: 1, name: Some("Y") }, UnpairedNet { side: Reference, net: 2, name: Some("VDD") }, UnpairedNet { side: Reference, net: 3, name: Some("VSS") }])
```

Option `u` needs both source and drain floating, and the source is on `VSS`, so the tie-off stays. With option `c` and `VSS` named a supply:

```sh
gpurify lvs dummy.gds --deck filter_c.deck --reference inv.spice
```

```text
violations: 0
lvs: Match
```

The gate is on a supply and the drain floats, so the tie-off leaves the comparison and the inverter matches.

**Options.**

| Option | Value | Meaning |
|---|---|---|
| `ae` | None | Leaves out a transistor whose source, drain and gate all float. |
| `af` | None | Leaves out a transistor whose source and drain are on one net. |
| `ag` | None | Leaves out a transistor whose every pin, bulk included, is on one net. |
| `c` | None | Leaves out a transistor whose gate is on a supply net and whose source or drain floats. Needs at least one `lvs supply`. |
| `u` | None | Leaves out a transistor whose source and drain both float. |

**Status and limits.** Partial. Calibre's options `K`, `P` and `Q`, which follow paths to pads, are not available: no public source defines their path or pad. Nor are the options the public sources do not list. The report does not list the transistors left out; a match gives no trace of them.

**Sources.** Siemens Calibre `LVS FILTER UNUSED OPTION ... LAYOUT`, with its options as quoted in US 8,751,985 B1, column 7, lines 44 to 62 (<https://patents.google.com/patent/US8751985B1>); US 2010/0306720 A1, paragraph [0162] (<https://patents.google.com/patent/US20100306720A1>); Siemens Calibre `LVS POWER NAME` and `LVS GROUND NAME`; KLayout `purge_nets` (<https://www.klayout.de/doc/about/lvs_ref_netter.html>).

## Strict and relaxed topology

### LVS-049: Topology against property policy

**What it catches.** The choice between matching passives by structure and matching them by value. A schematic that writes one 1.5 kΩ resistor where the layout draws two 3 kΩ resistors in parallel is the same circuit electrically, but not structurally. A matching-critical resistor array must keep its count; a filter's resistor needs only its value.

**How GPurify measures it.** `lvs topology strict`, the default, never combines values: parallel passives keep their value and count `m`, and no passive merges in series. `lvs topology relaxed` combines a resistor, capacitor, diode or bipolar whose card states its value (`r`, `c`, `area`, `ae`). In parallel, resistances and inductances combine harmonically and the rest add. In series, resistors, capacitors and inductors combine by the opposite law, through a net only the two touch and that is no port. A card's `m` folds into its value first, and a device whose card states no value keeps its count.

![Two 3 kΩ rpoly resistors in parallel reduce under relaxed to one of 1.5 kΩ, matching the reference; under strict to one of 3 kΩ with m 2](../../diagrams/lvs-049.svg)

**In the deck.**

```text
lvs topology strict
lvs topology relaxed
```

```text
lvs topology relaxed
```

Added to [the example deck](README.md#the-example-deck), saved as `relaxed.deck`; `strict.deck` adds `lvs topology strict`. The topology is stated at most once. See [LVS controls](../deck/lvs-controls.md).

**Example violation.** The layout draws two 3 kΩ poly resistors in parallel between `A` and `B`. The reference writes one of 1.5 kΩ:

```text
.subckt rp A B
R1 A B rpoly r=1.5k
.ends
```

```sh
gpurify lvs res_pair.gds --deck strict.deck --reference res_1k5.spice
```

```text
violations: 2
...
lvs merges:
  layout parallel: 2 devices of rpoly (0, 1) are one
lvs: Mismatch([ParameterMismatch { layout_device: 0, ref_device: 0, param: "m", layout_value: 2.0, ref_value: 1.0 }, ParameterMismatch { layout_device: 0, ref_device: 0, param: "r", layout_value: 2999.9999999999995, ref_value: 1500.0 }])
```

Strict, the two resistors merge into one of 3 kΩ counted `m=2`, which differs from the card's 1.5 kΩ, counted 1. With `lvs topology relaxed`:

```sh
gpurify lvs res_pair.gds --deck relaxed.deck --reference res_1k5.spice
```

```text
violations: 0
lvs merges:
  layout parallel: 2 devices of rpoly (0, 1) are one
lvs: Match
```

The two 3 kΩ resistors combine into 1.5 kΩ. Strict, the same layout matches a card `R1 A B rpoly r=3k m=2` instead.

**Status and limits.** Implemented. No known limits.

**Sources.** Netgen `property` series and parallel combination (<http://opencircuitdesign.com/netgen/reference.html>); KLayout LVS device combination (<https://www.klayout.de/doc/about/lvs_ref_netter.html>).
