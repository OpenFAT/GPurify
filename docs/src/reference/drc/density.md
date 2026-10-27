# Density checks

Density checks measure how much of an area a layer covers: over the whole die, in windows swept
across it, or inside the shapes of another layer. Chemical-mechanical polishing (CMP) dishes wide
open metal and erodes dense metal, so foundries bound the coverage of each layer and ask for fill
and slots to keep it in range.

## Die and window density

### DRC-070: Global density

**What it catches.** A layer that covers too little or too much of the whole die. A die with too
little metal dishes during polishing, and one with too much erodes, so the oxide over it ends up
uneven and the layers above it lose focus and planarity.

**How GPurify measures it.** GPurify merges the layer, clips it to the die and divides the area it
covers by the die's area:

\\[ D = \frac{A_L}{A_\text{die}} \\]

where \\( A_L \\) is the area of the layer inside the die, overlaps counted once, and
\\( A_\text{die} \\) is the area of the die's bounding box. The die is the bounding box of the
rule's boundary layer when you name one, and otherwise the bounding box of every drawn layer. A
derived layer never widens the die. In the example below, metal1 covers 100 µm × 30 µm of a
100 µm × 100 µm die, so \\( D = 3000 / 10000 = 0.30 \\), under the 35% minimum. A density is a
fraction from 0 to 1: the deck writes a limit as `0.35` or `35%`, the report prints it bare, and a
density equal to the limit passes.

![A 100 by 100 µm die with metal1 covering its lower 30 µm, marked as failing a 35% minimum density](../../diagrams/drc-070.svg)

**In the deck.**

```text
rule <id> global_density(<layer>[, <boundary>]) >= <fraction>
rule <id> global_density(<layer>[, <boundary>]) <= <fraction>
```

```text
grid 5nm
layer metal1 = gds(8, 0)
layer prboundary = gds(189, 0)
rule M1.j global_density(metal1, prboundary) >= 35%
rule M1.k global_density(metal1, prboundary) <= 60%
```

**Example violation.**

```text
rules:
  M1.j: ran, examined 1 shapes, found 1 violations
  M1.k: ran, examined 1 shapes, found 0 violations
violations: 1
  M1.j error layer metal1 at (50000 nm, 50000 nm) measured 0.3 against limit 0.35 on shape 0
...
```

Metal1 covers 30% of the die against IHP's 35% minimum; the marker is the die's centre.

**Status and limits.** Implemented. A layer with an edge that is not horizontal or vertical is
refused. The deck's `boundary` line does not apply here: name the boundary layer in the rule.
When a deck counts fill toward density, as most foundries do, write the rule on a derived layer
such as `metal1 or metal1_filler`.

**Sources.** IHP SG13G2 layout rules M1.j and M1.k
([IHP Open PDK](https://github.com/IHP-GmbH/IHP-Open-PDK)); GlobalFoundries GF180MCU PL.8 and
Mn.4 ([GF180MCU design manual](https://gf180mcu-pdk.readthedocs.io/en/latest/physical_verification/design_manual/));
SkyWater SKY130 m1.13 ([SKY130 periphery rules](https://skywater-pdk.readthedocs.io/en/main/rules/periphery.html));
LEF/DEF 5.8 Language Reference, `MINIMUMDENSITY` and `MAXIMUMDENSITY`.

### DRC-071: Windowed density

**What it catches.** A region of the die where a layer is too sparse or too dense, even when the
whole die is in range. Polishing responds to the density over a few hundred micrometres, so a
foundry checks a square window at every step across the die.

**How GPurify measures it.** Square windows of side \\( W \\) start at the die's lower-left corner
\\( (x_0, y_0) \\) and repeat every step \\( S \\) along each axis, until they cover the die. Along
an axis of length \\( L_x \\) there are

\\[ n_x = \left\lceil \frac{\max(L_x - W,\ 0)}{S} \right\rceil + 1 \\]

windows, with lower-left corners at \\( x_0 + iS \\) for \\( i = 0, \dots, n_x - 1 \\), and the same
along y. The density of a window \\( w \\) is

\\[ d_w = \frac{A(L \cap w \cap \text{die})}{W^2} \\]

where \\( A(L \cap w \cap \text{die}) \\) is the area of the merged layer inside both the window and
the die, and \\( W^2 \\) is the whole window's area. The last window along an axis can hang past the
die; the part outside counts as empty, so it still divides by \\( W^2 \\). A die smaller than one
window gets one window. The die is found as for `global_density`. Each failing window is reported
at its centre.

In the example, the die is 1600 µm square, \\( W = 800 \\) µm and \\( S = 400 \\) µm, so
\\( n_x = n_y = \lceil 800 / 400 \rceil + 1 = 3 \\) and there are 9 windows. Metal1 covers the die
except its upper-right quadrant, which holds one 200 µm × 200 µm block. The window from
(800 µm, 800 µm) to (1600 µm, 1600 µm) has \\( d = 200^2 / 800^2 = 0.0625 \\), under the 25%
minimum. Had the die been 1500 µm wide, the windows would still start at 0, 400 and 800 µm, and the
last column would hang 100 µm past the die: fully covered, it would read \\( 700/800 = 0.875 \\).

![Nine overlapping 800 µm windows stepped 400 µm over a 1600 µm die; the upper-right window, holding one 200 µm block, fails](../../diagrams/drc-071.svg)

**In the deck.**

```text
rule <id> density(<layer>[, <boundary>]; window: <length>, step: <length>) >= <fraction>
rule <id> density(<layer>[, <boundary>]; window: <length>, step: <length>) <= <fraction>
```

```text
grid 5nm
layer metal1 = gds(8, 0)
layer prboundary = gds(189, 0)
rule M1Fil.h density(metal1, prboundary; window: 800um, step: 400um) >= 25%
```

**Example violation.**

```text
rules:
  M1Fil.h: ran, examined 9 shapes, found 1 violations
violations: 1
  M1Fil.h error layer metal1 at (1200000 nm, 1200000 nm) measured 0.0625 against limit 0.25 on shape 2
...
```

The window centred at (1200 µm, 1200 µm) holds 6.25% metal1 against the 25% minimum. For this
rule, `examined` counts windows.

**Options.**

| Parameter | Value | Meaning |
|---|---|---|
| `window` | length | The side of the square window. |
| `step` | length | How far each window starts from the one before it, along x and along y. |

**Status and limits.** Implemented. Windows are square; for a rectangular window, or one clipped to
the die rather than padded with empty space, use `density_cmp` (see
[DRC-113](dfm.md#drc-113-litho-and-cmp-hotspots)). A layer with an edge that is not horizontal or
vertical is refused.

**Sources.** IHP SG13G2 layout rules MFil.h and AFil.g2, 800 µm window stepped 400 µm
([IHP Open PDK](https://github.com/IHP-GmbH/IHP-Open-PDK)); SkyWater SKY130 m1.pd.2a and m1.pd.2b
([SKY130 periphery rules](https://skywater-pdk.readthedocs.io/en/main/rules/periphery.html));
GlobalFoundries GF180MCU density test structures; LEF/DEF 5.8 Language Reference,
`DENSITYCHECKWINDOW` and `DENSITYCHECKSTEP`; KLayout `with_density`
([KLayout DRC reference](https://www.klayout.de/doc/about/drc_ref_layer.html)).

## Density over a region

### DRC-072: Local density over a device

**What it catches.** Too much or too little of a layer over a device, such as metal over a
capacitor. Dense metal above a device changes the polish over it and couples to it, so the
foundry bounds the pattern density over the device's own area.

**How GPurify measures it.** For each shape \\( r \\) of the region layer, merged, GPurify divides
the area of the measured layer inside it by the shape's own area:

\\[ d_r = \frac{A(L \cap r)}{A(r)} \\]

where \\( A(r) \\) excludes the shape's holes. Each region shape is judged on its own and reported
at the centre of its first rectangle. In the example, met3 strips cover 8 µm × 10 µm of a
10 µm × 10 µm capacitor, so \\( d = 80 / 100 = 0.8 \\), over the 70% maximum.

![A 10 µm capacitor marker with four 2 µm met3 strips covering 80% of it, against a 70% maximum](../../diagrams/drc-072.svg)

**In the deck.**

```text
rule <id> region_density(<layer>, <region>) <= <fraction>
rule <id> region_density(<layer>, <region>) >= <fraction>
```

```text
grid 5nm
layer capacitor = gds(82, 64)
layer met3 = gds(70, 20)
rule cap.density region_density(met3, capacitor) <= 70%
```

**Example violation.**

```text
rules:
  cap.density: ran, examined 1 shapes, found 1 violations
violations: 1
  cap.density error layer capacitor at (5000 nm, 5000 nm) measured 0.8 against limit 0.7 on shape 0
...
```

Met3 covers 80% of the capacitor against a 70% maximum. The violation is reported on the region
layer, at the capacitor's centre.

**Status and limits.** Implemented. A layer with an edge that is not horizontal or vertical is
refused. The 70% limit in the example is illustrative; take the value from your foundry's manual.

**Sources.** SkyWater SKY130 vpp.5a to vpp.5c and vpp.11
([SKY130 periphery rules](https://skywater-pdk.readthedocs.io/en/main/rules/periphery.html)).

## Fill

### DRC-073: Fill geometry and fill-to-drawn spacing

**What it catches.** Dummy fill shapes of the wrong size, too close to each other, or too close to
drawn layout. Fill raises density for polishing, but fill near a wire adds coupling capacitance,
and fill of the wrong size does not print.

**How GPurify measures it.** There is no fill check of its own. Fill sits on its own layer, and the
ordinary `width` and `space` checks hold it: `width` on the fill layer for
its size, and `space` between the fill layer and the drawn layer for its clearance, measured as on
[How GPurify measures distances](../../explanation/measuring.md).

![A metal1 wire with a 2 µm filler square 300 nm above it, against a 420 nm fill-to-metal space](../../diagrams/drc-073.svg)

**In the deck.**

```text
rule <id> width(<fill>) >= <length>
rule <id> width(<fill>) <= <length>
rule <id> space(<fill>) >= <length>
rule <id> space(<fill>, <drawn>) >= <length>
```

```text
grid 5nm
layer metal1 = gds(8, 0)
layer metal1_filler = gds(8, 22)
rule M1Fil.a1 width(metal1_filler) >= 1um
rule M1Fil.a2 width(metal1_filler) <= 5um
rule M1Fil.c space(metal1_filler, metal1) >= 420nm
```

**Example violation.**

```text
rules:
  M1Fil.a1: ran, examined 2 shapes, found 1 violations
  M1Fil.a2: ran, examined 2 shapes, found 0 violations
  M1Fil.c: ran, examined 1 shapes, found 1 violations
violations: 2
  M1Fil.a1 error layer metal1_filler at (4400 nm, 1900 nm) measured 800 nm against limit 1000 nm on shape 2
  M1Fil.c error layer metal1_filler at (1000 nm, 1150 nm) measured 300 nm against limit 420 nm on shape 1 and shape 0
...
```

A filler square sits 300 nm above the metal1 wire against IHP's 420 nm minimum, and an 800 nm
filler is under the 1 µm minimum width.

**Status and limits.** Expressible. Write each fill rule with the general checks. To add fill
rather than check it, use the `fill` command.

**Sources.** IHP SG13G2 layout rules AFil, GFil and MFil
([IHP Open PDK](https://github.com/IHP-GmbH/IHP-Open-PDK)); GlobalFoundries GF180MCU DCF, DPF and
DM ([GF180MCU design manual](https://gf180mcu-pdk.readthedocs.io/en/latest/physical_verification/design_manual/));
LEF/DEF 5.8 Language Reference, `FILLACTIVESPACING`.

### DRC-074: No-fill and exclusion regions

**What it catches.** Fill drawn inside a region marked to stay free of it, such as over an
inductor, a sensitive analogue block or a fuse. Fill there changes the device it sits over.

**How GPurify measures it.** There is no exclusion check of its own. The overlap of the fill layer
and the exclusion marker is a derived layer, and `forbidden` reports each of its shapes with its
area.

![A metal1 filler square crossing the edge of a metal1 no-fill marker, the overlap marked as the violation](../../diagrams/drc-074.svg)

**In the deck.**

```text
rule <id> forbidden(<fill> and <exclusion>)
```

```text
grid 5nm
layer metal1_filler = gds(8, 22)
layer metal1_nofill = gds(8, 23)
layer fill_in_nofill = metal1_filler and metal1_nofill
rule M1.nofill forbidden(fill_in_nofill)
```

**Example violation.**

```text
rules:
  M1.nofill: ran, examined 1 shapes, found 1 violations
violations: 1
  M1.nofill error layer fill_in_nofill at (9000 nm, 6000 nm) measured 2000000 nm^2 against limit 0 nm^2 on shape 3
...
```

A 2 µm filler square reaches 1 µm into the no-fill region, an overlap of 2 µm². To flag fill that
only touches the region too, write `metal1_filler.interacting(metal1_nofill)` instead; to keep fill
a distance away, write `space(metal1_filler, metal1_nofill) >= <length>`.

**Status and limits.** Expressible. Write it with `forbidden` on a derived layer, or with `space`.

**Sources.** GlobalFoundries GF180MCU DCF.8a, DPF.15 and DM.8
([GF180MCU design manual](https://gf180mcu-pdk.readthedocs.io/en/latest/physical_verification/design_manual/));
IHP SG13G2 layout rules GFil.i and section 6.12
([IHP Open PDK](https://github.com/IHP-GmbH/IHP-Open-PDK)).

## Slotting

### DRC-075: Wide-metal slotting

**What it catches.** A wide metal plate with no slots, or too few. A solid plate dishes in
polishing and stresses the dielectric, so foundries cap the width of unslotted metal and ask for
slots (slits) through wide plates.

**How GPurify measures it.** Three checks combine. `cheesing` flags a merged shape larger than the
limit area that has no hole: a slot cut fully through the plate is a hole, a notch open to the
edge is not. `width(L) <= len` flags a plate wider than the limit in every direction, with the
slots removed from it. `region_density` holds the slot coverage of each plate, as in
[DRC-072](#drc-072-local-density-over-a-device).

![Two 40 µm metal1 plates: the solid one fails the width and cheesing limits; the one with a 3 µm slit passes](../../diagrams/drc-075.svg)

**In the deck.**

```text
rule <id> cheesing(<layer>) <= <area>
rule <id> width(<layer>) <= <length>
rule <id> region_density(<slot>, <plate>) >= <fraction>
```

```text
grid 5nm
layer metal1 = gds(8, 0)
layer metal1_slit = gds(8, 24)
layer metal1_wide = metal1 not metal1_slit
layer metal1_plate = metal1.with_rect(35um x 35um)
rule Slt.c.M1 width(metal1_wide) <= 30um
rule m1.slot cheesing(metal1_wide) <= 1000um2
rule m1.slit_density region_density(metal1_slit, metal1_plate) >= 5%
```

**Example violation.**

```text
rules:
  Slt.c.M1: ran, examined 2 shapes, found 1 violations
  m1.slot: ran, examined 2 shapes, found 1 violations
  m1.slit_density: ran, examined 2 shapes, found 1 violations
violations: 3
  Slt.c.M1 error layer metal1_wide at (20000 nm, 20000 nm) measured 40000 nm against limit 30000 nm on shape 3
  m1.slot error layer metal1_wide at (20000 nm, 20000 nm) measured 1600000000 nm^2 against limit 1000000000 nm^2 on shape 3
  m1.slit_density error layer metal1_plate at (20000 nm, 20000 nm) measured 0 against limit 0.05 on shape 6
...
```

The solid 40 µm plate is 40 µm wide against IHP's 30 µm maximum, has 1600 µm² with no slot against
the 1000 µm² limit, and holds 0% slit. The second plate, with a 3 µm × 30 µm slit through it, is
under 30 µm wide on each side of the slit, has a hole, and holds 5.6% slit: it passes all three.
The cheesing area and the slit density limits are illustrative.

**Status and limits.** Partial. The slot geometry (width, length, enclosure, spacing to vias) is
written with the general checks. Not checked: GlobalFoundries GF180MCU MSLOT.4b, a maximum slot
spacing, because the manual does not say which slots it holds and GlobalFoundries' own deck checks
only the minimum; and MSLOT.6, staggered slots, which the manual states with no geometry.

**Sources.** IHP SG13G2 layout rules Slt.a to Slt.i
([IHP Open PDK](https://github.com/IHP-GmbH/IHP-Open-PDK)); GlobalFoundries GF180MCU MSLOT
([GF180MCU design manual](https://gf180mcu-pdk.readthedocs.io/en/latest/physical_verification/design_manual/));
SkyWater SKY130 m1.11 and m1.12
([SKY130 periphery rules](https://skywater-pdk.readthedocs.io/en/main/rules/periphery.html)).

## Density under a cover layer

### DRC-076: Waffle-window density

**What it catches.** A window where a cover layer, such as a waffle-drop fill marker, covers a
large share of the area, but the held layer is not dense enough for that share. SkyWater's
waffle-drop rules ask a window that the waffle marker covers heavily to carry a minimum metal
density.

**How GPurify measures it.** Windows are laid and swept as for `density`
([DRC-071](#drc-071-windowed-density)). In each window \\( w \\) of side \\( W \\), GPurify computes
the cover's coverage and the held layer's density:

\\[ c_w = \frac{A(C \cap w \cap \text{die})}{W^2}, \qquad d_w = \frac{A(L \cap w \cap \text{die})}{W^2} \\]

where \\( C \\) is the cover layer and \\( L \\) the held layer. The bands are pairs
\\( (c_k, d_k) \\) with \\( c_k \\) rising. The window falls in the last band whose \\( c_k \\) it
reaches (\\( c_w \ge c_k \\) with `inclusive: true`, \\( c_w > c_k \\) with `inclusive: false`), and
fails when \\( d_w < d_k \\). A window below every band is not judged.

In the example, two 700 µm windows, stepped 700 µm, tile a 1400 µm × 700 µm die. In the left
window the waffle marker covers \\( c = 700 \times 630 / 700^2 = 0.9 \\), which reaches the 80% band,
so the window needs 65% metal; met1 covers \\( d = 350 \times 700 / 700^2 = 0.5 \\), and the window
fails. In the right window the marker covers 0.5, below every band, so nothing is asked.

![Two 700 µm windows: the left one, 90% under the waffle marker with 50% met1, fails its 65% band; the right one is in no band](../../diagrams/drc-076.svg)

**In the deck.**

```text
rule <id> cover_density(<layer>, <cover>[, <boundary>]; window: <length>, step: <length>, cover: [<fraction>, ..], density: [<fraction>, ..], inclusive: <bool>)
```

```text
grid 5nm
layer met1 = gds(68, 20)
layer cmm1_waffle = gds(62, 24)
layer prBoundary = gds(235, 4)
rule m1.waffle cover_density(met1, cmm1_waffle, prBoundary; window: 700um, step: 700um, cover: [80%], density: [65%], inclusive: true)
```

**Example violation.**

```text
rules:
  m1.waffle: ran, examined 2 shapes, found 1 violations
violations: 1
  m1.waffle error layer met1 at (350000 nm, 350000 nm) measured 0.5 against limit 0.65
...
```

The left window, centred at (350 µm, 350 µm), holds 50% met1 where its band asks 65%. The finding
names no shape.

**Options.**

| Parameter | Value | Meaning |
|---|---|---|
| `window` | length | The side of the square window. |
| `step` | length | How far each window starts from the one before it, along x and along y. |
| `cover` | list of fractions | Each band's lowest coverage by the cover layer, rising strictly, from 0 to 1. |
| `density` | list of fractions | Each band's minimum density of the held layer, one per `cover` entry. |
| `inclusive` | `true` or `false` | Whether a coverage exactly at a band's start is in that band. |

**Status and limits.** Implemented. The manual gives the 700 µm window and the bands but no window
step and no reading of a band's edge, so the deck states both. The shipped sky130 deck leaves the
rule out, because SkyWater's current manual lists the waffle-drop rules as obsolete.

**Sources.** SkyWater SKY130 m1.- to m4.- waffle-drop rules
([SKY130 periphery rules](https://skywater-pdk.readthedocs.io/en/main/rules/periphery.html)).
