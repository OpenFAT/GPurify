# Deck language

A deck is one plain-text file that describes your process to GPurify: its layers, how they
connect, what a device looks like, the metal stack for parasitics, and the rules a layout must
meet. This page covers the file's structure and its values; the pages under it cover each
statement.

GPurify reads a deck strictly. Every parameter of every rule is written out, and nothing has a
default. A misspelt name, an undeclared layer, a number without a unit, or a unit of the wrong
kind is an error at its line and column, so a deck that loads means what it says.

## A complete deck

This deck describes a process with two metals and one via layer. It loads, and the tutorial
[Write your first deck](../../tutorials/first-deck.md) runs it on a layout.

```text
# A two-metal process
grid 5nm

layer met1       = gds(10, 0)
layer via1       = gds(11, 0)
layer met2       = gds(12, 0)
layer met1_label = gds(10, 5)

rule M1.W   width(met1) >= 140nm
rule M1.S   space(met1) >= 140nm
rule M1.A   area(met1) >= 0.083um2
rule V1.W   size(via1) == 150nm x 150nm
rule V1.EN  enclosure(via1, met1) >= 30nm
rule M2.W   width(met2) >= 200nm

connect conductors [met1, met2]
connect touch_within_layer
connect via via1 [met1, met2]
connect label met1_label names met1
```

Pass a deck file to any command with `--deck`:

```sh
gpurify drc layout.gds --deck two_metal.deck
```

`--deck` also takes the name of a deck GPurify ships: `sky130`, `gf180mcu`, `ihp_sg13g2` or
`asap7`. A shipped name wins over a file of the same name in the working directory.

## File structure

- **One statement per line.** The first word names the statement (`layer`, `rule`, `connect`).
- **Comments.** `#` starts a comment that runs to the end of the line, anywhere in the file.
- **Continuation.** A statement continues onto the next lines while a `(` or `[` is open. A long
  rule or table wraps this way; a line that ends outside brackets ends the statement.
- **Blank lines** separate nothing and are ignored.
- **Order.** A name is declared before anything uses it: a layer before the rule that reads it,
  and `grid` before the first length. The order of everything else is free, except that `stage`
  lines group the rules written after them (see [Rules and stages](rules.md#stages)).
- **One file.** A deck has no include statement. To repeat statements, use `let` and `for` in the
  same file (see [Names, loops and switches](reuse.md)).

```text
grid 5nm   # the manufacturing grid
layer met1 = gds(10, 0)

rule M1.S.table space_table(met1;
    prl:   [0um, 1um],      # run lengths
    width: [0um, 0.3um],    # widths
    space: [[140nm, 140nm],
            [140nm, 200nm]])
```

## Names

A name, such as a layer, a `let` binding or a stage, starts with a letter or `_` and holds
letters, digits and `_`. Names are case-sensitive. Layers and `let` bindings share one set of
names, so one name means one thing.

A rule id, the word after `rule` and `waive`, holds letters, digits, `_` and `.`, and may start
with a digit: `m1.1`, `licon.5a`, `M1.bR` and `1.2a` are all ids. Use the foundry's rule numbers,
so the report reads like the design manual. A hyphen is not part of an id.

A device model, a net name and a pattern are written in double quotes: `"sky130_fd_pr__nfet_01v8"`.
Inside quotes, `\"` is a quote and `\\` a backslash; no other escape exists.

## Values

| Form | Example | Used for |
|---|---|---|
| Number and unit | `140nm`, `0.083um2`, `1.8V` | Every physical quantity |
| Bare number | `3.9`, `2`, `0.3` | Counts, ratios, exponents, fractions |
| Word | `met1`, `none`, `true`, `opposite` | Layers, switches, modifiers |
| Quoted string | `"nfet"` | Models, net names, patterns |
| List | `[met1, met2]`, `[0um, 1um]` | Layer lists, tables |
| Tuple | `(met1, 140nm)` | Loop items, points, profile rows |
| Named group | `(space: 100nm, within: 50nm)` | A rule parameter with parts of its own |
| Box | `150nm x 150nm` | A rectangle's two sides |

A minus sign before a number makes it negative: `-50nm`. A number may carry an exponent, as in
`1.4e2nm` or `3.179e-3/K`. Write a box with spaces round the `x`.

`none` stands for a value a parameter may leave absent. Leaving the parameter out is still an
error: you write `none` to say you mean it.

## Units

Every number that is a physical quantity carries its unit, with no space between them. The units
of one kind convert into each other exactly, so `140nm`, `0.14um` and `0.00014mm` are the same
length. A unit of the wrong kind is an error: a length parameter refuses `0.083um2`.

| Kind | Units |
|---|---|
| Length | `nm`, `um`, `mm` |
| Area | `nm2`, `um2`, `mm2` |
| Voltage | `mV`, `V` |
| Current | `nA`, `uA`, `mA`, `A` |
| Current per width | `uA/um`, `mA/um`, `A/m` |
| Frequency | `Hz`, `kHz`, `MHz`, `GHz` |
| Resistance | `mohm`, `ohm`, `kohm`, `Mohm` |
| Capacitance | `aF`, `fF`, `pF` |
| Capacitance per area | `aF/um2`, `fF/um2` |
| Capacitance per length | `aF/um`, `fF/um` |
| Inductance | `pH`, `nH`, `uH` |
| Temperature | `K`, or `C` for degrees Celsius |
| Temperature coefficient | `/K` (first order), `/K2` (second order) |
| Energy | `eV` |
| Thermal conductivity | `W/mK` |
| Time | `h` |
| Electric field | `V/um`, `V/nm`, `MV/cm` |
| Fraction | `%`, or a bare number from 0 to 1 |
| Angle | `deg`, a whole number of degrees |
| Threshold-voltage mismatch | `mV·um` |
| Ratio mismatch | `%·um` |
| Threshold-voltage gradient | `uV/um` |

The last three belong to the `matching` statement (see [Device matching](matching.md)). The
middle dot may be written as a full stop: `mV.um`, `%.um`.

A count (cuts, colours, devices) is a bare whole number. A ratio, an exponent and a dielectric
constant are bare numbers.

## The grid

`grid 5nm` states the manufacturing grid. Every length in the deck must be a whole multiple of it,
and every area a whole multiple of the grid squared. GPurify never rounds: `142nm` on a 5 nm grid is
an error, not 140 nm.

A length must also be a whole number of the layout's database units. A deck on a 5 nm grid runs on
a layout with a 1 nm or 5 nm database unit. On a layout with a 10 nm database unit, a deck that
states `145nm` is refused at that length. Each shipped deck states its foundry's grid: 5 nm, or
1 nm for `asap7`.

The grid applies to the deck's numbers. To check that drawn vertices lie on the grid, write an
`off_grid` rule (see the [DRC checks](../drc/README.md)).

## Errors

GPurify reads the whole deck before it stops, and reports up to 50 errors together, each with its
line and column. An error inside a rule names the rule id first.

```text
error: deck bad.deck: Invalid
  line 9:28: M1.W: 142nm is not a multiple of the grid
  line 10:28: M1.S: 142nm is not a multiple of the grid
  line 11:25: M1.A: area needs an area, got 0.083 (no unit)
  line 14:19: M2.W: unknown layer `metal2`
```

A deck whose lines each read correctly can still contradict itself: a waiver for a rule the deck
does not have, or a label layer that names a layer that is not a conductor. GPurify reports the
first such contradiction without a line number, naming the statement:

```text
error: deck bad2.deck: Malformed
  waive M1.X: no rule of the deck has that id
```

Either way the run stops before it reads the layout, and the exit code is 1.

## Statements

| Statement | What it states | Page |
|---|---|---|
| `grid` | The manufacturing grid | [The grid](#the-grid) |
| `let`, `for`, `if` | Names for values, repeated statements, deck switches | [Names, loops and switches](reuse.md) |
| `layer` | A drawn layer (`gds(L, D)`) or a derived layer | [Layers](layers.md) |
| `ignore` | A GDS layer and datatype to drop | [Layers](layers.md#ignored-gds-layers) |
| `boundary` | The layer that outlines the die | [Layers](layers.md#the-die-boundary) |
| `rule` | A check, its layers and its limit | [Rules and stages](rules.md) |
| `stage` | A group of rules checked before the next | [Rules and stages](rules.md#stages) |
| `waive` | A waiver layer for a rule | [Waivers](waivers.md) |
| `connect` | Conductors, vias, global nets and labels | [Connectivity](connectivity.md) |
| `device` | How a device is recognised and measured | [Devices](devices.md) |
| `matching` | A device model's mismatch coefficients | [Device matching](matching.md) |
| `lvs` | How LVS compares one model, or the whole netlist | [LVS controls](lvs-controls.md) |
| `netlist_scale` | The unit of bare sizes in the reference netlist | [LVS controls](lvs-controls.md#netlist-scale) |
| `pex` | One layer of the metal stack | [Parasitic extraction](extraction.md) |
| `temperature` | The sign-off and nominal temperatures | [Parasitic extraction](extraction.md#temperature) |
| `corner` | A layer's stack values at a process corner | [Parasitic extraction](extraction.md#process-corners) |
| `extraction` | Which parasitics to write, and the coupling reach | [Parasitic extraction](extraction.md#extraction-type) |
| `pex_fill` | How extraction treats metal fill | [Parasitic extraction](extraction.md#metal-fill) |
| `pex_device` | A transistor's capacitance inside the device | [Parasitic extraction](extraction.md#device-region-capacitance) |
| `pex_tsv` | A through-silicon via layer | [Parasitic extraction](extraction.md#through-silicon-vias) |
| `pex_substrate` | The substrate resistance network | [Parasitic extraction](extraction.md#substrate-network) |
| `fill` | Metal fill that `gpurify fill` draws | [Fill and enhance](fill-and-enhance.md) |
| `widen` | Power straps that `gpurify enhance` widens | [Fill and enhance](fill-and-enhance.md#widened-straps) |
| `report` | Extra measurements in the text report | [Report lines](report-lines.md) |

The checks a `rule` can name are listed on the check pages: [DRC checks](../drc/README.md),
[ERC checks](../erc/README.md), [LVS checks](../lvs/README.md) and
[PEX checks](../pex/README.md).
