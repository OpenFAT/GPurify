# Accuracy and field solving

GPurify extracts every net in closed form from the deck's parasitic stack, and field-solves the nets
you name for a reference value. The entries on this page cover that field solve, the process
corners and temperature the stack is read at, and the device, fill and through-silicon via effects
the deck adds.

## Field solving

### PEX-005: Field solver reference for selected nets

**What it catches.** The error of the closed forms on a net that matters: a clock, a sensitive
analog node, a matched pair. The closed forms treat lateral coupling as a parallel plate and ignore
shielding, so on narrow, tall, closely spaced wires they misjudge how the capacitance splits between
ground and the neighbours. A field solve gives the number a sign-off extractor's reference mode
gives.

**How GPurify measures it.** With `--quasistatic <net>`, GPurify solves the named nets from the
field instead of the closed forms. Everything else in the run stays in closed form.

| Quantity | Closed form, every net | Field solve, nets named with `--quasistatic` |
|---|---|---|
| Resistance | `sheet × L / W` per region | Filaments, as FastHenry, at 1 MHz |
| Capacitance to ground | `area_cap × A + fringe_cap × P` | Boundary elements on every face, as FastCap; the substrate is a grounded plane |
| Coupling between two solved nets | Parallel plate, side by side or overlapping | From the same solve's capacitance matrix |
| Coupling to a net not solved | Parallel plate | Parallel plate, unchanged |
| Inductance | None | Self and mutual, from the filament solve |

The capacitance solve meshes every face of the solved nets' shapes, and every interface where the
dielectric changes with height, over a window around them. The panel size is the smallest length
the stack states, coarsened until the mesh fits 1,048,576 panels. Each solve runs until its relative
residual is below 1e-10, or GPurify refuses the run. A shape on a layer at height 0 (a well or a
diffusion) is a junction: it keeps its closed-form capacitance beside the field-solved metal.

![Met1 wires a and b in cross-section and their network: 0.859 fF closed form or 0.542 fF field-solved to ground, 1.025 fF or 1.543 fF between them](../../diagrams/pex-005.svg)

**In the deck.** Nothing to write beyond the parasitic stack: every layer a solved net uses above
the substrate needs a positive `thickness` and a `dielectric`. Run with `--quasistatic <net>` once
for each net.

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
met2 wire 0.3 µm × 3 µm that crosses over both. In closed form:

```sh
gpurify pex cross.gds --deck wires.deck --format spice > closed.sp
```

```text
.subckt cross a b c
C1 a 0 0.858852f
R1 a a#1 8.928571
C2 a b 1.024556f
C3 a c 0.006198f
...
```

Field-solving `a` and `b`:

```sh
gpurify pex cross.gds --deck wires.deck --quasistatic a --quasistatic b --format spice > field.sp
```

```text
.subckt cross a b c
C1 a 0 0.542366f
...
C2 a b 1.542564f
...
C3 a c 0.006198f
...
```

The field moves a third of `a`'s ground capacitance to `b`: 0.542 fF to ground and 1.543 fF to `b`,
against 0.859 fF and 1.025 fF in closed form. The total grows from 1.890 fF to 2.091 fF, because
the parallel plate leaves out the fringe between the two sidewalls. The coupling to `c` stays the
closed form's 6.2 aF, since `c` was not solved. To compare two such files net by net, see
[PEX-009](output.md#pex-009-pex-netlist-diff-and-qualification).

A name that labels no net, or a layer the field cannot mesh, is refused before any solve:

```text
  pex: refused, no extracted net is named zz, so it cannot be field solved
```

```text
  pex: refused, layer met2: no pex row gives this layer a positive thickness and permittivity, so it cannot be meshed
```

**Status and limits.** Implemented. Measured against published values:

- A 1 µm cube over a grounded plane reads 1.8% under its published capacitance at 2 panels a side
  and 0.014% under at 32. Each refinement raises the value.
- A plate whose bottom face lies on a dielectric interface matches two dielectric layers in series
  in closed form, within 2%.
- A single straight bar matches Grover's self inductance within 5%. Two parallel bars match
  Grover's mutual inductance within 0.1%.
- A right-angle bend reads 0.62 squares at its corner, against Hall's 0.559 for the exact current
  path and 1 square for the centre line.

A differential against FastCap and FastHenry themselves is not part of this release's checks. The
solve leaves out the polarisation beyond its window, and it models no conformal dielectric and no
dielectric beside a wire that differs from the one above and below. Where the dielectric changes
with height, the matrix is reciprocal only to its discretisation: a solve more than 5% from
reciprocal is refused, and any other is written symmetrised. Resistance and inductance are solved
at 1 MHz only, without skin or proximity effect (see
[PEX-004](inductance.md#pex-004-partial-self-and-mutual-inductance)). The solve's cost grows with
the square of the panel count, so name the nets you need rather than every net.

**Sources.** Nabors and White, "FastCap: a multipole accelerated 3-D capacitance extraction
program", IEEE Transactions on CAD 10(11), 1991. Kamon, Tsuk and White, "FastHenry: a
multipole-accelerated 3-D inductance extraction program", IEEE Transactions on Microwave Theory and
Techniques 42(9), 1994. Read, Journal of Computational Physics 133, 1997, and Hwang,
Mascagni and Given, 2004, for the capacitance of the unit cube. Grover, *Inductance Calculations* (1946). Hall,
"Resistance calculations for thin film patterns", Thin Solid Films 1(4), 1967.

## Process variation

### PEX-006: Multi-corner extraction

**What it catches.** The spread of each parasitic across the process window. A path that meets
timing at nominal fails with the thickest, most capacitive metal, or the thinnest, most
resistive, when its slack is smaller than the spread. Sign-off reads the extraction at the corners, not only at nominal.

**How GPurify measures it.** Each `corner` line gives some of one layer's `pex` values at a named
corner. Every value it does not give is the nominal row's. GPurify extracts the nominal stack and
every corner in one run, the same nets the same way, `--quasistatic` included. SPEF writes each
value as the IEEE 1481 triplet `min:typ:max`: the smallest value at any corner or the nominal, the
nominal, and the largest. DSPF, which has no triplets, holds the nominal stack. With
`--format spice -o <file>`, each corner's netlist goes to `<file>.<corner>`, and the nominal one to
standard output.

![A 10 µm met1 wire a and its network, each value a min:typ:max triplet: 7.857:8.929:10.000 Ω along it, 0.859:0.859:0.944 fF to ground](../../diagrams/pex-006.svg)

**In the deck.**

```text
corner <name> <layer> [thickness <length>] [height <length>] [sheet <resistance>] [dielectric <k>] [area_cap <aF/um2>] [fringe_cap <aF/um>] [tc1 <1/K> tc2 <1/K2>]
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
corner cmax met1 thickness 396nm sheet 0.11ohm area_cap 28.4aF/um2 fringe_cap 44.6aF/um
corner cmin met1 thickness 324nm sheet 0.14ohm
```

**Example output.** The three nets of the PEX-005 example:

```sh
gpurify pex cross.gds --deck corners.deck --format spef > cross.spef
```

```text
*D_NET a 1.786421:1.889606:2.078411
*CONN
*P a B
*CAP
1 a 0.858852:0.858852:0.944248
2 a b 0.922100:1.024556:1.127012
3 a c 0.005469:0.006198:0.007151
*RES
1 a a:1 7.857143:8.928571:10.000000
*INDUC
*END
...
```

The wire's resistance runs from 7.857 Ω at `cmax`, where met1 is 0.11 Ω per square, to 10.000 Ω at
`cmin`, at 0.14 Ω. Its ground capacitance is lowest at nominal, since `cmin` leaves `area_cap` and
`fringe_cap` at their nominal values. The coupling to `b` scales with met1's thickness, from
324 nm to 396 nm.

```sh
gpurify pex cross.gds --deck corners.deck --format spice -o cross.sp > cross.nominal.sp
```

This writes `cross.sp.cmax` and `cross.sp.cmin` beside the nominal netlist. `cross.sp.cmin` holds
`R1 a a#1 10.000000` and `C2 a b 0.922100f`.

**Options.** A `corner` line takes the keys of a `pex` line, each optional, at least one given.

| Parameter | Value | Meaning |
|---|---|---|
| `<name>` | identifier | The corner. Lines with one name build one corner. A corner names each layer once. |
| `<layer>` | layer | A layer with a `pex` line. |
| `tc1`, `tc2` | per kelvin, per kelvin squared | The corner's own temperature coefficients for its `sheet`, both or neither. Without them, the row's apply. |

**Status and limits.** Implemented. Every corner is at the deck's one `temperature`: there is no
per-corner temperature. A corner varies the stack only, with no layout bias per corner. A coupling
that the coupling reach finds at one corner and not at another reads 0 at the corner without it.

**Sources.** IEEE 1481 (SPEF), the `min:typ:max` triplet. The Synopsys StarRC datasheet, for
simultaneous multi-corner extraction. The example's corner values are illustrative.

### PEX-007: Process effects

**What it catches.** A resistance that changes with the conditions it is signed off at. Metal
resistance rises by about 0.3% per kelvin, so a wire at 85 °C has about 18% more resistance than
the foundry's sheet value at 30 °C. IR drop, electromigration and delay checks at hot sign-off read
low without it.

**How GPurify measures it.** The deck's `temperature T nominal T0` says the run is signed off at
`T` and every `sheet` is the value at `T0`. Each `pex` row's resistance is then read at `T` as

\\[ R(T) = R(T_0)\left(1 + t_{c1}\,\Delta T + t_{c2}\,\Delta T^2\right), \quad \Delta T = T - T_0 \\]

where \\( t_{c1} \\) and \\( t_{c2} \\) are the row's `tc1` and `tc2`. This is the ngspice resistor
law, in the coefficients PDKs publish. Only resistance moves with temperature; capacitance does not.
For sky130's met1, \\( t_{c1} = 3.179 \times 10^{-3} \\) /K and \\( t_{c2} = 3.094 \times 10^{-7} \\)
/K². From 30 °C to 85 °C, \\( \Delta T = 55 \\) K and the factor is
\\( 1 + 0.17485 + 0.00094 = 1.17578 \\).

![A 10 µm met1 wire a extracted as one resistor from a to a:1: 8.929 Ω at 30 °C, 10.498 Ω at 85 °C, a factor of 1.1758](../../diagrams/pex-007.svg)

**In the deck.**

```text
temperature <operating> nominal <nominal>
pex <layer> ... tc1 <1/K> tc2 <1/K2>
```

```text
grid 5nm
temperature 85C nominal 30C
layer met1 = gds(68, 20)
layer via = gds(68, 44)
layer met2 = gds(69, 20)
connect conductors [met1, met2]
connect via via [met1, met2]
connect label met1 names met1
connect label met2 names met2
pex met1 thickness 360nm height 1376.1nm sheet 0.125ohm dielectric 4.5 area_cap 25.78aF/um2 fringe_cap 40.57aF/um tc1 3.179e-3/K tc2 3.094e-7/K2
pex via thickness 270nm height 1736.1nm sheet 4.5ohm dielectric 4.5 area_cap 0aF/um2 fringe_cap 0aF/um tc1 0/K tc2 0/K2
pex met2 thickness 360nm height 2006.1nm sheet 0.125ohm dielectric 4.2 area_cap 17.5aF/um2 fringe_cap 37.76aF/um tc1 3.179e-3/K tc2 3.094e-7/K2
extraction rcc coupling_halo 10
```

**Example output.** The three nets of the PEX-005 example at 85 °C:

```sh
gpurify pex cross.gds --deck temp.deck --format spice > cross.sp
```

```text
.subckt cross a b c
C1 a 0 0.858852f
R1 a a#1 10.498044
C2 a b 1.024556f
...
R3 c c#1 1.469726
.ends cross
```

Wire `a` reads 8.928571 Ω × 1.17578 = 10.498044 Ω, and the met2 wire `c` 1.25 Ω × 1.17578 =
1.469726 Ω. The capacitances are those of the nominal run.

**Options.**

| Parameter | Value | Meaning |
|---|---|---|
| `temperature` | temperature (`85C` or kelvin) | The sign-off temperature. At most once. |
| `nominal` | temperature | The temperature every `sheet` is stated at. |
| `tc1` | per kelvin (`/K`) | First-order coefficient. Either sign. Required on every `pex` row once the deck states a `temperature`; write `tc1 0/K tc2 0/K2` for a resistance that does not vary. |
| `tc2` | per kelvin squared (`/K2`) | Second-order coefficient, given with `tc1`. |

GPurify refuses `tc1` and `tc2` without a `temperature`, a `temperature` with a row that lacks them,
and coefficients that bring a resistance to zero or below at `T`.

**Status and limits.** Partial. Only temperature-dependent resistance is modelled. Not modelled:
metal thickness from CMP pattern density, width- and spacing-dependent thickness and sheet
resistance, layer etch bias, current-dependent via resistance, via-coverage resistance, and colour
(mask-shift) effects of multi-patterning. Their models need foundry calibration data that no open
PDK publishes.

**Sources.** The [ngspice manual](https://ngspice.sourceforge.io/docs.html), resistor model
parameters `tc1` and `tc2`. The example's coefficients are SkyWater SKY130's met1 `tc1rm1` and
`tc2rm1` at `tnom = 30`, in the
[sky130_fd_pr resistor and capacitor models](https://github.com/google/skywater-pdk-libs-sky130_fd_pr).
The Synopsys StarRC datasheet, for the effects not modelled.

## Device, fill and 3D effects

### PEX-011: Device-region parasitics

**What it catches.** The capacitance inside a transistor's footprint that its SPICE model leaves to
extraction: from the gate to the source and drain contacts, and from the gate to the diffusion
beside it. In advanced nodes it is a large share of a gate's load, and it adds Miller feedback from
drain to gate. Without it, a simulation of the extracted netlist runs fast.

**How GPurify measures it.** For every MOS whose model a `pex_device` line names, GPurify adds
`(gate_contact_cap + gate_diffusion_cap) × W` from the gate's net to the source's, and the same
again to the drain's. `W` is the extracted gate width. A finger has one source side and one drain
side of its width, so the total is the same however the width is split into fingers. A side on the
gate's own net gets nothing.

![An nfet 2 µm wide, poly gate inp across a diffusion with source tail and drain outp, beside two 1 aF capacitors from inp to tail and from inp to outp](../../diagrams/pex-011.svg)

**In the deck.**

```text
pex_device "<model>" gate_contact_cap <aF/um> gate_diffusion_cap <aF/um>
```

The shipped `sky130` deck with one line added:

```text
pex_device "sky130_fd_pr__nfet_01v8" gate_contact_cap 0.3aF/um gate_diffusion_cap 0.2aF/um
```

**Example output.** A differential pair of two 2 µm nfets, gate `inp` on `XM1` between `tail` and
`outp`:

```sh
gpurify pex diffpair.gds --deck sky130_dev.deck --reference diffpair.spice --format spice > diffpair.sp
```

```text
.subckt diffpair inp inn outp outn tail vss
...
C2 inp inn 0.007172f
C3 inp outp 0.001000f
C4 inp tail 0.001000f
...
```

`C3` and `C4` are the device region: 0.3 aF/µm plus 0.2 aF/µm, times 2 µm, is 1 aF on each side of
`XM1`'s gate. Without the `pex_device` line, both cards are absent.

**Options.**

| Parameter | Value | Meaning |
|---|---|---|
| `<model>` | quoted model name | A `device mos` model of the deck. Each model is stated once. |
| `gate_contact_cap` | capacitance per length (`aF/um`) | Gate to source or drain contact, per µm of gate width. Zero or more. |
| `gate_diffusion_cap` | capacitance per length (`aF/um`) | Gate to the diffusion beside it, per µm of gate width. Zero or more. |

**Status and limits.** Partial. The values are the deck's; they come from the foundry's device
cross-section, which no open PDK publishes. Not modelled: trench-contact resistance, and the gate
resistance that the position of the gate contact sets. Both need a node inside the device, and the
netlist attaches each terminal at the node of the region it touches (see
[PEX-017](output.md#pex-017-simulator-ready-netlist)).

**Sources.** GPurify-specific. The Synopsys StarRC datasheet, for device-region (MEOL)
extraction.

### PEX-012: Metal fill treatment

**What it catches.** The capacitance that dummy metal fill adds to the signal wires around it. Fill
sits between and beside wires, so it raises both their ground capacitance and their coupling. Left
out, the extraction reads low; extracted as signal nets, the fill buries the netlist in thousands of
unnamed nets.

**How GPurify measures it.** A net drawn only on a `pex_fill` layer is a fill piece, not a signal.
GPurify extracts each piece like any net: a fill layer at the height and thickness of a metal layer
couples sideways to that metal as if it were one layer. Then it applies the treatment, and removes
the fill nets from the output:

- `floating`: each piece is a conductor with no charge. GPurify eliminates the pieces from the
  capacitance network together (a Kron reduction). Two nets coupled to a lone piece by
  \\( c_1 \\) and \\( c_2 \\), the piece to ground by \\( c_g \\), couple through it by
  \\[ \frac{c_1 c_2}{c_1 + c_2 + c_g} \\]
  and each keeps its share of the path to ground.
- `grounded`: each piece is tied to ground, so a net's coupling to it becomes capacitance to ground.
- `ignored`: the fill is left out, and every element touching it is dropped.

![Bars a and b on met1 with three met1_fill squares between them; one square couples 28.7 aF to each bar and 188 aF to ground, reduced to 0.0818 fF a to b](../../diagrams/pex-012.svg)

**In the deck.**

```text
pex_fill <layer> floating|grounded|ignored
```

```text
grid 5nm
layer met1 = gds(68, 20)
layer met1_fill = gds(68, 28)
connect conductors [met1, met1_fill]
connect label met1 names met1
pex met1 thickness 360nm height 1376.1nm sheet 0.125ohm dielectric 4.5 area_cap 25.78aF/um2 fringe_cap 40.57aF/um
pex met1_fill thickness 360nm height 1376.1nm sheet 0.125ohm dielectric 4.5 area_cap 25.78aF/um2 fringe_cap 40.57aF/um
extraction rcc coupling_halo 10
pex_fill met1_fill floating
```

**Example output.** Nets `a` and `b` are met1 bars 10 µm × 0.5 µm, 2 µm apart. Between them sit
three 1 µm met1_fill squares, each 0.5 µm from both bars:

```sh
gpurify pex fillpex.gds --deck fillpex.deck --format spice > fillpex.sp
```

```text
.subckt fillpex a b
C1 a 0 1.046814f
R1 a a#1 2.500000
C2 a b 0.081778f
C3 b 0 1.046814f
R2 b b#1 2.500000
.ends fillpex
```

Each square faces each bar over 1 µm across 0.5 µm, which is 28.7 aF, and has 188 aF of its own to
ground. Floating, the three squares add 10.06 aF to the bars' direct 71.7 aF coupling, and 65.9 aF to
each bar's 980.9 aF to ground. With `grounded`, each bar's ground capacitance is instead
0.980870 fF + 3 × 28.7 aF = 1.066933 fF, and the coupling stays 0.071719 fF.

**Options.**

| Parameter | Value | Meaning |
|---|---|---|
| `<layer>` | layer | A conductor layer with a `pex` line, stated once. A net drawn only on it is fill. |
| `floating` | keyword | Fill floats: its couplings are in series. |
| `grounded` | keyword | Fill is at ground: couplings to it are capacitance to ground. |
| `ignored` | keyword | Fill is left out. |

**Status and limits.** Partial. The treatment is the deck's; no open deck states one, and which a
foundry signs off with is its own. Not done: virtual fill (the fill a fill tool would insert, before
it is drawn), and fill in the field solve: a field-solved net's coupling to fill is the closed form's.
More than 2048 floating pieces coupled into one cluster are refused. A fill piece's resistance plays
no part.

**Sources.** The Synopsys StarRC and Cadence Quantus datasheets, for the floating and grounded
treatments. Kron, *Tensor Analysis of Networks* (1939), for the elimination.

### PEX-015: 3D-IC extraction

**What it catches.** The capacitance and resistance of a through-silicon via (TSV), which joins
the front-side metal to a backside pad or another die. A TSV is tens of micrometres long, and its
oxide liner to the silicon is a capacitor of tens to hundreds of femtofarads that loads every
signal crossing between dies.

**How GPurify measures it.** Each cut on a `pex_tsv` layer is a copper cylinder through the
silicon, with the radius of the circle of the cut's drawn area, inside an oxide liner. GPurify adds
its liner capacitance to ground on the node of the net it lands on,

\\[ C = \frac{2\pi \varepsilon_0 k\, l}{\ln\left((r + t)/r\right)} \\]

where \\( l \\) is the `length`, \\( t \\) the `liner` thickness, \\( k \\) the `liner_k` and
\\( r = \sqrt{A/\pi} \\) for a cut of area \\( A \\). The cut's resistance is the `pex` row's
resistance per cut, in series between the layers it joins. For a 5 µm square cut,
\\( r = 2.821 \\) µm. With a 50 µm length and a 200 nm liner of \\( k = 3.9 \\),
\\( C = 2\pi \times 8.854 \times 10^{-3} \times 3.9 \times 50 / \ln(3.021/2.821) = 158.4 \\) fF.

![A 50 µm TSV in its 200 nm liner, joining met1 pad t to backside pad bmet, beside its network: 0.02 Ω from t to t#0 and 158.4 fF of liner on t#0](../../diagrams/pex-015.svg)

**In the deck.**

```text
pex_tsv <cut layer> length <length> liner <length> liner_k <k>
```

```text
grid 5nm
layer met1 = gds(68, 20)
layer tsv = gds(80, 0)
layer bmet = gds(81, 0)
connect conductors [met1, bmet]
connect via tsv [met1, bmet]
connect label met1 names met1
pex met1 thickness 360nm height 1376.1nm sheet 0.125ohm dielectric 4.5 area_cap 25.78aF/um2 fringe_cap 40.57aF/um
pex bmet thickness 1000nm height 0nm sheet 0.02ohm area_cap 0aF/um2 fringe_cap 0aF/um
pex tsv thickness 100nm height 0nm sheet 0.02ohm area_cap 0aF/um2 fringe_cap 0aF/um
extraction rcc coupling_halo 10
pex_tsv tsv length 50um liner 200nm liner_k 3.9
```

**Example output.** Net `t` is a 10 µm met1 pad over one 5 µm TSV cut, landing on a 10 µm backside
pad:

```sh
gpurify pex tsv.gds --deck tsv.deck --format spice > tsv.sp
```

```text
.subckt tsv t
C1 t#0 0 158.375233f
...
C2 t 0 4.200800f
...
```

`C1` is the liner, 158.4 fF, on the backside pad's node. `C2` is the met1 pad's own capacitance to
the substrate: 25.78 aF/µm² × 100 µm² plus 40.57 aF/µm × 40 µm.

**Options.**

| Parameter | Value | Meaning |
|---|---|---|
| `<cut layer>` | layer | A `connect via` cut layer, stated once. |
| `length` | length | The TSV's length through the silicon. Positive. |
| `liner` | length | The oxide liner's thickness. Positive. |
| `liner_k` | number | The liner's relative permittivity. Positive. |

**Status and limits.** Partial. The values are the deck's; no open PDK has a TSV. Not modelled: the
depletion capacitance in series with the liner, TSV-to-TSV coupling through the silicon,
micro-bumps, and interposer wiring.

**Sources.** Katti, Stucchi, De Meyer and Dehaene, "Electrical modeling and characterization of
through silicon via for three-dimensional ICs", IEEE Transactions on Electron Devices 57(1), 2010,
equation 2. The Synopsys StarRC datasheet and Siemens Calibre 3DSTACK, for 3D-IC extraction.
