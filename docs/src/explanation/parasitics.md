# How parasitics are modelled

GPurify turns each net into a small network of resistors, capacitors and, for the nets you
field-solve, inductors. This page explains where each number comes from, so you can predict a
value before you read it and judge how far to trust it. The reference pages give the deck syntax:
[Resistance extraction](../reference/pex/resistance.md),
[Capacitance extraction](../reference/pex/capacitance.md),
[Inductance extraction](../reference/pex/inductance.md) and
[Accuracy and field solving](../reference/pex/accuracy.md).

## From shapes to regions

GPurify first merges a net's shapes on each layer. Each merged piece is a *region*, so a wire
gives the same numbers however it was cut into polygons. Each region becomes a resistor between
two nodes, from the node where current enters it to its far node. A via array, the cuts that join
the same two regions, becomes one resistor between them.

The node a net's label sits on is the net's port. SPEF and DSPF write it with the bare net name,
`a`. Every other node is `a:1`, `a:2` and so on, or `a#1`, `a#2` in a SPICE netlist.

Two pieces of a net that touch only at a corner are two regions, because a point carries no
current. GPurify joins them with no resistance between them.

## Resistance

A region's resistance is its sheet resistance times its number of squares. GPurify counts the
squares of the rectangle that has the region's area and perimeter:

\\[ R = R_s \frac{L}{W}, \qquad L + W = \frac{P}{2}, \qquad L W = A \\]

where \\( R_s \\) is the layer's `sheet` resistance in ohms per square, \\( A \\) the region's
area and \\( P \\) its perimeter. \\( L \\) and \\( W \\) are the two roots of
\\( t^2 - (P/2) t + A = 0 \\). For a straight wire, \\( L \\) is its length and \\( W \\) its
width, so the count is exact.

For example, a met1 wire 10 µm × 0.14 µm with a 0.3 µm landing pad at one end has an area of
1.448 µm² and a perimeter of 20.6 µm. Its rectangle is 10.157 µm × 0.143 µm, or 71.03 squares. At
0.125 Ω per square, that is 8.878 Ω.

A via array's resistance is its layer's resistance per cut divided by the number of cuts. It sits
in series between the wire below and the wire above, from the lower region's far node to the upper
region's node. The current from one end of the net to the other passes through every region and
every cut in turn, so the end-to-end resistance is their sum.

![Net a as drawn, a met1 wire of 71.03 squares, one via cut and a met2 wire of 10.27 squares, and its series network from a to a:3: 8.878 + 4.5 + 1.283 = 14.66 Ω](../diagrams/parasitics-1.svg)

The met1 wire above climbs one cut of 4.5 Ω to a met2 wire 0.3 µm × 3.08 µm (10.27 squares,
1.283 Ω). From `a` to `a:3`, the net reads 8.878 + 4.5 + 1.283 = 14.66 Ω.

The rectangle of the same area and perimeter is exact only for a straight wire. For a bend, a T or
a width step, it is an estimate, and the current path is not resolved. A region also has a single
node at each end, so GPurify does not tell where along a wire a via lands. When the current path
through a bend matters, field-solve the net (see [When a field solve runs](#when-a-field-solve-runs)).

## Capacitance to ground

Each region has a capacitance to the substrate, which is ground:

\\[ C_g = C_a A + C_f P \\]

where \\( C_a \\) is the layer's `area_cap` in aF/µm² and \\( C_f \\) its `fringe_cap` in aF/µm.
For a met1 wire 10 µm × 0.14 µm, that is 25.78 × 1.4 + 40.57 × 20.28 = 858.9 aF, or 0.859 fF. The
capacitance sits on the region's first node.

The coefficients are the deck's, one pair per layer, measured over bare substrate. GPurify counts
no shielding: a wire keeps its full capacitance to ground even under another wire. That errs
towards more capacitance to ground than a field solve gives.

Because a region's capacitance sits on its first node, a net drawn as one straight region has all
its capacitance at the driver end. A timing tool reading such a net sees the wire's capacitance as
load, but no delay along the wire itself. The delay between regions, across a via or a change of
layer, is kept.

## Coupling to neighbours

Two nets couple where their shapes face each other. GPurify uses two parallel-plate forms:

\\[ C_\text{side} = \frac{\varepsilon_0 \varepsilon_r t L}{S}, \qquad C_\text{over} = \frac{\varepsilon_0 \varepsilon_r A}{d} \\]

For \\( C_\text{side} \\), two rectangles of different nets lie side by side on one layer.
\\( t \\) is the layer's thickness, \\( L \\) the length they face each other, \\( S \\) the gap,
and \\( \varepsilon_r \\) the layer's `dielectric`. For \\( C_\text{over} \\), two rectangles on two
layers overlap. \\( A \\) is the overlap area, \\( d \\) the gap from the top of the lower layer to
the bottom of the upper one, and \\( \varepsilon_r \\) the lower layer's `dielectric`.
\\( \varepsilon_0 \\) is 8.854 aF/µm.

![Cross-section of met1 wires a and b with met2 wire c above: a side-by-side capacitor between a and b, overlap capacitors from c to each, and area and fringe capacitors to the substrate](../diagrams/parasitics-2.svg)

Two met1 wires 10 µm long, 0.36 µm thick and 0.14 µm apart in ε = 4.5 couple by
8.854 × 4.5 × 0.36 × 10 / 0.14 = 1024.6 aF. A met2 wire 0.3 µm wide crossing one of them, 0.27 µm
above it, overlaps 0.042 µm² and couples by 8.854 × 4.5 × 0.042 / 0.27 = 6.2 aF.

Lateral coupling is looked for only within `coupling_halo` thicknesses of each layer, so two
wires further apart than that do not couple. The side form leaves out the fringe between the two
sidewalls' tops and bottoms, so lateral coupling reads low. A field solve of the wires above gives
1.543 fF between them, not 1.025 fF.

## When a field solve runs

Every net gets the closed forms above. A net named with `--quasistatic <net>` is solved from the
field instead:

- **Capacitance** comes from a boundary-element solve over every face of the named nets' shapes
  and every interface where the dielectric changes with height, as FastCap does. The substrate is
  a grounded plane. A field-solved net's coupling to a net that was not named stays in closed form.
- **Resistance and inductance** come from a filament solve at 1 MHz, as FastHenry does. A lone
  rectangle is one filament with uniform current. A bend or a width step is a grid of filaments, so
  current crowds at an inner corner: a right-angle corner reads 0.62 squares, against 0.559 for the
  exact current path and 1 square for its centre line.

The field solve is the reference for the nets that matter: a clock, a matched pair, a sensitive
node. For the two met1 wires above, it moves a third of each wire's ground capacitance into the
coupling: 0.542 fF to ground and 1.543 fF between them, against 0.859 fF and 1.025 fF in closed
form. To see such differences net by net, compare the two SPEF files with `gpurify compare` (see
[PEX-009](../reference/pex/output.md#pex-009-pex-netlist-diff-and-qualification)).

## Inductance

Only field-solved nets get inductance. Each one gets its resistance and its self inductance in
series, from its port to its far node. Every two field-solved nets get their mutual inductance,
written in SPICE and DSPF as a `K` card with \\( k = M / \sqrt{L_1 L_2} \\). Two parallel met1 wires
10 µm × 0.14 µm, 0.14 µm apart, each read 8.40 pH, and they couple by 6.41 pH, so \\( k = 0.763 \\).

Inductance matters when \\( \omega L \\) is comparable to the wire's resistance: long, wide or fast
wires such as clock spines, supply straps and RF lines. At 1 GHz, the 8.40 pH wire above has an
\\( \omega L \\) of 0.053 Ω against its 8.93 Ω, so its inductance is negligible. Skin and
proximity effects above 1 MHz are not modelled.

## Corners and temperature

A deck's `corner` lines describe the stack at the edges of the process window: thicker or thinner
metal, a higher or lower sheet resistance. GPurify extracts the nominal stack and every corner in
one run. SPEF writes each value as a `min:typ:max` triplet: the smallest value at any corner or the
nominal, the nominal, and the largest. The `min` and `max` of one value can come from different
corners, so a triplet is an envelope, not one corner's netlist. For one corner's netlist, write
SPICE with `-o`, which writes each corner to its own file.

A deck's `temperature` line reads every resistance at the operating temperature:

\\[ R(T) = R(T_0) \left( 1 + t_{c1} (T - T_0) + t_{c2} (T - T_0)^2 \right) \\]

where \\( T \\) is the operating temperature, \\( T_0 \\) the nominal one, and \\( t_{c1} \\) and
\\( t_{c2} \\) the layer's `tc1` and `tc2`. Capacitance does not change with temperature. See
[Process effects](../reference/pex/accuracy.md#pex-007-process-effects).

## What the totals mean

A SPEF `*D_NET` line gives a net's total capacitance: its capacitance to ground plus every
coupling it has. A coupling between `a` and `b` is listed under both nets, and each net's total
counts it. Summing the totals of all nets therefore counts every coupling twice; `gpurify compare`
counts it once.

An `rc` or `c` extraction grounds every coupling: it puts the same capacitance from each of the two
nets to ground. Each net's total stays the same, but the crosstalk between them is gone.

The resistances are the network's elements, not a net's resistance from end to end. To get the
resistance between two points on a net, sum the resistors along the path between them, or ask
GPurify with `report p2p` (see
[PEX-016](../reference/pex/output.md#pex-016-point-to-point-resistance-and-net-to-net-coupling-report)).
For the net above, the path from `a` to `a:3` is 14.66 Ω.
