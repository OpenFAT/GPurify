# Parasitic extraction

The parasitic statements describe the metal stack that `gpurify pex` extracts resistance and
capacitance from: one `pex` line per conducting layer, and optional lines for temperature, process
corners, the output's type, metal fill, through-silicon vias, the substrate and the capacitance
inside a transistor. What each extraction computes is on the [PEX checks](../pex/README.md) page.

```text
pex <layer> thickness <len> height <len> sheet <res> [dielectric <k>] area_cap <c/area> fringe_cap <c/len> [tc1 </K> tc2 </K2>]
temperature <T> nominal <T0>
corner <name> <layer> <key> <value> ...
extraction r|c|cc|rc|rcc [coupling_threshold <cap>] [coupling_halo <ratio>]
pex_fill <layer> floating|grounded|ignored
pex_device "<model>" gate_contact_cap <c/len> gate_diffusion_cap <c/len>
pex_tsv <cut layer> length <len> liner <len> liner_k <k>
pex_substrate ports [<layer>, ...] backside grounded|floating profile [(<len>, <ohm·cm>), ...]
```

## The stack

```text
pex met1 thickness 360nm height 1376nm sheet 0.125ohm dielectric 3.9 area_cap 25.8aF/um2 fringe_cap 40.5aF/um
pex via1 thickness 270nm height 1736nm sheet 4.5ohm dielectric 3.9 area_cap 0aF/um2 fringe_cap 0aF/um
pex met2 thickness 360nm height 2006nm sheet 0.125ohm dielectric 3.9 area_cap 16.9aF/um2 fringe_cap 37.6aF/um
```

One line per layer, its keys in any order, each once:

| Key | Unit | Meaning |
|---|---|---|
| `thickness` | length | The layer's thickness. Positive. |
| `height` | length | The height of its bottom above the substrate. |
| `sheet` | resistance | On a conductor, the sheet resistance in Ω per square. On a via cut layer, the resistance of one cut. |
| `dielectric` | bare number | The relative permittivity of the dielectric the layer sits in. Optional; positive when stated. |
| `area_cap` | capacitance per area | Capacitance to the substrate per area. |
| `fringe_cap` | capacitance per length | Capacitance to the substrate per length of edge. |
| `tc1`, `tc2` | `/K`, `/K2` | Temperature coefficients of `sheet`, given together, and only with a `temperature` line. |

Every key but `dielectric`, `tc1` and `tc2` is required. A value is one a process can have:
`thickness` positive, a stated `dielectric` positive, a temperature coefficient of either sign, the
rest zero or more. A negative value, or a `dielectric` of 0, is an error at the value. These
lengths describe the stack, so they are not held to the grid.

A zero means the deck does not state that value. Every conductor and via layer that carries a net
needs a positive `sheet`: without one, PEX is refused, naming the layer, rather than reading it as
a perfect wire. A `connect global` layer needs no line.

A line with no `dielectric` gives no closed-form coupling for its layer, and above the substrate it
is a layer the field solve (`--quasistatic`) refuses. This is how the `asap7` deck says it
extracts no lateral coupling.

A layer at height 0, a well or a diffusion, is a junction in the substrate. Its `area_cap` and
`fringe_cap` are its junction capacitance, which a field solve adds in closed form rather than
solving, so it needs no dielectric.

The dielectrics make a layered stack for the field solve. Each line's dielectric fills the stack
from its `height` up to the next line's height; the lowest reaches down to the substrate and the
highest up without end. Two lines at one height must state the same dielectric, or the field solve
is refused naming the layer.

## Temperature

```text
temperature <operating> nominal <nominal>
```

```text
temperature 85C nominal 30C
pex met1 thickness 360nm height 1376nm sheet 0.125ohm dielectric 3.9 area_cap 25.8aF/um2 fringe_cap 40.5aF/um tc1 3.179e-3/K tc2 3.094e-7/K2
```

`temperature` says the run is signed off at the operating temperature, and that every `sheet` is
the value at the nominal one. Write each in `K` or `C`, above absolute zero, at most once. Each
row's resistance is read at the operating temperature \\( T \\) as

\\[ R(T) = R(T_0) \left(1 + \mathit{tc1} (T - T_0) + \mathit{tc2} (T - T_0)^2\right) \\]

where \\( T_0 \\) is the nominal temperature. This is the ngspice resistor model's law, and the
coefficients are the ones PDKs publish: the example is SkyWater's met1 (`tc1rm1`, `tc2rm1` at
`tnom = 30`). At 85 °C it scales met1's 0.125 Ω per square by \\( 1 + 0.003179 \cdot 55 +
3.094 \times 10^{-7} \cdot 55^2 = 1.1758 \\), to 0.147 Ω per square.

With a `temperature` line, every `pex` row needs `tc1` and `tc2`; write `tc1 0/K tc2 0/K2` for a
resistance that does not vary. Without one, no row may give them. A coefficient may be negative,
but not so far that a resistance reaches zero at the operating temperature.

Extraction, the power grid and `lib` read the resistance at the operating temperature, and the
electromigration and reliability rules derate to it. A deck without a `temperature` line reads
every `sheet` as written; with no `temperature_c` in the [design intent](../design-intent.md)
either, those rules are refused. Only resistance moves with temperature.

## Process corners

```text
corner <name> <layer> <key> <value> ...
```

```text
corner cmax met1 thickness 396nm sheet 0.11ohm area_cap 28.4aF/um2 fringe_cap 44.6aF/um
corner cmin met1 thickness 324nm sheet 0.14ohm
```

A process corner is the stack at the edge of the process window. A `corner` line gives some of one
layer's `pex` values at a named corner, in the keys and units of a `pex` line and within the same
bounds. Every value it does not give is the nominal row's. A corner names each layer at most once,
states at least one value, and varies only a layer that has a `pex` line.

PEX extracts the nominal stack and every corner, the same nets the same way. SPEF writes each value
as the `min:typ:max` triplet of IEEE 1481: the smallest value at any corner or the nominal, the
nominal, and the largest. DSPF, which has no triplets, is the nominal stack's.

Every corner is at the deck's one `temperature`. A corner's `sheet` is the value at the nominal
temperature, read at the operating one by the corner line's `tc1` and `tc2` if it gives them (both,
or neither), else by the row's.

## Extraction type

```text
extraction <type> [coupling_threshold <capacitance>] [coupling_halo <ratio>]
```

```text
extraction rcc coupling_threshold 0.1fF coupling_halo 10
```

At most one line. The type says which parasitics PEX writes, in Calibre's names:

| Type | Writes |
|---|---|
| `rcc` | Resistance, capacitance to ground and coupling capacitance: everything |
| `rc` | Resistance and capacitance to ground; every coupling is grounded |
| `r` | Resistance only, no capacitance |
| `cc` | Capacitance only, one node per net, with the coupling between nets |
| `c` | Capacitance to ground only, one node per net, every coupling grounded |

To ground a coupling capacitance is to put the same capacitance from each of its two nets to
ground, so every net keeps its total. A field-solved net's inductance stays wherever its
resistance does.

`coupling_halo` is how far apart two shapes still couple, in thicknesses of the layer: with
`coupling_halo 10`, met1 shapes 360 nm thick couple up to 3.6 µm apart. It is positive, and every
type but `r` needs it: without it PEX is refused, since no lateral reach is everyone's. Every
shipped deck states `coupling_halo 10`.

`coupling_threshold` grounds every coupling below it, as OpenROAD's
`extract_parasitics -coupling_threshold` does. It is zero or more, and a positive threshold needs a
type that keeps coupling (`cc` or `rcc`).

With `extraction cc coupling_halo 10` and the stack above, the
[tutorial layout](../../tutorials/first-deck.md) extracts to one node per net:

```sh
gpurify pex two_metal.gds --deck pexcc.deck --format spef
```

```text
*D_NET A 0.388703
*CONN
*P A B
*CAP
1 A:0 0.302630
2 A:0 B:0 0.086073
*RES
*INDUC
*END
...
```

Net A has 0.389 fF in total, of which 0.086 fF couples to net B. With `extraction c`, that
coupling is grounded and net A's single capacitance is the same 0.389 fF.

## Metal fill

```text
pex_fill <layer> floating|grounded|ignored
```

```text
layer met1_fill = gds(10, 28)
connect conductors [met1, met1_fill, met2]
pex met1_fill thickness 360nm height 1376nm sheet 0.125ohm dielectric 3.9 area_cap 25.8aF/um2 fringe_cap 40.5aF/um
pex_fill met1_fill floating
```

`pex_fill` says how PEX treats metal fill: a net drawn only on that conductor layer is a fill
piece, not a signal.

- `floating` leaves each piece floating, so a net's coupling through it is in series with the
  piece's other capacitances. Two nets coupled to a piece by \\( c_1 \\) and \\( c_2 \\), the piece
  to ground by \\( c_g \\), couple by \\( c_1 c_2 / (c_1 + c_2 + c_g) \\). Pieces coupled to each
  other are eliminated together.
- `grounded` ties each piece to ground, so a net's coupling to it is capacitance to ground.
- `ignored` leaves the fill out.

Either way the fill's own nets are gone from the output. The layer is a conductor with a `pex`
line, stated once. Which treatment a foundry signs off with is its own; no open deck states one.

## Device-region capacitance

```text
pex_device "<model>" gate_contact_cap <c/len> gate_diffusion_cap <c/len>
```

```text
pex_device "nfet" gate_contact_cap 0.3aF/um gate_diffusion_cap 0.2aF/um
```

`pex_device` gives a transistor model's capacitance inside the device that its SPICE model leaves
to extraction: from the gate to the source and drain contacts, and from the gate to the diffusion
beside it, each per µm of gate width. PEX adds \\( (\mathit{gate\_contact\_cap} +
\mathit{gate\_diffusion\_cap}) \cdot W \\) from the gate's net to the source's, and again to the
drain's; a net the gate is on gets nothing. Both values are required, zero or more. The model
needs a `device mos` statement, and is stated once. The values come from the foundry's device
cross-section, which no open PDK publishes.

## Through-silicon vias

```text
pex_tsv <cut layer> length <len> liner <len> liner_k <k>
```

```text
connect via tsv [met1, bsm]
pex tsv thickness 100nm height 0nm sheet 0.02ohm area_cap 0aF/um2 fringe_cap 0aF/um
pex_tsv tsv length 50um liner 200nm liner_k 3.9
```

`pex_tsv` says a via cut layer is a through-silicon via. Each cut is a copper cylinder through the
silicon, of the radius of the circle with the cut's drawn area, inside an oxide liner. PEX adds the
liner's capacitance to the via's net,

\\[ C = \frac{2 \pi \varepsilon_0 k l}{\ln((r + t) / r)} \\]

where \\( k \\) is `liner_k`, \\( l \\) the `length`, \\( t \\) the `liner` thickness and \\( r \\)
the cut's radius (Katti et al., IEEE Transactions on Electron Devices, 2010). The cut's resistance
is the `pex` row's per cut. All three values are required and positive, and the layer is a
`connect via` cut layer, stated once. No open PDK has a TSV, so the values are the deck's.

## Substrate network

```text
pex_substrate ports [<layer>, ...] backside grounded|floating profile [(<thickness>, <resistivity>), ...]
```

```text
pex_substrate ports [ptap] backside grounded profile [(3um, 10), (300um, 0.01)]
```

`pex_substrate` asks PEX for the resistance through the silicon between the nets that contact it.
The profile lists the silicon's layers from the top down, each a thickness and a resistivity in
Ω·cm as a bare number, uniform across the die. The backside is a grounded contact, or carries no
current. Every shape on a port layer is a contact on the silicon's top face, and all of one net's
shapes are one contact.

PEX writes, between every two port nets, the resistance that couples them, and from each to a
grounded backside its resistance there: a DSPF `R` card (to `0` for the backside), and a
`// substrate <node> <node | 0> <ohm>` comment in SPEF, whose resistance section cannot join two
nets. The port layers are conductors. Every key is required, every value positive, and the line is
stated once. No open PDK states its substrate profile, so it is the deck's. See
[issue 12](https://github.com/OpenFAT/GPurify/issues/12).
