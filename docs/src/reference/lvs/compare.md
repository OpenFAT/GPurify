# Comparison checks

These checks compare the layout's extracted circuit with the reference netlist, device by device and
net by net, after both sides are reduced. Each difference is one error row under its rule id, and the
`lvs:` line at the end of the report gives the verdict and lists the differences.

## Missing and extra parts

### LVS-010: Circuit without partner

**What it catches.** A block of the reference netlist that the layout does not draw, or draws
differently. A designer places cells as subcircuit instances (`X` cards); a block left out of the
layout, or a cell swapped for another, leaves a whole group of reference devices with nothing to pair.
A chip with a missing block fails at power-up or works without a function it was specified with.

**How GPurify measures it.** GPurify flattens the reference below its top subcircuit: each `X` card is
replaced by the devices of the subcircuit it calls, all the way down. The flat reference is then
compared with the layout device by device. A missing block is a mismatch like any other, and the
report names each reference instance none of whose devices found a partner (see
[LVS-017](#lvs-017-subcircuit-instance-unpaired)).

![Reference hierarchy with an inverter X1 and a resistor block X2; the layout draws only the inverter, so X2's resistor and nets P and Q have no partner](../../diagrams/lvs-010.svg)

**In the deck.** Nothing to write in the deck beyond its `device` lines. Run LVS with a reference
netlist.

**Example violation.** The layout is one inverter. The reference places that inverter as `X1` and a
resistor block as `X2`:

```text
.subckt inv A Y VDD VSS
M1 Y A VSS VSS nfet W=1u L=0.15u
M2 Y A VDD VDD pfet W=2u L=0.15u
.ends
.subckt load P Q
R1 P Q rpoly w=0.5u l=5u
.ends
.subckt top A Y P Q VDD VSS
X1 A Y VDD VSS inv
X2 P Q load
.ends
```

```sh
gpurify lvs inv.gds --deck example.deck --reference hier_load.spice
```

```text
violations: 4
...
lvs unpaired instances:
  X2 (load): none of its 1 devices has a partner in the layout
lvs: Mismatch([UnpairedDevice { side: Reference, device: 2, model: "rpoly" }, UnpairedNet { side: Reference, net: 2, name: Some("P") }, UnpairedNet { side: Reference, net: 3, name: Some("Q") }])
```

The inverter pairs; the resistor of instance `X2` and its nets `P` and `Q` have no partner in the
layout.

**Status and limits.** Partial. The comparison is flat: GPurify does not match the layout cell by
cell, and it prints no list of which layout cell corresponds to which reference subcircuit. Matching
per cell needs the layout extracted per cell, with the nets that cross a cell boundary as its pins;
the layout is flattened on reading. A reference that calls itself, directly or through other
subcircuits, is refused. So is one nested more than 1024 levels deep, and one that flattens to more
than 2²⁸ devices, nets and instances. Flattening takes time in proportion to what it places.

**Sources.** KLayout LVS `align` and `same_circuits`
(<https://www.klayout.de/doc/about/lvs_ref_netter.html>); Netgen `flatten` and `equate classes`
(<http://opencircuitdesign.com/netgen/reference.html>).

### LVS-011: Device class only on one side

**What it catches.** A device model that one side holds and the other does not: a capacitor in the
schematic with no capacitor drawn, or a layout device of a model the schematic never uses. The circuit
then differs in a whole kind of component, which a simulation of the schematic never sees.

**How GPurify measures it.** Devices pair only with devices of the same kind and model. A device whose
model the other side has none of finds no partner and is reported as `lvs.unpaired_device`, with the
nets only it touches as `lvs.unpaired_net`. The rest of the circuit still pairs.

![Reference with an nfet and a cmim capacitor on nets P and Q; the layout has only the nfet, so the capacitor is unpaired](../../diagrams/lvs-011.svg)

**In the deck.** Nothing to write in the deck beyond its `device` lines. Run LVS with a reference
netlist.

**Example violation.** The layout is one transistor. The reference adds a MiM capacitor on two nets
of its own:

```text
.subckt t G S D P Q
M1 D G S S nfet W=1u L=0.15u
C1 P Q cmim c=10f
.ends
```

```sh
gpurify lvs nfet.gds --deck example.deck --reference nfet_cap.spice
```

```text
violations: 3
...
lvs: Mismatch([UnpairedDevice { side: Reference, device: 1, model: "cmim" }, UnpairedNet { side: Reference, net: 3, name: Some("P") }, UnpairedNet { side: Reference, net: 4, name: Some("Q") }])
```

The reference's `cmim` capacitor has no layout device of its model, so it and its nets `P` and `Q`
are unpaired; the transistor pairs.

**Status and limits.** Implemented. No known limits.

**Sources.** KLayout LVS netlist comparison, device class mismatch
(<https://www.klayout.de/doc/about/lvs_ref_netter.html>); Netgen `equate classes`
(<http://opencircuitdesign.com/netgen/reference.html>).

### LVS-012: Missing or extra device

**What it catches.** A device drawn in the layout and absent from the reference, or written in the
reference and never drawn: a forgotten transistor, a left-over dummy, a deleted keeper. An extra or
missing device changes the circuit's function or loading.

**How GPurify measures it.** After reduction (see [Netlist reduction](reduction.md)), each device must
pair one to one with a device of the same model on the other side. A device left without a partner is
`lvs.unpaired_device`, and each net only it reaches is `lvs.unpaired_net`. Where a group of equivalent
devices or nets has a different count on each side, the group is also reported once as
`lvs.class_imbalance`, with the two counts.

![Reference inverter plus an extra nfet M3 on nets P and Q; the layout draws only the inverter](../../diagrams/lvs-012.svg)

**In the deck.** Nothing to write in the deck beyond its `device` lines. Run LVS with a reference
netlist.

**Example violation.** The layout is an inverter. The reference adds a third transistor, `M3`, wired
as a diode between two nets of its own:

```text
.subckt inv A Y P Q VDD VSS
M1 Y A VSS VSS nfet W=1u L=0.15u
M2 Y A VDD VDD pfet W=2u L=0.15u
M3 Q P P VSS nfet W=1u L=0.15u
.ends
```

```sh
gpurify lvs inv.gds --deck example.deck --reference extra.spice
```

```text
violations: 3
...
lvs: Mismatch([UnpairedDevice { side: Reference, device: 2, model: "nfet" }, UnpairedNet { side: Reference, net: 2, name: Some("P") }, UnpairedNet { side: Reference, net: 3, name: Some("Q") }])
```

The reference's third `nfet` and its nets `P` and `Q` have no partner; the inverter pairs.

**Status and limits.** Implemented. No known limits.

**Sources.** KLayout LVS device mismatch (<https://www.klayout.de/doc/about/lvs_ref_netter.html>);
Netgen (<http://opencircuitdesign.com/netgen/reference.html>).

### LVS-013: Paired device with a different model

**What it catches.** A device wired exactly as its counterpart but of another model: a regular-Vt
transistor drawn where the schematic asks for a low-Vt one, or the reverse. The circuit's topology is
right and its electrical behaviour is not.

**How GPurify measures it.** Devices of different models start apart, so a model swap first leaves one
unpaired device on each side. GPurify then compares again with models set aside. When that pairs every
device and net and the only differences are models, the report is one `lvs.model_mismatch` per such
pair, naming both models. Their parameters are not compared. Otherwise the devices stay unpaired.

![Reference inverter whose lower transistor is written as a pfet, against the layout's nfet in the same place](../../diagrams/lvs-013.svg)

**In the deck.** Nothing to write in the deck beyond its `device` lines. Run LVS with a reference
netlist.

**Example violation.** The layout is an inverter. The reference writes its lower transistor with the
`pfet` model:

```text
.subckt inv A Y VDD VSS
M1 Y A VSS VSS pfet W=1u L=0.15u
M2 Y A VDD VDD pfet W=2u L=0.15u
.ends
```

```sh
gpurify lvs inv.gds --deck example.deck --reference model.spice
```

```text
violations: 1
...
lvs: Mismatch([ModelMismatch { layout_device: 0, ref_device: 0, layout_model: "nfet", ref_model: "pfet" }])
```

Every device and net pairs; the one pair whose models differ is reported once, `nfet` drawn against
`pfet` written.

**Status and limits.** Implemented. A pair is reported as a model mismatch only when models are the
only difference in the whole circuit. With any other difference, the swapped devices are reported as
unpaired.

**Sources.** KLayout LVS netlist comparison, devices paired across device classes
(<https://www.klayout.de/doc/about/lvs_ref_netter.html>).

## Values and wiring

### LVS-014: Parameter mismatch with tolerance

**What it catches.** A device drawn at the wrong size: a transistor's width or length, a resistor's
value or a capacitor's area that differs from what the schematic states. A wrong size shifts currents,
gains and matching, and no structural check sees it.

**How GPurify measures it.** For each paired device, GPurify compares every parameter the reference
card states with the value it measures in the layout (see
[Device recognition and parameters](devices.md)). Two values \\( a \\) and \\( b \\) agree when
\\[ |a - b| \le t_\text{abs} + t_\text{rel} \cdot \max(|a|, |b|) \\]
where \\( t_\text{rel} \\) is the relative tolerance and \\( t_\text{abs} \\) the absolute one. By
default \\( t_\text{rel} \\) is the deck's `lvs tolerance default` and \\( t_\text{abs} \\) is zero.
For example, 1 µm against 1.05 µm differ by 0.05 µm, which is 4.8% of the larger value. The counts
`m`, `nf` and `nfin` agree only when equal. A value outside the tolerance is
`lvs.parameter_mismatch`, with both values in SI units.

![Reference inverter with M1 1.05 µm wide against the layout's 1 µm nfet, apart by 4.8%, more than a 3% tolerance](../../diagrams/lvs-014.svg)

**In the deck.**

```text
lvs tolerance default relative <fraction>
lvs tolerance "<model>" <param> relative <fraction> absolute <value>
lvs ignore_parameter "<model>" <param>
```

```text
lvs tolerance "nfet" w relative 3%
```

Added to [the example deck](README.md#the-example-deck). A row for one model and parameter replaces
the default; its relative and absolute parts add, and a part it leaves out is zero. `lvs
ignore_parameter` leaves a parameter out of the comparison and of merging. Both are described under
[LVS controls](../deck/lvs-controls.md).

**Example violation.** The layout's n-channel transistor is 1 µm wide. The reference states 1.05 µm:

```text
.subckt inv A Y VDD VSS
M1 Y A VSS VSS nfet W=1.05u L=0.15u
M2 Y A VDD VDD pfet W=2u L=0.15u
.ends
```

```sh
gpurify lvs inv.gds --deck example.deck --reference param.spice
```

```text
violations: 1
...
lvs: Mismatch([ParameterMismatch { layout_device: 0, ref_device: 0, param: "w", layout_value: 1e-6, ref_value: 1.05e-6 }])
```

The widths 1 µm and 1.05 µm differ by 4.8% of the larger, more than the 3% the deck allows for `w` of
`nfet`.

**Options.**

| Parameter | Value | Meaning |
|---|---|---|
| `relative` | fraction or percentage | The allowed difference as a share of the larger value. |
| `absolute` | value in the parameter's unit | The allowed difference added to the relative part. |

**Status and limits.** Implemented. A parameter the layout measures and the reference card does not
state is not compared. A parameter the card states and the layout does not measure is reported (see
[LVS-020](#lvs-020-undeclared-parameter)).

**Sources.** KLayout LVS `tolerance` and `ignore_parameter`
(<https://www.klayout.de/doc/about/lvs_ref_netter.html>); Netgen `property` with `tolerance` and
`remove` (<http://opencircuitdesign.com/netgen/reference.html>).

### LVS-015: Missing, extra or miswired net

**What it catches.** A connection that differs between the layout and the reference: a net drawn
open, two nets shorted together, or a terminal wired to the wrong net. A miswired gate or supply
breaks the circuit even when every device is present and sized right.

**How GPurify measures it.** Nets pair by the devices and terminals they connect. A wrong connection
leaves the nets at its two ends unpaired, as `lvs.unpaired_net`. A paired device with a terminal on a
net that does not correspond to its partner's is `lvs.terminal_mismatch`, naming the terminal; the rest
of the circuit pairs. A group of interchangeable nets with a different count on each side is also
`lvs.class_imbalance`.

![Reference nfet with its gate tied to its drain, against the layout's nfet with gate, source and drain on three separate nets](../../diagrams/lvs-015.svg)

**In the deck.** Nothing to write in the deck beyond its `device` lines. Run LVS with a reference
netlist.

**Example violation.** The layout is one transistor with gate `G`, source `S` and drain `D` on three
nets. The reference ties the gate to the drain:

```text
.subckt n G S D
M1 D D S S nfet W=1u L=0.15u
.ends
```

```sh
gpurify lvs nfet.gds --deck example.deck --reference diodeconn.spice
```

```text
violations: 7
...
lvs: Mismatch([UnpairedDevice { side: Layout, device: 0, model: "nfet" }, UnpairedNet { side: Layout, net: 0, name: Some("S") }, UnpairedNet { side: Layout, net: 1, name: Some("G") }, UnpairedNet { side: Layout, net: 2, name: Some("D") }, UnpairedDevice { side: Reference, device: 0, model: "nfet" }, UnpairedNet { side: Reference, net: 1, name: Some("S") }, UnpairedNet { side: Reference, net: 2, name: Some("D") }])
```

The layout has three nets on the transistor and the reference two, so no net and no device pairs.

**Status and limits.** Implemented. No known limits.

**Sources.** KLayout LVS net mismatch (<https://www.klayout.de/doc/about/lvs_ref_netter.html>); Netgen
(<http://opencircuitdesign.com/netgen/reference.html>).

### LVS-016: Pin or port mismatch

**What it catches.** A port of the reference's top subcircuit whose label in the layout is missing,
misspelt or on the wrong net. The cell then connects wrongly when placed: two pins swapped at a pad, or
a pin that the next level up cannot find.

**How GPurify measures it.** Under `lvs ports_by_name`, each reference port pairs only with the layout
net its name labels. A port with no such net, or one whose wiring disagrees with that net's, is
`lvs.unpaired_net`. Port order never matters. Without the statement, names only break ties between
nets that the circuit itself does not tell apart (see
[LVS-018](#lvs-018-symmetric-or-ambiguous-matching)): a misnamed port then passes, and so does a
reference port that nothing in the reference connects.

![Reference inverter with an extra port Z; the layout has no net labelled Z](../../diagrams/lvs-016.svg)

**In the deck.**

```text
lvs ports_by_name
```

Added to [the example deck](README.md#the-example-deck). See [LVS controls](../deck/lvs-controls.md).

**Example violation.** The layout is an inverter labelled `A`, `Y`, `VDD` and `VSS`. The reference
declares a fifth port, `Z`:

```text
.subckt inv A Y Z VDD VSS
M1 Y A VSS VSS nfet W=1u L=0.15u
M2 Y A VDD VDD pfet W=2u L=0.15u
.ends
```

```sh
gpurify lvs inv.gds --deck example.deck --reference openport.spice
```

```text
violations: 1
...
lvs: Mismatch([UnpairedNet { side: Reference, net: 2, name: Some("Z") }])
```

Port `Z` has no layout net labelled `Z`. Without `lvs ports_by_name` the same run reports `lvs: Match`.

**Status and limits.** Implemented. No known limits.

**Sources.** KLayout LVS `flag_missing_ports`
(<https://www.klayout.de/doc/about/lvs_ref_netter.html>); Netgen port matching
(<http://opencircuitdesign.com/netgen/reference.html>); Siemens Calibre LVS `LVS CHECK PORT NAMES`.

## Hierarchy and pairing

### LVS-017: Subcircuit instance unpaired

**What it catches.** A reference instance, an `X` card, whose devices all failed to pair: a block the
layout leaves out or draws wrongly. Naming the instance tells you which block to look at, where a list
of unpaired transistors would not.

**How GPurify measures it.** While flattening the reference, GPurify records each instance it expands:
its path, its cell and the devices it holds. After a mismatch, each reference instance none of whose
devices paired is reported once, as `lvs.unpaired_instance`, with its path and cell under
`lvs unpaired instances:`. Only the outermost such instance is named, not every level inside it. The
verdict itself comes from the flat comparison.

![Reference hierarchy top, X1 (inv) and X2 (bias) holding XR (load) and R1; X2 is named as the outermost unpaired instance](../../diagrams/lvs-017.svg)

**In the deck.** Nothing to write in the deck beyond its `device` lines. Run LVS with a reference
netlist.

**Example violation.** The layout is one inverter. The reference places the inverter as `X1` and a
bias block `X2`, which places the resistor block `XR`:

```text
.subckt inv A Y VDD VSS
M1 Y A VSS VSS nfet W=1u L=0.15u
M2 Y A VDD VDD pfet W=2u L=0.15u
.ends
.subckt load P Q
R1 P Q rpoly w=0.5u l=5u
.ends
.subckt bias P Q
XR P Q load
.ends
.subckt top A Y P Q VDD VSS
X1 A Y VDD VSS inv
X2 P Q bias
.ends
```

```sh
gpurify lvs inv.gds --deck example.deck --reference hier_deep.spice
```

```text
violations: 4
...
lvs unpaired instances:
  X2 (bias): none of its 1 devices has a partner in the layout
lvs: Mismatch([UnpairedDevice { side: Reference, device: 2, model: "rpoly" }, UnpairedNet { side: Reference, net: 2, name: Some("P") }, UnpairedNet { side: Reference, net: 3, name: Some("Q") }])
```

`X2` of cell `bias` is named, not `XR` inside it: it is the outermost instance with no device paired.

**Status and limits.** Partial. Instances are not paired as units. An instance with only some of its
devices unpaired is not named. The layout is flattened on reading, so it has no instances to name.
Where a missing block changes its neighbours' nets, their devices are unpaired too, so an instance
beside the missing one is named with it.

**Sources.** KLayout LVS subcircuit mismatch (<https://www.klayout.de/doc/about/lvs_ref_netter.html>);
Netgen (<http://opencircuitdesign.com/netgen/reference.html>).

### LVS-018: Symmetric or ambiguous matching

**What it catches.** Nothing on its own: this is how GPurify pairs parts that the wiring alone cannot
tell apart, such as the two halves of a differential pair. A wrong choice there would report a false
parameter mismatch, or hide a real one.

**How GPurify measures it.** GPurify pairs devices and nets by how they connect, refining groups of
look-alikes until each holds one part per side. When a group stops splitting with several parts on
each side, GPurify picks one layout part and pairs it with the reference part whose parameters are
closest. For a net, the closest is the pairing that puts the paired transistors' diffusions closest at
each channel end. On a tie, the net whose name its layout label carries wins, then the first. The
choice is a trial: if refinement then shows it wrong, GPurify undoes it and tries the next closest, up
to eight per stall.

![Two nfets on a shared net T on each side; the reference halves are 1.5 µm and 2 µm, the layout's 1 µm and 2 µm, and the closest widths pair](../../diagrams/lvs-018.svg)

**In the deck.** Nothing to write in the deck beyond its `device` lines. Run LVS with a reference
netlist.

**Example violation.** The layout is a differential pair, 1 µm and 2 µm wide, labelled `INP`, `INN`,
`OUTP`, `OUTN` and `T`. The reference names its nets differently, so only the widths tell the halves
apart:

```text
.subckt pair P N X Z T
M1 Z N T T nfet W=2u L=0.5u
M2 X P T T nfet W=1.5u L=0.5u
.ends
```

```sh
gpurify lvs pair.gds --deck example.deck --reference tie.spice
```

```text
violations: 1
...
lvs: Mismatch([ParameterMismatch { layout_device: 0, ref_device: 1, param: "w", layout_value: 1e-6, ref_value: 1.5e-6 }])
```

The 2 µm halves pair, and the 1 µm layout transistor pairs with the 1.5 µm card, the closest: one
mismatch, not two. With `M2` at 1 µm the same run reports `lvs: Match`.

**Status and limits.** Implemented. A trial is judged only against what follows it directly: a wrong
pairing that a later stall exposes is kept, and so is one whose right partner ranks past the eighth.

**Sources.** KLayout LVS `consider_net_names`
(<https://www.klayout.de/doc/about/lvs_ref_netter.html>); Netgen symmetry resolution by property value
(<http://opencircuitdesign.com/netgen/reference.html>); C. Ebeling, "GeminiII: a second generation
layout validation program", ICCAD 1988.

## Verdict and undeclared parameters

### LVS-019: Verdict classes

**What it catches.** Whether the layout matches the reference, and whether the comparison could decide
at all. A run that could not decide must not read as a pass.

**How GPurify measures it.** Every comparison ends in one of three verdicts on the `lvs:` line:

| Verdict | Exit code | Meaning |
|---|---|---|
| `Match` | 0, if nothing else failed | After reduction every device, and every net with a terminal or a name, paired one to one, and every pair agrees in kind, model, terminals and parameters. |
| `Mismatch([...])` | 1 | At least one difference, each listed in the brackets and reported as an error row. |
| `Inconclusive(AmbiguousTop)` | 1 | The reference has no single top: more than one subcircuit that nothing places. LVS is refused. |
| `Inconclusive(RoundLimit)` | 1 | Refinement split groups for more than 1000 passes in a row without settling. LVS is refused, and nothing is said about whether the circuits match. |

Nothing turns an inconclusive comparison into a match. A deck with no `lvs tolerance default` is
refused before comparing, with the message
``the deck states no `lvs tolerance default`, so no parameter tolerance is the deck's``.

![A comparison leads to Match with exit code 0, Mismatch with one row per difference, or Inconclusive when no unique top exists](../../diagrams/lvs-019.svg)

**In the deck.**

```text
lvs tolerance default relative <fraction>
```

The [example deck](README.md#the-example-deck) states `lvs tolerance default relative 2%`, as every
shipped deck does. See [LVS controls](../deck/lvs-controls.md).

**Example violation.** The layout is an inverter. The reference defines two subcircuits and places
neither, so it has no single top:

```text
.subckt inv A Y VDD VSS
M1 Y A VSS VSS nfet W=1u L=0.15u
M2 Y A VDD VDD pfet W=2u L=0.15u
.ends
.subckt buf A Y VDD VSS
M1 Y A VSS VSS nfet W=1u L=0.15u
M2 Y A VDD VDD pfet W=2u L=0.15u
.ends
```

```sh
gpurify lvs inv.gds --deck example.deck --reference twotops.spice
```

```text
violations: 0
lvs: Inconclusive(AmbiguousTop)
summary:
  drc: not selected
  erc: not selected
  lvs: refused, the comparison did not conclude: AmbiguousTop
...
```

Zero violations and still a failed run: LVS is refused, and the exit code is 1. A matching run prints
`lvs: Match` and `lvs: ran`; a mismatch is shown under each entry above.

**Status and limits.** Implemented. To compare one of several subcircuits, make it the only one that
nothing places, for example by removing the others from the file.

**Sources.** KLayout LVS netlist cross-reference status
(<https://www.klayout.de/doc/about/lvs_ref_netter.html>); Netgen comparison result
(<http://opencircuitdesign.com/netgen/reference.html>).

### LVS-020: Undeclared parameter

**What it catches.** A parameter the reference card states that the layout does not measure, such as
a stress parameter `sa` when the deck measures none. Passing it silently would read as "checked" when
nothing was compared.

**How GPurify measures it.** For each paired device, every parameter its reference card states is
looked up among the layout's measured values. One the layout does not measure is reported as
`lvs.undeclared_param`, per device, naming the parameter. A value measured in the layout and not
stated on the card is not compared.

![Reference inverter whose M1 states sa of 0.5 µm; the layout's nfet measures no sa](../../diagrams/lvs-020.svg)

**In the deck.** Nothing to write in the deck beyond its `device` lines. To compare the parameter,
make the deck measure it (for `sa`, `lvs lde`, see [LVS controls](../deck/lvs-controls.md)); to skip it,
write `lvs ignore_parameter "<model>" <param>`.

**Example violation.** The layout is an inverter. The reference states `sa` on its n-channel
transistor:

```text
.subckt inv A Y VDD VSS
M1 Y A VSS VSS nfet W=1u L=0.15u sa=0.5u
M2 Y A VDD VDD pfet W=2u L=0.15u
.ends
```

```sh
gpurify lvs inv.gds --deck example.deck --reference undeclared.spice
```

```text
violations: 1
...
lvs: Mismatch([UndeclaredParam { side: Reference, layout_device: 0, ref_device: 0, param: "sa" }])
```

The card states `sa`, which the example deck does not measure, so the pair is reported rather than
passed.

**Status and limits.** Implemented. No known limits.

**Sources.** GPurify-specific.
