# Fill and enhance

Two statements configure the layout edits that `gpurify fill` and `gpurify enhance` make: `fill`
draws density fill, and `widen` widens power straps. Neither is a check. Each command writes the
edited layout, then runs the deck's DRC rules on what it wrote, so the rules check the edit.

```text
fill <layer> for <density layer> size <len> space <len> keep <len> avoid [<layer>, ...]
widen <layer> net "<pattern>" by <len>
```

```sh
gpurify fill layout.gds filled.gds --deck process.deck
gpurify enhance layout.gds enhanced.gds --deck process.deck
```

## Density fill

`fill` draws fill on `<layer>`, a drawn layer, for the `density` and `global_density` rules that
measure `<density layer>`, usually the metal and its fill together:

- **Squares** `size` on a side, on a grid `size + space` apart, from the lower-left corner of the
  rules' die (their boundary layer, or the drawn layers' extent), wholly inside it.
- **Clearance.** A square is drawn only at least `keep` from every shape of the `avoid` layers,
  measured square to them, so a corner keeps it diagonally too. It also keeps `space` from fill
  already on the layer, and lies on nothing of the density layer.
- **Amount.** Squares are taken in rows from the bottom, left to right. Each is drawn only while a
  window it lies in is below a minimum, and only if no window it lies in then passes a maximum.
  Fill brings each window up to its minimum and never past a maximum.

A window with no room left stays short, and its rule reports it. Every value is required: `size`
and `space` are positive, `keep` is zero or more. A `fill` line whose density layer no `density`
or `global_density` rule measures is refused when fill runs, since nothing says how much to draw.
Fill does not read `density_balance`, `cover_density` or `density_cmp` rules, and two `fill` lines
for one density layer each fill as if the other drew nothing.

```text
grid 5nm
layer met1       = gds(10, 0)
layer met1_label = gds(10, 5)
layer met1_fill  = gds(10, 28)
layer nofill     = gds(10, 99)
layer outline    = gds(235, 4)
layer met1_all   = met1 or met1_fill

rule M1.PD.MIN density(met1_all, outline; window: 4um, step: 2um) >= 0.3
rule M1.PD.MAX density(met1_all, outline; window: 4um, step: 2um) <= 0.7
rule M1.FILL.S space(met1_fill, met1) >= 300nm

fill met1_fill for met1_all size 500nm space 300nm keep 300nm avoid [met1, nofill]
```

The layout is an 8 µm square die outline with one met1 wire 500 nm wide across it and a 1 µm
no-fill marker near its top-right corner. Before the fill, all nine windows are below 30%:

```sh
gpurify fill fill.gds filled.gds --deck fill.deck
```

```text
rules:
  M1.PD.MIN: ran, examined 9 shapes, found 1 violations
  M1.PD.MAX: ran, examined 9 shapes, found 0 violations
  M1.FILL.S: ran, examined 0 shapes, found 0 violations
violations: 1
  M1.PD.MIN error layer met1_all at (6000 nm, 6000 nm) measured 0.25 against limit 0.3 on shape 112
...
wrote filled.gds: 68 fill squares
```

Fill draws 68 squares and brings eight windows to 30% or more. The window centred at
(6000 nm, 6000 nm) holds the no-fill marker, has no room left, and stays at 25%. The last line goes
to standard error.

## Widened straps

`widen <layer> net "<pattern>" by <len>` widens power straps. Each rectangle on `<layer>`, a drawn
layer, whose net carries a label matching the pattern gains a strip `by` wide along each of its two
long sides. The pattern is a glob: `*` matches any run of characters and `?` one. `by` is positive.

A strip that would touch a shape of another net, on the layer or through a cut that joins it, is
never drawn. A strip that adds a DRC violation is taken back.

```text
widen met2 net "A" by 100nm
```

On the [tutorial layout](../../tutorials/first-deck.md), with the tutorial deck's connectivity and
`rule M2.W width(met2) >= 200nm`, `rule M2.S space(met2) >= 200nm`:

```sh
gpurify enhance two_metal.gds widened.gds --deck widen.deck
```

```text
...
wrote widened.gds: 0 redundant cuts, 2 strap sides widened
```

## Redundant cuts

`gpurify enhance` also adds redundant cuts, configured by the deck's
`via_redundancy(cut, lower, upper; pitch: len, space: len)` rules rather than a statement. Beside
each single-cut via, it draws the first of its cut's four neighbours one `pitch` away that the
rule finds room for. For a dead via, one with no such room, it draws the first neighbour at least
`space` from every cut, and extends each metal that does not hold it by the box round both cuts,
grown by the margin the metal leaves round the via's own cut. The `via_redundancy` check is on the
[DRC checks](../drc/README.md) page.

## Status and limits

Fill is density-driven only; it does not read timing. See
[issue 15](https://github.com/OmarSiwy/GPurify/issues/15) for fill and
[issue 17](https://github.com/OmarSiwy/GPurify/issues/17) for enhancement.
