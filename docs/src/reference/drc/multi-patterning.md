# Multi-patterning checks

A multi-patterned layer is printed with two or more masks, each shape on one of them, and shapes on
one mask must keep a wider space than shapes on different masks. These checks decide whether the
layer splits into masks at all, whether drawn mask colours can be honoured, and hold stitches,
mask balance, trim layers and self-aligned patterning to their rules.

Write one rule per kind of error, so each is reported under its own id. The examples use the layer
`m1` with its masks marked by `m1_c1` and `m1_c2`, on a 1 nm grid.

## Colouring

### DRC-100: Colouring legality

**What it catches.** A layer that cannot be split into the available masks: three shapes each too
close to the other two for one mask form an odd cycle that two masks cannot colour. No
decomposition exists, so the layout must change.

**How GPurify measures it.** GPurify builds a conflict graph: each shape is a node, touching shapes
merged, and two shapes closer than the limit are joined. A shape whose own notch is narrower than
the limit conflicts with itself. If no assignment of `colors` masks keeps every joined pair apart,
the layer fails once, as needing one more mask than it has.

![Three m1 wires each within 80 nm of the other two: an odd cycle that two masks cannot colour](../../diagrams/drc-100.svg)

**In the deck.**

```text
rule <id> patterning(<layer>; colors: <count>) >= <length>
```

```text
grid 1nm
layer m1 = gds(30, 0)
layer m1_c1 = gds(30, 1)
layer m1_c2 = gds(30, 2)
rule M1.DP.odd patterning(m1; colors: 2) >= 80nm
```

**Example violation.**

```text
rules:
  M1.DP.odd: ran, examined 3 shapes, found 1 violations
violations: 1
  M1.DP.odd error layer m1 at (20 nm, 200 nm) measured 3 against limit 2 on shape 0
...
```

Two vertical wires 60 nm apart and a horizontal wire 60 nm above both form a triangle of conflicts:
3 masks needed against 2. The point is the centre of a shape on the cycle.

**Options.**

| Parameter | Value | Meaning |
|---|---|---|
| `colors` | count | The number of masks. |

**Status and limits.** Implemented. A colouring search that runs out of its budget is refused, never
reported clean.

**Sources.** Kahng et al. 2008; Yu et al. 2011; Yu and Pan 2016; the multi-patterning checks of
Calibre, IC Validator and Pegasus.

### DRC-101: Multi-patterning error classes

**What it catches.** The classes of decomposition error Calibre publishes, each under its own rule:
an odd cycle, shapes whose drawn colours cannot be honoured (an anchor path or anchor
self-conflict), a shape too close to itself for one mask, and two shapes closer than any two masks
allow.

**How GPurify measures it.** With anchor layers, a shape overlapping a shape on the first anchor
layer must take mask 1, on the second mask 2, and so on; a shape no anchor touches takes any mask.
With two masks, a failure names the two anchored shapes whose chain of conflicts has the wrong
parity, or one shape two anchor layers both claim. The other classes are ordinary checks: `notch`
for the self-conflict and `space` for the opposite-mask minimum.

![Two m1 wires 60 nm apart, both anchored to mask 1, against an 80 nm same-mask space](../../diagrams/drc-101.svg)

**In the deck.**

```text
rule <id> patterning(<layer>, <anchor 1>, <anchor 2>, ...; colors: <count>) >= <length>
rule <id> notch(<layer>) >= <length>      # self-conflict
rule <id> space(<layer>) >= <length>      # minimum opposite-mask spacing
```

```text
grid 1nm
layer m1 = gds(30, 0)
layer m1_c1 = gds(30, 1)
layer m1_c2 = gds(30, 2)
rule M1.DP.anc patterning(m1, m1_c1, m1_c2; colors: 2) >= 80nm
```

**Example violation.**

```text
rules:
  M1.DP.anc: ran, examined 2 shapes, found 1 violations
violations: 1
  M1.DP.anc error layer m1 at (70 nm, 200 nm) measured 3 against limit 2 on shape 0 and shape 1
...
```

Two wires 60 nm apart are both drawn on mask 1, so they conflict on one mask: an anchor path of the
wrong parity. The point is midway between the two shapes.

**Options.**

| Parameter | Value | Meaning |
|---|---|---|
| `colors` | count | The number of masks; one anchor layer per mask follows the patterned layer. |

**Status and limits.** Implemented. A layer no split exists for at all is reported by the plain
`patterning` rule, not the anchored one.

**Sources.** The Calibre multi-patterning error classes.

### DRC-102: Same-mask and different-mask spacing

**What it catches.** Two shapes drawn on one mask closer than the same-mask space, or on different
masks closer than the different-mask space. LEF/DEF `MASK` colours and foundry decks with coloured
layers hold each mask's spacing on its own.

**How GPurify measures it.** Each mask's shapes are a derived layer, `m1 and m1_c1`. Same-mask
spacing is `space` on that layer, different-mask spacing is `space` between two of them, measured
as plain spacing is.

![Two m1 wires on mask 1, 60 nm apart, against an 80 nm same-mask space](../../diagrams/drc-102.svg)

**In the deck.**

```text
layer <mask k> = <layer> and <colour k>
rule <id> space(<mask k>) >= <length>
rule <id> space(<mask 1>, <mask 2>) >= <length>
```

```text
grid 1nm
layer m1 = gds(30, 0)
layer m1_c1 = gds(30, 1)
layer m1_c2 = gds(30, 2)
layer m1_mask1 = m1 and m1_c1
layer m1_mask2 = m1 and m1_c2
rule M1.S.same space(m1_mask1) >= 80nm
rule M1.S.diff space(m1_mask1, m1_mask2) >= 40nm
```

**Example violation.**

```text
rules:
  M1.S.same: ran, examined 1 shapes, found 1 violations
  M1.S.diff: ran, examined 0 shapes, found 0 violations
violations: 1
  M1.S.same error layer m1_mask1 at (70 nm, 200 nm) measured 60 nm against limit 80 nm on shape 4 and shape 5
...
```

Two mask-1 wires are 60 nm apart against the 80 nm same-mask space. No mask-2 shape exists, so the
different-mask rule examined nothing.

**Status and limits.** Partial. LEF58 `PARALLELSAMEMASK` is not checked: the public LEF/DEF 5.8
reference does not define it, and no checker reads it.

**Sources.** LEF/DEF 5.8 `MASK`; LEF58 `SAMEMASK` and `PARALLELSAMEMASK`; ASAP7 rule M4.S.1.

## Stitches and balance

### DRC-103: Stitch legality

**What it catches.** A stitch, where one shape is split across two masks, that overlaps too little or
sits too close to another shape. A short overlap opens under mask misalignment, and a stitch near
another shape bridges.

**How GPurify measures it.** The overlap between the two mask parts is `overlap(c1, c2)`, the
overlap's width measured across the stitch. Keeping the stitch clear of other shapes is a spacing
from the stitch region, `c1 and c2`, to the shapes it does not touch.

![An m1 wire split between mask 1 and mask 2 with a 5 nm overlap, against a 10 nm minimum](../../diagrams/drc-103.svg)

**In the deck.**

```text
rule <id> overlap(<colour 1>, <colour 2>) >= <length>
rule <id> space(<colour 1> and <colour 2>, (<colour 1> or <colour 2>).not_interacting(<colour 1> and <colour 2>)) >= <length>
```

```text
grid 1nm
layer m1 = gds(30, 0)
layer m1_c1 = gds(30, 1)
layer m1_c2 = gds(30, 2)
rule M1.ST.ov overlap(m1_c1, m1_c2) >= 10nm
```

**Example violation.**

```text
rules:
  M1.ST.ov: ran, examined 1 shapes, found 1 violations
violations: 1
  M1.ST.ov error layer m1_c1 at (20 nm, 402 nm) measured 5 nm against limit 10 nm on shape 1 and shape 2
...
```

The mask-1 part ends 5 nm past the start of the mask-2 part: a 5 nm overlap against 10 nm. The point
is the middle of the overlap.

**Status and limits.** Expressible. Bans on stitches at line ends, corners and vias are not public
and are not checked.

**Sources.** The stitch checks of Calibre and IC Validator.

### DRC-104: Per-mask density and mask balance

**What it catches.** A window where one mask covers far more than the other. Masks out of balance
print and etch differently, so the foundry holds each mask's density and the ratio between masks.

**How GPurify measures it.** GPurify sweeps a window across the layout in steps. In each window it
takes the coverage of both masks and divides the lesser by the greater: 1 is equal coverage, 0 is a
mask missing. A window neither mask covers is skipped. Each mask's own density is a plain
`density` rule on that mask.

![A window holding 2 µm² of mask 1 and 0.4 µm² of mask 2, a balance of 0.2 against 0.8](../../diagrams/drc-104.svg)

**In the deck.**

```text
rule <id> density_balance(<mask 1>, <mask 2>; window: <length>, step: <length>) >= <fraction>
rule <id> density_balance(<mask 1>, <mask 2>, <boundary>; window: <length>, step: <length>) >= <fraction>
```

```text
grid 1nm
layer m1 = gds(30, 0)
layer m1_c1 = gds(30, 1)
layer m1_c2 = gds(30, 2)
rule M1.D.bal density_balance(m1_c1, m1_c2; window: 2um, step: 1um) >= 0.8
```

**Example violation.**

```text
rules:
  M1.D.bal: ran, examined 1 shapes, found 1 violations
violations: 1
  M1.D.bal error layer m1_c1 at (1000 nm, 1000 nm) measured 0.2 against limit 0.8
...
```

In the one 2 µm window, mask 1 covers 2 µm² and mask 2 covers 0.4 µm², a balance of 0.2 against
0.8. The point is the window's centre. A window finding names no shape.

**Options.**

| Parameter | Value | Meaning |
|---|---|---|
| `window` | length | The side of the square window. |
| `step` | length | How far the window moves each time. |

**Status and limits.** Implemented. A third layer names the die outline the windows tile; without it,
they tile the extent of the drawn layers.

**Sources.** The per-colour density checks of Calibre.

## Trim and self-aligned patterning

### DRC-105: Trim and cut-metal layers

**What it catches.** A trim or cut shape that cuts nothing, or that does not extend far enough past
the line it cuts. At advanced nodes, gates and wires are drawn long and cut by a separate mask; a
misplaced cut leaves a short or a stub.

**How GPurify measures it.** Trim layers are written with ordinary checks: `forbidden` on the cuts
that touch no line, `extension` past the line, `width` on the cut, and edge selections such as
`.vertical()` for direction.

![A GCUT shape crossing a GATE line passes; a second GCUT touching no gate is reported](../../diagrams/drc-105.svg)

**In the deck.**

```text
layer <lone cut> = <cut>.not_interacting(<line>)
rule <id> forbidden(<lone cut>)
rule <id> extension(<cut>, <line>) >= <length>
```

```text
grid 1nm
layer GATE = gds(7, 0)
layer GCUT = gds(10, 0)
layer lone_gcut = GCUT.not_interacting(GATE)
rule GCUT.AUX.1 forbidden(lone_gcut)
```

**Example violation.**

```text
rules:
  GCUT.AUX.1: ran, examined 1 shapes, found 1 violations
violations: 1
  GCUT.AUX.1 error layer lone_gcut at (100 nm, 240 nm) measured 2400 nm^2 against limit 0 nm^2 on shape 3
...
```

The second gate cut, 60 nm by 40 nm, touches no gate. It is reported with its area at a corner.

**Status and limits.** Expressible. LEF58 `TRIMMEDMETAL` pairs trim mask k with metal mask k as
derived layers. The further rules of LEF58 `TYPE TRIMMETAL` are not public and are not checked.

**Sources.** ASAP7 GCUT rules; LEF58 `TYPE TRIMMETAL` and `TRIMMEDMETAL`.

### DRC-128: Self-aligned double patterning

**What it catches.** A layer that self-aligned double patterning cannot decompose, and line ends a
gridded SADP layer cannot print. In SADP, the spacer sets the gap between mandrel and non-mandrel
lines, so shapes at some distances must take different colours and at others the same colour.

**How GPurify measures it.** `sadp` joins shapes closer than `different` with a different-colour
edge and shapes closer than `same` with a same-colour edge. A cycle with an odd number of
different-colour edges cannot be coloured, and is reported once between the two shapes that close
it. A shape whose own notch is under `different` fails at its centre. With a track grid, a shape
wider than `track_width` that is not an odd number of tracks wide fails with its width.
`sadp_line_end` holds the line ends of gridded rectangles to four rules: tip to tip on one track,
and overlap, corner and offset between ends on adjacent tracks.

![Two m4 lines 24 nm apart and a crossing line 50 nm above both, closing an odd different-colour cycle](../../diagrams/drc-128.svg)

**In the deck.**

```text
rule <id> sadp(<layer>; different: <length>, same: <length>, track_width: <length> | none, track_space: <length> | none)
rule <id> sadp_line_end(<layer>; adjacent: <length>, tip: <length>, overlap: <length>, corner: <length>, offset: <length>)
```

```text
grid 1nm
layer m4 = gds(40, 0)
rule M4.SADP sadp(m4; different: 72nm, same: 120nm, track_width: none, track_space: none)
```

**Example violation.**

```text
rules:
  M4.SADP: ran, examined 3 shapes, found 1 violations
violations: 1
  M4.SADP error layer m4 at (60 nm, 1025 nm) measured 1 against limit 0 on shape 1 and shape 2
...
```

Two lines 24 nm apart must take different colours, and a crossing line 50 nm above both must differ
from each: an odd cycle, 1 against 0. The point is midway between the two shapes that close it.

**Options.**

| Parameter | Value | Meaning |
|---|---|---|
| `different` | length | Shapes closer than this take different colours. |
| `same` | length | Shapes at least `different` but closer than this take the same colour. |
| `track_width`, `track_space` | length or `none` | The track grid: a shape wider than `track_width` must be `(2k + 1)` widths and `2k` spaces wide. |
| `adjacent` | length | `sadp_line_end`: lines at most this far apart side to side are on adjacent tracks. Each rectangle longer than wide is a line. |
| `tip` | length | Ends on one track closer than this fail. |
| `overlap` | length | Ends on adjacent tracks facing apart that overlap by less than this fail. |
| `corner` | length | Ends on adjacent tracks that do not overlap and are closer than this along the track fail. |
| `offset` | length | Ends on adjacent tracks facing the same way, offset by more than 0 and less than this, fail. |

**Status and limits.** Partial. The trim mask's own width, space and overlay on feature edges, bent
lines, SAQP and any foundry's values are not checked; ASAP7 states none. The values in the deck are
yours.

**Sources.** US patent 2015/0286764 A1 (GLOBALFOUNDRIES); Xu et al., IEEE TCAD 34(5), 2015, Table
II; Xiao, ISPD 2012; Yu and Pan 2016; ASAP7 fin SAQP and M4 to M7 SADP (Clark et al. 2016).
