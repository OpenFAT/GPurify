# Chip-level checks

These checks look at the chip as a whole: its seal ring, its pads, its frame and cell names, how
placed cells sit beside each other, and how dies line up in a stack. Most are written with the
general deck checks; the placement and stacking checks run on a DEF layout or a system file.

## Seal ring and pads

### DRC-095: Seal ring

**What it catches.** A chip with no seal ring, with more than one, with drawing outside it, or
with its seal ring away from the origin. The seal ring stops cracks and moisture from the sawn
edge reaching the circuit, and the foundry's frame generation expects it at a fixed place.

**How GPurify measures it.** The seal ring's geometry (its widths, spacings and cut sizes) is
written with the general checks. `count` counts the merged shapes on a layer in the whole layout,
touching shapes as one. `origin` takes the bounding box of every polygon on its layer and reports
its lower-left corner when that is not (0, 0), with its distance from the origin. To keep drawing
inside the ring, forbid what lies outside the ring and its hole.

![A seal ring whose lower-left corner is at (1 µm, 1 µm), flagged 1414 nm from the origin, and a met1 shape outside the ring, flagged](../../diagrams/drc-095.svg)

**In the deck.**

```text
rule <id> count(<layer>) <= <count>
rule <id> count(<layer>) >= <count>
rule <id> origin(<layer>)
rule <id> forbidden(<layer> not (<seal> or <seal>.holes()))
```

```text
grid 5nm
layer seal = gds(39, 0)
layer met1 = gds(68, 20)
layer chip = seal or seal.holes()
layer met1_outside = met1 not chip
rule Seal.m count(seal) <= 1
rule Seal.m.min count(seal) >= 1
rule x.19 origin(seal)
rule Seal.l forbidden(met1_outside)
```

**Example violation.**

```text
rules:
  Seal.m: ran, examined 1 shapes, found 0 violations
  Seal.m.min: ran, examined 1 shapes, found 0 violations
  x.19: ran, examined 2 shapes, found 1 violations
  Seal.l: ran, examined 1 shapes, found 1 violations
violations: 2
  x.19 error layer seal at (1000 nm, 1000 nm) measured 1414 nm against limit 0 nm on shape 2
  Seal.l error layer met1_outside at (53000 nm, 30000 nm) measured 20000000 nm^2 against limit 0 nm^2 on shape 6
...
```

The seal ring starts at (1 µm, 1 µm), 1414 nm from the origin. A 2 µm × 10 µm met1 shape at
x = 53 µm lies outside the ring, 20 µm² against a limit of 0.

**Status and limits.** Partial. SkyWater SKY130 rule x.27 is not checked: when a seal ring is
present, a part-number block must be placed unless a text says it is not needed. No check states a
condition on one layer's presence, and no public deck marks the part-number cell.

**Sources.** IHP SG13G2 rules Seal.a to Seal.n
([IHP Open PDK](https://github.com/IHP-GmbH/IHP-Open-PDK)); SkyWater SKY130 rules x.19 and x.27
([periphery rules](https://skywater-pdk.readthedocs.io/en/main/rules/periphery.html));
GlobalFoundries GF180MCU guard-ring rules GR.1 to GR.11
([design manual](https://gf180mcu-pdk.readthedocs.io/)).

### DRC-096: Pad and bump rules

**What it catches.** A bond pad, bump or pillar that is the wrong size, too close to another, or
not sitting on its top metal. A pad too large or too small fails bonding or probing, and a pad
opening past its metal exposes the layers below to the bond.

**How GPurify measures it.** Pad rules are written with the general checks: `width` for the
opening's size, `space` between pads, `enclosure` or `inside` for the metal under the opening. A
derived layer picks out the pad, such as the passivation opening over the pad marker. `inside`
reports each inner shape not wholly on the outer layer, with the area left outside.

![An 80 µm dfpad opening whose topmetal2 stops 2 µm short of its right edge; the uncovered strip is flagged](../../diagrams/drc-096.svg)

**In the deck.** Use the general checks on the pad layers.

```text
rule <id> width(<pad>) <= <length>
rule <id> inside(<pad>, <top metal>)
```

```text
grid 5nm
layer passiv = gds(9, 0)
layer dfpad = gds(41, 0)
layer topmetal2 = gds(134, 0)
layer pad = passiv and dfpad
rule Pad.a1 width(pad) <= 150um
rule Pad.i inside(dfpad, topmetal2)
```

**Example violation.**

```text
rules:
  Pad.a1: ran, examined 1 shapes, found 0 violations
  Pad.i: ran, examined 1 shapes, found 1 violations
violations: 1
  Pad.i error layer dfpad at (40000 nm, 40000 nm) measured 160000000 nm^2 against limit 0 nm^2 on shape 0
...
```

The 80 µm pad's top metal ends at x = 78 µm, leaving a 2 µm × 80 µm strip, 160 µm², uncovered.

**Status and limits.** Expressible. Pad, bump and pillar rules are compositions of the general
checks; there is no pad-specific check.

**Sources.** IHP SG13G2 rules Pad, Padb and Padc
([IHP Open PDK](https://github.com/IHP-GmbH/IHP-Open-PDK)); GlobalFoundries GF180MCU pad and
circuit-under-pad rules ([design manual](https://gf180mcu-pdk.readthedocs.io/)); SkyWater SKY130
rules pad.2 and pad.3
([periphery rules](https://skywater-pdk.readthedocs.io/en/main/rules/periphery.html)).

### DRC-097: Frame and cell-name rules

**What it catches.** Drawing in the scribe line or frame where it is not allowed, and layers used
in cells whose names do not permit them, or cells whose names are too long. Frame rules keep the
saw and the foundry's test structures clear. Cell-name rules let a foundry allow a layer only in
its own qualified cells, and keep names within what mask tools accept.

**How GPurify measures it.** Frame and scribe geometry is written with the general checks, such as
`forbidden(sl and diff)`. A cell-name rule selects shapes by the cells they are placed under:
`.in_cells("pattern", ..)` keeps the shapes of a drawn layer drawn in, or placed under, a cell
whose whole name matches one of the patterns, and `.not_in_cells` the others. `*` matches any run
of characters and `?` one. A name longer than `n` characters is `.in_cells` of `n + 1` `?` then
`*`.

![Two met1 cells, inv_x1 passing and inverter_strong_x16 flagged because its 19-character name is over the 16-character limit](../../diagrams/drc-097.svg)

**In the deck.**

```text
rule <id> forbidden(<layer>.in_cells("<pattern>", ..))
rule <id> forbidden(<layer>.not_in_cells("<pattern>", ..))
```

```text
grid 5nm
layer met1 = gds(68, 20)
layer long_named = met1.in_cells("?????????????????*")
rule cell.name forbidden(long_named)
```

**Example violation.**

```text
rules:
  cell.name: ran, examined 1 shapes, found 1 violations
violations: 1
  cell.name error layer long_named at (5000 nm, 0 nm) measured 1000000 nm^2 against limit 0 nm^2 on shape 2
...
```

The pattern of 17 `?` then `*` matches names of 17 characters or more. The cell
`inverter_strong_x16`, 19 characters, places a 1 µm² met1 square at (5000 nm, 0 nm); the cell
`inv_x1` passes.

**Status and limits.** Partial. A cell-name rule sees only cells that hold or place a shape on the
layer it reads, so a long-named cell with nothing on that layer is not reported. Patterns may not
use `[`, `]`, `{`, `}` or `\`, and a deck holds at most 64 `.in_cells` and `.not_in_cells`
selections. The seal ring's corner at the
origin is `origin`, under [DRC-095](#drc-095-seal-ring). SkyWater SKY130 rules x.26 and x.27,
which hold each placement of a parametrised cell, are missing.

**Sources.** SkyWater SKY130 rules x.12 to x.29
([periphery rules](https://skywater-pdk.readthedocs.io/en/main/rules/periphery.html)); IHP SG13G2
LBE rules ([IHP Open PDK](https://github.com/IHP-GmbH/IHP-Open-PDK)); Siemens Calibre's
`DRC MAXIMUM CELL NAME LENGTH`; KLayout `select` on cell names
([DRC reference](https://www.klayout.de/doc/about/drc_ref_layer.html)).

## Placement and assembly

### DRC-127: Cell edge-type spacing between placed cells

**What it catches.** Two placed standard cells whose typed edges are closer than the library
allows. A library types a cell's sides (for example, an edge with a well tap or an implant step)
and asks for a minimum gap between certain pairs of types. Cells placed closer break implant or
well rules at the boundary that neither cell's own DRC can see.

**How GPurify measures it.** With a DEF layout, GPurify reads each macro's `LEF58_EDGETYPE` and the
library's `LEF58_CELLEDGESPACINGTABLE`. Each typed edge moves with its placed cell, so a mirrored
cell's `LEFT` edge lies on its right. Any two parallel typed edges of different cells that share a
stretch of positive length are held to the last table entry naming their two types, in either
order. The gap is the distance between the two edges; it is reported at the middle of the gap and
of the shared stretch.

![Two INV cells 0.2 µm apart, their typed GAP edges facing across a gap the table asks to be 0.4 µm](../../diagrams/drc-127.svg)

**In the deck.** Nothing to write in the deck. The library LEF states the table and the edge types,
and the run reads a DEF layout:

```text
PROPERTYDEFINITIONS
  LIBRARY LEF58_CELLEDGESPACINGTABLE STRING ;
  MACRO LEF58_EDGETYPE STRING ;
END PROPERTYDEFINITIONS
PROPERTY LEF58_CELLEDGESPACINGTABLE "CELLEDGESPACINGTABLE EDGETYPE GAP GAP 0.4 ; " ;
...
MACRO INV
  CLASS CORE ;
  ORIGIN 0 0 ;
  SIZE 1.0 BY 2.0 ;
  SITE core ;
  PROPERTY LEF58_EDGETYPE "EDGETYPE RIGHT GAP ; EDGETYPE LEFT GAP ;" ;
END INV
```

```text
COMPONENTS 2 ;
  - u1 INV + PLACED ( 1000 0 ) N ;
  - u2 INV + PLACED ( 2200 0 ) N ;
END COMPONENTS
```

```sh
gpurify drc top.def --deck top.deck --lef cells.lef
```

**Example violation.**

```text
rules:
...
  def.cell_edge_spacing: ran, examined 4 shapes, found 1 violations
violations: 1
  def.cell_edge_spacing error at (2100 nm, 1000 nm) measured 200 nm against limit 400 nm
...
```

`u1`'s right edge at x = 2 µm and `u2`'s left edge at x = 2.2 µm are both `GAP`, 200 nm apart
against the table's 400 nm. For this rule the examined count is the number of typed edges.

**Options.** `LEF58_EDGETYPE` and `LEF58_CELLEDGESPACINGTABLE` keywords GPurify reads:

| Keyword | Meaning |
|---|---|
| `EDGETYPE side type` | Types a whole side: `LEFT`, `RIGHT`, `TOP` or `BOTTOM`. |
| `CELLROW n` | Types the `n`th row's stretch of a left or right side of a multi-row cell, rows the height of the first DEF row's site. |
| `HALFROW n` | The same in half rows. |
| `RANGE b e` | Types the stretch from `b` to `e` along a top or bottom side. |
| `EXCEPTABUTTED` | Exempts two edges that touch (a gap of 0). |

**Status and limits.** Partial. A table entry with `EXCEPTNONFILLERINBETWEEN`, `OPTIONAL`, `SOFT` or
`EXACT` is not checked, since no public text defines them, and there is no `DEFAULT` type for
untyped sides. Filler cells (`CORE SPACER`) have no typed edges. The check runs only on a DEF layout.

**Sources.** ISPD 2014 detailed-placement contest, benchmark suite A; ICCAD 2017 contest problem C;
LEF/DEF 5.8 Language Reference, `LEF58_EDGETYPE` and `LEF58_CELLEDGESPACINGTABLE`; OpenROAD detailed
placement.

### DRC-129: Inter-die alignment and overlap

**What it catches.** In a die stack or on an interposer, two bonded bumps whose centres are too far
apart, and a bump too close to a bump on the facing die that it does not bond. A misaligned bond
has less contact area and more resistance. A bump near a foreign bump can short to it when the
solder spreads.

**How GPurify measures it.** `gpurify system` places each die as the system file says and finds
the bumps that bond: two bumps of facing layers that overlap with some area. For each bonded pair
it measures the distance between the two bumps' centres against the bond's `max_offset_nm`,
reported at the middle of the two centres. For each bump and each bump of the facing die it does
not bond, it measures the gap between them, edge to edge, against `min_space_nm`, reported at the
middle of the gap. A die is placed by quarter turns only, so no rotation can be off.

![Two bonded 20 µm bumps offset 4 µm against a 2 µm limit, and a chip bump 26 µm from an interposer bump it does not bond, against a 30 µm space](../../diagrams/drc-129.svg)

**In the deck.** Nothing to write in the deck. State the limits on the bond in the system file:

```json
{
  "dies": [
    { "name": "Xint", "layout": "interposer.gds", "deck": "die.deck" },
    { "name": "Xchip", "layout": "chip.gds", "deck": "die.deck" }
  ],
  "bonds": [
    { "a": { "die": "Xint", "layer": "bump" },
      "b": { "die": "Xchip", "layer": "bump" },
      "max_offset_nm": 2000, "min_space_nm": 30000 }
  ]
}
```

```sh
gpurify system stack.json --reference system.spice
```

**Example violation.**

```text
rules:
  system.unbonded_bump: ran, examined 4 shapes, found 0 violations
  system.bump_offset: ran, examined 2 shapes, found 2 violations
  system.bump_space: ran, examined 4 shapes, found 1 violations
...
violations: 3
  system.bump_offset error at (12000 nm, 10000 nm) measured 4000 nm against limit 2000 nm on shape 0 and shape 0
  system.bump_offset error at (62000 nm, 10000 nm) measured 4000 nm against limit 2000 nm on shape 1 and shape 1
  system.bump_space error at (37000 nm, 10000 nm) measured 26000 nm against limit 30000 nm on shape 1 and shape 0
...
```

Each chip bump lands 4 µm right of its interposer bump, against a 2 µm offset limit. The chip's
first bump, ending at x = 24 µm, is 26 µm from the interposer's second bump at x = 50 µm, which it
does not bond, against a 30 µm space.

**Options.** The bond's fields in the system file:

| Field | Value | Meaning |
|---|---|---|
| `max_offset_nm` | whole nm | The largest distance between the centres of two bonded bumps. Left out, offsets are not checked. |
| `min_space_nm` | whole nm | The least gap from a bump to a facing bump it does not bond. Left out, spacing is not checked. |

**Status and limits.** Implemented. No public deck states these limits; the packager or foundry
supplies them. Each bump must be a rectangle on a conductor of its die's deck. A bump that bonds
nothing is `system.unbonded_bump`, part of system LVS.

**Sources.** Siemens Calibre 3DSTACK.
