# ERC checks

Electrical rule checks (ERC) judge the layout as a circuit: its nets, its devices and the current and
voltage they carry. This page says what an ERC run reads, how it reports, and where each category of
check is described.

## What ERC reads

A design rule looks at shapes. An electrical rule looks at what the shapes make, so GPurify builds the
circuit before any ERC rule runs:

- **Nets** come from the deck's `connect` lines: which layers conduct, which cuts join them, and which
  text labels name them. A net's name in the report and in the design intent is its label.
- **Devices** come from the deck's `device` lines: a transistor, resistor, capacitor, diode, bipolar
  transistor or inductor wherever its marker layer has a shape.
- **Resistance** comes from the deck's `pex` lines, one per conductor. Rules that solve a current or
  a resistance (IR drop, electromigration, the ESD discharge paths, the pin-to-clamp resistance) need a
  `pex` line with a sheet resistance on every conductor they cross. Without it, the rule is refused.

Some facts belong to the chip, not the process: which nets are supplies, at what voltage, and how
much current they carry. ERC reads those from the design intent file, given with `--intent`. Its
fields are listed on [Design intent](../design-intent.md). A rule that needs design intent and gets
none reports `skipped`.

The power-grid rules can also read a simulator's per-terminal currents, given with `--currents`. These
replace the even share of a net's current budget with each device terminal's own current. GPurify
places each terminal on the layout through LVS, so `--currents` needs the reference netlist too:

```sh
gpurify erc top.gds --deck top.deck --intent intent.json --reference top.spice --currents top.emir.json
```

`erc` takes `--reference` only together with `--currents`. To compare the layout with the reference,
run `lvs`.

| Input | Given by | Read by |
|---|---|---|
| Layers, connectivity, devices | The deck (`--deck`) | Every ERC rule |
| Sheet resistance per conductor | The deck's `pex` lines | IR-drop, electromigration and ESD resistance rules |
| Supplies, domains, voltages, current budgets, limits, temperature | The design intent (`--intent`) | The voltage, power-grid and most ESD and latch-up rules |
| Simulated terminal currents | `--currents`, with `--reference` | The power-grid rules |

## How ERC reports

ERC uses the same report as DRC. Each rule in the deck reports one of three outcomes:

- `ran`: the rule looked at the layout. Its violations are listed.
- `skipped`: an input was missing, and the report names it. A rule that needs design intent, run
  without `--intent`, says `no design intent was supplied`.
- `refused`: the input is outside what the rule can decide exactly, for example a conductor with no
  sheet resistance on an IR-drop rule. GPurify does not guess.

Take this deck, a 40 µm by 1 µm metal rail labelled `VDD` that feeds one transistor, with one rule:

```text
grid 5nm
layer diff = gds(2, 0)
layer poly = gds(3, 0)
layer licon = gds(4, 0)
layer li = gds(5, 0)
layer mcon = gds(6, 0)
layer met1 = gds(7, 0)
layer met1_label = gds(7, 5)
layer gate = poly and diff
layer diff_active = diff not poly
connect conductors [diff_active, poly, li, met1]
connect touch_within_layer
connect via licon [diff_active, li]
connect via mcon [li, met1]
connect label met1_label names met1
device mos gate model "nfet" terminals [poly, diff_active, diff_active]
pex diff_active thickness 100nm height 0nm sheet 120ohm dielectric 3.9 area_cap 0aF/um2 fringe_cap 0aF/um
pex poly thickness 200nm height 200nm sheet 48.2ohm dielectric 3.9 area_cap 106aF/um2 fringe_cap 55aF/um
pex licon thickness 500nm height 400nm sheet 152ohm dielectric 3.9 area_cap 0aF/um2 fringe_cap 0aF/um
pex li thickness 100nm height 900nm sheet 12.2ohm dielectric 3.9 area_cap 37aF/um2 fringe_cap 41aF/um
pex mcon thickness 300nm height 1000nm sheet 9.3ohm dielectric 3.9 area_cap 0aF/um2 fringe_cap 0aF/um
pex met1 thickness 400nm height 1300nm sheet 0.125ohm dielectric 3.9 area_cap 25aF/um2 fringe_cap 40aF/um
rule vdd.drop ir_drop()
```

Run without design intent, the rule looks at nothing:

```sh
gpurify erc rail.gds --deck rail.deck
```

```text
rules:
  vdd.drop: skipped, no design intent was supplied, examined 0 shapes, found 0 violations
violations: 0
summary:
  drc: not selected
  erc: ran
  lvs: not selected
  pex: not selected
  1 rules skipped
  0 rules clean
  0 violations: 0 errors, 0 warnings
```

> [!WARNING]
> A `skipped` rule examined nothing. Its zero violations prove nothing, and the run exits with 1.

With an intent file that declares `VDD` a 1.8 V supply drawing 2 mA, and limits its drop to 5 mV,
the rule runs:

```json
{
  "domains":  { "core": { "voltage_mv": 1800 } },
  "supplies": [ { "net": "VDD", "domain": "core", "role": "power" } ],
  "limits":   [ { "net": "VDD", "max_drop_mv": 5, "budget_current_ua": 2000 } ]
}
```

```sh
gpurify erc rail.gds --deck rail.deck --intent intent.json
```

```text
rules:
  vdd.drop: ran, examined 7 shapes, found 5 violations
violations: 5
...
  vdd.drop error layer diff_active at (450 nm, 400 nm) measured 412.8999999999985 mV against limit 5 mV on shape 7
...
```

The transistor's source, at (450 nm, 400 nm), sits 412.9 mV below the supply against a 5 mV limit.
Most of that drop is the single 152 Ω contact, which carries the whole 2 mA.

Each violation line gives the rule, the layer, a point, the measured value and the limit, as a DRC
violation does. The value's unit follows the check: a ratio for antenna rules, a current for
electromigration rules, a voltage for IR drop, a resistance for ESD paths. Some checks add to the
line: an antenna finding names the diode area that would clear it, and a power-grid finding run with
`--currents` names the terminal that loads it most. The check pages show each form.

The run exits with 0 only when every rule ran and none found an error. A rule written
`rule <id> warning <check>` reports its findings as warnings, which do not fail the run.

## ERC check pages

Each page holds one entry per check, in catalog order.

| Page | Catalog rows | What the checks catch | Needs design intent |
|---|---|---|---|
| [Antenna checks](antenna.md) | ERC-A1 to ERC-A15 | Gates that collect too much plasma charge through the metal and cuts joined to them during manufacture | No |
| [Electromigration and IR-drop checks](electromigration.md) | ERC-E1 to ERC-E14 | Wires and cuts carrying more current than their rating, supply nodes that drop too far, and breaks in the power grid | Yes |
| [ESD checks](esd.md) | ERC-C1 to ERC-C14 | Pins with no discharge path, clamps too small or too far, paths too resistive, and unprotected gates and domain crossings | Most rules |
| [Voltage checks](voltage.md) | ERC-F1 to ERC-F14 | Devices stressed beyond their voltage rating, missing level shifters and isolation, and voltage-dependent spacing | Yes |
| [Latch-up checks](latchup.md) | ERC-D1 to ERC-D9 | Wells and diffusions too far from a tap, and guard rings that are missing, narrow or tied to the wrong rail | Some rules |
| [Connectivity checks](classic.md) | ERC-G1 to ERC-G9 | Floating gates and wells, shorts, multiple drivers, soft connections and unconnected pins | Some rules |
| [Programmable electrical checks](perc.md) | ERC-H1 to ERC-H4 | Path checks by net type, analog matching groups and fan-out | Some rules |
| [Planarity checks](planarity.md) | ERC-B1 | Metal density and predicted polish thickness out of range | No |

For why the power-grid numbers come out as they do, see
[How GPurify computes IR drop and electromigration](../../explanation/ir-drop-and-em.md).
