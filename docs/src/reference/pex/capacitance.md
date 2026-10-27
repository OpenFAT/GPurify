# Capacitance extraction

GPurify extracts each net's capacitance to the substrate, the coupling capacitance between nets on
one layer and on two layers, and, when the deck describes the silicon, the resistance through the
substrate between the nets that contact it. The capacitances go into the SPEF `*CAP` section and
the DSPF and SPICE `C` cards.

## Capacitance to ground

### PEX-002: Area and fringe capacitance to substrate

**What it catches.** The capacitance from each wire to the substrate below it. It loads every
driver, and it sets the RC delay and the switching power of the net. A long wire on a low metal
layer can carry more capacitance than the gates it drives.

**How GPurify measures it.** Each region of a net (its merged shapes on one layer) gets
`area_cap × A + fringe_cap × P`. Here `A` is the region's area in µm² and `P` its perimeter in µm.
The capacitance sits on the region's node. The substrate is ground.

![A met1 wire 10 µm by 0.14 µm over the substrate, its plate and fringe fields drawn, extracted as one capacitor of 0.859 fF from node a to ground](../../diagrams/pex-002.svg)

**In the deck.**

```text
pex <layer> thickness <length> height <length> sheet <resistance> [dielectric <k>] area_cap <aF/um2> fringe_cap <aF/um>
```

```text
grid 5nm
layer met1 = gds(68, 20)
layer via = gds(68, 44)
layer met2 = gds(69, 20)
connect conductors [met1, met2]
connect via via [met1, met2]
connect label met1 names met1
connect label met2 names met2
pex met1 thickness 360nm height 1376.1nm sheet 0.125ohm dielectric 4.5 area_cap 25.78aF/um2 fringe_cap 40.57aF/um
pex via thickness 270nm height 1736.1nm sheet 4.5ohm dielectric 4.5 area_cap 0aF/um2 fringe_cap 0aF/um
pex met2 thickness 360nm height 2006.1nm sheet 0.125ohm dielectric 4.2 area_cap 17.5aF/um2 fringe_cap 37.76aF/um
extraction rcc coupling_halo 10
```

**Example output.** Nets `a` and `b` are met1 wires 10 µm × 0.14 µm, 0.14 µm apart. Net `c` is a
met2 wire 0.3 µm × 3 µm that crosses over both:

```sh
gpurify pex cross.gds --deck wires.deck --format spef > cross.spef
```

```text
*D_NET a 1.889606
*CONN
*P a B
*CAP
1 a 0.858852
2 a b 1.024556
3 a c 0.006198
...
```

The first `*CAP` line is the ground capacitance: 25.78 aF/µm² × 1.4 µm² plus 40.57 aF/µm × 20.28 µm,
or 0.858852 fF. The `*D_NET` line's total, 1.889606 fF, adds the coupling to `b` and `c`.

**Options.**

| Parameter | Value | Meaning |
|---|---|---|
| `area_cap` | capacitance per area (`aF/um2`) | Plate capacitance to the substrate per µm² of the layer. Zero or more. |
| `fringe_cap` | capacitance per length (`aF/um`) | Fringe capacitance to the substrate per µm of the region's perimeter. Zero or more. |

**Status and limits.** Implemented. The coefficients are the deck's, one pair per layer. A wire
keeps its full area and fringe capacitance to the substrate even where another wire lies between
it and the substrate, so the closed forms count no shielding. That errs towards more capacitance
to ground. A layer at height 0 (a well or a diffusion) is a junction: its `area_cap` and
`fringe_cap` are its junction capacitance. For the field-solved value, see
[PEX-005](accuracy.md#pex-005-field-solver-reference-for-selected-nets).

**Sources.** Weste and Harris, *CMOS VLSI Design*, 4th edition (2011), chapter 6. The example's
coefficients are the
[SkyWater SKY130 parasitic tables](https://github.com/google/skywater-pdk/tree/main/docs/rules/rcx).

## Coupling between nets

### PEX-003: Coupling capacitance

**What it catches.** The capacitance between two nets: side by side on one layer, or one above the
other on two layers. Coupling slows or speeds a switching net, depending on what its neighbour does,
and injects noise (crosstalk) into a quiet one. A timing tool reads it to find signal-integrity
failures.

**How GPurify measures it.** In closed form, two rectangles of different nets on one layer couple
by `ε₀ εr t L / S`. Here `t` is the layer's thickness, `L` the length they face each other, `S` the
gap and `εr` the layer's `dielectric`. Two rectangles couple only when they face each other within
`coupling_halo` thicknesses. Two overlapping rectangles on two layers couple by `ε₀ εr A / d`. Here
`A` is the overlap area, `d` the gap from the top of the lower layer to the bottom of the upper one,
and `εr` the lower layer's `dielectric`. Both are parallel-plate forms, so lateral coupling reads
low.

With `--quasistatic <net>`, GPurify solves the named nets' capacitance from the field instead (see
[PEX-005](accuracy.md#pex-005-field-solver-reference-for-selected-nets)). Their coupling to every
net that was not field-solved stays in closed form.

![Wires a and b on met1, 0.14 µm apart, with c on met2 crossing over them, extracted as a 1.025 fF coupling capacitor between a and b and 6.2 aF capacitors from c to each](../../diagrams/pex-003.svg)

**In the deck.**

```text
pex <layer> thickness <length> height <length> sheet <resistance> dielectric <k> area_cap <aF/um2> fringe_cap <aF/um>
extraction rcc coupling_halo <thicknesses> [coupling_threshold <capacitance>]
```

```text
grid 5nm
layer met1 = gds(68, 20)
layer via = gds(68, 44)
layer met2 = gds(69, 20)
connect conductors [met1, met2]
connect via via [met1, met2]
connect label met1 names met1
connect label met2 names met2
pex met1 thickness 360nm height 1376.1nm sheet 0.125ohm dielectric 4.5 area_cap 25.78aF/um2 fringe_cap 40.57aF/um
pex via thickness 270nm height 1736.1nm sheet 4.5ohm dielectric 4.5 area_cap 0aF/um2 fringe_cap 0aF/um
pex met2 thickness 360nm height 2006.1nm sheet 0.125ohm dielectric 4.2 area_cap 17.5aF/um2 fringe_cap 37.76aF/um
extraction rcc coupling_halo 10
```

**Example output.** The same three nets as in PEX-002:

```sh
gpurify pex cross.gds --deck wires.deck --format spef > cross.spef
```

```text
*D_NET c 0.277362
*CONN
*P c B
*CAP
1 c 0.264966
2 c a 0.006198
3 c b 0.006198
...
```

`a` and `b` face each other over 10 µm across a 0.14 µm gap. In ε = 4.5 with met1 0.36 µm thick,
that is 1.024556 fF, listed under both nets. Net `c` overlaps each of them by 0.3 µm × 0.14 µm,
0.27 µm above met1, which is 6.198 aF each.

**Options.**

| Parameter | Value | Meaning |
|---|---|---|
| `dielectric` | number | Relative permittivity around the layer. A layer without one has no closed-form coupling, and a field solve refuses it. |
| `coupling_halo` | number | How far lateral coupling is looked for, in thicknesses of each layer. Required for every extraction type but `r`. |
| `coupling_threshold` | capacitance | A coupling below this is grounded on both nets. See [PEX-008](output.md#pex-008-reduction-modes). |

**Status and limits.** Partial. The closed forms see one permittivity per layer and count no
fringing between sidewalls and no shielding by a wire in between. Two conductor layers drawn at the
same height, such as a metal and its fill on another datatype, couple sideways as if they were one
layer. The field solve (`--quasistatic`) meshes each interface where the dielectric changes with
height, over a window around the solved nets. It leaves out the polarisation beyond that window,
and it models no conformal dielectric and no dielectric beside a wire that differs from the one
above and below it. Where the dielectric changes with height, its capacitance matrix is
reciprocal only to its discretisation: a solve more than 5% from reciprocal is refused, and any
other is written symmetrised. The substrate is a
grounded plane at height 0. A shape on a layer at height 0 (a well, a diffusion) is a junction in
that plane, so the field reads metal over another net's junction as coupling to ground. Open issue:
[PEX-003: Coupling C (same-layer and cross-layer)](https://github.com/OmarSiwy/GPurify/issues/11).

**Sources.** Weste and Harris, *CMOS VLSI Design*, 4th edition (2011), chapter 6. Nabors and
White, "FastCap: a multipole accelerated 3-D capacitance extraction program", IEEE Transactions on
CAD 10(11), 1991, for the multi-dielectric field solve.

## Substrate

### PEX-013: Substrate network extraction

**What it catches.** The resistance through the silicon between the nets that contact it, such as
substrate taps and well ties, and from each to a grounded backside. Noise injected into the
substrate by one block reaches another through this network. An RF or mixed-signal design needs it
to check isolation.

**How GPurify measures it.** GPurify models the silicon under the drawn die as horizontal layers of
uniform resistivity, from the deck's profile, with insulating sides. Every shape of a net on a port
layer is one contact on the top face, all of that net's shapes at one potential. GPurify solves the
silicon on a graded grid and writes the port admittance as resistors: one between every two port
nets, and one from each to the backside when the backside is grounded.

![Two substrate taps t1 and t2 on a two-layer silicon profile over a grounded backside, extracted as resistors of 1.78 MΩ between t1 and t2 and 47.3 kΩ from each to ground](../../diagrams/pex-013.svg)

**In the deck.**

```text
pex_substrate ports [<layer>, ..] backside grounded|floating profile [(<thickness>, <ohm-cm>), ..]
```

```text
grid 5nm
layer tap = gds(65, 44)
connect conductors [tap]
connect label tap names tap
pex tap thickness 120nm height 206.2nm sheet 197ohm dielectric 3.9 area_cap 0aF/um2 fringe_cap 0aF/um
extraction rcc coupling_halo 10
pex_substrate ports [tap] backside grounded profile [(3um, 10), (300um, 0.01)]
```

**Example output.** Two taps 2 µm square and 10 µm apart, nets `t1` and `t2`:

```sh
gpurify pex taps.gds --deck substrate.deck --format spice > taps.sp
```

```text
.subckt taps t1 t2
R1 t1 0 47260.698418
R2 t1 t1#1 197.000000
R3 t1 t2 1775788.233788
R4 t2 0 47260.698418
R5 t2 t2#1 197.000000
.ends taps
```

Each tap reaches the grounded backside through 47.3 kΩ of the 10 Ω·cm top layer. The two taps
couple through 1.78 MΩ, since the low-resistivity bulk below shunts most of the current to the
backside. `R2` and `R5` are the taps' own sheet resistance. In SPEF, whose `*RES` joins only nodes
of one net, the same values are comments, `// substrate t1:0 t2:0 1775788.233788`.

**Options.**

| Parameter | Value | Meaning |
|---|---|---|
| `ports` | list of layers | Conductor layers whose shapes contact the silicon. Each net's shapes on them are one contact. |
| `backside` | `grounded` or `floating` | A grounded backside is a contact at ground; a floating one carries no current. |
| `profile` | list of (thickness, resistivity) | The silicon's layers from the top down. Resistivity is in Ω·cm, written as a bare number. |

**Status and limits.** Partial. The profile is the deck's, and no open PDK publishes one. Not
modelled: junction and substrate capacitance (a well is a contact, not a doped volume), lateral
doping changes, contact resistance and trench isolation. A grid of more than 1500 lines on an axis
is refused. Open issue:
[PEX-013: Substrate network extraction](https://github.com/OmarSiwy/GPurify/issues/12).

**Sources.** GPurify-specific; substrate extraction is offered by the Synopsys StarRC and Cadence
Quantus datasheets, whose models are not public. The solve is checked against the spreading
resistance of a square contact on a half-space (from Read, *Journal of Computational Physics* 133,
1997, the capacitance of the unit square) with the image series of a slab subtracted, and against
Ohm's law through layers in series.
