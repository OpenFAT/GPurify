# Width, area and length checks

These checks hold one shape on its own to a size: its width, its area, the area of its holes, the
length of its edges, and the exact sizes a cut or a resistor may take. Each one reads the layer
after touching shapes merge, so a wire drawn in pieces is measured as one shape.

How a distance is measured, at corners and on 45° edges, is in
[How GPurify measures](../../explanation/measuring.md).

## Width

### DRC-010: Minimum width

**What it catches.** A shape narrower than the process can print anywhere along it. A line below the
minimum width thins or breaks in lithography and etch, which opens the wire or raises its
resistance and its electromigration risk.

**How GPurify measures it.** GPurify measures across the shape's material between facing edges, and
corner to corner where two inside corners face each other across a diagonal neck. It reports each
shape once, at its narrowest place.

![A met1 wire 0.10 µm wide fails a 0.14 µm minimum width; a wire 0.14 µm wide passes](../../diagrams/drc-010.svg)

**In the deck.**

```text
rule <id> width(<layer>) >= <length>
```

```text
grid 5nm
layer met1 = gds(68, 20)
rule m1.1 width(met1) >= 140nm
```

**Example violation.**

```text
rules:
  m1.1: ran, examined 1 shapes, found 1 violations
violations: 1
  m1.1 error layer met1 at (50 nm, 1000 nm) measured 100 nm against limit 140 nm on shape 0
...
```

A met1 wire 100 nm wide breaks the 140 nm limit. The point is the middle of the wire, halfway across.

**Status and limits.** Implemented. A shape with several narrow places is reported once, at the
narrowest. Two shapes that touch only at a corner are one shape with a width of 0 at that corner.

**Sources.** SkyWater SKY130 rule m1.1; IHP SG13G2 rule M1.a; GlobalFoundries GF180MCU rule Mn.1;
ASAP7 rule M1.W.1; LEF/DEF 5.8 `WIDTH`, `MINWIDTH` and `LEF58_MINWIDTH`; KLayout
[`width`](https://www.klayout.de/doc/about/drc_ref_layer.html); Magic `width`; OpenROAD
[TritonRoute](https://openroad.readthedocs.io/en/latest/main/src/drt/README.html).

### DRC-011: Device channel width and length

**What it catches.** A transistor whose channel is shorter or narrower than the device's rule. A
short channel leaks and breaks down early, and a narrow one does not match its model. The gate is
the overlap of poly and diffusion, and the rule reads two of its edge sets.

**How GPurify measures it.** With `gate = poly and diff`, the gate edges that are not diffusion
edges are the gate's poly sides, and the width between them is the channel length. The gate edges
on the diffusion boundary are the channel's ends, and the width between them is the channel width.
GPurify measures straight across between two parallel edges that face each other across the gate.

![A gate 0.13 µm long and 0.36 µm wide, measured between its poly edges and between its diffusion edges](../../diagrams/drc-011.svg)

**In the deck.**

```text
layer <gate> = <poly> and <diff>
rule <id> width(<gate>.edges() not <diff>.edges()) >= <length>   # channel length
rule <id> width(<gate>.edges() and <diff>.edges()) >= <length>   # channel width
```

```text
grid 5nm
layer diff = gds(65, 20)
layer poly = gds(66, 20)
layer gate = poly and diff
layer gate_ends  = gate.edges() not diff.edges()
layer gate_sides = gate.edges() and diff.edges()
rule poly.1b   width(gate_ends) >= 150nm
rule difftap.2 width(gate_sides) >= 420nm
```

**Example violation.**

```text
rules:
  poly.1b: ran, examined 1 shapes, found 1 violations
  difftap.2: ran, examined 1 shapes, found 1 violations
violations: 2
  poly.1b error layer gate_ends at (465 nm, 180 nm) measured 130 nm against limit 150 nm
  difftap.2 error layer gate_sides at (465 nm, 180 nm) measured 360 nm against limit 420 nm
...
```

A poly line 130 nm wide crosses a diffusion 360 nm tall: the channel is 130 nm long against 150 nm,
and 360 nm wide against 420 nm. Both points are the middle of the gate. A finding on an edge layer
names no shape.

**Status and limits.** Implemented. A straight gate is measured exactly. A bent gate is measured side
pair by side pair, so each straight stretch of it is held to the limit on its own.

**Sources.** SkyWater SKY130 rules poly.1b, difftap.2 and poly.13; IHP SG13G2 rules Gat.a1 to Gat.a4;
GlobalFoundries GF180MCU rule PL.2.

### DRC-012: Maximum width

**What it catches.** A shape wider than the limit in every direction somewhere along it: a fill
square too large, or a wide metal plate that needs slots. Wide metal dishes in polishing and lifts
under stress, so foundries cap it.

**How GPurify measures it.** GPurify finds every part of the shape where a square one grid unit
larger than the limit fits. It reports each such part once, with the part's narrowest width. A
shape exactly as wide as the limit passes.

![An activ filler 6 µm by 8 µm against a 5 µm maximum width](../../diagrams/drc-012.svg)

**In the deck.**

```text
rule <id> width(<layer>) <= <length>
```

```text
grid 5nm
layer activ_filler = gds(1, 22)
rule AFil.a width(activ_filler) <= 5um
```

**Example violation.**

```text
rules:
  AFil.a: ran, examined 1 shapes, found 1 violations
violations: 1
  AFil.a error layer activ_filler at (3000 nm, 4000 nm) measured 6000 nm against limit 5000 nm on shape 0
...
```

A filler 6 µm by 8 µm is 6 µm wide in both directions, over the 5 µm limit. The point is the centre
of the filler.

**Status and limits.** Implemented. Touching shapes count as one, so a plate with a thin tab is as
wide as the plate.

**Sources.** IHP SG13G2 rules Slt.c and AFil.a; GlobalFoundries GF180MCU rule DF.2b; SkyWater SKY130
rule m1.11; ASAP7 rule M4.W.2; LEF/DEF 5.8 `MAXWIDTH`; Magic `maxwidth`.

### DRC-013: Exact cut size

**What it catches.** A contact or via cut that is not the one size the process allows. Cuts are
printed and filled for one size; a larger or oblong cut fills badly and changes its resistance.

**How GPurify measures it.** GPurify compares each cut's bounding box with the rule's rectangle,
either way round. It reports the first side that differs, against the side it should be. A cut
with the right box that is not a rectangle reports its area against the rectangle's.

![A via1 cut 0.19 µm by 0.25 µm against an exact 0.19 µm by 0.19 µm size](../../diagrams/drc-013.svg)

**In the deck.**

```text
rule <id> size(<layer>) == <length> x <length>
```

```text
grid 5nm
layer via1 = gds(19, 0)
rule V1.a size(via1) == 190nm x 190nm
```

**Example violation.**

```text
rules:
  V1.a: ran, examined 1 shapes, found 1 violations
violations: 1
  V1.a error layer via1 at (95 nm, 125 nm) measured 250 nm against limit 190 nm on shape 0
...
```

A cut 190 nm by 250 nm has its long side 250 nm against 190 nm. The point is the centre of the cut.

**Status and limits.** Implemented. Touching cuts count as one shape, so two abutting squares are one
slot and fail.

**Sources.** IHP SG13G2 rules Cnt.a and V1.a; GlobalFoundries GF180MCU rules CO.1 and Vn.1; SkyWater
SKY130 rules licon.1, ct.1 and via.1a; LEF58 `CUTCLASS`.

### DRC-014: Cut classes

**What it catches.** A cut that is none of the several sizes the process allows. Some layers take a
small set of cut sizes, each with its own spacing and enclosure, and any other size is unmodelled.

**How GPurify measures it.** GPurify compares each cut's bounding box with every listed size, either
way round. A cut that is a rectangle of one listed size passes. Any other cut is reported once, as
0 matching sizes against 1 required.

![A 0.15 µm via passes and a 0.20 µm via fails against the sizes 0.15, 0.23 and 0.28 µm](../../diagrams/drc-014.svg)

**In the deck.**

```text
rule <id> size(<layer>; allowed: [<length> x <length>, ...])
```

```text
grid 5nm
layer via = gds(68, 44)
rule via.1b size(via; allowed: [150nm x 150nm, 230nm x 230nm, 280nm x 280nm])
```

**Example violation.**

```text
rules:
  via.1b: ran, examined 2 shapes, found 1 violations
violations: 1
  via.1b error layer via at (1100 nm, 100 nm) measured 0 against limit 1 on shape 1
...
```

A 200 nm square via matches none of the three sizes; the 150 nm via beside it passes. The point is
the centre of the failing via.

**Options.**

| Parameter | Value | Meaning |
|---|---|---|
| `allowed` | list of `w x h` | The legal cut sizes, each either way round. |

**Status and limits.** Implemented. Spacing that depends on the cut class is a separate check, the
cut-class table on [Via and cut checks](cut.md).

**Sources.** SkyWater SKY130 rule via.1b; IHP SG13G2 rule CntB.a; LEF58 `CUTCLASS`.

### DRC-015: Allowed width set

**What it catches.** A shape whose width is not one of a fixed set of widths. Precision resistors
come in a few drawn widths that the models cover, and LEF width tables restrict routing to listed
widths.

**How GPurify measures it.** GPurify takes each shape's narrowest width, as the minimum-width check
measures it, and compares it exactly with the list. With `open_last: true`, the last width and
anything wider also pass. A shape off the list reports its width against the nearest listed width.

![A resistor 0.50 µm wide against the allowed widths 0.35, 0.69, 1.41, 2.85 and 5.73 µm](../../diagrams/drc-015.svg)

**In the deck.**

```text
rule <id> width(<layer>; allowed: [<length>, ...])
rule <id> width(<layer>; allowed: [<length>, ...], open_last: <bool>)
```

```text
grid 5nm
layer poly = gds(66, 20)
layer rpm  = gds(86, 20)
layer prec_res = poly and rpm
rule rpm.1b width(prec_res; allowed: [350nm, 690nm, 1410nm, 2850nm, 5730nm])
```

**Example violation.**

```text
rules:
  rpm.1b: ran, examined 1 shapes, found 1 violations
violations: 1
  rpm.1b error layer prec_res at (250 nm, 2000 nm) measured 500 nm against limit 350 nm on shape 2
...
```

A resistor 500 nm wide is none of the five widths; 350 nm is the nearest. The point is the centre of
the resistor.

**Options.**

| Parameter | Value | Meaning |
|---|---|---|
| `allowed` | list of lengths | The legal widths. |
| `open_last` | `true` or `false` | With `true`, the last width and any wider one are legal, as LEF58 `WIDTHTABLE` reads it. |

**Status and limits.** Partial. A shape with parts of several widths is judged by its narrowest part.
LEF58 `WIDTHTABLE`'s split of a shape into rectangles, its `WRONGDIRECTION` and `ORTHOGONAL` forms,
and ASAP7 M4.W.3 and M4.W.4 (no even multiple of the minimum width) are not checked: no public
source defines them.

**Sources.** SkyWater SKY130 rules rpm.1b to rpm.1f; ASAP7 rules M4.W.3 and M4.W.4; LEF58
`WIDTHTABLE`.

### DRC-016: Wrong-direction width and spacing

**What it catches.** A width or a gap measured in one direction only, such as the width of a
horizontal wire across its vertical edges. Gridded layers have different limits along and across
their preferred direction.

**How GPurify measures it.** You select the edges with `.horizontal()` or `.vertical()`. `width`
measures straight across between two parallel edges whose shapes lie toward each other.
`facing_space` measures between two parallel edges whose shapes face away from each other. Each
pair of edges is judged on its own.

![An M4 shape 40 nm wide between its vertical edges and a 30 nm gap to the next shape](../../diagrams/drc-016.svg)

**In the deck.**

```text
rule <id> width(<layer>.edges().vertical()) >= <length>
rule <id> facing_space(<layer>.edges().vertical()) >= <length>
rule <id> facing_space(<edge layer>; prl: <length>) >= <length>
```

```text
grid 1nm
layer M4 = gds(40, 0)
layer M4_v = M4.edges().vertical()
rule M4.W.5 width(M4_v) >= 44nm
rule M4.S.2 facing_space(M4_v) >= 40nm
```

**Example violation.**

```text
rules:
  M4.W.5: ran, examined 2 shapes, found 1 violations
  M4.S.2: ran, examined 1 shapes, found 1 violations
violations: 2
  M4.W.5 error layer M4_v at (20 nm, 12 nm) measured 40 nm against limit 44 nm
  M4.S.2 error layer M4_v at (55 nm, 12 nm) measured 30 nm against limit 40 nm
...
```

The first shape is 40 nm wide between its vertical edges, against 44 nm, and it is 30 nm from the
next shape, against 40 nm. Each point is halfway between the two edges.

**Options.**

| Parameter | Value | Meaning |
|---|---|---|
| `prl` | length | `facing_space` judges only pairs that run alongside each other for more than this. |

**Status and limits.** Partial. LEF58 wrong-direction spacing with `NONEOL` and `PRL` on a horizontal
layer is `facing_space(met1.edges().vertical().with_length(>= 150nm); prl: 100nm) >= 120nm`. Its
`LENGTH` qualifier and a negative `PRL` are not checked: no public text defines them.

**Sources.** ASAP7 rules M4.W.1, M4.W.5, M4.S.1 and M4.S.2; LEF58 `WIDTH WRONGDIRECTION` and
`SPACING WRONGDIRSPACING`; OpenROAD
[TritonRoute](https://openroad.readthedocs.io/en/latest/main/src/drt/README.html).

## Area

### DRC-017: Minimum area

**What it catches.** A shape whose area is below the limit. A small island of metal or implant
lifts off or does not print, and a via landing on it loses contact.

**How GPurify measures it.** GPurify measures the area of each shape, holes not counted, and reports
each shape below the limit once.

![A met1 shape 0.20 µm by 0.30 µm, 0.06 µm², against a 0.083 µm² minimum area](../../diagrams/drc-017.svg)

**In the deck.**

```text
rule <id> area(<layer>) >= <area>
```

```text
grid 5nm
layer met1 = gds(68, 20)
rule m1.6 area(met1) >= 0.083um2
```

**Example violation.**

```text
rules:
  m1.6: ran, examined 1 shapes, found 1 violations
violations: 1
  m1.6 error layer met1 at (100 nm, 150 nm) measured 60000 nm^2 against limit 83000 nm^2 on shape 0
...
```

A 200 nm by 300 nm shape has 0.06 µm² against 0.083 µm². The point is the centre of the shape's
first rectangle.

**Status and limits.** Implemented. The LEF58 `AREA` exceptions (`EXCEPTMINWIDTH`,
`EXCEPTRECTANGLE` and the rest) are not modelled.

**Sources.** SkyWater SKY130 rule m1.6; IHP SG13G2 rule M1.d; GlobalFoundries GF180MCU rule Mn.3;
ASAP7 rule M1.A.1; LEF/DEF 5.8 `AREA` and `LEF58_AREA`; KLayout `with_area`; Magic `area`; OpenROAD
TritonRoute.

### DRC-018: Maximum area

**What it catches.** A shape larger than the process allows, such as a MIM capacitor plate above its
largest qualified size. Large plates suffer from defects and stress, so foundries cap their area.

**How GPurify measures it.** You select the shapes above the area with `.with_area(> area)` and
forbid them. Every selected shape is reported with its area.

![A mim plate 80 µm by 80 µm, 6400 µm², over a 5625 µm² maximum area](../../diagrams/drc-018.svg)

**In the deck.**

```text
layer <big> = <layer>.with_area(> <area>)
rule <id> forbidden(<big>)
```

```text
grid 5nm
layer mim = gds(36, 0)
layer big_mim = mim.with_area(> 5625um2)
rule MIM.g forbidden(big_mim)
```

**Example violation.**

```text
rules:
  MIM.g: ran, examined 1 shapes, found 1 violations
violations: 1
  MIM.g error layer big_mim at (0 nm, 80000 nm) measured 6400000000 nm^2 against limit 0 nm^2 on shape 1
...
```

An 80 µm square plate has 6400 µm², over the 5625 µm² limit. A `forbidden` finding reports the
shape's area against 0, at a corner of the shape.

**Status and limits.** Expressible. The shipped IHP SG13G2 deck carries MIM.g this way, and the
GF180MCU deck carries MIMTM.8b.

**Sources.** IHP SG13G2 rules MIM.g, GFil.i and LBE.b1; SkyWater SKY130 rules capm.12 and pad.3.

### DRC-019: Minimum enclosed area

**What it catches.** A hole in a shape smaller than the limit. A small hole in metal or implant does
not open in lithography and leaves a defect, so foundries ask for a minimum hole area.

**How GPurify measures it.** GPurify measures each hole of each shape, after touching shapes merge.
A ring closed only at a corner encloses a hole too. Each small hole is reported at its centre.

![A met1 ring with a 0.30 µm by 0.30 µm hole, 0.09 µm², against a 0.14 µm² minimum](../../diagrams/drc-019.svg)

**In the deck.**

```text
rule <id> hole_area(<layer>) >= <area>
```

```text
grid 5nm
layer met1 = gds(68, 20)
rule m1.7 hole_area(met1) >= 0.14um2
```

**Example violation.**

```text
rules:
  m1.7: ran, examined 1 shapes, found 1 violations
violations: 1
  m1.7 error layer met1 at (500 nm, 500 nm) measured 90000 nm^2 against limit 140000 nm^2 on shape 0
...
```

A 300 nm square hole has 0.09 µm² against 0.14 µm². The point is the hole's centre. `examined`
counts holes.

**Status and limits.** Implemented. No known limits.

**Sources.** SkyWater SKY130 rule m1.7; IHP SG13G2 rule Act.e; GlobalFoundries GF180MCU rule DF.10;
LEF/DEF 5.8 `MINENCLOSEDAREA`; KLayout `holes`; OpenROAD TritonRoute.

## Edges and steps

### DRC-020: Minimum step and edge length

**What it catches.** Short edges along a shape's outline: a jog, a notch step or a staircase that
the mask writer and the router handle badly. LEF holds runs of short edges with `MINSTEP` and its
qualifiers, and some foundries set a plain minimum edge length.

**How GPurify measures it.** GPurify walks each outline of each shape and finds the edges shorter
than the limit. `edge_length` reports every such edge. `min_step` judges runs of consecutive short
edges by how many there are, by the corner or step they form between the long edges either side,
or by their neighbours. An end of line is neither a corner nor a step.

![A met1 staircase of four 0.10 µm edges in a row against a 0.14 µm step with at most one short edge](../../diagrams/drc-020.svg)

**In the deck.**

```text
rule <id> edge_length(<layer>) >= <length>
rule <id> min_step(<layer>; max_edges: <count>) >= <length>
rule <id> min_step(<layer>; corner: outside | inside | step, length_sum: <length> | none) >= <length>
rule <id> min_step(<layer>; adjacent: <length>, except_rectangle: <bool>) >= <length>
rule <id> min_step(<layer>; adjacent: <length>, adjacent_eol: <length>, except_rectangle: <bool>) >= <length>
rule <id> min_step(<layer>; between_eol: <length>) >= <length>
```

```text
grid 5nm
layer met1 = gds(68, 20)
rule m1.step min_step(met1; max_edges: 1) >= 140nm
```

**Example violation.**

```text
rules:
  m1.step: ran, examined 1 shapes, found 1 violations
violations: 1
  m1.step error layer met1 at (1900 nm, 1100 nm) measured 4 against limit 1 on shape 0
...
```

A staircase of four 100 nm edges in a row breaks a rule that allows one edge under 140 nm. The value
is the count of short edges, and the point is the centre of the staircase.

**Options.**

| Parameter | Value | Meaning |
|---|---|---|
| `max_edges` | count | More than this many short edges in a row fail (LEF `MAXEDGES`). |
| `corner` | `outside`, `inside` or `step` | Two or more short edges at an outside corner fail (`OUTSIDECORNER`), or at an inside corner (`INSIDECORNER`); one or more between two long edges running the same way fail (`STEP`). |
| `length_sum` | length or `none` | A run passes while its total length is at most this (`LENGTHSUM`). |
| `adjacent` | length | A short edge fails when the edge before or after it is shorter than this (LEF58 `MINADJACENTLENGTH`). |
| `adjacent_eol` | length | Also fails a short edge beside an end of line shorter than this (`NOADJACENTEOL`). |
| `except_rectangle` | `true` or `false` | With `true`, a rectangle is not checked (`EXCEPTRECTANGLE`). |
| `between_eol` | length | A short edge, an end of line shorter than this, then another short edge fail (`NOBETWEENEOL`). |

**Status and limits.** Partial. LEF58 `MINSTEP` follows OpenROAD TritonRoute, since no public LEF
text defines it. Its `CONVEXCORNER`, `CONCAVECORNER` and second `MINADJACENTLENGTH` length,
`MINBETWEENLENGTH` with `EXCEPTSAMECORNERS`, and `NOADJACENTEOL` without `MINADJACENTLENGTH` are not
checked: TritonRoute never checks them and no public text defines them.

**Sources.** LEF/DEF 5.8 `MINSTEP` and `MINSIZE`; LEF58 `MINSTEP`; GlobalFoundries GF180MCU rule
DF.11; Magic `area` with its minimum edge; OpenROAD
[TritonRoute](https://openroad.readthedocs.io/en/latest/main/src/drt/README.html).

### DRC-021: Feature length

**What it catches.** A feature shorter or longer than its rule, such as a resistor body below its
minimum length or a fuse of the wrong length. The length sets the resistance and the fuse's blow
current.

**How GPurify measures it.** A straight feature's length is the longer side of its bounding box,
selected with `.with_bbox_max(...)`. An edge's length is `length(E)` on an edge layer. Each selected
feature is reported with its area.

![A res shape 0.40 µm long against a 0.50 µm minimum length](../../diagrams/drc-021.svg)

**In the deck.**

```text
layer <short> = <layer>.with_bbox_max(< <length>)
rule <id> forbidden(<short>)
rule <id> length(<edge layer>) >= <length>
```

```text
grid 5nm
layer res = gds(24, 29)
layer short_res = res.with_bbox_max(< 500nm)
rule Rsil.f forbidden(short_res)
```

**Example violation.**

```text
rules:
  Rsil.f: ran, examined 1 shapes, found 1 violations
violations: 1
  Rsil.f error layer short_res at (0 nm, 400 nm) measured 160000 nm^2 against limit 0 nm^2 on shape 1
...
```

A 400 nm square resistor body is shorter than 500 nm. The finding gives its area, at a corner.

**Status and limits.** Partial. The length of a bent feature along its path has no public definition
and is not measured. IHP's own deck checks Rsil.f and Rppd.e as a width in every direction instead.

**Sources.** ASAP7 rule type L; IHP SG13G2 rules Rsil.f and Rppd.e; SkyWater SKY130 rule mf.2.

### DRC-022: Aspect ratio

**What it catches.** A shape far longer than it is wide, such as a long thin capacitor plate. A high
aspect ratio warps the plate's capacitance from the model, and the foundry caps it.

**How GPurify measures it.** GPurify takes each shape's bounding box and divides its longer side by
its shorter side, as KLayout's `with_bbox_aspect_ratio` does. Touching shapes count as one.

![A capm plate 1 µm by 25 µm, an aspect ratio of 25, against a maximum of 20](../../diagrams/drc-022.svg)

**In the deck.**

```text
rule <id> aspect_ratio(<layer>) <= <ratio>
```

```text
grid 5nm
layer capm = gds(89, 44)
rule capm.6 aspect_ratio(capm) <= 20
```

**Example violation.**

```text
rules:
  capm.6: ran, examined 1 shapes, found 1 violations
violations: 1
  capm.6 error layer capm at (500 nm, 12500 nm) measured 25 against limit 20 on shape 0
...
```

A plate 1 µm by 25 µm has a ratio of 25 against 20. The point is the centre of the plate's first
rectangle.

**Status and limits.** Implemented. The ratio is a bare number. An L-shaped plate is judged by its
bounding box.

**Sources.** SkyWater SKY130 rules capm.6 and li.2; KLayout `with_bbox_aspect_ratio`.

### DRC-125: Protrusion width

**What it catches.** A narrow stub sticking out of a wide wire. The stub etches and fills
differently from the wide metal it hangs off, so LEF asks for a wider minimum width there.

**How GPurify measures it.** GPurify finds the parts of each shape where no square of the limit
width fits, then keeps those that touch a part where a square of side `wide` fits. Each such stub
is reported once, with its narrowest width, at its centre.

![A met1 stub 0.20 µm wide on a 4 µm plate against a 0.30 µm protrusion width](../../diagrams/drc-125.svg)

**In the deck.**

```text
rule <id> protrusion_width(<layer>; wide: <length>) >= <length>
```

```text
grid 5nm
layer met1 = gds(68, 20)
rule m1.prot protrusion_width(met1; wide: 3um) >= 300nm
```

**Example violation.**

```text
rules:
  m1.prot: ran, examined 1 shapes, found 1 violations
violations: 1
  m1.prot error layer met1 at (4500 nm, 1100 nm) measured 200 nm against limit 300 nm on shape 1
...
```

A stub 200 nm wide on a 4 µm plate is under the 300 nm protrusion width. The point is the centre of
the stub.

**Options.**

| Parameter | Value | Meaning |
|---|---|---|
| `wide` | length | A part is wide where a square this size fits. Only stubs touching a wide part are held. |

**Status and limits.** Partial. This is LEF `PROTRUSIONWIDTH width1 LENGTH 0 WIDTH width2`. A
positive `LENGTH`, which exempts a long protrusion, is not checked: LEF/DEF 5.8 settles how to
measure it only by a figure, and OpenROAD stores the statement without checking it.

**Sources.** LEF/DEF 5.8 `PROTRUSIONWIDTH`.
