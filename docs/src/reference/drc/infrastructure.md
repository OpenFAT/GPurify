# Rule infrastructure

These entries cover how a deck builds the layers its rules read: derived layers, selections of
shapes, edge layers, and how a hierarchical layout is read. They report nothing on their own, so each
example feeds the derived layer to a check such as `forbidden`, which reports every shape on it.

## Derived layers and selections

### DRC-120: Derived layers

**What it catches.** Nothing by itself: a derived layer is how a deck states the geometry a foundry
rule speaks of, such as "licon on a gate" or "the parts of met1 wider than 3 µm". Most foundry rules
read such a layer rather than a drawn one, so a deck needs booleans, sizing and selection to state
them.

**How GPurify measures it.** A derived layer combines earlier layers with `and`, `or` and `not`, left
to right, with parentheses to group. Operations follow a layer after a `.` and chain left to right.
Shapes that touch or overlap count as one shape before any operation looks at them, and two shapes
that meet only at a corner are one shape. A layer must be declared before anything uses it, and a
rule can take a layer expression in place of a name.

![A licon on the overlap of poly and diff, the derived layer licon_on_gate, flagged by licon.17; a licon on diff only passes](../../diagrams/drc-120.svg)

**In the deck.**

```text
layer <name> = <layer> and <layer>
layer <name> = (<layer> or <layer>) not <layer>
layer <name> = <layer>.<operation>(..).<operation>(..)
```

```text
grid 5nm
layer diff  = gds(65, 20)
layer tap   = gds(65, 44)
layer poly  = gds(66, 20)
layer licon = gds(66, 44)
layer difftap = diff or tap
layer licon_on_gate = (licon and poly) and difftap
rule licon.17 forbidden(licon_on_gate)
```

**Example violation.**

```text
rules:
  licon.17: ran, examined 1 shapes, found 1 violations
violations: 1
  licon.17 error layer licon_on_gate at (415 nm, 385 nm) measured 28900 nm^2 against limit 0 nm^2 on shape 6
...
```

A 170 nm licon on the gate, where poly crosses diff, is a 28 900 nm² shape on `licon_on_gate`, which
`licon.17` forbids. A licon on diff away from the poly is not on the layer.

**Options.** The operations on shapes:

| Operation | Value | Meaning |
|---|---|---|
| `and`, `or`, `not` | layer | Intersection, union and difference, left to right. |
| `.sized(len)` | length | Every shape grown by `len` on all sides, corners square; a negative `len` shrinks, and a part no wider than twice the shrink disappears. `.sized(-a).sized(a)` keeps the parts wider than `2a`. |
| `.interacting(L)` / `.not_interacting(L)` | layer | The shapes that touch or overlap a shape on `L`, a shared corner included, or the others. |
| `.inside(L)` | layer | The shapes entirely covered by `L`; touching `L`'s boundary from inside counts. |
| `.outside(L)` / `.not_overlapping(L)` | layer | The shapes that share no area with `L`; touching is outside. |
| `.holes()` | none | Each hole, filled, islands in it included. |
| `.extents()` | none | The bounding box of each shape. Overlapping boxes stay separate shapes until a check merges them. |
| `.with_area(bounds)` | area bounds | The shapes whose area, holes not counted, is within the bounds. |
| `.with_width(bounds)` | length bounds | The shapes whose narrowest width is within the bounds, compared exactly. |
| `.with_bbox_max(bounds)` / `.with_bbox_min(bounds)` | length bounds | The shapes whose bounding box's longer, or shorter, side is within the bounds. |
| `.with_text(T, "pattern")` / `.without_text(T, "pattern")` | text layer, pattern | The shapes holding a text on drawn layer `T` that matches, or the others. `*` matches any run of characters, `?` one. |
| `T.texts_outside(L)` | layer | Each text on `T` that lies on no shape of `L`, as a one-grid-unit box. |
| `.in_cells("pattern", ..)` / `.not_in_cells("pattern", ..)` | patterns | The shapes of a drawn layer placed under a cell whose name matches, or the others. At most 64 per deck. |

Bounds are one or two comparisons with `>=`, `>`, `<=` or `<`, or a single `==`:
`with_area(>= 1um2)`, `with_width(> 1um, <= 3um)`. Bounds nothing can satisfy are an error.

**Status and limits.** Implemented. `.extents()` keeps one box per shape, unmerged, as KLayout does.
Operations on layers with 45° edges, or edges at other angles, round crossings onto the grid;
[How distances are measured](../../explanation/measuring.md) says how.

**Sources.** IHP SG13G2 layout rules section 4.2 (derived layers); GlobalFoundries GF180MCU design
manual section 4.2; KLayout DRC layer operations
([DRC reference](https://www.klayout.de/doc/about/drc_ref_layer.html)); Magic's `templayer`.

### DRC-121: Selection by shape class, net or angle

**What it catches.** Nothing by itself: these selections pick shapes by what they are, so a rule can
say "only rectangular capacitors" or "the capacitor grown sideways must stay on its plate". They
cover KLayout's `rectangles`, `squares`, `covering`, `overlapping` and anisotropic `sized`.

**How GPurify measures it.** Shapes merge before they are selected, so touching pieces that make one
rectangle are one rectangle, and two rectangles meeting only at a corner are one shape that is
neither. `.sized(dx, dy)` grows every shape by `dx` left and right and by `dy` above and below.
Selection by angle works on edge layers, with `.horizontal()` and `.vertical()`
([DRC-122](#drc-122-edge-layer-operations)).

![An L-shaped capm flagged as not a rectangle; a capm grown 140 nm sideways sticks 40 nm past met3](../../diagrams/drc-121.svg)

**In the deck.**

```text
layer <name> = <layer>.rectangles()
layer <name> = <layer>.non_rectangles()
layer <name> = <layer>.squares()
layer <name> = <layer>.non_squares()
layer <name> = <layer>.covering(<layer>)
layer <name> = <layer>.not_covering(<layer>)
layer <name> = <layer>.overlapping(<layer>)
layer <name> = <layer>.sized(<dx>, <dy>)
```

```text
grid 5nm
layer capm = gds(89, 44)
layer met3 = gds(70, 20)
layer capm_bent = capm.non_rectangles()
layer capm_out = capm.sized(140nm, 0nm) not met3
rule capm.7 forbidden(capm_bent)
rule capm.side forbidden(capm_out)
```

**Example violation.**

```text
rules:
  capm.7: ran, examined 1 shapes, found 1 violations
  capm.side: ran, examined 1 shapes, found 1 violations
violations: 2
  capm.7 error layer capm_bent at (0 nm, 2000 nm) measured 3000000 nm^2 against limit 0 nm^2 on shape 4
  capm.side error layer capm_out at (3860 nm, 2000 nm) measured 80000 nm^2 against limit 0 nm^2 on shape 7
...
```

An L-shaped capm of 3 µm² is not a rectangle, which `capm.7` forbids. A 2 µm capm grown 140 nm to each
side reaches 40 nm past its met3 plate, a 40 nm by 2 µm strip of 80 000 nm².

**Options.**

| Operation | Value | Meaning |
|---|---|---|
| `.rectangles()` / `.non_rectangles()` | none | The shapes that are one axis-aligned rectangle with no hole, or the others. |
| `.squares()` / `.non_squares()` | none | The rectangles with equal sides, or the others. |
| `.covering(L)` / `.not_covering(L)` | layer | The shapes that hold a whole shape of `L`, which may touch the holder's boundary from inside, or the others. |
| `.overlapping(L)` | layer | The shapes that share area with `L`; touching is not overlapping. |
| `.sized(dx, dy)` | two lengths | Growth by `dx` along x and `dy` along y. Both negative shrinks; one growing and one shrinking is an error, so chain two `sized` for that. |

**Status and limits.** Partial. There is no selection by net: derived layers are computed before
nets are extracted, and connectivity can read derived layers. A derived layer still carries its
conductors' nets for net spacing. Selection by angle is horizontal or vertical edges only; there is
no selection of shapes or edges by any other angle. See
[issue 19, selection by shape class, net or angle](https://github.com/OmarSiwy/GPurify/issues/19).

**Sources.** SkyWater SKY130 rule capm.7
([periphery rules](https://skywater-pdk.readthedocs.io/en/main/rules/periphery.html)); KLayout's
`rectangles`, `squares`, `covering`, `overlapping` and `sized(dx, dy)`
([DRC reference](https://www.klayout.de/doc/about/drc_ref_layer.html)).

## Edge layers

### DRC-122: Edge layer operations

**What it catches.** Nothing by itself: an edge layer holds the boundary segments of shapes, so a deck
can state rules about edges, such as the edge where tap butts diff, or a band either side of it.
Foundry rules such as sky130 difftap.4 to difftap.7 and nsd.6 read edges, not shapes.

**How GPurify measures it.** `.edges()` turns each shape's boundary into an edge layer. Each edge
knows which side its shape was on, and runs with its shape on its left. Edge layers combine only with
other edge layers, and only the checks that say so take one. `.extended(..)` turns each edge back into
a box, as KLayout's `extended` does: lengthened by `begin` before its start and `end` past its end,
widened by `out` away from its shape and `in` into it. The boxes are not merged.

![diff and tap butting along a 200 nm edge, against 290 nm, and a licon inside the band 60 nm either side of that edge](../../diagrams/drc-122.svg)

**In the deck.**

```text
layer <name> = <layer>.edges()
layer <name> = <edges> and <edges>
layer <name> = <edges>.extended(begin: <length>, end: <length>, out: <length>, in: <length>)
```

```text
grid 5nm
layer diff  = gds(65, 20)
layer tap   = gds(65, 44)
layer licon = gds(66, 44)
layer butt = tap.edges() and diff.edges()
layer licon_near_butt = licon and butt.extended(begin: 0nm, end: 0nm, out: 60nm, in: 60nm)
rule difftap.4 length(butt) >= 290nm
rule butt.licon forbidden(licon_near_butt)
```

**Example violation.**

```text
rules:
  difftap.4: ran, examined 1 shapes, found 1 violations
  butt.licon: ran, examined 1 shapes, found 1 violations
violations: 2
  difftap.4 error layer butt at (1000 nm, 100 nm) measured 200 nm against limit 290 nm
  butt.licon error layer licon_near_butt at (1030 nm, 185 nm) measured 5100 nm^2 against limit 0 nm^2 on shape 4
...
```

The tap butts the diff along 200 nm of edge, under the 290 nm limit; an edge finding names no shape.
A licon 30 nm past that edge has a 30 nm by 170 nm strip, 5100 nm², inside the 60 nm band.

**Options.** The operations on edge layers:

| Operation | Value | Meaning |
|---|---|---|
| `E and F`, `E not F`, `E or F` | edge layer | The parts of `E` that coincide with `F` (whichever side each shape is on), that do not, or both. |
| `.inside_part(L)` / `.outside_part(L)` | layer | The parts of each edge strictly inside, or strictly outside, `L`. Parts on `L`'s boundary are in neither. |
| `.interacting(L)` / `.not_interacting(L)` | layer | The whole edges that touch or lie in a shape on `L`, or the others. |
| `.with_length(bounds)` | length bounds | The edges whose length is within the bounds. |
| `.horizontal()` / `.vertical()` | none | The edges along that axis. |
| `.extended(begin:, end:, out:, in:)` | four lengths | One box per edge, as above. Every length is 0 or more, and `out` or `in` is above 0. The result is a shape layer. |

**Status and limits.** Implemented. `.extended(..)` takes horizontal and vertical edges only; on a
layer with a 45° edge, or one at any other angle, the rules reading it are refused.

**Sources.** SkyWater SKY130 rules difftap.4 to difftap.7 and nsd.6
([periphery rules](https://skywater-pdk.readthedocs.io/en/main/rules/periphery.html)); KLayout's
`edges` and `extended` ([DRC reference](https://www.klayout.de/doc/about/drc_ref_layer.html)).

## Hierarchy

### DRC-123: Hierarchical processing

**What it catches.** Nothing by itself: this is how GPurify reads a layout built from cells placed
many times. A checker that works on the hierarchy checks a cell once and only its interactions per
placement, which keeps large designs fast.

**How GPurify measures it.** GPurify flattens the layout when it loads it. Every placement of a cell,
with its rotation, mirroring and array, becomes ordinary shapes in the top cell, and every rule
checks the flat result. A violation inside a cell is reported once per placement, at that
placement's position. The results are those of a flat check; only the run time and memory grow with
the number of placements.

![A cell with two vias 140 nm apart, placed once as drawn and once turned 90°, giving one via.2 violation at each placement](../../diagrams/drc-123.svg)

**In the deck.** Nothing to write in the deck. Every rule reads the flattened layout, here a cell
`PAIR` with two vias 140 nm apart, placed at (0, 0) and turned a quarter at (5 µm, 0):

```text
grid 5nm
layer via = gds(68, 44)
rule via.2 space(via) >= 170nm
```

**Example violation.**

```text
rules:
  via.2: ran, examined 2 shapes, found 2 violations
violations: 2
  via.2 error layer via at (220 nm, 75 nm) measured 140 nm against limit 170 nm on shape 0 and shape 1
  via.2 error layer via at (4925 nm, 220 nm) measured 140 nm against limit 170 nm on shape 2 and shape 3
...
```

The one gap inside `PAIR` is reported at both placements: across x at the first, across y at the
turned one.

**Status and limits.** Partial. GPurify has no hierarchical mode like KLayout's deep mode. This is a
matter of run time and memory, not of the result: a flat check finds what a hierarchical one finds.
See [issue 20, hierarchical processing](https://github.com/OmarSiwy/GPurify/issues/20).

**Sources.** KLayout's deep (hierarchical) mode
([DRC reference](https://www.klayout.de/doc/about/drc_ref_layer.html)).
