# Antenna checks

While a metal or cut layer is etched, the plasma charges every shape of it, and that charge drains
through whatever gate oxide the shape is joined to at that moment. These checks hold the ratio of
charge-collecting area to gate area under the foundry's limit, with credit for a protection diode
where the process grants it.

Two rule kinds do the work. `antenna` measures the plain ratio. `antenna_electrical` measures the
same ratio less the credit a protection diode earns. Both run under `gpurify erc` and need no design
intent. Every parameter of both kinds is required: write `none` where a value does not apply.

The examples on this page share one stack: diffusion, poly, `li` and two metals, joined by `licon`,
`mcon` and `via1`. Each transistor has a gate 0.2 µm wide and 1 µm long, so 0.2 µm² of gate area,
joined from poly up to `met1`.

## Ratio checks

### ERC-A1: Per-layer area ratio

**What it catches.** A gate joined to too much area of one layer while that layer is etched. The
charge the etch puts on the metal drains through the thin gate oxide. Too much of it shifts the
transistor's threshold voltage or breaks the oxide, a defect that test can miss and that shortens
the part's life.

**How GPurify measures it.** GPurify rebuilds the nets as the stack stands when the collector layer
is etched: that conductor and every conductor and cut below it, nothing above. For each gate it then
divides the collector area on the gate's net by the gate area on that net:

\\[ R = \frac{A_\text{layer}}{A_\text{gate}} \\]

where \\( A_\text{layer} \\) is the merged area of the collector layer's shapes on the gate's net
at that stage (overlaps count once), and \\( A_\text{gate} \\) is the area of every gate shape on
that net at that stage. Gates that share a net at every stage the row reads are one gate, judged
once. A gate joins its net through the gate terminal layer of the deck's `device mos` row, here
`poly`.

In the example, gate G1 sits under a `met1` plate of 20 µm². Gate G2 sits under a `met1` stub of
2 µm². A second 20 µm² plate reaches G2 only through `met2`, which does not exist yet while `met1` is
etched, so it does not count:

\\[ R_{G1} = \frac{20}{0.2} = 100, \qquad R_{G2} = \frac{2}{0.2} = 10 \\]

Against a limit of 50, G1 fails and G2 passes. Breaking a long wire with a jump to a higher layer
is the usual repair, for this reason.

![Two gates in section as met1 is etched: G1 under a 20 µm² plate fails at ratio 100; G2 under a 2 µm² stub passes at 10](../../diagrams/erc-a1.svg)

**In the deck.**

```text
rule <id> antenna(<gate>, <collector>; max_ratio: <n>, sidewall: none, diode: none, diode_area: none, diode_min: none)
```

```text
grid 5nm
layer diff = gds(2, 0)
layer poly = gds(3, 0)
layer licon = gds(4, 0)
layer li = gds(5, 0)
layer mcon = gds(6, 0)
layer met1 = gds(7, 0)
layer via1 = gds(8, 0)
layer met2 = gds(9, 0)
layer dio = gds(14, 0)
layer gate = poly and diff
layer diff_active = diff not poly
connect conductors [diff_active, poly, li, met1, met2]
connect touch_within_layer
connect via licon [diff_active, li]
connect via licon [poly, li]
connect via mcon [li, met1]
connect via via1 [met1, met2]
device mos gate model "nfet" terminals [poly, diff_active, diff_active]
rule ar.met1 antenna(gate, met1; max_ratio: 50, sidewall: none, diode: none, diode_area: none, diode_min: none)
```

**Example violation.**

```sh
gpurify erc par.gds --deck a1.deck
```

```text
rules:
  ar.met1: ran, examined 2 shapes, found 1 violations
violations: 1
  ar.met1 error layer gate at (1000 nm, 500 nm) measured 100 against limit 50 on shape 16
...
```

Gate G1, reported at the centre of its gate shape, has a ratio of 100 against the limit of 50. The
ratio has no unit.

**Options.**

| Parameter | Value | Meaning |
|---|---|---|
| `max_ratio` | number | The largest ratio allowed. A ratio exactly at it passes. |
| `sidewall` | length or `none` | With a length, collector area is the perimeter times this thickness (ERC-A2). |
| `diode` | layer or `none` | A gate whose net reaches this layer is left to another row (ERC-A8). |
| `diode_area` | area or `none` | Diode area per unit of ratio, for the fix hint (ERC-A15). |
| `diode_min` | area or `none` | The smallest diode the fix hint names. Needs `diode_area`. |

**Status and limits.** Implemented. A row whose gate or collector layer holds a shape with an edge
that is not horizontal or vertical is refused.

**Sources.** Cadence LEF/DEF 5.8 Language Reference, Appendix C, `ANTENNAAREARATIO`; IHP SG13G2
rule Ant.a; [SkyWater SKY130 antenna rules](https://skywater-pdk.readthedocs.io/en/main/rules/antenna.html).

### ERC-A2: Side-area ratio

**What it catches.** A gate joined to a wire whose side walls collect too much charge. On thick
metal the etch charges the walls more than the top, so many foundries state the limit on side area.

**How GPurify measures it.** With `sidewall: <t>`, each collector shape's area is its perimeter
times \\( t \\), the layer's etched thickness, holes included. The ratio is then as in ERC-A1:

\\[ R = \frac{P \, t}{A_\text{gate}} \\]

where \\( P \\) is the perimeter of the collector shapes on the gate's net at that stage. A cut
layer in the same row always collects by its area, as LEF states for cuts. In the example, G1's
`met1` plate is 20 µm by 1 µm, so \\( P \\) = 42 µm and, with \\( t \\) = 0.35 µm, the side area is
14.7 µm². The ratio is 14.7 / 0.2 = 73.5.

![A met1 wire in section, 20 µm long and 350 nm thick: side area 14.7 µm² over a 0.2 µm² gate gives ratio 73.5 against 50](../../diagrams/erc-a2.svg)

**In the deck.**

```text
rule <id> antenna(<gate>, <collector>; max_ratio: <n>, sidewall: <length>, diode: none, diode_area: none, diode_min: none)
```

```text
grid 5nm
layer diff = gds(2, 0)
layer poly = gds(3, 0)
layer licon = gds(4, 0)
layer li = gds(5, 0)
layer mcon = gds(6, 0)
layer met1 = gds(7, 0)
layer via1 = gds(8, 0)
layer met2 = gds(9, 0)
layer dio = gds(14, 0)
layer gate = poly and diff
layer diff_active = diff not poly
connect conductors [diff_active, poly, li, met1, met2]
connect touch_within_layer
connect via licon [diff_active, li]
connect via licon [poly, li]
connect via mcon [li, met1]
connect via via1 [met1, met2]
device mos gate model "nfet" terminals [poly, diff_active, diff_active]
rule ar.met1.side antenna(gate, met1; max_ratio: 50, sidewall: 350nm, diode: none, diode_area: none, diode_min: none)
```

**Example violation.**

```sh
gpurify erc par.gds --deck a2.deck
```

```text
rules:
  ar.met1.side: ran, examined 2 shapes, found 1 violations
violations: 1
  ar.met1.side error layer gate at (1000 nm, 500 nm) measured 73.5 against limit 50 on shape 16
...
```

G1 has a side-area ratio of 73.5 against the limit of 50. G2's stub, 2 µm by 1 µm, reads 10.5 and
passes.

**Options.**

| Parameter | Value | Meaning |
|---|---|---|
| `sidewall` | length | The etched thickness \\( t \\) of every metal collector in the row. |

**Status and limits.** Implemented. One thickness serves every metal in a row, so a row that
collects two metals of different thickness needs one row per metal.

**Sources.** Cadence LEF/DEF 5.8 Language Reference, Appendix C, `ANTENNASIDEAREARATIO`;
GlobalFoundries GF180MCU rules ANT.1 to ANT.7; SkyWater SKY130 antenna rules (side-area rows).

### ERC-A3: Cumulative ratio

**What it catches.** A gate whose ratios, summed over the etch of each layer it is joined to,
exceed the limit. Each etch adds damage to the same oxide, so some foundries limit the sum, LEF's
cumulative area ratio (CAR).

**How GPurify measures it.** A row that names several collectors adds one term per etch stage, each
term measured as ERC-A1 measures it at that stage:

\\[ R = \sum_{s} \frac{A_{\text{layer},s}}{A_{\text{gate},s}} \\]

where \\( A_{\text{layer},s} \\) is the area of the layers etched at stage \\( s \\) on the gate's
net at that stage, and \\( A_{\text{gate},s} \\) is the gate area on that net at that stage. The
denominator grows as higher layers join gates together, as in IHP's `AreaRatio`. Gates that share
a net at every stage are reported once.

In the example, G1 has a 4 µm² `met1` stub and G2 a 2 µm² one. A 21 µm² `met2` plate joins them:

\\[ R_{G1} = \frac{4}{0.2} + \frac{21}{0.2 + 0.2} = 20 + 52.5 = 72.5 \\]

\\[ R_{G2} = \frac{2}{0.2} + \frac{21}{0.4} = 10 + 52.5 = 62.5 \\]

Against a limit of 70, G1 fails.

![Two gates with met1 stubs of 4 µm² and 2 µm² joined by a 21 µm² met2 plate: G1 sums to 72.5 against 70, G2 to 62.5](../../diagrams/erc-a3.svg)

**In the deck.**

```text
rule <id> antenna(<gate>, <collector>, <collector>, ...; max_ratio: <n>, sidewall: none, diode: none, diode_area: none, diode_min: none)
```

```text
grid 5nm
layer diff = gds(2, 0)
layer poly = gds(3, 0)
layer licon = gds(4, 0)
layer li = gds(5, 0)
layer mcon = gds(6, 0)
layer met1 = gds(7, 0)
layer via1 = gds(8, 0)
layer met2 = gds(9, 0)
layer dio = gds(14, 0)
layer gate = poly and diff
layer diff_active = diff not poly
connect conductors [diff_active, poly, li, met1, met2]
connect touch_within_layer
connect via licon [diff_active, li]
connect via licon [poly, li]
connect via mcon [li, met1]
connect via via1 [met1, met2]
device mos gate model "nfet" terminals [poly, diff_active, diff_active]
rule car.met2 antenna(gate, met1, met2; max_ratio: 70, sidewall: none, diode: none, diode_area: none, diode_min: none)
```

**Example violation.**

```sh
gpurify erc car.gds --deck a3.deck
```

```text
rules:
  car.met2: ran, examined 2 shapes, found 1 violations
violations: 1
  car.met2 error layer gate at (1000 nm, 500 nm) measured 72.5 against limit 70 on shape 15
...
```

G1's cumulative ratio is 72.5 against the limit of 70. A row naming `met2` alone gives both gates
52.5, and reports them as one gate, since they share a net at its only stage.

**Options.**

| Parameter | Value | Meaning |
|---|---|---|
| collectors | layers | Every layer whose etch the sum covers, in any order. A layer named twice counts once. |

**Status and limits.** Implemented. The etch order is the order of `connect conductors`, bottom
first. A collector that is neither a conductor nor a cut is taken as etched with the row's highest
layer.

**Sources.** Cadence LEF/DEF 5.8 Language Reference, Appendix C, `ANTENNACUMAREARATIO`; IHP SG13G2
rules Ant.b and Ant.d.

### ERC-A4: Cut ratio and routing-plus-cut accumulation

**What it catches.** A gate joined to too much contact or via area, alone or summed with the metal
it sits on. Cuts are etched too, and LEF's `ANTENNACUMROUTINGPLUSCUT` adds their damage to the
metal's.

**How GPurify measures it.** A cut collects by its drawn area, never by side area. It is etched at
the stage of the conductor under it, after that conductor, so it reads the nets that conductor
reads. A row that lists cuts beside metals adds them in etch order into one cumulative ratio. In
`antenna_electrical`, a cut's area is first multiplied by `cut_factor`, LEF's `ANTENNAAREAFACTOR`.

In the example of ERC-A3, each stub carries one `via1` cut of 0.09 µm². Listing `via1` adds it at
the `met1` stage: G1 reads (4 + 0.09) / 0.2 + 52.5 = 72.95.

![The ERC-A3 layout with the via1 cut on G1's stub marked: it adds 0.09 µm² at the met1 stage, so G1 reads 72.95 against 70](../../diagrams/erc-a4.svg)

**In the deck.**

```text
rule <id> antenna(<gate>, <metal>, <cut>, <metal>, ...; max_ratio: <n>, sidewall: none, diode: none, diode_area: none, diode_min: none)
```

```text
grid 5nm
layer diff = gds(2, 0)
layer poly = gds(3, 0)
layer licon = gds(4, 0)
layer li = gds(5, 0)
layer mcon = gds(6, 0)
layer met1 = gds(7, 0)
layer via1 = gds(8, 0)
layer met2 = gds(9, 0)
layer dio = gds(14, 0)
layer gate = poly and diff
layer diff_active = diff not poly
connect conductors [diff_active, poly, li, met1, met2]
connect touch_within_layer
connect via licon [diff_active, li]
connect via licon [poly, li]
connect via mcon [li, met1]
connect via via1 [met1, met2]
device mos gate model "nfet" terminals [poly, diff_active, diff_active]
rule cum.via1 antenna(gate, met1, via1, met2; max_ratio: 70, sidewall: none, diode: none, diode_area: none, diode_min: none)
```

**Example violation.**

```sh
gpurify erc car.gds --deck a4.deck
```

```text
rules:
  cum.via1: ran, examined 2 shapes, found 1 violations
violations: 1
  cum.via1 error layer gate at (1000 nm, 500 nm) measured 72.95 against limit 70 on shape 15
...
```

G1's routing-plus-cut ratio is 72.95 against the limit of 70. A row that names only `via1`, as
IHP's Ant.d does, reads 0.09 / 0.2 = 0.45 for each gate.

**Options.**

| Parameter | Value | Meaning |
|---|---|---|
| `cut_factor` | number | In `antenna_electrical` only: the factor on every cut's area. Use 1 for none. |

**Status and limits.** Implemented. A layer counts as a cut when a `connect via` line names it.

**Sources.** Cadence LEF/DEF 5.8 Language Reference, Appendix C, `ANTENNACUMROUTINGPLUSCUT` and
`ANTENNAAREAFACTOR`; GlobalFoundries GF180MCU rules ANT.8 to ANT.13; SkyWater SKY130 rules
licon.1 and via.1; IHP SG13G2 rule Ant.c.

## Protection diodes

### ERC-A5: Subtractive diode credit

**What it catches.** A gate whose ratio stays above the limit after the credit its protection diode
earns. A diode on the gate's net bleeds the etch charge to the substrate, so the foundry subtracts
an amount per µm² of diode, as SkyWater SKY130 does with its etch gate area ratio (EGAR).

**How GPurify measures it.** `antenna_electrical` takes the ratio of ERC-A1 to ERC-A4 and subtracts
the diode credit:

\\[ R_\text{credited} = R - K \, A_\text{diode} - B \\]

where \\( R \\) is the ratio, \\( A_\text{diode} \\) is the area in µm² of the `diode` layer on the
gate's net when the row's highest collector is etched, \\( K \\) is `diode_credit` and \\( B \\) is
`diode_bonus`. The bonus applies only to a gate with some diode area. LEF's subtractive form,
`area_minus_diode` (\\( m \\)), takes \\( m \, A_\text{diode} \\) off each collector's area before
the division, and the running sum never falls below zero.

In the example, G2 has the 100 ratio of ERC-A1 and a 1 µm² diode joined through `li`. With
\\( K \\) = 10 and \\( B \\) = 20: \\( R_\text{credited} \\) = 100 − 10 × 1 − 20 = 70, above the
limit of 50. G1, without a diode, earns no credit and reads 100.

![A gate under 20 µm² of met1 with a 1 µm² diode on its net through li: 100 − 10 × 1 − 20 = 70 against 50](../../diagrams/erc-a5.svg)

**In the deck.**

```text
rule <id> antenna_electrical(<gate>, <collector>, ...; max_ratio: <n>, sidewall: <length> | none, cut_factor: <n>,
    diode: <layer>, diode_credit: <n>, diode_bonus: <n>, area_minus_diode: <n>, gate_plus_diode: <n>,
    diode_reduce: none, diode_max_ratio: none, exempt: <layer> | none)
```

```text
grid 5nm
layer diff = gds(2, 0)
layer poly = gds(3, 0)
layer licon = gds(4, 0)
layer li = gds(5, 0)
layer mcon = gds(6, 0)
layer met1 = gds(7, 0)
layer via1 = gds(8, 0)
layer met2 = gds(9, 0)
layer dio = gds(14, 0)
layer gate = poly and diff
layer diff_active = diff not poly
connect conductors [diff_active, poly, li, met1, met2]
connect touch_within_layer
connect via licon [diff_active, li]
connect via licon [poly, li]
connect via mcon [li, met1]
connect via via1 [met1, met2]
device mos gate model "nfet" terminals [poly, diff_active, diff_active]
rule egar.met1 antenna_electrical(gate, met1; max_ratio: 50, sidewall: none, cut_factor: 1,
    diode: dio, diode_credit: 10, diode_bonus: 20, area_minus_diode: 0, gate_plus_diode: 0,
    diode_reduce: none, diode_max_ratio: none, exempt: none)
```

**Example violation.**

```sh
gpurify erc diode.gds --deck a5.deck
```

```text
rules:
  egar.met1: ran, examined 2 shapes, found 2 violations
violations: 2
  egar.met1 error layer gate at (1000 nm, 500 nm) measured 100 against limit 50 on shape 17 fix 3000000 nm^2
  egar.met1 error layer gate at (1000 nm, 10500 nm) measured 70 against limit 50 on shape 18 fix 2000000 nm^2
...
```

G2, at (1000 nm, 10500 nm), reads 70 after its credit against the limit of 50. Each finding also
names the diode area to add (ERC-A15): 3 µm² for G1 and 2 µm² more for G2.

**Options.**

| Parameter | Value | Meaning |
|---|---|---|
| `diode` | layer or `none` | The protection diode layer, measured on the gate's net at the row's highest stage. |
| `diode_credit` | number | \\( K \\): the credit per µm² of diode. SKY130's `met1` value is 400. |
| `diode_bonus` | number | \\( B \\): the credit for having any diode. SKY130's `met1` value is 2200. |
| `area_minus_diode` | number | \\( m \\): LEF's `ANTENNAAREAMINUSDIFF`, per collector layer. Use 0 for none. |
| `max_ratio` | number | The limit on the credited ratio. |

**Status and limits.** Implemented. The diode area is the `diode` layer's area on the net, whatever
the diode's size, so a deck that asks for a minimum diode size derives the layer with
`.with_area()` (ERC-A9).

**Sources.** [SkyWater SKY130 antenna rules](https://skywater-pdk.readthedocs.io/en/main/rules/antenna.html),
EGAR and Table Ig; Cadence LEF/DEF 5.8 Language Reference, Appendix C, `ANTENNAAREAMINUSDIFF`;
[KLayout `antenna_check`](https://www.klayout.de/doc/about/drc_ref_netter.html), diode factor.

### ERC-A6: Additive diode credit

**What it catches.** A gate whose ratio is too high once its diode's area is counted as extra gate
area. GlobalFoundries GF180MCU re-checks a failing gate with "gate area + MF × diode area", MF being
2 for a thin oxide and 15 for a thick one.

**How GPurify measures it.** With `gate_plus_diode` (\\( p \\)), each collector layer's term
becomes:

\\[ R_\ell = \frac{A_\ell}{A_\text{gate} + p \, A_\text{diode}} \\]

where \\( A_\ell \\) is that layer's collecting area and \\( A_\text{diode} \\) is the diode area on
the gate's net as that layer is etched. In the example, G2: 20 / (0.2 + 2 × 1) = 9.09, against a
limit of 5.

![The gate and 1 µm² diode of ERC-A5: 20 / (0.2 + 2 × 1) = 9.09 against a limit of 5](../../diagrams/erc-a6.svg)

**In the deck.**

```text
rule <id> antenna_electrical(<gate>, <collector>; max_ratio: <n>, sidewall: <length> | none, cut_factor: 1,
    diode: <layer>, diode_credit: 0, diode_bonus: 0, area_minus_diode: 0, gate_plus_diode: <n>,
    diode_reduce: none, diode_max_ratio: none, exempt: none)
```

```text
grid 5nm
layer diff = gds(2, 0)
layer poly = gds(3, 0)
layer licon = gds(4, 0)
layer li = gds(5, 0)
layer mcon = gds(6, 0)
layer met1 = gds(7, 0)
layer via1 = gds(8, 0)
layer met2 = gds(9, 0)
layer dio = gds(14, 0)
layer gate = poly and diff
layer diff_active = diff not poly
connect conductors [diff_active, poly, li, met1, met2]
connect touch_within_layer
connect via licon [diff_active, li]
connect via licon [poly, li]
connect via mcon [li, met1]
connect via via1 [met1, met2]
device mos gate model "nfet" terminals [poly, diff_active, diff_active]
rule mf.met1 antenna_electrical(gate, met1; max_ratio: 5, sidewall: none, cut_factor: 1,
    diode: dio, diode_credit: 0, diode_bonus: 0, area_minus_diode: 0, gate_plus_diode: 2,
    diode_reduce: none, diode_max_ratio: none, exempt: none)
```

**Example violation.**

```sh
gpurify erc diode.gds --deck a6.deck
```

```text
rules:
  mf.met1: ran, examined 2 shapes, found 2 violations
violations: 2
  mf.met1 error layer gate at (1000 nm, 500 nm) measured 100 against limit 5 on shape 17
  mf.met1 error layer gate at (1000 nm, 10500 nm) measured 9.090909090909092 against limit 5 on shape 18
...
```

G2 reads 9.09 against the limit of 5. G1 has no diode, so its gate area stays 0.2 µm² and it reads
100. Neither finding carries a fix hint, because the ratio itself moves with the diode.

**Options.**

| Parameter | Value | Meaning |
|---|---|---|
| `gate_plus_diode` | number | \\( p \\): GF180MCU's MF, LEF's `ANTENNAGATEPLUSDIFF`. Use 0 for none. |

**Status and limits.** Implemented. One row per oxide class carries its own factor (ERC-A12).

**Sources.** GlobalFoundries GF180MCU rule ANT.16; Cadence LEF/DEF 5.8 Language Reference,
Appendix C, `ANTENNAGATEPLUSDIFF`.

### ERC-A7: Diffusion-dependent limit

**What it catches.** A gate above a limit that rises with its diode area. LEF states such a limit as
a piecewise-linear table, `ANTENNADIFFAREARATIO PWL`, and can scale the collecting area the same way,
`ANTENNAAREADIFFREDUCEPWL`.

**How GPurify measures it.** A table is a list of `(area, value)` points, areas rising. GPurify reads
it at the gate's diode area: linear between points, and the end value beyond either end. With
`diode_max_ratio`, the table is the limit of a gate that has diode area; a gate without one keeps
`max_ratio`. With `diode_reduce`, each collector's area is multiplied by the table's value at the
diode area its net has as that layer is etched.

In the example, the table runs from 20 at 0 µm² to 100 at 2 µm². G2's 1 µm² diode reads a limit of
20 + (100 − 20) × 1/2 = 60, and its ratio of 100 fails.

![A graph of the limit against diode area, rising from 20 at 0 µm² to 100 at 2 µm²: at 1 µm² the limit is 60, below the ratio of 100](../../diagrams/erc-a7.svg)

**In the deck.**

```text
rule <id> antenna_electrical(<gate>, <collector>; max_ratio: <n>, sidewall: <length> | none, cut_factor: 1,
    diode: <layer>, diode_credit: 0, diode_bonus: 0, area_minus_diode: 0, gate_plus_diode: 0,
    diode_reduce: [(<area>, <n>), ...] | none, diode_max_ratio: [(<area>, <n>), ...] | none, exempt: none)
```

```text
grid 5nm
layer diff = gds(2, 0)
layer poly = gds(3, 0)
layer licon = gds(4, 0)
layer li = gds(5, 0)
layer mcon = gds(6, 0)
layer met1 = gds(7, 0)
layer via1 = gds(8, 0)
layer met2 = gds(9, 0)
layer dio = gds(14, 0)
layer gate = poly and diff
layer diff_active = diff not poly
connect conductors [diff_active, poly, li, met1, met2]
connect touch_within_layer
connect via licon [diff_active, li]
connect via licon [poly, li]
connect via mcon [li, met1]
connect via via1 [met1, met2]
device mos gate model "nfet" terminals [poly, diff_active, diff_active]
rule pwl.met1 antenna_electrical(gate, met1; max_ratio: 50, sidewall: none, cut_factor: 1,
    diode: dio, diode_credit: 0, diode_bonus: 0, area_minus_diode: 0, gate_plus_diode: 0,
    diode_reduce: none, diode_max_ratio: [(0um2, 20), (2um2, 100)], exempt: none)
```

**Example violation.**

```sh
gpurify erc diode.gds --deck a7.deck
```

```text
rules:
  pwl.met1: ran, examined 2 shapes, found 2 violations
violations: 2
  pwl.met1 error layer gate at (1000 nm, 500 nm) measured 100 against limit 50 on shape 17 fix 2000000 nm^2
  pwl.met1 error layer gate at (1000 nm, 10500 nm) measured 100 against limit 60 on shape 18 fix 1000000 nm^2
...
```

G2 reads 100 against the table's limit of 60 at its 1 µm² diode. G1 has no diode and is held to
`max_ratio`, 50. With `diode_reduce: [(0um2, 1), (2um2, 0.2)]` instead, G2's area is scaled by 0.6
and reads 60.

**Options.**

| Parameter | Value | Meaning |
|---|---|---|
| `diode_max_ratio` | table or `none` | The limit as a function of diode area, LEF's `ANTENNADIFFAREARATIO PWL`. |
| `diode_reduce` | table or `none` | The factor on collecting area, LEF's `ANTENNAAREADIFFREDUCEPWL`. |

**Status and limits.** Implemented. Beyond the last point the table holds its end value. LEF does
not say what happens there, and OpenROAD extends the last segment instead, so a gate with more diode
area than the last point reads a lower limit in GPurify than in OpenROAD. LEF cannot state a step,
so the SKY130 tech LEF ramps its bonus in between 0.0125 µm² and 0.0225 µm²; a deck that copies it
inherits the ramp.

**Sources.** Cadence LEF/DEF 5.8 Language Reference, `ANTENNADIFFAREARATIO PWL` and
`ANTENNAAREADIFFREDUCEPWL`; the SkyWater SKY130 tech LEF.

### ERC-A8: Separate limits with and without a diode

**What it catches.** A process that states two limits: a strict one for an unprotected gate, and a
looser one for a gate with a protection diode. IHP SG13G2 holds metal to 200 without a diode
(Ant.b) and to 20000 with one (Ant.e).

**How GPurify measures it.** Write two rows. An `antenna` row with `diode: <layer>` skips every gate
whose net reaches that layer at the row's highest stage; those gates are not counted as examined.
An `antenna_electrical` row with the same diode layer and no credit holds every gate to the looser
limit. A gate without a diode then fails the loose row only where it already fails the strict one.

![Two gates: G1 without a diode fails Ant.b at 100 against 50; G2 with a diode is skipped by Ant.b and passes Ant.e at 100 against 200](../../diagrams/erc-a8.svg)

**In the deck.**

```text
rule <id> antenna(<gate>, <collector>; max_ratio: <n>, sidewall: none, diode: <layer>, diode_area: none, diode_min: none)
rule <id> antenna_electrical(<gate>, <collector>; max_ratio: <n>, sidewall: none, cut_factor: 1,
    diode: <layer>, diode_credit: 0, diode_bonus: 0, area_minus_diode: 0, gate_plus_diode: 0,
    diode_reduce: none, diode_max_ratio: none, exempt: none)
```

```text
grid 5nm
layer diff = gds(2, 0)
layer poly = gds(3, 0)
layer licon = gds(4, 0)
layer li = gds(5, 0)
layer mcon = gds(6, 0)
layer met1 = gds(7, 0)
layer via1 = gds(8, 0)
layer met2 = gds(9, 0)
layer dio = gds(14, 0)
layer gate = poly and diff
layer diff_active = diff not poly
connect conductors [diff_active, poly, li, met1, met2]
connect touch_within_layer
connect via licon [diff_active, li]
connect via licon [poly, li]
connect via mcon [li, met1]
connect via via1 [met1, met2]
device mos gate model "nfet" terminals [poly, diff_active, diff_active]
rule Ant.b antenna(gate, met1; max_ratio: 50, sidewall: none, diode: dio, diode_area: none, diode_min: none)
rule Ant.e antenna_electrical(gate, met1; max_ratio: 200, sidewall: none, cut_factor: 1,
    diode: dio, diode_credit: 0, diode_bonus: 0, area_minus_diode: 0, gate_plus_diode: 0,
    diode_reduce: none, diode_max_ratio: none, exempt: none)
```

**Example violation.**

```sh
gpurify erc diode.gds --deck a8.deck
```

```text
rules:
  Ant.b: ran, examined 1 shapes, found 1 violations
  Ant.e: ran, examined 2 shapes, found 0 violations
violations: 1
  Ant.b error layer gate at (1000 nm, 500 nm) measured 100 against limit 50 on shape 17
...
```

G1, without a diode, reads 100 against Ant.b's limit of 50. Ant.b examined only G1; Ant.e examined
both gates and passed them at 100 against 200.

**Options.**

| Parameter | Value | Meaning |
|---|---|---|
| `diode` | layer | On `antenna`: the gates whose net reaches it are left to the other row. |

**Status and limits.** Implemented. Any area of the diode layer on the net counts as a diode. To
count only diodes of the foundry's minimum size, derive the layer with `.with_area()`, as the
shipped IHP SG13G2 deck does (ERC-A9).

**Sources.** IHP SG13G2 rules Ant.b with Ant.e, and Ant.d with Ant.f;
[KLayout `antenna_check`](https://www.klayout.de/doc/about/drc_ref_netter.html) with a diode layer.

### ERC-A9: Minimum protection-diode size

**What it catches.** A protection diode smaller than the foundry allows. IHP SG13G2 rule Ant.g asks
for at least 0.16 µm², and a smaller diode does not earn the looser with-diode limit.

**How GPurify measures it.** GPurify has no antenna parameter for this. Write it with general deck
operations: an `area` rule on the marked diode, and a derived diode layer that keeps only diodes of
the minimum size, for the antenna rows to name as their `diode`.

![Top view of a 0.5 µm by 0.2 µm marked diode, 0.1 µm² against the 0.16 µm² minimum, beside a 1 µm² diode that passes](../../diagrams/erc-a9.svg)

**In the deck.**

```text
layer <diode> = <marked diode>.with_area(>= <area>)
rule <id> area(<marked diode>) >= <area>
```

```text
grid 5nm
layer nwell = gds(1, 0)
layer activ = gds(2, 0)
layer psd = gds(11, 0)
layer recog_diode = gds(14, 0)
layer ant_marked = activ and recog_diode
layer ant_diode = ant_marked.with_area(>= 0.16um2)
rule Ant.g area(ant_marked) >= 0.16um2
```

**Example violation.**

```sh
gpurify drc dsize.gds --deck a9.deck
```

```text
rules:
  Ant.g: ran, examined 3 shapes, found 1 violations
violations: 1
  Ant.g error layer ant_marked at (250 nm, 100 nm) measured 100000 nm^2 against limit 160000 nm^2 on shape 8
...
```

The diode at (250 nm, 100 nm) has 0.1 µm² against the 0.16 µm² minimum. The `area` rule runs under
`gpurify drc`, not `erc`.

**Status and limits.** Expressible. The size holds per diode, as the IHP manual states it. The
foundry's own KLayout deck sums a net's diode area and counts it only above 0.16 µm².

**Sources.** IHP SG13G2 Layout Rules, section 7.1, rule Ant.g.

### ERC-A10: Diode well legality

**What it catches.** An antenna diode drawn in the wrong well. IHP SG13G2 forbids its n+ antenna
diode (`dantenna`) in an n-well, rule Ant.h, and its p+ one (`dpantenna`) outside an n-well, rule
Ant.i. In the wrong well the junction is not a diode to the substrate and does not drain the charge.

**How GPurify measures it.** GPurify has no antenna parameter for this. Derive the diode in the
wrong well and forbid it with `forbidden`, which flags every shape of the layer.

![Section of three marked diodes: an n+ one in the substrate passes, an n+ one in an n-well fails Ant.h, a p+ one in the substrate fails Ant.i](../../diagrams/erc-a10.svg)

**In the deck.**

```text
rule <id> forbidden(<diode in the wrong well>)
```

```text
grid 5nm
layer nwell = gds(1, 0)
layer activ = gds(2, 0)
layer psd = gds(11, 0)
layer recog_diode = gds(14, 0)
layer dantenna_nw = ((activ not psd) and recog_diode) and nwell
layer dpantenna_pw = ((activ and psd) and recog_diode) not nwell
rule Ant.h forbidden(dantenna_nw)
rule Ant.i forbidden(dpantenna_pw)
```

**Example violation.**

```sh
gpurify drc dsize.gds --deck a10.deck
```

```text
rules:
  Ant.h: ran, examined 1 shapes, found 1 violations
  Ant.i: ran, examined 1 shapes, found 1 violations
violations: 2
  Ant.h error layer dantenna_nw at (3000 nm, 1000 nm) measured 1000000 nm^2 against limit 0 nm^2 on shape 12
  Ant.i error layer dpantenna_pw at (6000 nm, 1000 nm) measured 1000000 nm^2 against limit 0 nm^2 on shape 15
...
```

The n+ diode in the n-well, 1 µm², breaks Ant.h, and the p+ diode in the substrate breaks Ant.i.
`forbidden` reports each shape's area against a limit of zero.

**Status and limits.** Expressible. The shipped IHP SG13G2 deck does not carry Ant.h or Ant.i yet.

**Sources.** IHP SG13G2 Layout Rules, section 7.1, rules Ant.h and Ant.i.

## Victims and exemptions

### ERC-A11: MIM capacitor as victim

**What it catches.** A MIM capacitor whose top plate is joined to too much metal during the etch.
The capacitor's thin dielectric breaks down like a gate oxide. GlobalFoundries GF180MCU states it
as rules ANT.14 (metal) and ANT.15 (via) against the MIM area.

**How GPurify measures it.** The first argument of an antenna row takes any layer, not only a gate.
A layer that is not a conductor joins the net of the conductor it lies on: the gate terminal layer of
a `device mos` row first, else the conductor that no other overlapped conductor reaches upward
through cuts. Metal routed over the capacitor is passed over. On GF180MCU's topology the top plate
(FuseTop) reaches `met2` through `via1`, apart from its `met1` bottom plate.

In the example, a 2 µm by 2 µm capacitor, 4 µm², reaches a `met2` strip 1500 µm by 1 µm. Its side
area with \\( t \\) = 0.54 µm is 3002 × 0.54 = 1621.08 µm², and the ratio is 1621.08 / 4 = 405.27.

![Section of a MIM capacitor: the fusetop top plate joins a 1500 µm met2 strip through via1, ratio 405.27 against 400](../../diagrams/erc-a11.svg)

**In the deck.**

```text
rule <id> antenna(<capacitor marker>, <collector>; max_ratio: <n>, sidewall: <length> | none, diode: none, diode_area: none, diode_min: none)
```

```text
grid 5nm
layer met1 = gds(7, 0)
layer via1 = gds(8, 0)
layer met2 = gds(9, 0)
layer fusetop = gds(17, 0)
layer mim = gds(16, 0)
connect conductors [met1, fusetop, met2]
connect touch_within_layer
connect via via1 [met1, met2]
connect via via1 [fusetop, met2]
rule ANT.14 antenna(mim, met2; max_ratio: 400, sidewall: 540nm, diode: none, diode_area: none, diode_min: none)
rule ANT.15 antenna(mim, via1; max_ratio: 20, sidewall: none, diode: none, diode_area: none, diode_min: none)
```

**Example violation.**

```sh
gpurify erc mim.gds --deck a11.deck
```

```text
rules:
  ANT.14: ran, examined 1 shapes, found 1 violations
  ANT.15: ran, examined 1 shapes, found 0 violations
violations: 1
  ANT.14 error layer mim at (1000 nm, 1000 nm) measured 405.27 against limit 400 on shape 3
...
```

The capacitor's metal ratio is 405.27 against ANT.14's limit of 400. Its via ratio, 0.16 / 4 = 0.04,
passes ANT.15.

**Options.** As ERC-A1; the first argument is the victim layer.

**Status and limits.** Implemented. The shipped GF180MCU deck does not carry ANT.14 and ANT.15 yet.

**Sources.** GlobalFoundries GF180MCU rules ANT.14, ANT.15 and MIM.4.

### ERC-A12: Oxide-class limits

**What it catches.** A gate held to the wrong oxide's limit. Thin and thick gate oxides tolerate
different charge, so a process states a limit per oxide class, and a ratio counts only the gate area
of its own class.

**How GPurify measures it.** Write one row per oxide class, each naming a derived gate layer of that
class. A row's denominator counts only its own gate layer's area, even where gates of both classes
share a net. This is LEF's `ANTENNAMODEL OXIDE1` to `OXIDE4`.

In the example one poly line crosses a thin gate and a thick gate, each 0.2 µm², under 20 µm² of
`met1`. Each row reads 20 / 0.2 = 100. One row over both gates would read 20 / 0.4 = 50.

![One poly line over a thin gate and a thick gate, each 0.2 µm²: each oxide's row reads 20/0.2 = 100 against 80](../../diagrams/erc-a12.svg)

**In the deck.**

```text
layer <thin gate> = <gate> not <thick marker>
layer <thick gate> = <gate> and <thick marker>
rule <id> antenna(<thin gate>, <collector>; ...)
rule <id> antenna(<thick gate>, <collector>; ...)
```

```text
grid 5nm
layer diff = gds(2, 0)
layer poly = gds(3, 0)
layer licon = gds(4, 0)
layer li = gds(5, 0)
layer mcon = gds(6, 0)
layer met1 = gds(7, 0)
layer thick = gds(15, 0)
layer gate = poly and diff
layer gate_thin = gate not thick
layer gate_thick = gate and thick
layer diff_active = diff not poly
connect conductors [diff_active, poly, li, met1]
connect touch_within_layer
connect via licon [diff_active, li]
connect via licon [poly, li]
connect via mcon [li, met1]
device mos gate model "nfet" terminals [poly, diff_active, diff_active]
rule ANT.2 antenna(gate_thin, met1; max_ratio: 80, sidewall: none, diode: none, diode_area: none, diode_min: none)
rule ANT.2.DG antenna(gate_thick, met1; max_ratio: 80, sidewall: none, diode: none, diode_area: none, diode_min: none)
```

**Example violation.**

```sh
gpurify erc oxide.gds --deck a12.deck
```

```text
rules:
  ANT.2: ran, examined 1 shapes, found 1 violations
  ANT.2.DG: ran, examined 1 shapes, found 1 violations
violations: 2
  ANT.2 error layer gate_thin at (1000 nm, 500 nm) measured 100 against limit 80 on shape 11
  ANT.2.DG error layer gate_thick at (1000 nm, -2500 nm) measured 100 against limit 80 on shape 12
...
```

Each gate reads 100 against its class's limit of 80.

**Options.** As ERC-A1 and ERC-A5, once per class; `gate_plus_diode` carries the class's own factor.

**Status and limits.** Implemented. A macro pin's LEF antenna values for `OXIDE2` to `OXIDE4` are not
read (ERC-A14).

**Sources.** Cadence LEF/DEF 5.8 Language Reference, `ANTENNAMODEL`; GlobalFoundries GF180MCU
rules ANT.1 to ANT.16, one per gate oxide.

### ERC-A13: Exemption for substrate-shorted nets

**What it catches.** Nothing: it keeps a gate out of the check. SkyWater SKY130 rule .ar.1 exempts any
net joined to a p+ substrate tap, since the tap drains the charge.

**How GPurify measures it.** An `antenna_electrical` row with `exempt: <layer>` skips every gate
whose net reaches that layer when the row's highest collector is etched. The gate is not examined.
An `antenna` row's `diode` skips gates the same way (ERC-A8). Nothing else exempts a gate.

![Two gates under 20 µm² of met1: G1 fails at 100 against 50; G2's net reaches a ptap, so it is not examined](../../diagrams/erc-a13.svg)

**In the deck.**

```text
rule <id> antenna_electrical(...; ..., exempt: <layer>)
```

```text
grid 5nm
layer diff = gds(2, 0)
layer poly = gds(3, 0)
layer licon = gds(4, 0)
layer li = gds(5, 0)
layer mcon = gds(6, 0)
layer met1 = gds(7, 0)
layer via1 = gds(8, 0)
layer met2 = gds(9, 0)
layer ptap = gds(14, 0)
layer gate = poly and diff
layer diff_active = diff not poly
connect conductors [diff_active, poly, li, met1, met2]
connect touch_within_layer
connect via licon [diff_active, li]
connect via licon [poly, li]
connect via mcon [li, met1]
connect via via1 [met1, met2]
device mos gate model "nfet" terminals [poly, diff_active, diff_active]
rule ar.met1 antenna_electrical(gate, met1; max_ratio: 50, sidewall: none, cut_factor: 1,
    diode: none, diode_credit: 0, diode_bonus: 0, area_minus_diode: 0, gate_plus_diode: 0,
    diode_reduce: none, diode_max_ratio: none, exempt: ptap)
```

**Example violation.**

```sh
gpurify erc diode.gds --deck a13.deck
```

```text
rules:
  ar.met1: ran, examined 1 shapes, found 1 violations
violations: 1
  ar.met1 error layer gate at (1000 nm, 500 nm) measured 100 against limit 50 on shape 17
...
```

Of the two gates, only G1 was examined; it reads 100 against 50. G2, on the tap, is skipped.

> [!WARNING]
> An exempt gate is not counted as examined. A row that examined 0 gates passed none.

**Options.**

| Parameter | Value | Meaning |
|---|---|---|
| `exempt` | layer or `none` | Gates whose net reaches this layer at the row's highest stage are skipped. |

**Status and limits.** Implemented. No known limits.

**Sources.** [SkyWater SKY130 antenna rules](https://skywater-pdk.readthedocs.io/en/main/rules/antenna.html), rule .ar.1.

## Macros and fix hints

### ERC-A14: Macro-pin antenna

**What it catches.** An antenna violation whose gate sits inside a placed block. A DEF layout draws
each block as its LEF abstract, so its gates are not drawn. The LEF states them on the pin instead,
as `ANTENNAGATEAREA` and its kin.

**How GPurify measures it.** When a DEF layout is read with its LEFs, each placed pin with antenna
data takes part in the rows:

- `ANTENNAGATEAREA` is gate area on the pin's net from its layer's etch stage on.
- `ANTENNADIFFAREA` is diode area, in a row with a `diode` layer.
- `ANTENNAPARTIALMETALAREA`, `ANTENNAPARTIALMETALSIDEAREA` and `ANTENNAPARTIALCUTAREA` add to the
  collecting area of the layer they name, beside the pin's drawn shape.
- In a row of several collectors, `ANTENNAMAXAREACAR`, `ANTENNAMAXSIDEAREACAR` and
  `ANTENNAMAXCUTCAR` add the ratio the pin's gate already carries inside the block.

A value stated per layer counts from that layer's stage; GPurify takes the highest stated layer
standing. A finding on a pin's gate is reported at the pin. In the example, an inverter's pin `A`
carries 0.5 µm² of gate and 1 µm² of partial `met1`. A 10 µm² `met1` wire covers the pin:
(10 + 1) / 0.5 = 22.

![An inverter block whose pin A states 0.5 µm² of gate area, under a 10 µm by 1 µm met1 wire plus 1 µm² partial area: ratio 22 against 20](../../diagrams/erc-a14.svg)

**In the deck.** Nothing extra in the deck: the antenna rows are as above, and the gate argument is
still required. Run with the DEF layout and `--lef`. The LEF names its layers as the deck does.

```text
grid 1nm
layer met1 = gds(1, 0)
layer via1 = gds(2, 0)
layer met2 = gds(3, 0)
layer gate = gds(6, 0)
connect conductors [met1, met2]
connect touch_within_layer
connect via via1 [met1, met2]
connect label met1 names met1
connect label met2 names met2
rule par.met1 antenna(gate, met1; max_ratio: 20, sidewall: none, diode: none, diode_area: none, diode_min: none)
```

```text
VERSION 5.8 ;
UNITS DATABASE MICRONS 1000 ; END UNITS
LAYER met1 TYPE ROUTING ; WIDTH 0.2 ; END met1
LAYER via1 TYPE CUT ; END via1
LAYER met2 TYPE ROUTING ; WIDTH 0.2 ; END met2
MACRO INV
  CLASS CORE ;
  ORIGIN 0 0 ;
  SIZE 1 BY 1 ;
  PIN A
    DIRECTION INPUT ;
    ANTENNAGATEAREA 0.5 LAYER met1 ;
    ANTENNAPARTIALMETALAREA 1.0 LAYER met1 ;
    PORT
      LAYER met1 ;
        RECT 0 0 0.2 0.2 ;
    END
  END A
END INV
END LIBRARY
```

```text
VERSION 5.8 ;
DESIGN top ;
UNITS DISTANCE MICRONS 1000 ;
DIEAREA ( 0 0 ) ( 20000 5000 ) ;
COMPONENTS 1 ;
- u1 INV + PLACED ( 1000 1000 ) N ;
END COMPONENTS
SPECIALNETS 1 ;
- n ( u1 A )
+ RECT met1 ( 1000 1000 ) ( 11000 2000 ) ;
END SPECIALNETS
END DESIGN
```

**Example violation.**

```sh
gpurify erc top.def --deck a14.deck --lef cells.lef
```

```text
rules:
  par.met1: ran, examined 1 shapes, found 1 violations
violations: 1
  par.met1 error layer met1 at (1100 nm, 1100 nm) measured 22 against limit 20 on shape 0
...
```

Pin `A` of `u1`, at (1100 nm, 1100 nm), reads 22 against the limit of 20.

**Options.** As ERC-A1 and ERC-A5.

**Status and limits.** Partial.

- A DEF `PINS` section's own `ANTENNAPIN*` values, a budget passed down to a block, are not read.
- `ANTENNAMODEL OXIDE2` to `OXIDE4` values are not read: every row counts a pin's `OXIDE1` values, so
  a deck with one row per oxide class holds the pin to each class.
- A LEF CAR value that already counts the pin layer's partial area counts it twice, an over-report.
- A GDS layout flattens each block and checks its geometry as drawn; the LEF values play no part.

**Sources.** Cadence LEF/DEF 5.8 Language Reference, `ANTENNAGATEAREA`, `ANTENNADIFFAREA`,
`ANTENNAPARTIAL*` and `ANTENNAMAX*CAR`, and Appendix C, Examples 1 and 2.

### ERC-A15: Fix hint for the required diode area

**What it catches.** Nothing new: it tells you how to repair an antenna finding. Each finding a
protection diode can clear names the diode area to add, the report's `fix` (`"fix"` in JSON).

**How GPurify measures it.** An `antenna_electrical` row solves its own model for the least added
area that brings the credited ratio within its limit. Under SKY130's EGAR the total diode area must
satisfy

\\[ A_\text{diode} \ge \frac{R - L - B}{K} \\]

where \\( R \\) is the ratio, \\( L \\) is the limit, \\( B \\) is `diode_bonus` and \\( K \\) is
`diode_credit`. The hint is that total less the diode the net already has. A `diode_max_ratio` table
is solved segment by segment. An `antenna` row with `diode_area` gives IHP SG13G2's Ant.g Note 4
instead: `diode_area` times the ratio, at least `diode_min`.

In the example of ERC-A5, G2 reads 100 with 1 µm² of diode, \\( K \\) = 10, \\( B \\) = 20 and
\\( L \\) = 50. It needs (100 − 50 − 20) / 10 = 3 µm² in all, so 2 µm² more. G1 has none and needs
3 µm².

![A graph of the credited ratio against diode area: G2 reads 70 at 1 µm²; the line meets the limit of 50 at 3 µm², so the fix is 2 µm²](../../diagrams/erc-a15.svg)

**In the deck.** For `antenna_electrical`, nothing: the hint comes from the row's credit. For
`antenna`, give `diode_area` and `diode_min`.

```text
grid 5nm
layer diff = gds(2, 0)
layer poly = gds(3, 0)
layer licon = gds(4, 0)
layer li = gds(5, 0)
layer mcon = gds(6, 0)
layer met1 = gds(7, 0)
layer via1 = gds(8, 0)
layer met2 = gds(9, 0)
layer dio = gds(14, 0)
layer gate = poly and diff
layer diff_active = diff not poly
connect conductors [diff_active, poly, li, met1, met2]
connect touch_within_layer
connect via licon [diff_active, li]
connect via licon [poly, li]
connect via mcon [li, met1]
connect via via1 [met1, met2]
device mos gate model "nfet" terminals [poly, diff_active, diff_active]
rule Ant.d antenna(gate, met1; max_ratio: 50, sidewall: none, diode: none, diode_area: 0.02um2, diode_min: 0.16um2)
```

**Example violation.**

```sh
gpurify erc diode.gds --deck a15.deck
```

```text
rules:
  Ant.d: ran, examined 2 shapes, found 2 violations
violations: 2
  Ant.d error layer gate at (1000 nm, 500 nm) measured 100 against limit 50 on shape 17 fix 2000000 nm^2
...
```

G1 reads 100, and the hint is 0.02 µm² × 100 = 2 µm² of diode, above the 0.16 µm² floor. The report
prints the area in nm²: `fix 2000000 nm^2` is 2 µm².

**Options.**

| Parameter | Value | Meaning |
|---|---|---|
| `diode_area` | area or `none` | On `antenna`: diode area per unit of ratio (IHP Note 4: `0.02um2`). |
| `diode_min` | area or `none` | On `antenna`: the smallest hint (IHP Ant.g: `0.16um2`). |

**Status and limits.** Partial.

- A row whose ratio moves with the diode (`area_minus_diode`, `gate_plus_diode`, `diode_reduce`)
  gives no hint, so GF180MCU's ANT.16 rows give none.
- A ratio that no diode clears, such as one above a `diode_max_ratio` table's end value with no
  `diode_credit`, gives no hint.
- The hint assumes the diode joins the net at or below the lowest etch stage. Where the router puts
  it is not checked.
- An `antenna` row's hint should be withheld when the ratio is above the limit that applies once a
  diode is present, such as IHP's Ant.f (500): no diode clears such a gate. GPurify does not yet
  know that limit and prints the hint anyway, so check the paired row before you add the diode.

**Sources.** IHP SG13G2 Layout Rules, section 7.1, rule Ant.g and Note 4;
[SkyWater SKY130 antenna rules](https://skywater-pdk.readthedocs.io/en/main/rules/antenna.html), EGAR;
[US 9,142,556 B2](https://patents.google.com/patent/US9142556B2), column 6; Cadence LEF/DEF 5.8
Language Reference, `ANTENNADIFFAREARATIO PWL`.
