# ESD checks

An electrostatic discharge enters a chip at a pin and must leave through clamps to a supply before it
reaches a gate oxide or a junction. These checks find pins with no discharge path, clamps that are too
small or too far away, paths whose resistance or current is too high, and unprotected domain crossings.

Most rules need design intent that names the supplies (see [Design intent](../design-intent.md)), and
the rules that solve a path need a `pex` row with a sheet resistance on every conductor and cut it
crosses. Every parameter of every kind on this page is required: write `none` where a value does not
apply. No public deck states these limits, so the values are yours to supply.

The examples share two decks. `esd.deck` holds diodes and pads; each entry adds its rules to it. The
pad layer is a conductor of its own, joined to `met1` by the `padvia` cuts, so that each pad shape is
on its pin's net:

```text
grid 5nm
layer pdiff = gds(2, 0)
layer ndiff = gds(3, 0)
layer cont = gds(4, 0)
layer met1 = gds(7, 0)
layer met1_label = gds(7, 5)
layer dio = gds(14, 0)
layer clampmk = gds(15, 0)
layer padvia = gds(36, 0)
layer pad = gds(37, 0)
connect conductors [pdiff, ndiff, met1, pad]
connect touch_within_layer
connect via cont [pdiff, met1]
connect via cont [ndiff, met1]
connect via padvia [met1, pad]
connect label met1_label names met1
device diode dio model "esd_diode" terminals [pdiff, ndiff]
device diode clampmk model "rail_clamp" terminals [pdiff, ndiff]
pex pdiff thickness 100nm height 0nm sheet 10ohm area_cap 1fF/um2 fringe_cap 0.1fF/um
pex ndiff thickness 100nm height 0nm sheet 10ohm area_cap 1fF/um2 fringe_cap 0.1fF/um
pex cont thickness 500nm height 100nm sheet 1ohm area_cap 0aF/um2 fringe_cap 0aF/um
pex met1 thickness 360nm height 600nm sheet 0.125ohm area_cap 25.8aF/um2 fringe_cap 40.5aF/um
pex padvia thickness 500nm height 1000nm sheet 0.5ohm area_cap 0aF/um2 fringe_cap 0aF/um
pex pad thickness 1000nm height 1500nm sheet 0.01ohm area_cap 0aF/um2 fringe_cap 0aF/um
```

`mos.deck` adds poly, transistors and a poly resistor of 100 Ω per square:

```text
grid 5nm
layer pdiff = gds(2, 0)
layer ndiff = gds(3, 0)
layer cont = gds(4, 0)
layer poly = gds(5, 0)
layer met1 = gds(7, 0)
layer met1_label = gds(7, 5)
layer dio = gds(14, 0)
layer clampmk = gds(15, 0)
layer resmk = gds(18, 0)
layer padvia = gds(36, 0)
layer pad = gds(37, 0)
layer psd = pdiff not poly
layer nsd = ndiff not poly
layer poly_c = poly not resmk
layer ngate = poly and ndiff
layer pgate = poly and pdiff
layer rbody = poly and resmk
connect conductors [psd, nsd, poly_c, met1, pad]
connect touch_within_layer
connect via cont [psd, met1]
connect via cont [nsd, met1]
connect via cont [poly_c, met1]
connect via padvia [met1, pad]
connect label met1_label names met1
device diode dio model "esd_diode" terminals [psd, nsd]
device diode clampmk model "rail_clamp" terminals [psd, nsd]
device mos ngate model "nfet" terminals [poly_c, nsd, nsd]
device mos pgate model "pfet" terminals [poly_c, psd, psd]
device resistor rbody model "rpoly" terminals [poly_c, poly_c] sheet 100ohm
pex psd thickness 100nm height 0nm sheet 10ohm area_cap 1fF/um2 fringe_cap 0.1fF/um
pex nsd thickness 100nm height 0nm sheet 10ohm area_cap 1fF/um2 fringe_cap 0.1fF/um
pex poly_c thickness 180nm height 300nm sheet 10ohm area_cap 0.1fF/um2 fringe_cap 0.05fF/um
pex cont thickness 500nm height 100nm sheet 1ohm area_cap 0aF/um2 fringe_cap 0aF/um
pex met1 thickness 360nm height 600nm sheet 0.125ohm area_cap 25.8aF/um2 fringe_cap 40.5aF/um
pex padvia thickness 500nm height 1000nm sheet 0.5ohm area_cap 0aF/um2 fringe_cap 0aF/um
pex pad thickness 1000nm height 1500nm sheet 0.01ohm area_cap 0aF/um2 fringe_cap 0aF/um
```

The intent `io.json` declares one supply pair; `cross.json` declares two domains, A and B:

```json
{
  "domains":  { "core": { "voltage_mv": 1800 } },
  "supplies": [
    { "net": "VDD", "domain": "core", "role": "power" },
    { "net": "VSS", "domain": "core", "role": "ground" }
  ]
}
```

```json
{
  "domains":  { "a": { "voltage_mv": 1800 }, "b": { "voltage_mv": 1800 } },
  "supplies": [
    { "net": "VDDA", "domain": "a", "role": "power" },
    { "net": "VSSA", "domain": "a", "role": "ground" },
    { "net": "VDDB", "domain": "b", "role": "power" },
    { "net": "VSSB", "domain": "b", "role": "ground" }
  ]
}
```

Most layouts are built round one 20 µm square pad labelled `IO`, a `VDD` rail to its right and a
`VSS` rail to its left. Each diode is 4 µm × 4 µm, its anode (`pdiff`) and cathode (`ndiff`) each
2 µm wide with three contacts.

## Pad protection

### ERC-C1: Pad ESD path to power and ground

**What it catches.** A pad that cannot discharge to both a power and a ground rail through clamps. A
pulse between that pad and the rail it cannot reach has no designed path. It finds its own through a
gate oxide or a junction, and the part fails its human-body-model test.

**How GPurify measures it.** A pad is a net with a shape on the pad layer. From each pad net GPurify
follows clamps: a device of a listed model from the pad to a supply, then any chain of clamps between
supplies, such as a rail clamp. Another signal net does not continue the path. It counts the rail kinds
reached, power and ground, against 2.

A clamp is any device of a listed model. The one exception is a diode its supplies bias forward in
operation, which conducts all the time and is no clamp: a diode with its anode on a power supply, or
its cathode on a ground supply.

![A pad IO with one esd_diode up to VDD and no clamp to VSS, marked as reaching 1 rail of 2](../../diagrams/erc-c1.svg)

**In the deck.**

```text
rule <id> esd_topological(<pad layer>; clamps: [<model>, ...])
```

Added to `esd.deck`:

```text
rule esd.pad esd_topological(pad; clamps: ["esd_diode", "rail_clamp"])
```

```sh
gpurify erc io_up.gds --deck esd.deck --intent io.json
```

**Example violation.** The layout `io_up.gds` has the `IO` pad and one `esd_diode` from `IO` up to
`VDD`, with no diode down from `VSS` and no rail clamp.

```text
rules:
  esd.pad: ran, examined 1 shapes, found 1 violations
violations: 1
  esd.pad error layer met1 at (0 nm, 0 nm) measured 1 against limit 2 on shape 7
...
```

The pad net, reported at its first corner, reaches 1 rail kind of 2. With the diode down from `VSS`
and a `rail_clamp` between the rails, as in `io_ok.gds`, the row finds 0 violations.

> [!WARNING]
> A row that says `examined 0 shapes` found no pad. Make the pad layer a conductor joined to the metal
> under it, as `esd.deck` does, or the row has nothing to check.

**Options.**

| Parameter | Value | Meaning |
|---|---|---|
| `clamps` | list of model names | The device models that protect a pad, the rail clamps included. |

To hold a pad's guard ring as well, `esd_latchup` adds two limits to the same clamp path:
`rule <id> esd_latchup(<pad layer>, <guard ring layer>; min_guard_ring_width: <length>, max_tap_distance: <length>, clamps: [<model>, ...])`.
It flags a guard-ring shape narrower than `min_guard_ring_width`, and one further than
`max_tap_distance` from every supply shape. Guard rings are described on [Latch-up checks](latchup.md).

**Status and limits.** Implemented. Only the existence of a path is checked: its resistance and
current are ERC-C2 and ERC-C6 to ERC-C8. A transistor clamp counts however its gate is wired. The
shipped `sky130`, `gf180mcu` and `ihp_sg13g2` decks read a pad layer that is not a conductor, so their
pad rows find no pad; add the pad layer to `connect conductors` and a `connect via` to the top metal.
A pad layer that holds shapes but no net makes the row `refused`.

**Sources.** ESDA TR18.0-01-25, *ESD Electronic Design Automation Checks*, §4.5.2 to §4.5.4;
[ESDA, "ESD EDA Checks", Part I, In Compliance, 2012](https://www.esda.org/assets/News/8df611267c/ESDEDA-InCompliance-part1.pdf).

### ERC-C2: ESD device sizing

**What it catches.** A clamp too small for the share of the discharge current it carries. Each clamp
fails at its second-breakdown current, It2, which grows with its size, so an undersized diode or clamp
transistor burns out on the first strong pulse.

**How GPurify measures it.** `esd_path` forces `current` into each pad and solves the network from the
pad to every supply its clamps reach. Each clamp conducts as a resistor of `clamp_resistance`, and the
current exits at the supply's own pad shapes, or at its feed point when it has none. Each clamp's
current is then held to

\\[ I_\text{allowed} = I_{t2} \, s \\]

where \\( I_{t2} \\) is `clamp_it2`, the It2 per unit of size, and \\( s \\) is the clamp's size: its
width for a transistor, its perimeter for any other device. A violation sits at the clamp's marker.

In the example, two 4 µm × 4 µm diodes share 1.33 A, so each carries 665 mA. Each has a perimeter of
16 µm, so \\( I_\text{allowed} \\) = 30 mA/µm × 16 µm = 480 mA.

![The IO pad forcing 1.33 A through two parallel 4 µm diodes to VDD: each carries 665 mA against 30 mA/µm × 16 µm = 480 mA](../../diagrams/erc-c2.svg)

**In the deck.**

```text
rule <id> esd_path(<pad layer>; clamps: [<model>, ...], current: <current>, clamp_resistance: <resistance>, max_resistance: <resistance> | none, clamp_it2: <current per width> | none, max_density: <current per width> | none, max_current_per_cut: <current> | none, max_voltage: <voltage> | none, min_width: <length> | none, clamp_voltage: <voltage> | none)
```

Added to `esd.deck`, with the 1.33 A a 2 kV human-body-model pulse peaks at:

```text
rule esd.it2 esd_path(pad; clamps: ["esd_diode"], current: 1.33A, clamp_resistance: 1ohm, max_resistance: none, clamp_it2: 30mA/um, max_density: none, max_current_per_cut: none, max_voltage: none, min_width: none, clamp_voltage: none)
```

```sh
gpurify erc pair2.gds --deck esd.deck --intent io.json
```

**Example violation.** The layout `pair2.gds` joins the `IO` pad to a `VDD` plate through two diodes
side by side.

```text
rules:
  esd.it2: ran, examined 1 shapes, found 2 violations
violations: 2
  esd.it2 error layer dio at (22000 nm, 2000 nm) measured 665000.0000002665 uA against limit 480000.0000000001 uA on shape 12 and shape 23
  esd.it2 error layer dio at (22000 nm, 14000 nm) measured 665000.0000002665 uA against limit 480000.0000000001 uA on shape 13 and shape 23
...
```

Each diode, at its marker's corner, carries 665 mA against 480 mA. `examined` counts the pad and
supply pairs solved, here `IO` to `VDD`.

**Options.**

| Parameter | Value | Meaning |
|---|---|---|
| `clamps` | list of model names | The devices that conduct the pulse. |
| `current` | current | The current forced into each pad. |
| `clamp_resistance` | resistance | The on-resistance of each conducting clamp. |
| `max_resistance` | resistance or `none` | The largest pad-to-supply resistance (ERC-C6). |
| `clamp_it2` | current per width or `none` | It2 per unit of clamp size. |
| `max_density` | current per width or `none` | The pulse current a wire may carry per unit width (ERC-C7). |
| `max_current_per_cut` | current or `none` | The pulse current one cut may carry (ERC-C7). |
| `max_voltage` | voltage or `none` | The highest pad voltage under the pulse (ERC-C8). |
| `min_width` | length or `none` | The narrowest wire that may carry the pulse (ERC-C14). |
| `clamp_voltage` | voltage or `none` | The voltage each conducting clamp holds besides its resistance (ERC-C8). |

With a second layer, `esd_path(<pad layer>, <source layer>; ...)`, the current enters at the second
layer's shapes instead of the pads, as for an injection stress on a guard ring
([Latch-up checks](latchup.md)).

**Status and limits.** Implemented. Every clamp has the same on-resistance and It2 per unit size. A
row whose clamps include a device with no measured width or perimeter is `refused`.

**Sources.** ESDA TR18.0-01-25 Figures 23 and 24;
[ESDA, "ESD EDA Checks", Part II, In Compliance, 2012](https://www.esda.org/assets/News/ESDEDA-InCompliance-part2.pdf),
section III; [GF180MCU Design Rule Manual](https://gf180mcu-pdk.readthedocs.io/en/latest/physical_verification/design_man.html) §14.5.

### ERC-C3: Protected device

**What it catches.** A transistor whose gate a pad reaches without local protection, and an output
driver on a pad that is not rated for ESD. A thin gate oxide behind a pad breaks down at a few volts,
so it needs a series resistor and a local clamp to both rails behind the pad's own clamps.

**How GPurify measures it.** A gate is exposed when its net holds a pad, or is joined to one only
through devices of the `resistors` models; a supply never counts. For each exposed gate GPurify
counts the rail kinds its own net's clamps reach, as in ERC-C1, against 2. With `min_series` it also
holds the effective resistance from the pads to the gate, through the resistors, at or above that
value. Each resistor is its sheet resistance times its length over its width. A transistor with its
source or drain on a pad is a driver, and must be of a `rated` or `clamps` model, 0 against 1.

In the example, the `IO` pad is protected, but a poly resistor 2 µm wide and 4 µm long leads to an
NMOS gate. The resistor is 100 Ω × 4 / 2 = 200 Ω, under the 500 Ω asked, and no clamp sits at the
gate.

![The IO pad with diodes up and down, then a 200 Ω rpoly resistor to an NMOS gate IN: no clamp at IN reaches a rail, and 200 Ω is under 500 Ω](../../diagrams/erc-c3.svg)

**In the deck.**

```text
rule <id> esd_exposed(<pad layer>; clamps: [<model>, ...], resistors: [<model>, ...] | none, rated: [<model>, ...] | none, min_series: <resistance> | none)
```

Added to `mos.deck`:

```text
rule esd.exposed esd_exposed(pad; clamps: ["esd_diode", "rail_clamp"], resistors: ["rpoly"], rated: none, min_series: 500ohm)
```

```sh
gpurify erc exposed.gds --deck mos.deck --intent io.json
```

**Example violation.** The layout `exposed.gds` is the protected `IO` pad of ERC-C1, with the resistor
and the NMOS below it. The NMOS's source is on `VSS` and its drain on `VDD`.

```text
rules:
  esd.exposed: ran, examined 1 shapes, found 2 violations
violations: 2
  esd.exposed error layer ngate at (9000 nm, -11000 nm) measured 0 against limit 2 on shape 72
  esd.exposed error layer ngate at (9000 nm, -11000 nm) measured 200 ohm against limit 500 ohm on shape 72
...
```

The NMOS gate at (9000 nm, −11000 nm) reaches 0 rails of 2 through clamps on its own net, and its
series resistance is 200 Ω against at least 500 Ω.

**Options.**

| Parameter | Value | Meaning |
|---|---|---|
| `clamps` | list of model names | Protection devices, as in ERC-C1. |
| `resistors` | list of model names or `none` | Series resistors a pad reaches a gate through. |
| `rated` | list of model names or `none` | Transistors rated to drive a pad. |
| `min_series` | resistance or `none` | The least series resistance between a pad and an exposed gate. |

**Status and limits.** Implemented. A series resistor whose value cannot be measured makes the row
`refused` when `min_series` is given. Industry Council White Paper 2 §2.3.1 gives 100 Ω to 5000 Ω as a
common range for the series resistor, not as a rule.

**Sources.** ESDA TR18.0-01-25 §4.5.1 and Rule 6.1.11; ESDA, "ESD EDA Checks", Part I; GF180MCU Design
Rule Manual §14.4; [Industry Council on ESD Target Levels, White Paper 2](https://www.esdindustrycouncil.org/ic/en/documents) §2.3.

## Power domains

### ERC-C4: Cross-domain signal ESD protection

**What it catches.** A signal from one power domain driving a gate in another, with nothing to carry a
discharge between the two domains' grounds. A pulse between the domains then crosses the receiver's
gate oxide, a common charged-device-model failure.

**How GPurify measures it.** A receiver is a transistor whose gate is driven from a power domain that
reaches neither end of its channel. For each receiver GPurify asks that the driver's ground and the
receiver's ground be one net, or be joined by an anti-parallel pair of `diodes` devices, directly or
through a chain of such pairs: 0 against 1. With `local`, the gate's net must hold a device of a
`local` model tied to a ground of the receiver's domain. With `min_series`, the effective resistance
from the driving nets to the gate, through `resistors` devices, must be at least that value.

![An inverter in domain A drives an NMOS gate in domain B over net X; VSSA and VSSB are not coupled, measured 0 against 1](../../diagrams/erc-c4.svg)

**In the deck.**

```text
rule <id> esd_cross_domain(; diodes: [<model>, ...], local: [<model>, ...] | none, resistors: [<model>, ...] | none, min_series: <resistance> | none, max_ground_resistance: <resistance> | none, coupling_resistance: <resistance> | none)
```

Added to `mos.deck`:

```text
rule esd.xdomain esd_cross_domain(; diodes: ["esd_diode"], local: none, resistors: none, min_series: none, max_ground_resistance: none, coupling_resistance: none)
```

```sh
gpurify erc cross0.gds --deck mos.deck --intent cross.json
```

**Example violation.** The layout `cross0.gds` has an inverter on `VDDA` and `VSSA` whose output `X`
drives the gate of an NMOS between `VDDB` and `VSSB`. Nothing joins the two grounds.

```text
rules:
  esd.xdomain: ran, examined 1 shapes, found 1 violations
violations: 1
  esd.xdomain error layer ngate at (47000 nm, 8000 nm) measured 0 against limit 1 on shape 31
...
```

The receiver's gate at (47000 nm, 8000 nm) has 0 coupling paths between `VSSA` and `VSSB` against 1.
In `cross2.gds` a pair of anti-parallel diodes joins the grounds, and the row finds 0 violations.

**Options.**

| Parameter | Value | Meaning |
|---|---|---|
| `diodes` | list of model names | The diode models that couple two grounds when wired in anti-parallel pairs. |
| `local` | list of model names or `none` | Local clamp models at the receiver's gate. |
| `resistors` | list of model names or `none` | Series resistor models between driver and receiver. |
| `min_series` | resistance or `none` | The least series resistance before the receiver's gate. |
| `max_ground_resistance` | resistance or `none` | The largest driver-to-receiver ground resistance (ERC-C9). |
| `coupling_resistance` | resistance or `none` | The on-resistance of each coupling diode (ERC-C9). Needed with `max_ground_resistance`. |

**Status and limits.** Implemented. Domains come from the design intent's supplies, carried through
the transistors' channels. US 9,035,393 B2 states 50 Ω, 100 Ω or 200 Ω for the series resistor of a
cross-domain cell; no public deck states a limit.

**Sources.** ESDA TR18.0-01-11 check 5.1.3; ESDA TR18.0-01-25 §5.6.2; ESDA, "ESD EDA Checks", Part I
Figure 5 and Part II; [US 12,021,077 B2](https://patents.google.com/patent/US12021077B2);
[US 9,035,393 B2](https://patents.google.com/patent/US9035393B2).

### ERC-C5: Ground-domain coupling

**What it catches.** Two ground domains with no anti-parallel diode pair between them. A pulse between
two grounds needs a path in both directions; a single diode carries it one way only, and the other
polarity breaks down whatever lies between the domains.

**How GPurify measures it.** GPurify groups the declared grounds: two grounds joined by an
anti-parallel pair of `diodes` devices, directly or through a chain of such pairs, share a group. GPurify
keeps one group and flags every other group once, at the first shape of its ground, 0 pairs against 1.
So with two uncoupled grounds, one finding names one of them.

![VSSA and VSSB joined by one diode, flagged as one direction only, beside the same grounds joined by an anti-parallel pair, which couples them](../../diagrams/erc-c5.svg)

**In the deck.**

```text
rule <id> esd_ground_coupling(; diodes: [<model>, ...])
```

Added to `mos.deck`:

```text
rule esd.gnd esd_ground_coupling(; diodes: ["esd_diode"])
```

```sh
gpurify erc cross1.gds --deck mos.deck --intent cross.json
```

**Example violation.** The layout `cross1.gds` is `cross0.gds` with one diode from `VSSA` to `VSSB`.

```text
rules:
  esd.gnd: ran, examined 2 shapes, found 1 violations
violations: 1
  esd.gnd error layer met1 at (40000 nm, 0 nm) measured 0 against limit 1 on shape 17
...
```

`VSSB`, at its rail's corner (40000 nm, 0 nm), is not in `VSSA`'s group. `examined` counts the two
declared grounds. With the second, reversed diode of `cross2.gds`, the row finds 0 violations.

**Options.**

| Parameter | Value | Meaning |
|---|---|---|
| `diodes` | list of model names | The diode models that couple grounds in anti-parallel pairs. |

**Status and limits.** Implemented. Only diode pairs couple: grounds joined through another clamp or a
resistor are not coupled.

**Sources.** ESDA TR18.0-01-25 Figure 5; ESDA, "ESD EDA Checks", Part I Figure 2 and Part II Figure 1
and section IV.

## Discharge-path resistance and current

### ERC-C6: P2P resistance on the discharge path

**What it catches.** A pin whose discharge path to a supply, or to another pin, is too resistive. The
pin's voltage under the pulse is the current times that resistance, so a few ohms too many lift the
pin past the voltage the protected circuit survives.

**How GPurify measures it.** `esd_path` with `max_resistance` forces `current` into each pad, as in
ERC-C2, and reports the point-to-point (P2P) resistance

\\[ R = \frac{V_\text{pin}}{I} \\]

where \\( V_\text{pin} \\) is the pad's rise above the supply and \\( I \\) is `current`. Each conducting
clamp counts as `clamp_resistance`. `esd_pin_pair` does the same between two pins whose clamps reach a
supply in common, through every net either pin's clamps reach.

In the example, each pin reaches `VDD` through one diode. Its 3.18 Ω is the 1 Ω clamp plus 2.18 Ω of
pad, `met1`, contacts and diffusion. From `IO1` to `IO2` the path crosses both diodes, so it reads
6.36 Ω.

![Pins IO1 and IO2 each joined to VDD through wiring and a 1 Ω clamp: IO1 to VDD reads 3.18 Ω and IO1 to IO2 6.36 Ω, against 2 Ω](../../diagrams/erc-c6.svg)

**In the deck.**

```text
rule <id> esd_path(<pad layer>; ..., max_resistance: <resistance>, ...)
rule <id> esd_pin_pair(<pad layer>; clamps: [<model>, ...], current: <current>, clamp_resistance: <resistance>, max_resistance: <resistance>)
```

Added to `esd.deck`:

```text
rule esd.p2p esd_path(pad; clamps: ["esd_diode"], current: 1.33A, clamp_resistance: 1ohm, max_resistance: 2ohm, clamp_it2: none, max_density: none, max_current_per_cut: none, max_voltage: none, min_width: none, clamp_voltage: none)
rule esd.pins esd_pin_pair(pad; clamps: ["esd_diode"], current: 1.33A, clamp_resistance: 1ohm, max_resistance: 2ohm)
```

```sh
gpurify erc pins.gds --deck esd.deck --intent io.json
```

**Example violation.** The layout `pins.gds` has two pads, `IO1` at x = 0 µm and `IO2` at x = 80 µm,
each joined by one diode to a `VDD` plate between them.

```text
rules:
  esd.p2p: ran, examined 2 shapes, found 2 violations
  esd.pins: ran, examined 1 shapes, found 1 violations
violations: 3
  esd.p2p error layer pad at (0 nm, 0 nm) measured 3.182562066260894 ohm against limit 2 ohm on shape 24 and shape 16
  esd.p2p error layer pad at (80000 nm, 0 nm) measured 3.1789408894570146 ohm against limit 2 ohm on shape 25 and shape 16
  esd.pins error layer pad at (0 nm, 0 nm) measured 6.361502955730679 ohm against limit 2 ohm on shape 24 and shape 25
...
```

Each pad reads about 3.18 Ω to `VDD`, and `IO1` reads 6.36 Ω to `IO2`, all against 2 Ω. Each line
names the stressed pad and the shape the current leaves by.

**Options.** For `esd_path`, as in [ERC-C2](#erc-c2-esd-device-sizing). `esd_pin_pair` takes `clamps`,
`current` and `clamp_resistance` as `esd_path` does, and `max_resistance` as its limit.

Within one net, `rule <id> p2p_resistance(; max: <resistance>)` holds the largest resistance between
two device terminals on every net to `max`, with no forced current and no clamps.

**Status and limits.** Implemented. Every clamp is a resistor of `clamp_resistance`, whatever its size.
Which pin pairs to stress follows JS-001's pin-combination tables only as far as the rows you write:
`esd_path` covers each pin to each supply its clamps reach, and `esd_pin_pair` each pair of signal pins.

**Sources.** ESDA TR18.0-01-25 Figure 58; ESDA TR18.0-02-20 Figure 21; ANSI/ESDA/JEDEC JS-001-2024
Tables 2A and 2B; ESDA, "ESD EDA Checks", Part I Figure 2;
[Bakhali, "ESD P2P And CD Verification Doesn't Have To Be Hard", Semiconductor Engineering, 2020](https://semiengineering.com/esd-p2p-and-cd-verification-doesnt-have-to-be-hard/);
[US 11,714,117 B2](https://patents.google.com/patent/US11714117B2); Siemens Calibre PERC, Synopsys IC
Validator and Cadence Voltus P2P checks.

### ERC-C7: ESD-pulse current density

**What it catches.** A wire or cut on the discharge path too narrow for the pulse current. Metal and
contacts fuse within the pulse when the current density is too high, and the pad is left open or
damaged after one zap.

**How GPurify measures it.** `esd_path` solves the pulse as in ERC-C2 and holds every wire segment to
`max_density` times its width, and every cut to `max_current_per_cut`. The pulse is a direct current
at its peak value. A violation sits at the segment's or cut's first node.

In the example, 1.33 A flows from the pad through one diode. A `met1` segment 4 µm wide may carry
300 mA/µm × 4 µm = 1.2 A. In each column of three contacts, the middle one carries most of the
current, 1.02 A, against 200 mA.

![The IO pad, a 4 µm met1 strap, one diode with three contacts per side and VDD: the middle contact carries 1.02 A against 200 mA, the strap 1.33 A against 1.2 A](../../diagrams/erc-c7.svg)

**In the deck.**

```text
rule <id> esd_path(<pad layer>; ..., max_density: <current per width>, max_current_per_cut: <current>, ...)
```

Added to `esd.deck`:

```text
rule esd.cd esd_path(pad; clamps: ["esd_diode"], current: 1.33A, clamp_resistance: 1ohm, max_resistance: none, clamp_it2: none, max_density: 300mA/um, max_current_per_cut: 200mA, max_voltage: none, min_width: none, clamp_voltage: none)
```

```sh
gpurify erc pair1.gds --deck esd.deck --intent io.json
```

**Example violation.** The layout `pair1.gds` is `pair2.gds` with one diode.

```text
rules:
  esd.cd: ran, examined 1 shapes, found 6 violations
violations: 6
  esd.cd error layer cont at (23000 nm, 10000 nm) measured 1018385.3564545707 uA against limit 200000 uA on shape 30 and shape 10
  esd.cd error layer cont at (25000 nm, 10000 nm) measured 1017058.8235292644 uA against limit 200000 uA on shape 12 and shape 11
  esd.cd error layer met1 at (20000 nm, 10000 nm) measured 1329999.9999998326 uA against limit 1140000 uA on shape 7 and shape 10
  esd.cd error layer met1 at (25000 nm, 10000 nm) measured 1329999.9999997898 uA against limit 1200000.0000000002 uA on shape 11 and shape 11
...
```

The middle contact on each side of the diode carries about 1.02 A against 200 mA. The `met1` strap
carries all 1.33 A against 1.2 A where it is 4 µm wide, and against 1.14 A where it is 3.8 µm wide.

**Options.** As in [ERC-C2](#erc-c2-esd-device-sizing): `max_density` and `max_current_per_cut`.

**Status and limits.** Implemented. The pulse is a direct current at its peak: there is no waveform
and no self-heating, so a limit stated for a pulse width must be entered for that width.

**Sources.** ESDA TR18.0-01-25 Figure 58; ESDA TR22.0 §4.4; ESDA, "ESD EDA Checks", Part I; Siemens
Calibre PERC, Synopsys IC Validator and Ansys PathFinder-SC current-density checks.

### ERC-C8: Path voltage against device failure

**What it catches.** A pin that rises above the voltage its protected circuit survives during the
pulse, the ESD design window. The clamps turn on at a voltage of their own, and that voltage adds to
the drop across the path's resistance.

**How GPurify measures it.** `esd_path` with `max_voltage` holds the pad's voltage under the forced
current. With `clamp_voltage`, each conducting clamp holds that voltage in series with its
on-resistance, as Industry Council White Paper 2 §2.9.3 sums the path:

\\[ V_\text{pin} = V_\text{clamp} + I R \\]

where \\( V_\text{clamp} \\) is `clamp_voltage` (once per clamp in series), \\( I \\) is `current` and
\\( R \\) is the path resistance of ERC-C6. In the example, one diode lies on the path:
\\( V_\text{pin} \\) = 0.7 V + 1.33 A × 3.18 Ω = 4.93 V, against 4.5 V.

![The IO pad forcing 1.33 A through 3.18 Ω and a 0.7 V clamp to VDD: the pad sits at 0.7 + 1.33 × 3.18 = 4.93 V, over 4.5 V](../../diagrams/erc-c8.svg)

**In the deck.**

```text
rule <id> esd_path(<pad layer>; ..., max_voltage: <voltage>, ..., clamp_voltage: <voltage> | none)
```

Added to `esd.deck`:

```text
rule esd.window esd_path(pad; clamps: ["esd_diode"], current: 1.33A, clamp_resistance: 1ohm, max_resistance: 2ohm, clamp_it2: none, max_density: none, max_current_per_cut: none, max_voltage: 4.5V, min_width: none, clamp_voltage: 0.7V)
```

```sh
gpurify erc pair1.gds --deck esd.deck --intent io.json
```

**Example violation.** The layout is `pair1.gds` from ERC-C7.

```text
rules:
  esd.window: ran, examined 1 shapes, found 2 violations
violations: 2
  esd.window error layer pad at (0 nm, 0 nm) measured 4932.80754813177 mV against limit 4500 mV on shape 13 and shape 8
  esd.window error layer pad at (0 nm, 0 nm) measured 3.182562066260894 ohm against limit 2 ohm on shape 13 and shape 8
...
```

The pad rises to 4932.8 mV against 4500 mV. The same row also states `max_resistance: 2ohm`, so it
reports the 3.18 Ω path too; that resistance does not include the clamp voltage.

**Options.** As in [ERC-C2](#erc-c2-esd-device-sizing): `max_voltage` and `clamp_voltage`.

**Status and limits.** Partial. GPurify checks the pin's voltage, not each protected device's own
terminal voltages. A snapback clamp's trigger voltage before it conducts is not modelled, and one
`clamp_voltage` serves every clamp of a row.

**Sources.** ESDA TR18.0-01-25 §2.1; ESDA TR22.0 §4.1 and §8; ESDA, "ESD EDA Checks", Part I Figure 4;
GF180MCU Design Rule Manual §14.4; Industry Council on ESD Target Levels, White Paper 2 §2.9.3.

## Charged-device model

### ERC-C9: CDM checks

**What it catches.** A charged-device-model (CDM) weakness at a domain crossing: a receiver gate with
no local clamp, or a driver whose ground is too resistive from the receiver's. In a CDM event the
chip's own charge discharges in about a nanosecond, and the ground resistance between driver and
receiver turns into a voltage across the receiver's gate.

**How GPurify measures it.** `esd_cross_domain` finds each receiver as in ERC-C4. With `local`, a
receiver whose gate net holds no `local` device tied to its own domain's ground is flagged, 0 against
1. With `max_ground_resistance`, GPurify drives a unit current from each driver's ground attach point
to the receiver's, through both grounds and the coupling diodes, each diode at `coupling_resistance`.
The ratio of rise to current is the ground resistance.

In the example, the two 4 Ω coupling diodes in parallel give 2 Ω. The `VSSA` and `VSSB` rails, the
diode's diffusion and the contacts add 6.54 Ω, so the driver-to-receiver ground resistance is 8.54 Ω.

![The domain A inverter drives a domain B NMOS; the grounds join through two 4 Ω anti-parallel diodes. No local clamp at X, and 8.54 Ω of ground resistance against 2 Ω](../../diagrams/erc-c9.svg)

**In the deck.**

```text
rule <id> esd_cross_domain(; diodes: [<model>, ...], local: [<model>, ...], resistors: none, min_series: none, max_ground_resistance: <resistance>, coupling_resistance: <resistance>)
```

Added to `mos.deck`:

```text
rule esd.cdm esd_cross_domain(; diodes: ["esd_diode"], local: ["esd_diode"], resistors: none, min_series: none, max_ground_resistance: 2ohm, coupling_resistance: 4ohm)
```

```sh
gpurify erc cross2.gds --deck mos.deck --intent cross.json
```

**Example violation.** The layout `cross2.gds` is `cross0.gds` with an anti-parallel diode pair
between `VSSA` and `VSSB`, so the grounds are coupled and ERC-C4 passes.

```text
rules:
  esd.cdm: ran, examined 1 shapes, found 2 violations
violations: 2
  esd.cdm error layer ngate at (47000 nm, 8000 nm) measured 0 against limit 1 on shape 55
  esd.cdm error layer ngate at (47000 nm, 8000 nm) measured 8.544314626961077 ohm against limit 2 ohm on shape 55 and shape 54
...
```

The receiver at (47000 nm, 8000 nm) has no local clamp, 0 against 1. Its ground resistance to the
driver is 8.54 Ω against 2 Ω; the second shape named is the driver's.

**Options.** As in [ERC-C4](#erc-c4-cross-domain-signal-esd-protection): `local`,
`max_ground_resistance` and `coupling_resistance`.

**Status and limits.** Partial. The bus inductance a CDM discharge sees is not checked: no public
source states a static check or a limit for it. Etherton and others give 2 Ω as an example ground
resistance limit, not a rule.

**Sources.** ESDA TR18.0-01-25 §5.6.3 and §6.6; JEDEC JEP157A (Industry Council White Paper 2);
ESDA, "ESD EDA Checks", Part I;
[Etherton and others, "A New Full-Chip Verification Methodology to Prevent CDM Oxide Failures", EOS/ESD Symposium, 2015](https://www.synopsys.com/content/dam/synopsys/implementation&signoff/electrical-layout-verification-documents/cdm-esd-paper.pdf);
Ansys PathFinder-SC.

## Layout

### ERC-C10: Layout parasitic ESD paths

**What it catches.** A pad's diffusion drawn close to a diffusion on another net. The two junctions and
the substrate between them form a parasitic bipolar transistor that a pulse can trigger, so the
discharge flows somewhere the designer did not plan.

**How GPurify measures it.** `esd_parasitic` takes every shape of its diffusion layer on a pad net and
every shape of that layer on any other net. It flags each pair closer than `min_spacing`, measured edge
to edge, Euclidean at corners. A violation sits at the pad junction's first corner. `examined` counts
the diffusion shapes on pad nets. The row needs no design intent.

![An ndiff shape on IO 1 µm above an ndiff tap on VSS, flagged as a parasitic NPN at 1 µm against 2 µm](../../diagrams/erc-c10.svg)

**In the deck.**

```text
rule <id> esd_parasitic(<pad layer>, <diffusion layer>; min_spacing: <length>)
```

Added to `esd.deck`:

```text
rule esd.parasitic esd_parasitic(pad, ndiff; min_spacing: 2um)
```

```sh
gpurify erc io_stray.gds --deck esd.deck
```

**Example violation.** The layout `io_stray.gds` is `io_ok.gds` with an n+ tap on `VSS` 1 µm below the
cathode of the diode down from `VSS`, which sits on `IO`.

```text
rules:
  esd.parasitic: ran, examined 1 shapes, found 1 violations
violations: 1
  esd.parasitic error layer ndiff at (-4000 nm, 13000 nm) measured 1000 nm against limit 2000 nm on shape 33 and shape 35
...
```

The diode's cathode on `IO`, at (−4000 nm, 13000 nm), is 1000 nm from the tap on `VSS` against
2000 nm.

**Options.**

| Parameter | Value | Meaning |
|---|---|---|
| `min_spacing` | length | The least space between a pad's diffusion and another net's. |

**Status and limits.** Implemented. Spacing alone decides: what lies between the two diffusions, such
as a guard ring, is not considered. Foundry spacings for this check are not public.

**Sources.** ESDA TR18.0-01-25 §5.6.1; ESDA, "ESD EDA Checks", Part I; GF180MCU Design Rule Manual
§14.4.

### ERC-C11: ESD device geometry

**What it catches.** An ESD transistor drawn outside the foundry's ESD layout rules: a channel too
short, a drain contact too close to the gate, too few or too short fingers. An ESD transistor conducts
its pulse through a parasitic bipolar, and its drain ballast and finger layout set how evenly the
fingers share it.

**How GPurify measures it.** GPurify has no ESD-device kind for these rules. Derive the gate and
contacts under the ESD marker, then hold them with ordinary `width` and `space` rules, edge to edge and
Euclidean at corners. GlobalFoundries GF180MCU states them as rules LVESD.1 to LVESD.13: LVESD.3(a), a
recommended channel length of at least 0.3 µm, and LVESD.8(b), a drain-contact-to-gate space (DCGS) of
at least 1 µm.

![One ESD NMOS finger under esd_mk: a 0.25 µm poly2 gate against LVESD.3a's 0.3 µm, and a drain contact 0.8 µm from it against LVESD.8b's 1 µm](../../diagrams/erc-c11.svg)

**In the deck.**

```text
layer <esd gate> = (<poly> and <diffusion>) and <esd marker>
layer <drain contact> = (<contact> and <esd marker>) not <source marker>
rule <id> width(<esd gate>) >= <length>
rule <id> space(<drain contact>, <esd gate>) >= <length>
```

```text
grid 5nm
layer comp = gds(3, 0)
layer contact = gds(4, 0)
layer poly2 = gds(5, 0)
layer esd_mk = gds(24, 0)
layer lvs_source = gds(25, 0)
layer esd_gate = (poly2 and comp) and esd_mk
layer drain_contact = (contact and esd_mk) not lvs_source
rule LVESD.3a width(esd_gate) >= 300nm
rule LVESD.8b space(drain_contact, esd_gate) >= 1um
```

```sh
gpurify drc lvesd_bad.gds --deck lvesd.deck
```

**Example violation.** The layout `lvesd_bad.gds` is one finger: a gate 0.25 µm long and a drain
contact 0.8 µm from it, under `esd_mk`, with `lvs_source` over the source.

```text
rules:
  LVESD.3a: ran, examined 1 shapes, found 1 violations
  LVESD.8b: ran, examined 1 shapes, found 1 violations
violations: 2
  LVESD.3a error layer esd_gate at (2125 nm, 12500 nm) measured 250 nm against limit 300 nm on shape 7
  LVESD.8b error layer drain_contact at (2650 nm, 12110 nm) measured 800 nm against limit 1000 nm on shape 10 and shape 7
...
```

The gate's channel is 250 nm against 300 nm, and the drain contact sits 800 nm from the gate against
1000 nm. `lvesd_ok.gds`, at 0.3 µm and 1 µm, finds 0 violations.

**Status and limits.** Expressible. The shipped `gf180mcu` deck does not carry the LVESD rules yet. A
rule on finger count or total finger width needs the fingers counted, which ordinary rules do not do.

**Sources.** [GF180MCU Design Rule Manual §14.4.1](https://gf180mcu-pdk.readthedocs.io/en/latest/physical_verification/design_manual/drm_14_4_1.html),
rules LVESD.1 to LVESD.13; IHP SG13G2 Layout Rules §6.8.

## Package and system

### ERC-C12: Package and multi-die ESD

**What it catches.** A package pin, or a bump between two stacked dies, without a discharge path to
both rails. In a 2.5D or 3D assembly a die-to-die bump is often left with lighter protection, and each
die must still survive the discharge it sees during assembly, alone.

**How GPurify measures it.** `gpurify system` assembles the dies a system file names and checks the
paths as ERC-C1 does, counting rail kinds against 2:

- `system.esd_package` holds each bump on the package face to clamps reaching a power and a ground
  rail, through any die of the assembly.
- `system.esd_d2d` holds each die-to-die bump to clamps on its own die alone, as JEDEC JEP196 asks.

![Two stacked dies bonded by ubumps: the base die's PAD has diodes to both rails, but the top die's pin A has only a sense diode, 0 rails of 2 on its own die](../../diagrams/erc-c12.svg)

**In the deck.** Nothing extra in the die decks. Write a system file with an `esd` section and run
`gpurify system`. The system file `stack.json`:

```json
{
  "dies": [
    { "name": "Xbase", "layout": "base.gds", "deck": "die.deck", "intent": "rails.json" },
    { "name": "Xtop", "layout": "top.gds", "deck": "die.deck", "intent": "rails.json" }
  ],
  "bonds": [
    { "a": { "die": "Xbase", "layer": "ubump" }, "b": { "die": "Xtop", "layer": "ubump" } }
  ],
  "package": { "die": "Xbase", "layer": "c4" },
  "esd": { "clamps": ["esd_diode", "rail_clamp"],
           "system_clamps": ["iec_scr"], "system_pins": ["PAD"] }
}
```

Both dies use `die.deck`, and `rails.json` is `io.json`:

```text
grid 5nm
layer pdiff = gds(2, 0)
layer ndiff = gds(3, 0)
layer cont = gds(4, 0)
layer met1 = gds(7, 0)
layer met1_label = gds(7, 5)
layer dio = gds(14, 0)
layer clampmk = gds(15, 0)
layer sense = gds(16, 0)
layer c4 = gds(40, 0)
layer ubump = gds(41, 0)
connect conductors [pdiff, ndiff, met1, c4, ubump]
connect touch_within_layer
connect via cont [pdiff, met1]
connect via cont [ndiff, met1]
connect via c4 [met1, c4]
connect via ubump [met1, ubump]
connect label met1_label names met1
device diode dio model "esd_diode" terminals [pdiff, ndiff]
device diode clampmk model "rail_clamp" terminals [pdiff, ndiff]
device diode sense model "sense_diode" terminals [pdiff, ndiff]
lvs tolerance default relative 2%
```

The system netlist `stack.spice`:

```text
.subckt BASE PAD VDD VSS
D1 PAD VDD esd_diode
D2 VSS PAD esd_diode
D3 VSS VDD rail_clamp
.ends
.subckt TOPDIE A VDD VSS
D1 VSS A sense_diode
D2 VSS VDD rail_clamp
.ends
.subckt STACK PAD VDD VSS
Xbase PAD VDD VSS BASE
Xtop PAD VDD VSS TOPDIE
.ends
```

```sh
gpurify system stack.json --reference stack.spice
```

**Example violation.** The base die's `PAD` has diodes to both rails, a package bump and a ubump up to
the top die's pin `A`. On the top die, `A` has only a `sense_diode`, which is no clamp.

```text
rules:
  system.unbonded_bump: ran, examined 6 shapes, found 0 violations
  system.open: ran, examined 9 shapes, found 0 violations
  system.short: ran, examined 9 shapes, found 0 violations
  system.esd_d2d: ran, examined 6 shapes, found 1 violations
  system.esd_package: ran, examined 3 shapes, found 0 violations
  system.esd_iec: ran, examined 1 shapes, found 1 violations
violations: 2
  system.esd_d2d error at (3000 nm, 3000 nm) measured 0 against limit 2
...
```

The ubump at (3000 nm, 3000 nm) reaches 0 rails of 2 on the top die alone. Through the assembly the
same pin is protected, so `system.esd_package` passes. A system finding names no layer and no shape,
since its point is in the assembly's coordinates, not one die's.

**Options.** In the system file's `esd` section:

| Field | Value | Meaning |
|---|---|---|
| `clamps` | list of model names | The protection devices and rail clamps, on every die. At least one. |
| `system_clamps` | list of model names | Models rated for system-level stress (ERC-C13). |
| `system_pins` | list of labels | Package pins exposed to system-level stress (ERC-C13). |

The `esd` section needs a `package` face.

**Status and limits.** Partial. Only the existence of a path is checked: no resistance, current, clamp
size or CDM level. A wafer-on-wafer bond gets no exemption, and the package's resistance, inductance
and capacitance are not modelled.

**Sources.** ESDA TR18.0-01-25 §6.3 to §6.7; JEDEC JEP196; Siemens
Calibre 3DSTACK and 3D PERC.

### ERC-C13: System-level ESD

**What it catches.** A package pin exposed to system-level stress, such as a connector pin under IEC
61000-4-2, protected only by component-level clamps. A system-level pulse carries far more energy than
a human-body-model test, and a clamp rated for the latter fails under it.

**How GPurify measures it.** `system.esd_iec` holds each package pin named in `system_pins` to a path
to both a power and a ground rail through devices of the `system_clamps` models alone, as ERC-C1 does,
against 2. The ordinary `clamps` do not count.

![The PAD system pin protected by esd_diode devices to VDD and VSS, but with no iec_scr: 0 rails of 2](../../diagrams/erc-c13.svg)

**In the deck.** The system file of ERC-C12, with `"system_clamps": ["iec_scr"]` and
`"system_pins": ["PAD"]`, run the same way:

```sh
gpurify system stack.json --reference stack.spice
```

**Example violation.** `PAD` has `esd_diode` devices to both rails, and no `iec_scr`.

```text
rules:
...
  system.esd_iec: ran, examined 1 shapes, found 1 violations
violations: 2
...
  system.esd_iec error at (10000 nm, 10000 nm) measured 0 against limit 2
...
```

The package bump of `PAD`, at (10000 nm, 10000 nm), reaches 0 rails of 2 through system-rated clamps.

**Options.** `system_clamps` and `system_pins`, as in [ERC-C12](#erc-c12-package-and-multi-die-esd).
A name in `system_pins` that labels no package bump is refused.

**Status and limits.** Partial. GPurify checks only that a system-rated path exists. System robustness
itself (the board's TVS diodes, the residual pulse, soft failures, powered latch-up) needs simulation,
not a layout.

**Sources.** ESDA TR18.0-01-25 §7;
[Industry Council on ESD Target Levels, White Paper 3](https://www.esdindustrycouncil.org/ic/en/documents),
Part I §6.3.1; IEC 61000-4-2.

## Clamp placement and path metal

### ERC-C14: ESD layout rules on recognised devices

**What it catches.** A clamp placed too far from its pad, and metal on the discharge path too narrow
for the pulse. Distance from the pad is resistance, which raises the pin's voltage under the pulse,
and a narrow wire fuses under it.

**How GPurify measures it.** `esd_clamp_resistance` drives a unit current from each pad shape to each
clamp on the pad's own net, at the clamp's marker. The clamp itself is not in the path. The rise over
the current is the pad-to-clamp resistance, held to `max_resistance`; for a straight wire it is about

\\[ R = R_s \frac{L}{W} \\]

where \\( R_s \\) is the wire's sheet resistance, \\( L \\) its length and \\( W \\) its width. This
row needs no design intent. `esd_path` with `min_width` flags each wire segment that carries the
pulse and is narrower than `min_width`.

In the example, a `met1` line 100 µm long and 2 µm wide joins the pad to the diode:
0.125 Ω × 100 / 2 = 6.25 Ω. With the pad, the line's ends and the diode's terminal wiring, the run
reads 7.15 Ω.

![A pad joined to a diode clamp by a 100 µm met1 line 2 µm wide: 7.15 Ω from pad to clamp against 1 Ω, and 2 µm of width against 5 µm](../../diagrams/erc-c14.svg)

**In the deck.**

```text
rule <id> esd_clamp_resistance(<pad layer>; clamps: [<model>, ...], max_resistance: <resistance>)
rule <id> esd_path(<pad layer>; ..., min_width: <length>, ...)
```

Added to `esd.deck`:

```text
rule esd.clamp_r esd_clamp_resistance(pad; clamps: ["esd_diode"], max_resistance: 1ohm)
rule esd.width esd_path(pad; clamps: ["esd_diode"], current: 1.33A, clamp_resistance: 1ohm, max_resistance: none, clamp_it2: none, max_density: none, max_current_per_cut: none, max_voltage: none, min_width: 5um, clamp_voltage: none)
```

```sh
gpurify erc far.gds --deck esd.deck --intent io.json
```

**Example violation.** The layout `far.gds` has the pad, a `met1` line 100 µm × 2 µm, and one diode to
`VDD` at its far end.

```text
rules:
  esd.clamp_r: ran, examined 1 shapes, found 1 violations
  esd.width: ran, examined 1 shapes, found 9 violations
violations: 10
  esd.clamp_r error layer pad at (0 nm, 0 nm) measured 7.151327540851371 ohm against limit 1 ohm on shape 14 and shape 6
  esd.width error layer met1 at (20000 nm, 10000 nm) measured 2000 nm against limit 5000 nm on shape 7 and shape 8
...
  esd.width error layer met1 at (119500 nm, 10000 nm) measured 4000 nm against limit 5000 nm on shape 9 and shape 9
...
```

The clamp sits 7.15 Ω from its pad against 1 Ω. Each `met1` segment of the line, 2000 nm wide, and of
the 4 µm straps at the diode, is under 5000 nm.

**Options.**

| Parameter | Value | Meaning |
|---|---|---|
| `clamps` | list of model names | On `esd_clamp_resistance`: the clamps whose distance from the pad is held. |
| `max_resistance` | resistance | On `esd_clamp_resistance`: the largest pad-to-clamp resistance. |
| `min_width` | length | On `esd_path`: the narrowest wire that may carry the pulse. |

**Status and limits.** Implemented. Public material states a clamp's distance from its pad as this
resistance, not as a length. `min_width` applies to the metal that carries the pulse, not to a clamp's
own terminal diffusion, which its device rules size.

**Sources.** ESDA, "ESD EDA Checks", Part I;
[Hogan and Medhat, "Circuit Reliability Verification For Automotive Electronics", Semiconductor Engineering, 2021](https://semiengineering.com/circuit-reliability-verification-for-automotive-electronics/);
Bakhali, Semiconductor Engineering, 2020; US 11,714,117 B2; Siemens Calibre PERC LDL.
