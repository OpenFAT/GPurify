# DRC checks

Design rule checking (DRC) holds the geometry of a layout to the rules of its process: widths,
spaces, enclosures, areas, densities and the rest. In GPurify, each `rule` line of the deck names
one check, the layers it reads and its limit, and `gpurify drc` runs every rule over the flattened
layout.

## How a rule runs

GPurify reads the layout, flattens it, and computes each derived layer the deck declares. It then
runs the rules in deck order. A rule reads its layers after touching and overlapping shapes on one
layer merge, so a shape is the merged region, not the polygon as drawn. How each distance is
measured is in [How GPurify measures](../../explanation/measuring.md).

Every rule ends with one of three outcomes:

| Outcome | Meaning |
|---|---|
| `ran` | The rule looked at the layout. Its violations are listed. |
| `skipped` | The rule did not run, and the reason is given: an earlier stage of the deck found errors, or a check that needs design intent got none, or, for some checks such as `patterning`, `tap_distance` and `origin`, the layer holds no shapes. |
| `refused` | The input is outside what the rule decides exactly, such as a 45° edge on a check that measures only horizontal and vertical edges. GPurify does not guess. |

A rule that fails reports one line per violation. A rule written `rule <id> warning <check>` reports
warnings instead of errors.

## The report

```sh
gpurify drc layout.gds --deck process.deck
```

```text
grid 5nm
layer met1 = gds(68, 20)
layer met2 = gds(69, 20)
rule m1.1 width(met1) >= 140nm
rule m1.2 space(met1) >= 140nm
rule m1.3b wide_space(met1; width: 3um) >= 280nm
rule m2.1 width(met2) >= 140nm
rule m1.2r warning space(met1) >= 250nm
```

On a layout with two met1 wires and one 45° met1 strip, and nothing on met2:

```text
rules:
  m1.1: ran, examined 3 shapes, found 2 violations
  m1.2: ran, examined 0 shapes, found 0 violations
  m1.3b: refused, examined 0 shapes, found 0 violations
  m2.1: ran, examined 0 shapes, found 0 violations
  m1.2r: ran, examined 1 shapes, found 1 violations
violations: 3
  m1.1 error layer met1 at (1000 nm, 0 nm) measured 0 nm against limit 140 nm on shape 2
  m1.1 error layer met1 at (50 nm, 2000 nm) measured 100 nm against limit 140 nm on shape 0
  m1.2r warning layer met1 at (200 nm, 1000 nm) measured 200 nm against limit 250 nm on shape 0 and shape 1
summary:
  drc: ran
  1 rules skipped
  2 rules clean
  3 violations: 2 errors, 1 warnings
```

Read the report in this order:

1. **The rule lines.** Each rule gives its outcome, how many things it examined and how many
   violations it found. What `examined` counts depends on the check: shapes, pairs of shapes,
   edges, holes or line ends. A rule that ran but examined 0 found nothing to look at, as `m2.1`
   on an empty layer.
2. **The violation lines.** Each gives the rule id, `error` or `warning`, the layer, a point in nm,
   the measured value, the limit, and the shape or shapes it is on. Lengths are in `nm`, areas in
   `nm^2`, and counts and ratios bare. The 45° strip's sharp corner has a width of 0.
3. **The summary.** The summary counts refused rules with the skipped ones, here `m1.3b`.

> [!WARNING]
> A rule reported `skipped` or `refused` looked at nothing. Its zero violations prove nothing, and
> the run fails.

`gpurify drc` exits with 0 when no rule found an error and none was skipped or refused. Warnings
alone do not fail the run.

## Check pages

| Page | Covers |
|---|---|
| [Spacing checks](spacing.md) | Gaps between shapes and within a shape: plain, wide-metal, run-length and two-width tables, line ends, corners, forbidden ranges, pitch, spans, 45° shapes. |
| [Width, area and length checks](dimension.md) | One shape's size: minimum and maximum width, channel width and length, cut sizes, allowed widths, area, hole area, edge steps, length, aspect ratio, protrusions. |
| [Enclosure and overlap checks](overlay.md) | Two layers against each other: enclosure, extension, overlap, containment, butting edges, gate shapes. |
| [Via and cut checks](cut.md) | Cuts: cut spacing, cut-class tables, stacking, minimum cut count, via choice, cut keep-out zones. |
| [Net-aware checks](net.md) | Rules that read the extracted nets: same-net and different-net spacing, voltage spacing, high-voltage tags, floating metal, well taps, shorts. |
| [Multi-patterning checks](multi-patterning.md) | Splitting a layer into masks: colouring, anchors, mask spacing, stitches, mask balance, trim layers, self-aligned patterning. |
| [Device checks](device.md) | Device-family rules, per-chip counts and areas, and exemptions by region, cell or switch. |
| [Manufacturability checks](dfm.md) | Recommended rules, DFM scoring, critical area, pattern matching, via redundancy. |
| [Layout integrity checks](integrity.md) | The layout itself: off-grid vertices, edge angles, invalid polygons, shape classes, forbidden layers, labels, input exceptions. |
| [Density checks](density.md) | Coverage of a layer: whole-chip and windowed density, local density, fill, slotting. |
| [Chip-level checks](chip.md) | The die as a whole: seal ring, pads and bumps, frame and cell names, cell edges, die alignment. |
| [Rule infrastructure](infrastructure.md) | The deck operations every check builds on: derived layers, selections, edge layers, hierarchy. |
