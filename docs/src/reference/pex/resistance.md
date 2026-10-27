# Resistance extraction

GPurify gives every wire a resistance from its layer's sheet resistance and its number of squares,
and every via array a resistance from its layer's resistance per cut. The values go into the SPEF
`*RES` section and the DSPF and SPICE `R` cards.

## Wires and vias

### PEX-001: Sheet and via resistance

**What it catches.** The series resistance of each wire and via on a net. A long, narrow wire or a
single-cut via adds IR drop and RC delay that the schematic does not show. A timing tool or a
simulator needs these values to predict the real circuit.

**How GPurify measures it.** GPurify first merges a net's shapes on each layer, so a wire reads the
same however it was cut into polygons. Each merged piece is a region. A region's resistance is
`sheet × L / W`, where `L` and `W` are the sides of the rectangle with the region's area and
perimeter. For a straight wire, that is its length over its width. A via array is the cuts that
join the same two regions. Its resistance is the layer's resistance per cut divided by the number of
cuts, in series between the wire below and the wire above.

![A met1 wire 10 µm long climbing a via to a met2 wire, extracted as three resistors in series: met1 8.88 Ω, via 4.5 Ω, met2 1.28 Ω](../../diagrams/pex-001.svg)

Two pieces of a net that touch only at a corner are two regions, since a point carries no current.
GPurify chains them with no resistance between them.

**In the deck.**

```text
pex <layer> thickness <length> height <length> sheet <resistance> [dielectric <k>] area_cap <aF/um2> fringe_cap <aF/um> [tc1 <1/K> tc2 <1/K2>]
```

For a via layer, `sheet` is the resistance of one cut.

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

The values are SkyWater SKY130's met1, via and met2.

**Example output.** Net `a` is a met1 wire 10 µm × 0.14 µm with a 0.3 µm landing pad, a single via
cut, and a met2 wire 0.3 µm × 3.08 µm:

```sh
gpurify pex pair.gds --deck wires.deck --format spef > pair.spef
```

```text
*D_NET a 1.964144
...
*RES
1 a a:1 8.878497
2 a:1 a:2 4.500000
3 a:2 a:3 1.283333
```

The met1 region reads 71.03 squares at 0.125 Ω, or 8.88 Ω. The cut adds 4.5 Ω in series, and the
met2 wire adds 10.27 squares, or 1.28 Ω. From `a` to `a:3` that is 14.66 Ω.

**Options.**

| Parameter | Value | Meaning |
|---|---|---|
| `sheet` | resistance | Sheet resistance per square of a conductor, or resistance of one cut of a via layer. Must be positive on every layer that carries a net. |
| `thickness` | length | Layer thickness. Must be positive. |
| `height` | length | Height of the layer's bottom above the substrate. |
| `tc1`, `tc2` | per kelvin, per kelvin squared | Temperature coefficients, required on every row when the deck states a `temperature`. See [PEX-007](accuracy.md#pex-007-process-effects). |

**Status and limits.** Implemented. A region that is not a straight wire (a bend, a T, a width
step) reads as the rectangle of its area and perimeter, not as the path the current takes. For the
current path through a bend, field-solve the net with `--quasistatic` (see
[PEX-004](inductance.md#pex-004-partial-self-and-mutual-inductance)). A region has one node, so
GPurify does not tell where along a wire a via lands. A conductor layer with a diagonal edge cannot
be merged exactly, so GPurify refuses it and names the layer. A conductor or via layer that carries
a net and has no `pex` line, or a zero `sheet`, is refused:

```text
  pex: refused, layer via: no pex row gives this via layer a positive resistance per cut
```

**Sources.** Weste and Harris, *CMOS VLSI Design*, 4th edition (2011), chapter 6. The example's
values are the
[SkyWater SKY130 parasitic tables](https://github.com/google/skywater-pdk/tree/main/docs/rules/rcx)
and the cut resistances in Magic's SKY130 technology file.
