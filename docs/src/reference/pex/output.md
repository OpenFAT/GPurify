# PEX output formats

GPurify writes the extracted network as SPEF for a timing tool, as DSPF, or as a simulator-ready
SPICE subcircuit, and compares two SPEF or DSPF files from any tools. This page covers what each
format holds, how the deck's extraction type thins it, routed DEF designs, and the point-to-point
reports.

## Choosing what is written

### PEX-008: Reduction modes

**What it catches.** Which parasitics reach the output. A full RC network with coupling is the
most accurate, but a timing or simulation run on a large block slows down with every element. An
`rc` or `c` netlist is smaller, and a coupling threshold drops couplings too small to matter.

**How GPurify measures it.** The extraction type picks the elements written. To ground a coupling
is to put its capacitance from each of its two nets to ground, so every net keeps its total
capacitance. `coupling_threshold` grounds every coupling below it. A field-solved net's inductance
stays wherever its resistance does.

| Type | Writes |
|---|---|
| `rcc` | Resistance, capacitance to ground and coupling capacitance |
| `rc` | Resistance and capacitance to ground, every coupling grounded |
| `cc` | Capacitance only, one node per net, with the coupling between nets |
| `c` | Capacitance to ground only, one node per net, every coupling grounded |
| `r` | Resistance only, no capacitance |

![Nets a and b extracted with rcc, a 1.025 fF coupling capacitor between them, and with rc, the same 1.025 fF to ground on each net](../../diagrams/pex-008.svg)

**In the deck.**

```text
extraction r|c|cc|rc|rcc [coupling_threshold <capacitance>] [coupling_halo <thicknesses>]
```

```text
grid 5nm
layer met1 = gds(68, 20)
layer via = gds(68, 44)
layer met2 = gds(69, 20)
connect conductors [met1, met2]
connect via via [met1, met2]
connect label met1 names met1
connect label met2 names met2
pex met1 thickness 360nm height 1376.1nm sheet 0.125ohm dielectric 4.5 area_cap 25.78aF/um2 fringe_cap 40.57aF/um
pex via thickness 270nm height 1736.1nm sheet 4.5ohm dielectric 4.5 area_cap 0aF/um2 fringe_cap 0aF/um
pex met2 thickness 360nm height 2006.1nm sheet 0.125ohm dielectric 4.2 area_cap 17.5aF/um2 fringe_cap 37.76aF/um
extraction rcc coupling_halo 10 coupling_threshold 0.01fF
```

**Example output.** Nets `a` and `b` are met1 wires 10 µm × 0.14 µm, 0.14 µm apart. Net `c` is a
met2 wire that crosses both:

```sh
gpurify pex cross.gds --deck threshold.deck --format spice > cross.sp
```

```text
.subckt cross a b c
C1 a 0 0.006198f
C2 a 0 0.858852f
R1 a a#1 8.928571
C3 a b 1.024556f
...
C6 c 0 0.006198f
C7 c 0 0.006198f
C8 c 0 0.264966f
R3 c c#1 1.250000
.ends cross
```

The 6.198 aF couplings between `c` and each met1 wire are under the 0.01 fF threshold, so each
appears twice as a capacitor to ground, once on each of its nets. The 1.024556 fF coupling between
`a` and `b` stays. With `extraction cc coupling_halo 10`, the same layout gives
`C1 a 0 0.858852f` and `C2 a b 1.024556f` and no `R` card.

**Options.**

| Parameter | Value | Meaning |
|---|---|---|
| `coupling_threshold` | capacitance | A coupling below this is grounded on both its nets. Zero or more, and allowed only with `cc` and `rcc`. |
| `coupling_halo` | number | How far lateral coupling is looked for, in thicknesses of each layer. Required for every type but `r`, and refused with `r`. |

**Status and limits.** Implemented. Without an `extraction` line, or without `coupling_halo` on
it, GPurify refuses the run, because no lateral reach suits every process:

```text
  pex: refused, the deck states no `coupling_halo` on its `extraction` line, so no lateral coupling reach is the deck's
```

Not offered: merging series resistors, a threshold relative to a net's total capacitance, an
R-only network reduction, extraction of selected nets only, and regions excluded from extraction
by a marker layer.

**Sources.** The extraction types are those of Siemens Calibre xACT (`PEX EXTRACT`). The
threshold follows OpenROAD's `extract_parasitics -coupling_threshold`.

## Comparing two extractions

### PEX-009: PEX netlist diff and qualification

**What it catches.** Differences between two parasitic netlists of the same layout: two
extractors, two deck versions, or closed forms against a field solve. Qualifying a deck against a
reference extractor, or catching a regression after a deck change, needs a net-by-net comparison
with a pass or fail.

**How GPurify measures it.** `gpurify compare` reads two SPEF or DSPF files from any tools and
links their nets by name. It compares each net's total capacitance, capacitance to ground,
pin-to-pin resistance from the driver and Elmore delay, and each pair of nets' coupling. Each
metric row reports the worst, mean and RMS percentage difference and how many rows are within the
tolerance. A coupling listed under both nets counts once. Rows under 0.01 (fF, Ω or fs) in both
files are not compared.

![Net a in two files: 0.542 fF to ground and 1.543 fF to b in the reference, 0.859 fF and 1.025 fF in the candidate, with the percentage differences](../../diagrams/pex-009.svg)

**In the deck.** Nothing to write in the deck. Give the reference first, then the candidate, and
optionally a JSON spec with the tolerance in percent (5% without one):

```sh
gpurify compare <reference> <candidate> [--spec <compare.json>]
```

```json
{"tolerance": 5}
```

**Example output.** The reference field-solves nets `a` and `b` of the layout in PEX-008, and the
candidate uses the closed forms:

```sh
gpurify pex cross.gds --deck wires.deck --quasistatic a --quasistatic b --format spef > field.spef
gpurify pex cross.gds --deck wires.deck --format spef > closed.spef
gpurify compare field.spef closed.spef
```

```text
reference field.spef
candidate closed.spef
nets: 3 in both, 0 in the reference only, 0 in the candidate only
tolerance 5%, rows under 0.01 in both not compared
metric            unit  rows  within  worst%      mean%     rms%      worst row
total_cap         fF       3       1     -9.637     6.425     7.869  a
ground_cap        fF       3       1    +58.353    38.902    47.645  a
pin_to_pin_res    ohm      3       3     +0.000     0.000     0.000  a
elmore_delay      fs       0       0     +0.000     0.000     0.000  -
coupling_cap      fF       1       0    -33.581    33.581    33.581  a/b
fail
```

The closed forms put 58% more of net `a`'s capacitance to ground and 34% less on its coupling to
`b` than the field solve, so the comparison fails and exits with status 1. It exits 0 only when
every row is within the tolerance and both files hold the same nets. The Elmore delay row is empty
because each wire here is one region, whose capacitance sits on its first node, so no net has a
delay above 0.01 fs.

**Options.**

| Parameter | Value | Meaning |
|---|---|---|
| `tolerance` | percent | The largest difference a row may have and still pass. Default 5. |

**Status and limits.** Implemented. Reduced nets (`*R_NET`) and physical nets (`*D_PNET`) are
refused. Nets are linked by name only, through the SPEF name map when there is one.

**Sources.** The metrics and the net linking follow Silvaco PEX Certify: total and ground
capacitance, net-to-net capacitance, pin-to-pin resistance and delay.

## SPEF and DSPF

### PEX-010: SPEF output

**What it catches.** The extracted network in the format a timing tool reads. Static timing
analysis with SPEF sees each net's wire delay and crosstalk, which a schematic-level run cannot.

**How GPurify measures it.** GPurify writes IEEE 1481 SPEF: a header, then one `*D_NET` per net
with its total capacitance, coupling included. Each net has one bidirectional `*P` port, named by
its label. The node the label sits on is the port itself, written with the bare net name; every
other node is `<net>:<index>`. A coupling capacitance is listed under both nets, each with its own
node first. Resistances are in ohms, capacitances in femtofarads, and inductances in `0.000001 UH`
units, which are picohenries.

![Net a, a met1 wire up a via to met2, beside net b, and its SPEF network: port a, nodes a:1 to a:3, ground capacitors on a and a:2, and 0.820 fF to b](../../diagrams/pex-010.svg)

`--format dspf` writes the same network as DSPF 1.4: one `*|NET` per net, then every element as a
SPICE card with `f` and `p` suffixes and ground net `0`. A subnode line (`*|S`) carries the deck
layer, as `L<layer number>`, in place of a position. DSPF has no process corners, so it holds the
nominal values.

**In the deck.** Nothing to write beyond the parasitic stack and the `extraction` line (see
[Resistance extraction](resistance.md#pex-001-sheet-and-via-resistance)). Run with `--format spef`
or `--format dspf`.

**Example output.** Net `a` is a met1 wire 10 µm × 0.14 µm with a landing pad, one via cut, and a
met2 wire. Net `b` is a met1 wire 8 µm long, 0.14 µm beside it:

```sh
gpurify pex pair.gds --deck wires.deck --format spef > pair.spef
```

```text
*SPEF "IEEE 1481-1998"
*DESIGN "pair.gds"
...
*T_UNIT 1 NS
*C_UNIT 1 FF
*R_UNIT 1 OHM
*L_UNIT 0.000001 UH

*D_NET a 1.964144
*CONN
*P a B
*CAP
1 a 0.873071
2 a b 0.819645
3 a:2 0.271428
*RES
1 a a:1 8.878497
2 a:1 a:2 4.500000
3 a:2 a:3 1.283333
*INDUC
*END

*D_NET b 1.508998
*CONN
*P b B
*CAP
1 b 0.689353
2 b a 0.819645
*RES
1 b b:1 7.142857
*INDUC
*END
```

The 0.819645 fF coupling appears under both `a` and `b`, and each net's total counts it:
0.873071 + 0.819645 + 0.271428 = 1.964144 fF for `a`. The network starts at the port node `a`, so a
timing tool sees the whole load on the port. The DSPF cards for the same net start
`C1 a 0 0.873071f` and `R1 a a:1 8.878497`.

An empty layout writes the header and no `*D_NET`, a valid SPEF file with no nets. DSPF and SPICE
likewise write an empty network.

**Status and limits.** Implemented. Earlier releases listed a coupling capacitance under one net
only; each coupling is now listed under both nets, as OpenSTA's reader expects. With process
corners, every value is a `min:typ:max` triplet (see
[PEX-006](accuracy.md#pex-006-multi-corner-extraction)). SPEF has no element for mutual inductance
or for a resistance between two nets, so these are comments: `// mutual a b 6.409104` and
`// substrate t1:0 t2:0 1775788.233788`. GPurify writes no reduced (`*R_NET`) nets.

SPEF names each net by its label, so GPurify refuses a file it cannot name honestly: a net with no
label, a net with two labels (a short), or one label on two separate nets. The refusal names the
net and its labels:

```text
error: --format spef: net 0 carries 2 labels (a first), a short no pin can name
```

DSPF and SPICE refuse the same shorts and split labels, but name a net with no label `n<number>`.

**Sources.** IEEE 1481-1998, *Standard for Integrated Circuit (IC) Open Library Architecture
(OLA)*, the SPEF clause. The node naming follows the SPEF examples in the
[OpenTimer SPEF guide](https://github.com/OpenTimer/OpenTimer/blob/master/wiki/io/spef.md).
DSPF 1.4 (Open Verilog International).

## Routed designs

### PEX-014: Route-level extraction from LEF and DEF

**What it catches.** The parasitics of a routed digital block, read from its DEF and the
technology and cell LEF files instead of a GDS. A place-and-route flow can extract its wires with
the same deck the custom layout uses.

**How GPurify measures it.** GPurify draws the DEF's routed wires, vias and pins on the deck's
layers, each wire as its centre line widened to the LEF `WIDTH` and extended by half the width at
each end. A placed cell's LEF pin shapes join their net. Each net takes its DEF name. Extraction
then runs as on any layout, with the deck's `pex` rows, the closed forms and `--quasistatic`.

![A DEF ROUTED met1 segment from (0 0) to (100000 0), drawn 100.2 µm by 0.2 µm, extracted as 50.1 Ω, 8.633 fF to ground and 0.433 fF to the wire b beside it](../../diagrams/pex-014.svg)

**In the deck.** Nothing to write beyond the parasitic stack. The deck's layer names match the LEF
layer names. Give each LEF file with `--lef`:

```sh
gpurify pex <design.def> --lef <tech.lef> [--lef <cells.lef> ..] --deck <deck> --format spef
```

```text
grid 1nm
layer met1 = gds(1, 0)
layer via1 = gds(2, 0)
layer met2 = gds(3, 0)
connect conductors [met1, met2]
connect via via1 [met1, met2]
connect label met1 names met1
connect label met2 names met2
pex met1 thickness 100nm height 1000nm sheet 0.1ohm dielectric 3.9 area_cap 30aF/um2 fringe_cap 40aF/um
pex via1 thickness 100nm height 1100nm sheet 2ohm dielectric 3.9 area_cap 0aF/um2 fringe_cap 0aF/um
pex met2 thickness 100nm height 1200nm sheet 0.05ohm dielectric 3.9 area_cap 20aF/um2 fringe_cap 30aF/um
extraction rcc coupling_halo 10
```

**Example output.** Two nets, each `ROUTED met1` over 100 µm, 1 µm apart on centre, with a LEF
`WIDTH` of 0.2 µm:

```sh
gpurify pex route.def --lef tech.lef --deck routed.deck --format spef > route.spef
```

```text
*D_NET a 9.065705
*CONN
*P a B
*CAP
1 a 8.633200
2 a b 0.432505
*RES
1 a a:1 50.100000
...
```

The wire is 100.2 µm long with its end extensions, or 501 squares at 0.1 Ω: 50.1 Ω. Its ground
capacitance is 30 aF/µm² × 20.04 µm² plus 40 aF/µm × 200.8 µm, or 8.6332 fF.

**Status and limits.** Implemented. The resistance and capacitance come from the deck's `pex`
rows, not from the LEF `RESISTANCE RPERSQ` and `CAPACITANCE CPERSQDIST` values. Against OpenROAD's
extractor with LEF RC values, the resistance agrees, and the capacitance agrees except for the
fringe on a wire's two ends, which GPurify counts. OpenROAD extracts routing only, and GPurify also
joins a placed cell's LEF pin shapes to the net.

**Sources.** LEF/DEF 5.8 Language Reference (Cadence, published through Si2). OpenROAD
`extract_parasitics` (OpenRCX).

## Point-to-point reports

### PEX-016: Point-to-point resistance and net-to-net coupling report

**What it catches.** The resistance between two named points on one net, such as a supply pad and
a cell's power pin, and the total coupling between two nets. These answer one question about one
path without reading a SPEF file.

**How GPurify measures it.** Each point must lie on a conducting shape of the net. GPurify models
each conducting shape as a chain of resistors along its long axis, at its sheet resistance per
square, and each via cut at its layer's resistance. It reduces the network to the points and
prints the effective resistance between every two of them. `report coupling` prints the sum of
all coupling capacitance between two nets in the extracted network.

![Net a with points (0, 0.07) on met1 and (9.85, 3) on met2, and the met1, via and met2 resistances in series between them, 14.515476 Ω](../../diagrams/pex-016.svg)

**In the deck.**

```text
report p2p "<net>" at [(<x>, <y>), (<x>, <y>), ..]
report coupling "<net>" "<net>"
```

```text
grid 5nm
layer met1 = gds(68, 20)
layer via = gds(68, 44)
layer met2 = gds(69, 20)
connect conductors [met1, met2]
connect via via [met1, met2]
connect label met1 names met1
connect label met2 names met2
pex met1 thickness 360nm height 1376.1nm sheet 0.125ohm dielectric 4.5 area_cap 25.78aF/um2 fringe_cap 40.57aF/um
pex via thickness 270nm height 1736.1nm sheet 4.5ohm dielectric 4.5 area_cap 0aF/um2 fringe_cap 0aF/um
pex met2 thickness 360nm height 2006.1nm sheet 0.125ohm dielectric 4.2 area_cap 17.5aF/um2 fringe_cap 37.76aF/um
extraction rcc coupling_halo 10
report p2p "a" at [(0um, 70nm), (9850nm, 3um)]
report coupling "a" "b"
```

**Example output.** The layout of PEX-010:

```sh
gpurify pex pair.gds --deck p2p.deck
```

```text
summary:
...
  pex: ran
...
p2p a (0, 0.07) um to (9.85, 3) um: 14.515476 ohm
coupling a b: 0.819645 fF
```

From the left end of the met1 wire to the top of the met2 wire, net `a` reads 14.52 Ω: about
8.79 Ω of met1, 4.5 Ω through the cut and 1.22 Ω of met2. The reports go to the text report only,
not to SPEF, DSPF or JSON.

**Options.**

| Parameter | Value | Meaning |
|---|---|---|
| `at` | list of two or more points | Points on the deck's grid, each on a conducting shape of the net. |

**Status and limits.** Partial. Current spreading across a wide shape is not modelled: each shape
is one chain along its long axis, so the resistance across a wide plate reads as if the current
flowed in a strip. Coupling is reported between nets, not between points. A net the layout lacks,
or a label on two separate nets, is an error when the report is made.

**Sources.** GPurify-specific. Point-to-point resistance is offered by Siemens Calibre PERC P2P
and the Synopsys StarRC datasheet.

## Simulator-ready netlist

### PEX-017: Simulator-ready netlist

**What it catches.** A post-layout netlist that a schematic testbench runs unchanged: the
subcircuit has the reference's name and pin order, each device is the reference card it matched,
and the parasitic network sits between the pins and the devices. A designer can then simulate the
extracted view by swapping one include line.

**How GPurify measures it.** With `--reference`, `pex` runs LVS first and refuses a layout that
fails it. It writes one `.subckt` with the reference's subcircuit name, pin order and net names.
Each device takes the name and model of the reference card it matched, with its terminals in that
card's order, on the node of the region each terminal touches. Sizes come from the extraction, in
the deck's `netlist_scale` units. Then come the `R`, `C`, `L` and `K` cards, as in DSPF. A node is
the net's name on the pin node and `<net>#<index>` elsewhere.

![The reference card XM1 with drain outp, gate inp and source tail, beside the extracted XM1 on outp#1, inp#1 and tail#1, each joined to its pin through the wiring resistance](../../diagrams/pex-017.svg)

**In the deck.** Nothing to write beyond the parasitic stack and the deck's `device` lines. Run with
`--reference` and `--format spice`; `-o <file>` also writes each process corner to
`<file>.<corner>`.

```sh
gpurify pex <layout> --deck <deck> --reference <netlist> --format spice -o <file>
```

**Example output.** A sky130 differential pair; the reference card is
`XM1 outp inp tail vss sky130_fd_pr__nfet_01v8 W=2 L=0.5`:

```sh
gpurify pex diffpair.gds --deck sky130 --reference diffpair.spice --format spice > diffpair.pex.sp
```

```text
* 0.1.0 pex: diffpair.gds, deck sky130, reference diffpair.spice, corner nominal
* sizes in units of 1e-6 m: a bench's .option scale must say the same
.subckt diffpair inp inn outp outn tail vss
XM1 outp#1 inp#1 tail#1 vss sky130_fd_pr__nfet_01v8 w=2.0 l=0.5 nf=1 as=1.0 ps=3.0 ad=2.0 pd=6.0
XM2 outn#1 inn#1 tail#1 vss sky130_fd_pr__nfet_01v8 w=2.0 l=0.5 nf=1 as=1.0 ps=3.0 ad=2.0 pd=6.0
C1 inp 0 0.087585f
R1 inp inp#1 0.125000
...
.ends diffpair
```

`XM1` keeps the reference's drain `outp` and source `tail`, with the drain diffusion's 2.0 µm² on
`ad` and the shared source's 1.0 µm² on `as`. The second comment line says the sizes are in
micrometres, so a bench needs `.option scale=1e-6`. With `--format dspf`, the same run adds an
`*|I` line for each device terminal and an instance section with the device cards.

**Status and limits.** Partial. Refused: a layout that fails LVS, black boxes, and must-connect
joins. A terminal attaches at the node of the region it touches, not at a point inside the device.
The cards carry no layout-dependent effect parameters (length of diffusion, well proximity).
Without `--reference`, devices are named by layout index and pins come in label order, so the
netlist cannot replace the schematic, and GPurify warns:

```text
warning: no --reference, so devices are named by layout index and pins come in label order: this netlist cannot be back-annotated
```

**Sources.** Magic's `ext2spice`, and the DSPF instance section of Siemens Calibre xRC.
