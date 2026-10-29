# Via and cut checks

These checks hold the cuts of a via or contact layer: how close cuts sit to each other on one layer
and across layers, how many cuts a via needs, which cut a wire width asks for, and how much cut area
a design change may lose. How GPurify measures a distance in general is on
[How distances are measured](../../explanation/measuring.md).

## Spacing between cuts

### DRC-060: Cut-to-cut spacing

**What it catches.** Two cuts on one layer that sit closer than the minimum space. Cuts closer than
the limit print as one opening or bridge in the etch, which shorts two vias or leaves a cut open.

**How GPurify measures it.** This is the ordinary one-layer `space` check applied to a cut layer.
Cuts that touch or overlap count as one shape. The gap is measured edge to edge, Euclidean at the
corners.

![Two 150 nm via cuts 140 nm apart, against a 170 nm minimum space; a third cut 560 nm away passes](../../diagrams/drc-060.svg)

**In the deck.**

```text
rule <id> space(<cut layer>) >= <length>
```

```text
grid 5nm
layer via = gds(68, 44)
rule via.2 space(via) >= 170nm
```

**Example violation.**

```text
rules:
  via.2: ran, examined 1 shapes, found 1 violations
violations: 1
  via.2 error layer via at (220 nm, 75 nm) measured 140 nm against limit 170 nm on shape 0 and shape 1
...
```

Two 150 nm vias 140 nm apart break the 170 nm limit. The point is midway across the gap.

**Status and limits.** Implemented. No known limits.

**Sources.** SkyWater SKY130 rules ct.2 and via.2
([periphery rules](https://skywater-pdk.readthedocs.io/en/main/rules/periphery.html)); IHP SG13G2
rules Cnt.b and V1.b; GlobalFoundries GF180MCU rule CO.2a; ASAP7 rule V1.S.1; LEF/DEF 5.8 cut-layer
`SPACING`; the OpenROAD detailed router's cut spacing check.

### DRC-061: Centre-to-centre cut spacing

**What it catches.** Two cuts whose centres are closer than a minimum pitch. Some processes state
cut spacing between centres rather than between edges, as LEF's `CENTERTOCENTER` does.

**How GPurify measures it.** GPurify takes each cut as drawn, without merging, and uses the middle
of its bounding box as its centre. It measures the straight distance between two centres. Two
overlapping cuts are still two cuts and are measured. The marker sits midway between the centres.

![Two 150 nm via1 cuts with centres 280 nm apart, against a 300 nm centre-to-centre minimum](../../diagrams/drc-061.svg)

**In the deck.**

```text
rule <id> space(<cut layer>, center) >= <length>
```

```text
grid 5nm
layer via1 = gds(68, 44)
rule V1.CC space(via1, center) >= 300nm
```

**Example violation.**

```text
rules:
  V1.CC: ran, examined 3 shapes, found 1 violations
violations: 1
  V1.CC error layer via1 at (215 nm, 75 nm) measured 280 nm against limit 300 nm on shape 0 and shape 1
...
```

Two cuts whose centres are 280 nm apart break the 300 nm limit. The point is midway between the
centres.

**Status and limits.** Implemented. The `CENTERTOCENTER` cells of a `LEF58_SPACINGTABLE` cut-class
table are part of [DRC-063](#drc-063-cut-class-spacing-tables), where they are not yet checked.

**Sources.** LEF/DEF 5.8 cut-layer `SPACING ... CENTERTOCENTER`; `LEF58_SPACINGTABLE ...
CENTERTOCENTER`.

### DRC-062: Array and adjacent-cut spacing

**What it catches.** Cuts in a crowded group that need more space than a lone pair. A large via
array, or a cut with many close neighbours, etches differently and needs a wider gap. Foundries
state this as array spacing (IHP Cnt.b1, GF180MCU CO.2b) or as LEF `ADJACENTCUTS`.

**How GPurify measures it.** Both forms take cuts as drawn, without merging.

- `via_array_space` groups cuts into clusters: two cuts belong together when they are at most the
  limit apart, edge to edge. In a cluster of more than `array` cuts, every pair closer than the limit
  is a violation.
- `adjacent_space` counts, for each cut, the other cuts strictly closer than `within`. A pair closer
  than the limit is a violation when either cut has at least `cuts` such neighbours. Distances are
  edge to edge, or centre to centre with `center`.

![A 2 by 2 via1 array that passes and a 2 by 3 array whose middle cuts have three neighbours and break a 120 nm space](../../diagrams/drc-062.svg)

**In the deck.**

```text
rule <id> via_array_space(<cut layer>; array: <count>) >= <length>
rule <id> adjacent_space(<cut layer>; cuts: <count>, within: <length>) >= <length>
rule <id> adjacent_space(<cut layer>, center; cuts: <count>, within: <length>) >= <length>
```

```text
grid 5nm
layer contact = gds(33, 0)
layer via1 = gds(35, 0)
rule CO.2b via_array_space(contact; array: 15) >= 280nm
rule V1.ADJ adjacent_space(via1; cuts: 3, within: 120nm) >= 120nm
```

**Example violation.**

```text
rules:
  CO.2b: ran, examined 42 shapes, found 24 violations
  V1.ADJ: ran, examined 2 shapes, found 5 violations
violations: 29
  CO.2b error layer contact at (345 nm, 110 nm) measured 250 nm against limit 280 nm on shape 0 and shape 4
...
  V1.ADJ error layer via1 at (2200 nm, 4075 nm) measured 100 nm against limit 120 nm on shape 35 and shape 37
...
```

A 4 by 4 array of 220 nm contacts 250 nm apart is a cluster of 16, more than 15, so each of its 24
neighbouring pairs breaks the 280 nm limit; a 3 by 5 array of 15 passes. In a 2 by 3 via1 array 100 nm
apart, the two middle cuts have three neighbours closer than 120 nm, so their five pairs break the
120 nm limit; a 2 by 2 array passes.

**Options.**

| Parameter | Value | Meaning |
|---|---|---|
| `array` | count | A cluster with more cuts than this is an array. |
| `cuts` | count | How many neighbours a cut needs before its pairs are held. |
| `within` | length | How close, strictly, a neighbour must be to count. |
| `center` | word | Measure every distance between centres, not edges. |

**Status and limits.** Implemented. An array is a cluster of more than `array` cuts, not a count of
rows and columns. A single long row of cuts is held too, which is stricter than "more than 4 rows
and 4 columns". `ADJACENTCUTS ... EXCEPTSAMEPGNET` is not modelled: cuts on the same power or ground
net are held like any others.

**Sources.** IHP SG13G2 rules Cnt.b1 and V1.b1; GlobalFoundries GF180MCU rule CO.2b; LEF/DEF 5.8
`SPACING ... ADJACENTCUTS` and `ARRAYSPACING`; `LEF58_ARRAYSPACING`; the ISPD 2019 initial detailed
routing contest.

### DRC-063: Cut-class spacing tables

**What it catches.** Two cuts closer than the space their classes need. On a layer with several
cut sizes, a slot next to a slot, a slot next to a square and two squares each need their own
space, and the end of a slot can differ from its side. LEF58 `SPACINGTABLE` with `CUTCLASS` states
this as a table.

**How GPurify measures it.** Each class is a cut size, `short` by `long`, either way round. A cut
of no class is not checked by this rule. The table has two rows and two columns per class: its END,
then its SIDE. A cut uses its SIDE when its long side faces the other cut, and its END otherwise; a
square cut always uses its END. GPurify picks the cell for the two facing sides and measures edge to
edge, taking cuts as drawn.

- Apart along both axes, a pair needs the larger of its two cells.
- Touching or overlapping, it needs the largest cell of its two classes.

![A 170 nm square licon 400 nm from the side of a slotted licon, against 510 nm; two slots 400 nm apart end to end pass 350 nm](../../diagrams/drc-063.svg)

**In the deck.**

```text
rule <id> cut_class_space(<cut layer>;
    short: [<length>, ..], long: [<length>, ..],
    space: [[<length>, ..], ..])
```

```text
grid 5nm
layer licon = gds(66, 44)
rule licon.2 cut_class_space(licon;
    short: [170nm, 190nm],
    long:  [170nm, 2000nm],
    space: [[170nm, 170nm, 510nm, 510nm],
            [170nm, 170nm, 510nm, 510nm],
            [510nm, 510nm, 350nm, 510nm],
            [510nm, 510nm, 510nm, 510nm]])
```

The rows and columns are, in order: square END, square SIDE, slot END, slot SIDE.

**Example violation.**

```text
rules:
  licon.2: ran, examined 3 shapes, found 1 violations
violations: 1
  licon.2 error layer licon at (370 nm, 85 nm) measured 400 nm against limit 510 nm on shape 0 and shape 1
...
```

A square licon 400 nm from the long side of a 0.19 µm by 2 µm slot breaks the 510 nm limit. Two slots
400 nm apart end to end pass their 350 nm cell.

**Options.**

| Parameter | Value | Meaning |
|---|---|---|
| `short` | list of lengths | Each class's shorter side. |
| `long` | list of lengths | Each class's longer side, in the same order. |
| `space` | rows of lengths | The table: two rows and two columns per class, END then SIDE. It must be symmetric, every cell above 0. |

**Status and limits.** Partial. Only the class-pair SIDE and END cells are checked. The table's
second parallel-run value, `CENTERTOCENTER` and `CENTERANDEDGE` cells, `SAMENET` and `SAMEMETAL`
tables, `LAYER` tables between two cut layers, `EXACTALIGNEDSPACING` and LEF `SPACINGTABLE
ORTHOGONAL` are not checked. See [issue 6, cut-class spacing tables](https://github.com/OpenFAT/GPurify/issues/6).

**Sources.** `LEF58_SPACINGTABLE` with `CUTCLASS`; LEF/DEF 5.8 `SPACINGTABLE ORTHOGONAL`; SkyWater
SKY130 rules licon.2 to licon.2d; the OpenROAD detailed router's cut-class spacing check.

### DRC-064: Slotted and bar cut spacing

**What it catches.** Spacing rules for long cuts (slots or bars) that depend on which edges face
each other. A bar's long side next to another bar needs more room than two square contacts, and
more still where the two run alongside each other for a long way.

**How GPurify measures it.** There is no separate kind for bars. Write them with the general
checks. When the bars have fixed sizes, a cut-class table holds them
([DRC-063](#drc-063-cut-class-spacing-tables)). When a bar can have any length, select the bars as
the cuts that are not square, then use `space`, `prl_space` and two-layer `space` on that derived
layer.

![Two bars 290 nm apart along a 2 µm run, against 300 nm, and a square contact 200 nm from a bar, against 260 nm](../../diagrams/drc-064.svg)

**In the deck.**

```text
layer <bars> = <cut layer>.non_squares()
layer <squares> = <cut layer>.squares()
rule <id> space(<bars>) >= <length>
rule <id> prl_space(<bars>; prl: <length>) >= <length>
rule <id> space(<bars>, <squares>) >= <length>
```

```text
grid 5nm
layer cont = gds(6, 0)
layer bar = cont.non_squares()
layer square = cont.squares()
rule bar.space space(bar) >= 280nm
rule bar.run prl_space(bar; prl: 1um) >= 300nm
rule bar.square space(bar, square) >= 260nm
```

**Example violation.**

```text
rules:
  bar.space: ran, examined 0 shapes, found 0 violations
  bar.run: ran, examined 1 shapes, found 1 violations
  bar.square: ran, examined 1 shapes, found 1 violations
violations: 2
  bar.run error layer bar at (305 nm, 1000 nm) measured 290 nm against limit 300 nm on shape 5 and shape 6
  bar.square error layer bar at (710 nm, 980 nm) measured 200 nm against limit 260 nm on shape 6 and shape 9
...
```

Two 2 µm bars 290 nm apart break the 300 nm limit for a run over 1 µm. A square contact 200 nm from a
bar breaks the 260 nm limit. Two short bars 290 nm apart pass, since their 400 nm run is under 1 µm.

**Status and limits.** Implemented. The values in the example are illustrative; take yours from the
foundry manual.

**Sources.** SkyWater SKY130 rules licon.2b to licon.2d; IHP SG13G2 layout rules 5.15 (ContBar,
CntB rules), where any contact that is not square is a bar.

## Vias across layers

### DRC-065: Via stacking and cross-layer cut spacing

**What it catches.** Cuts on different layers that interfere. A stack of vias directly on top of each
other can be too tall to manufacture reliably (LEF `MAXVIASTACK`). Cuts on two adjacent cut layers that
nearly, but not exactly, line up need a minimum space (LEF `SPACING ... LAYER ... STACK`).

**How GPurify measures it.**

- `via_stack` lists cut layers bottom to top. A cut stacks on a cut of the layer before it that it
  overlaps. GPurify finds the tallest chain through each cut and reports the cut at height
  `count + 1` of each chain that is too tall, with the chain's height. With the metals named between
  the cuts and `single`, only single-cut vias stack: a via of two or more cuts joining the same two
  metal shapes interrupts the stack, as LEF states.
- `stack_space` measures a cut on `A` against a cut on `B`, edge to edge, overlap counting as 0. A
  pair on one net where one cut's box covers the other's is a legal stack and is not measured. Two
  equal boxes must be aligned. A cut takes the net of the shape of `M` it lands on, so the deck needs
  its `connect` lines. With `same_net: true`, only same-net pairs are held (LEF `SAMENET`).
- Cross-layer cut spacing without the stack exception is the ordinary two-layer `space(A, B)`.

![Cross-section: via1, via2 and via3 stacked three high against a limit of 2; a via2 cut 50 nm beside a via1 cut on one net, against 200 nm](../../diagrams/drc-065.svg)

**In the deck.**

```text
rule <id> via_stack(<cut 1>, <cut 2>, ..) <= <count>
rule <id> via_stack(<metal 1>, <cut 1>, <metal 2>, <cut 2>, .., <metal N>, single) <= <count>
rule <id> stack_space(<cut A>, <cut B>, <metal between>) >= <length>
rule <id> stack_space(<cut A>, <cut B>, <metal between>; same_net: <bool>) >= <length>
rule <id> space(<cut A>, <cut B>) >= <length>
```

```text
grid 5nm
layer met1 = gds(34, 0)
layer via1 = gds(35, 0)
layer met2 = gds(36, 0)
layer via2 = gds(38, 0)
layer met3 = gds(42, 0)
layer via3 = gds(40, 0)
layer met4 = gds(46, 0)
connect conductors [met1, met2, met3, met4]
connect via via1 [met1, met2]
connect via via2 [met2, met3]
connect via via3 [met3, met4]
rule V.stack via_stack(via1, via2, via3) <= 2
rule V2.stack stack_space(via2, via1, met2) >= 200nm
```

**Example violation.**

```text
rules:
  V.stack: ran, examined 5 shapes, found 1 violations
  V2.stack: ran, examined 2 shapes, found 1 violations
violations: 2
  V.stack error layer via3 at (200 nm, 200 nm) measured 3 against limit 2 on shape 11
  V2.stack error layer via2 at (2325 nm, 200 nm) measured 50 nm against limit 200 nm on shape 10 and shape 8
...
```

Three stacked cuts reach a height of 3 against a limit of 2; the via3 cut on top is reported. A via2
cut 50 nm beside the via1 cut below it, on the same net but not covering it, breaks the 200 nm limit.

**Options.**

| Parameter | Value | Meaning |
|---|---|---|
| `single` | word | Count single-cut vias only; the metals are named between the cuts. |
| `same_net` | `true` or `false` | With `true`, hold only pairs on the same net. |

**Status and limits.** Implemented. `via_stack` without `single` counts every cut as a single-cut via.

**Sources.** LEF/DEF 5.8 `MAXVIASTACK` and cut-layer `SPACING ... LAYER ... STACK`; GlobalFoundries
GF180MCU rules Vn.5 and CUP.5.

### DRC-066: Minimum cut count and redundant vias

**What it catches.** A via with too few cuts. A via onto a wide wire needs several cuts, since one
cut carries too little current and fails open more often (LEF `MINIMUMCUT`). A recommended rule can
ask for a second cut near every cut, for yield.

**How GPurify measures it.**

- `min_cuts` treats a via as the cuts that join one shape of the wide metal to one shape of the
  metal on the far side (`other`). A via is held when one of its cuts lies on a part of the wide
  metal wider than `width`, where a square that wide fits. A held via with fewer than `count` cuts
  reports each of its cuts. With `within`, only cuts closer than that to each other count together.
- With `length` and `distance`, the rule holds the vias on a thin wire that joins a wide wire
  instead. The wide wire's region must be longer than `length`, and the via closer than `distance`
  to it. The wide wire's own vias are not held (LEF `MINIMUMCUT ... LENGTH ... WITHIN`).
- `redundant_via` counts, for each cut, the cuts at most `within` from it, edge to edge, itself
  included. It reads only the cut layer, not the metals.

![A single via1 cut on a 1.2 µm wide met2 plate, against a minimum of 2 cuts; a two-cut via passes](../../diagrams/drc-066.svg)

**In the deck.**

```text
rule <id> min_cuts(<cut>, <wide metal>, <other metal>; width: <length>) >= <count>
rule <id> min_cuts(<cut>, <wide metal>, <other metal>; width: <length>, within: <length>) >= <count>
rule <id> min_cuts(<cut>, <wide metal>, <other metal>; width: <length>, length: <length>, distance: <length>) >= <count>
rule <id> redundant_via(<cut>; within: <length>) >= <count>
```

```text
grid 5nm
layer met1 = gds(34, 0)
layer via1 = gds(35, 0)
layer met2 = gds(36, 0)
rule M2.MINCUT min_cuts(via1, met2, met1; width: 1um) >= 2
rule V1.RED warning redundant_via(via1; within: 300nm) >= 2
```

`other` decides the direction: `min_cuts(via1, met2, met1; ..)` is LEF's `FROMBELOW` on met2. Write
the rule twice, once with each neighbouring metal, for LEF's default of both directions.

**Example violation.**

```text
rules:
  M2.MINCUT: ran, examined 2 shapes, found 1 violations
  V1.RED: ran, examined 3 shapes, found 1 violations
violations: 2
  M2.MINCUT error layer via1 at (600 nm, 600 nm) measured 1 against limit 2 on shape 3
  V1.RED warning layer via1 at (600 nm, 600 nm) measured 1 against limit 2 on shape 3
...
```

A single cut joins met1 to a 1.2 µm wide met2 plate, where two cuts are required. The same cut has no
second cut within 300 nm, which the recommended rule reports as a warning. A two-cut via beside it
passes both.

**Options.**

| Parameter | Value | Meaning |
|---|---|---|
| `width` | length | The wire is wide where it is wider than this. |
| `within` | length | Only cuts closer than this to each other count as one via (`min_cuts`); the reach for counting neighbours (`redundant_via`). |
| `length` | length | A wide wire's region must be longer than this to hold the thin wires beside it. |
| `distance` | length | How close to the wide wire a thin wire's via must be to be held. |

**Status and limits.** Partial. `LEF58_MINIMUMCUT`'s `CUTCLASS` is this rule written on a layer of
that class's cuts. `LEF58_MINIMUMCUT`'s `AREA`, `SAMEMETALOVERLAP` and `FULLYENCLOSED` forms are not
checked: no public text defines them.

**Sources.** LEF/DEF 5.8 `MINIMUMCUT` (Example 1-14, Figure 1-11); `LEF58_MINIMUMCUT`;
GlobalFoundries GF180MCU rule MT30.8a; SkyWater SKY130 rule x.18; the OpenROAD detailed router's
minimum-cut check.

### DRC-067: Metal-width-dependent via choice

**What it catches.** A via whose cut is not the one the process asks for at those wire widths. Some
processes map each pair of wire widths to a via, so a wide wire takes a larger cut. LEF states this
with `LEF58_METALWIDTHVIAMAP`.

**How GPurify measures it.** Each `via_map` rule is one entry of the map. A cut is held when it lies
on a part of the lower metal whose width is from `below_min` to `below_max`, both included, and on a
part of the upper metal from `above_min` to `above_max`. A wire's width is read as an enclosure
rule's `width:` band reads it: by the largest square that fits around the cut. A held cut must be a
`w` by `h` box, either way round. A violation reports `measured 0 against limit 1`: the cut matches
0 of the 1 size the entry allows.

![A 120 nm via1 cut where a 160 nm met1 wire crosses a 160 nm met2 wire; the map asks for a 100 nm cut](../../diagrams/drc-067.svg)

**In the deck.**

```text
rule <id> via_map(<cut>, <lower metal>, <upper metal>;
    below_min: <length>, below_max: <length>, above_min: <length>, above_max: <length>,
    cut: <length> x <length>)
```

```text
grid 5nm
layer met1 = gds(34, 0)
layer via1 = gds(35, 0)
layer met2 = gds(36, 0)
rule V1.MAP via_map(via1, met1, met2;
    below_min: 100nm, below_max: 200nm, above_min: 100nm, above_max: 200nm,
    cut: 100nm x 100nm)
```

**Example violation.**

```text
rules:
  V1.MAP: ran, examined 2 shapes, found 1 violations
violations: 1
  V1.MAP error layer via1 at (80 nm, 80 nm) measured 0 against limit 1 on shape 6
...
```

A 120 nm cut between two 160 nm wires is not the 100 nm cut the map gives for that pair of widths. A
correct 100 nm cut on the same widths passes, and a cut between 400 nm wires is not held by this entry.

**Options.**

| Parameter | Value | Meaning |
|---|---|---|
| `below_min`, `below_max` | length | The lower metal's width band, both ends included. |
| `above_min`, `above_max` | length | The upper metal's width band, both ends included. |
| `cut` | length `x` length | The cut size the entry asks for, either way round. |

**Status and limits.** Implemented. No public LEF text defines the property; GPurify follows how the
OpenROAD router reads and checks it. The router compares the upper metal for both wires and reads
widths on maximal rectangles; GPurify reads each wire's own width. `PGVIA` and `USEVIACUTCLASS` are
not read, as the router does not read them.

**Sources.** `LEF58_METALWIDTHVIAMAP`, as the OpenROAD detailed router reads it.

## Comparing two databases

### DRC-068: Cut-area conservation between two databases

**What it catches.** Cut area lost or gained between two versions of a design, such as the
aluminium and the slotted copper databases of one product. A via that loses cuts carries its
current through less area, which raises IR drop. SkyWater's `ct.irdrop` and `via.irdrop` rules hold
that change to a tolerance by the via's cut count.

**How GPurify measures it.**

- `gpurify xor` compares two layouts layer by layer, as KLayout's `xor` does. Each region where
  exactly one layout has material is a violation of the rule `xor.<layer>`, measured by its area.
  On a cut layer, the areas add up to the cut area one layout gained or lost.
- `cut_area_change` reads both databases' cuts as two layers of one layout. A connector is a shape
  on `lower` and a shape on `upper` that overlap. Its cuts are the `pre` cuts on that overlap. Its
  change is the difference between the `pre` and the `post` cut area there, either way. The last band
  whose `cuts` the connector reaches allows that band's `change`. Below the first band nothing is
  judged.

![One connector with two 170 nm cuts before and one after: 0.0289 µm² lost, against 0.02 µm² allowed for 2 cuts](../../diagrams/drc-068.svg)

**In the deck.**

```text
rule <id> cut_area_change(<pre cuts>, <post cuts>, <lower metal>, <upper metal>;
    cuts: [<count>, ..], change: [<area>, ..])
```

```text
grid 5nm
layer li = gds(67, 20)
layer met1 = gds(68, 20)
layer mcon_pre = gds(67, 44)
layer mcon_post = gds(67, 45)
rule ct.irdrop cut_area_change(mcon_pre, mcon_post, li, met1;
    cuts: [1, 2, 4], change: [0um2, 0.02um2, 0.05um2])
```

To compare two layout files instead, run `xor` with a deck that declares the layers:

```text
grid 5nm
layer licon = gds(66, 44)
layer li = gds(67, 20)
layer mcon = gds(67, 44)
layer met1 = gds(68, 20)
```

```sh
gpurify xor pre.gds post.gds --deck compare.deck
```

**Example violation.**

```text
rules:
  ct.irdrop: ran, examined 1 shapes, found 1 violations
violations: 1
  ct.irdrop error layer mcon_pre at (500 nm, 500 nm) measured 28900 nm^2 against limit 20000 nm^2
...
```

A connector with two 170 nm cuts lost one of them, 28 900 nm² of cut area, against the 0.02 µm² its
two-cut band allows. The point is the centre of the connector. The same two databases as two files,
`pre.gds` with both cuts and `post.gds` with one, give one `xor` region:

```text
rules:
  xor.li: ran, examined 2 shapes, found 0 violations
  xor.licon: ran, examined 0 shapes, found 0 violations
  xor.mcon: ran, examined 3 shapes, found 1 violations
  xor.met1: ran, examined 2 shapes, found 0 violations
violations: 1
  xor.mcon error layer mcon at (500 nm, 270 nm) measured 28900 nm^2 against limit 0 nm^2
...
```

The lost mcon cut is 28 900 nm² that only `pre.gds` has, against a limit of 0. The point is a corner
of that region.

**Options.**

| Parameter | Value | Meaning |
|---|---|---|
| `cuts` | list of counts | The band edges by cut count, rising strictly from at least 1. |
| `change` | list of areas | The cut-area change each band allows, 0 or more. |

**Status and limits.** Implemented. The connector and the tolerances are yours to state: no public
source defines a connector, and the manual's unit for the change is unsettled. The shipped sky130
deck leaves the rule out. `xor` compares drawn layers only, not derived layers or text labels, and
refuses a layer with a 45° edge. Both layouts must be on the same grid.

**Sources.** SkyWater SKY130 rules ct.irdrop.1 to ct.irdrop.3 and via.irdrop.1 to via4.irdrop.4
([periphery rules](https://skywater-pdk.readthedocs.io/en/main/rules/periphery.html)); KLayout's
`xor` ([DRC reference](https://www.klayout.de/doc/about/drc_ref_layer.html)).

## Keep-out zones

### DRC-126: Cut keep-out zone by cut class

**What it catches.** Another cut inside the keep-out zone round a cut of a given class. Advanced
nodes reserve room beside the sides and past the ends of an oblong cut, so lithography can print
it. LEF states this as `LEF58_KEEPOUTZONE`.

**How GPurify measures it.** GPurify builds two zones round each cut of `class`, an oblong
`short` by `long` size either way round.

- The side zone is the cut lengthened by `side_forward` at both ends and widened by `side_side` on
  both sides.
- The end zone is the cut lengthened by `end_side` at both ends and widened by `end_forward`.

Any other cut overlapping either zone with some area is a violation; touching a zone is not inside
it. With `to`, only cuts of that size count. The violation measures the other cut's area inside the
two zones together.

![A 200 by 100 nm via1 cut with its side and end zones; another cut 40 nm above it has 4000 nm² inside the zones](../../diagrams/drc-126.svg)

**In the deck.**

```text
rule <id> keep_out_zone(<cut layer>; class: <length> x <length>, to: <length> x <length> | none,
    end_side: <length>, end_forward: <length>, side_side: <length>, side_forward: <length>)
```

```text
grid 5nm
layer via1 = gds(35, 0)
rule V1.KOZ keep_out_zone(via1; class: 100nm x 200nm, to: none,
    end_side: 50nm, end_forward: 80nm, side_side: 60nm, side_forward: 40nm)
```

**Example violation.**

```text
rules:
  V1.KOZ: ran, examined 2 shapes, found 2 violations
violations: 2
  V1.KOZ error layer via1 at (50 nm, 160 nm) measured 4000 nm^2 against limit 0 nm^2 on shape 0 and shape 1
...
```

A 100 nm square cut 40 nm above a 200 nm by 100 nm cut reaches 40 nm into the end zone, 4000 nm² of
it. The point is the centre of the part inside.

**Options.**

| Parameter | Value | Meaning |
|---|---|---|
| `class` | length `x` length | The cut size the zones are built round. It must be oblong; a square class is refused. |
| `to` | length `x` length, or `none` | Count only other cuts of this size; `none` counts every cut. |
| `end_side` | length | How far the end zone reaches past each end. |
| `end_forward` | length | How far the end zone reaches past each long side. |
| `side_side` | length | How far the side zone reaches past each long side. |
| `side_forward` | length | How far the side zone reaches past each end. |

**Status and limits.** Partial. The `EXTENSION` form without `ENDEXTENSION`, `SPIRALEXTENSION` and
`EXCEPTEXACTALIGNED` are not checked: the OpenROAD router reads them but never checks them, and no
public text defines them. A square class is refused, since the router skips square vias.

**Sources.** `LEF58_KEEPOUTZONE`, as the OpenROAD detailed router checks it
([OpenROAD](https://github.com/The-OpenROAD-Project/OpenROAD)).
