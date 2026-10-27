# Device checks

These checks hold the layers of a device to its family's rules, count devices and their total area
across the chip, and exempt regions, cells or rule groups the foundry excludes. They are written
with the general deck operations: a device's marker becomes a derived layer, and an ordinary check
reads it.

## Device geometry

### DRC-090: Device-family rules

**What it catches.** A resistor, capacitor, varactor, bipolar transistor, inductor, fuse or other
device drawn outside its family's rules: a precision resistor of an unmodelled width, or a resistor
terminal with too many contacts. The models and the foundry's qualification cover only the drawn
forms the manual lists.

**How GPurify measures it.** You build each device's region from its marker and drawn layers, then
apply an ordinary check to it. `contains(outer, inner)` counts the inner shapes lying entirely
inside each outer shape, touching inner shapes as one. Other family rules use `width` with an
`allowed` list, edge widths for a channel, `enclosure`, `space` and `forbidden`.

![A poly resistor terminal under rpm holding two licon cuts where one is allowed](../../diagrams/drc-090.svg)

**In the deck.**

```text
layer <device region> = <expression of drawn layers>
rule <id> contains(<outer>, <inner>) <= <count>
rule <id> contains(<outer>, <inner>) >= <count>
rule <id> contains(<outer>, <inner>) == <count>
```

```text
grid 5nm
layer poly  = gds(66, 20)
layer rpm   = gds(86, 20)
layer licon = gds(66, 44)
layer prec_term = (poly and rpm).interacting(licon)
rule rpm.1g contains(prec_term, licon) <= 1
```

**Example violation.**

```text
rules:
  rpm.1g: ran, examined 1 shapes, found 1 violations
violations: 1
  rpm.1g error layer prec_term at (175 nm, 3000 nm) measured 2 against limit 1 on shape 5
...
```

A resistor terminal holds two licon cuts where one is allowed. The point is the terminal's centre.

**Status and limits.** Implemented. The family rules are compositions: exact resistor widths are
`width(L; allowed: [...])` (sky130 rpm.1b to rpm.1f), channel length and width are edge widths
(see [DRC-011](dimension.md#drc-011-device-channel-width-and-length)), the varactor channel width
is `width(var_channel.edges() and tap.edges())` (varac.2), and the varactor-to-tap space is
`space(var_tap, difftap.not_interacting(var_tap))` (varac.6). The sky130 manual does not define
the resistor terminal region, so the shipped sky130 deck leaves rpm.1g to rpm.1k out.

**Sources.** IHP SG13G2 section 6; GlobalFoundries GF180MCU PRES, MIM, LDMOS, EF and SK rules;
[SkyWater SKY130](https://skywater-pdk.readthedocs.io/en/main/rules/periphery.html) rpm, capm,
varac, indm, mf, photo and denmos rules.

### DRC-091: Per-chip count and total area

**What it catches.** More devices of a kind, or more total area of a layer, than the chip may hold:
the number of bipolar emitters, or the total MIM capacitor area. The foundry qualifies a chip for
so many of a sensitive device, and a large total area of capacitor oxide raises the chance of a
defect.

**How GPurify measures it.** `count(L)` counts the shapes on the layer in the whole layout, touching
shapes as one. `total_area(L)` sums the layer's area, overlaps once and holes not at all. Each rule
reports once, at the centre of the drawn layers' extent.

![Three emitter shapes on a chip against a limit of two](../../diagrams/drc-091.svg)

**In the deck.**

```text
rule <id> count(<layer>) <= <count>
rule <id> count(<layer>) >= <count>
rule <id> total_area(<layer>) <= <area>
```

```text
grid 5nm
layer emitter = gds(124, 0)
rule npn13G2.bR count(emitter) <= 2
```

**Example violation.**

```text
rules:
  npn13G2.bR: ran, examined 3 shapes, found 1 violations
violations: 1
  npn13G2.bR error layer emitter at (1035 nm, 450 nm) measured 3 against limit 2 on shape 0
...
```

The layout holds three emitters against a limit of two. The point is the centre of the layout.

**Status and limits.** Implemented. "One seal ring per chip" is `count(seal) <= 1` with
`count(seal) >= 1`. A layout with nothing drawn skips both rules.

**Sources.** IHP SG13G2 rules npn13G2.bR and MIM.gR.

## Exemptions

### DRC-092: Exemptions by region, cell and switch

**What it catches.** A rule applied where the foundry exempts it: inside a standard-cell area, inside
a named cell, or in a rule group the design does not use. Without the exemption, the run floods
with violations the foundry does not count.

**How GPurify measures it.** You remove the exempt part before the check. `L not areaid` drops a
region. `L.in_cells("pattern", ...)` keeps the shapes placed under a cell whose name matches a `*`
and `?` glob, and `L.not_in_cells(...)` keeps the rest. `let name = true | false` with
`if name { ... }` and `if not name { ... }` switches rule groups; a block switched off is not read.

![Two met1 wires 0.10 µm wide, one inside the areaid_sc region and exempt, the other reported](../../diagrams/drc-092.svg)

**In the deck.**

```text
layer <kept> = <layer> not <region>
layer <kept> = <layer>.in_cells("<pattern>", ...)
layer <kept> = <layer>.not_in_cells("<pattern>", ...)
let <name> = true | false
if <name> { ... }
if not <name> { ... }
```

```text
grid 5nm
layer met1 = gds(68, 20)
layer areaid_sc = gds(81, 4)
layer met1_core = met1 not areaid_sc
let check_cells = false
if check_cells {
    rule m1.1 width(met1) >= 140nm
}
if not check_cells {
    rule m1.1 width(met1_core) >= 140nm
}
```

**Example violation.**

```text
rules:
  m1.1: ran, examined 1 shapes, found 1 violations
violations: 1
  m1.1 error layer met1_core at (50 nm, 1000 nm) measured 100 nm against limit 140 nm on shape 3
...
```

Two wires are 100 nm wide. The one under `areaid_sc` is exempt; the other is reported. With
`check_cells` set to `true`, the rule checks both.

**Status and limits.** Implemented. A cell pattern matches the cell a shape is drawn in or any cell
above it, the top included, as KLayout's `select("-", "+pattern")`. At most 64 cell patterns per
deck. A switch is flipped where it is bound, in the deck.

**Sources.** SkyWater SKY130 flags and areaid layers, rules m1.4a and licon.11c; IHP SG13G2 section
6.12 (inductor) and section 8 (digital boundary).
