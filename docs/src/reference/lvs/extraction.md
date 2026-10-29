# Layout extraction checks

These checks read the layout alone: its labels, its nets and its device markers. Every LVS run reports them before the comparison, and the short check also runs with DRC, with or without a reference netlist.

## Labels and ports

### LVS-001: Port and label consistency

**What it catches.** A label that names two nets the layout does not join, which is an open, and two labels on one net, which is a short. Labels are how a layout says which net is which, so a disagreement between labels and wiring is a wiring error. Under `lvs ports_by_name`, it also catches a reference port whose label is missing or sits on a net wired otherwise.

**How GPurify measures it.** GPurify binds each text label to the net of the shape it sits on. One label text on two or more nets is `lvs.label_conflict`, one row for each pair of nets, placed on the lowest shape carrying the label. Two or more label texts on one net is `lvs.net_seed_conflict`, described under [LVS-005](#lvs-005-short-isolation-and-localisation). With `lvs ports_by_name`, each port of the reference's top subcircuit pairs only with the layout net its label names; a port with no such net, or whose net is wired otherwise, is reported as `lvs.unpaired_net`.

![Layout: the inverter's output drawn as two met1 straps, both labelled Y and not joined; extracted: two nets named Y, flagged as a label conflict](../../diagrams/lvs-001.svg)

**In the deck.** Nothing to write in the deck beyond its `connect label` lines; the label check runs on every LVS run. To hold reference ports to their labels:

```text
lvs ports_by_name
```

See [LVS controls](../deck/lvs-controls.md).

**Example violation.** The example inverter with its output strap drawn in two pieces, one over the nfet's drain and one over the pfet's, each labelled `Y`:

```text
.subckt inv A Y VDD VSS
M1 Y A VSS VSS nfet W=1u L=0.15u
M2 Y A VDD VDD pfet W=2u L=0.15u
.ends
```

```sh
gpurify lvs open_y.gds --deck example.deck --reference inv.spice
```

```text
rules:
  lvs.floating_net: ran, examined 6 shapes, found 0 violations
  lvs.label_conflict: ran, examined 6 shapes, found 1 violations
...
violations: 14
...
  lvs.label_conflict error layer met1 at (1000 nm, 4650 nm) measured 2 against limit 1 on shape 32 and shape 34
...
```

The label `Y` sits on two met1 nets, shapes 32 and 34; the row is placed on the corner of the first. The comparison then reports the mismatch the open causes.

**Status and limits.** Implemented. KLayout's explicit `same_nets!` pairs have their counterpart in `lvs same_nets`, described under [LVS-032](equivalence.md#lvs-032-net-name-seeding).

**Sources.** KLayout LVS `flag_missing_ports` and `same_nets!` ([KLayout LVS reference](https://www.klayout.de/doc/about/lvs_ref_netter.html)); Netgen pin matching ([Netgen reference](http://opencircuitdesign.com/netgen/reference.html)).

### LVS-002: Implicit joins

**What it catches.** A net drawn in pieces that the layout joins only at a higher level, such as two VSS rails of a standard cell that the chip's power grid connects. Without a rule for them, the pieces carry one label on two nets: an open. Declaring them must-connect lets LVS compare them as one net while still warning that this layout leaves them apart.

**How GPurify measures it.** By default, disjoint shapes with one label are not joined: the open is reported as `lvs.label_conflict`, an error. `lvs connect_implicit "<pattern>"` makes every layout net whose label matches the pattern one net for the comparison, with the other nets of the same label. `lvs connect_explicit "<a>" "<b>" ...` joins the nets labelled with any of the names. The layout keeps its open, and `lvs.label_conflict` reports it as a warning.

![Two inverters whose VSS rails are separate met1 pieces, each labelled VSS; a dashed link marks connect_implicit joining them for the comparison](../../diagrams/lvs-002.svg)

**In the deck.**

```text
lvs connect_implicit "<pattern>"
lvs connect_explicit "<name>" "<name>" ...
```

The pattern is a glob over the whole label: `*` matches any run of characters and `?` one. The example adds:

```text
lvs connect_implicit "VSS"
```

Added to [the example deck](README.md#the-example-deck). See [LVS controls](../deck/lvs-controls.md).

**Example violation.** Two inverters in a row, the second driven by the first, whose two VSS rails are separate met1 straps both labelled `VSS`:

```text
.subckt two A Z VDD VSS
M1 Y A VSS VSS nfet W=1u L=0.15u
M2 Y A VDD VDD pfet W=2u L=0.15u
M3 Z Y VSS VSS nfet W=1u L=0.15u
M4 Z Y VDD VDD pfet W=2u L=0.15u
.ends
```

Without the line:

```sh
gpurify lvs split_vss.gds --deck example.deck --reference two.spice
```

```text
violations: 20
...
  lvs.label_conflict error layer met1 at (150 nm, 3450 nm) measured 2 against limit 1 on shape 60 and shape 64
...
```

With `lvs connect_implicit "VSS"`:

```sh
gpurify lvs split_vss.gds --deck implicit.deck --reference two.spice
```

```text
rules:
  lvs.floating_net: ran, examined 7 shapes, found 0 violations
  lvs.label_conflict: ran, examined 7 shapes, found 1 violations
...
violations: 1
  lvs.label_conflict warning layer met1 at (150 nm, 3450 nm) measured 2 against limit 1 on shape 60 and shape 64
lvs: Match
```

The open between the two VSS straps drops from an error to a warning, and the circuits match. The run exits 0.

**Status and limits.** Partial. The same label on disjoint shapes is never joined without a `connect_implicit` or `connect_explicit` line. The LEF 5.8 `MUSTJOINALLPORTS` property is not read. See [issue 7](https://github.com/OpenFAT/GPurify/issues/7).

**Sources.** KLayout LVS `connect_implicit` and `connect_explicit` ([KLayout LVS reference](https://www.klayout.de/doc/about/lvs_ref_netter.html)); LEF/DEF 5.8 `LEF58_MUSTJOINALLPORTS`; Siemens Calibre `VIRTUAL CONNECT COLON` and `VIRTUAL CONNECT NAME`.

### LVS-003: Soft connections through well or substrate

**What it catches.** A net held together only through a high-resistance layer, such as two supply straps that meet only through an n-well. The well carries no current worth the name, so the two straps are in effect apart, and a design that relies on the well to join them has an open its LVS would otherwise hide.

**How GPurify measures it.** For each net with a shape on a listed soft layer, GPurify takes the soft layers and the cuts into them out and extracts the net again. If the rest falls into two or more pieces, the net is reported once, on its lowest remaining shape, naming a shape in another piece, measured 2 against 1.

![An n-well holding two n taps, each wired to its own met1 strap labelled VDD; the well is the only joint, marked as a soft connection](../../diagrams/lvs-003.svg)

**In the deck.** A rule line names the soft layers. It runs with ERC (`gpurify erc` or `gpurify all`), not with `gpurify lvs`.

```text
rule <id> soft_connection(<layer>, ...)
```

```text
rule nwell.soft soft_connection(nwell)
```

Added to [the example deck](README.md#the-example-deck).

**Example violation.** One n-well holding two n taps, each contacted up to its own met1 strap, both straps labelled `VDD` and not otherwise joined:

```sh
gpurify erc soft_well.gds --deck soft.deck
```

```text
rules:
  nwell.soft: ran, examined 1 shapes, found 1 violations
violations: 1
  nwell.soft error layer li at (550 nm, 500 nm) measured 2 against limit 1 on shape 0 and shape 2
```

The `VDD` net falls into two pieces once the well is taken out; the row sits on the first tap's li pad and names the other piece's shape 2.

**Status and limits.** Implemented. No known limits.

**Sources.** KLayout LVS `soft_connect` ([KLayout LVS reference](https://www.klayout.de/doc/about/lvs_ref_netter.html)); Magic `disconnect`; Siemens Calibre `SCONNECT`.

## Devices

### LVS-004: Malformed device

**What it catches.** A device marker whose terminals cannot all be bound: a transistor gate with diffusion on one side only, or a terminal layer missing under the marker. Such a shape is no device, so the comparison would silently lose it.

**How GPurify measures it.** Each marker shape is bound against the terminal layers its `device` line lists, in order. Each position needs a shape of its own that touches the marker; a source drawn twice with no drain is not a shorted transistor. A marker no recogniser binds is reported as `lvs.terminal_net` on the marker, measured as the terminals bound against the terminals listed. A device whose terminal count its kind does not allow (a transistor 3 or 4, a bipolar 3, a two-pin device 2) is reported as `lvs.terminal_count`. Recognition does not depend on the order in which duplicated terminal shapes are drawn, and a hole in a marker is part of the marker, never a marker of its own.

![A diffusion whose poly crosses its right end: the gate marker touches diffusion on one side only, two of three terminals bound](../../diagrams/lvs-004.svg)

**In the deck.** Nothing to write in the deck beyond its `device` lines.

**Example violation.** The example inverter, plus an n-channel gate whose poly runs off the right end of its diffusion, so the gate has a source but no drain:

```sh
gpurify lvs malformed.gds --deck example.deck --reference inv.spice
```

```text
rules:
...
  lvs.terminal_net: ran, examined 7 shapes, found 1 violations
...
violations: 3
...
  lvs.terminal_net error layer ngate at (7100 nm, 1000 nm) measured 2 against limit 3 on shape 76
lvs: Mismatch([UnpairedNet { side: Layout, net: 4, name: Some("D") }, UnpairedNet { side: Layout, net: 5, name: Some("G") }])
```

The marker binds 2 of the 3 terminals its line lists, so it is no transistor; its labelled nets `D` and `G` then have no partner in the reference.

**Status and limits.** Implemented. No known limits.

**Sources.** KLayout LVS `ignore_extraction_errors` ([KLayout LVS reference](https://www.klayout.de/doc/about/lvs_ref_netter.html)); Magic `param_limits`.

## Shorts and floating nets

### LVS-005: Short isolation and localisation

**What it catches.** Two labelled nets joined by the layout: a short between, say, an input and ground. A short merges two nets into one, so the comparison reports a mismatch spread over every device on both. This check names the two labels and the path of shapes that joins them, so you can find the bridge.

**How GPurify measures it.** Two or more labels on one net is `lvs.net_seed_conflict`, one row per pair of names, on the lowest shape carrying each. The `lvs.short_path` rows follow: the fewest shapes joining the two labelled ones, one row per step from one shape to the next, numbered by the step against the step count. A cut joins the shapes it lands on and is no step itself. When several paths are equally short, one is reported, always the same one. Two labels on one shape give one path row, measured 1 against 1.

![The inverter's input strap A and its VSS strap joined by a met1 bridge on the left; the four steps of the short path numbered from VSS to A](../../diagrams/lvs-005.svg)

**In the deck.** Nothing to write in the deck beyond its `connect label` lines. The check runs with `gpurify lvs`, `gpurify drc` and `gpurify all`, with or without a reference.

**Example violation.** The example inverter with a met1 bridge drawn from its input strap `A` to its `VSS` strap:

```sh
gpurify drc short_a_vss.gds --deck example.deck
```

```text
rules:
  lvs.net_seed_conflict: ran, examined 4 shapes, found 1 violations
  lvs.short_path: ran, examined 1 shapes, found 4 violations
violations: 5
  lvs.net_seed_conflict error layer met1 at (150 nm, 3450 nm) measured 2 against limit 1 on shape 30 and shape 31
  lvs.short_path error layer met1 at (-1000 nm, 3450 nm) measured 3 against limit 4 on shape 34 and shape 35
  lvs.short_path error layer met1 at (-850 nm, 3450 nm) measured 2 against limit 4 on shape 36 and shape 34
  lvs.short_path error layer met1 at (150 nm, 3450 nm) measured 1 against limit 4 on shape 30 and shape 36
  lvs.short_path error layer met1 at (-850 nm, 4050 nm) measured 4 against limit 4 on shape 35 and shape 31
```

`VSS` (shape 30) and `A` (shape 31) are one net. The path runs in four steps: from the VSS strap to its extension (shape 36), to the bridge (shape 34), to the A extension (shape 35), to the A strap. Step 3 starts at the bridge at x = −1000 nm.

**Status and limits.** Partial. The path is the shortest one, not every route between the two labels. Opens are not isolated: a reference net split over several layout nets shows only as `lvs.label_conflict` where the pieces are labelled, never as a path. See [issue 8](https://github.com/OpenFAT/GPurify/issues/8).

**Sources.** Siemens Calibre `LVS ISOLATE SHORTS` and `LVS ISOLATE OPENS`; Synopsys IC Validator ShortFinder; Cadence Pegasus short isolation.

### LVS-006: Floating nets

**What it catches.** A net that no device terminal reaches and no label names: a stray piece of metal, or a well with no tap. It does nothing electrically, so it usually marks a forgotten connection or a leftover shape.

**How GPurify measures it.** Every net is examined. A net with no device terminal on it is reported, unless it carries a label or is made only of a global layer's shapes (such as the substrate). The row is placed on the net's lowest shape, measured 0 against 1.

![The example inverter beside an unlabelled met1 square that touches nothing, flagged as a floating net](../../diagrams/lvs-006.svg)

**In the deck.** Nothing to write in the deck.

**Example violation.** The example inverter beside a 1 µm met1 square that touches nothing:

```sh
gpurify lvs stray_metal.gds --deck example.deck --reference inv.spice
```

```text
rules:
  lvs.floating_net: ran, examined 6 shapes, found 1 violations
...
violations: 1
  lvs.floating_net error layer met1 at (-3000 nm, 0 nm) measured 0 against limit 1 on shape 34
lvs: Match
```

The square at (−3000 nm, 0 nm) is a net of its own with no terminal and no label. The circuits still match, since the comparison skips a net with nothing on it.

**Status and limits.** Implemented. No known limits.

**Sources.** KLayout LVS ([KLayout LVS reference](https://www.klayout.de/doc/about/lvs_ref.html)); Netgen ([Netgen reference](http://opencircuitdesign.com/netgen/reference.html)).
