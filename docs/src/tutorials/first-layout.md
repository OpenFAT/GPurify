# Check your first layout

In this tutorial you draw a small SkyWater SKY130 layout, check it against the SKY130 deck that
ships with GPurify, read the report, fix the defect it finds and check it again until it passes.
It takes about 15 minutes. The layout is a differential pair: two n-channel transistors that share
a source.

## What you need

- GPurify on your `PATH`. [Install GPurify](../how-to/install.md) covers it.
- Python 3 with the [gdstk](https://heitzmann.github.io/gdstk/) package, which writes GDS files.
  With Nix, `nix-shell -p "python3.withPackages(ps: [ps.gdstk])"` gives you a shell that has
  both. Without Nix, run `pip install gdstk`.
- An empty directory to work in.

## Draw the layout

Save this script as `diffpair.py`. It draws two transistors, each 2 µm wide and 0.5 µm long, on
one diffusion strip. Every terminal climbs through a contact (`licon`), local interconnect (`li`)
and a second contact (`mcon`) to a metal 1 (`met1`) pad that carries a text label. The labels name
the nets: `inp`, `inn`, `outp`, `outn`, `tail` and `vss`.

```python
import gdstk

# SKY130 GDS layer and datatype pairs.
DIFF, TAP, POLY, LICON = (65, 20), (65, 44), (66, 20), (66, 44)
LI, MCON, MET1, NSDM, PSDM = (67, 20), (67, 44), (68, 20), (93, 44), (94, 20)

lib = gdstk.Library(unit=1e-6, precision=1e-9)
top = lib.new_cell("diffpair")


def box(layer, x0, y0, x1, y1):
    top.add(gdstk.rectangle((x0, y0), (x1, y1), layer=layer[0], datatype=layer[1]))


def contact(x, y, name):
    """A licon, li pad, mcon and met1 pad at (x, y), labelled on met1."""
    box(LICON, x - 0.085, y - 0.085, x + 0.085, y + 0.085)
    box(LI, x - 0.2, y - 0.2, x + 0.2, y + 0.2)
    box(MCON, x - 0.085, y - 0.085, x + 0.085, y + 0.085)
    box(MET1, x - 0.25, y - 0.25, x + 0.25, y + 0.25)
    top.add(gdstk.Label(name, (x, y), layer=68, texttype=5))


# Two n-channel transistors on one diffusion strip, sharing the source "tail".
box(DIFF, 0.0, 0.0, 4.0, 2.0)
box(NSDM, -0.2, -0.2, 4.2, 2.2)
for x0, name in ((1.0, "inp"), (2.5, "inn")):
    box(POLY, x0, -0.15, x0 + 0.5, 2.6)        # the gate
    box(POLY, x0 - 0.1, 2.6, x0 + 0.6, 3.3)    # its contact pad
    contact(x0 + 0.25, 2.95, name)
for x, name in ((0.5, "outp"), (2.0, "tail"), (3.5, "outn")):
    contact(x, 1.0, name)
# The substrate tap, the transistors' bulk.
box(TAP, 5.0, 0.5, 5.6, 1.5)
box(PSDM, 4.8, 0.3, 5.8, 1.7)
contact(5.3, 1.0, "vss")

lib.write_gds("diffpair.gds")
```

Run it:

```sh
python3 diffpair.py
```

You now have `diffpair.gds`, with one cell, `diffpair`, on a 1 nm grid.

## Check it

Run the design rules of the shipped SKY130 deck on the layout, and keep the report in a file:

```sh
gpurify drc diffpair.gds --deck sky130 > report.txt
echo $?
```

```text
1
```

`--deck sky130` names a deck that ships inside GPurify, so you need no deck file. The exit code
is 1: the layout does not pass.

## Read the report

Open `report.txt`. It has three parts: the rules, the violations and the summary.

```text
rules:
  dnwell.2: ran, examined 0 shapes, found 0 violations
  dnwell.3: ran, examined 0 shapes, found 0 violations
...
  licon.15: ran, examined 2 shapes, found 2 violations
...
  licon.18: ran, examined 2 shapes, found 2 violations
...
violations: 4
  licon.15 error layer poly_licon at (1250 nm, 2950 nm) measured 0 nm against limit 100 nm on shape 84
  licon.15 error layer poly_licon at (2750 nm, 2950 nm) measured 0 nm against limit 100 nm on shape 85
  licon.18 error layer poly_licon at (1250 nm, 2950 nm) measured 28900 nm^2 against limit 0 nm^2 on shape 84
  licon.18 error layer poly_licon at (2750 nm, 2950 nm) measured 28900 nm^2 against limit 0 nm^2 on shape 85
summary:
  drc: ran
  erc: not selected
  lvs: not selected
  pex: not selected
  0 rules skipped
  263 rules clean
  4 violations: 4 errors, 0 warnings
```

**The rules.** Every rule in the deck has one line. `ran` means the rule looked at the layout.
`examined` counts what it looked at, and `found` counts its violations. The rule ids are the
foundry's, so `licon.15` is rule licon.15 in the SkyWater SKY130 periphery rules. A rule that
examined 0 shapes found nothing to look at: this layout draws no deep n-well, so `dnwell.2` has
nothing to check.

**The violations.** Each line gives the rule, its severity, the deck layer it measured, a point on
the offending shape, the measured value and the limit. Both failing rules point at the two gate
contacts, the contacts on the poly pads at (1250 nm, 2950 nm) and (2750 nm, 2950 nm). The layer
`poly_licon` is the deck's name for a contact that lands on poly.

- `licon.15` asks for the nitride poly cut layer, `npc`, to enclose every poly contact by
  100 nm. The layout draws no `npc` at all, so the enclosure measured is 0 nm.
- `licon.18` asks for every poly contact to sit inside `npc`. The measured 28900 nm² is the
  contact area outside `npc`: the whole 170 nm by 170 nm contact, against a limit of 0 nm².

One missing layer breaks two rules at two contacts, which gives four violations.

**The summary.** One line per check says whether it ran. Then come the counts: rules skipped,
rules clean, and violations split into errors and warnings. The layout passes only when every
selected check ran, no rule was skipped and no error was found.

## Fix the layout

Draw `npc` over both gate contacts. In `diffpair.py`, add `npc`'s layer pair, GDS layer 95,
datatype 20, to the layer list:

```python
LI, MCON, MET1, NSDM, PSDM, NPC = (67, 20), (67, 44), (68, 20), (93, 44), (94, 20), (95, 20)
```

Then add one box before the last line. It reaches from x = 0.8 µm to 3.2 µm and from y = 2.5 µm
to 3.4 µm. That covers both contacts with more than 100 nm to spare, and it stays 500 nm clear of
the transistor gates below:

```python
# Nitride poly cut over both gate contacts.
box(NPC, 0.8, 2.5, 3.2, 3.4)

lib.write_gds("diffpair.gds")
```

## Check it again

```sh
python3 diffpair.py
gpurify drc diffpair.gds --deck sky130 > report.txt
echo $?
```

```text
0
```

The end of the report now reads:

```text
violations: 0
summary:
  drc: ran
  erc: not selected
  lvs: not selected
  pex: not selected
  0 rules skipped
  265 rules clean
  0 violations: 0 errors, 0 warnings
```

All 265 design rules ran, none was skipped and none found an error. The exit code 0 says the same.

## What you did

You checked a layout against a shipped deck, traced each violation to its rule and its place, fixed
the layout and confirmed the fix. [Run your first LVS](first-lvs.md) uses the same layout to
compare it with its schematic.

To read further:

- [Report format](../reference/report.md) describes every field of the report.
- [How a run passes](../explanation/outcomes.md) explains `ran`, `skipped` and `refused`.
- [Shipped decks](../reference/shipped-decks.md) lists what the SKY130 deck covers.
