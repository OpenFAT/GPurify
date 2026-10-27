# Device recognition and parameters

These checks cover what LVS measures on each device the deck recognises, and how those values are
compared with the reference netlist's cards. A value outside the tolerance is reported as
`lvs.parameter_mismatch`, and a device of the wrong flavour as `lvs.model_mismatch`.

## Transistors and passives

### LVS-060: MOS width, length and diffusions

**What it catches.** A transistor drawn at another width, length or finger count than the schematic
states, or with source and drain diffusions of another size. Width and length set the drive current
and the matching of a pair. The diffusion areas and perimeters set the junction capacitance that a
post-layout simulation reads.

**How GPurify measures it.** Each shape on the gate marker is one transistor. `w` is the marker's
extent across the current and `l` its extent along it, read from the marker's bounding box. `nf` is
1 for each drawn channel, and fingers merged in parallel add up. `as`, `ad`, `ps` and `pd` are the
area and perimeter of the source and drain shapes on their terminal layer, the edge along the gate
included, as BSIM4 counts them with `perMod=1`. A diffusion shared by two fingers is split evenly
between them. `area` and `perim` are the marker's own. GPurify compares only the parameters the
reference card states.

![Reference card W 1 µm, L 0.18 µm beside the drawn nfet, W 1 µm across the gate and L 0.15 µm along it; L is marked as the mismatch](../../diagrams/lvs-060.svg)

**In the deck.**

```text
device mos <marker> model "<model>" terminals [<gate>, <source/drain>, <source/drain>, [<bulk>]]
```

```text
device mos ngate model "nfet" terminals [poly_c, nsd, nsd]
```

This line is already in [the example deck](README.md#the-example-deck). See
[Devices](../deck/devices.md) for the statement.

**Example violation.** The layout is one n-channel transistor, 1 µm wide and 0.15 µm long, with
0.7 µm of diffusion on each side. The reference card states a 0.18 µm length and the drain's
area and perimeter:

```text
.subckt mos G S D
M1 D G S S nfet W=1u L=0.18u AD=0.7p PS=3.4u
.ends
```

```sh
gpurify lvs mos.gds --deck example.deck --reference mos_l.spice
```

```text
violations: 1
...
lvs: Mismatch([ParameterMismatch { layout_device: 0, ref_device: 0, param: "l", layout_value: 1.4999999999999997e-7, ref_value: 1.8e-7 }])
```

The drawn length, 0.15 µm, is 17% short of the card's 0.18 µm. The drain's 0.7 µm² and
3.4 µm agree, so they are not reported.

**Status and limits.** Partial. `w` and `l` come from the marker's bounding box, so a bent or
L-shaped gate reads its box. A source or drain drawn in more than one touching piece is not
measured. `nf` counts drawn channels only: a card's `nf` agrees with the number of fingers merged
into the device. When the deck lists no bulk terminal, the reference card's bulk is dropped.

**Sources.** KLayout LVS MOS3 and MOS4 device extractors
(<https://www.klayout.de/doc/about/lvs_ref.html>); Netgen
(<http://opencircuitdesign.com/netgen/reference.html>); SkyWater SKY130 Netgen setup; BSIM4
(<https://bsim.berkeley.edu/models/bsim4/>).

### LVS-061: Resistor value, width and length

**What it catches.** A resistor drawn at another width or length than the schematic states, so its
resistance differs. A wrong bias or feedback resistor shifts a circuit's operating point and gain.

**How GPurify measures it.** `w` and `l` are the resistor body's extent across and along the
current, read from the marker's bounding box. With a `sheet` resistance on the `device` line,
\\[ r = \mathit{sheet} \cdot \frac{l}{w} \\]
where \\( l \\) and \\( w \\) are the body's length and width. A 300 Ω sheet over a body 5 µm long
and 0.5 µm wide gives 300 Ω × 10 = 3 kΩ. A card's positional value (`R1 a b 1k rpoly`) is read as
`r`. A card that names no model is the deck's one resistor.

![Reference card r 2.5 kΩ beside the drawn poly resistor, l 5 µm and w 0.5 µm under rpm, giving 3 kΩ; r is marked as the mismatch](../../diagrams/lvs-061.svg)

**In the deck.**

```text
device resistor <marker> model "<model>" terminals [<end>, <end>] [sheet <resistance>]
```

```text
device resistor rbody model "rpoly" terminals [poly_c, poly_c] sheet 300ohm
```

This line is already in [the example deck](README.md#the-example-deck). See
[Devices](../deck/devices.md) for the statement.

**Example violation.** The layout is one poly resistor, 0.5 µm wide and 5 µm long. The reference
states 2.5 kΩ:

```text
.subckt res A B
R1 A B rpoly r=2.5k w=0.5u l=5u
.ends
```

```sh
gpurify lvs res.gds --deck example.deck --reference res.spice
```

```text
violations: 1
...
lvs: Mismatch([ParameterMismatch { layout_device: 0, ref_device: 0, param: "r", layout_value: 2999.9999999999995, ref_value: 2500.0 }])
```

The drawn resistor is 3 kΩ against the card's 2.5 kΩ; its `w` and `l` agree.

**Options.**

| Parameter | Value | Meaning |
|---|---|---|
| `sheet` | resistance per square | The body's sheet resistance. Without it, `r` is not measured, and a card that states `r` is reported as `lvs.undeclared_param`. |

**Status and limits.** Partial. A bent body reads its bounding box, so its `w`, `l` and `r` are
wrong. Resistors in series merge only under `lvs topology relaxed` (see
[Netlist reduction](reduction.md)).

**Sources.** KLayout LVS resistor extractor (<https://www.klayout.de/doc/about/lvs_ref.html>);
Magic resistor extraction.

### LVS-062: Capacitor value, area and perimeter

**What it catches.** A capacitor drawn at another size than the schematic states. A wrong capacitor
moves a filter's corner, a loop's stability margin or a sampling network's settling.

**How GPurify measures it.** `area` and `perim` are the marker's area and perimeter, a hole's edge
included. With `area_cap` and `fringe_cap` on the `device` line,
\\[ c = \mathit{area\\_cap} \cdot \mathit{area} + \mathit{fringe\\_cap} \cdot \mathit{perim} \\]
of the terms given. A 5 µm by 5 µm plate at 2 fF/µm² gives 50 fF. A card's `A` and `P` are read as
`area` and `perim`. A card's positional value is read as `c`, and a card that names no model
is the deck's one capacitor.

![Reference card c 40 fF beside the drawn 5 µm by 5 µm MiM capacitor, 2 fF/µm² giving 50 fF; c is marked as the mismatch](../../diagrams/lvs-062.svg)

**In the deck.**

```text
device capacitor <marker> model "<model>" terminals [<top>, <bottom>] [area_cap <c/area>] [fringe_cap <c/length>]
```

```text
device capacitor capm model "cmim" terminals [met2, met1] area_cap 2fF/um2
```

This line is already in [the example deck](README.md#the-example-deck). See
[Devices](../deck/devices.md) for the statement.

**Example violation.** The layout is one MiM capacitor, 5 µm by 5 µm. The reference states 40 fF:

```text
.subckt cap T B
C1 T B cmim c=40f
.ends
```

```sh
gpurify lvs cap.gds --deck example.deck --reference cap.spice
```

```text
violations: 1
...
lvs: Mismatch([ParameterMismatch { layout_device: 0, ref_device: 0, param: "c", layout_value: 4.999999999999999e-14, ref_value: 4.0000000000000006e-14 }])
```

The drawn plate gives 50 fF against the card's 40 fF.

**Options.**

| Parameter | Value | Meaning |
|---|---|---|
| `area_cap` | capacitance per area | The capacitance of 1 µm² of the marker. |
| `fringe_cap` | capacitance per length | The capacitance of 1 µm of the marker's edge. |

**Status and limits.** Partial. A capacitor has no `w` or `l`. Without `area_cap` or `fringe_cap`,
`c` is not measured, and a card that states it is reported as `lvs.undeclared_param`.

**Sources.** KLayout LVS capacitor extractor (<https://www.klayout.de/doc/about/lvs_ref.html>);
Magic capacitor extraction.

### LVS-063: Diode area and perimeter

**What it catches.** A diode drawn at another size than the schematic states, or wired the other
way round. A diode's area sets its leakage and its current capacity, as in an ESD or
temperature-sensing diode.

**How GPurify measures it.** `area` is the marker's area with any hole taken out. `perim` is the
length of every edge, a hole's included. A card's `A`, `P` and `pj` are read as `area` and `perim`.
Anode and cathode are compared as such, so a reversed diode is a mismatch. A card that names no
model is the deck's one diode.

![Reference card area 3 µm² beside the drawn 2 µm by 2 µm n diode under dmark, area 4 µm²; area is marked as the mismatch](../../diagrams/lvs-063.svg)

**In the deck.**

```text
device diode <marker> model "<model>" terminals [<anode>, <cathode>]
```

```text
device diode ndiode model "dn" terminals [psub, nsd]
```

This line is already in [the example deck](README.md#the-example-deck). See
[Devices](../deck/devices.md) for the statement.

**Example violation.** The layout is one n diode, 2 µm by 2 µm, with a p tap for its anode. The
reference states 3 µm²:

```text
.subckt dio K VSS
D1 VSS K dn area=3p perim=8u
.ends
```

```sh
gpurify lvs diode.gds --deck example.deck --reference diode.spice
```

```text
violations: 1
...
lvs: Mismatch([ParameterMismatch { layout_device: 0, ref_device: 0, param: "area", layout_value: 3.999999999999998e-12, ref_value: 3e-12 }])
```

The drawn diode is 4 µm² against the card's 3 µm²; its 8 µm perimeter agrees.

> [!WARNING]
> A diode whose two nets touch nothing else pairs by structure either way round. Here a card
> `D1 K VSS dn` reports `Match`. Add `lvs ports_by_name` to hold each port to its label, and the
> reversed diode is reported.

**Status and limits.** Implemented. No known limits.

**Sources.** KLayout LVS diode extractor (<https://www.klayout.de/doc/about/lvs_ref.html>).

### LVS-064: Bipolar emitter area and perimeter

**What it catches.** A bipolar transistor drawn with another emitter size than the schematic
states. The emitter area sets the collector current at a given base voltage, so a bandgap
reference built from mismatched emitters gives the wrong voltage.

**How GPurify measures it.** `ae` and `pe` are the area and perimeter of the emitter's shape on
the second terminal layer. `area` and `perim` are the marker's own. Base, emitter and collector are
compared as such, and the emitter and collector never trade places.

![Reference card ae 1.5 µm² beside the drawn pnp, a 1 µm by 1 µm emitter in the n well; ae is marked as the mismatch](../../diagrams/lvs-064.svg)

**In the deck.**

```text
device bjt <marker> model "<model>" terminals [<base>, <emitter>, <collector>]
```

```text
device bjt pnp model "pnp" terminals [nwell, psd, psub]
```

This line is already in [the example deck](README.md#the-example-deck). See
[Devices](../deck/devices.md) for the statement.

**Example violation.** The layout is one vertical pnp with a 1 µm by 1 µm emitter. The reference
states 1.5 µm²:

```text
.subckt bjt B E C
Q1 C B E pnp ae=1.5p pe=4u
.ends
```

```sh
gpurify lvs bjt.gds --deck example.deck --reference bjt.spice
```

```text
violations: 1
...
lvs: Mismatch([ParameterMismatch { layout_device: 0, ref_device: 0, param: "ae", layout_value: 9.999999999999996e-13, ref_value: 1.5e-12 }])
```

The drawn emitter is 1 µm² against the card's 1.5 µm²; its 4 µm perimeter agrees.

**Status and limits.** Partial. The emitter count `ne` is not measured, and a bipolar with several
emitters is one device. An emitter drawn in more than one touching piece is not measured. The
shipped `sky130` deck recognises no bipolar.

**Sources.** KLayout LVS BJT3 and BJT4 device extractors
(<https://www.klayout.de/doc/about/lvs_ref.html>).

### LVS-065: Inductor value

**What it catches.** An inductor cell of another value than the schematic states, or one placed
where the schematic has none. A wrong inductor detunes an oscillator or a matching network.

**How GPurify measures it.** Each shape on the marker is one inductor with two interchangeable
ends. Its `ind` is the `inductance` that the `device` line states, the same for every device of
the line, as a foundry's fixed inductor cell has one value. A reference `L` card's positional value
or `l=` is read as `ind`, never as a length. In parallel, inductors count as `m`; under
`lvs topology relaxed`, they combine harmonically in parallel and add in series.

![Reference card 3 nH beside the drawn inductor marker between two met1 pads, whose deck value is 2 nH; ind is marked as the mismatch](../../diagrams/lvs-065.svg)

**In the deck.**

```text
device inductor <marker> model "<model>" terminals [<end>, <end>] inductance <inductance>
```

```text
device inductor indm model "ind" terminals [met1, met1] inductance 2nH
```

This line is already in [the example deck](README.md#the-example-deck). See
[Devices](../deck/devices.md) for the statement.

**Example violation.** The layout is one inductor marker between two met1 pads. The reference
states 3 nH:

```text
.subckt coil A B
L1 A B 3n ind
.ends
```

```sh
gpurify lvs ind.gds --deck example.deck --reference coil.spice
```

```text
violations: 1
...
lvs: Mismatch([ParameterMismatch { layout_device: 0, ref_device: 0, param: "ind", layout_value: 2e-9, ref_value: 3.0000000000000004e-9 }])
```

The deck's 2 nH differs from the card's 3 nH.

**Options.**

| Parameter | Value | Meaning |
|---|---|---|
| `inductance` | inductance | The value of every inductor the line recognises. |

**Status and limits.** Partial. GPurify does not compute an inductance from a spiral's drawn
geometry, and it does not measure turns, track width, spacing or diameter. The value comes from the
deck, and no public PDK deck states one.

**Sources.** KLayout LVS inductor device class (<https://www.klayout.de/doc/about/lvs_ref.html>);
IHP SG13G2 layout rules, section 6.12; Netgen `parallel` and `series` properties
(<http://opencircuitdesign.com/netgen/reference.html>).

## Flavours, cell devices and limits

### LVS-066: Device flavour by implant marker

**What it catches.** A transistor drawn with the wrong threshold implant: a high-Vt device where
the schematic asks for a regular one, or the reverse. Topology and size are right, but the
threshold voltage, leakage and speed are not.

**How GPurify measures it.** A flavour is a `device` line of its own, with a marker that includes
the implant: `ngate and hvtp` for the high-Vt transistor. The plain flavour's marker excludes it:
`ngate not hvtp`. Each gate then belongs to exactly one model, and a model swap is reported as
`lvs.model_mismatch` (see [Comparison checks](compare.md#lvs-013-paired-device-with-a-different-model)).
If the plain line does not exclude the implant, a high-Vt gate is two devices, one of each model.

![Reference card M1 nfet beside the drawn transistor with the hvtp implant over its gate, recognised as nfet_hvt; the model is marked as the mismatch](../../diagrams/lvs-066.svg)

**In the deck.** No statement of its own. Write one marker layer and one `device` line per flavour:

```text
layer <flavour marker> = <gate> and <implant>
layer <plain marker> = <gate> not <implant>
```

```text
layer hvtp = gds(78, 44)
layer ngate_hvt = ngate and hvtp
layer ngate_svt = ngate not hvtp
device mos ngate_svt model "nfet" terminals [poly_c, nsd, nsd]
device mos ngate_hvt model "nfet_hvt" terminals [poly_c, nsd, nsd]
```

These lines replace the `device mos ngate` line of [the example deck](README.md#the-example-deck).
The shipped `sky130` and `asap7` decks recognise their threshold flavours this way.

**Example violation.** The layout is one n-channel transistor with the high-Vt implant drawn over
its gate. The reference card asks for the regular model:

```text
.subckt mos G S D
M1 D G S S nfet W=1u L=0.15u
.ends
```

```sh
gpurify lvs hvt.gds --deck hvt.deck --reference mos.spice
```

```text
violations: 1
...
lvs: Mismatch([ModelMismatch { layout_device: 0, ref_device: 0, layout_model: "nfet_hvt", ref_model: "nfet" }])
```

The drawn gate is `nfet_hvt`, against the card's `nfet`. The same layout without the implant
matches.

**Status and limits.** Expressible. No known limits.

**Sources.** GF180MCU design manual, Appendix A; IHP SG13G2 LVS decks; SkyWater SKY130 device
details (<https://skywater-pdk.readthedocs.io/en/main/rules/device-details.html>).

### LVS-067: Subcircuit-modelled devices

**What it catches.** A device whose PDK model is a subcircuit, written in the schematic as an `X`
call: a resistor or a fixed cell such as a VPP capacitor or an ESD clamp. Read as an ordinary
subcircuit, its body would be flattened into devices the layout never draws, and the comparison
would fail on every such device.

**How GPurify measures it.** An `X` call whose subcircuit name is a model a `device` line names is
that device, even where the netlist defines a subcircuit of that name. The subcircuit's body is not
read, and it is never taken as the top. The call's parameters are compared as a card's are. A fixed
cell recognised by its name is a black box instead, compared by its pins (see
[Equivalence, swappable pins and black boxes](equivalence.md)).

![Reference XR1 calling rpoly, r 2.5 kΩ, with the rpoly subcircuit not read, beside the drawn rpoly resistor of 3 kΩ; r is marked](../../diagrams/lvs-067.svg)

**In the deck.** Nothing to write in the deck beyond the model's `device` line. Run LVS with a
reference netlist.

**Example violation.** The layout is the poly resistor of [LVS-061](#lvs-061-resistor-value-width-and-length).
The reference defines an `rpoly` subcircuit, as a PDK library does, and calls it:

```text
.subckt rpoly a b
.ends
.subckt res A B
XR1 A B rpoly w=0.5u l=5u r=2.5k
.ends
```

```sh
gpurify lvs res.gds --deck example.deck --reference xres.spice
```

```text
violations: 1
...
lvs: Mismatch([ParameterMismatch { layout_device: 0, ref_device: 0, param: "r", layout_value: 2999.9999999999995, ref_value: 2500.0 }])
```

`XR1` is compared as an `rpoly` resistor: the drawn 3 kΩ against the call's 2.5 kΩ.

**Status and limits.** Partial. A fixed cell recognised by its name has no parameters compared. A
Spectre instance of a defined subcircuit is not read as a device model. GPurify does not recognise
a subcircuit by the topology of its drawn devices. See
[issue 10](https://github.com/OmarSiwy/GPurify/issues/10).

**Sources.** Magic `subcircuit` and `rsubcircuit` device extraction; KLayout SPICE reader
`wants_subcircuit` (<https://www.klayout.de/doc/about/lvs_ref.html>); IHP SG13G2 LVS decks.

### LVS-068: Device count and parameter range limits

**What it catches.** A device drawn outside the sizes its model is valid for, and more or fewer
devices of a model than the foundry allows. A transistor below the model's minimum width simulates
without error but is not characterised. IHP SG13G2 recommends a maximum number of `npn13G2`
emitters on a chip.

**How GPurify measures it.** These checks read only the layout's devices, and the comparison's
verdict does not depend on them. `lvs range` holds every layout device of the model to bounds on a measured parameter; a
value at a bound is legal. A device out of range is reported as `lvs.param_range` on its marker. A
device whose parameter was not measured makes the rule refused. `lvs count` holds the number of the
model's layout devices to bounds, reported as `lvs.device_count`. Over the maximum, the row sits on
the first device past it; under the minimum, on the model's first device.

![Two drawn nfets, W 1 µm and W 3 µm: the first is marked below a 2 µm minimum width, the second as the device past a count of 1](../../diagrams/lvs-068.svg)

**In the deck.**

```text
lvs range "<model>" <param> [>= <min>] [<= <max>]
lvs count "<model>" [>= <min>] [<= <max>]
```

```text
lvs range "nfet" w >= 2um
lvs count "nfet" <= 1
```

Added to [the example deck](README.md#the-example-deck). See
[LVS controls](../deck/lvs-controls.md).

**Example violation.** The layout is two n-channel transistors, 1 µm and 3 µm wide, and the
reference states both:

```text
.subckt two G S D D2
M1 D G S S nfet W=1u L=0.15u
M2 D2 G S S nfet W=3u L=0.15u
.ends
```

```sh
gpurify lvs two.gds --deck limits.deck --reference two.spice
```

```text
rules:
...
  lvs.param_range: ran, examined 2 shapes, found 1 violations
  lvs.device_count: ran, examined 1 shapes, found 1 violations
violations: 2
  lvs.param_range error layer ngate at (700 nm, 1000 nm) measured 1000 nm against limit 2000 nm on shape 52
  lvs.device_count error layer ngate at (3450 nm, 3000 nm) measured 2 against limit 1 on shape 53
lvs: Match
```

The 1 µm transistor's gate at (700 nm, 1000 nm) is under the 2 µm minimum. The second gate, at
(3450 nm, 3000 nm), is the device past the count of 1. The circuits still match.

**Options.**

| Parameter | Value | Meaning |
|---|---|---|
| `>=` | length, area or count | The smallest legal value. |
| `<=` | length, area or count | The largest legal value. |

**Status and limits.** Implemented. `lvs range` takes `w`, `l`, `perim`, `ps`, `pd`, `pe`, `area`,
`as`, `ad`, `ae`, `nf` and `nfin`. A bipolar with several emitters counts once, since a device is
one marker.

**Sources.** IHP SG13G2 layout rules, `npn13G2.bR`; GF180MCU design manual, Appendix A; Magic
device parameter limits.

## Layout-dependent effects and fins

### LVS-074: Layout-dependent effect parameters

**What it catches.** A transistor whose distance to the edge of its active area, or to the edge of a
well, differs from what a post-layout netlist states. Shallow-trench stress and well proximity
shift a transistor's threshold and mobility, so two transistors of one size placed differently do
not match.

**How GPurify measures it.** `sa` and `sb` are the distances from the gate's two edges across the
channel to the ends of the active area `od`. Where that end is not straight, GPurify takes BSIM4's
effective distance, the average of \\( 1/(SA + L/2) \\) over the gate's width. The two are compared
as a pair, smaller first, since BSIM4's stress model reads only their inverse sum. With `well`,
GPurify computes `sca`, `scb` and `scc` from the median distances between each gate edge and the
first well edge beyond it, by the closed forms of Silvaco's application note. A distance past
`max` reads as `max`.

![Reference card sa 0.5 µm and sb 0.7 µm beside the drawn nfet, 0.7 µm of diffusion on each side of the gate; sa is marked as the mismatch](../../diagrams/lvs-074.svg)

**In the deck.**

```text
lvs lde "<model>" od <layer> max <length> [well <layer> scref <length>]
```

```text
lvs lde "nfet" od diff max 10um
```

Added to [the example deck](README.md#the-example-deck). See
[LVS controls](../deck/lvs-controls.md).

**Example violation.** The layout is the transistor of
[LVS-060](#lvs-060-mos-width-length-and-diffusions), with 0.7 µm of diffusion on each side of the
gate. The reference states 0.5 µm on one side:

```text
.subckt mos G S D
M1 D G S S nfet W=1u L=0.15u sa=0.5u sb=0.7u
.ends
```

```sh
gpurify lvs mos.gds --deck lde.deck --reference mos_lde.spice
```

```text
violations: 1
...
lvs: Mismatch([ParameterMismatch { layout_device: 0, ref_device: 0, param: "sa", layout_value: 6.999999999999999e-7, ref_value: 5e-7 }])
```

The drawn transistor's smaller distance is 0.7 µm, against the card's 0.5 µm. Without the `lvs lde`
line, the card's `sa` and `sb` are reported as `lvs.undeclared_param`.

**Options.**

| Parameter | Value | Meaning |
|---|---|---|
| `od` | layer | The active area that `sa` and `sb` are measured to. Required. |
| `max` | length | The largest distance measured; a farther edge reads as this. Required. |
| `well` | layer | The well that `sca`, `scb` and `scc` are measured to. Needs `scref`. |
| `scref` | length | BSIM4's reference distance for the well-proximity integrals. Needs `well`. |

**Status and limits.** Partial. `sd`, the spacing between fingers of one instance, is not measured,
since each device is one channel. A gate that is not one rectangle inside the active area is not
measured. Holes in the active area or the well are read as solid. The layers, `max` and `scref`
come from the deck, and no open PDK deck states them.

**Sources.** BSIM4, layout-dependent parasitics and stress effect model
(<https://bsim.berkeley.edu/models/bsim4/>); Silvaco, "Well Proximity and STI Stress Effect
Parameters Extraction in SmartDRC/LVS" (2022).

### LVS-076: FinFET size by fin count

**What it catches.** A FinFET drawn with another number of fins than the schematic states. A
FinFET's width is quantised to whole fins, so the fin count is its size, and a missing fin changes
the drive current by a whole step.

**How GPurify measures it.** With `fins` on the `device` line, each transistor is sized by the
shapes of the fin layer under its marker, touching pieces counted once, as `nfin`. Such a
transistor measures no `w`. Fingers merged in parallel add up their fins, `m` multiplies them, and
`nfin` is compared exactly.

![Reference card nfin 4 beside the drawn n-channel side of INVx2, two gates over three fins each, merged in parallel to nfin 6; nfin is marked](../../diagrams/lvs-076.svg)

**In the deck.**

```text
device mos <marker> model "<model>" terminals [<gate>, <source/drain>, <source/drain>] fins <fin layer>
```

```text
device mos NMOS_RVT model "nmos_rvt" terminals [GATE_FET, SD, SD] fins FIN
```

This line is from the shipped `asap7` deck, which sizes all eight of its transistor models this
way and leaves the schematic's `w` out of the comparison. See [Devices](../deck/devices.md).

**Example violation.** The layout is the ASAP7 cell `INVx2_ASAP7_75t_R`, whose n-channel side is
two fingers of three fins. The reference is its CDL with the n-channel `nfin` changed to 4:

```text
.SUBCKT INVx2_ASAP7_75t_R A VDD VSS Y
MM0 Y A VSS VSS nmos_rvt w=162.00n l=20n nfin=4
MM1 Y A VDD VDD pmos_rvt w=162.00n l=20n nfin=6
.ENDS
```

```sh
gpurify lvs INVx2_ASAP7_75t_R.gds --deck asap7 --reference INVx2_nfin4.cdl
```

```text
violations: 1
...
lvs merges:
  layout parallel: 2 devices of nmos_rvt (0, 1) are one
  layout parallel: 2 devices of pmos_rvt (2, 3) are one
lvs: Mismatch([ParameterMismatch { layout_device: 0, ref_device: 0, param: "nfin", layout_value: 6.0, ref_value: 4.0 }])
```

The two n-channel fingers merge into one transistor of 6 fins, against the card's 4. With the
cell's own CDL, `nfin=6`, the cell matches.

**Options.**

| Parameter | Value | Meaning |
|---|---|---|
| `fins` | layer | The fin layer whose shapes under the marker give `nfin`. |

**Status and limits.** Implemented. No known limits.

**Sources.** ASAP7 predictive PDK (<https://github.com/The-OpenROAD-Project/asap7>);
`asap7sc7p5t_28` standard-cell CDL; BSIM-CMG `NFIN` (<https://bsim.berkeley.edu/models/bsimcmg/>).
