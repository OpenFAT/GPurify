# How GPurify measures

A design rule is a number, but the number depends on how the distance is taken: along which line,
between which shapes, and what counts as exactly at the limit. This page explains the choices
GPurify makes, so you can predict what a rule reports on your layout. The examples use met1
(`gds(68, 20)`) on a 5 nm grid with a 1 nm layout database unit.

## Shapes merge before they are measured

GPurify reads a layer after its touching and overlapping polygons merge. A shape is the merged
region, not the polygon as drawn. A wire drawn as three abutting rectangles is one shape, so its
width is the wire's width, and it has no space to itself.

Two polygons that share only a corner point also merge, joined by a neck of width 0. So `width`
reports 0 at that corner, `space` never measures between them, and a gap between their other parts
is a `notch`. A ring closed only at a corner encloses a hole.

![Two met1 squares meeting at one corner, reported as one shape with a width of 0 at the corner](../diagrams/measuring-2.svg)

```text
grid 5nm
layer met1 = gds(68, 20)
rule m1.1 width(met1) >= 140nm
rule m1.2 space(met1) >= 600nm
```

Two 1 µm squares that meet at (1000 nm, 1000 nm):

```text
rules:
  m1.1: ran, examined 2 shapes, found 1 violations
  m1.2: ran, examined 1 shapes, found 0 violations
violations: 1
  m1.1 error layer met1 at (1000 nm, 1000 nm) measured 0 nm against limit 140 nm on shape 0
...
```

Merging decides how often a rule reports. A width, area or notch rule reports each shape once, at
its worst place. A spacing rule reports each pair of drawn polygons that lie in different shapes and
are too close. A wire drawn as two touching polygons beside another wire reports twice, once for
each polygon:

```text
  m1.2 error layer met1 at (500 nm, 350 nm) measured 300 nm against limit 600 nm on shape 0 and shape 2
  m1.2 error layer met1 at (1500 nm, 350 nm) measured 300 nm against limit 600 nm on shape 1 and shape 2
```

The `shape` numbers in a violation are the drawn polygons, counted across the layout as read.

## Edge to edge, Euclidean at corners

`space` and `width` measure the least distance between two outlines. Where two edges face each
other and overlap along their length, that is the distance straight across. Where the shapes are
offset diagonally, it is the Euclidean distance between the nearest corners, not the larger or the
sum of the two axis gaps.

![Two met1 pairs: facing edges 595 nm apart, and corners offset 300 nm and 400 nm, 500 nm apart](../diagrams/measuring-1.svg)

Two 1 µm squares offset by 300 nm across x and 400 nm across y are 500 nm apart:

```text
  m1.2 error layer met1 at (1150 nm, 1200 nm) measured 500 nm against limit 600 nm on shape 0 and shape 1
```

`width` reads a diagonal neck the same way. Where two rectangles overlap by 50 nm at a corner, the
two inside corners are 50√2 ≈ 70.7 nm apart, and the rule reports that neck:

```text
  m1.1 error layer met1 at (975 nm, 975 nm) measured 70 nm against limit 140 nm on shape 0
```

Some rules measure otherwise, and their pages say so. `space(A, B, projection)` measures only across
facing edges that overlap along their length, so a corner-to-corner pair is not measured. Run on a
met1 square with one met2 square 500 nm to its side and another offset diagonally:

```text
grid 5nm
layer met1 = gds(68, 20)
layer met2 = gds(69, 20)
rule euclid space(met1, met2) >= 600nm
rule proj space(met1, met2, projection) >= 600nm
```

```text
rules:
  euclid: ran, examined 2 shapes, found 2 violations
  proj: ran, examined 2 shapes, found 1 violations
...
```

LEF58 corner spacing (`corner_space(...; corner_to_corner: false, ...)`) takes the larger of the two
axis gaps, and a few cut rules measure centre to centre.

## Exactly at the limit

A minimum passes at the limit: `space(met1) >= 600nm` accepts a gap of exactly 600 nm and flags
595 nm. A maximum passes at the limit too: `width(L) <= 5um` accepts a shape exactly 5 µm wide.

Where a rule selects a row or a class by a threshold, the page states which side the threshold
falls on, because it differs by source:

| Threshold | Exactly at it |
|---|---|
| `width` in `wide_space`, `wide` in `protrusion_width` | Wide: a part exactly `width` wide holds a `width` square. |
| `width` rows in `space_table` and `two_width_table` | Not wide: the shape must be strictly wider, as "wider than 0.3 µm". |
| `prl` columns in `space_table` | Not reached: the run must exceed the column's length. |
| `prl` in `prl_space` | Reached: a run of exactly `prl` is held. |
| `eol_width` | Not an end: an end of line is strictly shorter. |
| `min` and `max` in `forbidden_space` | Inside the range: both ends are forbidden. |

For a foundry rule written "wider than 3 µm" on a check that counts exactly `width` as wide, write
the next grid step: `width: 3005nm` on a 5 nm grid.

## The grid and the reported value

Every length in the deck must be a multiple of the deck's `grid`. GPurify refuses a deck that asks
for `142nm` on a 5 nm grid and names the line:

```text
error: deck offgrid.deck: Invalid
  line 3:26: m1.1: 142nm is not a multiple of the grid
```

The layout keeps its own database unit, and GPurify measures in it exactly, in integers. A layout
with a 0.5 nm unit reports a wire 100.5 nm wide as 100.5 nm. Vertices off the deck's grid are not
moved; the `off_grid` rule reports them.

A distance that is not a whole number of units, such as a corner-to-corner gap or a gap to a 45°
edge, is compared with the limit exactly and reported rounded down to the database unit. The report
never shows a gap larger than it is: a 70.7 nm neck reads 70 nm.

## 45° and all-angle edges

Edges at 45° are measured exactly. A gap to a 45° edge is the perpendicular distance, a fraction
compared exactly and reported rounded down.

![A met1 triangle with a 45° edge 565.7 nm from the corner of a met1 square](../diagrams/measuring-3.svg)

A triangle whose hypotenuse runs from (1000 nm, 0) to (0, 1000 nm), and a square whose corner sits at
(900 nm, 900 nm), are (1800 − 1000)/√2 ≈ 565.7 nm apart:

```text
  m1.2 error layer met1 at (700 nm, 700 nm) measured 565 nm against limit 600 nm on shape 0 and shape 1
```

`width` reads a 45° shape as KLayout's Euclidean width does: the distance between two parallel
edges facing across the material, 0 at a corner sharper than 90°, and, for an axis edge and a 45°
edge at 135° to each other, the distance between the parts of each on the other's material side.

Edges at any other angle, as GDS writes a curve, are measured by `width`, `notch`, `space`, `area`,
`hole_area` and `edge_length`, with the distance kept as an exact fraction. Every other check
refuses a layer that holds an edge which is not horizontal or vertical, and reports `refused`
rather than a guess. Where a derived layer's angled edges cross between grid points, the crossing
is moved onto the grid.

## Where a violation is placed

The point in a violation line is in nm, rounded down to the database unit.

![The report point of a spacing violation: midway across the gap, at the middle of the run where the edges face](../diagrams/measuring-4.svg)

| Rule kind | Point |
|---|---|
| Spacing, width and notch | Midway across the gap, at the middle of the stretch where the two edges face each other; between corners, midway between them. |
| Width, notch or spacing on a layer with angled edges | The midpoint of the two nearest points, which on a long parallel run lies near one end of it, not at its middle. |
| Area and aspect ratio | The centre of the shape's first rectangle. |
| Hole area | The centre of the hole. |
| Cut size and cut class | The centre of the cut. |
| `forbidden`, and the presence checks such as floating metal | A corner of the shape. |
| Whole-layout checks such as `count` and `total_area` | The centre of the drawn layers' extent. |
| Windowed checks | The centre of the window. |

A gap from 1000 nm to 1595 nm is reported at 1297 nm, the midpoint 1297.5 nm rounded down:

```text
  m1.2 error layer met1 at (500 nm, 1297 nm) measured 595 nm against limit 600 nm on shape 0 and shape 2
```

Each check page names the point its rules report.
