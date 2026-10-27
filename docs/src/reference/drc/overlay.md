# Enclosure and overlap checks

These checks hold one layer against another: how far a host surrounds what it holds, how far one
layer runs past or over another, and what may or may not lie inside what. Distances are measured
as described in [How GPurify measures distances](../../explanation/measuring.md); this page says
only what each check reads.

## Enclosure

### DRC-040: Enclosure on all sides

**What it catches.** A cut or implant whose host does not surround it by the minimum on every
side, such as a contact too close to the edge of its metal. Mask misalignment shifts one layer
against the other, and a thin margin leaves the cut partly off its landing, raising its resistance
or opening it.

**How GPurify measures it.** Each `inner` polygon, as drawn, is measured in the merged `outer`
shape that covers all of it, as the least distance from the polygon to the host's boundary, holes
included. Corners are Euclidean. A polygon that no single host covers measures 0. The other
enclosure forms on this page read inner polygons the same way.

![A 170 nm mcon square 20 nm from the left edge of its met1, against a 30 nm minimum, and a second mcon on no met1 at 0 nm](../../diagrams/drc-040.svg)

**In the deck.**

```text
rule <id> enclosure(<inner>, <outer>) >= <length>
```

```text
grid 5nm
layer mcon = gds(67, 44)
layer met1 = gds(68, 20)
rule m1.4 enclosure(mcon, met1) >= 30nm
```

**Example violation.**

```text
rules:
  m1.4: ran, examined 2 shapes, found 2 violations
violations: 2
  m1.4 error layer mcon at (685 nm, 85 nm) measured 0 nm against limit 30 nm on shape 1
  m1.4 error layer mcon at (10 nm, 185 nm) measured 20 nm against limit 30 nm on shape 0 and shape 2
...
```

The mcon at (20 nm, 100 nm) sits 20 nm inside the left edge of its met1, under the 30 nm limit;
the mcon at (600 nm, 0 nm) has no met1 at all and measures 0.

**Status and limits.** Implemented. No known limits. Shapes with 45° edges and edges at any other
angle are measured too.

**Sources.** SkyWater SKY130 rules ct.4, m1.4 and licon.5a
([periphery rules](https://skywater-pdk.readthedocs.io/en/main/rules/periphery.html)); IHP SG13G2
rules M1.c and V1.c ([IHP Open PDK](https://github.com/IHP-GmbH/IHP-Open-PDK)); GlobalFoundries
GF180MCU rule CO.3 ([design manual](https://gf180mcu-pdk.readthedocs.io/)); ASAP7 rule V3.M4.EN.2
([ASAP7 PDK](https://github.com/The-OpenROAD-Project/asap7)); LEF/DEF 5.8 `ENCLOSURE`; KLayout
`enclosing` ([DRC reference](https://www.klayout.de/doc/about/drc_ref_layer.html)); Magic
`surround`.

### DRC-041: Enclosure on two opposite sides

**What it catches.** A via whose metal does not overhang it by the minimum on both ends of at least
one axis. Advanced processes let a via sit flush with the sides of a narrow wire as long as the
wire runs past both of its ends, so the rule asks for the overhang on one opposite pair, not all
four sides.

**How GPurify measures it.** Each edge of the inner shape is read straight out to the host. For the
vertical edges, GPurify takes the least reading, and the same for the horizontal edges; the
better of the two axes is the measured value. An L-shaped inner shape therefore needs the limit
past every vertical edge, or past every horizontal one.

![A via1 with 40 nm of met1 on every side fails a 50 nm two-side minimum; a second via flush top and bottom with 50 nm left and right passes](../../diagrams/drc-041.svg)

**In the deck.**

```text
rule <id> enclosure(<inner>, <outer>, opposite) >= <length>
```

LEF `ENCLOSURE o1 o2` is two rules: the `opposite` rule at `o1` and the all-sides rule at `o2`.

```text
grid 1nm
layer via1 = gds(21, 0)
layer met1 = gds(19, 0)
rule V1.M1.EN.1 enclosure(via1, met1, opposite) >= 50nm
rule V1.M1.EN.2 enclosure(via1, met1) >= 10nm
```

**Example violation.**

```text
rules:
  V1.M1.EN.1: ran, examined 2 shapes, found 1 violations
  V1.M1.EN.2: ran, examined 2 shapes, found 1 violations
violations: 2
  V1.M1.EN.1 error layer via1 at (20 nm, 90 nm) measured 40 nm against limit 50 nm on shape 2 and shape 0
  V1.M1.EN.2 error layer via1 at (500 nm, 0 nm) measured 0 nm against limit 10 nm on shape 3 and shape 1
...
```

The first via has 40 nm of met1 on every side, so neither axis reaches 50 nm. The second via has
50 nm left and right, which passes the `opposite` rule, but it is flush with the met1 top and
bottom, which breaks the 10 nm all-sides rule.

**Status and limits.** Implemented. A host with 45° edges is measured; an inner shape must be a
rectangle there, and an inner shape with a 45° edge is refused. Edges at any other angle are
refused.

**Sources.** ASAP7 rule V1.M1.EN.1 ([ASAP7 PDK](https://github.com/The-OpenROAD-Project/asap7));
LEF/DEF 5.8 `ENCLOSURE overhang1 overhang2`; KLayout's rectangle error filter
([DRC reference](https://www.klayout.de/doc/about/drc_ref_layer.html)).

### DRC-042: Enclosure on one of two adjacent sides

**What it catches.** A contact whose metal overhang is too short on both sides that meet at some
corner. Foundries write this as "enclosed by at least 60 nm on one of two adjacent sides": at
every corner of the cut, one of its two sides needs the larger overhang, so a contact can never be
tight on two sides that meet.

**How GPurify measures it.** At each convex corner of the inner shape, GPurify reads each of the two
edges meeting there straight out to the host, just inside that corner, and keeps the better of the
two. The measured value is the worst corner. On a host that does not step along the cut's sides,
this gives the same result as `opposite`; where the host steps, a side that is far enclosed at one
end and short at the other is read at each end.

![An mcon with 60 nm of met1 left and below but 30 nm right and above fails 60 nm at its top-right corner; one with 60 nm left and right passes](../../diagrams/drc-042.svg)

**In the deck.**

```text
rule <id> enclosure(<inner>, <outer>, adjacent) >= <length>
```

```text
grid 5nm
layer mcon = gds(67, 44)
layer met1 = gds(68, 20)
rule m1.5 enclosure(mcon, met1, adjacent) >= 60nm
```

**Example violation.**

```text
rules:
  m1.5: ran, examined 2 shapes, found 1 violations
violations: 1
  m1.5 error layer mcon at (245 nm, 145 nm) measured 30 nm against limit 60 nm on shape 0 and shape 2
...
```

The first mcon has 60 nm of met1 on its left and bottom but only 30 nm on its right and top, so
its top-right corner has 30 nm on both sides, under the 60 nm limit. The second mcon has 60 nm
left and right, so every corner has one 60 nm side.

**Status and limits.** Partial. LEF58 `ENCLOSURE ... EOL` (an overhang required only toward a
metal line end) is not checked: the LEF 5.8 text does not define it, and no public checker says
what violates it. An end-cap rule that needs the overhang on two opposite ends, as IHP SG13G2
M1.c1, is the `opposite` form ([DRC-041](#drc-041-enclosure-on-two-opposite-sides)). The inner
shape must be a rectangle on a host with 45° edges; edges at any other angle are refused.

**Sources.** SkyWater SKY130 rules li.5, m1.5, via.5a and licon.5c
([periphery rules](https://skywater-pdk.readthedocs.io/en/main/rules/periphery.html)); IHP SG13G2
rules M1.c1 and V1.c1 ([IHP Open PDK](https://github.com/IHP-GmbH/IHP-Open-PDK)); LEF58
`ENCLOSURE EOL`; Magic `surround directional`.

### DRC-043: Width-dependent enclosure

**What it catches.** A via whose required overhang depends on the wire it lands on: a narrow wire
needs more end-of-line overhang than a wide one, or a long wire less than a short one. LEF writes
these as `ENCLOSURE ... WIDTH`, `EXCEPTEXTRACUT` and `LENGTH`, and foundries as rules such as
"Metal1 (< 0.34 µm) end-of-line overlap".

**How GPurify measures it.** The rule measures as the all-sides or the `opposite` enclosure above,
but holds only the inner shapes the named arguments select:

- `width`: the inner shape lies wholly on a part of `outer` at least that wide, where a square of
  that side fits around all of it.
- `below`: the inner shape does not lie wholly on such a part that wide.
- `except_extra_cut` and `extra_cut`: another drawn inner shape lies on the same merged `outer`
  shape and the same merged `other` shape (the metal on the cut's far side), at most that far
  away, box to box: a redundant cut. `except_extra_cut` skips such cuts, `extra_cut` holds only
  them.
- `length`: the overhang length reaches it. That is the longer of the runs of `outer` along the
  horizontal and the vertical line through the cut's centre, each the run holding the centre. A
  200 nm cut with 50 nm of metal on its left and 400 nm on its right reads 650 nm.
  `length_below` holds the cuts whose overhang length is under it.

LEF applies the rule of the largest `WIDTH` a wire reaches, so write one rule per band, each
band's `below` equal to the next band's `width`. An inner shape on no `outer` falls in the lowest
band.

![A 220 nm contact with 40 nm of metal1 on every side of a 300 nm wire fails 60 nm; the same contact on a 1 µm plate is not held](../../diagrams/drc-043.svg)

**In the deck.**

```text
rule <id> enclosure(<inner>, <outer>[, opposite]; width: <length>, below: <length>) >= <length>
rule <id> enclosure(<inner>, <outer>[, opposite]; width: <length>[, below: <length>], except_extra_cut: <length>, other: <layer>) >= <length>
rule <id> enclosure(<inner>, <outer>[, opposite]; width: <length>[, below: <length>], extra_cut: <length>, other: <layer>) >= <length>
rule <id> enclosure(<inner>, <outer>[, opposite]; length: <length>[, below: <length>]) >= <length>
rule <id> enclosure(<inner>, <outer>[, opposite]; length_below: <length>[, below: <length>]) >= <length>
```

`width` and `below` may each be left out of the first form.

```text
grid 5nm
layer contact = gds(33, 0)
layer metal1 = gds(34, 0)
rule CO.6 enclosure(contact, metal1, opposite; below: 340nm) >= 60nm
```

LEF/DEF 5.8 Example 1-4 is three rules:

```text
rule a enclosure(v, m, opposite; below: 300nm) >= 50nm
rule b enclosure(v, m, opposite; width: 300nm, extra_cut: 200nm, other: m4) >= 50nm
rule c enclosure(v, m; width: 300nm, except_extra_cut: 200nm, other: m4) >= 30nm
```

LEF/DEF 5.8 Example 1-5 is three more:

```text
rule d enclosure(v, m, opposite; length: 700nm, below: 1um) >= 50nm
rule e enclosure(v, m; length_below: 700nm, below: 1um) >= 50nm
rule f enclosure(v, m; width: 1um) >= 100nm
```

**Example violation.**

```text
rules:
  CO.6: ran, examined 1 shapes, found 1 violations
violations: 1
  CO.6 error layer contact at (20 nm, 150 nm) measured 40 nm against limit 60 nm on shape 0 and shape 2
...
```

The contact on the 300 nm wide metal1 has 40 nm on every side, under the 60 nm limit. The same
contact on a 1 µm plate is not held, since a 340 nm square fits around it.

**Options.**

| Parameter | Value | Meaning |
|---|---|---|
| `width` | length | Hold only an inner shape lying on a part of `outer` at least this wide. |
| `below` | length | Skip an inner shape lying on a part of `outer` this wide. Must exceed `width`. |
| `except_extra_cut` | length | Skip an inner shape with a redundant cut at most this far away. Needs `width` and `other`. |
| `extra_cut` | length | Hold only an inner shape with a redundant cut at most this far away. Needs `width` and `other`. |
| `other` | layer | The metal on the far side of the cut, which a redundant cut must share. |
| `length` | length | Hold only an inner shape whose overhang length is at least this. |
| `length_below` | length | Hold only an inner shape whose overhang length is under this. |

**Status and limits.** Partial. LEF lets a band list several rules of which a via "only needs to
meet one" (Example 1-4's `0.0 0.05` or `0.01 0.04`); GPurify holds each rule on its own, so that
choice cannot be written. LEF58 `ENCLOSURETABLE` is not checked: the LEF 5.8 text does not define
it. Every form with a named argument refuses a layer with a 45° edge.

**Sources.** LEF/DEF 5.8 `ENCLOSURE ... WIDTH`, `EXCEPTEXTRACUT` and `LENGTH` (Examples 1-3 to 1-5,
Figure 1-5); LEF58 `ENCLOSURETABLE`; GlobalFoundries GF180MCU rule CO.6
([design manual](https://gf180mcu-pdk.readthedocs.io/)).

### DRC-044: Maximum enclosure

**What it catches.** A host layer that reaches too far past what it holds, such as an implant
blocking layer drawn far beyond the contacts it is meant to cover. Some layers must stay close to
their contents, because extra area changes a device or blocks a neighbour.

**How GPurify measures it.** Each merged `outer` shape that wholly holds one or more `inner` shapes
must lie within those inner shapes grown by the limit, square at the corners. Several inner shapes
under one host are measured together. A host holding no inner shape is not checked. The measured
value is the least whole growth that would cover the host.

![An npc square reaching 135 nm past the right side of its licon, against a 95 nm maximum](../../diagrams/drc-044.svg)

**In the deck.**

```text
rule <id> enclosure(<inner>, <outer>) <= <length>
```

```text
grid 5nm
layer licon = gds(66, 44)
layer npc = gds(95, 20)
rule npc.5 enclosure(licon, npc) <= 95nm
```

**Example violation.**

```text
rules:
  npc.5: ran, examined 2 shapes, found 1 violations
violations: 1
  npc.5 error layer npc at (380 nm, 180 nm) measured 135 nm against limit 95 nm on shape 2
...
```

The first npc runs 135 nm past the right side of its licon, beyond the 95 nm limit; the point
lies in the part that reaches too far. The second npc stops 95 nm from its licon on every side
and passes.

**Status and limits.** Implemented. A layer with a 45° edge is refused. A maximum space between
two layers, such as IHP SG13G2 Rppd.c, is written as a band round one layer's edges that the
other must reach:
`forbidden(cont.not_interacting(salblock.edges().extended(begin: 0nm, end: 0nm, out: 200nm, in: 200nm)))`.
A maximum of 0 to a butted shape (GF180MCU NP.3d) is a forbidden overlap,
`forbidden(ncomp and pcomp)`.

**Sources.** SkyWater SKY130 rules npc.5 and mf.5
([periphery rules](https://skywater-pdk.readthedocs.io/en/main/rules/periphery.html)); IHP SG13G2
rules Sdiod.a to Sdiod.c, Rppd.c and LU.c ([IHP Open PDK](https://github.com/IHP-GmbH/IHP-Open-PDK));
GlobalFoundries GF180MCU rules NP.3d and GR.1 ([design manual](https://gf180mcu-pdk.readthedocs.io/)).

## Overlap and separation

### DRC-045: Extension past another layer

**What it catches.** A gate whose poly does not run far enough past the diffusion, or a diffusion
that does not run far enough past the gate. Corner rounding pulls a line end back, so a short end
cap lets the channel short source to drain at the edge.

**How GPurify measures it.** Each gate is one shape of the area the two merged layers share. An
axis counts as crossed when every gate edge facing along it lies on the boundary of `B`. Each such
edge is read straight out along `A` past it, and the gate measures the least reading over its
crossed axes. A gate that bends, or that ends inside `B`, measures 0. Shapes that only touch make
no gate.

![A poly line crossing diff and ending 100 nm below it, against a 130 nm minimum extension, beside one that extends 130 nm](../../diagrams/drc-045.svg)

**In the deck.**

```text
rule <id> extension(<A>, <B>) >= <length>
```

```text
grid 5nm
layer diff = gds(65, 20)
layer poly = gds(66, 20)
rule poly.8 extension(poly, diff) >= 130nm
```

**Example violation.**

```text
rules:
  poly.8: ran, examined 2 shapes, found 1 violations
violations: 1
  poly.8 error layer poly at (675 nm, -50 nm) measured 100 nm against limit 130 nm on shape 2 and shape 0
...
```

The second poly line runs only 100 nm past the bottom of the diff, under the 130 nm limit; the
point lies midway along that end cap. The first runs 130 nm past both sides and passes.

**Status and limits.** Implemented. A bent gate measures 0, which matches every foundry: bent
gates are not allowed, and [DRC-052](#drc-052-gate-shape-rules) reports the bend itself. A layer
with a 45° edge is refused.

**Sources.** SkyWater SKY130 rules poly.7 and poly.8
([periphery rules](https://skywater-pdk.readthedocs.io/en/main/rules/periphery.html)); IHP SG13G2
rule Gat.c ([IHP Open PDK](https://github.com/IHP-GmbH/IHP-Open-PDK)); GlobalFoundries GF180MCU
rule PL.4 ([design manual](https://gf180mcu-pdk.readthedocs.io/)); ASAP7 rule GATE.ACTIVE.EX.1
([ASAP7 PDK](https://github.com/The-OpenROAD-Project/asap7)); Magic `overhang` and `extend`.

### DRC-046: Overlap amount

**What it catches.** Two layers that overlap, but by less than the minimum, such as a stitch
between two masks of a double-patterned layer or two implants that must share a strip. A thin
overlap vanishes under misalignment and leaves a gap.

**How GPurify measures it.** Each shape of the area the two merged layers share is measured as
`width` measures a shape: its narrowest extent. Shapes that do not overlap, or only touch, are not
measured.

![Two mask shapes overlapping by 6 nm, against a 10 nm minimum overlap](../../diagrams/drc-046.svg)

**In the deck.**

```text
rule <id> overlap(<A>, <B>) >= <length>
```

```text
grid 1nm
layer m1_c1 = gds(15, 1)
layer m1_c2 = gds(15, 2)
rule M1.ST.ov overlap(m1_c1, m1_c2) >= 10nm
```

**Example violation.**

```text
rules:
  M1.ST.ov: ran, examined 1 shapes, found 1 violations
violations: 1
  M1.ST.ov error layer m1_c1 at (203 nm, 20 nm) measured 6 nm against limit 10 nm on shape 0 and shape 1
...
```

The two masks share a strip from 200 nm to 206 nm, a 6 nm overlap under the 10 nm limit.

**Status and limits.** Implemented. A layer with a 45° edge is refused.

**Sources.** IHP SG13G2 rule pSD.e ([IHP Open PDK](https://github.com/IHP-GmbH/IHP-Open-PDK));
GlobalFoundries GF180MCU rule NP.5a ([design manual](https://gf180mcu-pdk.readthedocs.io/));
SkyWater SKY130 rule hv.poly.7
([periphery rules](https://skywater-pdk.readthedocs.io/en/main/rules/periphery.html)); ASAP7 rules
of type OV ([ASAP7 PDK](https://github.com/The-OpenROAD-Project/asap7)); KLayout `overlap`
([DRC reference](https://www.klayout.de/doc/about/drc_ref_layer.html)).

### DRC-047: Separation between two layers

**What it catches.** A shape on one layer too close to a shape on another, such as field poly too
close to diffusion. Each foundry has many such pairs: they keep a layer from printing into, or
interacting electrically with, another.

**How GPurify measures it.** Every pair of a shape on `A` and a shape on `B` closer than the limit
is a violation, edge to edge and Euclidean at corners. Shapes that touch, overlap or nest measure
0 and are reported. To measure only the shapes that stay apart, select them first, as the example
does with `not_interacting`.

![A field poly line 50 nm from a diff box, against a 75 nm minimum separation](../../diagrams/drc-047.svg)

**In the deck.**

```text
rule <id> space(<A>, <B>) >= <length>
```

```text
grid 5nm
layer diff = gds(65, 20)
layer poly = gds(66, 20)
layer poly_field = poly.not_interacting(diff)
rule poly.4 space(poly_field, diff) >= 75nm
```

**Example violation.**

```text
rules:
  poly.4: ran, examined 1 shapes, found 1 violations
violations: 1
  poly.4 error layer poly_field at (1025 nm, 250 nm) measured 50 nm against limit 75 nm on shape 3 and shape 0
...
```

The field poly at x = 1050 nm is 50 nm from the diff's right edge, under the 75 nm limit. The
poly line that crosses the diff is a gate and is not on `poly_field`.

**Status and limits.** Implemented. No known limits. Shapes with 45° edges and edges at any other
angle are measured too. For the space measured only across facing edges, see
[DRC-055](#drc-055-direction-dependent-spacing).

**Sources.** SkyWater SKY130 rules poly.4 and licon.11
([periphery rules](https://skywater-pdk.readthedocs.io/en/main/rules/periphery.html)); IHP SG13G2
rules NW.d and Gat.d ([IHP Open PDK](https://github.com/IHP-GmbH/IHP-Open-PDK)); GlobalFoundries
GF180MCU rule DF.16 ([design manual](https://gf180mcu-pdk.readthedocs.io/)); ASAP7 rule
GATE.ACTIVE.S.4 ([ASAP7 PDK](https://github.com/The-OpenROAD-Project/asap7)); KLayout
`separation` ([DRC reference](https://www.klayout.de/doc/about/drc_ref_layer.html)); Magic
`spacing`.

## Containment and forbidden overlap

### DRC-048: Containment

**What it catches.** A shape that must lie inside another but sticks out, such as a poly contact
outside its implant, and a host that must hold at least one of something but holds none, such as
a tap without a contact. An unhoused contact or an unconnected tap leaves a device without the
doping or the connection it needs.

**How GPurify measures it.** `inside` merges `inner` and reports each merged shape not entirely
covered by `outer`, with the area left outside. A shape touching `outer`'s edge from inside is
inside. `contains` counts, for each merged `outer` shape, the merged `inner` shapes it holds
entirely: an inner shape across the outer's edge is not held, and touching inner shapes count as
one.

![A tap holding no licon, against a minimum of one, and a poly_licon square sticking 70 nm out of its npc](../../diagrams/drc-048.svg)

**In the deck.**

```text
rule <id> inside(<inner>, <outer>)
rule <id> contains(<outer>, <inner>) >= <count>
```

```text
grid 5nm
layer tap = gds(65, 44)
layer licon = gds(66, 44)
rule licon.16 contains(tap, licon) >= 1
```

```text
grid 5nm
layer poly = gds(66, 20)
layer licon = gds(66, 44)
layer npc = gds(95, 20)
layer poly_licon = licon and poly
rule licon.18 inside(poly_licon, npc)
```

**Example violation.**

```text
rules:
  licon.16: ran, examined 2 shapes, found 1 violations
violations: 1
  licon.16 error layer tap at (1250 nm, 250 nm) measured 0 against limit 1 on shape 3
...
```

```text
rules:
  licon.18: ran, examined 2 shapes, found 1 violations
violations: 1
  licon.18 error layer poly_licon at (785 nm, 185 nm) measured 11900 nm^2 against limit 0 nm^2 on shape 5
...
```

The second tap holds 0 licons, since its only licon crosses the tap's edge, against a minimum of
1. The poly contact at x = 700 nm runs 70 nm past the npc, leaving 11900 nm² outside it.

**Status and limits.** Implemented. No known limits.

**Sources.** SkyWater SKY130 rules licon.4, licon.16 and licon.18
([periphery rules](https://skywater-pdk.readthedocs.io/en/main/rules/periphery.html)); IHP SG13G2
rules Cnt.g and Cnt.h ([IHP Open PDK](https://github.com/IHP-GmbH/IHP-Open-PDK)); ASAP7 rule
V1.AUX.1 ([ASAP7 PDK](https://github.com/The-OpenROAD-Project/asap7)); KLayout `inside` and
`covering` ([DRC reference](https://www.klayout.de/doc/about/drc_ref_layer.html)).

### DRC-049: Exact or maximum count

**What it catches.** A host that holds more of something than allowed, or not exactly the number
required, such as a precision resistor terminal with two contacts where the model assumes one. The
device's characterised value no longer matches what was drawn.

**How GPurify measures it.** As for `contains` in [DRC-048](#drc-048-containment): each merged
`outer` shape counts the merged `inner` shapes it holds entirely. `<=` reports a count above the
limit, and `==` any count other than the limit.

![A res_terminal holding two licon squares, against a maximum of one](../../diagrams/drc-049.svg)

**In the deck.**

```text
rule <id> contains(<outer>, <inner>) <= <count>
rule <id> contains(<outer>, <inner>) == <count>
```

```text
grid 5nm
layer licon = gds(66, 44)
layer res_terminal = gds(66, 20)
rule rpm.1g contains(res_terminal, licon) <= 1
```

**Example violation.**

```text
rules:
  rpm.1g: ran, examined 1 shapes, found 1 violations
violations: 1
  rpm.1g error layer res_terminal at (175 nm, 500 nm) measured 2 against limit 1 on shape 2
...
```

The terminal holds 2 licons, over the maximum of 1. The point is the centre of the terminal.

**Status and limits.** Implemented. SkyWater SKY130 via.13, "Max of 5 vias within 0.350 µm", is
not written: the manual does not say whether 0.35 µm bounds a window or a distance from each via.

**Sources.** SkyWater SKY130 rules rpm.1g to rpm.1k and via.13
([periphery rules](https://skywater-pdk.readthedocs.io/en/main/rules/periphery.html)).

### DRC-050: Forbidden overlap

**What it catches.** A combination of layers that must never occur, such as a contact landing on
poly over diffusion, a layer straddling another, or a layer outside its permitted region. Each is
a structure the process cannot build or that the device models do not cover.

**How GPurify measures it.** You write the forbidden combination as a layer, with `and`, `not`
and the selection operations, and `forbidden` reports every shape on it with its area. On an edge
layer it reports every edge.

![A licon on poly over diff, the forbidden licon_on_gate overlap outlined, against no allowed area](../../diagrams/drc-050.svg)

**In the deck.**

```text
rule <id> forbidden(<layer>)
```

```text
grid 5nm
layer diff = gds(65, 20)
layer tap = gds(65, 44)
layer poly = gds(66, 20)
layer licon = gds(66, 44)
layer licon_on_gate = licon and poly and (diff or tap)
rule licon.17 forbidden(licon_on_gate)
```

**Example violation.**

```text
rules:
  licon.17: ran, examined 1 shapes, found 1 violations
violations: 1
  licon.17 error layer licon_on_gate at (450 nm, 370 nm) measured 28900 nm^2 against limit 0 nm^2 on shape 4
...
```

A 170 nm licon lies wholly on poly over diff, so all 28900 nm² of it is forbidden.

**Status and limits.** Implemented. No known limits. A straddle is written with the selection
operations: sky130 licon.6, a licon partly on tap, is
`forbidden((licon and tap).interacting(licon not tap))`.

**Sources.** SkyWater SKY130 rules licon.6, licon.17 and x.23a to x.23f
([periphery rules](https://skywater-pdk.readthedocs.io/en/main/rules/periphery.html)); IHP SG13G2
rule Cnt.j ([IHP Open PDK](https://github.com/IHP-GmbH/IHP-Open-PDK)); GlobalFoundries GF180MCU
rule PL.9 ([design manual](https://gf180mcu-pdk.readthedocs.io/)); KLayout `overlapping` and
`in_and_out` ([DRC reference](https://www.klayout.de/doc/about/drc_ref_layer.html)); Magic
`no_overlap` and `exact_overlap`.

## Edge relations

### DRC-051: Butting edges

**What it catches.** Rules on the edge where two layers abut, such as a tap butting a diffusion:
the butting edge must be long enough, two butting edges far enough apart, and the implant must
cover the butting edge. A short butt leaves a weak tie; a misplaced implant counter-dopes the
junction.

**How GPurify measures it.** The butting edges are an edge layer, `A.edges() and B.edges()`. The
edge checks then measure them: `length` the length of each edge, `space` the distance between two
edges, edge to edge and Euclidean, `enclosure` how far `L` covers each edge's outside, measured
straight out from the edge along its length.

![A tap butting a 200 nm tall diff, the 200 nm butting edge marked, against a 290 nm minimum length](../../diagrams/drc-051.svg)

**In the deck.**

```text
rule <id> length(<edges>) >= <length>
rule <id> space(<edges>[, <edges>]) >= <length>
rule <id> enclosure(<edges>, <layer>) >= <length>
```

```text
grid 5nm
layer diff = gds(65, 20)
layer tap = gds(65, 44)
layer butt = tap.edges() and diff.edges()
rule difftap.4 length(butt) >= 290nm
```

**Example violation.**

```text
rules:
  difftap.4: ran, examined 1 shapes, found 1 violations
violations: 1
  difftap.4 error layer butt at (1000 nm, 100 nm) measured 200 nm against limit 290 nm
...
```

The tap butts the diff along a 200 nm edge at x = 1000 nm, under the 290 nm limit. An edge
finding names no shape.

**Status and limits.** Partial. The edge `enclosure` measures straight out from each edge, so it
misses a gap that opens only diagonally past an edge's end, and can pass a layout a sign-off
deck would flag.

**Sources.** SkyWater SKY130 rules difftap.4 to difftap.7 and licon.5b
([periphery rules](https://skywater-pdk.readthedocs.io/en/main/rules/periphery.html)); IHP SG13G2
rules pSD.e to pSD.g ([IHP Open PDK](https://github.com/IHP-GmbH/IHP-Open-PDK)); GlobalFoundries
GF180MCU rules DF.3b and NP.3d ([design manual](https://gf180mcu-pdk.readthedocs.io/)); Magic
`edge4way`.

### DRC-052: Gate shape rules

**What it catches.** A gate that bends on the diffusion, and poly that covers an inner corner of
the diffusion. Either makes a channel whose length and width vary along it, so the transistor no
longer matches its model.

**How GPurify measures it.** `bend` reports each concave corner of `A` that lies in `B`'s material
where their shared area turns too. A stub off a gate is two such corners; a turn on `B`'s edge is
none. `covers_corner` reports each concave corner of `B` that `A` covers, where their shared
area turns. Each corner is reported where it is, with a count of 1 against a limit of 0.

![An L-shaped poly turning a corner on diff, and a straight poly over the inner corner of an L-shaped diff](../../diagrams/drc-052.svg)

**In the deck.**

```text
rule <id> bend(<A>, <B>)
rule <id> covers_corner(<A>, <B>)
```

```text
grid 5nm
layer diff = gds(65, 20)
layer poly = gds(66, 20)
rule poly.10 covers_corner(poly, diff)
rule poly.11 bend(poly, diff)
```

**Example violation.**

```text
rules:
  poly.10: ran, examined 2 shapes, found 1 violations
  poly.11: ran, examined 2 shapes, found 1 violations
violations: 2
  poly.10 error layer poly at (2500 nm, 500 nm) measured 1 against limit 0 on shape 3 and shape 1
  poly.11 error layer poly at (550 nm, 150 nm) measured 1 against limit 0 on shape 2 and shape 0
...
```

The poly over the L-shaped diff covers its inner corner at (2500 nm, 500 nm). The L-shaped poly
turns on the diff at (550 nm, 150 nm).

**Status and limits.** Implemented. A layer with a 45° edge is refused.

**Sources.** SkyWater SKY130 rules poly.10 and poly.11
([periphery rules](https://skywater-pdk.readthedocs.io/en/main/rules/periphery.html)); IHP SG13G2
rule Gat.f ([IHP Open PDK](https://github.com/IHP-GmbH/IHP-Open-PDK)); GlobalFoundries GF180MCU
rule PL.6 ([design manual](https://gf180mcu-pdk.readthedocs.io/)); ASAP7 rule GATE.AUX.1
([ASAP7 PDK](https://github.com/The-OpenROAD-Project/asap7)).

### DRC-053: Exact width match across layers

**What it catches.** A via that is not exactly as wide as the wire it lands on, across the wire.
Self-aligned via processes cut the via by the wire's own edges, so the via drawn must match the
wire's width exactly.

**How GPurify measures it.** Each inner shape is read straight out from each edge to its host. On
one axis, every edge must meet the host's edge, so every reading is 0. The measured value is the
widest reading on the better axis. An inner shape on no host is not reported here; that is for
`inside` ([DRC-048](#drc-048-containment)).

![A V1 square 2 nm short of the top and bottom of its 18 nm M2 wire, against an exact match](../../diagrams/drc-053.svg)

**In the deck.**

```text
rule <id> full_width(<inner>, <outer>)
```

```text
grid 1nm
layer V1 = gds(21, 0)
layer M2 = gds(20, 0)
rule V1.M2.AUX.2 full_width(V1, M2)
```

**Example violation.**

```text
rules:
  V1.M2.AUX.2: ran, examined 2 shapes, found 1 violations
violations: 1
  V1.M2.AUX.2 error layer V1 at (309 nm, 1 nm) measured 2 nm against limit 0 nm on shape 2 and shape 0
...
```

The second V1 stops 2 nm short of the M2 wire's top and bottom edges, so it misses the exact
match by 2 nm. The first V1 spans the wire and passes.

**Status and limits.** Partial. The check is the ASAP7 V1.M2.AUX.2 form only. LEF58 `SPACING
EXACTALIGNED`, the spacing of exactly aligned line ends, is not checked: no public text defines
it. A layer with a 45° edge is refused.

**Sources.** ASAP7 rule V1.M2.AUX.2 ([ASAP7 PDK](https://github.com/The-OpenROAD-Project/asap7));
LEF58 `SPACING EXACTALIGNED`.

### DRC-054: Enclosure excluding coincident edges

**What it catches.** An implant too close to the edge of the well around it, where the two may
also share an edge. The foundry rule exempts the shared (coincident) edges: an implant drawn
flush with its well is intended, but one drawn just inside it is a sliver of well the implant
does not cover.

**How GPurify measures it.** Each edge of the inner shape is measured to the parallel edges of
the outer shape that face the same way and lie at or beyond it, edge to edge and Euclidean. Pairs
that touch, a coincident edge or a corner on the edge, are not measured.

![An lvtn flush with the left side of its nwell and 300 nm from its top and bottom, against a 380 nm minimum](../../diagrams/drc-054.svg)

**In the deck.**

```text
rule <id> enclosure(<inner>, <outer>, noncoincident) >= <length>
```

```text
grid 5nm
layer nwell = gds(64, 20)
layer lvtn = gds(125, 44)
rule lvtn.10 enclosure(lvtn, nwell, noncoincident) >= 380nm
```

**Example violation.**

```text
rules:
  lvtn.10: ran, examined 2 shapes, found 1 violations
violations: 1
  lvtn.10 error layer lvtn at (3500 nm, 150 nm) measured 300 nm against limit 380 nm on shape 1 and shape 3
...
```

The second lvtn shares its left edge with the nwell, which is exempt, but sits 300 nm from the
nwell's bottom edge, under the 380 nm limit. The first lvtn is 400 nm from the top and bottom and
passes.

**Status and limits.** Implemented. No known limits. Shapes with 45° edges and edges at any other
angle are measured too.

**Sources.** SkyWater SKY130 rule lvtn.10
([periphery rules](https://skywater-pdk.readthedocs.io/en/main/rules/periphery.html)).

### DRC-055: Direction-dependent spacing

**What it catches.** A layer too close to a device along one direction only, such as a
low-threshold implant too close to a PMOS gate along its source-drain direction. Corner-to-corner
proximity does not matter to such a rule, only edges that face each other.

**How GPurify measures it.** Each polygon on `A`, as drawn, is measured to each on `B` only
across edges that are parallel, face each other, and overlap in projection by more than 0, in
either axis. Corner to corner is not measured. Shapes that touch or overlap measure 0.

![An lvtn 150 nm from a gate's facing edge, against a 235 nm minimum, and an lvtn diagonal to the gate's corner, not measured](../../diagrams/drc-055.svg)

**In the deck.**

```text
rule <id> space(<A>, <B>, projection) >= <length>
```

```text
grid 5nm
layer diff = gds(65, 20)
layer poly = gds(66, 20)
layer lvtn = gds(125, 44)
layer gate = poly and diff
rule lvtn.3b space(lvtn, gate, projection) >= 235nm
```

**Example violation.**

```text
rules:
  lvtn.3b: ran, examined 2 shapes, found 1 violations
violations: 1
  lvtn.3b error layer lvtn at (625 nm, 250 nm) measured 150 nm against limit 235 nm on shape 1 and shape 4
...
```

The lvtn to the right of the gate faces it across a 150 nm gap, under the 235 nm limit. The lvtn
up and to the left is 141 nm from the gate's corner, but no edges face, so it is not measured.

**Status and limits.** Partial. GPurify reads lvtn.3b as sky130's own KLayout deck does: facing
edges in both axes. Magic's sky130 technology file reads the source-drain direction from the
gate instead, at a different distance. The manual does not say which is meant, so the two public
decks differ. A layer with a 45° edge is refused.

**Sources.** SkyWater SKY130 rule lvtn.3b
([periphery rules](https://skywater-pdk.readthedocs.io/en/main/rules/periphery.html)); KLayout's
`projection` metric ([DRC reference](https://www.klayout.de/doc/about/drc_ref_layer.html)).

## Shape selection

### DRC-130: Shape must contain a rectangle

**What it catches.** A shape too small or too oddly shaped to hold a rectangle of a given size,
such as a pad or a landing area that must fit a probe or a bond of known dimensions. Area and
width alone do not catch an L-shaped plate that is big but has no room for the box.

**How GPurify measures it.** `L.with_rect(w x h)` selects the merged shapes that can hold an
axis-aligned `w` by `h` rectangle either way round, the rectangle's edges allowed on the shape's
edges. `L.without_rect(w x h)` selects the others, and `forbidden` reports them with their area.

![A 1.5 µm met3 square that cannot hold a 1 µm by 2 µm box, and a 2.1 µm by 1.2 µm plate that holds it turned](../../diagrams/drc-130.svg)

**In the deck.**

```text
layer <name> = <layer>.without_rect(<length> x <length>)
rule <id> forbidden(<name>)
```

```text
grid 5nm
layer met3 = gds(70, 20)
layer met3_small = met3.without_rect(1um x 2um)
rule m3.rect forbidden(met3_small)
```

**Example violation.**

```text
rules:
  m3.rect: ran, examined 1 shapes, found 1 violations
violations: 1
  m3.rect error layer met3_small at (0 nm, 1500 nm) measured 2250000 nm^2 against limit 0 nm^2 on shape 2
...
```

The 1.5 µm square has no room for a 1 µm by 2 µm box, so all 2250000 nm² of it is reported. The
2.1 µm by 1.2 µm plate holds the box turned on its side and passes.

**Status and limits.** Implemented. Both sides must be positive. A layer with a 45° edge or an
edge at any other angle is refused. Calibre's options for `ENCLOSE RECTANGLE`, such as `ORTHOGONAL
ONLY`, are not public and not modelled.

**Sources.** Siemens Calibre `ENCLOSE RECTANGLE`, as stated on the
[KLayout forum, thread 2141](https://www.klayout.de/forum/discussion/2141); no open foundry rule
states such a check.
