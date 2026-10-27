# Run LVS against a SPICE or CDL netlist

Compare a layout with its schematic netlist and get a verdict: `Match`, `Mismatch` with the
discrepancies listed, or `Inconclusive` with the reason.

## Before you start

- A layout whose top cell is the circuit to compare, with text labels on its pins.
- A deck with `device` lines for every device the layout draws. The four shipped decks have them;
  [Shipped decks](../reference/shipped-decks.md) lists the devices each one recognises.
- The reference netlist in one of these forms:
  - SPICE or CDL (`.subckt` cards),
  - Spectre (`subckt` statements),
  - structural Verilog for the top level, beside a SPICE or Spectre library of the cells it
    places.
- Device model names in the netlist that match the deck's `device` lines, such as
  `sky130_fd_pr__nfet_01v8`.

## Steps

1. Make sure the netlist has exactly one top: one subcircuit that no other subcircuit places.
   Subcircuits below it nest to any depth. Delete or comment out spare cells that nothing
   places, or GPurify cannot tell which one is the top.

2. Run the comparison:

   ```sh
   gpurify lvs diffpair.gds --deck sky130 --reference diffpair.spice
   ```

   For a hierarchical netlist nothing changes. This one places one transistor cell twice, and
   matches the same layout:

   ```text
   * The diff pair as two placements of one cell.
   .subckt nhalf d g s b
   XM1 d g s b sky130_fd_pr__nfet_01v8 W=2 L=0.5
   .ends nhalf
   .subckt diffpair inp inn outp outn tail vss
   X1 outp inp tail vss nhalf
   X2 outn inn tail vss nhalf
   .ends diffpair
   ```

3. Read the line that starts with `lvs:` near the end of the report.

   - `lvs: Match` and exit code 0: the layout and the netlist have the same devices, wired the
     same way, with parameters within tolerance.
   - `lvs: Mismatch([...])` and exit code 1: each discrepancy is listed, and each is also an error
     row in the violations, under a rule such as `lvs.model_mismatch` or `lvs.unpaired_device`.
     [Run your first LVS](../tutorials/first-lvs.md) reads one.
   - `lvs: Inconclusive(...)` and exit code 1: the comparison could not decide, and the summary
     says `lvs: refused`. A netlist with two candidate tops gives this:

     ```text
     violations: 0
     lvs: Inconclusive(AmbiguousTop)
     summary:
       drc: not selected
       erc: not selected
       lvs: refused, the comparison did not conclude: AmbiguousTop
       pex: not selected
       0 rules skipped
       5 rules clean
       0 violations: 0 errors, 0 warnings
     ```

4. If GPurify refuses the netlist before comparing, it prints `error: reference <file>:` with the
   reason and the line at fault. Fix the line and run again.

## Use a CDL netlist

GPurify reads a CDL netlist as SPICE: `.SUBCKT` and `.ENDS`, `M`, `R`, `C`, `D` and `Q` device
cards, `X` calls, and `*` comment lines such as `*.PININFO`. Give it with `--reference` as any
other netlist:

```sh
gpurify lvs INVx1_ASAP7_75t_R.gds --deck asap7 --reference INVx1_ASAP7_75t_R.cdl
```

```text
...
violations: 0
lvs: Match
...
```

Other dot statements are refused, `.GLOBAL`, `.PARAM` and `.INCLUDE` among them. Remove them, or
write a global net as a port of each subcircuit that uses it. CDL's `/` before the cell name of a
call (`XI0 a b / inv`) is not read: write the call as SPICE, `XI0 a b inv`.

## Use a Spectre netlist

GPurify reads a netlist as Spectre when its first subcircuit opens with `subckt`, not `.subckt`.
A file with no subcircuit opener is read as Spectre when its name ends in `.scs` or `.spectre`.

## Use a Verilog top level

Give the cell library first and the Verilog top second, each with its own `--reference`:

```sh
gpurify lvs diffpair.gds --deck sky130 --reference cells.spice --reference top.v
```

`cells.spice` defines the cell, and `top.v` places it:

```text
* One sky130 nfet as a cell.
.subckt nhalf d g s b
XM1 d g s b sky130_fd_pr__nfet_01v8 W=2 L=0.5
.ends nhalf
```

```text
module diffpair (inp, inn, outp, outn, tail, vss);
  input inp, inn;
  output outp, outn;
  inout tail, vss;
  nhalf left  (.d(outp), .g(inp), .s(tail), .b(vss));
  nhalf right (.d(outn), .g(inn), .s(tail), .b(vss));
endmodule
```

A file ending in `.v` is Verilog. Give at most one SPICE or Spectre file beside the Verilog files.
GPurify reads the structural subset a netlister writes. Compiler directives (`` `ifdef ``) and
constants (`1'b0`) are refused, so write power connections and tie cells as nets and instances.

## Hold pins to their labels

By default GPurify pairs nets by how they are wired, and a label only breaks a tie between nets
that the wiring cannot tell apart. A layout whose pin labels sit on the wrong nets still gives
`Match` when its wiring alone pairs with the netlist's. To report it, add this line to a copy of
the deck:

```text
lvs ports_by_name
```

Each port of the netlist's top cell is then held to the layout net its name labels, and a swapped
or missing label is reported as `lvs.unpaired_net`. The shipped decks do not set it.

## Related

- [LVS checks](../reference/lvs/README.md)
- [How LVS matches devices](../explanation/how-lvs-matches.md)
- [Deck language](../reference/deck/README.md)
- [Choose a deck](choose-a-deck.md)
