# Run features

These features change how a run is organised rather than what a rule measures. They cover
waivers, staged decks, routed designs, custom rules, layout edits, re-checks after an edit and the
triage of large result sets.

## Waivers and stages

### FLOW-001: Geometric waivers

**What it catches.** A violation that the design team has reviewed and accepted, such as a known
exception inside an IP block. Without waivers, every run reports the same accepted violations and
the real new ones get lost among them. A waiver records the exception once, in the layout, and
every later run honours it.

**How GPurify measures it.** A waiver is a shape on a layer that the deck names for one rule. A
violation of that rule whose marker point lies on a waiver shape, its boundary included, is
waived. GPurify lists it under `waived`, not under `violations`, and the rule's count drops by
one. A waived violation does not fail the run. Because the waiver is drawn in the layout, a waiver
inside a cell waives at every placement of that cell, however it is turned or mirrored.

**In the deck.**

```text
waive <rule id> <layer>
```

```text
grid 5nm
layer met1 = gds(68, 20)
layer waive_m1 = gds(255, 1)
rule m1.1 width(met1) >= 140nm
waive m1.1 waive_m1
```

**Example violation.** Two met1 wires 0.1 µm wide, with a waiver shape drawn over the right one:

```sh
gpurify drc waive.gds --deck waive.deck
```

```text
rules:
  m1.1: ran, examined 2 shapes, found 1 violations
violations: 1
  m1.1 error layer met1 at (1000 nm, 50 nm) measured 100 nm against limit 140 nm on shape 0
waived: 1
  m1.1 error layer met1 at (6000 nm, 50 nm) measured 100 nm against limit 140 nm on shape 1
...
```

The wire at (6 µm, 0.05 µm) is 100 nm wide against the 140 nm limit, but its marker lies on the
waiver shape, so only the left wire counts. A rule may have several waiver layers, each stated
once. A waiver for a rule id that the deck does not have would waive nothing, so GPurify refuses
the deck:

```text
error: deck waive_bad.deck: Malformed
  waive m1.9: no rule of the deck has that id
```

**Status and limits.** Implemented. A waiver matches the violation's marker point, not its whole
geometry: a waiver shape must cover the point the report prints. Waivers are not matched by
pattern.

**Sources.** Siemens Calibre Auto-Waivers, which keeps waivers on a geometry layer; Cadence
Pegasus waivers.

### FLOW-002: Staged runs on a dirty design

**What it catches.** On an early layout, thousands of small violations hide the few gross ones that
cause them. A staged deck checks the gross rules first. When a stage finds an error, the later
stages are not checked, so you fix the causes before you look at the details.

**How GPurify measures it.** A `stage` line starts a stage. The rules after it, up to the next
`stage` line, belong to it. GPurify checks the stages in the order written. Once a stage finds an
error, every rule of every later stage reports `skipped`, with nothing examined and nothing found.
A warning does not stop the run. DRC stops at its first stage with an error. ERC runs every stage,
and GPurify withdraws the results of the stages after the first one with an error.

**In the deck.**

```text
stage <name>
rule <id> ...
stage <name>
rule <id> ...
```

```text
grid 5nm
layer met1 = gds(68, 20)
ignore gds(255, 1)
stage gross
rule m1.1 width(met1) >= 140nm
rule m1.2 space(met1) >= 140nm
stage signoff
rule m1.6 area(met1) >= 0.083um2
```

Every rule of a staged deck belongs to a stage, so no rule may come before the first `stage` line.
Each stage's rules are written together, and a stage name appears once. A deck with no `stage`
line checks every rule.

**Example violation.** The two narrow wires of the waiver example, with no waiver:

```sh
gpurify drc waive.gds --deck stage.deck
```

```text
rules:
  m1.1: ran, examined 2 shapes, found 2 violations
  m1.2: ran, examined 0 shapes, found 0 violations
  m1.6: skipped, an earlier stage of the deck found errors; fix those first, examined 0 shapes, found 0 violations
violations: 2
  m1.1 error layer met1 at (1000 nm, 50 nm) measured 100 nm against limit 140 nm on shape 0
  m1.1 error layer met1 at (6000 nm, 50 nm) measured 100 nm against limit 140 nm on shape 1
...
```

Stage `gross` finds two wires 100 nm wide against the 140 nm limit, so `m1.6` in stage `signoff`
is skipped.

> [!WARNING]
> A skipped stage looked at nothing. A run that stops at an early stage does not pass, and its
> later rules have not been checked.

**Status and limits.** Implemented. You choose the subset in the deck; GPurify does not pick the
early rules for you.

**Sources.** Siemens Calibre nmDRC-Recon; Synopsys IC Validator Explorer.

## Routed designs

### FLOW-003: SoC integration checks

**What it catches.** Mistakes in assembling a placed-and-routed design that no shape rule sees.
Examples are fill or a block outside the die, two blocks overlapping, a standard cell off its row's
sites, a pin off its routing tracks and a vertex off the manufacturing grid. Each one breaks the
next tool in the flow or the mask build.

**How GPurify measures it.** When the layout is a DEF file, a DRC run adds seven checks on the
design, each reported like a rule and each read from LEF/DEF 5.8:

| Rule | Flags |
|---|---|
| `def.fill_outside_die` | A `FILLS` shape not wholly inside the `DIEAREA`. The measured value is the fill shape's area. |
| `def.component_outside_die` | A placed component whose `SIZE` box is not wholly inside the `DIEAREA` |
| `def.component_overlap` | Two placed components whose boxes overlap in area. `CLASS COVER` macros, such as bumps, are left out. The measured value is the overlap area. |
| `def.off_site` | A placed `CORE` cell whose origin is on no site of any `ROW` |
| `def.pin_off_track` | A placed pin whose shape centre is on no `TRACKS` line of its layer |
| `def.off_manufacturing_grid` | A shape vertex off the LEF `MANUFACTURINGGRID` |
| `def.cell_edge_spacing` | Two placed cells' typed edges closer than the LEF cell edge spacing table allows. See the DRC pages for this rule. |

Each finding is on no layer and no shape. Its point is the lower-left corner of the offending shape
or component.

**In the deck.** Nothing to write for the integration checks. Name the deck's layers as the LEF
names them, and run DRC on the DEF with its LEF files, technology first:

```sh
gpurify drc soc.def --lef tech.lef --deck soc.deck
```

```text
grid 1nm
layer met1 = gds(1, 0)
layer via1 = gds(2, 0)
layer met2 = gds(3, 0)
rule m1.w width(met1) >= 140nm
rule m2.s space(met2) >= 200nm
connect conductors [met1, met2]
connect via via1 [met1, met2]
connect label met1 names met1
connect label met2 names met2
```

**Example violation.** The die is 200 µm square, and a fill shape hangs over its right edge. Two
5 µm blocks overlap. An inverter sits at x = 1010 nm on a row whose sites are 200 nm apart, and a
pin is centred at y = 10150 nm, between met1 tracks 200 nm apart:

```text
rules:
  m1.w: ran, examined 4 shapes, found 0 violations
  m2.s: ran, examined 1 shapes, found 0 violations
  def.fill_outside_die: ran, examined 1 shapes, found 1 violations
  def.component_outside_die: ran, examined 4 shapes, found 0 violations
  def.component_overlap: ran, examined 4 shapes, found 1 violations
  def.off_site: ran, examined 2 shapes, found 1 violations
  def.pin_off_track: ran, examined 2 shapes, found 1 violations
  def.off_manufacturing_grid: ran, examined 7 shapes, found 0 violations
  def.cell_edge_spacing: ran, examined 0 shapes, found 0 violations
violations: 4
  def.fill_outside_die error at (199000 nm, 100000 nm) measured 2000000 nm^2 against limit 0 nm^2
  def.component_overlap error at (4000 nm, 4000 nm) measured 4000000 nm^2 against limit 0 nm^2
  def.off_site error at (1010 nm, 10000 nm) measured 0 against limit 1
  def.pin_off_track error at (59900 nm, 10050 nm) measured 0 against limit 1
...
```

The two blocks overlap by 2 µm × 2 µm, which is 4000000 nm² against a limit of none. For the
placement checks, `measured 0 against limit 1` means the cell or pin is on no site or track.

**Status and limits.** Partial. Macro synchronisation, which compares a macro's own layout with its
LEF abstract, is not checked.

**Sources.** Si2 LEF/DEF 5.8 Language Reference (`DIEAREA`, `FILLS`, `ROW`, `TRACKS`,
`MANUFACTURINGGRID`, `CLASS COVER`); Synopsys IC Validator.

### FLOW-004: Interface DRC between top level and blocks

**What it catches.** A top-level wire that breaks a design rule against a block's pins or
obstructions. A block is often delivered as a LEF abstract, without its full layout. A top-level
route that runs too close to the block's boundary fails at sign-off, after the block is merged.

**How GPurify measures it.** A DEF layout draws every placed block's LEF abstract, its pin and
obstruction shapes, on the deck's layers beside the top-level routing. The deck's rules then check
them together, so a top-level wire is measured against a block's obstruction like any other shape.

**In the deck.** Nothing to write beyond the rules. Run DRC on the DEF with the LEF files that hold
the blocks' abstracts. The example uses the deck of FLOW-003:

```sh
gpurify drc iface.def --lef tech.lef --deck soc.deck
```

**Example violation.** A 5 µm block whose met2 obstruction covers it, and a 0.4 µm met2 power wire
100 nm from its right edge:

```text
rules:
  m1.w: ran, examined 1 shapes, found 0 violations
  m2.s: ran, examined 1 shapes, found 1 violations
...
violations: 1
  m2.s error layer met2 at (15050 nm, 12500 nm) measured 100 nm against limit 200 nm on shape 1 and shape 2
...
```

The wire is 100 nm from the block's obstruction at x = 15.05 µm, against the 200 nm limit.

**Status and limits.** Partial. GPurify reads no block layout: the abstract stands in for it, so
there is no hierarchical DRC inside a block. A violation between two shapes of one abstract is
reported like one at the interface, and the report does not tell them apart.

**Sources.** Si2 LEF/DEF 5.8 Language Reference (`MACRO`, `PIN`, `OBS`); Siemens Calibre; Synopsys
IC Validator.

## Tool integration

### FLOW-005: In-design live DRC

**What it catches.** A design-rule violation at the moment a layout editor or a generator draws it,
instead of in a separate batch run later. Live DRC shortens the loop between drawing and fixing.

**How GPurify measures it.** GPurify gives an editor or a layout generator two pieces of it. The
`gpurify deck` command writes a deck's compiled layers and rules as one JSON document. It adds the
values a generator asks for, such as minimum width, spacing and enclosure. The tool then reads
GPurify's own parse of the deck rather than the deck language. A program built on GPurify's library can re-check a layout
after each edit, as [FLOW-008](#flow-008-incremental-re-verification) describes.

**In the deck.** Nothing to write in the deck.

```sh
gpurify deck waive.deck --format json
```

**Example output.**

```json
{"format":"gpurify-deck/1","deck":"waive.deck","grid_nm":5,
"layers":[
{"id":0,"name":"met1","gds":[68,20]},
{"id":1,"name":"waive_m1","gds":[255,1]}
],
"rules":[
{"id":"m1.1","kind":"min_width","keyword":"width","domain":"drc","severity":"error","layers":[0],"params":[{"name":"limit","value":140,"unit":"nm"}]}
],
...
```

Every length is a whole number of nanometres, and a value the deck does not state is `null`.

**Status and limits.** Partial. GPurify has no editor integration that checks as you draw.
Open issue: [FLOW-005: In-design / live DRC](https://github.com/OpenFAT/GPurify/issues/13).

**Sources.** Siemens Calibre RealTime; Synopsys IC Validator Live; Cadence Pegasus.

### FLOW-006: User-programmable rules

**What it catches.** A process or design rule that no built-in check expresses. A team writes it
once, and it runs and reports like any other rule.

**How GPurify measures it.** A program built on GPurify's library adds a custom DRC rule as a
function, with the rule id, the layers it reads and its severity. GPurify calls the function with
those layers and keeps the accounting itself. A rule whose layers are all empty is `skipped` and
never called. Its examined count is the shapes and edges on its layers. Its violations are sorted
and repeats dropped. A violation on a layer the rule did not declare, outside the layout, or with a
value that is not finite refuses the rule and discards its violations. The same program can give
its runs decks built in code, each named as the shipped decks are.

**In the deck.** Nothing to write in the deck. A custom rule is code, not deck text.

**Status and limits.** Partial. Custom ERC rules are not supported. There is no way to write a
custom rule in the deck language or in a scripting language. Open issue:
[FLOW-006: User-programmable rules](https://github.com/OpenFAT/GPurify/issues/14).

**Sources.** Siemens Calibre TVF; KLayout's Ruby and Python DRC scripts.

## Layout edits and re-verification

### FLOW-007: Fill insertion

**What it catches.** A metal layer whose density in some window is below the foundry's minimum.
Chemical-mechanical polishing dishes a sparse area and erodes a dense one, so the foundry asks for
a density range in every window. Fill adds unconnected squares of metal until each window is in
range.

**How GPurify measures it.** `gpurify fill` reads each `fill` line of the deck and draws squares
on its fill layer. The squares are `size` on a side, on a grid `size + space` apart from the
lower-left corner of the die. A square goes only where it lies wholly inside the die and on nothing of
the density layer. It stays `keep` from every shape of the `avoid` layers, diagonally too at
corners, and `space` from fill already drawn. GPurify takes squares in rows from the bottom,
left to right. It takes one only while a window that holds it is below a `density` or
`global_density` minimum, and only if no window that holds it would then pass a maximum. A window
with no room left stays short, and its rule reports it.

![A 40 µm die with met1 bars along the bottom and top and a nofill box in the middle; 80 fill squares bring each of four 20 µm windows to 0.3 density](../diagrams/flow-007.svg)

GPurify writes the input layout to the output file with the squares added to its top cell. It then
runs DRC on that file and reports it, with DRC's exit status, so a run that exits 0 wrote a layout
that passes the deck.

**In the deck.**

```text
fill <fill layer> for <density layer> size <length> space <length> keep <length> avoid [<layer>, ..]
```

```text
grid 5nm
layer met1 = gds(68, 20)
layer met1_fill = gds(68, 28)
layer nofill = gds(68, 99)
layer met1_all = met1 or met1_fill
rule m1.pd.min density(met1_all; window: 20um, step: 20um) >= 0.3
rule m1.pd.max density(met1_all; window: 20um, step: 20um) <= 0.7
rule m1.fill.d space(met1_fill, met1) >= 1um
fill met1_fill for met1_all size 2um space 1um keep 1um avoid [met1, nofill]
```

The density layer is usually the metal and its fill together. The deck's own rules check what fill
drew: here `m1.fill.d` holds the fill 1 µm from drawn metal.

**Example output.** A 40 µm die has a met1 bar 2 µm wide along its bottom and top edges. Each
20 µm window starts at a density of 0.1:

```sh
gpurify fill fill.gds filled.gds --deck fill.deck
```

```text
rules:
  m1.pd.min: ran, examined 4 shapes, found 0 violations
  m1.pd.max: ran, examined 4 shapes, found 0 violations
  m1.fill.d: ran, examined 13 shapes, found 0 violations
violations: 0
...
wrote filled.gds: 80 fill squares
```

Each window needs 80 µm² more metal to reach 0.3, which is 20 squares of 4 µm². The last line goes
to standard error; the report goes to standard output.

**Options.**

| Parameter | Value | Meaning |
|---|---|---|
| `for` | layer | The layer whose `density` and `global_density` rules set how much to draw. A line whose density layer no such rule measures is refused. |
| `size` | length | The side of a fill square. Positive. |
| `space` | length | The gap between fill squares, and from fill already drawn. Positive. |
| `keep` | length | The least distance from every shape of the `avoid` layers. Zero or more. |
| `avoid` | list of layers | The layers fill keeps away from: the drawn metal and any no-fill layer. |

**Status and limits.** Partial. Fill is square, single-size and on one grid: no staggered or
multi-size fill. It reads no `density_balance`, `cover_density` or `density_cmp` rules, and it is
not timing-aware. Two `fill` lines for one density layer each fill as if the other drew nothing.
Every layer a line reads must be rectilinear. Open issue:
[FLOW-007: Fill insertion](https://github.com/OpenFAT/GPurify/issues/15).

**Sources.** KLayout `Cell#fill_region`; OpenROAD `density_fill`; Siemens Calibre SmartFill;
Synopsys IC Validator; Cadence Pegasus.

### FLOW-008: Incremental re-verification

**What it catches.** The violations an edit adds or removes, without checking the whole layout
again. A router or an editor that changes a few shapes needs an answer in the time of the change,
not in the time of a full run.

**How GPurify measures it.** A program built on GPurify's library checks a layout once, then checks
it again after each edit. Local rules, such as width, spacing, enclosure, area, notch and cut
rules, run again only on the groups of shapes within their reach of what the edit added or removed.
The reach is the largest distance any local rule measures, plus what the deck's sized and extended
layers grow. GPurify keeps the previous findings elsewhere. Density, design-wide, net, stack,
pattern and colouring rules run on the whole layout. The result equals a full DRC run on the edited
layout.

**In the deck.** Nothing to write in the deck. The command line keeps no state between runs, so
there is no command for it.

**Status and limits.** Partial. Only DRC is re-checked: not ERC, LVS or PEX. The re-check extracts
no nets, and it applies no stages, waivers or custom rules. It does not narrow a re-check to the
nets an edit changed. Open issue:
[FLOW-008: Incremental / ECO re-verification](https://github.com/OpenFAT/GPurify/issues/16).

**Sources.** Cadence Pegasus; Synopsys StarRC datasheet.

### FLOW-009: Automated layout enhancement

**What it catches.** Single-cut vias and narrow power straps that pass the rules but weaken the
design. A single cut fails open more often than a pair, and a narrow strap carries more IR drop and
electromigration stress. Adding a second cut and widening the straps where there is room raises
yield without a redesign.

**How GPurify measures it.** `gpurify enhance` proposes two kinds of edit. For each
`via_redundancy` rule, it adds a second cut beside each single-cut via. The cut goes to the first
of the four neighbours one `pitch` away that lies wholly on both metals and `space` from every cut. For a via
with no such room, it takes the first neighbour `space` from every cut and extends each metal under
it. For each `widen` line, it adds a strip along both long sides of every rectangle on the layer
whose net carries a matching label. An edit that would touch another net is never tried. GPurify
then runs DRC on the result and takes back every edit near a violation the input did not have, and
repeats until none is left.

![Net s: a 1 µm met1 and met2 pad with one via and a second via added 320 nm to its right; net VPWR: a 1 µm met2 strap widened by 0.5 µm on each side](../diagrams/flow-009.svg)

The output has no violation that the input lacked, and its redundant-via rate does not fall. Like
`fill`, `enhance` writes the edited layout, then reports DRC on it with DRC's exit status.

**In the deck.**

```text
rule <id> via_redundancy(<cut>, <lower>, <upper>; pitch: <length>, space: <length>) >= <fraction>
widen <layer> net "<pattern>" by <length>
```

```text
grid 5nm
layer met1 = gds(68, 20)
layer via = gds(68, 44)
layer met2 = gds(69, 20)
connect conductors [met1, met2]
connect touch_within_layer
connect via via [met1, met2]
connect label met1 names met1
connect label met2 names met2
rule m1.1 width(met1) >= 140nm
rule m1.2 space(met1) >= 140nm
rule via.2 space(via) >= 170nm
rule via.rv via_redundancy(via, met1, met2; pitch: 320nm, space: 170nm) >= 0.9
widen met2 net "VPWR" by 500nm
```

**Example output.** Net `s` is a 1 µm met1 and met2 pad joined by one 0.15 µm cut. Net `VPWR` is
a met2 strap 1 µm wide and 20 µm long:

```sh
gpurify enhance enhance.gds enhanced.gds --deck enhance.deck
```

```text
rules:
  m1.1: ran, examined 1 shapes, found 0 violations
  m1.2: ran, examined 0 shapes, found 0 violations
  via.2: ran, examined 1 shapes, found 0 violations
  via.rv: ran, examined 1 shapes, found 0 violations
violations: 0
...
wrote enhanced.gds: 1 redundant cuts, 2 strap sides widened
```

GPurify adds a second cut 320 nm to the right of the first and widens the strap to 2 µm. The last
line goes to standard error.

**Options.**

| Parameter | Value | Meaning |
|---|---|---|
| `pitch` | length | How far from a single cut its second cut goes, left, right, up or down. |
| `space` | length | The least distance from the second cut to every other cut. |
| `net` | glob | The labels of the nets whose straps are widened: `*` matches any run of characters, `?` one character. |
| `by` | length | The width of the strip added along each long side. |

**Status and limits.** Partial. GPurify adds no new power straps or via arrays, spreads no wires,
and makes no timing-aware choices. Open issue:
[FLOW-009: Automated DRC-clean layout enhancement](https://github.com/OpenFAT/GPurify/issues/17).

**Sources.** Siemens Calibre DesignEnhancer; Xu and others, "Redundant-via enhanced maze routing
for yield improvement", ASP-DAC 2005, for the redundant-via rate.

## Triage

### FLOW-010: Clustering of large result sets

**What it catches.** A systematic error that shows up thousands of times, such as one cell placed
across a die. Listed one by one, it buries every other violation. Clustered, it reads as one line
with a count and a bounding box.

**How GPurify measures it.** GPurify groups each rule's violations by single linkage. Two markers
of one rule at most the reach apart are in one cluster, and so is every marker chained to them. Distance is Euclidean, marker to marker. Clusters are listed largest first, then by rule id,
then by lower-left corner. The list comes after the findings and passes or fails nothing.

**In the deck.**

```text
report cluster <length>
```

```text
grid 5nm
layer met1 = gds(68, 20)
rule m1.1 width(met1) >= 140nm
ignore gds(255, 1)
report cluster 5um
```

The reach is zero or more, and the line appears at most once.

**Example output.** Four met1 wires 0.1 µm wide: three 3 µm apart, and one 40 µm further on:

```sh
gpurify drc cluster.gds --deck cluster.deck
```

```text
violations: 4
  m1.1 error layer met1 at (500 nm, 50 nm) measured 100 nm against limit 140 nm on shape 0
  m1.1 error layer met1 at (3500 nm, 50 nm) measured 100 nm against limit 140 nm on shape 1
  m1.1 error layer met1 at (6500 nm, 50 nm) measured 100 nm against limit 140 nm on shape 2
  m1.1 error layer met1 at (46500 nm, 50 nm) measured 100 nm against limit 140 nm on shape 3
...
cluster m1.1 3 violations within (0.5, 0.05)-(6.5, 0.05) um
cluster m1.1 1 violations within (46.5, 0.05)-(46.5, 0.05) um
```

The first three markers are 3 µm apart, within the 5 µm reach, so they form one cluster.

**Status and limits.** Partial. Clusters are by distance only. Clustering by shape, by context or
by root cause, as Calibre Vision AI offers, is not done, because those signatures are not public.

**Sources.** Sibson, "SLINK: an optimally efficient algorithm for the single-link cluster method",
The Computer Journal 16(1), 1973; Siemens Calibre Vision AI.
