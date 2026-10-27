# LVS checks

Layout versus schematic (LVS) extracts the devices and nets your layout draws and compares them with a reference netlist. A run reports a verdict, match or mismatch, and one error row for each difference it finds.

## What LVS needs

LVS reads three inputs:

- **The deck's connectivity.** The `connect` lines say which layers conduct, which cuts join them and which text layers name nets. Every net LVS compares comes from them.
- **The deck's devices.** Each `device` line recognises one model on a marker layer and lists its terminal layers. LVS compares devices by that model name. The deck also needs `lvs tolerance default`, the parameter tolerance, or LVS is refused.
- **A reference netlist**, given with `--reference`: a SPICE or CDL file, a Spectre file, or a structural Verilog top level beside the SPICE cell library its modules place. See [Reference netlists](netlists.md).

```sh
gpurify lvs <layout.gds> --deck <deck> --reference <netlist>
```

The reference's top subcircuit is compared with the whole layout, flattened. The deck's other `lvs` statements change how devices are merged and paired; [LVS controls](../deck/lvs-controls.md) lists them all.

Every LVS run also runs the extraction checks on the layout alone: floating nets, opens and shorts between labels, and markers no device binds. `gpurify all` and `gpurify drc` report the short check too, with or without a reference.

## The example deck

The pages under this one run their examples on this deck, saved as `example.deck`. It uses SkyWater SKY130's GDS layer numbers and recognises one device of each kind. A `mos` device here lists no bulk terminal, so the reference's bulks are dropped. Each entry shows only the lines it adds.

```text
# The LVS example deck: SKY130's GDS layer numbers, one recogniser of each kind.
grid 5nm
layer nwell = gds(64, 20)
layer diff = gds(65, 20)
layer tap = gds(65, 44)
layer poly = gds(66, 20)
layer rpm = gds(86, 20)
layer licon = gds(66, 44)
layer li = gds(67, 20)
layer mcon = gds(67, 44)
layer met1 = gds(68, 20)
layer via = gds(68, 44)
layer met2 = gds(69, 20)
layer capm = gds(89, 44)
layer dmark = gds(81, 23)
layer pnp = gds(82, 44)
layer indm = gds(81, 30)
layer nsdm = gds(93, 44)
layer psdm = gds(94, 20)
layer li_label = gds(67, 5)
layer met1_label = gds(68, 5)
layer met2_label = gds(69, 5)
layer sd = diff not poly
layer nsd = sd and nsdm
layer psd = sd and psdm
layer ntap = tap and nsdm
layer ptap = tap and psdm
layer poly_c = poly not rpm
layer psub = (diff or tap) not nwell
layer gate = poly and diff
layer ngate = gate and nsdm
layer pgate = gate and psdm
layer rbody = poly and rpm
layer ndiode = nsd and dmark
connect conductors [nsd, psd, ntap, ptap, nwell, poly_c, li, met1, met2]
connect touch_within_layer
connect global psub
connect via licon [nsd, li]
connect via licon [psd, li]
connect via licon [ntap, li]
connect via licon [ptap, li]
connect via licon [poly_c, li]
connect via ntap [ntap, nwell]
connect via ptap [ptap, psub]
connect via mcon [li, met1]
connect via via [met1, met2]
connect label li_label names li
connect label met1_label names met1
connect label met2_label names met2
device mos ngate model "nfet" terminals [poly_c, nsd, nsd]
device mos pgate model "pfet" terminals [poly_c, psd, psd]
device resistor rbody model "rpoly" terminals [poly_c, poly_c] sheet 300ohm
device capacitor capm model "cmim" terminals [met2, met1] area_cap 2fF/um2
device diode ndiode model "dn" terminals [psub, nsd]
device bjt pnp model "pnp" terminals [nwell, psd, psub]
device inductor indm model "ind" terminals [met1, met1] inductance 2nH
lvs tolerance default relative 2%
```

The example layouts draw each device in a row, wire every net on li and met1, and label each net on `met1_label`. The reference netlists write sizes with units (`W=1u L=0.15u`), since the deck states no `netlist_scale`.

## Verdicts

Every comparison ends in one of three verdicts, printed on the report's `lvs:` line.

| Verdict | Exit code | Meaning |
|---|---|---|
| `Match` | 0 | After reduction, every device and every named or connected net pairs one to one, and each pair agrees on kind, model, terminals and parameters. |
| `Mismatch([...])` | 1 | At least one difference. Each one is listed in the brackets and reported as an error row. |
| `Inconclusive(...)` | 1 | The comparison could not decide. `AmbiguousTop`: the reference has more than one subcircuit no other places, so there is no top to compare. `RoundLimit`: matching ran 1000 passes in a row without settling. Neither says the circuits differ. |

An inconclusive run reports the LVS stage as refused, so it never passes. With two top-level subcircuits in the reference, the report reads:

```text
lvs: Inconclusive(AmbiguousTop)
summary:
  drc: not selected
  erc: not selected
  lvs: refused, the comparison did not conclude: AmbiguousTop
```

[Comparison checks](compare.md) describes each verdict and each kind of difference.

## How a mismatch is reported

Each difference is one error row under its own rule id, and one entry in the verdict line:

| Rule id | Verdict entry | Reported when |
|---|---|---|
| `lvs.unpaired_device` | `UnpairedDevice` | A device has no partner on the other side. |
| `lvs.unpaired_net` | `UnpairedNet` | A net with a terminal or a name has no partner. |
| `lvs.terminal_mismatch` | `TerminalMismatch` | A paired device has a terminal on a net that is not its partner's. |
| `lvs.parameter_mismatch` | `ParameterMismatch` | A paired device's parameter is outside the tolerance. |
| `lvs.undeclared_param` | `UndeclaredParam` | The reference card states a parameter the layout does not measure. |
| `lvs.model_mismatch` | `ModelMismatch` | Two devices wired alike carry different models. |
| `lvs.class_imbalance` | `ClassImbalance` | A group of devices or nets that look alike has a different size on each side. |

Each verdict entry says which side it is about, and numbers the devices and nets of each side after reduction. A row on the layout side is placed on the device's marker or on the net's first shape; a reference-side row has no place in the layout. When devices merge before the comparison, the report lists each merge under `lvs merges:`, with the device rows it joined. The rows count devices from 0, in recognition order on the layout and in card order in the reference. When a whole reference instance goes unpaired, `lvs unpaired instances:` names it.

The example below compares the example deck's inverter with a reference that draws its n-channel side as two 1 µm cards in parallel, `M1` and `M3`:

```text
.subckt inv A Y VDD VSS
M1 Y A VSS VSS nfet W=1u L=0.15u
M2 Y A VDD VDD pfet W=2u L=0.15u
M3 Y A VSS VSS nfet W=1u L=0.15u
.ends
```

```sh
gpurify lvs inv.gds --deck example.deck --reference inv_extra.spice
```

```text
violations: 1
...
lvs merges:
  reference parallel: 2 devices of nfet (0, 2) are one
lvs: Mismatch([ParameterMismatch { layout_device: 0, ref_device: 0, param: "w", layout_value: 1e-6, ref_value: 2e-6 }])
```

The reference's cards 0 and 2 merge into one 2 µm transistor, which pairs with the drawn 1 µm one; their `w` differs by 50%, beyond the 2% tolerance.

![Reference inverter with two 1 µm nfets in parallel beside the drawn inverter with one 1 µm nfet, the n-channel side boxed: w 2 µm against 1 µm](../../diagrams/lvs-readme-1.svg)

[How LVS matches devices](../../explanation/how-lvs-matches.md) explains how GPurify pairs the two circuits, and where a difference shows up in the report.

## The check pages

| Page | Covers |
|---|---|
| [Comparison checks](compare.md) | Missing and extra devices and nets, model and parameter differences, pins, unpaired instances, symmetric circuits and the verdict |
| [Device recognition and parameters](devices.md) | What the layout measures on each device kind: W, L, fingers, diffusions, values, flavours, fin counts, layout-dependent effects, size limits |
| [Netlist reduction](reduction.md) | Parallel and series merging, multipliers and fingers, logic-gate recognition, unused devices, strict and relaxed topology |
| [Equivalence, swappable pins and black boxes](equivalence.md) | Interchangeable pins, asymmetric transistors, net-name seeds, black boxes, ignored and dummy devices, split gates |
| [Layout extraction checks](extraction.md) | Labels and ports, implicit joins, soft connections, malformed devices, shorts and their paths, floating nets |
| [Reference netlists](netlists.md) | SPICE and CDL, Spectre, hierarchical references, structural Verilog, multi-die systems |
