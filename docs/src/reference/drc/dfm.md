# Manufacturability checks

Manufacturability checks look past the minimum rules at what lowers yield: recommended rules,
critical area, process hotspots and single vias. Most report a score or a rate for the whole
design, against a sign-off value you choose.

## Recommended rules

### DRC-110: Recommended rules reported as warnings

**What it catches.** A layout that meets the required rule but not the foundry's recommended one,
such as a wider space between wide metal plates. Recommended rules raise yield where there is room
for them, so the foundry asks for them without making them a sign-off condition.

**How GPurify measures it.** Any rule can be marked `warning`. It measures exactly as without the
mark, but its findings are reported as warnings: they are listed and counted, and they do not fail
the run. A warning rule that is skipped or refused still fails the run, because it looked at
nothing. The example holds two IHP TopMetal2 plates, each 10 µm wide and 100 µm long, 3 µm apart:
they pass the required 2 µm space and miss the recommended 5 µm space between wide plates.

![Two 10 µm TopMetal2 plates 3 µm apart: they pass the 2 µm required space and get a warning against the 5 µm recommended space](../../diagrams/drc-110.svg)

**In the deck.**

```text
rule <id> warning <check>
```

```text
grid 5nm
layer topmetal2 = gds(134, 0)
rule TM2.b space(topmetal2) >= 2um
rule TM2.bR warning space_table(topmetal2; prl: [0um, 50um], width: [0um, 5um], space: [[2um, 2um], [2um, 5um]])
```

**Example violation.**

```text
rules:
  TM2.b: ran, examined 0 shapes, found 0 violations
  TM2.bR: ran, examined 1 shapes, found 1 violations
violations: 1
  TM2.bR warning layer topmetal2 at (11500 nm, 50000 nm) measured 3000 nm against limit 5000 nm on shape 0 and shape 1
summary:
  drc: ran
...
  1 violations: 0 errors, 1 warnings
```

The plates are 3 µm apart where the recommended rule asks 5 µm. The run exits with status 0,
because the only finding is a warning.

**Status and limits.** Implemented. No known limits. The example leaves out the inductor exemption
of IHP's TM2.bR.

**Sources.** IHP SG13G2 layout rules, rules with an `R` suffix such as TM2.bR
([IHP Open PDK](https://github.com/IHP-GmbH/IHP-Open-PDK)); SkyWater SKY130 rules flagged RR and RC
([SKY130 periphery rules](https://skywater-pdk.readthedocs.io/en/main/rules/periphery.html));
ASAP7 design rules of type R; LEF/DEF 5.8 Language Reference, `PREFERENCLOSURE`.

### DRC-111: DFM scoring of recommended rules

**What it catches.** A design whose recommended-rule misses add up to too much yield risk. One
space a little under the recommended value costs little; hundreds of them cost a measurable share
of the dies. A DFM score turns each miss into a number and combines them.

**How GPurify measures it.** GPurify runs the check (`space`, `width` or `enclosure`) at the
recommended value \\( R \\). Each finding, measured at \\( m \\), scores

\\[ s = \min\left(1,\ \max\left(0,\ \frac{m - r}{R - r}\right)\right) \\]

where \\( r \\) is the required value: 0 at or below the required value, 1 at the recommended one,
linear between. The design scores

\\[ F = \prod_i \bigl(1 - \rho\,(1 - s_i)\bigr) \\]

over every finding \\( i \\), where \\( \rho \\) is the rule's failure rate: the chance that a miss at
the required value kills the die. When \\( F \\) is below the sign-off value, the rule reports one
violation, at the lowest-scoring finding, with the design's score.

In the example, three pairs of metal1 lines sit 190 nm, 200 nm and 210 nm apart, with
\\( r = 180 \\) nm, \\( R = 220 \\) nm and \\( \rho = 0.01 \\). Their scores are 0.25, 0.5 and 0.75,
so \\( F = 0.9925 \times 0.995 \times 0.9975 = 0.98507 \\), under the 0.99 sign-off.

![Three pairs of metal1 lines 190, 200 and 210 nm apart, each scored between the 180 nm required and 220 nm recommended space; the 190 nm pair is marked](../../diagrams/drc-111.svg)

**In the deck.**

```text
rule <id> dfm_score(<layer>[, <outer>]; check: space | width | enclosure, required: <length>, recommended: <length>, rate: <fraction>) >= <score>
```

```text
grid 5nm
layer metal1 = gds(8, 0)
rule M1.b.dfm dfm_score(metal1; check: space, required: 180nm, recommended: 220nm, rate: 1%) >= 0.99
```

**Example violation.**

```text
rules:
  M1.b.dfm: ran, examined 3 shapes, found 1 violations
violations: 1
  M1.b.dfm error layer metal1 at (500 nm, 295 nm) measured 0.9850686562500002 against limit 0.99 on shape 0 and shape 1
...
```

The design scores 0.985 against a 0.99 sign-off; the marker is the 190 nm gap, the worst finding.

**Options.**

| Parameter | Value | Meaning |
|---|---|---|
| `check` | `space`, `width` or `enclosure` | The check run at the recommended value: `space(L)`, `width(L)`, or `enclosure(L, outer)` with the outer layer as the second layer argument. |
| `required` | length | The value where a finding scores 0. |
| `recommended` | length | The value where a finding scores 1. It must be larger than `required`. |
| `rate` | fraction | The failure rate of one finding at the required value. |

**Status and limits.** Partial. Only `space`, `width` and `enclosure` can be scored, and only for
the whole design, not per cell. The published scoring method gives neither the curve between the
two values nor the per-finding function; the straight line and \\( 1 - \rho(1 - s) \\) are
GPurify's reading. The rate, the values and the sign-off are yours to state: no public deck gives
them.

**Sources.** Siemens Calibre YieldAnalyzer; GlobalFoundries' DFM scoring with IC Validator,
[arXiv:1805.10016](https://arxiv.org/abs/1805.10016), Equation 2.

## Yield analysis

### DRC-112: Critical area analysis

**What it catches.** Wiring that a random particle can short easily: long runs of two wires close
together. Critical area is the area where the centre of a defect of a given size lands and joins
two shapes, so it sets the expected number of shorts for a defect density.

**How GPurify measures it.** A defect is a square of half-side \\( r \\). GPurify grows every
merged shape of the layer by \\( r \\), square at the corners, and takes the union of the overlaps of
every two grown shapes. Its area is the short-circuit critical area \\( A(r) \\). For two parallel
lines of length \\( l \\), a gap \\( s \\) apart,

\\[ A(r) = (l + 2r)(2r - s) \quad \text{for } 2r > s, \\]

and 0 otherwise. Over a defect-size distribution, the mean critical area is

\\[ \bar A = \sum_k w_k\, A(r_k) \\]

where \\( r_k \\) are the sampled half-sides and \\( w_k \\) their weights, used as given. In the
example, two met1 lines 10 µm long are 200 nm apart. At \\( r = 150 \\) nm,
\\( A = 10.3 \times 0.1 = 1.03 \\) µm², over the 1 µm² limit. With the radii 100, 150 and 200 nm
weighted 0.5, 0.3 and 0.2, \\( \bar A = 0.5 \times 0 + 0.3 \times 1.03 + 0.2 \times 2.08 = 0.725 \\)
µm², under the limit.

![Two 10 µm met1 lines 200 nm apart, each grown by 150 nm; the 100 nm overlap strip between them is the critical area](../../diagrams/drc-112.svg)

**In the deck.**

```text
rule <id> critical_area(<layer>; radius: <length>) <= <area>
rule <id> critical_area(<layer>; radii: [<length>, ..], weights: [<fraction>, ..]) <= <area>
```

```text
grid 5nm
layer met1 = gds(68, 20)
rule m1.ca critical_area(met1; radius: 150nm) <= 1um2
rule m1.ca.mean critical_area(met1; radii: [100nm, 150nm, 200nm], weights: [0.5, 0.3, 0.2]) <= 1um2
```

**Example violation.**

```text
rules:
  m1.ca: ran, examined 2 shapes, found 1 violations
  m1.ca.mean: ran, examined 2 shapes, found 0 violations
violations: 1
  m1.ca error layer met1 at (5000 nm, 300 nm) measured 1030000 nm^2 against limit 1000000 nm^2
...
```

The critical area for a 150 nm half-side defect is 1.03 µm² against a 1 µm² limit. The rule
reports once, at the centre of the critical area's bounding box, naming no shape.

**Options.**

| Parameter | Value | Meaning |
|---|---|---|
| `radius` | length | The defect's half-side. |
| `radii` | list of lengths | The sampled half-sides, rising strictly. |
| `weights` | list of fractions | The weight of each half-side, from 0 to 1, one per radius. GPurify does not normalise them. |

**Status and limits.** Partial. Shorts only, between merged shapes of one layer: opens (a defect
cutting a wire) and shorts between nets rather than shapes are not computed. A layer with an edge
that is not horizontal or vertical is refused. The defect sizes, weights and limit are yours to
state: no public deck gives them.

**Sources.** Siemens Calibre YieldAnalyzer; C. H. Stapper, average critical area over a defect-size
distribution.

## Hotspots

### DRC-113: Litho and CMP hotspots

**What it catches.** A region whose metal density will polish out of flatness: a sharp step in
density between neighbouring windows, or a density far enough from the process target that the
film thickness leaves its range. Such hotspots pass every width and spacing rule and still fail in
polishing.

**How GPurify measures it.** This check runs with `gpurify erc`, not `drc`. Rectangular windows of
\\( W_x \times W_y \\) start at the die's lower-left corner and repeat every \\( S_x \\) and
\\( S_y \\) while they start inside the die, so an axis of length \\( L_x \\) has
\\( \lceil L_x / S_x \rceil \\) windows. The die is the deck's `boundary` layer, or the drawn
layers' extent. A window's density is

\\[ d_w = \frac{A(L \cap w \cap \text{die})}{A(w \cap \text{die})} \\]

so a window hanging past the die is measured over its part inside. With `partial_windows: false`,
only windows wholly inside the die are judged. A window fails when \\( d_w \\) is below `min` or above
`max`; when it differs by more than `max_delta` from the next window to its right or above it; or
when its first-order thickness excursion

\\[ t_w = k\,(d_w - d_0) \\]

has \\( |t_w| \\) above the model's `max_delta`, where \\( k \\) is the thickness sensitivity (film
thickness per unit of density) and \\( d_0 \\) the target density. The window stands for the
process's planarization length.

In the example, two 10 µm windows tile a 20 µm × 10 µm die: the left holds 90% met1, the right 20%.
Their difference, 0.7, exceeds 0.5. With \\( k = 400 \\) nm and \\( d_0 = 0.5 \\), the left window's
excursion is \\( 400 \times 0.4 = 160 \\) nm and the right's \\( 400 \times (-0.3) = -120 \\) nm, both
beyond 100 nm.

![Two 10 µm density windows over a 20 by 10 µm die, holding 90% and 20% met1; both windows and their step are marked as failing](../../diagrams/drc-113.svg)

**In the deck.**

```text
rule <id> density_cmp(<layer>; window: <length> x <length>, step: <length> x <length>, min: <fraction> | none, max: <fraction> | none, max_delta: <fraction> | none, partial_windows: <bool>, cmp: (target: <fraction>, sensitivity: <length>, max_delta: <length>) | none)
```

```text
grid 5nm
layer met1 = gds(68, 20)
layer prBoundary = gds(235, 4)
boundary prBoundary
rule m1.cmp density_cmp(met1; window: 10um x 10um, step: 10um x 10um, min: none, max: none, max_delta: 50%, partial_windows: false, cmp: (target: 50%, sensitivity: 400nm, max_delta: 100nm))
```

**Example violation.**

```sh
gpurify erc cmp.gds --deck cmp.deck
```

```text
rules:
  m1.cmp: ran, examined 2 shapes, found 3 violations
violations: 3
  m1.cmp error layer met1 at (5000 nm, 5000 nm) measured 160 nm against limit 100 nm on shape 0
  m1.cmp error layer met1 at (5000 nm, 5000 nm) measured 0.7 against limit 0.5 on shape 0
  m1.cmp error layer met1 at (15000 nm, 5000 nm) measured 120 nm against limit 100 nm on shape 1
...
```

The left window, centred at (5 µm, 5 µm), has a 160 nm excursion against 100 nm and a 0.7 density
step against 0.5; the right window has a 120 nm excursion. For this rule, `examined` counts the
windows judged.

**Options.**

| Parameter | Value | Meaning |
|---|---|---|
| `window` | `w x h` | The window's width and height. |
| `step` | `x x y` | How far each window starts from the one before it, along x and along y. |
| `min` | fraction or `none` | The least density a window may have. |
| `max` | fraction or `none` | The most density a window may have. |
| `max_delta` | fraction or `none` | The largest density difference between a window and the next one to its right or above it. |
| `partial_windows` | `true` or `false` | Whether windows that hang past the die are judged. |
| `cmp` | group or `none` | The thickness model: `target`, the density the process polishes flat; `sensitivity`, the thickness change per unit of density; `max_delta`, the largest excursion allowed. |

At least one of `min`, `max`, `max_delta` and `cmp` must be stated.

**Status and limits.** Partial. Only the density step and the first-order thickness excursion are
computed. Lithography hotspots (aerial-image and process-window simulation) and a full CMP
topography simulation need a foundry's calibrated optical, resist and polish models, which no open
PDK publishes. The shipped sky130 deck uses this check for SkyWater's maximum metal density, a
700 µm window stepped 70 µm, as a warning.

**Sources.** Siemens Calibre LFD and CMPAnalyzer; Cadence Pegasus; D. O. Ouma et al.,
"Characterization and modeling of oxide chemical-mechanical polishing using planarization length
and pattern density concepts", IEEE Transactions on Semiconductor Manufacturing 15(2), 2002.

### DRC-114: Pattern-matching DRC

**What it catches.** A known bad configuration of shapes, a hotspot, wherever it occurs. Some
layouts fail in lithography although every rule passes; a foundry collects them as patterns and
asks that none appear.

**How GPurify measures it.** A pattern is a window \\( [0, w] \times [0, h] \\), the rectangles that
must lie in it, and optional don't-care boxes. GPurify places the pattern at every corner of the
layer, in each of the eight orientations (four turns, mirrored or not). A placement matches when the
layer clipped to the window equals the pattern's rectangles exactly, outside the don't-care boxes.
A shape that runs past the window's edge is clipped there, so a rectangle that reaches the edge
matches a wire of any length. Each matching window is reported once, at its centre, with the
pattern's area.

![Two met1 lines tip to tip 200 nm apart inside a 1 µm by 600 nm pattern window, matched; a pair 300 nm apart does not match](../../diagrams/drc-114.svg)

**In the deck.**

```text
rule <id> pattern(<layer>; window: <w> x <h>, shapes: [<x> x <y>, ..], ignore: [<x> x <y>, ..] | none)
```

```text
grid 5nm
layer met1 = gds(68, 20)
rule m1.hotspot pattern(met1; window: 1um x 600nm, shapes: [0nm x 200nm, 400nm x 400nm, 600nm x 200nm, 1000nm x 400nm], ignore: none)
```

**Example violation.**

```text
rules:
  m1.hotspot: ran, examined 128 shapes, found 1 violations
violations: 1
  m1.hotspot error layer met1 at (5100 nm, 1100 nm) measured 160000 nm^2 against limit 0 nm^2
...
```

The two line ends 200 nm apart match the pattern; the window is centred at (5.1 µm, 1.1 µm), and
the measured value is the pattern's 0.16 µm² of shapes. The pair 300 nm apart does not match. For
this rule, `examined` counts the placements tried.

**Options.**

| Parameter | Value | Meaning |
|---|---|---|
| `window` | `w x h` | The pattern's window, from (0, 0). |
| `shapes` | list of points | The pattern's rectangles, two opposite corners each, so two points per rectangle. |
| `ignore` | list of points or `none` | Don't-care boxes, two corners each, where anything matches. |

Every rectangle and box lies inside the window, and the shapes need a corner strictly inside the
window and outside every don't-care box, or the deck is refused.

**Status and limits.** Partial. Edges match exactly, and a pattern is one layer: ranged (fuzzy)
edges and multi-layer patterns are not supported. Foundry hotspot libraries are not public, so the
patterns are yours to supply. A layer with an edge that is not horizontal or vertical is refused.

**Sources.** Siemens Calibre; Synopsys IC Validator; Cadence Pegasus; US patent 7,757,190 B2
([Google Patents](https://patents.google.com/patent/US7757190B2)); US patents 11,487,930 B2 and
9,171,126 B1 for fuzzy and multi-layer patterns.

## Custom and all-angle rules

### DRC-115: Equation-based DRC

**What it catches.** A rule whose limit is a formula over measured values rather than one number,
such as a space that grows with the run length and the widths of both wires. Calibre's eqDRC
states such rules as expressions.

**How GPurify measures it.** A custom rule is a function written against GPurify's library
interface. It reads the layout's shapes and nets, measures what it needs, and reports findings
under its rule id. GPurify runs and accounts it as any other rule: it is skipped when its layers
are empty, and refused if it reports a finding on a layer it did not declare, outside the layout,
or with a value that is not finite.

![A custom rule reading two met1 shapes and computing their limit from their widths, compared with the measured gap](../../diagrams/drc-115.svg)

**In the deck.** Nothing to write in the text deck: it has no expression language. A custom rule is
added to the deck through the library interface.

**Example violation.** A custom rule reports its findings in the same lines as any rule, under its
id. The text deck cannot state one, so this page has no run to show.

**Status and limits.** Partial. Equation-based rules are written as code, not in the text deck.
Many table-driven cases need no code: see the spacing tables on the spacing checks page.

**Sources.** Siemens Calibre eqDRC (fact sheet 82854-F).

### DRC-116: All-angle DRC

**What it catches.** Violations on shapes with edges at any angle, such as curved guard rings,
round pads or inductors, which GDSII stores as polygons with many short slanted edges. A checker
that refuses or snaps such edges misses violations there or reports false ones.

**How GPurify measures it.** Edges at any angle load, and derived layers compute on them. Where two
slanted edges cross between grid points, the crossing is rounded to the nearest grid point, half
away from zero, and every edge passing that close is bent through it, so rounding creates no new
crossing. The checks listed below measure slanted edges exactly: a distance to a slanted edge is a
fraction, compared with the limit exactly and reported rounded down.

In the example, a met1 triangle has an edge along the direction (5, 1) from the origin, and a met1
square has its corner at (10 nm, 7 nm). The distance from the corner to the edge is
\\( |5 \cdot 7 - 1 \cdot 10| / \sqrt{26} = 25/\sqrt{26} \approx 4.90 \\) nm: it fails a 5 nm space,
would pass a 4 nm one, and is reported as 4 nm.

![A met1 triangle with an edge of slope 1/5 and a met1 square whose corner is 25/√26 nm from that edge, against a 5 nm space](../../diagrams/drc-116.svg)

**In the deck.** Nothing extra to write: these checks take layers with slanted edges as they are.

```text
rule <id> width(<layer>) >= <length>
rule <id> space(<layer>[, <other>]) >= <length>
```

```text
grid 1nm
layer met1 = gds(68, 20)
rule m1.space space(met1) >= 5nm
```

**Example violation.**

```text
rules:
  m1.space: ran, examined 1 shapes, found 1 violations
violations: 1
  m1.space error layer met1 at (10 nm, 4 nm) measured 4 nm against limit 5 nm on shape 0 and shape 1
...
```

The square's corner is 4.90 nm from the triangle's slanted edge, reported as 4 nm, against a
5 nm minimum.

**Status and limits.** Partial. These checks measure layers with edges at any angle: `width`,
`notch`, `space` (one layer and two), `area`, `hole_area`, `edge_length`, `forbidden`, `inside`,
`contains`, and `enclosure` on every side and `noncoincident`. Every other check reports `refused`
on such a layer, `enclosure` with `opposite` or `adjacent` among them, and so do the layer
operations `.with_rect` and `.extended`. There is no tolerance option, since the measurement is
exact, and no true curves: GDSII has none, so a curve arrives as a polygon. See
[issue 18, all-angle DRC](https://github.com/OpenFAT/GPurify/issues/18).

**Sources.** Siemens Calibre; Silvaco; Empyrean; J. D. Hobby, "Practical segment intersection with
finite precision output", Computational Geometry 13, 1999; L. Guibas and D. Marimont, "Rounding
arrangements dynamically", International Journal of Computational Geometry and Applications 8,
1998.

## Via redundancy

### DRC-117: Via redundancy scoring

**What it catches.** Too many single-cut vias where a second cut would fit. A single cut that fails
opens the net, while a via with two cuts survives one failure, so foundries ask for doubled vias
wherever there is room and track the share that has them.

**How GPurify measures it.** A via is the cuts joining one merged `lower` shape to one merged
`upper` shape. A single-cut via is dead when no second cut fits beside it: GPurify moves its cut
by `pitch` left, right, up and down, and the via is alive if one of those positions lies wholly on
both metals and at least `space` from every cut. The redundant-via rate is

\\[ R = 1 - \frac{N_\text{dead}}{N_\text{via}} \\]

where \\( N_\text{via} \\) counts every via and \\( N_\text{dead} \\) the dead ones. The rule reports
once, at the first dead via's cut, when \\( R \\) is below the limit.

In the example, three vias join met1 and met2 with 150 nm cuts, a 320 nm pitch and a 170 nm
space. Via A sits on 1 µm plates and has room for a second cut. Via B sits on 290 nm pads with no
room. Via C already has two cuts. So \\( R = 1 - 1/3 = 0.667 \\), under the 90% limit.
`redundant_via` counts cuts instead: a cut with fewer than the limit cuts, itself included, within
`within` of it, edge to edge, is reported.

![Three met1 and met2 vias: one single cut with room for a second, one single cut on small pads marked dead, one with two cuts](../../diagrams/drc-117.svg)

**In the deck.**

```text
rule <id> via_redundancy(<cut>, <lower>, <upper>; pitch: <length>, space: <length>) >= <fraction>
rule <id> redundant_via(<cut>; within: <length>) >= <count>
```

```text
grid 5nm
layer met1 = gds(68, 20)
layer via = gds(68, 44)
layer met2 = gds(69, 20)
rule via.rate via_redundancy(via, met1, met2; pitch: 320nm, space: 170nm) >= 90%
rule via.double redundant_via(via; within: 200nm) >= 2
```

**Example violation.**

```text
rules:
  via.rate: ran, examined 3 shapes, found 1 violations
  via.double: ran, examined 4 shapes, found 2 violations
violations: 3
  via.rate error layer via at (3145 nm, 145 nm) measured 0.6666666666666667 against limit 0.9
  via.double error layer via at (3145 nm, 145 nm) measured 1 against limit 2 on shape 7
  via.double error layer via at (275 nm, 275 nm) measured 1 against limit 2 on shape 6
...
```

The design's rate is 0.667 against 0.9, reported at via B's cut. `redundant_via` flags both single
cuts, A and B, with one cut each against 2.

**Options.**

| Parameter | Value | Meaning |
|---|---|---|
| `pitch` | length | How far the second cut sits from the first, centre to centre. |
| `space` | length | The least gap from the second cut to every cut, the first included. |
| `within` | length | For `redundant_via`: how far, edge to edge, another cut may be and still count. |

**Status and limits.** Partial. The check scores vias; it does not add cuts. Adding the second cuts
is the `enhance` command's job. Where a second cut may go, the pitch and the space, is yours to
state. The rate and the limit are yours too: no public deck gives them.

**Sources.** Siemens Calibre YieldAnalyzer and YieldEnhancer; Siemens white paper 81850 on
critical-area yield models; G. Xu, L.-D. Huang, D. Z. Pan and M. D. F. Wong, "Redundant-via
enhanced maze routing for yield improvement", ASP-DAC 2005.
