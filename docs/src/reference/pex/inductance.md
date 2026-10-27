# Inductance extraction

GPurify extracts the self inductance of each field-solved net and the mutual inductance between
every two of them. Inductance matters on long, wide and fast wires, such as clock spines, supply
straps and RF lines, where `ωL` is comparable to the wire's resistance.

## Self and mutual inductance

### PEX-004: Partial self and mutual inductance

**What it catches.** The partial inductance of a wire and the magnetic coupling between two
wires. On a fast edge or at RF, inductance adds delay, ringing and supply bounce, and mutual
inductance couples noise between parallel wires that capacitance alone does not predict.

**How GPurify measures it.** Only nets named with `--quasistatic` get inductance. GPurify cuts each
such net into current filaments and solves them together at 1 MHz, as FastHenry does. A lone
rectangle is one filament carrying uniform current. A region of several rectangles (a bend, a
change of width) is a grid four cells across its narrowest part, so the current crowds at an inner
corner: a right-angle corner reads 0.62 squares, against the 0.559 of the exact answer and the
1 square of its centre line. A via is one filament between its landings.

Each field-solved net gets its resistance and self inductance in series, from its first node to its
far node. Every two field-solved nets get their mutual inductance: the open-circuit coupling
between their ports, where each port's current enters at the end of the net that comes first by
x, then by y. Two parallel wires read a positive mutual inductance. A net that is not field-solved
carries no current in the solve.

![Two parallel met1 wires a and b, each extracted as a resistor of 8.93 Ω in series with an inductor of 8.40 pH, the two inductors coupled by k = 0.763](../../diagrams/pex-004.svg)

**In the deck.** Nothing to write beyond the parasitic stack: every layer of a field-solved net
needs a positive `sheet` and `thickness`, and every layer above the substrate a `dielectric`. Run
with `--quasistatic <net>` once for each net.

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

**Example output.** Nets `a` and `b` are met1 wires 10 µm × 0.14 µm, 0.14 µm apart:

```sh
gpurify pex cross.gds --deck wires.deck --quasistatic a --quasistatic b --format spice > cross.sp
```

```text
.subckt cross a b c
C1 a 0 0.542366f
R1 a a#1 8.928571
L1 a#1 a#2 8.400109p
C2 a b 1.542564f
K1 L1 L2 0.762979
...
```

The 10 µm bar reads 8.40 pH, which Grover's formula for a rectangular bar also gives. `K1` couples
the two wires' inductors by `M / √(L₁L₂)`: a mutual inductance of 6.41 pH over 8.40 pH. SPEF has
no element for mutual inductance, so a SPEF file carries it as a comment in the first net's
block:

```text
*INDUC
1 a:1 a:2 8.400109
// mutual a b 6.409104
```

SPEF's `*L_UNIT 0.000001 UH` makes each inductance a value in picohenries.

**Status and limits.** Implemented. Resistance and inductance are solved at one frequency, 1 MHz.
Skin and proximity effects at higher frequencies, which FastHenry resolves with filament meshing
across the cross-section, are not modelled. A via is one filament, so current spreading around a
cut is not resolved. A field-solved net whose shapes do not join into one circuit is refused: two
pieces that meet only at a corner, or pieces joined only through a `connect global` layer (the
substrate).

```text
  pex: refused, net g's shapes do not join into one circuit through shared edges and vias, so its inductance is undefined
```

**Sources.** Grover, *Inductance Calculations* (1946). Kamon, Tsuk and White, "FastHenry: a
multipole-accelerated 3-D inductance extraction program", IEEE Transactions on Microwave Theory and
Techniques 42(9), 1994.
