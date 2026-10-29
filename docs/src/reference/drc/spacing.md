# Spacing checks

These checks hold the gap between shapes, or between parts of one shape, to a limit. The limit
depends on the plain gap, on how wide the shapes are, how far they run side by side, or whether an
edge is a line end.

How a gap is measured, edge to edge and corner to corner, is in
[How GPurify measures](../../explanation/measuring.md).

## Basic spacing

### DRC-023: Same-layer spacing

**What it catches.** Two shapes on one layer closer than the limit. Shapes too close bridge in
lithography and etch, which shorts two nets.

**How GPurify measures it.** GPurify measures the least distance between the two shapes' outlines,
edge to edge where edges face each other and Euclidean between corners. Touching shapes are one
shape and have no gap; a gap inside one shape is a notch. Each pair of drawn polygons in different
shapes closer than the limit is one violation.

![Two met1 wires 0.10 µm apart against a 0.14 µm minimum space](../../diagrams/drc-023.svg)

**In the deck.**

```text
rule <id> space(<layer>) >= <length>
rule <id> space(<layer a>, <layer b>) >= <length>
```

```text
grid 5nm
layer met1 = gds(68, 20)
rule m1.2 space(met1) >= 140nm
```

**Example violation.**

```text
rules:
  m1.2: ran, examined 1 shapes, found 1 violations
violations: 1
  m1.2 error layer met1 at (250 nm, 1000 nm) measured 100 nm against limit 140 nm on shape 0 and shape 1
...
```

Two wires 100 nm apart break the 140 nm limit. The point is midway across the gap, at the middle of
the stretch where the wires face each other.

**Status and limits.** Implemented. A wire drawn as two touching polygons beside another wire
reports one violation for each polygon. Between two layers, overlapping or touching shapes measure
0. To measure only across facing edges, without corners, write
`space(<layer a>, <layer b>, projection)`.

**Sources.** SkyWater SKY130 rule m1.2; IHP SG13G2 rule M1.b; GlobalFoundries GF180MCU rule Mn.2a;
ASAP7 rule M1.S.1; LEF/DEF 5.8 `SPACING`; KLayout
[`space`](https://www.klayout.de/doc/about/drc_ref_layer.html); Magic `spacing`; OpenROAD
[TritonRoute](https://openroad.readthedocs.io/en/latest/main/src/drt/README.html).

### DRC-024: Notch

**What it catches.** A gap between two parts of the same shape narrower than the limit, such as the
slot of a U. The slot fills in during lithography just as a gap between two shapes does.

**How GPurify measures it.** GPurify measures between two parallel edges of one shape that face each
other across empty space and overlap along their length. Each shape is reported once, at its
narrowest notch.

![A met1 U-shape with a 0.10 µm slot against a 0.14 µm minimum notch](../../diagrams/drc-024.svg)

**In the deck.**

```text
rule <id> notch(<layer>) >= <length>
```

```text
grid 5nm
layer met1 = gds(68, 20)
rule m1.2.notch notch(met1) >= 140nm
```

**Example violation.**

```text
rules:
  m1.2.notch: ran, examined 1 shapes, found 1 violations
violations: 1
  m1.2.notch error layer met1 at (350 nm, 1250 nm) measured 100 nm against limit 140 nm on shape 0
...
```

The slot of a U-shaped wire is 100 nm wide against 140 nm. The point is the middle of the slot.

**Status and limits.** Implemented. Pair every `space` rule with a `notch` rule of the same limit to
cover the foundry's spacing in full. Two shapes that touch only at a corner are one shape, so the
gap between their other parts is a notch.

**Sources.** SkyWater SKY130 rule x.6; IHP SG13G2 rule M1.b; LEF/DEF 5.8 `NOTCHLENGTH` and
`ENDOFNOTCHWIDTH`; KLayout `notch`.

## Width and run length

### DRC-025: Wide-metal spacing

**What it catches.** A shape too close to a wide part of another shape. Wide metal etches and
polishes differently, so the foundry asks for more space next to it than between narrow wires.

**How GPurify measures it.** GPurify finds the wide part of each shape, where a square of side
`width` fits. It measures from that part to other shapes, edge to edge and Euclidean at corners. A
thin tab of a wide plate is not wide.

![A met1 wire 0.20 µm from a 4 µm plate against a 0.28 µm wide-metal space](../../diagrams/drc-025.svg)

**In the deck.**

```text
rule <id> wide_space(<layer>; width: <length>) >= <length>
rule <id> space_table(<layer>; prl: [<length>, ...], width: [<length>, ...], space: [[<length>, ...], ...])
```

```text
grid 5nm
layer met1 = gds(68, 20)
rule m1.3b wide_space(met1; width: 3um) >= 280nm
```

**Example violation.**

```text
rules:
  m1.3b: ran, examined 1 shapes, found 1 violations
violations: 1
  m1.3b error layer met1 at (4100 nm, 2000 nm) measured 200 nm against limit 280 nm on shape 0 and shape 1
...
```

A wire 200 nm from a 4 µm plate breaks the 280 nm limit. The point is midway across the gap.

**Options.**

| Parameter | Value | Meaning |
|---|---|---|
| `width` | length | A part is wide where a square this size fits, so a part exactly this wide is wide. |

**Status and limits.** Implemented. For a foundry rule written "wider than 3 µm", write the next grid
step, `width: 3005nm` on a 5 nm grid. A width and run-length table is `space_table`, described under
[DRC-026](#drc-026-parallel-run-length-spacing).

**Sources.** SkyWater SKY130 rules m1.3b and m3.3c; IHP SG13G2 rules M1.e and M1.f; GlobalFoundries
GF180MCU rule Mn.2b; LEF/DEF 5.8 `SPACING RANGE` and `SPACINGTABLE`; Magic `widespacing`; OpenROAD
TritonRoute.

### DRC-026: Parallel-run-length spacing

**What it catches.** Two wires that run side by side for a long stretch closer than the limit for
that run. A long parallel run couples more and bridges more easily, so LEF and the foundries ask
for more space as the run and the wire width grow.

**How GPurify measures it.** The run is how far the facing edges of the two shapes project onto each
other, counting only edges at most the cell's space apart. Touching shapes merge first, so a wire
drawn as segments runs its whole length. In a table, the row is the last width the wider shape
exceeds and the column the last run the pair exceeds; "exceeds" is strict.

![A 0.40 µm and a 0.20 µm metal1 wire 0.20 µm apart over a 2 µm run, against the 0.22 µm table cell](../../diagrams/drc-026.svg)

**In the deck.**

```text
rule <id> prl_space(<layer>; prl: <length>) >= <length>
rule <id> space_table(<layer>; prl: [<length>, ...], width: [<length>, ...], space: [[<length>, ...], ...])
```

```text
grid 5nm
layer metal1 = gds(8, 0)
rule M1.bef space_table(metal1;
    prl:   [0um, 1um, 10um],
    width: [0um, 0.3um, 10um],
    space: [[180nm, 180nm, 180nm],
            [180nm, 220nm, 220nm],
            [180nm, 220nm, 600nm]])
```

**Example violation.**

```text
rules:
  M1.bef: ran, examined 1 shapes, found 1 violations
violations: 1
  M1.bef error layer metal1 at (500 nm, 1000 nm) measured 200 nm against limit 220 nm on shape 0 and shape 1
...
```

A 400 nm wire, wider than 0.3 µm, runs 2 µm beside another, more than 1 µm, so the pair needs
220 nm; it has 200 nm. The point is midway across the gap.

**Options.**

| Parameter | Value | Meaning |
|---|---|---|
| `prl` (in `prl_space`) | length | Only pairs that run alongside each other for at least this are held. |
| `prl` (in `space_table`) | list of lengths | The run lengths heading the columns: from 0, rising. |
| `width` | list of lengths | The widths heading the rows: from 0, rising. A row's width is measured on the part of the shape that wide. |
| `space` | rows of lengths | One row per width, one cell per run length; no cell is smaller than the one before it in its row or column. |

**Status and limits.** Implemented. No known limits.

**Sources.** LEF/DEF 5.8 `SPACINGTABLE PARALLELRUNLENGTH`; IHP SG13G2 rules M1.b, M1.e, M1.f and
CntB.b1; Magic `widespacing` with run length; KLayout `projection`.

### DRC-027: Two-widths spacing table

**What it catches.** Two shapes closer than the space their two widths ask for together. LEF
`SPACINGTABLE TWOWIDTHS` sets the space by the widths of both shapes, not only the wider, and a
width also sets a minimum run.

**How GPurify measures it.** The widths head both the rows and the columns. A width applies to a
shape strictly wider than it, when the pair's run exceeds that width's `prl` (`none` asks for no
run). The pair needs the cell at the last width that applies to each shape, measured between the
parts that wide.

![Two met2 wires 0.30 µm wide and 0.22 µm apart against the 0.25 µm cell for two widths over 0.25 µm](../../diagrams/drc-027.svg)

**In the deck.**

```text
rule <id> two_width_table(<layer>; width: [<length>, ...], prl: [none | <length>, ...], space: [[<length>, ...], ...])
```

```text
grid 5nm
layer met2 = gds(69, 20)
rule M2.S two_width_table(met2;
    width: [0nm, 250nm, 1500nm, 3000nm],
    prl:   [none, 0nm, 1500nm, 3000nm],
    space: [[150nm, 200nm, 500nm, 1000nm],
            [200nm, 250nm, 500nm, 1000nm],
            [500nm, 500nm, 600nm, 1000nm],
            [1000nm, 1000nm, 1000nm, 1200nm]])
```

**Example violation.**

```text
rules:
  M2.S: ran, examined 1 shapes, found 1 violations
violations: 1
  M2.S error layer met2 at (410 nm, 1000 nm) measured 220 nm against limit 250 nm on shape 0 and shape 1
...
```

Two wires 300 nm wide, both over 250 nm, need 250 nm; they are 220 nm apart. The point is midway
across the gap.

**Options.**

| Parameter | Value | Meaning |
|---|---|---|
| `width` | list of lengths | The widths heading both rows and columns, from 0, rising. |
| `prl` | list of lengths or `none` | Per width, the run the pair must exceed for it to apply; the first is `none`. |
| `space` | rows of lengths | A symmetric table, every cell positive, no cell falling along its row. |

**Status and limits.** Partial. A negative `PRL` and the LEF58 `SPACINGTABLE` qualifiers
`WRONGDIRECTION`, `SAMEMASK`, `EXCEPTEOL` and `EXCEPTWITHIN` are not checked: no public text defines
them.

**Sources.** LEF/DEF 5.8 `SPACINGTABLE TWOWIDTHS`; LEF58 `SPACINGTABLE`; OpenROAD TritonRoute.

### DRC-028: Influence spacing near wide metal

**What it catches.** A wire too close to a stub that leaves a wide plate. The stub is close enough to
the plate to etch like it, so the foundry holds it to the plate's spacing for a short distance.

**How GPurify measures it.** GPurify finds the parts of each shape where a square of side `width`
fits. It grows those parts by `attached` within the shape, square at the corners, then measures
spacing from the result, edge to edge and Euclidean at corners.

![A met1 wire 0.20 µm from a stub within 0.28 µm of a 4 µm plate, against a 0.28 µm space](../../diagrams/drc-028.svg)

**In the deck.**

```text
rule <id> wide_space(<layer>; width: <length>, attached: <length>) >= <length>
```

```text
grid 5nm
layer met1 = gds(68, 20)
rule m1.3a wide_space(met1; width: 3um, attached: 280nm) >= 280nm
```

**Example violation.**

```text
rules:
  m1.3a: ran, examined 2 shapes, found 1 violations
violations: 1
  m1.3a error layer met1 at (4280 nm, 1300 nm) measured 200 nm against limit 280 nm on shape 1 and shape 2
...
```

A wire runs 200 nm above a stub that leaves a 4 µm plate. The first 280 nm of the stub counts as
wide, so the wire breaks the 280 nm limit there. The point is midway across the gap.

**Options.**

| Parameter | Value | Meaning |
|---|---|---|
| `width` | length | A part is wide where a square this size fits. |
| `attached` | length | How far from the wide part a stub still counts as wide. |

**Status and limits.** Partial. The stub-width `RANGE` form and the two-stub `SPACINGTABLE INFLUENCE`
form are not checked. Near a wide corner, the square growth flags a little more than the foundry
rule does: a false violation, never a missed one. See
[issue 2](https://github.com/OpenFAT/GPurify/issues/2).

**Sources.** SkyWater SKY130 rule m1.3a; LEF/DEF 5.8 `SPACING RANGE INFLUENCE` and
`SPACINGTABLE INFLUENCE`; OpenROAD TritonRoute.

## Line ends and corners

### DRC-029: End-of-line spacing

**What it catches.** A shape too close to the end of a narrow line. Line ends shorten and round in
lithography, and the space in front of them bridges more easily than space along a side.

**How GPurify measures it.** An end of line is an edge shorter than `eol_width`. In the plain form,
GPurify measures from the end to any other shape in front of it, Euclidean. In the LEF form, the end
must also have both corners convex, and its keep-out reaches the limit out from the end and
`within` past each of its sides; an edge of another shape inside it is measured by its depth from
the end's line.

![A met2 line end 0.08 µm wide, 0.08 µm from a crossing wire, against a 0.10 µm end-of-line space](../../diagrams/drc-029.svg)

**In the deck.**

```text
rule <id> eol_space(<layer>; eol_width: <length>) >= <length>
rule <id> eol_space(<layer>; eol_width: <length>, within: <length>,
    parallel: none | (space: <length>, within: <length>, two_edges: <bool>),
    end_to_end: none | <length>) >= <length>
rule <id> eol_space(<layer>; eol_width: <length>, within: <length>, parallel: ..., end_to_end: ...,
    side_length: none | (length: <length>, maximum: <bool>, two_sides: <bool>),
    opposite_width: none | <length>,
    parallel_more: none | (subtract_eol_width: <bool>, min_length: none | <length>),
    end_prl: none | (space: <length>, prl: <length>),
    wrong_dir: none | (space: <length>, horizontal: <bool>),
    extension: none | <length>,
    enclose_cut: none | (cut: <layer>, within: <length>, space: <length>, all_cuts: <bool>)) >= <length>
```

```text
grid 5nm
layer met2 = gds(69, 20)
rule M2.eol eol_space(met2; eol_width: 90nm, within: 25nm, parallel: none, end_to_end: none) >= 100nm
```

**Example violation.**

```text
rules:
  M2.eol: ran, examined 4 shapes, found 1 violations
violations: 1
  M2.eol error layer met2 at (40 nm, 1040 nm) measured 80 nm against limit 100 nm on shape 1 and shape 0
...
```

The 80 nm end of a vertical wire is 80 nm below a crossing wire, against 100 nm. The point is
midway between the end and the wire. `examined` counts line ends.

**Options.**

| Parameter | Value | Meaning |
|---|---|---|
| `eol_width` | length | An edge shorter than this is an end of line. |
| `within` | length | How far past each side of the end the keep-out reaches (LEF `WITHIN`). |
| `parallel` | group or `none` | The end applies only beside a parallel edge less than `space` from its side, within `within` behind it (`PARALLELEDGE`); `two_edges: true` needs one on both sides (`TWOEDGES`). |
| `end_to_end` | length or `none` | Two ends facing each other need this space instead (LEF58 `ENDTOEND`). |
| `side_length` | group or `none` | The end applies only when a side edge meeting it is at least `length` (at most, with `maximum: true`), both sides with `two_sides` (`MINLENGTH`, `MAXLENGTH`, `TWOSIDES`). |
| `opposite_width` | length or `none` | A facing edge counts only where the wire beyond it is narrower than this (`OPPOSITEWIDTH`). |
| `parallel_more` | group or `none` | The parallel-edge search shrinks by the end's length (`SUBTRACTEOLWIDTH`); a side shorter than `min_length` has no parallel edge (`PARALLELEDGE ... MINLENGTH`). |
| `end_prl` | group or `none` | Past the end's own space and closer than `space`, an edge running along the end for at most `prl` fails too (`ENDPRLSPACING`). |
| `wrong_dir` | group or `none` | An end along the preferred direction (`horizontal` or vertical) needs `space` (`WRONGDIRSPACING`). |
| `extension` | length or `none` | Two facing ends pair where their spans, widened by this, overlap (`ENDTOEND ... EXTENSION`). |
| `enclose_cut` | group or `none` | A pair fails only beside a cut on `cut` less than `within` behind the end and less than `space` from the facing edge; `all_cuts: true` asks it of every such cut (`ENCLOSECUT`, `ALLCUTS`). |

**Status and limits.** Partial. The qualifiers follow the LEF/DEF 5.7 text where it defines them,
and OpenROAD TritonRoute where it does not. `TWOSIDES` and the pairing of two ends by the widened
span follow the text, which differs from TritonRoute. Not checked: `OTHERENDWIDTH`,
`EQUALRECTWIDTH`, `EXACTWIDTH`, `SAMEMASK`, `EXCEPTEXACTWIDTH`, `FILLCONCAVECORNER`, `WITHCUT`,
`TOCONCAVECORNER`, `TONOTCHLENGTH`, the `ENDTOEND` cut spaces and wrong-direction extension, the
wrong-direction `WITHIN`, the parallel edge's PRL, `SAMEMETAL`, `NONEOLCORNERONLY` and
`PARALLELSAMEMASK`. No public text defines them, and TritonRoute does not check them.

**Sources.** LEF/DEF 5.8 `SPACING ENDOFLINE ... PARALLELEDGE ... TWOEDGES`; LEF58 `SPACING
ENDOFLINE`; ASAP7 rules M1.S.2 to M1.S.5; ISPD 2019 contest; OpenROAD
[TritonRoute](https://openroad.readthedocs.io/en/latest/main/src/drt/README.html).

### DRC-030: End-of-line keep-out and extension spacing

**What it catches.** Another shape inside the box an end of line keeps clear, or too close to the end
once it is extended. Advanced nodes keep a zone around each line end free so the end prints and
the cut that trims it lands.

**How GPurify measures it.** `eol_keep_out` builds a box round each end of line: the end widened by
`side` each way, from `backward` behind its line to `forward` past it. Any other shape with area
inside the box fails, reported with that area; touching the box is not inside it.
`eol_extension_space` sweeps each end out of its shape by its row's `extension`, then measures from
that box to the edges of other shapes, Euclidean.

![A met2 line end with its keep-out box 0.05 µm to each side and 0.15 µm forward, entered by a wire](../../diagrams/drc-030.svg)

**In the deck.**

```text
rule <id> eol_keep_out(<layer>; eol_width: <length>, backward: <length>, side: <length>, forward: <length>)
rule <id> eol_keep_out(<layer>; eol_width: <length>, backward: <length>, side: <length>, forward: <length>,
    except_within: none | (low: <length>, high: <length>), corner_only: <bool>)
rule <id> eol_extension_space(<layer>; eol_width: [<length>, ...], extension: [<length>, ...],
    end_to_end: [none | <length>, ...], side_length: none | (length: <length>, two_sides: <bool>)) >= <length>
```

```text
grid 5nm
layer met2 = gds(69, 20)
rule M2.keepout eol_keep_out(met2; eol_width: 90nm, backward: 0nm, side: 50nm, forward: 150nm)
```

**Example violation.**

```text
rules:
  M2.keepout: ran, examined 4 shapes, found 1 violations
violations: 1
  M2.keepout error layer met2 at (115 nm, 1090 nm) measured 2400 nm^2 against limit 0 nm^2 on shape 0 and shape 1
...
```

A wire reaches 30 nm by 80 nm into the keep-out box of an 80 nm line end: 2400 nm² inside. The
point is the centre of the part inside the box.

The extension form, with the end swept 50 nm and a wire 100 nm past the end:

```text
grid 5nm
layer met2 = gds(69, 20)
rule M2.eolext eol_extension_space(met2; eol_width: [90nm], extension: [50nm], end_to_end: [none], side_length: none) >= 100nm
```

```text
rules:
  M2.eolext: ran, examined 4 shapes, found 1 violations
violations: 1
  M2.eolext error layer met2 at (40 nm, 1075 nm) measured 50 nm against limit 100 nm on shape 0 and shape 1
...
```

**Options.**

| Parameter | Value | Meaning |
|---|---|---|
| `eol_width` | length (keep-out) or list (extension) | An edge shorter than this, with both corners convex, is an end of line. In the extension form, one width per row, rising; an end takes the first row whose width exceeds it. |
| `backward`, `side`, `forward` | length | The keep-out box: behind the end's line, past each side, and in front. |
| `except_within` | group or `none` | A shape reaching with area into a zone beside either corner of the end, from `low` to `high` past it, is exempt (`EXCEPTWITHIN`). |
| `corner_only` | `true` or `false` | With `true`, only a shape with a corner strictly inside the box intrudes, reported with the count of such corners (`CORNERONLY`). |
| `extension` | list of lengths | Per row, how far the end is swept out of its shape. |
| `end_to_end` | list of lengths or `none` | Per row, the sweep used when two ends face each other head on. |
| `side_length` | group or `none` | The end applies only when a side meeting it is at least `length`, both with `two_sides` (`MINLENGTH`, `TWOSIDES`). |

**Status and limits.** Partial. `LEF58_EOLKEEPOUT` follows OpenROAD TritonRoute, since no public text
defines it; TritonRoute exempts per rectangle and GPurify per shape. `LEF58_EOLEXTENSIONSPACING`
follows the LEF/DEF 5.7 text, with TritonRoute's reading where the text is silent; `ENDTOEND` and
`MINLENGTH` follow the text, which TritonRoute ignores. The keep-out's `CLASS` is not checked.

**Sources.** LEF58 `EOLEXTENSIONSPACING` and `EOLKEEPOUT`; OpenROAD TritonRoute.

### DRC-031: Tip-to-tip and tip-to-side spacing

**What it catches.** Two facing edges closer than the space their lengths ask for. A line end (a
tip) shortens in lithography, so ASAP7 asks for more room tip to tip than side to side.

**How GPurify measures it.** Two edges of different shapes face each other when they are parallel,
each faces away from its own shape, and they overlap along their length; the gap is the distance
between them. Each edge's class is the last `length` it reaches, and the pair needs the cell at its
two classes. Touching shapes merge first, so a line end drawn as two strips is one end.

![Two M1 tips 18 nm long, 25 nm apart, against the 31 nm tip-to-tip cell](../../diagrams/drc-031.svg)

**In the deck.**

```text
rule <id> tip_space_table(<layer>; length: [<length>, ...], space: [[<length>, ...], ...])
```

```text
grid 1nm
layer M1 = gds(19, 0)
rule M1.S tip_space_table(M1;
    length: [0nm, 24nm, 37nm],
    space:  [[31nm, 31nm, 25nm],
             [31nm, 27nm, 25nm],
             [25nm, 25nm, 18nm]])
```

**Example violation.**

```text
rules:
  M1.S: ran, examined 1 shapes, found 1 violations
violations: 1
  M1.S error layer M1 at (212 nm, 9 nm) measured 25 nm against limit 31 nm on shape 0 and shape 1
...
```

Two lines 18 nm wide end 25 nm apart. Both tips are under 24 nm, so the pair needs 31 nm. The point
is midway across the gap.

**Options.**

| Parameter | Value | Meaning |
|---|---|---|
| `length` | list of lengths | The class thresholds, from 0, rising: an edge is in the last class it reaches. |
| `space` | rows of lengths | One row and one column per class, symmetric. |

**Status and limits.** Partial. ASAP7 M4.S.3, tip to tip on adjacent tracks with no common run, is
`corner_space(met4; corner_to_corner: false, except_eol: none) >= 40nm`; see
[DRC-032](#drc-032-corner-spacing). M4.S.4, tip to tip on adjacent tracks that share a run, is not
checked: the manual leaves it undefined. Edges that meet only at a diagonal do not face.

**Sources.** ASAP7 rules M1.S.1 to M1.S.5, M4.S.3 and M4.S.4.

### DRC-032: Corner spacing

**What it catches.** Two shapes whose convex corners face each other too closely across a diagonal.
Corners round in lithography and bridge diagonally, so foundries and LEF hold corner-to-corner
gaps.

**How GPurify measures it.** GPurify pairs convex corners of different shapes that each lie beyond
the other on both axes. `corner_space(L)` measures them Euclidean. The LEF58 form measures the
larger of the two axis gaps, or Euclidean with `corner_to_corner: true`, and exempts the corners of
a line end shorter than `except_eol`.

![Two M1 shapes with corners 30 nm and 40 nm apart on the two axes, against a 50 nm corner space](../../diagrams/drc-032.svg)

**In the deck.**

```text
rule <id> corner_space(<layer>) >= <length>
rule <id> corner_space(<layer>; corner_to_corner: <bool>, except_eol: none | <length>) >= <length>
```

```text
grid 1nm
layer M1 = gds(19, 0)
rule M1.S.6 corner_space(M1; corner_to_corner: false, except_eol: none) >= 50nm
```

**Example violation.**

```text
rules:
  M1.S.6: ran, examined 1 shapes, found 1 violations
violations: 1
  M1.S.6 error layer M1 at (115 nm, 120 nm) measured 40 nm against limit 50 nm on shape 0 and shape 1
...
```

The corners are 30 nm apart across x and 40 nm across y. The larger gap, 40 nm, breaks the 50 nm
limit. The point is midway between the corners. With `corner_to_corner: true` the same pair measures
50 nm, the Euclidean distance.

**Options.**

| Parameter | Value | Meaning |
|---|---|---|
| `corner_to_corner` | `true` or `false` | With `true`, the Euclidean distance (`CORNERTOCORNER`); else the larger axis gap. |
| `except_eol` | length or `none` | A corner of a line end shorter than this, on either shape, is exempt (`EXCEPTEOL`). |

**Status and limits.** Partial. `CONCAVECORNER`, the `WIDTH` table and the `SAMEMASK`, `CORNERONLY`,
`EXCEPTJOGLENGTH` and `EXCEPTSAMENET` qualifiers are not checked. The shipped sky130 deck's poly.4
over-reports. See [issue 3](https://github.com/OpenFAT/GPurify/issues/3).

**Sources.** LEF58 `CORNERSPACING`; ASAP7 rule M1.S.6; GlobalFoundries GF180MCU rule MT30.3; ISPD 2019
contest; KLayout `corners`; OpenROAD TritonRoute.

## Ranges, pitch and spans

### DRC-033: Forbidden spacing range

**What it catches.** Two wires whose gap falls inside a range the process cannot print, though both
narrower and wider gaps are legal. Some pitches resonate badly with the lithography's illumination,
so LEF58 forbids a band of spacings.

**How GPurify measures it.** GPurify pairs facing edges of different shapes, as the tip table does,
that run alongside each other for more than `prl`. A gap from `min` to `max`, both included, fails.
A narrower gap is for `space` to judge.

![Two met2 wires 0.12 µm apart over a 1 µm run, inside the forbidden range 0.10 µm to 0.15 µm](../../diagrams/drc-033.svg)

**In the deck.**

```text
rule <id> forbidden_space(<layer>; min: <length>, max: <length>, prl: <length>)
```

```text
grid 5nm
layer met2 = gds(69, 20)
rule M2.fs forbidden_space(met2; min: 100nm, max: 150nm, prl: 200nm)
```

**Example violation.**

```text
rules:
  M2.fs: ran, examined 1 shapes, found 1 violations
violations: 1
  M2.fs error layer met2 at (160 nm, 500 nm) measured 120 nm against limit 150 nm on shape 0 and shape 1
...
```

Two wires 120 nm apart over a 1 µm run sit inside the forbidden range of 100 nm to 150 nm. The limit
is the range's upper end; the point is midway across the gap.

**Options.**

| Parameter | Value | Meaning |
|---|---|---|
| `min`, `max` | length | The forbidden gaps, both ends included. |
| `prl` | length | Only edges running alongside each other for more than this are held. |

**Status and limits.** Partial. This is LEF58 `TWOWIRESFORBIDDENSPACING` as OpenROAD TritonRoute
reads it. Its `MINSPANLENGTH` and `MAXSPANLENGTH`, LEF58 `FORBIDDENSPACING`'s `WIDTH`, `WITHIN` and
`TWOEDGES`, and a preferred direction are not checked. See
[issue 4](https://github.com/OpenFAT/GPurify/issues/4).

**Sources.** LEF58 `FORBIDDENSPACING` and `TWOWIRESFORBIDDENSPACING`; OpenROAD TritonRoute.

### DRC-034: Maximum spacing

**What it catches.** A cut with no other cut near it. A lonely via is a reliability and yield risk,
so LEF58 asks every via of a class to have a neighbour within a distance.

**How GPurify measures it.** For each cut, GPurify looks for another cut whose centre is within the
limit of its own, centre to centre, the limit included. A cut with none fails and reports the
distance to its nearest neighbour. With two layers, the cuts of the first layer look for neighbours
among all cuts of the second.

![A via1 cut 4 µm from its nearest neighbour, against a 2 µm maximum spacing](../../diagrams/drc-034.svg)

**In the deck.**

```text
rule <id> max_space(<cut layer>) <= <length>
rule <id> max_space(<cut class layer>, <cut layer>) <= <length>
```

```text
grid 5nm
layer via1 = gds(68, 44)
rule V1.maxs max_space(via1) <= 2um
```

**Example violation.**

```text
rules:
  V1.maxs: ran, examined 3 shapes, found 1 violations
violations: 1
  V1.maxs error layer via1 at (5075 nm, 75 nm) measured 4000 nm against limit 2000 nm on shape 2
...
```

The third cut's nearest neighbour is 4 µm away, centre to centre, against 2 µm. The point is the
cut's centre.

**Status and limits.** Partial. This is LEF58 `MAXSPACING` as OpenROAD's router reads it; no public
LEF text defines it. A maximum spacing between wires on a routing layer has no public source and is
not checked.

**Sources.** LEF58 `MAXSPACING`; OpenROAD TritonRoute.

### DRC-035: Exact pitch

**What it catches.** Neighbouring lines whose centre lines are not exactly the pitch apart. Fins and
gates at advanced nodes sit on a fixed grid; a line off the pitch does not print.

**How GPurify measures it.** Every shape must be a rectangle, or the rule is refused. For each
rectangle, GPurify takes the nearest rectangles past it on the axis that overlap it across, and
compares the distance between their centre lines with the pitch. A missing line between two is a
pitch of twice the limit.

![Three FIN lines whose centre lines are 27 nm and 30 nm apart, against an exact 27 nm pitch](../../diagrams/drc-035.svg)

**In the deck.**

```text
rule <id> pitch(<layer>, vertical) == <length>
rule <id> pitch(<layer>, horizontal) == <length>
```

```text
grid 1nm
layer FIN = gds(2, 0)
rule FIN.S.1 pitch(FIN, vertical) == 27nm
```

**Example violation.**

```text
rules:
  FIN.S.1: ran, examined 2 shapes, found 1 violations
violations: 1
  FIN.S.1 error layer FIN at (250 nm, 45 nm) measured 30 nm against limit 27 nm on shape 1 and shape 2
...
```

The second and third fins are 30 nm apart, centre to centre, against an exact 27 nm. The point is
midway between their centre lines.

**Status and limits.** Partial. Track grids (LEF `PITCH`, LEF58 `PITCH`,
`RIGHTWAYONGRIDONLY`) are not checked. See [issue 5](https://github.com/OpenFAT/GPurify/issues/5).

**Sources.** ASAP7 rules FIN.S.1 and GATE.S.1; LEF/DEF 5.8 `PITCH`; LEF58 `PITCH` and
`RIGHTWAYONGRIDONLY`; OpenROAD TritonRoute.

### DRC-036: Span-length table

**What it catches.** A shape whose span, the length of material a horizontal or vertical line cuts
through it, is not one of the legal lengths. Gridded layers allow only a few wire widths and
lengths.

**How GPurify measures it.** GPurify cuts each shape with every horizontal line (the `x` list) and
every vertical line (the `y` list). Each span length must be on its list: every length but the last
exactly, the last and anything longer. Each region where the span stays the same is reported once,
against the shortest legal span above it.

![A met1 shape 0.30 µm wide whose horizontal span is not in the list 0.10, 0.20 and at least 0.40 µm](../../diagrams/drc-036.svg)

**In the deck.**

```text
rule <id> span_length(<layer>; x: [<length>, ...], y: [<length>, ...])
rule <id> span_length(<layer>; x: [<length>, ...], y: [<length>, ...], x_except: none | <length>, y_except: none | <length>)
```

```text
grid 5nm
layer met1 = gds(68, 20)
rule M1.span span_length(met1; x: [100nm, 200nm, 400nm], y: [100nm, 200nm, 400nm])
```

**Example violation.**

```text
rules:
  M1.span: ran, examined 2 shapes, found 1 violations
violations: 1
  M1.span error layer met1 at (150 nm, 1000 nm) measured 300 nm against limit 400 nm on shape 0
...
```

A shape 300 nm wide has a horizontal span of 300 nm, which is neither 100 nm, 200 nm nor at least
400 nm. Its vertical span, 2 µm, is legal. `examined` counts span regions on both axes.

**Options.**

| Parameter | Value | Meaning |
|---|---|---|
| `x` | list of lengths | Legal horizontal spans. For a LEF layer with `DIRECTION HORIZONTAL`, this is the `WRONGDIRECTION` table. |
| `y` | list of lengths | Legal vertical spans. For a horizontal LEF layer, this is the `SPANLENGTHTABLE`. |
| `x_except`, `y_except` | length or `none` | A rectangle's span is held only when its span the other way exceeds this (`EXCEPTOTHERSPAN`). |

**Status and limits.** Partial. `EXCEPTOTHERSPAN` applies to rectangles; any other shape is held with
no exception, since LEF defines the exception only on a `RECTONLY` layer. `ORTHOGONAL` is not
checked: LEF/DEF 5.8 leaves its measure undefined.

**Sources.** LEF58 `SPANLENGTHTABLE`.

## Angled shapes

### DRC-037: Bent and 45° features

**What it catches.** A width, gap or area on a shape with 45° edges, such as a bent wire, that
breaks its limit. A 45° bend narrows the wire's perpendicular width, and foundries set separate
limits for it.

**How GPurify measures it.** `width`, `notch`, `space`, `area`, `hole_area` and `edge_length`
measure 45° shapes exactly: a distance to a 45° edge is compared exactly and reported floored. A
corner sharper than 90° has a width of 0. `angle` checks that every edge runs at an allowed angle.
Every other check refuses a layer with an edge that is not horizontal or vertical.

![A metal1 wire 0.20 µm wide bending through a 45° segment only 0.14 µm wide](../../diagrams/drc-037.svg)

**In the deck.**

```text
rule <id> width(<layer>) >= <length>
rule <id> angle(<layer>; allowed: [0deg, 45deg, 90deg, 135deg])
```

```text
grid 5nm
layer metal1 = gds(8, 0)
rule M1.g width(metal1) >= 200nm
```

**Example violation.**

```text
rules:
  M1.g: ran, examined 1 shapes, found 1 violations
violations: 1
  M1.g error layer metal1 at (1050 nm, 150 nm) measured 141 nm against limit 200 nm on shape 0
...
```

The 45° segment of a 200 nm wire is 200/√2 ≈ 141.4 nm wide, floored to 141 nm, against 200 nm.

> [!WARNING]
> A rule refused on a layer with angled edges looked at nothing. Read the refused count before the
> violation count.

**Status and limits.** Partial. Edges at angles other than 45° are measured by `width`, `notch`,
`space`, `area`, `hole_area` and `edge_length` too. Every other geometric check is refused on a
non-rectilinear layer. See [issue 21](https://github.com/OpenFAT/GPurify/issues/21).

**Sources.** IHP SG13G2 rules M1.g, Mn.g and Gat.g; GlobalFoundries GF180MCU rules PL.7 and MT30.4;
SkyWater SKY130 rule via.14a.

### DRC-038: Diagonal width and spacing

**What it catches.** Two 45° edges closer than the limit, across a wire or between wires. LEF and IHP
state separate diagonal limits because a diagonal gap prints differently from an orthogonal one.

**How GPurify measures it.** GPurify measures between 45° edges exactly, Euclidean, square to the
edges. An axis edge and a 45° edge at 135° to each other are paired as KLayout's Euclidean width
pairs them.

![Two parallel metal1 strips at 45° whose edges are 0.177 µm apart, against a 0.22 µm minimum](../../diagrams/drc-038.svg)

**In the deck.**

```text
rule <id> space(<layer>) >= <length>
rule <id> width(<layer>) >= <length>
```

```text
grid 5nm
layer metal1 = gds(8, 0)
rule M1.i space(metal1) >= 220nm
```

**Example violation.**

```text
rules:
  M1.i: ran, examined 1 shapes, found 1 violations
violations: 1
  M1.i error layer metal1 at (487 nm, 62 nm) measured 176 nm against limit 220 nm on shape 0 and shape 1
...
```

Two 45° strips offset 250 nm along x are 250/√2 ≈ 176.8 nm apart, floored to 176 nm, against 220 nm.
The point lies on the gap's centre line.

**Status and limits.** Partial. LEF `DIAGWIDTH`, `DIAGSPACING` and `DIAGMINEDGELENGTH` as limits for
diagonal edges only are not a check of their own: the plain checks hold diagonal and orthogonal
edges to one limit.

**Sources.** LEF/DEF 5.8 `DIAGWIDTH`, `DIAGSPACING` and `DIAGMINEDGELENGTH`; IHP SG13G2 rules M1.g,
M1.i, Mn.g and Mn.i.
