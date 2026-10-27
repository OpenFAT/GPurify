# Layers

Every rule, connection and device in a deck reads layers. A drawn layer is a GDS layer and
datatype from the layout; a derived layer is computed from other layers with Boolean operators and
operations. This page lists both, and every operation's exact result.

## Drawn layers

```text
layer <name> = gds(<layer>, <datatype>)
```

A drawn layer takes every shape and text the layout has on that GDS layer and datatype. Both
numbers are bare whole numbers from 0 to 65535.

```text
layer met1       = gds(10, 0)
layer met1_label = gds(10, 5)
```

Declare each GDS layer and datatype once. To use one layer under a second name, derive it
(`layer metal1 = met1.sized(0nm)`) rather than declaring the pair twice.

A shape or text on a GDS layer the deck neither declares nor ignores refuses the layout, and
GPurify names the layer and datatype. A layer nobody wrote rules for cannot slip past every check
this way.

## Ignored GDS layers

```text
ignore gds(<layer>, <datatype>)
```

`ignore` drops every shape and text on that GDS layer and datatype, as when a marker layer no rule
reads is in the layout. A pair is ignored once, and a pair cannot be both ignored and declared.

```text
ignore gds(81, 4)
```

## The die boundary

```text
boundary <layer>
```

`boundary` names the drawn layer whose shapes outline the die, at most once. The extent of its
shapes is what the ERC density rules divide by, what the substrate network spans and the area
`lib` reports. Without a `boundary` line, or with nothing drawn on that layer, the die is the
extent of every drawn layer. A DRC density rule names its own boundary layer as an argument (see
the [DRC checks](../drc/README.md)).

```text
layer prBoundary = gds(235, 4)
boundary prBoundary
```

## Derived layers

```text
layer <name> = <expression>
```

A derived layer combines earlier layers with `and`, `or` and `not`, and with operations written
after a `.`. A derived layer needs at least one operator or operation: `layer copy = met1` is an
error.

| Operator | Result |
|---|---|
| `A and B` | The area both `A` and `B` cover |
| `A or B` | The area either covers |
| `A not B` | The area of `A` that `B` does not cover |

Operators apply left to right, so `met1 or met2 not blockage` is `(met1 or met2) not blockage`.
Use parentheses to group differently. Operations bind to the layer or parenthesised group just
before them, and chain left to right:

```text
layer ngate       = poly and diff and nsdm
layer diff_active = diff not poly
layer m12         = (met1 or met2) not blockage
layer huge_met1   = met1.sized(-1.5um).sized(1.5um)
layer tap_gate    = poly.interacting(tap).not_interacting(licon)
```

![Four panels: met1 and met2 as drawn; met1 and met2 keeps their overlap; met1 not met2 keeps met1 outside met2; met1.sized(d) grows met1 by d on every side](../../diagrams/deck-layers-1.svg)

Wherever a rule or another statement takes a layer, it can take an expression instead:
`forbidden(licon and poly)` is the same as declaring `layer x = licon and poly` and naming `x`.

### How shapes are read

Before an operation or a check reads a layer, the shapes that touch or overlap on it count as one
shape. Shapes that meet only at a corner point are one shape too, joined there by a neck of width
0. Space does not pass through such a corner, so a ring closed only at a corner encloses a hole.
Every operation, every check and net extraction read shapes this way.

### Operations on polygon layers

| Operation | Result |
|---|---|
| `.sized(len)` | Every shape grown by `len` on all sides, square at the corners. A negative `len` shrinks, and a part no wider than twice the shrink disappears, so `.sized(-a).sized(a)` keeps the parts wider than `2a`. |
| `.sized(dx, dy)` | Every shape grown by `dx` left and right and by `dy` above and below. Both negative shrinks. One growing and one shrinking is an error; chain two `.sized` for that. |
| `.interacting(L)` | The shapes that touch or overlap a shape on `L`. Sharing only a corner counts. |
| `.not_interacting(L)` | The shapes that do not. |
| `.inside(L)` | The shapes entirely covered by `L`. A shape may touch `L`'s boundary from inside. |
| `.outside(L)` | The shapes that share no area with `L`. A shape that only touches `L` is outside. |
| `.not_overlapping(L)` | The same as `.outside(L)`. |
| `.overlapping(L)` | The shapes that share area with `L`. Touching is not overlapping. |
| `.covering(L)` | The shapes that hold a whole shape of `L`, which may touch the holder's boundary from inside. |
| `.not_covering(L)` | The shapes that do not. |
| `.holes()` | Each hole, filled. A hole with an island in it is filled over the island. |
| `.extents()` | The bounding box of each shape. Boxes that overlap stay separate shapes until a check or another operation merges the layer. |
| `.with_area(bounds)` | The shapes whose area, holes not counted, is within the bounds. |
| `.with_width(bounds)` | The shapes whose narrowest width, as the `width` check measures it, is within the bounds. A diagonal width is compared exactly: a 70.7 nm neck is `> 70nm`. |
| `.with_bbox_max(bounds)` | The shapes whose bounding box's longer side is within the bounds. |
| `.with_bbox_min(bounds)` | The shapes whose bounding box's shorter side is within the bounds. |
| `.with_rect(w x h)` | The shapes with room for an axis-aligned `w` by `h` rectangle, either way round, its edges allowed on theirs. Both sides are positive. |
| `.without_rect(w x h)` | The other shapes. |
| `.rectangles()` | The shapes that are one axis-aligned rectangle with no hole. Touching pieces that make one rectangle are one. |
| `.squares()` | The rectangles with equal sides. |
| `.non_rectangles()`, `.non_squares()` | The other shapes. Two rectangles that meet only at a corner are one shape, which is neither. |
| `.with_text(T, "pattern")` | The shapes holding a text on drawn layer `T` that matches the pattern. A text on a shape's edge counts. |
| `.without_text(T, "pattern")` | The shapes holding no such text. |
| `T.texts_outside(L)` | Each text on drawn layer `T` that lies on no shape of `L`, neither on its material nor on its edge, as a box one grid unit across at the text. |
| `.in_cells("pattern", ...)` | The shapes of a drawn layer placed under a cell whose name matches one of the patterns: the cell the shape is drawn in, or any cell above it, the top cell included. Shapes are taken as drawn, before they merge. |
| `.not_in_cells("pattern", ...)` | The other shapes of the drawn layer. With `.in_cells` of the same patterns, it splits the layer in two. |
| `.edges()` | The boundary of each shape, as an edge layer (below). |

**Bounds** are one or two comparisons, separated by a comma: `>=`, `>`, `<=`, `<`, or a single
`==`. For example `with_area(>= 1um2)`, `with_width(> 1um, <= 3um)`. At most one bound is on each
side, and bounds that nothing can satisfy are an error.

**Patterns.** In a text or cell-name pattern, `*` matches any run of characters and `?` one
character. Everything else matches itself, case included, and the pattern covers the whole text or
name. A cell-name pattern refuses `[`, `]`, `{`, `}` and `\`. A deck holds at most 64 `.in_cells`
and `.not_in_cells` operations.

`.with_rect` and `.without_rect` refuse a layer with an edge that is neither horizontal nor
vertical: the rules reading such a layer report `refused`.

### Edge layers

`.edges()` turns a polygon layer into an edge layer: the boundary segments of its shapes, each
knowing which side its shape was on. Edge layers combine only with edge layers, and a check takes
one only where its check page says so; every other check refuses it.

| Operation | Result |
|---|---|
| `E and F` | The parts of `E` that coincide with an edge of `F`, whichever side each shape is on. The edges where two layers butt are `A.edges() and B.edges()`. |
| `E not F` | The parts of `E` that do not coincide with `F`. |
| `E or F` | Both, with the shared parts once. |
| `.inside_part(L)` | The parts of each edge strictly inside polygon layer `L`. |
| `.outside_part(L)` | The parts of each edge strictly outside `L`. A part on `L`'s boundary is in neither. |
| `.interacting(L)` | The whole edges that touch or lie in a shape on `L`. |
| `.not_interacting(L)` | The whole edges that do not. |
| `.with_length(bounds)` | The edges whose length is within the bounds. |
| `.horizontal()`, `.vertical()` | The edges running along that axis. |
| `.extended(begin: len, end: len, out: len, in: len)` | A box round each edge, as a polygon layer, one box per edge and not merged: the edge lengthened by `begin` before its start and `end` past its end, and widened by `out` away from its shape and `in` into it. |

An edge runs with its shape on its left, counter-clockwise round the shape, so `begin` is at the
corner the edge leaves. In `.extended`, write the four parts in that order. Each is 0 or more, and
`out` or `in` is above 0.

```text
layer butt    = nsdm.edges() and psdm.edges()
layer m1_long = met1.edges().with_length(>= 1um)
layer m1_end  = met1.edges().vertical().extended(begin: 0nm, end: 0nm, out: 50nm, in: 0nm)
```

### Angled edges

Layer operations take edges at any angle, as GDSII writes a curve: vertices on the grid, edges
between them. Results keep their vertices on the grid.

- Where two edges cross between grid points, the crossing is rounded to the nearest grid point,
  and every edge passing within that point's grid square is bent through it. Rounding moves a
  boundary less than half a grid unit along each axis and creates no new crossing. KLayout rounds
  the same way, except at two 45° edges meeting at a half-grid point: GPurify replaces that vertex
  with a one-unit step between the two nearest grid points, so the two tools differ inside that
  one-unit square.
- `.sized(len)` moves a 45° edge by `len` in x and in y, which is `len·√2` along its normal, so
  every result stays on the grid. KLayout moves every edge `len` along its normal, so the two
  differ on angled edges.
- `.with_length` measures an angled edge exactly, and `.inside_part` and `.outside_part` end a part
  at the last grid point inside it.

Which checks measure angled shapes is on each check page. A check that cannot measure one reports
the rule `refused` rather than guess.

## Example

```text
grid 5nm
layer met1       = gds(10, 0)
layer via1       = gds(11, 0)
layer met2       = gds(12, 0)
layer met1_label = gds(10, 5)

layer m1_no_via = met1.not_interacting(via1)
rule M1.NOVIA forbidden(m1_no_via)
```

On the layout of the [first-deck tutorial](../../tutorials/first-deck.md), wire B has no via:

```text
rules:
  M1.NOVIA: ran, examined 1 shapes, found 1 violations
violations: 1
  M1.NOVIA error layer m1_no_via at (0 nm, 600 nm) measured 200000 nm^2 against limit 0 nm^2 on shape 4
...
```

The derived layer holds wire B alone, 2 µm by 100 nm, and `forbidden` reports its whole area,
0.2 µm².
