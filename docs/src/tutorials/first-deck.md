# Write your first deck

In this tutorial you write a deck for a small process with two metals and one via layer, run it on
a layout, read the violations it finds, and fix them. Then you teach the deck how the layers
connect, and watch it find a short. It takes about 15 minutes.

You need `gpurify` on your path, and Python 3 with the `gdstk` package to draw the layout.

## 1. Draw the layout

The layout holds two met1 wires, A and B, each with a text label. A via1 cut joins wire A to a met2
strap that crosses both wires. Save this script as `make_layout.py`:

```python
import gdstk

lib = gdstk.Library(unit=1e-6, precision=1e-9)
top = lib.new_cell("TOP")

def box(layer, x0, y0, x1, y1, datatype=0):
    # Corners in nm; gdstk works in um.
    top.add(gdstk.rectangle((x0 / 1000, y0 / 1000), (x1 / 1000, y1 / 1000),
                            layer=layer, datatype=datatype))

box(10, 0, 0, 2000, 200)          # met1 wire A, 200 nm wide
box(10, 0, 500, 2000, 600)        # met1 wire B, 100 nm wide
box(11, 1800, 25, 1950, 175)      # via1 cut on wire A, 150 nm square
box(12, 1750, -200, 2000, 1000)   # met2 strap over both wires
top.add(gdstk.Label("A", (0.1, 0.1), layer=10, texttype=5))
top.add(gdstk.Label("B", (0.1, 0.55), layer=10, texttype=5))
lib.write_gds("two_metal.gds")
```

Run it to write `two_metal.gds`:

```sh
python3 make_layout.py
```

The layout uses four GDS layer and datatype pairs: met1 on 10/0, via1 on 11/0, met2 on 12/0, and
the labels on 10/5.

## 2. Declare the layers

A deck starts with the manufacturing grid, then names each GDS layer it reads. Save this as
`two_metal.deck`:

```text
# A two-metal process
grid 5nm

layer met1       = gds(10, 0)
layer via1       = gds(11, 0)
layer met2       = gds(12, 0)
layer met1_label = gds(10, 5)
```

Every length you write from now on must be a whole multiple of 5 nm. The deck declares the label
layer too: GPurify refuses a layout that has shapes or text on a layer the deck does not declare.

Check that the deck loads, and see what GPurify made of it:

```sh
gpurify deck two_metal.deck --format json
```

```text
{"format":"gpurify-deck/1","deck":"two_metal.deck","grid_nm":5,
"layers":[
{"id":0,"name":"met1","gds":[10,0]},
{"id":1,"name":"met1_label","gds":[10,5]},
{"id":2,"name":"met2","gds":[12,0]},
{"id":3,"name":"via1","gds":[11,0]}
],
"rules":[],
...
```

The four layers are there, each with the GDS pair it reads. There are no rules yet.

## 3. Write the rules

Add the process's rules to the end of the deck. Each `rule` line gives an id, which the report
prints, then a check, the layers it reads, and the limit:

```text
rule M1.W   width(met1) >= 140nm
rule M1.S   space(met1) >= 140nm
rule M1.A   area(met1) >= 0.083um2
rule V1.W   size(via1) == 150nm x 150nm
rule V1.EN  enclosure(via1, met1) >= 30nm
rule M2.W   width(met2) >= 200nm
```

In order, these say: met1 is at least 140 nm wide, met1 shapes are at least 140 nm apart, a met1
shape covers at least 0.083 µm², a via1 cut is exactly 150 nm square, met1 extends at least 30 nm
past every side of a via1 cut, and met2 is at least 200 nm wide. Every number carries its unit, and
an area takes an area unit such as `um2`.

## 4. Run DRC

```sh
gpurify drc two_metal.gds --deck two_metal.deck
```

```text
rules:
  M1.W: ran, examined 2 shapes, found 1 violations
  M1.S: ran, examined 0 shapes, found 0 violations
  M1.A: ran, examined 2 shapes, found 0 violations
  V1.W: ran, examined 1 shapes, found 0 violations
  V1.EN: ran, examined 1 shapes, found 1 violations
  M2.W: ran, examined 1 shapes, found 0 violations
violations: 2
  M1.W error layer met1 at (1000 nm, 550 nm) measured 100 nm against limit 140 nm on shape 1
  V1.EN error layer via1 at (1875 nm, 12 nm) measured 25 nm against limit 30 nm on shape 3 and shape 0
summary:
  drc: ran
  erc: not selected
  lvs: not selected
  pex: not selected
  0 rules skipped
  4 rules clean
  2 violations: 2 errors, 0 warnings
```

The command exits with status 1, because the layout has errors.

Read the report from the top:

- **`rules:`** lists every rule with its outcome. All six `ran`: each looked at the layout.
  `examined` counts what the check measured. For `space` that is the pairs of shapes near enough
  to compare, and the two wires are 300 nm apart, so `M1.S` examined none.
- **`violations:`** lists each place a limit is broken, with the rule id, the layer, a point, the
  measured value and the limit.
- **`summary:`** says which parts of the run ran and counts the result.

![The tutorial layout: met1 wire B is 100 nm wide against a 140 nm limit, and met1 wire A extends only 25 nm below the via1 cut against a 30 nm limit](../diagrams/first-deck-1.svg)

There are two violations:

- `M1.W` at (1000 nm, 550 nm), the middle of wire B: the wire is 100 nm wide, and the limit is
  140 nm.
- `V1.EN` at (1875 nm, 12 nm), just below the via: wire A extends 25 nm below the cut, and the limit
  is 30 nm. The via sits 25 nm from both long sides of the 200 nm wire.

## 5. Fix the layout

Widen wire B to 140 nm, and make wire A 210 nm wide with the via centred on it. Change three lines
of `make_layout.py`:

```python
box(10, 0, 0, 2000, 210)          # met1 wire A, 210 nm wide
box(10, 0, 500, 2000, 640)        # met1 wire B, 140 nm wide
box(11, 1800, 30, 1950, 180)      # via1 cut on wire A, 150 nm square
```

Run the script and DRC again:

```sh
python3 make_layout.py
gpurify drc two_metal.gds --deck two_metal.deck
```

```text
rules:
  M1.W: ran, examined 2 shapes, found 0 violations
  M1.S: ran, examined 0 shapes, found 0 violations
  M1.A: ran, examined 2 shapes, found 0 violations
  V1.W: ran, examined 1 shapes, found 0 violations
  V1.EN: ran, examined 1 shapes, found 0 violations
  M2.W: ran, examined 1 shapes, found 0 violations
violations: 0
summary:
  drc: ran
  erc: not selected
  lvs: not selected
  pex: not selected
  0 rules skipped
  6 rules clean
  0 violations: 0 errors, 0 warnings
```

Every rule ran and found nothing, and the command exits with status 0.

## 6. Describe the connectivity

So far the deck knows shapes but not wires. To build nets, it needs to know which layers carry
current, how a via joins them, and where the net names come from. Add these lines to the deck:

```text
connect conductors [met1, met2]
connect touch_within_layer
connect via via1 [met1, met2]
connect label met1_label names met1
```

The first line says met1 and met2 carry nets. The second joins shapes that touch on one layer. The
third joins met1 to met2 wherever a via1 cut lands on both. The last names a met1 net after the
text on `met1_label` that sits on it, so the two wires are nets `A` and `B`.

![The layout's nets: via1 joins met1 wire A to the met2 strap, so they are net A; the strap crosses wire B with no via, so wire B is net B on its own](../diagrams/deck-connectivity-1.svg)

Run `gpurify deck two_metal.deck --format json` again. Its `connectivity` line now reads:

```text
"connectivity":{"conductors":[0,2],"vias":[{"cut":3,"connects":[0,2]}],"touch_within_layer":true,"global":[],"labels":[{"layer":1,"names":0}]},
```

The numbers are the layer ids from step 2: met1 is 0 and met2 is 2, and the via cut is layer 3.

## 7. Find a short

To see the nets at work, short them. Add a second via1 cut where the strap crosses wire B, after
the other `box` lines of `make_layout.py`:

```python
box(11, 1800, 495, 1950, 645)     # a second via1 cut, on wire B
```

Run the script, then ERC, which reads the nets:

```sh
python3 make_layout.py
gpurify erc two_metal.gds --deck two_metal.deck
```

```text
rules:
  lvs.net_seed_conflict: ran, examined 2 shapes, found 1 violations
  lvs.short_path: ran, examined 1 shapes, found 2 violations
violations: 3
  lvs.net_seed_conflict error layer met1 at (0 nm, 0 nm) measured 2 against limit 1 on shape 0 and shape 1
  lvs.short_path error layer met1 at (0 nm, 0 nm) measured 1 against limit 2 on shape 0 and shape 2
  lvs.short_path error layer met2 at (1750 nm, -200 nm) measured 2 against limit 2 on shape 2 and shape 1
...
```

`lvs.net_seed_conflict` says one net carries two names, `A` and `B`, where one is allowed. The two
`lvs.short_path` lines trace the short one step at a time: from wire A (shape 0) to the met2 strap
(shape 2), then from the strap to wire B (shape 1). Remove the line you added to get the clean
layout back.

## What you have now

`two_metal.deck` is a complete deck:

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

To go further:

- [Deck language](../reference/deck/README.md) describes the file, its units and every statement.
- [Layers](../reference/deck/layers.md) derives new layers with `and`, `not` and the other
  operations.
- [Devices](../reference/deck/devices.md) teaches the deck to recognise transistors for LVS.
- [DRC checks](../reference/drc/README.md) lists every check a `rule` can name.
