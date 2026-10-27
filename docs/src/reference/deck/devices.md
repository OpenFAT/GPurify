# Devices

A `device` statement tells GPurify how to find one kind of device in the layout: the marker layer
whose shapes are the devices, the model name LVS compares, and the layers of its terminals. LVS
measures every device it finds, and the ERC voltage rules pass voltage through it.

```text
device <kind> <marker> model "<model>" terminals [<layer>, ...] [<value> ...]
```

```text
device mos       ngate model "nfet"      terminals [poly, diff_sd, diff_sd] on_gate_min 1V
device mos       pgate model "pfet"      terminals [poly, diff_sd, diff_sd] on_gate_max 0V
device resistor  rbody model "rpoly"     terminals [poly_c, poly_c] sheet 300ohm
device capacitor cmim  model "cmim"      terminals [met2, met1] area_cap 2fF/um2 fringe_cap 0.2fF/um
device diode     dio   model "dnw"       terminals [diff, nwell]
device bjt       npn   model "npn"       terminals [base, emitter, coll]
device inductor  ind   model "spiral_2n" terminals [met2, met2] inductance 2nH
```

## Kinds and terminals

The terminals are listed in a fixed order for each kind:

| Kind | Terminals, in order |
|---|---|
| `mos` | gate, source, drain, and optionally bulk |
| `bjt` | base, emitter, collector |
| `diode` | anode, cathode |
| `capacitor` | top plate, bottom plate |
| `resistor` | two ends |
| `inductor` | two ends |

LVS lets a transistor's source and drain trade places, and a resistor's or an inductor's two ends.
A diode and a capacitor are polar: a reversed diode is a mismatch, and so is a capacitor with its
plates swapped, unless an [`lvs permute`](lvs-controls.md#interchangeable-pins) line makes them
interchangeable. A bipolar's emitter and collector never trade places.

The model name is what LVS compares against the reference netlist's device. A reference resistor,
capacitor, diode or inductor card that names no model is matched to the deck's one `device` of that
kind. A `mos` row's gate terminal is also where an `antenna` rule connects the gate.

## How a device is recognised

Each shape on the marker layer is one candidate device. A terminal shape belongs to it when the two
share a point, so a source that only abuts the gate marker is under it. Terminal shapes that touch
or overlap are one shape.

![A transistor: a poly strip crosses a diffusion rectangle; the dashed marker ngate is their overlap; the diffusion on either side is the source and drain; W is the marker's extent along the poly, L its extent across](../../diagrams/deck-devices-1.svg)

- **Each terminal position needs a shape of its own.** A source drawn twice with no drain is not a
  transistor with its source and drain shorted: the marker is no device, and LVS reports it as
  `lvs.terminal_net`.
- **Layers repeat in order.** When two positions name one layer (`diff_sd` for both source and
  drain), its shapes fill the positions in the order they were read.
- **The first row wins.** When two `device` rows recognise one marker shape, the row written first
  in the deck takes it.

Write the terminal layers as the deck's own derived layers. The source and drain of a transistor
are `diff not poly`, not `diff`, so that each is a shape of its own beside the gate. Make the
marker the region that is the device, such as `poly and diff and nsdm` for an n-channel gate.

## Values a device states

A device row may end with values that every device of the row stands for. Each is optional, given
once, and only on its own kind:

| Value | Kind | Unit | Meaning |
|---|---|---|---|
| `sheet` | `resistor` | `ohm` (per square) | The body's sheet resistance, for `r` |
| `area_cap` | `capacitor` | `aF/um2`, `fF/um2` | Capacitance per area, for `c` |
| `fringe_cap` | `capacitor` | `aF/um`, `fF/um` | Capacitance per perimeter, for `c` |
| `inductance` | `inductor` | `pH`, `nH`, `uH` | The inductance every device of the row has, as a foundry's fixed inductor cell has one value |
| `on_gate_min` | `mos` | voltage | An n-channel switch: on while its gate can reach this voltage or more |
| `on_gate_max` | `mos` | voltage | A p-channel switch: on while its gate can fall to this voltage or less |
| `fins` | `mos` | a layer | The fin layer: the transistor is sized by its fin count, `nfin` |

### Gate conditions

`on_gate_min` and `on_gate_max` tell the ERC voltage rules when a transistor conducts. A
transistor gives one of the two, or neither, in which case it always conducts. When on, a channel
passes its full voltage range: there is no threshold drop.

The gate's reach is the range its net can take from the supplies in the
[design intent](../design-intent.md), so a switch is on in voltage propagation if its gate can
reach the condition at any time. A gate no supply reaches, such as an input of the cell, may take
any voltage, so its transistor conducts. This follows Calibre PERC's conditional voltage
propagation, as Siemens's white paper 81822 states it.

### FinFETs

A FinFET's size is its fin count, not a width. Name the fin layer with `fins`, and each transistor
of the row is sized by the fin shapes under its marker, touching pieces counted once. Such a
transistor measures no `w`.

```text
device mos NMOS_RVT model "nmos_rvt" terminals [GATE_FET, SD, SD] fins FIN
```

## What LVS measures

LVS measures every device from what is drawn, and compares each value a reference card states,
under the card's name for it, within the [`lvs tolerance`](lvs-controls.md#tolerances) for it.

| Name | Devices | Measured |
|---|---|---|
| `w`, `l` | `mos`, `resistor` | The marker's extent across and along the current. The current runs toward the first source or drain (a resistor's first end). Exact for a straight rectangle; a bent resistor body reads its bounding box. |
| `nf` | `mos` | 1: a marker is one channel, and fingers in parallel add up. |
| `nfin` | `mos` with `fins` | The fin shapes under the marker, touching pieces counted once. Fingers in parallel add up, `m` multiplies it, and it is compared exactly. |
| `area`, `perim` | every kind | The marker's area, less any hole in it, and its perimeter, a hole's edge included. A resistor, capacitor or diode card may also write them `A` and `P`, or the perimeter `pj`. |
| `as`, `ad`, `ps`, `pd` | `mos` | The area and perimeter of the source's and the drain's shape on its terminal layer, the edge along the channel included. A diffusion between two fingers is shared evenly by the transistors it serves, so fingers in parallel add up to it. |
| `ae`, `pe` | `bjt` | The area and perimeter of the emitter's shape on the second terminal layer. |
| `r` | `resistor` with `sheet` | `sheet × l / w` |
| `c` | `capacitor` with `area_cap` or `fringe_cap` | `area_cap × area + fringe_cap × perim`, of the terms given |
| `ind` | `inductor` with `inductance` | The inductance the deck states. A reference `L` card's value is compared as `ind`, never as a length. |

A source, drain or emitter is measured only where it is one shape that no other shape of its
layer touches; drawn in pieces, it is not measured. A value the deck does not give is not
computed, and never taken as zero: a reference card that states it is reported as
`lvs.undeclared_param`. Nothing measures a capacitor's `w` and `l`.

## Example

```text
grid 5nm
layer diff       = gds(65, 20)
layer poly       = gds(66, 20)
layer nsdm       = gds(93, 44)
layer diff_label = gds(65, 5)
layer poly_label = gds(66, 5)

layer ngate   = poly and diff and nsdm
layer diff_sd = diff not poly

connect conductors [diff_sd, poly]
connect touch_within_layer
connect label diff_label names diff_sd
connect label poly_label names poly

device mos ngate model "nfet" terminals [poly, diff_sd, diff_sd]

lvs tolerance default relative 2%
```

The layout draws a 1 µm by 600 nm diffusion crossed by a 150 nm poly strip. The reference states
the transistor's size and its drain:

```text
.subckt INV_N G S D
M1 D G S S nfet W=0.6u L=0.15u ad=0.24p ps=2.1u
.ends
```

```sh
gpurify lvs mos.gds --deck mos.deck --reference mos.sp
```

```text
rules:
  lvs.floating_net: ran, examined 3 shapes, found 0 violations
  lvs.label_conflict: ran, examined 3 shapes, found 0 violations
  lvs.net_seed_conflict: ran, examined 3 shapes, found 0 violations
  lvs.terminal_net: ran, examined 3 shapes, found 0 violations
  lvs.terminal_count: ran, examined 1 shapes, found 0 violations
violations: 0
lvs: Match
...
```

LVS measures `w` as 600 nm across the current and `l` as 150 nm along it. The drain's shape is
400 nm by 600 nm, 0.24 µm², and the source's perimeter is 2 × (450 nm + 600 nm), 2.1 µm.
