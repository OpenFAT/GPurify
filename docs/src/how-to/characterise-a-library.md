# Characterise a cell library

`gpurify lib` writes the timing and power model that a digital flow needs to place an analog or custom macro: one Liberty `.lib` file per process corner, and a Verilog blackbox with the same ports. The numbers come from your layout, extracted and simulated at the accuracy you choose. When you finish, you have files that OpenSTA and OpenROAD read.

## Before you start

- You have the cell's GDS layout, a deck that extracts its devices (a shipped deck works), and its SPICE `.subckt`. `lib` reads GDS only, not DEF.
- Every pin of the cell has a label in the layout.
- For any accuracy above `interface`, ngspice is on your `PATH`, and you have the foundry's ngspice model library.

The example is a SKY130 inverter, `inv.gds`, with this reference netlist, `inv.spice`:

```text
.subckt inv A Y vdd vss
XMN Y A vss vss sky130_fd_pr__nfet_01v8 W=0.65 L=0.15
XMP Y A vdd vdd sky130_fd_pr__pfet_01v8 W=1 L=0.15
.ends inv
```

## Steps

1. Write the macro spec, `inv.json`. The layout names the pins, but it cannot say which pin is an input, what each output computes, which timing arcs exist, or what the supplies are in each corner. The spec says those things.

   ```json
   {
     "cell": "inv",
     "accuracy": "spice",
     "substrate": "vss",
     "pins": [
       {"name": "A", "role": "input", "power": "vdd", "ground": "vss"},
       {"name": "Y", "role": "output", "power": "vdd", "ground": "vss", "function": "!A"},
       {"name": "vdd", "role": "power"},
       {"name": "vss", "role": "ground"}
     ],
     "arcs": [
       {"from": "A", "to": "Y", "kind": "combinational", "cases": [
         {"vectors": [{"A": "0"}], "edge": "rise", "output": "fall"},
         {"vectors": [{"A": "1"}], "edge": "fall", "output": "rise"}
       ]}
     ],
     "corners": [
       {"name": "tt_025C_1v80", "temperature": 25,
        "supplies": {"vdd": 1.8, "vss": 0},
        "models": [".lib \"/path/to/sky130A/libs.tech/ngspice/sky130.lib.spice\" tt"]}
     ]
   }
   ```

   List the pins in port order: that order is the blackbox's. `substrate` ties the deck's substrate net to a supply pin, so that it does not float in simulation. Each corner's `models` lines are copied into the simulator deck as written. An unknown key in the spec is an error.

2. Check the pins first, at `interface` accuracy. Set `"accuracy": "interface"` in a copy of the spec. This level measures nothing, so it finishes at once and tells you whether the spec, the layout and the netlist agree.

   ```sh
   gpurify lib inv.gds --deck sky130 --spec inv_if.json --output-dir out_if --reference inv.spice
   ```

   ```text
   interface: wrote out_if/inv.v
   interface: wrote out_if/inv__tt_025C_1v80.lib
   interface: done in 0.0 s
   ```

   Every spec pin must be a label in the layout, every port of the reference `.subckt` must be a spec pin, and, with `--lef`, every pin of the LEF macro too. A difference stops the run before anything is simulated. With output pin `Y` renamed `Z` in the spec:

   ```text
   error: interface accuracy: MissingPin: pin Z names no net in the layout: no label carries it
   ```

3. Choose the accuracy for the files you sign off with, and set it in the spec's `accuracy` key. Each level costs more than the one below.

   | Level | Pin capacitance | Timing arcs | Leakage |
   |---|---|---|---|
   | `interface` (0) | None | None | None |
   | `analytical` (1) | Closed-form wire capacitance plus each device's model capacitance | None | Simulated |
   | `field` (2) | Field-solved wire capacitance plus each device's model capacitance | None | Simulated |
   | `spice` (3) | Charge drawn on the extracted RC netlist | Delay and transition tables, setup and hold, internal energy | Simulated |
   | `statistical` (4) | As `spice` | As `spice`, plus Monte Carlo LVF sigma | Simulated |

   `interface` is enough for floorplanning and power-grid planning. Static timing sign-off wants `spice` or `statistical`. `"all"` writes every level, one subdirectory each. `statistical` needs `mc_models` in each corner: the same model lines with variation on.

4. Run it.

   ```sh
   gpurify lib inv.gds --deck sky130 --spec inv.json --output-dir out_sp --reference inv.spice
   ```

   ```text
   spice: wrote out_sp/inv.v
   spice: wrote out_sp/inv__tt_025C_1v80.lib
   ...
   ```

   Each corner's file is named `<cell>__<corner>.lib`. The run exits 0 when every file was written. Simulator decks and logs go to a temporary directory, which is removed on success and kept, with its path printed, on failure.

5. Read the result. The `.lib` holds the cell's leakage per state, each pin's capacitance in pF, and one table per arc in ns:

   ```text
           cell_leakage_power : 0.4269727710;
   ...
           pin ("A") {
   ...
               capacitance : 0.0029708847;
   ...
                   cell_rise ("delay_7x7") {
                       index_1("0.0100000000, 0.0230506000, 0.0531329000, 0.1224740000, 0.2823110000, 0.6507430000, 1.5000000000");
                       index_2("5.000000000e-4, 0.0013351700, 0.0035653300, 0.0095206200, 0.0254232000, 0.0678883000, 0.1812840000");
                       values("0.0233835000, 0.0282764000, 0.0408713000, 0.0734319000, 0.1591880000, 0.3872820000, 0.9960190000", \
   ...
   ```

   Pin `A` loads its driver with 2.97 fF. With a 10 ps input transition into a 0.5 fF load, `Y` rises 23.4 ps after `A` falls. Leakage is in nW. The slews and loads default to the sky130_fd_sc_hd tables, so the file diffs against a shipped standard-cell library.

6. Give the files to the flow: the `.lib` to OpenSTA with `read_liberty`, and the `.v` blackbox to synthesis. When an arc's cases disagree, as a data-dependent comparator's do, the main file carries the worst case and a `min/` subdirectory the best, for `read_liberty -min`.

## Analog pins and constraints

- An analog pin takes `"role": "analog"`, a `direction` (`input`, `output` or `inout`) and a `bias`, its DC voltage while everything else is measured. It gets a capacitance at that bias and no arc, so static timing leaves it unconstrained.
- A clocked arc's `kind` is the Liberty `timing_type`: `rising_edge`, `falling_edge`, `setup_rising`, `hold_rising`, `setup_falling` or `hold_falling`. A constraint case gives `data`, the edge the data pin makes, and `check`, the `{"pin", "value"}` a correct capture produces.
- `characterization` overrides the tables and thresholds (`slews_ns`, `loads_pf`, the threshold percentages, `mc_samples` and others). `simulator` overrides the simulator binary, its `.option` lines and how many simulator processes run at once.

## What GPurify does not cover

- Minimum pulse width, recovery and removal checks, and input-pin internal power are not characterised.
- Only NLDM tables are written. CCS and ECSM are not.
- The `.lib` carries no antenna data. OpenROAD reads that from the LEF, which `lib` checks against the spec but does not write.
- The field solve at `spice` accuracy grows with the square of a window's panel count, so a dense layout is slow at `spice` and `statistical`.

## Related

- [Command line](../reference/cli.md)
- [Extract parasitics to SPEF, DSPF or SPICE](extract-parasitics.md)
- [How parasitics are modelled](../explanation/parasitics.md)
