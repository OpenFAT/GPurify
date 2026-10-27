# Planarity checks

Planarity checks find metal density that chemical-mechanical polishing (CMP) turns into uneven
thickness. GPurify measures density in windows across the die and predicts each window's polish
excursion from it.

## Density and polish thickness

### ERC-B1: Windowed density and CMP thickness

**What it catches.** A window of the die where a layer's density is below or above the foundry's
range, a sudden jump in density between neighbouring windows, and a window whose density would
polish the layer too thin or too thick. Polishing removes material faster over sparse regions and
slower over dense ones. The resulting thickness steps change wire resistance and capacitance, and
leave dishing and erosion that later layers cannot planarise.

**How GPurify measures it.** GPurify lays a grid of windows on the die, starting at its lower-left
corner and stepping by `step` while a window's corner still lies inside the die. A window's density
is the area of the layer inside it, overlaps counted once, over the window's area inside the die.
It flags a density below `min` or above `max`, and a difference above `max_delta` between a window
and its next window to the right or above. With `cmp`, the predicted thickness excursion is
`sensitivity × (density − target)`, and a window is flagged when its size exceeds the model's
`max_delta`. A finding sits at the centre of the window.

![A 20 µm die cut into four 10 µm met1 windows; the 0.875 and 0.125 windows are marked as failing](../../diagrams/erc-b1.svg)

The die is the extent of the shapes on the deck's `boundary` layer. Without a `boundary` statement,
or with nothing drawn on that layer, it is the extent of every drawn layer. With
`partial_windows: false`, a window that reaches past the die is not held to any limit, the
neighbour step included. With `partial_windows: true`, it is held to every limit, its density taken
over the part inside the die.

**In the deck.**

```text
rule <id> density_cmp(<layer>; window: <length> x <length>, step: <length> x <length>,
    min: <fraction> | none, max: <fraction> | none, max_delta: <fraction> | none,
    partial_windows: true | false,
    cmp: (target: <fraction>, sensitivity: <length>, max_delta: <length>) | none)
```

```text
grid 5nm
layer met1 = gds(5, 0)
layer outline = gds(20, 0)
boundary outline
rule m1.density density_cmp(met1; window: 10um x 10um, step: 10um x 10um,
    min: 0.2, max: 0.8, max_delta: 0.5, partial_windows: false,
    cmp: (target: 0.5, sensitivity: 80nm, max_delta: 25nm))
```

```sh
gpurify erc density.gds --deck planarity.deck
```

**Example violation.**

```text
rules:
  m1.density: ran, examined 4 shapes, found 6 violations
violations: 6
  m1.density error layer met1 at (5000 nm, 5000 nm) measured 30 nm against limit 25 nm on shape 0
  m1.density error layer met1 at (5000 nm, 5000 nm) measured 0.625 against limit 0.5 on shape 0
  m1.density error layer met1 at (5000 nm, 5000 nm) measured 0.625 against limit 0.5 on shape 0
  m1.density error layer met1 at (5000 nm, 5000 nm) measured 0.875 against limit 0.8 on shape 0
  m1.density error layer met1 at (15000 nm, 15000 nm) measured 30 nm against limit 25 nm on shape 2
  m1.density error layer met1 at (15000 nm, 15000 nm) measured 0.125 against limit 0.2 on shape 2
...
```

The lower-left window, centred at (5 µm, 5 µm), holds 0.875 met1 against a 0.8 maximum. It steps
by 0.625 to each of its two neighbours of 0.25, against a 0.5 limit, and polishes 80 nm × 0.375 =
30 nm off target, against 25 nm. The upper-right window holds 0.125 against a 0.2 minimum and
polishes 30 nm off target the other way. The count after `examined` is the number of windows held
to the limits.

**Options.**

| Parameter | Value | Meaning |
|---|---|---|
| `window` | length `x` length | The window's width and height. |
| `step` | length `x` length | How far the window moves across and up. A step smaller than the window gives overlapping windows. |
| `min` | fraction or `none` | The least density a window may hold. |
| `max` | fraction or `none` | The most density a window may hold. |
| `max_delta` | fraction or `none` | The largest density difference between a window and its neighbour one step to the right or one step up. |
| `partial_windows` | `true` or `false` | Whether a window that reaches past the die is held to the limits. |
| `cmp` | group or `none` | The polish model: `target`, the density that polishes to nominal thickness; `sensitivity`, the thickness change per unit of density; `max_delta`, the largest excursion allowed. |

A row needs at least one of `min`, `max`, `max_delta` and `cmp`: GPurify refuses a row that bounds
nothing, since it would always pass. A window or step that is not positive is refused.

**Status and limits.** Implemented. The polish model is first order: the excursion is linear in
the window's own density, with the window standing for the planarisation length. It predicts the
step from nominal, not an absolute thickness, and has no neighbour smoothing, dishing or erosion
model. No open PDK publishes the calibration (`target`, `sensitivity`), so the deck states it.
The shipped sky130 deck holds met1 to met4 to a 0.7 maximum in 700 µm windows stepped by 70 µm,
whole windows only, as warnings. For a density rule reported as DRC, with a single density limit
per row, see the DRC density checks.

**Sources.** GlobalFoundries GF180MCU design rule manual, section 13 (dummy fill rules and
guidelines); LEF/DEF 5.8 `MINIMUMDENSITY`, `MAXIMUMDENSITY`, `DENSITYCHECKWINDOW` and
`DENSITYCHECKSTEP`, as the sky130 standard-cell technology LEF states them; D. O. Ouma et al.,
"Characterization and modeling of oxide chemical-mechanical polishing using planarization length
and pattern density concepts", IEEE Transactions on Semiconductor Manufacturing 15(2), 2002.
