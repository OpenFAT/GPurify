# Give ERC its design intent

Some electrical rules need facts that no process deck holds: which nets are supplies, at what
voltage, and how much drop or current each net is allowed. This guide writes those facts into a
design intent file and runs ERC with it, so the rules that need them run instead of reporting
`skipped`.

## Before you start

- GPurify is installed. See [Install GPurify](install.md).
- You have a layout whose supply nets carry text labels on a label layer the deck reads. The
  examples use the sky130 diff pair from the tutorials, whose ground net is labelled `vss`.
- You know each supply's nominal voltage, and the limits you want checked on each net.

## Steps

1. Run ERC without design intent, to see which rules wait for it:

   ```sh
   gpurify erc diffpair.gds --deck sky130
   ```

   ```text
   rules:
   ...
     ir_drop: skipped, no design intent was supplied, examined 0 shapes, found 0 violations
   ...
     vgs.01v8: skipped, no design intent was supplied, examined 0 shapes, found 0 violations
   ...
     EM.met1_mcon: skipped, no design intent was supplied, examined 0 shapes, found 0 violations
   ...
   summary:
     drc: not selected
     erc: ran
     lvs: not selected
     pex: not selected
     15 rules skipped
     21 rules clean
     2 violations: 2 errors, 0 warnings
   ```

   Fifteen of the shipped sky130 deck's ERC rules are skipped, and the run exits 1. A skipped
   rule looked at nothing.

2. Write the intent file. Name each supply net as its layout label names it, put it in a voltage
   domain, and give it a role, `power` or `ground`. Save this as `intent.json`:

   ```json
   {
     "temperature_c": 105,
     "domains": { "core": { "voltage_mv": 1800 } },
     "supplies": [
       { "net": "vss", "domain": "core", "role": "ground" }
     ],
     "limits": [
       { "net": "vss", "max_drop_mv": 90, "budget_current_ua": 200 }
     ]
   }
   ```

   `domains` gives each domain its nominal voltage. `supplies` places nets in domains: a power
   net sits at its domain's voltage, and a ground net at 0 V. `limits` holds the per-net limits:
   here the ground net rises by at most 90 mV while its loads draw 200 µA between them.
   `temperature_c` is the junction temperature the electromigration rules run at. Every section
   is optional, and every key is checked: a misspelt key refuses the file rather than leaving a
   rule unchecked.

3. Run ERC with the intent file:

   ```sh
   gpurify erc diffpair.gds --deck sky130 --intent intent.json
   ```

   ```text
   rules:
   ...
     ir_drop: ran, examined 4 shapes, found 0 violations
   ...
     vgs.01v8: ran, examined 0 shapes, found 0 violations
   ...
     EM.met1_mcon: ran, examined 2 shapes, found 0 violations
   ...
   summary:
     drc: not selected
     erc: ran
     lvs: not selected
     pex: not selected
     0 rules skipped
     36 rules clean
     2 violations: 2 errors, 0 warnings
   ```

   No rule is skipped now. The two remaining errors are `floating_gate` findings on the gate
   inputs `inp` and `inn`: the sky130 deck does not count a label as a driver, so a cell's input
   gates are floating until the cell is placed.

4. Read the `examined` count of each rule you rely on. `vgs.01v8` ran but examined 0 shapes: it
   checks a transistor only when some supply reaches its gate and channel, and in this cell no
   supply reaches the gates. Declare the supply that drives a net, or check the block where it
   is driven, before you count such a rule as clean.

5. Tighten a limit to see how a broken one reads. In `intent.json`, set `vss` to
   `"max_drop_mv": 0.05` and `"budget_current_ua": 1000`, and run again:

   ```sh
   gpurify erc diffpair.gds --deck sky130 --intent intent.json
   ```

   ```text
   rules:
   ...
     ir_drop: ran, examined 4 shapes, found 1 violations
   ...
   violations: 3
   ...
     ir_drop error layer met1 at (5050 nm, 1000 nm) measured 0.0625 mV against limit 0.05 mV on shape 24
   ...
   ```

   The ground net rises 0.0625 mV at the `vss` pad, (5050 nm, 1000 nm), against a 0.05 mV limit.

6. Use the same file with `gpurify all`, which also takes `--intent`.

If the file has a mistake, the run stops before any check and names the line. Here `typo.json`
spells `max_drop_mv` as `max_drop_mV`:

```sh
gpurify erc diffpair.gds --deck sky130 --intent typo.json
```

```text
error: intent typo.json: Malformed
  malformed intent file: UnknownField at line 8 column 34
```

## What GPurify does not cover

- A limit you leave out is not checked for that net. It does not mean the net is unlimited.
- A current budget spreads one current evenly over a net's loads, all in phase. For per-device
  currents from a simulation, see
  [Use simulated currents for EM and IR drop](use-simulated-currents.md).

## Related

- [Design intent file](../reference/design-intent.md): every key, including power states and net
  types
- [ERC checks](../reference/erc/README.md)
- [How a run passes](../explanation/outcomes.md)
- [IR drop and electromigration](../explanation/ir-drop-and-em.md)
