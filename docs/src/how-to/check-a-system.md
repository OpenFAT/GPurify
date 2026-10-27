# Check a multi-die system

`gpurify system` checks a 2.5D or 3D assembly as one circuit: dies on an interposer, a die stack, or chiplets. It reads each die with its own deck, places the dies, bonds the bumps that face each other, and compares the assembled circuit with one system netlist. When you finish, you know whether every bump bonds, whether the bonds line up within your assembly limits, and whether the dies together make the circuit the netlist describes.

## Before you start

- Each die has a GDS layout and a deck. The deck declares the bump layer as a conductor and connects it to the die's wiring with a `connect via` line. Every die is on the same grid.
- Every bump is a rectangle on its die's bump layer, and each signal that crosses a bond has a label on its die.
- You have a system netlist (SPICE or Spectre) with one top subcircuit. It places one instance per active die, named as the die, and its ports are the package pins. A die no instance names, such as a passive interposer, is wiring only.
- You know your assembly limits: the largest centre-to-centre offset of two bonded bumps, and the least gap to a bump that should not bond. Your packager or foundry states them; GPurify has no defaults.

The example joins two dies, `XA` and `XB`, each a 500 Ω poly resistor, through one bump on net `mid`. The system netlist is `system.spice`:

```text
* Two dies in series: XA's resistor feeds XB's through one bump.
.subckt RA in mid
R1 in mid rpoly r=500
.ends RA
.subckt RB mid out
R1 mid out rpoly r=500
.ends RB
.subckt SYS in out
XA in mid RA
XB mid out RB
.ends SYS
```

## Steps

1. Write the system file, `stack.json`. It lists the dies, where each sits, and which layers bond. Paths in it are relative to the file.

   ```json
   {
     "dies": [
       { "name": "XA", "layout": "XA.gds", "deck": "die.deck" },
       { "name": "XB", "layout": "XB.gds", "deck": "die.deck", "mirror": true }
     ],
     "bonds": [
       { "a": { "die": "XA", "layer": "bump" },
         "b": { "die": "XB", "layer": "bump" },
         "max_offset_nm": 200 }
     ]
   }
   ```

   `mirror` flips a die face down: GPurify reflects it in its x axis, then turns it counter-clockwise by `rotate` (0, 90, 180 or 270), then moves its origin to `origin_nm`, as a GDS reference places a cell. Each bond names a layer on two different dies. Two bumps bond where they overlap with some area; bumps that only touch do not bond.

2. Run the check with the system file and the system netlist. `system` takes no `--deck`, because each die names its own.

   ```sh
   gpurify system stack.json --reference system.spice
   ```

   ```text
   rules:
     system.unbonded_bump: ran, examined 2 shapes, found 0 violations
     system.bump_offset: ran, examined 1 shapes, found 0 violations
     system.open: ran, examined 4 shapes, found 0 violations
     system.short: ran, examined 4 shapes, found 0 violations
   violations: 0
   summary:
     drc: not selected
     erc: not selected
     lvs: ran
     pex: not selected
     0 rules skipped
     4 rules clean
     0 violations: 0 errors, 0 warnings
   ```

   The bump on `XA` lands on the bump on `XB`, so `mid` is one net across both dies, and the two resistors match the netlist. The run exits 0.

3. Read a failure. Here `XB` is moved 400 nm along x, with `"origin_nm": [400, 0]`. The bumps still overlap, so they bond, but their centres are 400 nm apart:

   ```sh
   gpurify system shifted.json --reference system.spice
   ```

   ```text
   rules:
     system.unbonded_bump: ran, examined 2 shapes, found 0 violations
     system.bump_offset: ran, examined 1 shapes, found 1 violations
   ...
   violations: 1
     system.bump_offset error at (10200 nm, 0 nm) measured 400 nm against limit 200 nm on shape 0 and shape 0
   summary:
   ...
     1 violations: 1 errors, 0 warnings
   ```

   The bond at (10200 nm, 0 nm) is offset by 400 nm against the 200 nm `max_offset_nm`. Each shape number counts within its own die. The run exits 1.

4. Fix what the rows name, and rerun until the run exits 0. The rows a system run reports:

   | Row | What it flags |
   |---|---|
   | `system.unbonded_bump` | A bump that bonds nothing on the die it faces: missing, or misaligned so far that the bumps do not overlap. |
   | `system.bump_offset` | Two bonded bumps whose centres are further apart than the bond's `max_offset_nm`. |
   | `system.bump_space` | A bump closer than the bond's `min_space_nm` to a bump of the facing die that it does not bond. |
   | `system.open` | A netlist pin on no labelled net, or a netlist net that the assembly leaves in pieces. |
   | `system.short` | An assembled net that carries pins of two netlist nets. |
   | `lvs.*` | The assembled dies against the flattened system netlist, device by device, as [LVS checks](../reference/lvs/README.md) describes. |
   | `system.esd_d2d`, `system.esd_package`, `system.esd_iec` | A bump or package pin with no clamp path to a power and a ground rail (step 5). |

   When the dies come apart, every device and net that crosses the bond fails to pair, so expect `lvs.unpaired_device` and `lvs.unpaired_net` rows beside the `system.unbonded_bump` that causes them. Fix the bump first.

5. To check ESD protection across the assembly, add three things to the system file: a `"package"` face (`{"die": ..., "layer": ...}`, the layer whose bumps are the package pins), an `"esd"` section, and an `"intent"` file on each die whose supplies are the rails. The `esd` section lists `clamps`, the device models that count as a clamp, and optionally `system_pins` with the `system_clamps` that must protect them.

   `system.esd_d2d` checks that each die-to-die bump reaches clamps to a power and a ground rail on its own die, since the bump is exposed before bonding (JEDEC JEP196). `system.esd_package` checks each package pin anywhere in the assembly. `system.esd_iec` checks each pin in `system_pins` through `system_clamps` devices. A clamp is any device of a listed model, however it is wired.

6. For a machine-readable report, add `--format json`.

## What GPurify does not cover

- Pins are compared by name: the label at a die's bump is its pin. A bus wired in the wrong order is a short and an open, even where the devices alone would match.
- The ESD rows check that a protection path exists. They do not check its resistance, the clamps' size, or the board. What a system-level IEC 61000-4-2 discharge delivers to a pin depends on the board's protection and needs simulation.
- A system run runs no DRC, ERC or PEX on the dies. Check each die on its own with `drc`, `erc` and `pex` first.

## Related

- [Command line](../reference/cli.md)
- [Report format](../reference/report.md)
- [Give ERC its design intent](give-erc-design-intent.md)
- [LVS checks](../reference/lvs/README.md)
