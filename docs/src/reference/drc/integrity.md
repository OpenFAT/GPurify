# Layout integrity checks

These checks hold the layout data itself to what a mask shop can make: vertices on the grid, edges
at allowed angles, well-formed polygons, and layers and labels only where they belong. Most read the
drawn polygons as they are in the layout, before touching pieces merge into shapes.

## Grid and angles

### DRC-001: Off-grid vertex

**What it catches.** A vertex of a drawn polygon that is not on the manufacturing grid. The mask
writer cannot place it, so the fracturing tool moves it, and the shape on silicon is not the one
you checked. Foundries and LEF state the grid as a fixed pitch, such as 5 nm on SKY130.

**How GPurify measures it.** GPurify reads every vertex of every drawn polygon, on every drawn
layer. It measures how far the vertex is from the nearest grid point: the larger of its x and y
offsets. A vertex off the grid is reported with that offset against a limit of 0. Derived layers
are not checked, since they repeat the drawn vertices.

![A met1 rectangle whose right edge sits at x = 3003 nm, 2 nm from the nearest 5 nm grid line, with both of its right vertices flagged](../../diagrams/drc-001.svg)

**In the deck.**

```text
rule <id> off_grid(; pitch: <length>)
```

```text
grid 5nm
layer met1 = gds(68, 20)
rule x.1a off_grid(; pitch: 5nm)
```

**Example violation.**

```text
rules:
  x.1a: ran, examined 8 shapes, found 2 violations
violations: 2
  x.1a error layer met1 at (3003 nm, 0 nm) measured 2 nm against limit 0 nm on shape 1
  x.1a error layer met1 at (3003 nm, 1000 nm) measured 2 nm against limit 0 nm on shape 1
...
```

The second met1 rectangle ends at x = 3003 nm, 2 nm from the grid point at 3005 nm, so both of its
right vertices break the limit of 0. For this rule the examined count is the number of vertices
read.

**Options.**

| Parameter | Value | Meaning |
|---|---|---|
| `pitch` | length | The grid every drawn vertex must lie on. It must be a multiple of the deck's `grid`. |

**Status and limits.** Implemented. No known limits. The layout's own database unit may be finer
than `pitch`; that is how an off-grid vertex gets into the file.

**Sources.** LEF/DEF 5.8 Language Reference, `MANUFACTURINGGRID`; SkyWater SKY130 rules x.1a and
x.1b ([periphery rules](https://skywater-pdk.readthedocs.io/en/main/rules/periphery.html));
GlobalFoundries GF180MCU grid rules ([design manual](https://gf180mcu-pdk.readthedocs.io/)); IHP
SG13G2 rule 3.1 ([IHP Open PDK](https://github.com/IHP-GmbH/IHP-Open-PDK)); OpenROAD TritonRoute's
off-grid check; KLayout `ongrid`
([DRC reference](https://www.klayout.de/doc/about/drc_ref_layer.html)); Magic `off_grid`.

### DRC-002: Allowed edge angles

**What it catches.** An edge drawn at an angle the process does not allow. Most processes allow
only horizontal and vertical edges, or those plus 45°. An edge at any other angle breaks the
mask writer's fracturing and the foundry's own checks.

**How GPurify measures it.** GPurify reads every edge of every drawn polygon, or of one layer's
polygons. Each edge lies along a line at 0°, 45°, 90° or 135°, or along none of them. An edge
whose line is not in the allowed list is reported at the vertex where it starts, as measured 0
against limit 1: it matches none of the allowed lines. Zero-length edges are skipped.

![A diff triangle whose 135-degree hypotenuse is flagged under a rule that allows only 0 and 90 degrees, beside a rectangle that passes](../../diagrams/drc-002.svg)

**In the deck.**

```text
rule <id> angle(; allowed: [<angle>, ..])
rule <id> angle(<layer>; allowed: [<angle>, ..])
```

```text
grid 5nm
layer diff = gds(65, 20)
rule x.2 angle(diff; allowed: [0deg, 90deg])
```

**Example violation.**

```text
rules:
  x.2: ran, examined 10 shapes, found 2 violations
violations: 2
  x.2 error layer diff at (3000 nm, 0 nm) measured 0 against limit 1 on shape 1
  x.2 error layer diff at (5000 nm, 500 nm) measured 0 against limit 1 on shape 2
...
```

The right triangle's hypotenuse, from (3000 nm, 0 nm), runs at 135°, which the rule does not
allow. The second triangle's slanted edge, at about 27°, is on no allowed line at all. For this
rule the examined count is the number of edges read.

**Options.**

| Parameter | Value | Meaning |
|---|---|---|
| `allowed` | list of angles | The lines an edge may lie along: `0deg`, `45deg`, `90deg`, `135deg`. An angle is read modulo 180°, so `180deg` is `0deg`. `45deg` is a rising diagonal and `135deg` a falling one; list both to allow every 45° edge. Any angle not a multiple of 45° refuses the deck. |

**Status and limits.** Partial. 45° and acute edges load, and this rule checks them. Of the other
checks, `width`, `notch`, `space`, `area`, `hole_area`, `edge_length`, `forbidden`, `inside`,
`contains` and `enclosure` measure layers with 45° edges (`enclosure` with `opposite` or `adjacent`
only for rectangular inner shapes). Every other check reports `refused` on such a layer, among them
the end-of-line, run-length, corner, wide and table spacings, `density`, `extension` and
`overlap`. Edges at other angles are covered under
[Manufacturability checks](dfm.md). Without a layer, the rule reads the drawn layers only; a derived
layer repeats their edges.

**Sources.** SkyWater SKY130 rules x.2 and x.3
([periphery rules](https://skywater-pdk.readthedocs.io/en/main/rules/periphery.html)); IHP SG13G2
rule 3.1 ([IHP Open PDK](https://github.com/IHP-GmbH/IHP-Open-PDK)); GlobalFoundries GF180MCU
acute-angle rules ([design manual](https://gf180mcu-pdk.readthedocs.io/)); KLayout `with_angle`
([DRC reference](https://www.klayout.de/doc/about/drc_ref_layer.html)); Magic `angles`.

### DRC-003: Acute angles

**What it catches.** A corner sharper than the process allows. An acute corner prints rounded
and thin, and its tip can lift or break off. IHP SG13G2 forbids angles under 87°.

**How GPurify measures it.** GPurify reads each corner of each drawn polygon as drawn, diagonal
edges included. It measures the angle inside the shape at that corner: 90° at a rectangle's
corner, 270° at the inner corner of an L, 45° at the sharp corners of a right isosceles triangle.
A corner under the limit is reported at its vertex with its angle in degrees.

![A diff triangle with corners of 26.6, 90 and 63.4 degrees; the two corners under 87 degrees are flagged](../../diagrams/drc-003.svg)

**In the deck.**

```text
rule <id> interior_angle(<layer>) >= <angle>
rule <id> interior_angle() >= <angle>
```

The second form reads every drawn layer.

```text
grid 5nm
layer diff = gds(65, 20)
rule ac interior_angle(diff) >= 87deg
```

**Example violation.**

```text
rules:
  ac: ran, examined 10 shapes, found 4 violations
violations: 4
  ac error layer diff at (3000 nm, 0 nm) measured 45 against limit 87 on shape 1
  ac error layer diff at (4000 nm, 0 nm) measured 26.565051177 against limit 87 on shape 2
  ac error layer diff at (5000 nm, 500 nm) measured 63.434948823 against limit 87 on shape 2
...
```

The triangle from (4000 nm, 0 nm) to (5000 nm, 0 nm) to (5000 nm, 500 nm) has corners of 26.6°
and 63.4°, both under the 87° limit; its right angle passes. For this rule the examined count is
the number of corners read.

**Status and limits.** Implemented. Other rules still refuse a layer whose edges are not at a
multiple of 45°; see [DRC-002](#drc-002-allowed-edge-angles).

**Sources.** IHP SG13G2 rule 3.1 ([IHP Open PDK](https://github.com/IHP-GmbH/IHP-Open-PDK));
GlobalFoundries GF180MCU acute-angle rules ([design manual](https://gf180mcu-pdk.readthedocs.io/));
Siemens Calibre's `FLAG ACUTE`.

## Polygon form

### DRC-004: Self-intersecting and zero-area polygons

**What it catches.** A drawn polygon whose outline crosses itself, such as a bow tie, or that
encloses no area. Such a polygon has no single meaning: tools disagree on which parts are
inside, so the mask may not match what any check saw.

**How GPurify measures it.** GPurify reads each drawn polygon on its own, before merging. A
polygon whose outline crosses itself, or whose vertices enclose no area, is reported at its first
vertex as measured 0 against limit 1. Every other rule on that polygon's layer reports `refused`,
since it cannot decide what the polygon covers.

![A bow-tie met1 polygon whose outline crosses itself and a flat three-point polygon, both flagged, beside a valid rectangle](../../diagrams/drc-004.svg)

**In the deck.**

```text
rule <id> valid(<layer>)
rule <id> valid()
```

The second form reads every drawn layer.

```text
grid 5nm
layer met1 = gds(68, 20)
rule valid valid(met1)
rule m1.1 width(met1) >= 140nm
```

**Example violation.**

```text
rules:
  valid: ran, examined 3 shapes, found 2 violations
  m1.1: refused, examined 0 shapes, found 0 violations
violations: 2
  valid error layer met1 at (2000 nm, 0 nm) measured 0 against limit 1 on shape 1
  valid error layer met1 at (4000 nm, 0 nm) measured 0 against limit 1 on shape 2
...
```

The bow tie starting at (2000 nm, 0 nm) crosses itself, and the three points from (4000 nm, 0 nm)
lie on one line. The width rule on met1 is refused: it looked at nothing.

**Status and limits.** Implemented. Without a `valid` rule, such a polygon still refuses every
rule on its layer, but no rule names it.

**Sources.** IHP SG13G2 rule 3.1 ([IHP Open PDK](https://github.com/IHP-GmbH/IHP-Open-PDK));
KLayout `odd_polygons`
([DRC reference](https://www.klayout.de/doc/about/drc_ref_layer.html)); Siemens Calibre's
`FLAG NONSIMPLE`.

### DRC-005: Rectangle-only and square-only shapes

**What it catches.** A shape that must be a plain rectangle or a square and is not, such as an
L-shaped capacitor top plate or a slotted contact where only square contacts are allowed. The
device models and the foundry's process assume the simple shape.

**How GPurify measures it.** Touching pieces merge into one shape first. A shape is a rectangle
when it is one axis-aligned rectangle with no hole, and a square when its sides are also equal.
Two rectangles that touch only at a corner are one shape that is neither. `forbidden` reports each
other shape with its area.

![An L-shaped capm shape and two capm boxes meeting at a corner, both flagged, beside a capm rectangle that passes](../../diagrams/drc-005.svg)

**In the deck.** Select the other shapes with `.non_rectangles()` or `.non_squares()`, and forbid
them.

```text
rule <id> forbidden(<layer>.non_rectangles())
rule <id> forbidden(<layer>.non_squares())
```

```text
grid 5nm
layer licon = gds(66, 44)
layer capm = gds(89, 44)
layer capm_odd = capm.non_rectangles()
layer licon_slot = licon.non_squares()
rule capm.7 forbidden(capm_odd)
rule licon.sq forbidden(licon_slot)
```

**Example violation.**

```text
rules:
  capm.7: ran, examined 2 shapes, found 2 violations
  licon.sq: ran, examined 1 shapes, found 1 violations
violations: 3
  capm.7 error layer capm_odd at (6000 nm, 1000 nm) measured 2000000 nm^2 against limit 0 nm^2 on shape 7
  capm.7 error layer capm_odd at (3000 nm, 2000 nm) measured 3000000 nm^2 against limit 0 nm^2 on shape 6
  licon.sq error layer licon_slot at (1000 nm, 4500 nm) measured 85000 nm^2 against limit 0 nm^2 on shape 8
...
```

The two 1 µm boxes meeting at (7000 nm, 1000 nm) are one 2 µm² shape that is not a rectangle,
and the L is 3 µm². The 170 nm × 500 nm licon is a rectangle but not a square.

**Status and limits.** Implemented. No known limits.

**Sources.** SkyWater SKY130 rules capm.7, x.2a and licon.3
([periphery rules](https://skywater-pdk.readthedocs.io/en/main/rules/periphery.html)); LEF/DEF 5.8
Language Reference, `LEF58_RECTONLY`; KLayout `rectangles` and `squares`
([DRC reference](https://www.klayout.de/doc/about/drc_ref_layer.html)); Magic `rect_only`;
OpenROAD TritonRoute.

## Layers and labels

### DRC-006: Forbidden layer or layer only inside a region

**What it catches.** A layer drawn where the design may not use it at all, or outside the region
it belongs to, such as a high-voltage implant outside its high-voltage area. These layers change
the process in ways the rest of the design does not expect.

**How GPurify measures it.** `forbidden` reports every shape on its layer, with its area. To hold
a layer inside a region, forbid the part of it outside the region, `L not R`: each piece that
sticks out is reported with its own area.

![An hvntm shape running 2 µm past the right edge of the hvi region, the part outside flagged](../../diagrams/drc-006.svg)

**In the deck.**

```text
rule <id> forbidden(<layer>)
rule <id> forbidden(<layer> not <region>)
```

```text
grid 5nm
layer hvi = gds(75, 20)
layer hvntm = gds(125, 20)
layer hvntm_outside = hvntm not hvi
rule hvntm.only_in_hvi forbidden(hvntm_outside)
```

**Example violation.**

```text
rules:
  hvntm.only_in_hvi: ran, examined 1 shapes, found 1 violations
violations: 1
  hvntm.only_in_hvi error layer hvntm_outside at (10000 nm, 4000 nm) measured 4000000 nm^2 against limit 0 nm^2 on shape 2
...
```

The hvntm shape runs 2 µm past the hvi edge at x = 10 µm; the 2 µm × 2 µm part outside is
reported, 4 µm² against a limit of 0.

**Status and limits.** Implemented. `inside(<layer>, <region>)` is the same check reported once per
shape with the area left outside; see [Enclosure and overlap checks](overlay.md).

**Sources.** IHP SG13G2 rule 3.2 ([IHP Open PDK](https://github.com/IHP-GmbH/IHP-Open-PDK));
SkyWater SKY130 rules x.8, x.9, x.15a and x.21
([periphery rules](https://skywater-pdk.readthedocs.io/en/main/rules/periphery.html)).

### DRC-007: Label and pin rules

**What it catches.** A pin shape that is not on the drawing it marks, and a text label that lands
on no shape. Both name a net that is not where the label says. A floating label leaves its net
unnamed in LVS and can name the wrong net after an edit.

**How GPurify measures it.** A pin outside its drawing is `inside(pin, drawing)`: each pin shape
not entirely on the drawing is reported with the area left outside. A floating label is
`T.texts_outside(L)`: each text on the GDS layer `T` that lies neither on a shape of `L` nor on its
edge, as a one-unit box at the text, which `forbidden` reports.

![A met1 pin shape running 0.5 µm past the end of its met1 wire, flagged, and a label B lying on no met1 shape, flagged](../../diagrams/drc-007.svg)

**In the deck.**

```text
rule <id> inside(<pin layer>, <drawing layer>)
rule <id> forbidden(<text layer>.texts_outside(<drawing layer>))
```

```text
grid 5nm
layer met1 = gds(68, 20)
layer met1_pin = gds(68, 16)
layer met1_label = gds(68, 5)
layer floating = met1_label.texts_outside(met1)
rule x.5 inside(met1_pin, met1)
rule x.17 forbidden(floating)
```

**Example violation.**

```text
rules:
  x.5: ran, examined 1 shapes, found 1 violations
  x.17: ran, examined 1 shapes, found 1 violations
violations: 2
  x.5 error layer met1_pin at (2000 nm, 250 nm) measured 250000 nm^2 against limit 0 nm^2 on shape 1
  x.17 error layer floating at (4000 nm, 250 nm) measured 1 nm^2 against limit 0 nm^2 on shape 2
...
```

The pin runs 500 nm past the end of the wire at x = 2 µm, leaving 0.25 µm² outside. The label `B`
at (4000 nm, 250 nm) lies on no met1, and its one-unit box is reported.

**Status and limits.** Implemented. The minimum spacing between pin centres is
`space(<pin layer>, center) >= <length>`, the centre-to-centre form described under
[Via and cut checks](cut.md); no public manual states its value, so the deck supplies it. A label
on a layer that `connect label` names must land on a shape: one that does not refuses the whole
run before any rule, so the floating-label rule reports labels on other text layers only.

**Sources.** SkyWater SKY130 rules x.5, x.17 and x.20
([periphery rules](https://skywater-pdk.readthedocs.io/en/main/rules/periphery.html)); IHP SG13G2
pin rules Pin.a to Pin.h ([IHP Open PDK](https://github.com/IHP-GmbH/IHP-Open-PDK)); KLayout
`texts` ([DRC reference](https://www.klayout.de/doc/about/drc_ref_layer.html)).

## Layout input

### DRC-124: Layout input exceptions

**What it catches.** A layout file GPurify cannot read exactly: a reference to a cell that does
not exist, two cells with one name, a placement turned by other than a quarter turn or magnified
by a fraction, and a path whose width is odd or zero. Reading any of these approximately would
move geometry, and every verdict after it would be about a different layout.

**How GPurify measures it.** GPurify reads the layout before any rule and refuses it at the first
such record, naming the problem. Nothing is checked and no report is written. Each case has one
fixed answer:

| Case | What GPurify does |
|---|---|
| Reference to an undefined cell | Refuses the layout. |
| Two cells with the same name | Refuses the layout: which one a reference places is not stated. |
| Placement turned by other than a multiple of 90° | Refuses the layout. |
| Magnification that is not a whole number from 1 to 1000000 | Refuses the layout. |
| Whole-number magnification | Reads the cell scaled by it. |
| Absolute magnification or angle | Refuses the layout. |
| `PATH` of odd, zero or negative width, or path type other than 0, 2 or 4 | Refuses the layout. |
| `PATH` with a diagonal or zero-length segment, or one that turns back on itself | Refuses the layout. |
| A spike (an outline that runs out and back along one line) | Reads the region the outline encloses; the spike adds no area. |
| Any vertex count | Reads the polygon whole. |

![A top cell placing a reference to cell NOPE, which the library does not define; the layout is refused](../../diagrams/drc-124.svg)

**In the deck.** Nothing to write in the deck. Every run reads the layout this way.

```sh
gpurify drc missing.gds --deck input.deck
```

**Example violation.**

```text
error: layout missing.gds: MissingCell
  cell NOPE is referenced but not defined
```

The top cell places `NOPE`, which the file does not define; GPurify exits with 1 and checks
nothing.

**Status and limits.** Partial. GPurify has no severity per case: each case is either refused,
which stops the run with no report, or read as stated without a note. A spike and a magnified
placement are read silently, where Calibre lets the deck choose an error or a warning for each.

**Sources.** Siemens Calibre's `LAYOUT INPUT EXCEPTION SEVERITY` and `DRC MAXIMUM VERTEX`.
