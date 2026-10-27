# Latch-up checks

These checks find the layout that lets the parasitic PNP and NPN of a CMOS process turn on as a
thyristor: diffusions too far from their taps, guard rings missing, distant, narrow or on the wrong
rail, and junctions the supplies can forward-bias. Some are purely geometric; the rest read the
[design intent](../design-intent.md) and the voltages GPurify propagates from it.

## Tap distance and tie area

### ERC-D1: Maximum distance to a well or substrate tap

**What it catches.** A diffusion with a point further from the nearest tap than the foundry allows.
The well or substrate under that point connects to its rail only through a long, resistive path. A
small injected current then raises the local potential enough to turn on the parasitic bipolar
transistor and start latch-up.

**How GPurify measures it.** For every polygon of the region layer, GPurify finds the point of the
polygon furthest from the nearest edge of any tap, every point and not only the corners. The
distance is Euclidean. A region drawn with a hole is measured as if the hole were filled, which can
only report more.

![Cross-section of an n-well: an n-tap at the left, a pdiff whose far end is 52 µm from the tap against a 20 µm limit, and the parasitic PNP and well resistance under it](../../diagrams/erc-d1.svg)

**In the deck.**

```text
rule <id> missing_tie(<region>, <tap>; max_distance: <length>)
rule <id> tap_distance(<region>, <tap>) <= <length>
```

The two lines measure the same thing. `missing_tie` runs with `gpurify erc`, `tap_distance` with
`gpurify drc`.

```text
grid 5nm
layer nwell = gds(1, 0)
layer diff = gds(2, 0)
layer tap = gds(6, 0)
layer pdiff = diff and nwell
layer ntap = tap and nwell
rule LU.1 missing_tie(pdiff, ntap; max_distance: 20um)
```

```sh
gpurify erc tap_far.gds --deck tap.deck
```

**Example violation.**

```text
rules:
  LU.1: ran, examined 1 shapes, found 1 violations
violations: 1
  LU.1 error layer pdiff at (55000 nm, 2000 nm) measured 52000 nm against limit 20000 nm on shape 3
...
```

The pdiff runs from 5 µm to 55 µm and its only n-tap ends at 3 µm, so its far corner at (55 µm,
2 µm) is 52 µm from the tap against a 20 µm limit.

**Options.**

| Parameter | Value | Meaning |
|---|---|---|
| `max_distance` | length | The furthest any point of a region polygon may lie from a tap edge. |

**Status and limits.** Implemented. The measured distance is rounded up to the next nanometre, so a
reported value is never at or below the limit. A region with no tap of the tap layer anywhere in the
layout measures 0 taps against 1. Taps on other nets count alike: the check reads geometry, not
which rail the tap is on (see [ERC-D3](#erc-d3-guard-ring-or-well-tied-to-the-correct-rail)).

**Sources.** [GlobalFoundries GF180MCU design manual](https://gf180mcu-pdk.readthedocs.io/en/latest/physical_verification/design_man.html)
rules LU.1 to LU.4; [IHP SG13G2 layout rules](https://github.com/IHP-GmbH/IHP-Open-PDK/tree/main/ihp-sg13g2/libs.doc/doc)
LU.a and LU.b; [ASAP7 design rule manual](https://github.com/The-OpenROAD-Project/asap7_pdk_r1p7/blob/main/docs/asap7_drm_201207a.pdf)
ACTIVE.LUP.1; [ESDA TR18.0-02-20, latch-up EDA](https://www.esda.org/store/standards/product/307/esd-tr18-0-02-20/)
section 3.1.1.

### ERC-D1a: Tap distance set by the space to a neighbouring well

**What it catches.** A diffusion further from its tap than a limit that depends on how close the
opposite-type diffusion sits to the well edge. The closer the two, the stronger the parasitic
thyristor between them, so the foundry tightens the tap distance. GF180MCU LU.1 to LU.4 allow 15 µm
when that space is under 1 µm, 30 µm under 2 µm, and 50 µm from 2 µm.

**How GPurify measures it.** For each region polygon, GPurify looks at every `other` polygon within
`within` of it and takes the least distance from one of those to a `well` polygon. That space picks
the band: below the first `spacing` value the first `max_distance`, and so on. With no `other`
polygon that near, the last band applies. The tap distance is then measured as for
[ERC-D1](#erc-d1-maximum-distance-to-a-well-or-substrate-tap).

![Top view: an ndiff 0.5 µm outside the n-well picks the 15 µm band, and the pdiff's far corner is 22 µm from the n-tap](../../diagrams/erc-d1a.svg)

**In the deck.**

```text
rule <id> conditional_tie(<region>, <tap>, <well>, <other>; within: <length>,
    spacing: [<length>, ..], max_distance: [<length>, ..])
```

```text
grid 5nm
layer nwell = gds(1, 0)
layer diff = gds(2, 0)
layer tap = gds(6, 0)
layer pdiff = diff and nwell
layer ndiff = diff not nwell
layer ntap = tap and nwell
rule LU.4 conditional_tie(pdiff, ntap, nwell, ndiff; within: 50um,
    spacing: [1um, 2um], max_distance: [15um, 30um, 50um])
```

```sh
gpurify erc tap_band.gds --deck band.deck
```

**Example violation.**

```text
rules:
  LU.4: ran, examined 1 shapes, found 1 violations
violations: 1
  LU.4 error layer pdiff at (25000 nm, 2000 nm) measured 22000 nm against limit 15000 nm on shape 4
...
```

The ndiff sits 0.5 µm outside the n-well, under the 1 µm threshold, so the pdiff's band is 15 µm.
Its far corner at (25 µm, 2 µm) is 22 µm from the n-tap. Without the ndiff the limit would be 50 µm
and the pdiff would pass.

**Options.**

| Parameter | Value | Meaning |
|---|---|---|
| `within` | length | How near an `other` polygon must be to the region to set its band. |
| `spacing` | list of lengths, rising | The thresholds between bands. |
| `max_distance` | list of lengths, one more than `spacing` | The tap distance in each band, the last for no near neighbour. |

**Status and limits.** Implemented. The neighbour's space is measured to any `well` polygon, not
only the well the region lies in. That can only pick a tighter band, never a looser one. The
distance is rounded up and an absent tap reads as 0 taps against 1, as for ERC-D1.

**Sources.** [GlobalFoundries GF180MCU design manual](https://gf180mcu-pdk.readthedocs.io/en/latest/physical_verification/design_man.html)
rules LU.1 to LU.4. The shipped `gf180mcu` deck carries all four.

### ERC-D1b: Minimum well tie area

**What it catches.** A well or guard ring whose tap contacts are too small for the channel area
inside it. Each transistor injects substrate current when it switches. Too little contact area
leaves the well resistance high enough for that current to trigger latch-up, even when every point
is near a tap.

**How GPurify measures it.** For every figure of the merged `region` layer, GPurify adds up the
area of `contact` inside it and the area of `channel` inside it, each with overlaps counted once.
The figure fails when the contact area divided by the channel area is below `min_ratio`. A figure
with no channel area is not checked.

![Top view: an n-well with one 0.3 µm tap contact and five gates of 3 µm² each, a ratio of 0.006 against 0.01](../../diagrams/erc-d1b.svg)

**In the deck.**

```text
rule <id> tie_area(<region>, <contact>, <channel>; min_ratio: <fraction>)
```

```text
grid 5nm
layer nwell = gds(1, 0)
layer diff = gds(2, 0)
layer poly = gds(3, 0)
layer cont = gds(4, 0)
layer tap = gds(6, 0)
layer tap_cont = cont and tap and nwell
layer pgate = poly and diff and nwell
rule tie.area tie_area(nwell, tap_cont, pgate; min_ratio: 1%)
```

```sh
gpurify erc tie_area.gds --deck area.deck
```

**Example violation.**

```text
rules:
  tie.area: ran, examined 1 shapes, found 1 violations
violations: 1
  tie.area error layer nwell at (0 nm, 0 nm) measured 0.006 against limit 0.01 on shape 2
...
```

One 0.3 µm × 0.3 µm contact (0.09 µm²) ties five 0.5 µm × 6 µm gates (15 µm²): a ratio of 0.006
against 0.01. The point is the well's first corner.

**Options.**

| Parameter | Value | Meaning |
|---|---|---|
| `min_ratio` | fraction | The least contact area per unit of channel area. For a guard ring, name the ring itself as `channel`. |

**Status and limits.** Implemented. No known limits.

**Sources.** [ESDA TR18.0-02-20, latch-up EDA](https://www.esda.org/store/standards/product/307/esd-tr18-0-02-20/)
Annex A; [GlobalFoundries GF180MCU design manual](https://gf180mcu-pdk.readthedocs.io/en/latest/physical_verification/design_man.html)
rules LU.7, IO.2 and IO.4.

## Guard rings and their rails

### ERC-D2: Guard ring round a pad diffusion

**What it catches.** A diffusion connected to an I/O pad that no guard ring surrounds, whose ring is
too far away, or whose ring is too narrow. A pad sees off-chip overshoot and undershoot, so its
diffusions inject far more current than core devices. A close, wide ring collects that current
before it reaches a neighbouring well.

**How GPurify measures it.** A target lies inside a ring when it sits in a hole of one figure of the
merged ring layer. With `max_space`, GPurify measures the largest gap from the target's bounding box
to the hole's bounding box on any side. With `min_width`, it measures the ring's narrowest width,
as DRC `width` measures it, and reports each narrow ring once. With `pad`, only targets on a net
that also holds a `pad` polygon count.

![Top view: an ndiff under a pad inside a 1 µm n-tap ring whose inner edge is 24.5 µm away, against limits of 15 µm space and 2 µm width](../../diagrams/erc-d2.svg)

**In the deck.**

```text
rule <id> guard_ring(<target>, <ring>; max_space: <length> | none, min_width: <length> | none,
    pad: <layer> | none, near: <layer> | none, within: <length> | none, clear: <layer> | none)
```

The `pad` layer must carry nets: list it in `connect conductors` and join it to the metal under it.

```text
grid 5nm
layer nwell = gds(1, 0)
layer diff = gds(2, 0)
layer cont = gds(4, 0)
layer met1 = gds(5, 0)
layer tap = gds(6, 0)
layer pad = gds(14, 0)
layer ndiff = diff not nwell
layer ntap = tap and nwell
connect conductors [ndiff, met1, pad]
connect touch_within_layer
connect via cont [ndiff, met1]
connect via pad [met1, pad]
rule IO.1 guard_ring(ndiff, ntap; max_space: 15um, min_width: none,
    pad: pad, near: none, within: none, clear: none)
rule IO.2 warning guard_ring(ndiff, ntap; max_space: none, min_width: 2um,
    pad: pad, near: none, within: none, clear: none)
```

```sh
gpurify erc pad_ring.gds --deck ring.deck
```

**Example violation.**

```text
rules:
  IO.1: ran, examined 1 shapes, found 1 violations
  IO.2: ran, examined 1 shapes, found 1 violations
violations: 2
  IO.1 error layer ndiff at (10000 nm, 14000 nm) measured 24500 nm against limit 15000 nm on shape 12
  IO.2 warning layer ntap at (500 nm, 39500 nm) measured 1000 nm against limit 2000 nm on shape 13
...
```

The ndiff ends at 14 µm and the ring's inner edge is at 38.5 µm: a 24.5 µm gap against 15 µm. The
ring itself is 1 µm wide against the recommended 2 µm, reported once at its first corner. A target
in no ring at all measures 0 rings against 1.

**Options.**

| Parameter | Value | Meaning |
|---|---|---|
| `max_space` | length or `none` | The largest gap from the target to the ring's inner edge, on any side. |
| `min_width` | length or `none` | The least width of a ring that surrounds a target. |
| `pad` | layer or `none` | Only targets on a net holding a polygon of this layer are checked. |
| `near`, `within` | layer and length, or `none` | Only targets within `within` of a `near` polygon are checked ([ERC-D7](#erc-d7-native-device-guard-ring)). |
| `clear` | layer or `none` | The ring's hole must hold no area of this layer outside the target ([ERC-D7](#erc-d7-native-device-guard-ring)). |

**Status and limits.** Implemented. The space is measured box to box, which is exact for
rectangular targets and holes and reports more for other shapes. A `pad` layer that no `connect`
statement names puts no polygon on a net, and the row is refused. The shipped `gf180mcu` deck
writes IO.1 to IO.4 but does not yet connect its `pad` layer. The `esd_latchup` check, on the ESD
page, combines a pad's clamp path with a ring's width.

**Sources.** [GlobalFoundries GF180MCU design manual](https://gf180mcu-pdk.readthedocs.io/en/latest/physical_verification/design_man.html)
rules IO.1 to IO.4; [IHP SG13G2 layout rules](https://github.com/IHP-GmbH/IHP-Open-PDK/tree/main/ihp-sg13g2/libs.doc/doc)
section 7.2.1; [ESDA TR18.0-02-20, latch-up EDA](https://www.esda.org/store/standards/product/307/esd-tr18-0-02-20/)
section 3.1.2.

### ERC-D3: Guard ring or well tied to the correct rail

**What it catches.** An n-type ring or tap that is not on the most positive supply, a p-type ring
or tap that is not on ground, and a transistor whose source or drain can forward-bias the junction
to its own well. An n-well below the P+ diffusions in it, or a p-substrate above the N+ in it,
turns on the emitter of a parasitic bipolar transistor directly. A ring on the wrong rail collects
nothing.

**How GPurify measures it.** `guard_ring_bias` reads the net of every ring polygon. With
`power: true` the net must be a declared supply held at the highest voltage of any declared power
supply; with `power: false` it must be a declared ground. `well_bias` compares each listed
transistor's bulk with its source and drain, using the range of voltages each net can reach from
the supplies ([how a voltage reaches a net](voltage.md#erc-f1-static-voltage-propagation)). A PMOS
fails when its source or drain can rise above the lowest voltage of its well; an NMOS when they can
fall below the highest voltage of its substrate.

![Cross-section: an n-well tied to VDD at 1.8 V holds a PMOS whose source is on VDDIO at 3.3 V, so the source can sit 1.5 V above the well](../../diagrams/erc-d3.svg)

**In the deck.**

```text
rule <id> guard_ring_bias(<ring>; power: true | false)
rule <id> well_bias(; pmos: [<model>, ..] | none, nmos: [<model>, ..] | none)
```

`well_bias` needs a bulk terminal on each `device mos` row: the fourth layer, here the n-well, which
must itself be a conductor tied to its tap.

```text
grid 5nm
layer nwell = gds(1, 0)
layer diff = gds(2, 0)
layer poly = gds(3, 0)
layer cont = gds(4, 0)
layer met1 = gds(5, 0)
layer text = gds(5, 1)
layer tap = gds(6, 0)
layer ntap = tap and nwell
layer nwell_tie = tap and nwell
layer psd = (diff not poly) and nwell
layer pgate = poly and diff and nwell
connect conductors [psd, ntap, nwell, poly, met1]
connect touch_within_layer
connect via cont [psd, met1]
connect via cont [ntap, met1]
connect via nwell_tie [ntap, nwell]
connect label text names met1
device mos pgate model "pfet" terminals [poly, psd, psd, nwell]
rule LU.9 guard_ring_bias(ntap; power: true)
rule well.bias well_bias(; pmos: ["pfet"], nmos: none)
```

Both rules read the [design intent](../design-intent.md). This example needs two power supplies in
two domains:

```json
{
  "domains": {
    "core": { "voltage_mv": 1800 },
    "io": { "voltage_mv": 3300 }
  },
  "supplies": [
    { "net": "VDD", "domain": "core", "role": "power" },
    { "net": "VDDIO", "domain": "io", "role": "power" }
  ]
}
```

```sh
gpurify erc well_rail.gds --deck bias.deck --intent io.json
```

**Example violation.**

```text
rules:
  LU.9: ran, examined 1 shapes, found 1 violations
  well.bias: ran, examined 1 shapes, found 1 violations
violations: 2
  LU.9 error layer ntap at (1000 nm, 5000 nm) measured 1800 mV against limit 3300 mV on shape 10
  well.bias error layer pgate at (5400 nm, 5000 nm) measured 1500 mV against limit 0 mV on shape 16
...
```

The n-tap, and with it the well, sits on VDD at 1800 mV while the highest supply is 3300 mV. The
PMOS in that well has its source on VDDIO, so the source can sit 1500 mV above its well, against a
limit of 0 mV.

**Options.**

| Parameter | Value | Meaning |
|---|---|---|
| `power` | `true` or `false` | `true` for an n-type ring (the highest power supply), `false` for a p-type ring (a ground). |
| `pmos` | models or `none` | Transistors whose bulk is an n-well. |
| `nmos` | models or `none` | Transistors whose bulk is the p-substrate or a p-well. |

**Status and limits.** Implemented. "Most positive" is the highest declared power supply of the
whole design, not of the ring's own domain: a core n-well ring on a 1.8 V supply fails beside a
3.3 V I/O supply. A ring on no declared supply measures 0 against 1. `well_bias` skips a transistor
whose bulk, or both of whose source and drain, no supply reaches; it cannot decide those. Both
rules report `skipped` without `--intent`. Only the shipped `sky130` deck connects its wells, so
only it carries `well_bias`.

**Sources.** [GlobalFoundries GF180MCU design manual](https://gf180mcu-pdk.readthedocs.io/en/latest/physical_verification/design_man.html)
rules LU.9, LU.10, IO.1 and IO.3.

### ERC-D4: Guard ring resistance and current under injection

**What it catches.** A guard ring whose metal path to its supply is too resistive, or too narrow,
for the current a latch-up test injects. JEDEC JESD78 forces ±100 mA into I/O pins. A ring that
collects that current through a long or thin strap rises far enough to forward-bias the junctions
it was meant to protect.

**How GPurify measures it.** GPurify forces `current` into each polygon of the ring layer, at the
point of its net nearest the centre of the polygon's bounding box. The current leaves at the ring's
supply: at that supply's `pad` polygons held at 0 V, or with none at its feed point. GPurify solves
the resistive network of the ring's net, using each conductor's and cut's `pex` sheet resistance.
It reports the path resistance (the ring's rise over `current`) above `max_resistance`, and each
wire segment carrying more than `max_density` times its width.

![Top view: 100 mA forced into a met1 ring flows through a via and a 1 µm met2 strap to VDD's pad, 4.18 Ω against 2 Ω](../../diagrams/erc-d4.svg)

**In the deck.**

```text
rule <id> esd_path(<pad>, <ring>; clamps: none, current: <current>, clamp_resistance: <resistance>,
    max_resistance: <resistance> | none, clamp_it2: none, max_density: <current per width> | none,
    max_current_per_cut: <current> | none, max_voltage: <voltage> | none, min_width: <length> | none,
    clamp_voltage: none)
```

This is the ESD discharge-path check with a second layer: the current enters at the ring instead of
at the pad. With `clamps: none` it flows through the ring's own net only.

```text
grid 5nm
layer met1 = gds(5, 0)
layer text = gds(5, 1)
layer met2 = gds(12, 0)
layer via = gds(13, 0)
layer pad = gds(14, 0)
layer padv = gds(17, 0)
connect conductors [met1, met2, pad]
connect touch_within_layer
connect via via [met1, met2]
connect via padv [met2, pad]
connect label text names met1
pex met1 thickness 360nm height 1400nm sheet 0.125ohm dielectric 3.9 area_cap 25aF/um2 fringe_cap 40aF/um
pex via thickness 400nm height 1760nm sheet 1ohm dielectric 3.9 area_cap 0aF/um2 fringe_cap 0aF/um
pex met2 thickness 360nm height 2160nm sheet 0.125ohm dielectric 3.9 area_cap 17aF/um2 fringe_cap 37aF/um
pex padv thickness 500nm height 2520nm sheet 0.5ohm dielectric 3.9 area_cap 0aF/um2 fringe_cap 0aF/um
pex pad thickness 1000nm height 3020nm sheet 0.01ohm dielectric 3.9 area_cap 10aF/um2 fringe_cap 20aF/um
rule LU.inject esd_path(pad, met1; clamps: none, current: 100mA, clamp_resistance: 1ohm,
    max_resistance: 2ohm, clamp_it2: none, max_density: 80mA/um, max_current_per_cut: none,
    max_voltage: none, min_width: none, clamp_voltage: none)
```

The ring's net must be a declared supply in the [design intent](../design-intent.md):

```json
{
  "domains": { "core": { "voltage_mv": 1800 } },
  "supplies": [
    { "net": "VDD", "domain": "core", "role": "power" }
  ]
}
```

```sh
gpurify erc ring_inject.gds --deck inject.deck --intent vdd.json
```

**Example violation.**

```text
rules:
  LU.inject: ran, examined 1 shapes, found 3 violations
violations: 3
  LU.inject error layer met1 at (0 nm, 12000 nm) measured 4.183541666666667 ohm against limit 2 ohm on shape 0 and shape 3
  LU.inject error layer met2 at (11500 nm, 6000 nm) measured 100000 uA against limit 80000 uA on shape 2 and shape 2
  LU.inject error layer met2 at (22000 nm, 6000 nm) measured 100000 uA against limit 80000 uA on shape 2 and shape 2
...
```

The path from the ring to the pad is 4.18 Ω against 2 Ω: a short run of the ring, one 1 Ω via,
21 squares of met2 at 0.125 Ω and the 0.5 Ω pad cut. The 1 µm met2 strap carries the whole 100 mA against 80 mA, reported
once per segment.

**Options.**

| Parameter | Value | Meaning |
|---|---|---|
| `current` | current | The injected current; JESD78 uses 100 mA. |
| `clamp_resistance` | resistance | Required by the syntax; unused with `clamps: none`. |
| `max_resistance` | resistance or `none` | The largest path resistance from the ring to its supply's pins. |
| `max_density` | current per width or `none` | The most current a wire may carry per unit of width. |
| `max_current_per_cut` | current or `none` | The most current one via cut may carry. |
| `max_voltage` | voltage or `none` | The highest the ring may rise. |
| `min_width` | length or `none` | The narrowest wire that may carry the injected current. |

The ESD page describes `clamps`, `clamp_it2` and `clamp_voltage`, which a ring injection leaves at
`none`.

**Status and limits.** Implemented. The injection is a DC current into the ring's metal, leaving at
its supply's pins. The share of the injected carriers that the substrate collects is not modelled.
A ring whose net is no declared supply is not solved; `guard_ring_bias` reports it. Every conductor
and cut on the path needs a `pex` row with a sheet resistance, or the row is refused. The rule
reports `skipped` without `--intent`.

**Sources.** [ESDA TR18.0-02-20, latch-up EDA](https://www.esda.org/store/standards/product/307/esd-tr18-0-02-20/)
section 2.3; [JEDEC JESD78F.02](https://www.jedec.org/standards-documents/docs/jesd-78b) Table 1;
Siemens Calibre PERC public material.

## Injectors and their victims

### ERC-D5: Voltage-aware aggressor and victim

**What it catches.** A diffusion near a junction that can inject carriers, held to a tighter tap
distance than elsewhere. An aggressor is a diffusion on a pad, or one the supplies can
forward-bias against its own well or substrate: a P+ that can rise above its n-well, or an N+ that
can fall below its p-substrate. The victim within reach collects those carriers, and only a nearby
tap keeps it from triggering.

**How GPurify measures it.** GPurify first selects the aggressors: polygons of the `aggressor`
layer, on a pad net when `pad` is given. With `bias` and `forward`, it keeps an aggressor only when
its net's voltage range can pass the range of the `bias` polygon it lies in
([how a voltage reaches a net](voltage.md#erc-f1-static-voltage-propagation)). Every `region`
polygon within `within` of a kept aggressor is then held to `max_distance` from a tap, measured as
for [ERC-D1](#erc-d1-maximum-distance-to-a-well-or-substrate-tap).

![Cross-section: a pdiff on VDDIO 3.3 V in an n-well on VDD 1.8 V injects; the ndiff victim beside it is 18 µm from its p-tap against 5 µm](../../diagrams/erc-d5.svg)

**In the deck.**

```text
rule <id> latchup_victim(<aggressor>, <region>, <tap>; within: <length>, max_distance: <length>,
    pad: <layer> | none, bias: <layer> | none, forward: above | below | none)
```

```text
grid 5nm
layer nwell = gds(1, 0)
layer diff = gds(2, 0)
layer cont = gds(4, 0)
layer met1 = gds(5, 0)
layer text = gds(5, 1)
layer tap = gds(6, 0)
layer pdiff = diff and nwell
layer ndiff = diff not nwell
layer ntap = tap and nwell
layer ptap = tap not nwell
layer nwell_tie = tap and nwell
connect conductors [pdiff, ndiff, ntap, nwell, met1]
connect touch_within_layer
connect via cont [pdiff, met1]
connect via cont [ntap, met1]
connect via nwell_tie [ntap, nwell]
connect label text names met1
rule LU.victim latchup_victim(pdiff, ndiff, ptap; within: 15um, max_distance: 5um,
    pad: none, bias: nwell, forward: above)
```

The `bias` layer must be a conductor tied to its tap, so that it has a net and a voltage. The
example uses the same [design intent](../design-intent.md) as ERC-D3: VDD at 1800 mV and VDDIO at
3300 mV.

```sh
gpurify erc victim.gds --deck victim.deck --intent io.json
```

**Example violation.**

```text
rules:
  LU.victim: ran, examined 1 shapes, found 1 violations
violations: 1
  LU.victim error layer ndiff at (12000 nm, 8000 nm) measured 18000 nm against limit 5000 nm on shape 10
...
```

The pdiff sits on VDDIO (3300 mV) in an n-well on VDD (1800 mV), so it can forward-bias and is an
aggressor. The ndiff 5 µm away is within reach, and its corner at (12 µm, 8 µm) is 18 µm from the
p-tap against 5 µm. Had the pdiff been on VDD, it could not rise above its well and nothing would
be checked.

**Options.**

| Parameter | Value | Meaning |
|---|---|---|
| `within` | length | How near a region polygon must be to an aggressor to be a victim. |
| `max_distance` | length | The tap distance a victim is held to. |
| `pad` | layer or `none` | Only aggressors on a net holding a polygon of this layer count. |
| `bias` | layer or `none` | The well or substrate layer an aggressor lies in. |
| `forward` | `above`, `below` or `none` | `above`: the aggressor can rise above its `bias` polygon's lowest voltage (P+ in an n-well). `below`: it can fall below the highest (N+ in the substrate). |

**Status and limits.** Partial. Over- and undershoot from off-chip are not modelled from voltages:
a pad diffusion is selected by `pad` alone. The whole victim polygon is held to `max_distance`,
not only its part within `within` of the aggressor; the foundry rule does not say which. An
aggressor or `bias` polygon no supply reaches cannot be judged and is not selected. A row with
`bias` reports `skipped` without `--intent`. As in ERC-D2, a `pad` layer must be connected.

**Sources.** [ESDA TR18.0-02-20, latch-up EDA](https://www.esda.org/store/standards/product/307/esd-tr18-0-02-20/)
section 2.2.3; [GlobalFoundries GF180MCU design manual](https://gf180mcu-pdk.readthedocs.io/en/latest/physical_verification/design_man.html)
section 14.3.2, rules IO.1 (b) and IO.3 (b); Siemens Calibre PERC public material;
[Bailey, "CVC: Circuit Validity Checker", WOSET 2020](https://woset-workshop.github.io/PDFs/2020/a05.pdf).

## Rings for special devices

### ERC-D6: Double guard ring round high-voltage devices

**What it catches.** A high-voltage device not surrounded by both rings the foundry asks for: an
inner P+ substrate ring on ground and an outer N+ ring in an n-well on the highest supply.
High-voltage devices inject more current, so the two rings collect electrons and holes on their way
to neighbouring low-voltage pockets.

**How GPurify measures it.** No dedicated check. Write two `guard_ring` rows, one per ring, and two
`guard_ring_bias` rows for their rails. Each `guard_ring` row needs the target in a hole of that
ring ([ERC-D2](#erc-d2-guard-ring-round-a-pad-diffusion)); each `guard_ring_bias` row needs the
ring on its rail ([ERC-D3](#erc-d3-guard-ring-or-well-tied-to-the-correct-rail)).

![Top view: a high-voltage diffusion inside a p-tap ring on VSS, with no n-tap ring around it](../../diagrams/erc-d6.svg)

**In the deck.**

```text
rule <id> guard_ring(<hv target>, <p ring>; ...)
rule <id> guard_ring(<hv target>, <n ring>; ...)
rule <id> guard_ring_bias(<p ring>; power: false)
rule <id> guard_ring_bias(<n ring>; power: true)
```

```text
grid 5nm
layer nwell = gds(1, 0)
layer diff = gds(2, 0)
layer cont = gds(4, 0)
layer met1 = gds(5, 0)
layer text = gds(5, 1)
layer tap = gds(6, 0)
layer hv = gds(9, 0)
layer hvdiff = diff and hv
layer ntap = tap and nwell
layer ptap = tap not nwell
connect conductors [ntap, ptap, met1]
connect touch_within_layer
connect via cont [ntap, met1]
connect via cont [ptap, met1]
connect label text names met1
rule HV.ring.p guard_ring(hvdiff, ptap; max_space: none, min_width: none,
    pad: none, near: none, within: none, clear: none)
rule HV.ring.n guard_ring(hvdiff, ntap; max_space: none, min_width: none,
    pad: none, near: none, within: none, clear: none)
rule HV.bias.p guard_ring_bias(ptap; power: false)
rule HV.bias.n guard_ring_bias(ntap; power: true)
```

The [design intent](../design-intent.md) declares the rails:

```json
{
  "domains": { "core": { "voltage_mv": 5000 } },
  "supplies": [
    { "net": "VDD", "domain": "core", "role": "power" },
    { "net": "VSS", "domain": "core", "role": "ground" }
  ]
}
```

```sh
gpurify erc hv_ring.gds --deck hv.deck --intent core.json
```

**Example violation.**

```text
rules:
  HV.ring.p: ran, examined 1 shapes, found 0 violations
  HV.ring.n: ran, examined 1 shapes, found 1 violations
  HV.bias.p: ran, examined 1 shapes, found 0 violations
  HV.bias.n: ran, examined 0 shapes, found 0 violations
violations: 1
  HV.ring.n error layer hvdiff at (10000 nm, 14000 nm) measured 0 against limit 1 on shape 8
...
```

The p-tap ring on VSS surrounds the high-voltage diffusion and passes. No n-tap ring surrounds it,
so `HV.ring.n` measures 0 rings against 1.

**Options.** The options of `guard_ring` ([ERC-D2](#erc-d2-guard-ring-round-a-pad-diffusion)) and
`guard_ring_bias` ([ERC-D3](#erc-d3-guard-ring-or-well-tied-to-the-correct-rail)).

**Status and limits.** Expressible. The rows check each ring on its own: nothing checks that the
p-ring lies inside the n-ring. The spacing rules between isolated high-voltage pockets in
TR18.0-02 section 3.3 are not written.

**Sources.** [GlobalFoundries GF180MCU design manual](https://gf180mcu-pdk.readthedocs.io/en/latest/physical_verification/design_man.html)
section 14.3.4; [ESDA TR18.0-02-20, latch-up EDA](https://www.esda.org/store/standards/product/307/esd-tr18-0-02-20/)
section 3.3.

### ERC-D7: Native device guard ring

**What it catches.** A native (zero-threshold) transistor near an n-well that no substrate guard
ring surrounds, or whose ring also encloses other N+ diffusion or n-well. A native device has no
well implant under it, so the substrate there is lightly doped and easily disturbed. GF180MCU LU.5
asks for a P+ ring round it with nothing of the other type in between.

**How GPurify measures it.** This is `guard_ring` with `near` and `clear`. Only targets within
`within` of a `near` polygon are checked. With `clear`, GPurify takes the hole round the target,
removes the target and the ring, and counts the `clear` figures that still have area there.

![Top view: a native device in a p-tap ring that also holds an ndiff; the n-well 31 µm away is within 50 µm](../../diagrams/erc-d7.svg)

**In the deck.**

```text
rule <id> guard_ring(<target>, <ring>; max_space: none, min_width: none, pad: none,
    near: <layer>, within: <length>, clear: <layer>)
```

```text
grid 5nm
layer nwell = gds(1, 0)
layer diff = gds(2, 0)
layer tap = gds(6, 0)
layer nat = gds(10, 0)
layer natdiff = diff and nat
layer ndiff = (diff not nwell) not nat
layer ptap = tap not nwell
layer between = ndiff or nwell
rule LU.5 guard_ring(natdiff, ptap; max_space: none, min_width: none,
    pad: none, near: nwell, within: 50um, clear: between)
```

```sh
gpurify erc native.gds --deck native.deck
```

**Example violation.**

```text
rules:
  LU.5: ran, examined 1 shapes, found 1 violations
violations: 1
  LU.5 error layer natdiff at (5000 nm, 9000 nm) measured 1 against limit 0 on shape 8
...
```

The native device is 31 µm from the n-well, within 50 µm, so it is checked. Its p-tap ring also
holds one ndiff, so it measures 1 figure between ring and device against 0.

**Options.** As for `guard_ring` ([ERC-D2](#erc-d2-guard-ring-round-a-pad-diffusion)).

**Status and limits.** Implemented. The hole is read as its bounding box less the ring. When the
same ring has another hole inside that box, its contents count too, which can only report more.

**Sources.** [GlobalFoundries GF180MCU design manual](https://gf180mcu-pdk.readthedocs.io/en/latest/physical_verification/design_man.html)
rule LU.5. The shipped `gf180mcu` deck carries it.

### ERC-D8: Forward-biased diode marked and ringed

**What it catches.** A diode that the supplies can forward-bias but that no latch-up marker
covers. A forward-biased junction injects minority carriers into the substrate. GF180MCU section
14.3.3 asks for such diodes to be marked (its Latchup_MK) so that their guard rings can be checked.

**How GPurify measures it.** For each diode of a listed model, GPurify takes the highest voltage its
anode can reach and the lowest its cathode can reach
([how a voltage reaches a net](voltage.md#erc-f1-static-voltage-propagation)). When the anode can
sit above the cathode, the diode must lie entirely inside one `marker` polygon. Check the rings
round the marked diodes with `guard_ring`, the marker layer as the target.

![Cross-section: a P+ to n-well diode with its anode on VDDIO 3.3 V and its well on VDD 1.8 V, forward by 1.5 V, with no latch-up marker](../../diagrams/erc-d8.svg)

**In the deck.**

```text
rule <id> forward_diode(<marker>; models: [<model>, ..])
```

```text
grid 5nm
layer nwell = gds(1, 0)
layer diff = gds(2, 0)
layer cont = gds(4, 0)
layer met1 = gds(5, 0)
layer text = gds(5, 1)
layer tap = gds(6, 0)
layer latchup_mk = gds(10, 0)
layer dio = gds(18, 0)
layer pdiff = diff and nwell
layer ntap = tap and nwell
layer nwell_tie = tap and nwell
connect conductors [pdiff, ntap, nwell, met1]
connect touch_within_layer
connect via cont [pdiff, met1]
connect via cont [ntap, met1]
connect via nwell_tie [ntap, nwell]
connect label text names met1
device diode dio model "pdiode" terminals [pdiff, nwell]
rule LU.mark forward_diode(latchup_mk; models: ["pdiode"])
```

The example uses the [design intent](../design-intent.md) of ERC-D3: VDD at 1800 mV and VDDIO at
3300 mV.

```sh
gpurify erc fwd_diode.gds --deck diode.deck --intent io.json
```

**Example violation.**

```text
rules:
  LU.mark: ran, examined 1 shapes, found 1 violations
violations: 1
  LU.mark error layer dio at (3500 nm, 2500 nm) measured 1500 mV against limit 0 mV on shape 3
...
```

The anode is on VDDIO and the n-well cathode on VDD, so the diode can be forward-biased by 1500 mV
against 0 mV, and no `latchup_mk` polygon covers it.

**Options.**

| Parameter | Value | Meaning |
|---|---|---|
| `models` | models | The diode models to check. |

**Status and limits.** Implemented. Voltages reach each terminal through transistor channels,
resistors and diodes without any drop, so a diode can read as forward-biased when the circuit never
drives it that way. That errs toward a false violation. A diode with a terminal no supply reaches
cannot be decided and is not examined. The rule reports `skipped` without `--intent`.

**Sources.** [GlobalFoundries GF180MCU design manual](https://gf180mcu-pdk.readthedocs.io/en/latest/physical_verification/design_man.html)
sections 14.3.2 and 14.3.3.

## Wells shared by transistors

### ERC-D9: PMOS or NMOS devices sharing one well

**What it catches.** A transistor whose well is fed from a different supply than the transistor
itself. When transistors share a well, each one's source should reach the well's own net. A
transistor fed from another supply can forward-bias the shared well's junctions whenever the two
supplies differ, which US patent 5,638,286 names as a latch-up path.

**How GPurify measures it.** For each transistor of a listed model with a bulk net, GPurify accepts
any one of three connections: a channel end on the bulk net; with `resistors: true`, one resistor
from a channel end to the bulk net; or a chain of channels of other transistors on the same bulk
net leading to it. A transistor with none of these fails. Source and drain count alike, as a layout
cannot tell them apart. The check reads connectivity only and needs no design intent.

![Schematic: two PMOS share an n-well tied to VDD; P1's source is on VDD, P2's on VDD2 with no channel path to the well's net](../../diagrams/erc-d9.svg)

**In the deck.**

```text
rule <id> well_sharing(; models: [<model>, ..], resistors: true | false)
```

```text
grid 5nm
layer nwell = gds(1, 0)
layer diff = gds(2, 0)
layer poly = gds(3, 0)
layer cont = gds(4, 0)
layer met1 = gds(5, 0)
layer text = gds(5, 1)
layer tap = gds(6, 0)
layer ntap = tap and nwell
layer nwell_tie = tap and nwell
layer psd = (diff not poly) and nwell
layer pgate = poly and diff and nwell
connect conductors [psd, ntap, nwell, poly, met1]
connect touch_within_layer
connect via cont [psd, met1]
connect via cont [ntap, met1]
connect via nwell_tie [ntap, nwell]
connect label text names met1
device mos pgate model "pfet" terminals [poly, psd, psd, nwell]
rule LU.share well_sharing(; models: ["pfet"], resistors: false)
```

```sh
gpurify erc well_share.gds --deck share.deck
```

**Example violation.**

```text
rules:
  LU.share: ran, examined 2 shapes, found 1 violations
violations: 1
  LU.share error layer pgate at (10400 nm, 5000 nm) measured 0 against limit 1 on shape 26
...
```

Both PMOS share an n-well tied to VDD. The first has its source on VDD and passes. The second, at
x = 10.4 µm, has its source on VDD2 and no chain of channels back to VDD, so it measures 0
connections against 1.

**Options.**

| Parameter | Value | Meaning |
|---|---|---|
| `models` | models | The transistor models that sit in a shared well. Each `device mos` row needs a bulk terminal. |
| `resistors` | `true` or `false` | Whether one resistor from a channel end to the bulk net counts as a connection. |

**Status and limits.** Implemented. Which models sit in a well, and whether a resistor counts, are
the deck's to say. Calibre PERC's own "PMOS/NMOS devices sharing the same well" check is described
only in public summaries; GPurify follows the patent.

**Sources.** [US patent 5,638,286](https://patents.google.com/patent/US5638286A);
[Hogan and Medhat (Siemens), "Circuit Reliability Verification For Automotive Electronics", 2021](https://semiengineering.com/circuit-reliability-verification-for-automotive-electronics/).
