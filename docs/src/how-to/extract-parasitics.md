# Extract parasitics to SPEF, DSPF or SPICE

This guide extracts the parasitic resistance and capacitance of a layout and writes them in the
form your next tool reads: SPEF for a timing tool, DSPF for a simulator, or a SPICE `.subckt`
that a post-layout testbench includes in place of the schematic.

## Before you start

- GPurify is installed. See [Install GPurify](install.md).
- Your deck has a `pex` line for every conductor layer that carries a net and every via layer
  whose cuts join two conductors. The shipped decks have them, except asap7's middle of line.
  See [Shipped decks](../reference/shipped-decks.md).
- Every net you want in a SPEF file carries a text label in the layout. SPEF names nets only by
  their labels.
- For DSPF or SPICE named in your schematic's terms, you have the reference netlist and LVS
  matches it. See [Run LVS against a SPICE or CDL netlist](run-lvs.md).

The examples use the sky130 diff pair from the tutorials, `diffpair.gds`, with reference netlist
`diffpair.spice`.

## Steps

1. Write SPEF for a timing tool:

   ```sh
   gpurify pex diffpair.gds --deck sky130 --format spef > diffpair.spef
   ```

   ```text
   *SPEF "IEEE 1481-1998"
   *DESIGN "diffpair.gds"
   ...
   *T_UNIT 1 NS
   *C_UNIT 1 FF
   *R_UNIT 1 OHM
   *L_UNIT 0.000001 UH
   ...
   *D_NET tail 0.208679
   *CONN
   *P tail B
   *CAP
   1 tail:0 0.087585
   2 tail:0 outn:0 0.007172
   ...
   ```

   Net `tail` has 0.208679 fF in total. A coupling capacitance appears in the `*CAP` section of
   both nets it joins, as readers that take one net at a time expect.

2. Write DSPF for a simulator, with the reference netlist so that devices and nets carry the
   schematic's names:

   ```sh
   gpurify pex diffpair.gds --deck sky130 --reference diffpair.spice --format dspf > diffpair.dspf
   ```

   ```text
   ...
   *|NET tail 0.208679f
   ...
   * instance section
   ...
   XM2 outn:1 inn:1 tail:1 vss:0 sky130_fd_pr__nfet_01v8 w=2.0 l=0.5 nf=1 as=1.0 ps=3.0 ad=2.0 pd=6.0
   ```

   With `--reference`, `pex` also runs LVS, and each device is written as the reference card it
   pairs with, on the extracted node its terminal touches. A layout that does not match its
   reference is refused, since no netlist is written for wiring the schematic does not have.

3. Write a SPICE subcircuit that a testbench runs on its own:

   ```sh
   gpurify pex diffpair.gds --deck sky130 --reference diffpair.spice --format spice > diffpair.pex.spice
   ```

   ```text
   * 0.1.0 pex: diffpair.gds, deck sky130, reference diffpair.spice, corner nominal
   * sizes in units of 1e-6 m: a bench's .option scale must say the same
   .subckt diffpair inp inn outp outn tail vss
   ...
   XM2 outn#1 inn#1 tail#1 vss sky130_fd_pr__nfet_01v8 w=2.0 l=0.5 nf=1 as=1.0 ps=3.0 ad=2.0 pd=6.0
   C1 inp 0 0.087585f
   ...
   .ends diffpair
   ```

   The `.subckt` is the reference's top cell with its ports in the reference's order, so the
   testbench includes this file in place of the schematic's subcircuit. Device sizes are in the
   deck's netlist unit, 1 µm for sky130, and the second line says so: the bench's `.option scale`
   must agree. A pin node keeps the net's bare name; every other node is `net#n`.

4. Without `--reference`, DSPF and SPICE still carry the devices, named by layout index, with the
   pins in label order. GPurify warns on standard error that such a netlist cannot be
   back-annotated:

   ```sh
   gpurify pex diffpair.gds --deck sky130 --format dspf > diffpair.dspf
   ```

   ```text
   warning: no --reference, so devices are named by layout index and pins come in label order: this netlist cannot be back-annotated
   ```

5. For a deck with `corner` lines, add `-o FILE` to a `--format spice` run. The nominal netlist
   goes to standard output and each corner's to `FILE.<corner>`. SPEF writes every value as a
   `min:typ:max` triplet over the corners, and DSPF writes the nominal one. The shipped decks
   state no corners.

6. To solve a critical net's capacitance and inductance from the field instead of the closed
   forms, name it with `--quasistatic`, once per net:

   ```sh
   gpurify pex diffpair.gds --deck sky130 --format spef --quasistatic tail > diffpair.spef
   ```

   The field solve is slower. Every two field-solved nets also get their mutual inductance,
   which DSPF writes as a `K` card.

7. Choose what is written with the deck's `extraction` line: resistance and capacitance with or
   without coupling, capacitance alone, or resistance alone. Without one, everything is written.

GPurify refuses rather than writes a file that reads as fewer parasitics than the layout has: a
conductor layer with no `pex` line, a net with no label in SPEF, a label on two unconnected nets,
and two labels on one net.

## What GPurify does not cover

- The closed forms are parallel-plate: lateral coupling has no fringing or shielding, so it is a
  lower bound.
- A conductor layer with a diagonal edge is refused, since its shapes cannot be merged exactly.
- The layout-dependent effect parameters LVS measures (`sa`, `sb` and the well proximity terms)
  are not written to the SPICE netlist.

## Related

- [PEX checks](../reference/pex/README.md)
- [Run features](../reference/run-features.md): `report p2p` and `report coupling`
- [Command line](../reference/cli.md)
- [How parasitics are modelled](../explanation/parasitics.md)
