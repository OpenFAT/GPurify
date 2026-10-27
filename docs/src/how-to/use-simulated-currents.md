# Use simulated currents for EM and IR drop

A current budget in the design intent spreads one current evenly over a net's loads. In an
analog block the per-device currents differ, and they decide whether a wire is wide enough. This
guide feeds a simulator's per-terminal currents to ERC, so the IR-drop and electromigration rules
check each wire and cut with the current that really flows through it.

## Before you start

- GPurify is installed. See [Install GPurify](install.md).
- You have a layout and its reference netlist, and LVS reports `lvs: Match` for them. See
  [Run LVS against a SPICE or CDL netlist](run-lvs.md). GPurify places each simulated current
  through the device pairing LVS finds, so a layout that does not match is refused.
- You have a current file in the `espice-emir/1` format, written by ESPice's `--emir` option from
  a simulation of the same reference netlist.
- You have a design intent file that declares the supplies. See
  [Give ERC its design intent](give-erc-design-intent.md).

The examples use the sky130 diff pair from the tutorials: two transistors `XM1` and `XM2` on a
shared source net `tail`, with reference netlist `diffpair.spice`.

## Steps

1. Confirm that LVS matches:

   ```sh
   gpurify lvs diffpair.gds --deck sky130 --reference diffpair.spice
   ```

   ```text
   ...
   lvs: Match
   ...
   ```

2. Check the current file. It lists, for every terminal of every device in the reference, its
   average, electromigration-average, RMS and peak current, in amperes and positive into the
   terminal. Here each transistor draws 0.5 mA from drain to source:

   ```json
   {
     "format": "espice-emir/1",
     "analysis": "tran",
     "temp": 105,
     "terminals": [
       {"instance": "xm1", "terminal": "d", "avg": 5.0e-4, "em_avg": 5.0e-4, "rms": 6.0e-4, "peak": 1.5e-3},
       {"instance": "xm1", "terminal": "g", "avg": 0, "em_avg": 0, "rms": 0, "peak": 0},
       {"instance": "xm1", "terminal": "s", "avg": -5.0e-4, "em_avg": 5.0e-4, "rms": 6.0e-4, "peak": 1.5e-3},
       {"instance": "xm1", "terminal": "b", "avg": 0, "em_avg": 0, "rms": 0, "peak": 0},
       {"instance": "xm2", "terminal": "d", "avg": 5.0e-4, "em_avg": 5.0e-4, "rms": 6.0e-4, "peak": 1.5e-3},
       {"instance": "xm2", "terminal": "g", "avg": 0, "em_avg": 0, "rms": 0, "peak": 0},
       {"instance": "xm2", "terminal": "s", "avg": -5.0e-4, "em_avg": 5.0e-4, "rms": 6.0e-4, "peak": 1.5e-3},
       {"instance": "xm2", "terminal": "b", "avg": 0, "em_avg": 0, "rms": 0, "peak": 0}
     ]
   }
   ```

   The instances are the reference's devices by their flattened names, in any case. A name under a
   device, such as `xm1.msky130_fd_pr__nfet_01v8` inside a PDK wrapper subcircuit, names that
   device too. When the simulation places the circuit under a testbench instance, such as
   `xdut.xm1`, GPurify reads the instances under it and leaves the testbench's own out. Each
   device's terminals come in the order of its card, as ESPice writes them.

3. Add limits for the nets the currents load. A non-supply net takes `max_drop_mv`, measured from
   its port, the labelled point where the current returns. Save this as `intent.json`:

   ```json
   {
     "temperature_c": 105,
     "domains": { "core": { "voltage_mv": 1800 } },
     "supplies": [
       { "net": "vss", "domain": "core", "role": "ground" }
     ],
     "limits": [
       { "net": "tail", "max_drop_mv": 5 }
     ]
   }
   ```

4. Run ERC with the reference, the intent and the currents:

   ```sh
   gpurify erc diffpair.gds --deck sky130 --reference diffpair.spice --intent intent.json --currents diffpair.emir.json
   ```

   ```text
   rules:
   ...
     ir_drop: ran, examined 3 shapes, found 2 violations
   ...
     EM.met1_mcon: ran, examined 7 shapes, found 3 violations
   ...
   violations: 7
   ...
     ir_drop error layer nsd at (2000 nm, 1000 nm) measured 194.3 mV against limit 5 mV on shape 40 loaded most by xm1 s
     ir_drop error layer li_c at (2000 nm, 1000 nm) measured 9.3 mV against limit 5 mV on shape 53 loaded most by xm1 s
     EM.met1_mcon error layer mcon at (500 nm, 1000 nm) measured 500 uA against limit 360 uA on shape 51 and shape 21 loaded most by xm1 d
     EM.met1_mcon error layer mcon at (2000 nm, 1000 nm) measured 1000 uA against limit 360 uA on shape 53 and shape 22 loaded most by xm1 s
     EM.met1_mcon error layer mcon at (3500 nm, 1000 nm) measured 500 uA against limit 360 uA on shape 55 and shape 23 loaded most by xm2 d
   summary:
   ...
   ```

   The shared source contact at (2000 nm, 1000 nm) carries both transistors' 1000 µA through one
   mcon cut, against the deck's 360 µA per cut. The `tail` diffusion under it sits 194.3 mV from
   the net's port, against the 5 mV limit.

5. Read `loaded most by` on each finding. It names the instance and terminal whose current loads
   that wire or cut most, so you know which device to move or which contact to double. The JSON
   report carries the same as `"load"`.

6. Fix the layout, or the limits, and run the same command again. `gpurify all` takes the same
   `--reference`, `--intent` and `--currents` options.

If GPurify cannot place the currents, the ERC stage is refused and says why. Here the reference
states `W=3` on both transistors, where the layout draws 2 µm:

```sh
gpurify erc diffpair.gds --deck sky130 --reference w3.spice --intent intent.json --currents diffpair.emir.json
```

```text
...
summary:
  drc: not selected
  erc: refused, --currents: the layout does not match its reference (LVS found 2 discrepancies), so no device pairing places them
...
```

GPurify also refuses a current file whose instances are not the reference's devices, a terminal
count that is not the card's, and a net with no label whose currents do not sum to zero, since
that current has nowhere to return.

## What GPurify does not cover

- One file is one simulation at one corner. Run once per corner you sign off.
- A net's RMS and peak currents are summed over its loads as if every load peaked together, an
  upper bound.
- A device the deck's `lvs ignore` leaves out carries no current into the grid.

## Related

- [Design intent file](../reference/design-intent.md)
- [ERC checks](../reference/erc/README.md)
- [Command line](../reference/cli.md)
- [IR drop and electromigration](../explanation/ir-drop-and-em.md)
