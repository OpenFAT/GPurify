# Running GPurify

```sh
gpurify <command> <layout.gds> --deck <process.deck> [options] > report
```

| Command | Checks | Needs |
|---|---|---|
| `drc` | Design rules: width, spacing, enclosure, area, density, grid, angle, vias | the deck |
| `erc` | Electrical rules: antenna, ties, floating gates and wells, shorts, power grid | the deck; `--intent` for the voltage, ESD and power-grid rules; `--currents` with `--reference` for simulated currents |
| `lvs` | The layout's devices and connections against your schematic | `--reference <netlist>` |
| `pex` | Parasitic resistance and capacitance; inductance for field-solved nets | the deck's `pex` lines |
| `all` | All four | a check whose input is missing is reported as skipped, never as passed |
| `lib` | Nothing: writes a macro's Liberty files, see [liberty.md](liberty.md) | `--spec`, `--output-dir` |
| `xor` | Two layouts against each other: every region where a layer differs, see [below](#comparing-two-layouts) | a second layout: `gpurify xor <layout> <other> --deck <deck>` |
| `fill` | Nothing: writes the layout with density fill added, then reports DRC on it, see [below](#editing-a-layout) | the deck's `fill` lines; `gpurify fill <layout> <output.gds> --deck <deck>` |
| `enhance` | Nothing: writes the layout with redundant cuts and widened straps added, then reports DRC on it, see [below](#editing-a-layout) | the deck's `via_redundancy` rules and `widen` lines; `gpurify enhance <layout> <output.gds> --deck <deck>` |
| `system` | Several dies as one assembly: system LVS and package and system ESD, see [below](#multi-die-systems) | a system file in place of the layout, `--reference <system netlist>`; no `--deck` |
| `compare` | Two parasitic netlists (SPEF or DSPF) against each other, net by net, see [below](#comparing-two-parasitic-netlists) | `gpurify compare <reference> <candidate> [--spec <compare.json>]`; no layout or deck |

## Options

The options are the files a run reads, the report's form, and one choice of
method, `--quasistatic`. Everything else is stated where it already lives:
the grid is the layout's own (its GDS `UNITS` record); layers to skip, the
temperature and the extra report lines are in the deck (`ignore gds(L, D)`,
`temperature`, `report`, see [deck.md](deck.md)); `lib`'s accuracy is in its
spec ([liberty.md](liberty.md#the-spec)) and `compare`'s tolerance in its
own. The report goes to standard output.

| Option | Meaning |
|---|---|
| `--deck <file>` | The process deck. Required. See [deck.md](deck.md). |
| `--reference <file>` | The schematic netlist for LVS (SPICE or Spectre). Repeat it to give a structural Verilog top level (`.v`) beside the SPICE or Spectre cell library its modules place; see below. |
| `--intent <file>` | Design intent: supply voltages and per-net limits. See below. |
| `--currents <file>` | A simulator's per-terminal currents (`espice-emir/1`) for the power-grid rules, placed on the layout through LVS. `erc` and `all`; needs `--reference`. See [below](#simulated-currents). |
| `--format text\|json\|spef\|dspf` | Report format. `spef` and `dspf` need a `pex` run. Default `text`. |
| `--quasistatic <net>` | Field-solve this net's capacitance and inductance instead of using the closed-form estimate. Repeat for more nets. |
| `--lef <file>` | A LEF a DEF layout reads (technology first, then cells). Repeat for more. Only with a `.def` layout. |

A flag that has moved is refused with where it went: `--p2p`, `--coupling`
and `--cluster` are the deck's `report` lines (see
[below](#point-to-point-and-net-to-net) and
[deck.md](deck.md#reports)), `lib`'s `--accuracy` is the spec's `accuracy`
field, and `compare`'s `--tolerance` is its spec's `tolerance` field.

A shape on a GDS layer the deck neither declares nor ignores refuses the
layout, naming the layer. A layout whose database unit is not a whole fraction
of a micrometre is refused too.

### A DEF layout

A layout named `*.def` is a placed-and-routed design: its routing (wires,
vias, special nets), its pins, its fill and every placed component's LEF
abstract (pin and obstruction shapes) are drawn on the deck's layers and
checked as a GDS would be. The grid is the DEF's `UNITS DISTANCE MICRONS`.
Each LEF layer is the deck layer of the same name, so name the deck's
layers as the LEF names them; a LEF layer the deck does not have refuses
the layout. Every routed shape carries its DEF net's name, through the
deck's `connect label` rows, so a net DEF draws in two pieces is an open
and two nets whose shapes touch are a short, as for labelled GDS. The
reader is LEF/DEF 5.8's subset that draws geometry; what it does not read
is refused with its line, never skipped
([`gpurify_ingest::lefdef`](../crates/ingest/src/lefdef/mod.rs)).

Since every block is drawn as its LEF abstract, `drc` on a DEF checks the
top-level routing against the blocks' pins and obstructions (interface
DRC). It also runs six integration checks on the design itself, each
reported like a rule: `def.fill_outside_die` (a `FILLS` shape not wholly
inside the `DIEAREA`), `def.component_outside_die`,
`def.component_overlap` (two placed components overlapping, `COVER`
macros such as bumps aside), `def.off_site` (a `CORE` cell whose
placement point is no site of a `ROW`), `def.pin_off_track` (a DEF pin
whose centre is on no `TRACKS` of its layer) and
`def.off_manufacturing_grid` (a vertex off the LEF `MANUFACTURINGGRID`).

## Reading the report

Every rule in the deck reports one of three outcomes, and the count of shapes
it examined:

- **ran**: the rule looked at your layout. Its violations are listed.
- **skipped**: the rule could not run, and the reason is given: the layer it
  names holds no geometry, it needs design intent you did not supply, or the
  deck is staged and an earlier stage found errors (see
  [deck.md](deck.md#stages)).
- **refused**: the input is outside what the rule can decide correctly, for
  example a 45° shape on a rectilinear check. GPurify will not guess.

A deck with waivers (`waive` lines, see [deck.md](deck.md#waivers)) lists
the violations its waiver shapes cover after the others, under `waived`
(the JSON report's `waived` key); they do not fail the run.

Read the skipped and refused counts before the violation count. A skipped
rule looked at nothing, so zero violations from it proves nothing, and the run
does not pass.

```
rules:
  m1.1: ran, examined 1 shapes, found 1 violations
  m1.2: ran, examined 0 shapes, found 0 violations
  tap_distance: skipped, the layer it names holds no geometry, examined 0 shapes, found 0 violations
violations: 1
  m1.1 error layer met1 at (40 nm, 500 nm) measured 80 nm against limit 140 nm on shape 0
summary:
  drc: ran
  1 rules skipped
  1 rules clean
  1 violations: 1 errors, 0 warnings
```

Each violation gives the rule, the layer by its deck name (JSON has
`"layer_name"` beside the numeric `"layer"`), a point on the offending shape,
what was measured, the limit it broke and the shapes involved. An LVS or
system finding sits on no layer and may name no shape: the text line then
leaves out that clause, and JSON writes `null` for it.

The JSON report ends with the same summary: `"summary"` holds `drc`, `erc`,
`lvs` and `pex`, each `{"status": "ran" | "not_selected" | "skipped" |
"refused"}` with a `"why"` for a skip or refusal, then `rules_skipped`,
`rules_clean`, `violations`, `errors` and `warnings`. Each entry in `"runs"`
names its stage in `"domain"`.

## Comparing two layouts

```sh
gpurify xor before.gds after.gds --deck <process.deck> > report
```

`xor` reads both layouts against one deck and compares every drawn layer the
deck declares, as KLayout's `xor` does: it reports each region where exactly
one of the two has material, with its area, as a violation of the rule
`xor.<layer>`. A layer's measured areas add up to the area the layouts
disagree on, so on a cut layer it is the cut area one of them gained or lost:
SkyWater's IR-drop rules (`ct.irdrop`, `via.irdrop`) compare that between the
aluminium and the slotted copper database of a product. Two identical
layouts pass. A layer with a shape `xor` cannot compare exactly, such as a 45°
edge, is refused. Both layouts must be on the same grid; derived layers and
text labels are not compared. It takes `--format text` or `json`.

`xor` does not hold a via array's change in cut area to a tolerance by its
number of cuts, as those rules go on to do. The deck rule
`cut_area_change(pre, post, lower, upper; cuts: [..], change: [..])` does,
with both databases' cuts streamed into one layout on two layers, and the
connector and the tolerances the deck's: their text leaves both unsettled.

## Editing a layout

```sh
gpurify fill layout.gds filled.gds --deck <process.deck> > report
gpurify enhance layout.gds enhanced.gds --deck <process.deck> > report
```

Two commands edit a GDS layout instead of only checking it, each as the
deck configures it: no option changes what they do. Each writes the edited
layout to the second file, the input's records unchanged and the new
boundaries added to its top cell, says on standard error what it added,
and then reports `drc` on the file it wrote, with `drc`'s exit code, so a
run that exits 0 wrote a layout that passes the deck.

`fill` draws density fill (dummy metal) for each `fill` line of the deck
([deck.md](deck.md#layout-edits)): squares of the line's size and spacing
on its fill layer, kept away from the layers it avoids, until every window
of each `density` and `global_density` rule on its density layer is at its
minimum, never over a maximum. A window with no room left stays short, and
the report says so.

`enhance` adds a second cut beside each single-cut via that a
`via_redundancy` rule of the deck measures, where its definition finds
room, and where it finds none, beside the cut with each metal extended
under it by the margin it already leaves round the via; and it widens the
straps each `widen` line names. A cut or patch, or a strap's side, that
would touch another net is never tried, and one that adds a DRC finding
the input did not have is taken back, so the output has no finding the
input lacked and the redundant-via rate does not fall.

A layout edited in memory, by a router or an editor, can be checked again
after each edit without a full run: `gpurify::engine::incremental`
re-checks only the clusters of shapes an edit reaches and keeps the rest
of the previous findings, giving what a full run gives. It is a library
interface; the command line has no saved state to start from.

## LVS reduction

Before matching, both sides are reduced, mostly the way netgen reduces them
(the differences are listed below):

- **Parallel:** devices of one model with every terminal on the same nets
  become one device. Source and drain are interchangeable, except on a
  model the deck declares `lvs asymmetric` (see
  [deck.md](deck.md#lvs-controls)), and so are a resistor's ends and any
  pins the deck declares with `lvs permute`. For transistors, W and `nf`
  are summed, and every other parameter, L included, must agree. Any other device keeps its value and
  counts: two equal capacitors in parallel are one with `m=2`, which matches
  a card with `m=2` but not one card of twice the capacitance, unless the
  deck relaxes the topology (`lvs topology relaxed`), when they combine by
  value. A transistor
  whose card states no W has no width to sum and counts the same way: two
  unsized transistors in parallel match a card with `m=2`, not a card
  without it. A transistor's source and drain diffusions (`as`, `ad`, `ps`,
  `pd`) are summed with its W, each on its own net, whichever end each
  finger calls its source.
- **Series:** transistors stacked through a node nothing else touches, with
  their gates strapped, become one device whose L is the sum, if every other
  parameter agrees. An asymmetric transistor never merges in series. Both
  must state L: with no length to add, two transistors in series stay two,
  so a stack does not match one unsized transistor.
  Transistors stating a diffusion do not merge in series: the diffusion
  between them would vanish, and no rule says what becomes of it.
- **Multiplier:** a transistor card's `m` multiplies its `W` and diffusions
  where it states a W, and `m` is then dropped (`nf` is untouched). Any other card's `m`, an
  unsized transistor's included, is its count of devices in parallel, so `m=2` matches two drawn devices and not one. `m=1` is the
  same as no `m`, and a card without `m` is one device whatever other cards
  state.

The parameter names are `w`, `l`, `nf` and `m`. Each merge needs only what
it adds: transistors stating W merge in parallel whether or not anything
states L, and transistors stating L merge in series whether or not anything
states W. The report lists every merge
under `lvs merges:` with the device rows it joined, so a paired device can be
traced back to what was drawn.

Where netgen (1.5.323) differs, given the setup that otherwise states these
rules (`tests/exhaustive/lvs/netgen.rs`, which checks every verdict against
netgen's):

- netgen never merges transistors in series, even with `series enable`, so a
  stack matches one long transistor here and not in netgen;
- netgen's `l critical` merges parallel transistors whose L agree within its
  tolerance; here L must be equal;
- netgen measures a parameter's difference against the mean of the two
  values, and this tool against the larger, so netgen's `2t/(2 − t)`
  (2.0202 % for 2 %) is this tool's `t`;
- netgen matches the top cell's pins by name; this tool uses a net's label
  only to choose among nets nothing else tells apart (as KLayout's
  `consider_net_names`), and compares port names only when the deck asks
  (`lvs ports_by_name`);
- when the deck extracts no bulk, the reference's bulks are dropped here;
  netgen has no such rule, so its setup must tie every bulk to one net on
  both sides.

## A Verilog top level

A digital block's schematic usually arrives as gate-level Verilog placing
standard cells whose transistors are in a SPICE library. Give both:

    gpurify lvs top.gds --deck sky130.deck --reference cells.spice --reference top.v

as Netgen reads them (`readnet verilog` into the netlist the cells were
read into). Every `.v` file is Verilog; at most one other file is the
SPICE or Spectre netlist. The top is the one module no other module
places, whatever cells of the library go unused. The Verilog read is the
structural subset a netlister writes: modules, `input`/`output`/`inout`/
`wire`/`supply0`/`supply1` declarations with constant ranges, `assign`
between nets, and instances connected by name or in order with nets, bits,
part selects and concatenations. A bus is its bits, `d[3]` and so on, and
a cell port `D[0]` takes bit `0` of a bus connected to `.D(...)`. A port an
instance leaves out is open, a net of its own. Compiler directives
(`` `ifdef ``) and constants (`1'b0`) are refused, so power connections
and tie cells must be written as nets and instances; the
`gpurify_ingest::netlist::verilog` docs list the subset.

## LVS parameters

The layout's devices are sized from what is drawn: transistor and resistor
`w` and `l`, a transistor's `nf` (one per drawn channel) and its source and
drain diffusions `as`, `ad`, `ps` and `pd`, a bipolar's emitter `ae` and
`pe`, every device's `area` and `perim`, and a resistor's `r` and a
capacitor's `c` where the deck gives their coefficients (see
[deck.md](deck.md#devices)). A diffusion is compared on the net it is drawn
on: a card that writes the transistor drain first gives its `as` to that
net. Where nothing else tells a transistor's two channel nets apart, they
pair the way its diffusions agree, so a card with them the other way round
is the same transistor. Each parameter a
schematic card states is compared on that device, within 2 % of the larger
value, except the counts `m` and `nf`: they are whole numbers and must be
equal, so `m=50` does not match `m=51`. The deck's `lvs tolerance` for a
parameter of a model replaces either (see
[deck.md](deck.md#lvs-controls)). A card that
leaves a parameter out says nothing about it, whatever other cards of the
same model state, and a parameter the layout does not measure is reported
(`lvs.undeclared_param`) rather than passed.

An `R` or `C` card may give its value positionally, between its nets and
its model: `R1 a b 1k rpoly` is `R1 a b rpoly r=1k`. Devices are paired by
model, so an `R`, `C` or `D` card that names none (`R1 a b 1k`, `D1 a b`)
is the deck's one device of its kind; where the deck has none of that kind,
or several, the card is refused, and the message names them. So is a
Spectre instance of a built-in primitive with no `model` card
(`R1 (a b) resistor r=1k`, `M1 (d g s b) nmos`), of any kind. On a
resistor, capacitor or diode card, other tools' names for the area and
perimeter are read as this tool's: KLayout's `A` and `P`, and ngspice's
diode `pj`, are `area`, `perim` and `perim`. A parameter stated twice, under
any of its names, is refused.

A device drawn with the wrong model, or written with one, but wired as
its counterpart is reported as one `lvs.model_mismatch` naming both
models, when nothing else differs; otherwise the devices are unpaired.

## LVS controls

The deck's `lvs` statements change the comparison per device model (see
[deck.md](deck.md#lvs-controls)): a parameter's tolerance, or leaving it out
(`lvs tolerance`, `lvs ignore_parameter`); ports held to their labels
(`lvs ports_by_name`); a transistor whose source and
drain do not swap (`lvs asymmetric`); pins that do (`lvs permute`); and
devices left out of the comparison altogether, fill or decap cells one side
does not state (`lvs ignore`), or dummies with every terminal on one net
(`lvs ignore_shorted`), or the layout's transistors wired to do nothing
(`lvs filter_unused`). A cell can be compared by its pins alone, its
contents ignored on both sides: a macro, or a foundry's fixed cell such as
a VPP capacitor (`lvs blackbox`). Must-connect nets, rails joined only above this
layout, are one net to compare (`lvs connect_implicit`, `lvs
connect_explicit`). And `lvs range` holds a model's drawn devices to the
sizes the foundry allows (`lvs.param_range`). The layout's own checks still see every
device.

## Exit code

`0` only when every selected check ran, no rule was skipped or refused, and
no error was found; findings from rules the deck marks `warning` are reported
but do not fail the run. Anything else is `1`: an error, a skipped rule, a
missing input, a file that could not be read.

## Design intent

Some electrical rules need facts about the chip that no process deck can know:
`ir_drop`, `dynamic_ir_drop`, `em_current_density`, `electromigration`,
`em_thermal`, `reliability`, `hv_domain`, `esd_latchup`, `esd_topological`,
`gate_oxide`, `drain_source`, `well_bias`, `missing_level_shifter`,
`domain_crossing`, `voltage_spacing`, `dielectric_field`, `hv_tag`,
`undriven_gate` and `missing_isolation` (these two also need `states`), and
`multiple_drivers` and `tie_high_low`, which read the supplies as the rails
that orient each transistor channel. Without `--intent` they report skipped.

```json
{
  "temperature_c": 105,
  "domains":  { "core": { "voltage_mv": 1800 } },
  "supplies": [
    { "net": "VDD", "domain": "core", "role": "power" },
    { "net": "VSS", "domain": "core", "role": "ground" }
  ],
  "limits": [
    { "net": "VDD", "max_drop_mv": 90, "max_drop_fraction": 0.05,
      "max_overvoltage_mv": 100, "budget_current_ua": 2000,
      "dynamic": { "max_drop_mv": 180, "toggle_rate": 0.2,
                   "clock_period_ps": 2000, "rise_time_ps": 100,
                   "decap_pf": 50 } }
  ]
}
```

Net names are the text labels in your layout. A ground net sits at 0 V and its
drop is how far it rises (ground bounce); `max_drop_fraction` is a fraction of
its domain's voltage for either role. A limit you leave out on a net
means that net is not checked for it, not that it is unlimited. `rms_current_ua` and
`peak_current_ua` state a net's RMS and peak current, shared among its loads
as the budget is, for the `em_rms` and `em_peak` rules (LEF's
`ACCURRENTDENSITY RMS` and `PEAK` limits); each load is taken to draw one
waveform in phase with the others. `frequency_mhz` is the frequency the net
switches at, which picks the row of a table that states several. A current
budget on a net that no device terminal reaches is refused rather than
ignored, because zero current would pass every limit.

`temperature_c` is the junction temperature the electromigration and
reliability rules run at; without it they run at the deck's `temperature`, and with neither they are refused. A net's `dynamic`
entry is what `dynamic_ir_drop` simulates: in the net's worst clock cycle
every load switches at once, each drawing its share of `budget_current_ua`
over the fraction `toggle_rate` of cycles it switches in, as a triangular
pulse `rise_time_ps` wide, while `decap_pf` (zero if left out) holds the
net up. `max_drop_mv` there is the limit on the static drop plus that
cycle's. It needs the net's `budget_current_ua`; a toggle rate above 1, or a
rise longer than the clock period, is refused.

The supplies also set the voltages the overstress and domain rules check. A
power net sits at its domain's voltage and a ground net at 0 V. Every other
net can reach anything between the lowest and highest supply connected to it
through transistor source and drain, resistors, diodes and bipolar
transistors; gates and capacitors pass nothing. A transistor whose deck row
states a gate condition (`on_gate_min`, `on_gate_max`) passes voltage only
while the range its gate can reach turns it on. Each power net's domain is
the power domain of the signals it drives, so give every separately powered
supply its own domain. A file may declare at most 64 domains.

Power states, for `undriven_gate` and `missing_isolation`, list the supplies
switched off and the inputs held at a voltage while each state lasts:

```json
"states": [
  { "name": "sleep",   "off": ["VDD_SW"] },
  { "name": "disable", "inputs": [{ "net": "EN", "voltage_mv": 0 }] }
]
```

In a state, a switched-off supply holds no voltage, and a held input is a
supply at its voltage (a ground at 0 V). Voltages are propagated again for
each state, gate conditions included, so a disabled tristate driver leaves its
output floating. A state may only turn off a declared supply, names are
unique, and an input is held once per state.

### Simulated currents

```sh
gpurify erc top.gds --deck sky130 --reference top.spice --intent intent.json --currents hot.emir.json
```

A budget spreads one current per net evenly over the net's loads, every load
in phase: a supply-grid model. In an analog block a bias line feeds a 1:10
mirror and a source line carries one branch's current, so the per-load
currents decide a wire. `--currents FILE` reads them from a simulator's
per-terminal current file (`espice-emir/1`, written by ESPice's `--emir`):
for each schematic instance terminal, its average, electromigration-average,
RMS and peak current at one corner (catalog ERC-E14).

1. LVS runs first, as `lvs` compares the layout with the reference. Its
   device and net pairing places each terminal: on the layout device LVS
   pairs the instance with, on that device's terminals on the net LVS pairs
   the terminal's net with (so a resistor's interchangeable ends, or a
   transistor's source and drain, land where the layout has them). A
   parallel or series group LVS reduced to one device shares the current
   evenly over its terminals on that net.
2. Each net's resistive grid, as `ir_drop` extracts it, is solved with every
   terminal current drawn at its device's tap. The net's port takes the
   return: one feed point, the centre of its highest, then widest, shape,
   held at the supply's voltage (0 V on a net that is no supply). This
   replaces spreading a budget over the loads.
3. `em_current_density`, `electromigration` and `em_thermal` check each wire
   and cut with the electromigration-average current through it; `em_rms`
   and `em_peak` with the RMS and peak values, combined over a net's loads
   by the in-phase sum the budget model already assumes, an upper bound.
4. `ir_drop` checks each node's drop to its net's port with the average
   currents: the supply's limits on a supply, and `max_drop_mv` alone, by
   magnitude, on any other net the currents load.

- A net that has both terminal currents and a budget uses the currents: an
  `erc.budget_unused` warning on the net says so, measured the net's
  simulated current (the sum of its average currents, by magnitude) against
  the budget no rule read. Nets the file does not reach keep their budgets.
- Each grid finding names the instance and terminal whose current loads it
  most (`loaded most by xdut.mn1 d` in the text report, `"load"` in JSON),
  found by one adjoint solve per finding.
- The file's instances are the reference's devices by their flattened names
  (`x1.mn1`; case does not matter), each with its terminals in card order as
  ESPice writes them. A name under a device names it too: `xm1.msky130_...`
  is the device inside a PDK wrapper subcircuit the simulator expanded. The
  names may sit under one testbench instance (`xdut.x1.mn1`); instances
  outside it are the testbench's and are left out.
- Refused, each naming the cause: `--currents` without `--reference`; a
  comparison that could not be made or did not conclude; a layout that does
  not match its reference (LVS found any discrepancy: a pairing of the
  devices that did match would still load wiring the reference never had);
  a terminal whose instance or net LVS left unmatched; a current file whose instance set does
  not match the reference (an instance that is no reference device, a
  reference device with no current, one device listed as several, a
  terminal count that is not the card's: another netlist); an instance LVS
  pairs with a black box; a terminal on a net with no label (no port) whose
  average currents do not sum to zero within 0.1 %, so nothing returns them.
  A net with no label whose currents balance (a mirror's inner node) needs
  no port.
- A device the deck's `lvs ignore` leaves out carries no current into the
  grid, nor does a net LVS reduction consumes (a series stack's inner node).
- The intent file is unchanged and still refuses unknown fields. Currents
  travel in their own file, so one simulator output serves GPurify and
  Philis 2.0 alike.

## Multi-die systems

```sh
gpurify system stack.json --reference system.spice [--format json]
```

A 2.5D or 3D assembly (dies on an interposer, a die stack, chiplets) is
checked as one: each die is read with its own deck, placed, bonded to the
dies it faces, and the whole is compared with a system netlist. The system
file says what Calibre 3DSTACK's configuration says: which dies, where each
sits, and which layers meet. Paths in it are relative to the file.

```json
{
  "dies": [
    { "name": "Xint", "layout": "interposer.gds", "deck": "interposer.deck" },
    { "name": "Xcpu", "layout": "cpu.gds", "deck": "cpu.deck",
      "intent": "cpu.json", "origin_nm": [120000, 40000],
      "rotate": 90, "mirror": true }
  ],
  "bonds": [
    { "a": { "die": "Xint", "layer": "ubump_pad" },
      "b": { "die": "Xcpu", "layer": "ubump" } }
  ],
  "package": { "die": "Xint", "layer": "c4" },
  "esd": { "clamps": ["esd_diode", "rail_clamp"],
           "system_clamps": ["iec_scr"], "system_pins": ["usb_dp"] }
}
```

- **Placement.** A die is reflected in its x axis when `mirror` (flipped face
  down), turned counter-clockwise by `rotate` (0, 90, 180 or 270), then its
  origin moved to `origin_nm`, as a GDS reference places a cell. Every die
  must be on the same grid.
- **Bonds.** Each bond names a layer of one die and a layer of another. Every
  shape on those layers is a bump, and must be a rectangle on a conductor of
  its deck. Two bumps bond where they overlap with some area; touching is not
  bonding. A through-silicon via is a `connect via` of its die's deck between
  its front and back layers. A bond may state `"max_offset_nm"`, the
  largest centre-to-centre offset of two bonded bumps, and `"min_space_nm"`,
  the least gap from a bump to any bump of the facing die it does not bond:
  assembly rules a packager or foundry states, so they are yours to give.
- **The system netlist** (SPICE or Spectre) has one top subcircuit. It places
  one instance per active die, named as the die (`Xcpu`), and its ports are
  the package pins. A die no instance names, such as a passive interposer, is
  wiring only.

Rows of a system run:

| Row | Flags |
|---|---|
| `system.unbonded_bump` | a bump that bonds nothing on the die it faces: missing, or misaligned |
| `system.bump_offset` | two bonded bumps whose centres are further apart than the bond's `max_offset_nm` |
| `system.bump_space` | a bump closer than the bond's `min_space_nm` to a bump of the facing die it does not bond |
| `system.open` | a pin of the netlist (a die instance's port, or a top port, labelled on the package face's die) on no labelled net, or a netlist net whose pins the assembly leaves in pieces |
| `system.short` | an assembled net carrying pins of two netlist nets |
| `lvs.*` | the assembled dies, flat, against the flattened system netlist, device by device, as `lvs` compares one die |
| `system.esd_d2d` | a die-to-die bump that does not reach clamps to a power and a ground rail on its own die (it is exposed only before bonding, JEP196) |
| `system.esd_package` | a package pin that does not reach clamps to a power and a ground rail anywhere in the assembly |
| `system.esd_iec` | a pin named in `system_pins` that does not reach both rails through `system_clamps` devices |

Pins are compared by name: the label at a die's bump is its pin, so a bus
wired in the wrong order is a short and an open even where the devices alone
would match. The ESD rows need `esd`, a package face, and each die's
`intent`, whose supplies are the rails; a clamp is any device of a listed
model, however it is wired. They check that a protection path exists, not
its resistance or the clamps' size, and nothing about the board: what a
system-level (IEC 61000-4-2) zap delivers to a pin depends on the board's
protection and needs simulation.

## Parasitics

`pex --format spef` writes a SPEF file for a timing tool, `--format dspf`
a DSPF file for a simulator, and `--format spice` a `.subckt` a simulator
runs on its own (below). SPEF lists a coupling capacitance in
the `*CAP` section of both nets it joins, as OpenSTA and other readers that
take one net at a time expect. Every net is extracted with closed-form
resistance and capacitance. Nets named with `--quasistatic` are solved from
the field instead, which is slower and more accurate, and their coupling to
nets that were not field-solved is kept. A field-solved net also gets its
inductance, and its resistance and inductance follow the wire through
every bend and every via, however the wire was cut into polygons: a
straight wire as one filament, and a bend or a change of width as a grid
of cells, so the current crowds at the inner corner (a right-angle corner
counts about 0.62 squares, against the one square of its centre line and
the 0.559 of the exact answer).
Every two field-solved nets also get their mutual inductance, from one
solve of all of them: the open-circuit coupling between their ports (each
port's current enters at the end of the net that comes first by x, then
y), so two parallel wires read a positive one. DSPF writes it as a `K` card
coupling the two nets' inductances by `M / √(L₁L₂)`; SPEF has no element for it, so the SPEF file carries it as a
`// mutual <node> <node> <pH>` comment in the first net's block. A
field-solved net whose shapes do not join into one circuit (two pieces that
meet only at a corner) is refused, and so is one with a shape the solve
cannot mesh (a layer above the substrate whose `pex` line states no
dielectric, or a diagonal edge), naming the layer, and a solve that does not
converge: PEX reports
the refusal and the rest of the report is still written. The field solve
holds the substrate at ground as a plane at height 0, so a field-solved
net's capacitance to ground
is to the substrate, as the closed forms' is. Where the deck's dielectrics
change with height (see [deck.md](deck.md#parasitic-stack)), the solve
meshes each interface between two dielectrics over a window around the
solved nets and solves the polarisation on it, so a wire sitting in one
dielectric under another sees both; the matrix is then reciprocal only to
the solve's discretisation, and is written symmetrised. A shape on a layer at height 0
(a well or a diffusion) is a junction in that plane, whose capacitance is a
depletion capacitance rather than a field: it is left out of the solve, and
the net's capacitance to ground adds the closed form from that layer's `pex`
line (area and fringe), while its resistance through the shape is computed
as for any other. So a net of metal and diffusion field-solves its metal,
and the field reads every junction as part of the grounded substrate. A
shape on a `connect global` layer (the substrate as a net) carries no
parasitics in the field solve either: it is left out and needs no `pex`
line, so a ground net tied to the substrate through its taps solves through
its other shapes, and one whose pieces join only through the substrate is
not one circuit and is refused. A net named twice is solved once.

A deck with process corners (`corner` lines, see
[deck.md](deck.md#process-corners)) is extracted at the nominal stack and
at every corner in the one run, and `--format spef` writes every value as a
`min:typ:max` triplet over them; `--format dspf` writes the nominal, and
`--format spice` the nominal and, with `-o`, each corner to a file.

The deck's `extraction` line picks which parasitics are written: resistance
and capacitance with or without the coupling between nets, capacitance alone
lumped on one node per net, or resistance alone, and a threshold below which
a coupling capacitance is grounded (see
[deck.md](deck.md#extraction-type)). Without one, everything is written.

A net with no text label in the layout has no name to write in SPEF, and
the run refuses it rather than inventing one; DSPF and SPICE carry the
devices and name it as below. A label on two nets that are not
connected cannot name either in a SPEF or DSPF file, which would merge them,
so the file is refused, naming the label. Two labels on one net, a short
that fails the run anyway, cannot both name it, as both formats give a net
one name: the file is refused too, naming both, rather than written under
one.

A wire is measured as drawn, not as cut into polygons: a net's shapes on one
layer are merged first, so pieces that abut or overlap read as the one
conductor they draw. Two pieces that meet only at a corner are one net but
two conductors, since a point carries no current: each is measured on its
own, and the closed forms chain them as they chain any two conductors of a
net. A conductor layer with a diagonal edge cannot be merged exactly, and
PEX is refused for it.

Every conductor layer that carries a net, and every via layer whose cuts join
two conductors, needs a `pex` line with a positive sheet resistance (see
[deck.md](deck.md#parasitic-stack)). A layer without one has unknown
parasitics, not zero ones, so PEX is refused and names the layer. Layers in
`connect global` (the substrate) carry no parasitics and need no line.

The same inputs always give a byte-identical report.

### A simulator-ready netlist

```sh
gpurify pex ota.gds --deck sky130 --reference ota.spice --format spice > ota.pex.spice
```

`--format spice` writes one `.subckt` for the top cell, ready for a
simulator (ESPice in any dialect, ngspice, or Spectre through `simulator
lang=spice`), so a post-layout bench runs the frozen schematic testbench on
the extracted view by including this file in place of the schematic's
subcircuit (catalog PEX-017):

```spice
* 0.1.0 pex: ota.gds, deck sky130, reference ota.spice, corner nominal
* sizes in units of 1e-6 m: a bench's .option scale must say the same
.subckt ota inp inn out vdd vss ib
XM1 out#3 inp#1 tail#2 vss sky130_fd_pr__nfet_01v8 w=4.2 l=0.5 nf=1 as=1.218 ad=1.218 ps=9.98 pd=9.98
...
R1 out out#1 12.400000
C1 out#1 0 3.100000f
C2 out#2 inp#4 0.210000f
.ends ota
```

- With `--reference`, `pex` also runs LVS, and the netlist is named in the
  reference's terms through the pairing LVS found: the `.subckt` is the
  reference's top cell, its pins that cell's ports in their order, each net
  the reference net LVS paired it with, and each device the reference card
  it paired with (`XM1`; a device under a placement as ngspice flattens it,
  `x1.xm1`, or `m.x1.m1` for a primitive card). Where the layout draws one
  reference device as several (fingers LVS merged in parallel), each is its
  own card on its own nodes, the extra ones `XM1_2`, `XM1_3`; a layout net
  no pair names (one a series merge consumed, or a floating piece) is
  `n<id>`, lengthened with `_` while another net has that name.
- The model is the deck's `device` statement's, and the sizes the
  extraction's: W, L, nf, junction areas and perimeters (`as`, `ad`, `ps`,
  `pd`, a diffusion shared by several transistors split evenly), a
  passive's `area` and `perim`, a diode's `pj`. They are written in the
  deck's `netlist_scale` unit (sky130's 1 µm, whose models set `.option
  scale=1.0u`), or in metres without one; the header says which.
- Each device terminal sits on the extracted node of the region of its net
  it touches most, on a layer the deck's `device` statements for that model
  name (a MOS's gate on its poly, its source and drain on their diffusion,
  never a strap above), and each pin on the region its label is on. A pin
  node keeps the net's bare name; every other node is `net#n`, `n` its
  place among the net's nodes as DSPF numbers them. A terminal on a net
  with no node (one drawn only on `connect global` layers, the substrate)
  is the net's bare name. Under a `c` or `cc` extraction, and on a
  field-solved net, every terminal is on the net's one node.
- The R, C, L and K cards follow the deck's `extraction` line exactly as
  DSPF writes them, coupling included.
- `--format dspf` carries the same devices: a node a terminal sits on is
  declared by one `*|I (node instance pin B 0 L<layer>)` line per terminal
  in place of its `*|S` (pin `d`, `g`, `s`, `b`; `c`, `b`, `e`, `s`; or its
  position from 1), and after the element cards a `* instance section`
  holds each device's card on the same node names. `gpurify compare` reads
  such a file and skips the instance section.
- Corners: with `-o FILE`, a deck with `corner` lines also writes each
  corner's `.subckt` to `FILE.<corner>`; the nominal one is on stdout.
- Refused, each naming what: a layout that fails LVS against the reference
  (no netlist is written for a layout that does not match), a comparison
  that did not run or did not conclude, a reference pin no layout net pairs
  with, a layout with black boxes or a deck that joins must-connect nets
  for LVS (neither is the layout's nets one to one), a name a SPICE card
  would read as syntax (a blank, `=`, `,`, a quote, a parenthesis, `#`),
  and two devices of one name.
- Without `--reference`, the `.subckt` is the layout's file stem, the pins
  its labelled nets in ascending net order, each device its family's letter
  and layout index (`M3`), and a warning on stderr says the netlist cannot
  be back-annotated. A label on two nets, or two labels on one, is refused
  as for SPEF.

Not done: the LOD and WPE parameters (`sa`, `sb`, `sca`..`scc`) LVS
measures under `lvs lde` are not written yet.

### Point to point and net to net

A deck line `report p2p "VDD" at [(10um, 20um), (150um, 20um), (150um,
90um)]` adds, to a `pex` (or `all`) run's text report, a line per pair of
points: the effective resistance of the net between them, each
conducting shape a chain of resistors along its long axis (sheet
resistance times squares), each via cut its layer's resistance, the
points tapped where they lie; the same model as ERC's `p2p_resistance`.
A point must lie on a conducting shape of the net. A parallel strap can
only lower it; current spreading across a wide shape is not modelled.
`report coupling "a" "b"` adds the total coupling capacitance between two
nets in the extracted network. `report cluster 2.5um` adds, to any check's
text report, one line per cluster after the violations: the violations of
one rule whose markers lie within that distance of each other, chained
(single linkage), largest first, with their count and bounding box, for
triage of a large result set. None of these is in the JSON, SPEF or DSPF
output.

### Comparing two parasitic netlists

```sh
gpurify compare <reference.spef> <candidate.spef> [--spec compare.json]
```

`compare` qualifies one extraction against another, from any two tools:
each file is SPEF (`*D_NET` nets) or DSPF, told by its first line. Nets are
linked by name. For every net in both it compares the total and ground
capacitance, the coupling to every other net, the resistance from the net's
driver (its input port or output pin, else its first node) to the farthest
node, and the Elmore delay to the slowest node; per metric it reports how
many rows were compared, how many are within the tolerance, and the worst,
mean and RMS relative error with the net of the worst. Rows under 0.01 (fF,
Ω, fs) in both files are noise and not compared. It exits 0 only when every
compared row is within the tolerance and both files name the same nets.
The tolerance is a qualification's own threshold, so it is stated in a
spec file kept with the qualification, `{"tolerance": 5}` in percent (an
unknown key is refused); without `--spec` it is 5 %. A coupling listed in both nets' `*CAP` sections, as most tools
write it, counts once; a reduced (`*R_NET`) or physical (`*D_PNET`) net is
refused.
