# Reference netlists

LVS reads the reference netlist you give with `--reference` as SPICE or CDL, as Spectre, or as a structural Verilog top level over a SPICE or Spectre cell library. A netlist outside the subset each reader accepts is refused with its file, line and token, and the run stops before any check.

## SPICE, CDL and Spectre

### LVS-070: SPICE and CDL reader

**What it catches.** A reference that GPurify cannot read exactly. The reader accepts `.subckt` and `.ends` (`.end` closes too), the `M`, `Q`, `R`, `C`, `D`, `L` and `X` cards, `+` continuation lines, `*` comment lines and `$` or `;` trailing comments, so CDL's `*.PININFO` lines read as comments. Anything else is refused rather than guessed: `.include`, `.param`, `.global`, `.model` and every other dot card, sources and other element letters, parameters on a `.subckt` line or an `X` card, a card outside every subcircuit, and a device with the wrong number of terminals.

**How GPurify measures it.** The first subcircuit opener names the dialect: `.subckt` is SPICE, `subckt` is Spectre. Only a file with neither is read as Spectre by its `.scs` or `.spectre` name. Card letters and dot keywords are case-blind, parameter names are read lower case, and net and cell names keep their case. A number takes the SPICE scale suffixes, `meg` and `mil` before `m`; an unknown suffix is refused. An `X` card that calls a model a `device` line names is that device, not a subcircuit. An `R`, `C` or `L` card may state its value between its nets and its model (`R1 a b 1k rpoly`). An `R`, `C`, `D` or `L` card that names no model is the deck's one recogniser of its kind, and it is refused when the deck has none of that kind or several.

![CDL inverter text beside the circuit it reads to, MN1 nfet 1 µm and MP1 pfet 2 µm; an .include line below it is boxed as refused](../../diagrams/lvs-070.svg)

**In the deck.** Nothing to write in the deck beyond its `device` lines for most netlists. When the netlist writes bare sizes, as PDK netlists do on their `X` cards, say what unit they are in:

```text
netlist_scale <length>
```

```text
netlist_scale 1um
```

Added to [the example deck](README.md#the-example-deck). With it, `XM1 Y A VSS VSS nfet W=1 L=0.15` is 1 µm by 0.15 µm and matches `inv.gds`. Without it, a bare `W=1` is 1 m, and every size is reported as `lvs.parameter_mismatch`. See [LVS controls](../deck/lvs-controls.md).

**Example violation.** The example inverter, `inv.gds`, against its reference in CDL style: a comment line, a `*.PININFO` line, one card continued on a `+` line, and a `$` comment.

```text
* inverter, CDL style
.SUBCKT inv A Y VDD VSS
*.PININFO A:I Y:O VDD:B VSS:B
MN1 Y A VSS VSS nfet W=1u
+ L=0.15u $ the pull-down
MP1 Y A VDD VDD pfet W=2u L=0.15u
.ENDS
```

```sh
gpurify lvs inv.gds --deck example.deck --reference inv.cdl
```

```text
violations: 0
lvs: Match
```

The same reference with `.include "models.lib"` on its first line is refused:

```sh
gpurify lvs inv.gds --deck example.deck --reference inv_include.spice
```

```text
error: reference inv_include.spice: Unsupported
  line 1: .include
```

The reader names the card it does not read and its line, and the run exits 1 without comparing.

**Status and limits.** Implemented. There is no open, authoritative CDL specification, so the reader follows the SPICE syntax ngspice documents, plus the CDL comment conventions. Included files, `.param` expressions and `.global` nets are not read: write the netlist out flat in one file, its subcircuits and cards with numeric values.

> [!WARNING]
> CDL's `$` extensions are not read. A `$` starts a comment, as in SPICE, so `R1 A B 3k $[rpoly] $W=7u` is a 3 kΩ resistor of the deck's one resistor model with no width, and it matches a 0.5 µm `rpoly` resistor of 3 kΩ. Write the model and sizes in SPICE form: `R1 A B 3k rpoly w=7u`.

**Sources.** ngspice manual, circuit description and scale factors ([ngspice manual](https://ngspice.sourceforge.io/docs/ngspice-manual.pdf)); KLayout `NetlistSpiceReader` ([KLayout reference](https://www.klayout.de/doc/code/class_NetlistSpiceReader.html)).

### LVS-071: Spectre reader

**What it catches.** A Spectre reference GPurify cannot read exactly. The reader accepts `subckt` and `ends` (or `endsubckt`), `model <name> <master>` cards, and instances `name (nets) master params` of a subcircuit, a model or a built-in primitive master, with `\` continuations and `//` comments. Other statements are refused, `simulator lang=spectre`, `include` and `parameters` among them. So is an instance of a primitive master that no `model` card names when the deck has no one recogniser of its kind.

**How GPurify measures it.** Spectre is case-sensitive, and so is the reader: a parameter is compared under the name written. A `model` card's name is the model the instances carry, and its master gives the device kind: `nmos`, `pmos`, `bsim4` and the other MOS masters, `npn`, `pnp` and the bipolar masters, `resistor`, `capacitor`, `diode` and `inductor`. An instance whose master is a primitive itself names no model, so it is the deck's one recogniser of that kind, as a SPICE card with no model is.

![Spectre inverter text beside the circuit it reads to, MN1 nfet and MP1 pfet; an instance of the bsim4 master with no model card is boxed as refused](../../diagrams/lvs-071.svg)

**In the deck.** Nothing to write in the deck beyond its `device` lines. Run LVS with a reference netlist.

**Example violation.** The example inverter against its reference in Spectre:

```text
// inverter, Spectre
model nfet bsim4
model pfet bsim4
subckt inv (A Y VDD VSS)
  MN1 (Y A VSS VSS) nfet w=1u l=0.15u
  MP1 (Y A VDD VDD) pfet w=2u \
    l=0.15u
ends inv
```

```sh
gpurify lvs inv.gds --deck example.deck --reference inv.scs
```

```text
violations: 0
lvs: Match
```

Without the `model` cards, with each instance calling the `bsim4` master directly:

```text
subckt inv (A Y VDD VSS)
  MN1 (Y A VSS VSS) bsim4 w=1u l=0.15u
  MP1 (Y A VDD VDD) bsim4 w=2u l=0.15u
ends inv
```

```sh
gpurify lvs inv.gds --deck example.deck --reference inv_primitive.scs
```

```text
error: reference inv_primitive.scs: NoModel
  line 2: MN1
  the deck has several mos models: nfet, pfet
```

`MN1` names no model, and the deck recognises two MOS models, so the reader refuses to choose one.

**Status and limits.** Implemented. Spectre's control statements are not read: remove `simulator lang=spectre`, `include`, `parameters`, analyses and options before you compare. Write parameter names as the deck's `device` lines measure them, `w` and `l` in lower case. A card written `W=1u` states a parameter `W` that the layout does not measure, reported as `lvs.undeclared_param`.

**Sources.** Cadence Spectre Circuit Simulator reference, netlist syntax (manual not public).

## Hierarchy

### LVS-072: Hierarchical reference flattening

**What it catches.** A reference written as a hierarchy of subcircuits that no flat comparison could read as it stands. GPurify takes the one subcircuit nothing places as the top and expands every instance below it, at any depth, so the layout's flat devices meet the reference's flat devices. A hierarchy that places itself, directly or through other subcircuits, is refused, since it never ends.

**How GPurify measures it.** Each `X` card is replaced by the devices of the subcircuit it calls, all the way down. A flattened device is named by its instance path, a dot and its card name (`X2.M1`), and an inner net by its instance path and net name (`X1.n1`). The top's ports and nets keep their names. A subcircuit called as a device model, or kept whole by `lvs blackbox`, is not expanded. A reference with more than one subcircuit that nothing places has no top, and the comparison ends `Inconclusive(AmbiguousTop)`.

![Hierarchical netlist of cells pd and pu placed in inv, flattened to X1.M1 nfet and X2.M1 pfet; X2.M1 is boxed, w 3 µm against the drawn 2 µm](../../diagrams/lvs-072.svg)

**In the deck.** Nothing to write in the deck beyond its `device` lines. Run LVS with a reference netlist.

**Example violation.** The example inverter against a reference that builds it from a pull-down cell `pd` and a pull-up cell `pu`, the pull-up written 3 µm wide:

```text
.subckt pd D G S
M1 D G S S nfet W=1u L=0.15u
.ends
.subckt pu D G S
M1 D G S S pfet W=3u L=0.15u
.ends
.subckt inv A Y VDD VSS
X1 Y A VSS pd
X2 Y A VDD pu
.ends
```

```sh
gpurify lvs inv.gds --deck example.deck --reference inv_hier_w.spice
```

```text
violations: 1
...
lvs: Mismatch([ParameterMismatch { layout_device: 1, ref_device: 1, param: "w", layout_value: 2e-6, ref_value: 3e-6 }])
```

`inv` is the top. Flattened, its devices are `X1.M1` and `X2.M1`, and reference device 1, `X2.M1`, pairs with the drawn 2 µm pfet but states 3 µm. With `W=2u` the same hierarchy matches.

A hierarchy where `pd` places `pd2` and `pd2` places `pd` again is refused:

```sh
gpurify lvs inv.gds --deck example.deck --reference inv_cycle.spice
```

```text
error: reference inv_cycle.spice: CyclicHierarchy
  subcircuit pd places itself through its instances
```

The reader names the subcircuit where the cycle closes.

**Status and limits.** Implemented. The comparison is flat, as [LVS-010](compare.md#lvs-010-circuit-without-partner) describes; the hierarchy only names the instances. A hierarchy nested more than 1024 levels deep, or one that flattens to more than 2²⁸ devices, nets and instances, is refused. Both limits are counted before anything is expanded.

**Sources.** KLayout LVS netlist flattening and `align` ([KLayout LVS reference](https://www.klayout.de/doc/about/lvs_ref_netter.html)); Netgen `flatten` ([Netgen reference](http://opencircuitdesign.com/netgen/reference.html)).

## Multi-die systems

### LVS-073: System LVS across dies

**What it catches.** An assembly of dies (chiplets on an interposer, a 2.5D or 3D stack) whose bumps do not join what the system netlist joins. A bump that lands on nothing leaves its net open between the dies, and a bump on the wrong net shorts two signals. Each die can pass LVS on its own while the assembly is wired wrongly.

**How GPurify measures it.** `gpurify system` reads a system description and the system netlist. It extracts each die with its own deck, names its labelled nets `<die>.<label>`, and places it: mirrored in x when asked, turned by quarter turns, then moved to its origin. On each bonded pair of faces, two bumps bond when their placed rectangles share area; touching is not bonding. A bump that bonds nothing is `system.unbonded_bump`, at its placed centre, measured 0 against 1. The dies' nets are then merged through the bonds. Each die instance of the system netlist's top pairs with the die of the same name, and its ports are compared pin by pin. A system net whose pins land on two or more assembled nets is `system.open`, one row for each net past the first, measured 2 against 1; a pin no label names is measured 0 against 1. An assembled net that holds pins of two or more system nets is `system.short`. Last, the whole assembly is compared device by device with the flattened system netlist, as a single layout is.

![Two inverter dies joined by bumps on met2; Xb's VSS bump lies 0.8 µm off Xa's, so both are unbonded and VSS is open](../../diagrams/lvs-073.svg)

**In the deck.** Nothing to write in the deck beyond each die's own deck, which needs its `lvs tolerance default`. The bump layer is a layer of that deck, and must be a conductor. The system description is a JSON file:

```text
{
  "dies": [
    { "name": "<instance>", "layout": "<gds>", "deck": "<deck>", "origin_nm": [<x>, <y>], "rotate": <degrees>, "mirror": <bool> }
  ],
  "bonds": [
    { "a": { "die": "<instance>", "layer": "<layer>" }, "b": { "die": "<instance>", "layer": "<layer>" } }
  ],
  "package": { "die": "<instance>", "layer": "<layer>" }
}
```

```sh
gpurify system <system.json> --reference <netlist>
```

**Example violation.** Two dies, `Xa` and `Xb`, each the example inverter with three 0.6 µm bumps on met2. `Xa` bumps its `VSS`, `Y` and `VDD`; `Xb`, mirrored face down onto it, bumps its `VSS`, `A` and `VDD`. Both use the example deck:

```json
{
  "dies": [
    { "name": "Xa", "layout": "die_a.gds", "deck": "example.deck" },
    { "name": "Xb", "layout": "die_b.gds", "deck": "example.deck", "mirror": true }
  ],
  "bonds": [
    { "a": { "die": "Xa", "layer": "met2" }, "b": { "die": "Xb", "layer": "met2" } }
  ]
}
```

The system netlist places one instance per die, named as the die, and joins `Xa`'s output to `Xb`'s input:

```text
.subckt inv A Y VDD VSS
M1 Y A VSS VSS nfet W=1u L=0.15u
M2 Y A VDD VDD pfet W=2u L=0.15u
.ends
.subckt buf IN OUT VDD VSS
Xa IN mid VDD VSS inv
Xb mid OUT VDD VSS inv
.ends
```

```sh
gpurify system system.json --reference buf.spice
```

```text
violations: 0
...
  3 rules clean
  0 violations: 0 errors, 0 warnings
```

All six bumps bond, the eight pins agree and the four devices pair. In `die_b_open.gds`, the `VSS` bump of `Xb` is drawn 0.8 µm off, so it meets nothing:

```sh
gpurify system system_open.json --reference buf.spice
```

```text
violations: 22
...
  system.unbonded_bump error layer met2 at (-1000 nm, -2000 nm) measured 0 against limit 1 on shape 40
  system.unbonded_bump error layer met2 at (-1000 nm, -1200 nm) measured 0 against limit 1 on shape 40
  system.open error layer 65535 at (-1000 nm, -1200 nm) measured 2 against limit 1 on shape 4294967295
...
```

`Xa`'s VSS bump at (−1000 nm, −2000 nm) and `Xb`'s at (−1000 nm, −1200 nm) bond nothing, so the system net `VSS` lands on two assembled nets; the `system.open` row sits at `Xb`'s bump. The 19 rows cut above are the device comparison, which the split supply unpairs.

**Options.** The keys of the system description:

| Key | Value | Meaning |
|---|---|---|
| `dies` | list, at least one | Each die: `name`, `layout` and `deck` are required. A die no instance of the system netlist names is interconnect only, such as an interposer. |
| `intent` | path | A die's design intent, read by the ESD checks. |
| `origin_nm` | `[x, y]`, nanometres | Where the die's origin lands, a whole number of grid units. Default `[0, 0]`. |
| `rotate` | 0, 90, 180 or 270 | Counter-clockwise turn in degrees, after `mirror`. Default 0. |
| `mirror` | `true` or `false` | Reflect the die in x (y to −y), a die flipped face down. Default `false`. |
| `bonds` | list | Pairs of faces `a` and `b` on two different dies, each a `die` and a deck `layer` whose shapes are the bumps. |
| `max_offset_nm` | nanometres | On a bond: the largest centre-to-centre offset of two bonded bumps, reported as `system.bump_offset`. |
| `min_space_nm` | nanometres | On a bond: the least gap to a facing bump it does not bond, reported as `system.bump_space`. |
| `package` | a face | The face that meets the package. Its bumps carry the top's ports, which are then held as pins too. |
| `esd` | object | The package and system-level ESD checks, described with the ERC checks. |

**Status and limits.** Partial. Every bump must be a rectangle, and every die must share one grid; otherwise the run is refused. A bump's size is not checked, and 3D parasitics across the bond are not extracted. The report lists the rows and the summary, without a `rules:` block or an `lvs:` verdict line. Every instance the system netlist's top places must be a die of the description.

**Sources.** Siemens Calibre 3DSTACK (fact sheet 82850-D2, 2022; manual not public).

## Structural Verilog

### LVS-075: Structural Verilog reference netlist

**What it catches.** A digital top level written in Verilog over a cell library in SPICE or Spectre, as a synthesis or place-and-route flow writes it. GPurify reads the IEEE 1364-2005 structural subset: module ports in either style; `input`, `output`, `inout`, `wire`, `supply0` and `supply1` with constant ranges; `assign` between nets; instances by name or in order; bits, part selects and concatenations; escaped identifiers. It refuses anything else with its line: compiler directives such as `` `ifdef ``, constants such as `1'b0`, parameters, instance arrays and behavioural code.

**How GPurify measures it.** Give `--reference` once for the cell library and once for each `.v` file; a file ending `.v` is Verilog, and at most one file is SPICE or Spectre. Each module becomes a subcircuit of instances, each instance placing a library cell or another module. An `assign` makes its two nets one, a bus is its bits (`d[3]`, most significant first), and an unconnected port is a net of its own, named `<instance>.<port>`. A module with no instance and no `assign`, named as a library cell with as many ports, declares that cell and adds nothing. The top is the one module no other module places; it is then flattened like any hierarchy.

![Verilog module top placing the SPICE cell inv as X1, read to X1.M1 nfet and X1.M2 pfet; a connection to the constant 1'b0 is boxed as refused](../../diagrams/lvs-075.svg)

**In the deck.** Nothing to write in the deck beyond its `device` lines. Run LVS with a reference netlist.

**Example violation.** The example inverter against a Verilog top level, `top.v`, that places the cell `inv` of `inv.spice`:

```text
// structural top level over the SPICE cell inv
module top (A, Y, VDD, VSS);
  input A;
  output Y;
  inout VDD, VSS;
  inv X1 (.A(A), .Y(Y), .VDD(VDD), .VSS(VSS));
endmodule
```

```text
.subckt inv A Y VDD VSS
M1 Y A VSS VSS nfet W=1u L=0.15u
M2 Y A VDD VDD pfet W=2u L=0.15u
.ends
```

```sh
gpurify lvs inv.gds --deck example.deck --reference inv.spice --reference top.v
```

```text
violations: 0
lvs: Match
```

The same top over the Spectre library `inv.scs` matches too. Tied to a constant instead, `.VSS(1'b0)` on line 5 of `top_const.v`, it is refused:

```sh
gpurify lvs inv.gds --deck example.deck --reference inv.spice --reference top_const.v
```

```text
error: reference top_const.v: Unsupported
  line 5: the constant 1'b0 in a connection
```

A constant names no net, so the reader refuses it rather than invent one. Connect the pin to a supply net of the module.

**Status and limits.** Implemented. Power pins must be written as ordinary ports: a netlist that guards them with `` `ifdef USE_POWER_PINS `` is refused at the directive. An instance that leaves its power ports unconnected (`inv X1 (.A(A), .Y(Y));`) still matches the example inverter: each open port is a net of its own, such as `X1.VDD`, and pairs by its connections.

**Sources.** Netgen `readnet verilog` ([Netgen reference](http://opencircuitdesign.com/netgen/reference.html)); Siemens Calibre `v2lvs`; IEEE 1364-2005, Verilog Hardware Description Language.
