# LVS controls

The `lvs` statements change how LVS compares the layout with the reference netlist: how far a
parameter may differ, which pins and devices are interchangeable or left out, and which nets are
paired by name. Most apply to the devices of one model, which a `device` statement declares. What
each comparison reports is on the [LVS checks](../lvs/README.md) page.

```text
lvs tolerance default relative 2%
lvs tolerance "nfet" w relative 1%
lvs tolerance "nfet" l relative 0.5% absolute 5nm
lvs tolerance "rpoly" r absolute 10ohm
lvs ignore_parameter "nfet" as
lvs asymmetric "pfet"
lvs permute "cmim" top bottom
lvs ignore "sky130_fd_pr__decap"
lvs ignore_shorted "nfet"
lvs ports_by_name
lvs range "nfet" w >= 420nm <= 100um
lvs topology relaxed
lvs connect_implicit "VDD*"
lvs connect_explicit "VSS" "GND"
lvs max_res 1Mohm
lvs min_caps 10aF
lvs same_nets "OUT_PAD" "OUT"
lvs count "npn" <= 4000
lvs recognize_gates
lvs split_gates
lvs lde "nfet" od diff max 10um well nwell scref 950nm
lvs blackbox "sram_*"
lvs filter_unused ae af ag c u
lvs supply "VDD" "VSS"
netlist_scale 1um
```

A model is written in quotes. Every control that names a model needs a `device` statement for it,
except `lvs ignore` and `lvs ignore_shorted`. Parameter names are case-blind: `W` and `w` are one
parameter.

## Tolerances

```text
lvs tolerance default relative <fraction>
lvs tolerance "<model>" <param> [relative <fraction>] [absolute <value>]
```

`lvs tolerance default` sets how far apart the layout and reference values of every parameter
without a row of its own may be and still agree:

\\[ |a - b| \le r \cdot \max(|a|, |b|) \\]

where \\( a \\) and \\( b \\) are the two values and \\( r \\) the fraction. With
`relative 2%`, a 600 nm layout width agrees with a reference width from 588 nm to 612 nm.

LVS needs the default: a deck that states none has LVS refused, since no tolerance is every
foundry's. The shipped decks state `2%`. It is stated at most once.

A row for one model and parameter replaces the default for it:

\\[ |a - b| \le \mathit{absolute} + \mathit{relative} \cdot \max(|a|, |b|) \\]

Give `relative`, `absolute` or both; a part left out is zero, so `absolute 10ohm` alone allows
10 Ω and nothing relative. `relative` is a fraction from 0 to 1, or a percentage. `absolute` is
zero or more, in the parameter's unit:

| Parameter | Unit of `absolute` |
|---|---|
| `w`, `l`, `ps`, `pd`, `pe`, `perim` | A length |
| `area`, `as`, `ad`, `ae` | An area |
| `r` | A resistance |
| `c` | A capacitance |
| `ind` | An inductance |
| `m`, `nf`, `nfin` | A bare count |

Any other parameter takes `relative` only. A parameter has at most one row per model. Counts (`m`,
`nf`) and a fin count (`nfin`) are whole numbers and agree only exactly under the default.

## Ignored parameters

```text
lvs ignore_parameter "<model>" <param>
```

Leaves a parameter out of the comparison for one model, as KLayout's `ignore_parameter` and
Netgen's `property ... remove` do. It is dropped from both sides before devices merge, so it is
never compared and never stops a merge. `m` counts devices and cannot be ignored, and an ignored
parameter cannot also have a tolerance row. The `asap7` deck ignores `w` on its FinFETs, which are
sized by `nfin`.

## Asymmetric transistors

```text
lvs asymmetric "<model>"
```

Declares a transistor whose source and drain are not interchangeable, such as an LDMOS. Its source
pairs only with a reference source and its drain with a drain. Such transistors merge in parallel
only source on source and drain on drain, and never in series. The model must be a `mos`.

## Interchangeable pins

```text
lvs permute "<model>" <pin> <pin>
```

Makes two pins of the model's devices interchangeable, as Netgen's `permute` and KLayout's
`equivalent_pins` do: a symmetric capacitor's plates, or a bipolar whose emitter and collector may
be wired either way.

| Kind | Pins |
|---|---|
| `mos` | `gate`, `source`, `drain`, `bulk` |
| `bjt` | `base`, `emitter`, `collector` |
| `resistor` | `end_a`, `end_b` |
| `capacitor` | `top`, `bottom` |
| `diode` | `anode`, `cathode` |
| `inductor` | `end_a`, `end_b` |

Pins already interchangeable stay so, and permutations chain: permuting `gate` with `source` makes
gate, source and drain all interchangeable. Devices whose interchangeable pins are other than a
transistor's source and drain merge in parallel either way round, and never in series. A pin
cannot be permuted with itself, and an asymmetric transistor's source and drain cannot be
permuted.

## Devices left out

```text
lvs ignore "<model>"
lvs ignore_shorted "<model>"
lvs max_res <resistance>
lvs min_caps <capacitance>
lvs filter_unused <option> ...
lvs supply "<net>" ...
```

**`lvs ignore`** leaves every device of the model out of LVS on both sides, as Netgen's
`ignore class` does: fill, decap or tap cells one side draws and the other does not state. A net
only those devices touched is left out too, unless it is a reference port or carries a layout
label. The model need not be declared, since a reference may hold devices the layout has no
recogniser for. The layout's own checks still see the devices.

**`lvs ignore_shorted`** leaves out only the model's dummies: each device whose every compared
terminal is on one net, as Netgen's `ignore shorted` does. Where the deck extracts no bulk, a
transistor with its gate, source and drain on one net is a dummy whatever its reference bulk is.

**`lvs max_res`** and **`lvs min_caps`** leave out, on both sides, every resistor above that
resistance and every capacitor below that capacitance, as KLayout's `max_res` and `min_caps` do.
Such a device is taken for an open. The layout's value is the one its `sheet`, `area_cap` or
`fringe_cap` gives (see [Devices](devices.md#what-lvs-measures)), and a device with no value to
read stays. Each is stated once, positive.

**`lvs filter_unused`** leaves out each layout transistor wired so that it does nothing, as
Calibre's `LVS FILTER UNUSED OPTION ... LAYOUT` does for the options public sources define
(US 8,751,985 B1):

| Option | Leaves out a transistor with |
|---|---|
| `ae` | Source, drain and gate all floating |
| `af` | Source and drain tied together |
| `ag` | Every pin tied together, bulk included |
| `c` | The gate on a supply net, and the source or the drain floating |
| `u` | Source and drain both floating |

A pin floats when its net holds no other terminal and carries no label. Each transistor is judged
once, as drawn, and the reference is not filtered. Give the options in one statement, each once.

**`lvs supply`** names the power and ground nets the `c` option reads, by layout label, as
Calibre's `LVS POWER NAME` and `LVS GROUND NAME` together. `filter_unused c` needs at least one.
Several `lvs supply` lines add up; a name is stated once.

## Black boxes

```text
lvs blackbox "<cell pattern>"
```

Compares a cell by its pins alone, its contents ignored on both sides, as KLayout's
`blank_circuit` and Netgen's black boxes do: a macro whose schematic is not at hand, or a fixed
foundry cell such as a SkyWater VPP capacitor. The pattern matches whole cell names, `*` any run of
characters and `?` one, case included; `[`, `]`, `{`, `}` and `\` are refused. Give one statement
per pattern. A pattern may not match a `device` model.

- **On the layout,** each placement of a matching cell is one device. Its pins are the cell's own
  text labels on a label layer, each on the net of the shape it sits on. Every device drawn wholly
  inside the placement's extent leaves the comparison. The cell's own wiring stays in the nets.
- **On the reference,** each `X` call of a matching subcircuit is one device on the call's nets.
  The subcircuit must be defined; an empty `.subckt` with its ports is enough.

A pin pairs only with the port of its name, so a pin with no matching port, or a port with no pin,
is a mismatch. Black boxes never merge in parallel. See
[issue 9](https://github.com/OmarSiwy/GPurify/issues/9) for what black boxes do not cover yet.

## Ports and nets paired by name

```text
lvs ports_by_name
lvs same_nets "<layout label>" "<reference net>"
```

**`lvs ports_by_name`** holds each port of the reference's top cell to the layout net its name
labels, as KLayout's `flag_missing_ports` does, so swapped pad labels or a missing label are
reported rather than matched by structure. Without it, names only break ties between nets nothing
else tells apart.

**`lvs same_nets`** pairs the layout net labelled with the first name with the reference net of
the second, which need not be a port, as KLayout's `same_nets!` does. The two pair with each other
and no other net. It is a seed: it never turns a mismatch into a match. Each net is named by one
row at most; under `lvs ports_by_name`, a port's own name wins.

## Must-connect nets

```text
lvs connect_implicit "<label pattern>"
lvs connect_explicit "<label>" "<label>" ...
```

**`lvs connect_implicit`** declares must-connect nets, as KLayout's `connect_implicit` does: layout
nets whose label matches the pattern (`*` any run of characters, `?` one) are one net for the
comparison with every other net of that label, as rails joined only above this layout are.

**`lvs connect_explicit`** joins the nets labelled with any of the two or more names.

The layout keeps its open: `lvs.label_conflict` still reports it, as a warning rather than an
error. See [issue 7](https://github.com/OmarSiwy/GPurify/issues/7).

## Merging by value

```text
lvs topology strict
lvs topology relaxed
```

`strict`, the default, never combines values: two capacitors in parallel are one of the same value
with `m=2`. `relaxed` lets parallel and series passives match by value, as Netgen's
`property topology relaxed` does:

- **In parallel,** a resistor, capacitor, diode or bipolar whose reference card states its value
  (`r`, `c`, `area`, `ae`) merges with others of its model on the same nets into one of the
  combined value. Resistances and inductances combine harmonically (two of 200 Ω are one of
  100 Ω), the rest add (two of 0.5 fF are one of 1 fF). A card's `m` folds into the value first.
- **In series,** a resistor, capacitor or inductor stating its value merges with another of its
  model through a net only the two touch and that is no port. Resistances and inductances add,
  capacitances combine harmonically. A resistor's `w` must agree, and a capacitor's plates must
  chain top to bottom unless `lvs permute` makes them interchangeable. Diodes and bipolars never
  merge in series.

A device that states no value keeps its count. The topology is stated at most once.

## Logic gates and split stacks

```text
lvs recognize_gates
lvs split_gates
```

**`lvs recognize_gates`** lets a logic gate's inputs be wired in any order, as Silvaco Guardian
LVS's logic gate recognition does. Transistors of one model and identical sizes, each on a gate of
its own, stacked in series through nodes nothing else touches and that carry no label, or set in
parallel on one source and drain, become one device whose gates are interchangeable. A NAND's stack
in another order then matches, as does a NOR's. Transistors of different sizes never merge. It is
off by default: in an analog circuit a stack's order is part of the design.

**`lvs split_gates`** joins the fingers of a stack drawn with inner nets of their own, as
KLayout's `split_gates` does. A chain is transistors in series between two nets through nets that
join exactly two channel ends and nothing else. Two chains between the same two nets that agree
position by position in model, gate and bulk nets and `l` are fingers of one stack, and their
inner nets are joined. It is off by default.

## Device limits

```text
lvs range "<model>" <param> [>= <min>] [<= <max>]
lvs count "<model>" [>= <min>] [<= <max>]
```

**`lvs range`** holds every layout device of the model to bounds on what is drawn, as a foundry
states each device's legal sizes. `w`, `l`, `perim`, `ps`, `pd` and `pe` take lengths; `area`,
`as`, `ad` and `ae` areas; `nf` and `nfin` counts. Give `>=`, `<=` or both; a value at a bound is
legal. A device out of range is reported as `lvs.param_range` on its marker. A device whose
parameter could not be measured makes the row refused rather than passed.

**`lvs count`** holds the number of layout devices of the model to bounds, as IHP SG13G2's
recommended rules allow 4000 `npn13G2` emitters. Bounds are whole numbers, and a count at a bound
is legal. A count out of bounds is reported as `lvs.device_count`. A device is one recognised
marker, so a bipolar with several emitters counts once. Each model has one row at most.

## Layout-dependent effects

```text
lvs lde "<model>" od <layer> max <length> [well <layer> scref <length>]
```

Measures BSIM4's layout-dependent effect parameters on every transistor of the model, so a
post-layout reference that states them is compared. The keys come in any order, each once.

- `sa` and `sb`: the distances from the gate's two ends to the edges of the active area `od`.
  Where that edge is not straight, the effective distance from BSIM4's \\( 1/(SA + L/2) \\)
  averaged over the gate's width. They are compared as a pair, smaller first, since BSIM4's stress
  model reads only their inverse sum.
- With `well`: `sca`, `scb` and `scc`, the well-proximity integrals, from the median distance
  between each gate edge and the first well edge beyond it, with the model's `scref`.

A distance past `max` reads as `max`. `od` and `max` are required, `well` and `scref` go together,
and the model must be a `mos`. The gate must be one rectangle inside the active area, or nothing
is measured. Every value here is the deck's to state; no foundry value is built in.

## Netlist scale

```text
netlist_scale <length>
```

`netlist_scale`, at most once, says what unit the reference netlist's bare sizes are in, as SPICE's
`.option scale` does. With `netlist_scale 1um`, `XM1 d g s b nfet W=0.42` is 0.42 µm wide. A bare
length (`w`, `l`, `ps`, `pd`, `pe`, `perim`) is multiplied by the scale and a bare area (`area`,
`as`, `ad`, `ae`) by its square. A value with a suffix (`w=0.42u`) is absolute, and `M`, `R`, `C`
and the other primitive cards are never scaled. Without the statement a bare value is in metres,
as SPICE reads it. The `sky130` deck states `netlist_scale 1um`, since its netlists write sizes in
µm.
