# Voltage checks

These checks find devices and wires that see more voltage than they are built for, and signals that cross power domains without the cells that make the crossing safe. Each one reads the voltages GPurify propagates from the supplies in your [design intent](../design-intent.md), so each one needs `--intent`.

## Voltage propagation

### ERC-F1: Static voltage propagation

**What it catches.** Nothing by itself: it is the analysis every other check on this page reads. It works out which voltages each net can reach from the declared supplies. A device can only be checked for overstress once GPurify knows what its terminals can see, and a wrong range gives a wrong verdict everywhere.

**How GPurify measures it.** GPurify gives every net a range, the lowest and highest voltage it can reach, and the set of power domains that reach it.

- Each declared supply is fixed: a power net at its domain's voltage, a ground net at 0 V. A walk never passes through a supply.
- Voltage passes from one net to another through a conducting device: a transistor from source to drain, and every pin of a resistor, inductor, diode or bipolar transistor. A net's range covers every supply that reaches it this way.
- Gates, bulk terminals and capacitors pass nothing.
- A transistor whose `device` row states `on_gate_min` conducts only while its gate can reach that voltage or more (an n-channel switch). One that states `on_gate_max` conducts only while its gate can fall to that voltage or less (a p-channel switch). A transistor that states neither always conducts.
- A gate that no supply reaches, even with every switch on, is driven from outside the layout, so it takes any voltage and its switch conducts. A gate left floating by switches that are off also lets its switch conduct.
- A conducting channel passes its full range. There is no threshold drop and no body effect.

A check examines a device or a pair of nets only when some supply reaches each net it compares. Everything else is left out, and the rule's `examined` count says how many items were judged.

![An n-channel switch from VDDH at 3.3 V, gate EN an input, drives X at 3.3 V into a 1.8 V inverter whose oxide is flagged](../../diagrams/erc-f1.svg)

In the example, EN is a cell input that no supply reaches, so the switch conducts and X reaches 3.3 V. The inverter's gate oxide then sees 3.3 V. With EN tied to VSS, the switch is off, X is reached by no supply, and the inverter is not examined. The switch itself is examined instead: its gate sits at 0 V and its source at 3.3 V.

When GPurify cannot decide, it says so rather than reporting a clean result:

- Without `--intent`, every rule that reads voltages reports `skipped, no design intent was supplied`, and the run fails.
- A supply is matched to the net that carries its name as a label ([nets in the design intent](../design-intent.md#nets)). A declared supply that no label carries is not in the run. When no declared supply is in the layout, the rules report `skipped, no design intent was supplied`, as without `--intent`.
- A rule that needs power states (ERC-F7, ERC-F8, ERC-F14 and ERC-H1) reports `skipped` when the intent declares none, and says that no power state is declared.
- A device or a pair of nets that no supply reaches is left out, not passed. Compare the rule's `examined` count with the devices you expect it to judge.

> [!WARNING]
> A misspelt supply name is not an error: the run goes ahead with the supplies that did match. With `VCC` in the intent and `VDD` on the layout, the buffer of [ERC-F2](#erc-f2-gate-oxide-overstress) reports `ran, examined 2 shapes, found 0 violations` instead of 2 violations. Check that each supply's name matches a label exactly.

**In the deck.**

Nothing to write for the propagation itself; it runs whenever a rule reads voltages. A transistor row optionally states when it conducts:

```text
device mos <marker> model "<model>" terminals [<gate>, <source>, <drain>] on_gate_min <voltage>
device mos <marker> model "<model>" terminals [<gate>, <source>, <drain>] on_gate_max <voltage>
```

```text
grid 5nm
layer nwell = gds(1, 0)
layer diff = gds(2, 0)
layer poly = gds(3, 0)
layer cont = gds(4, 0)
layer met1 = gds(5, 0)
layer text = gds(5, 1)
layer sd = diff not poly
layer ngate = (poly and diff) not nwell
layer pgate = poly and diff and nwell
connect conductors [sd, poly, met1]
connect touch_within_layer
connect via cont [sd, met1]
connect via cont [poly, met1]
connect label text names met1
device mos ngate model "nfet" terminals [poly, sd, sd] on_gate_min 0.5V
device mos pgate model "pfet" terminals [poly, sd, sd] on_gate_max 1.3V
rule ox.thin gate_oxide(; models: ["nfet", "pfet"], max: 1.95V)
```

The intent declares a 1.8 V core supply pair and a 3.3 V supply, `two.json`:

```json
{
  "domains": { "core": { "voltage_mv": 1800 }, "io": { "voltage_mv": 3300 } },
  "supplies": [
    { "net": "VDD", "domain": "core", "role": "power" },
    { "net": "VSS", "domain": "core", "role": "ground" },
    { "net": "VDDH", "domain": "io", "role": "power" }
  ]
}
```

```sh
gpurify erc pass_open.gds --deck switch.deck --intent two.json
gpurify erc pass_off.gds --deck switch.deck --intent two.json
```

**Example violation.**

With EN an input (`pass_open.gds`):

```text
rules:
  ox.thin: ran, examined 2 shapes, found 2 violations
violations: 2
  ox.thin error layer ngate at (1400 nm, 1000 nm) measured 3300 mV against limit 1950 mV on shape 35
  ox.thin error layer pgate at (1400 nm, 4000 nm) measured 3300 mV against limit 1950 mV on shape 37
...
```

With EN wired to VSS (`pass_off.gds`):

```text
rules:
  ox.thin: ran, examined 1 shapes, found 1 violations
violations: 1
  ox.thin error layer ngate at (7400 nm, -5000 nm) measured 3300 mV against limit 1950 mV on shape 37
...
```

In the first run, both inverter transistors see 3.3 V against a 1.95 V limit. In the second, only the switch at (7400 nm, -5000 nm) is examined and flagged, with 3.3 V between its gate and source.

**Options.**

| Parameter | Value | Meaning |
|---|---|---|
| `on_gate_min` | voltage | The transistor conducts only while its gate can reach this voltage or more. |
| `on_gate_max` | voltage | The transistor conducts only while its gate can fall to this voltage or less. |

A row states one of the two, or neither.

**Status and limits.** Implemented. The model has no threshold drop and no body effect, and a diode passes voltage both ways. Ranges are worst case: two nets that never sit at their extremes together still count as reaching them, so the check errs toward a false violation. No shipped deck states a gate condition, so with a shipped deck every transistor conducts.

**Sources.** Siemens white paper 81822 (Calibre PERC), figure 1, conditional voltage propagation; [SkyWater SKY130](https://skywater-pdk.readthedocs.io/en/main/rules/periphery.html) rule hv.X.1; US patent 10,796,045 B2 (property-based path tracing); US patent 9,262,574 B2 (voltage-related analysis of layout data).

## Device overstress

### ERC-F2: Gate-oxide overstress

**What it catches.** A transistor whose gate can sit further from its source, drain or bulk than its oxide is rated for. A thin-oxide device on a high-voltage net breaks down or wears out early: the oxide fails by time-dependent breakdown long before the chip's intended life.

**How GPurify measures it.** For each transistor of the listed models, GPurify takes the worst-case difference between the gate's range and each of the source's, drain's and bulk's ranges: the highest one can reach minus the lowest the other can. The largest of these is held to `max`. A pair whose nets no supply reaches is not judged, and a device with no judged pair is not examined.

![A two-inverter buffer on a 3.3 V supply; the second inverter's gate sees 0 V to 3.3 V against a 1.95 V oxide rating](../../diagrams/erc-f2.svg)

**In the deck.**

```text
rule <id> gate_oxide(; models: [<model>, ..], max: <voltage>)
```

```text
grid 5nm
layer nwell = gds(1, 0)
layer diff = gds(2, 0)
layer poly = gds(3, 0)
layer cont = gds(4, 0)
layer met1 = gds(5, 0)
layer text = gds(5, 1)
layer sd = diff not poly
layer ngate = (poly and diff) not nwell
layer pgate = poly and diff and nwell
connect conductors [sd, poly, met1]
connect touch_within_layer
connect via cont [sd, met1]
connect via cont [poly, met1]
connect label text names met1
device mos ngate model "nfet" terminals [poly, sd, sd]
device mos pgate model "pfet" terminals [poly, sd, sd]
rule ox.thin gate_oxide(; models: ["nfet", "pfet"], max: 1.95V)
```

The buffer runs from a 3.3 V supply, `io.json`:

```json
{
  "domains": { "io": { "voltage_mv": 3300 } },
  "supplies": [
    { "net": "VDD", "domain": "io", "role": "power" },
    { "net": "VSS", "domain": "io", "role": "ground" }
  ]
}
```

```sh
gpurify erc buffer.gds --deck oxide.deck --intent io.json
```

**Example violation.**

```text
rules:
  ox.thin: ran, examined 2 shapes, found 2 violations
violations: 2
  ox.thin error layer ngate at (7400 nm, 1000 nm) measured 3300 mV against limit 1950 mV on shape 43
  ox.thin error layer pgate at (7400 nm, 4000 nm) measured 3300 mV against limit 1950 mV on shape 45
...
```

Both transistors of the second inverter, at x = 7400 nm, see 3.3 V across a 1.95 V oxide. The first inverter's gate, input A, is reached by no supply, so its two transistors are not examined.

**Options.**

| Parameter | Value | Meaning |
|---|---|---|
| `models` | list of models | The transistor models the limit applies to, each declared by a `device` row. |
| `max` | voltage | The largest gate-to-source, gate-to-drain or gate-to-bulk voltage allowed. |

**Status and limits.** Implemented. Ranges are worst case, so a gate and source that always move together still count their full spread, which errs toward a false violation. The bulk counts only when the `device` row names a fourth terminal. The shipped `sky130`, `gf180mcu` and `ihp_sg13g2` decks carry this check.

**Sources.** [GlobalFoundries GF180MCU design manual](https://gf180mcu-pdk.readthedocs.io/en/latest/physical_verification/design_man.html) §14.1.4.2; [SkyWater SKY130](https://skywater-pdk.readthedocs.io/en/main/rules/periphery.html) high-voltage rules; ESDA TR22.0 (foundry ESD parameters) §4.1; Siemens Calibre PERC public material.

### ERC-F3: Drain-source overstress

**What it catches.** A transistor whose drain can sit further from its source than the device is rated for. Too much voltage across the channel causes junction breakdown and punch-through, and drives hot-carrier damage.

**How GPurify measures it.** For each transistor of the listed models, GPurify takes the worst-case difference between the source's and the drain's ranges and holds it to `max`. A transistor whose source or drain no supply reaches is not examined.

![The same buffer with all four transistors boxed: each channel sees up to 3.3 V against a 1.95 V limit](../../diagrams/erc-f3.svg)

**In the deck.**

```text
rule <id> drain_source(; models: [<model>, ..], max: <voltage>)
```

```text
grid 5nm
layer nwell = gds(1, 0)
layer diff = gds(2, 0)
layer poly = gds(3, 0)
layer cont = gds(4, 0)
layer met1 = gds(5, 0)
layer text = gds(5, 1)
layer sd = diff not poly
layer ngate = (poly and diff) not nwell
layer pgate = poly and diff and nwell
connect conductors [sd, poly, met1]
connect touch_within_layer
connect via cont [sd, met1]
connect via cont [poly, met1]
connect label text names met1
device mos ngate model "nfet" terminals [poly, sd, sd]
device mos pgate model "pfet" terminals [poly, sd, sd]
rule ds.thin drain_source(; models: ["nfet", "pfet"], max: 1.95V)
```

The intent is `io.json` from [ERC-F2](#erc-f2-gate-oxide-overstress): VDD at 3.3 V, VSS at 0 V.

```sh
gpurify erc buffer.gds --deck vds.deck --intent io.json
```

**Example violation.**

```text
rules:
  ds.thin: ran, examined 4 shapes, found 4 violations
violations: 4
  ds.thin error layer ngate at (1400 nm, 1000 nm) measured 3300 mV against limit 1950 mV on shape 42
  ds.thin error layer ngate at (7400 nm, 1000 nm) measured 3300 mV against limit 1950 mV on shape 43
  ds.thin error layer pgate at (1400 nm, 4000 nm) measured 3300 mV against limit 1950 mV on shape 44
  ds.thin error layer pgate at (7400 nm, 4000 nm) measured 3300 mV against limit 1950 mV on shape 45
...
```

Every transistor has one end on a rail and the other on an output that reaches both rails, so each channel sees 3.3 V against the 1.95 V limit. The first inverter is examined here: its source and drain are reached even though its gate is not.

**Options.**

| Parameter | Value | Meaning |
|---|---|---|
| `models` | list of models | The transistor models the limit applies to. |
| `max` | voltage | The largest drain-to-source voltage allowed. |

**Status and limits.** Implemented. Ranges are worst case, as for [ERC-F2](#erc-f2-gate-oxide-overstress). The shipped `sky130`, `gf180mcu` and `ihp_sg13g2` decks carry this check.

**Sources.** [SkyWater SKY130](https://skywater-pdk.readthedocs.io/en/main/rules/periphery.html) high-voltage rules; IHP SG13G2 process specification, operating voltages.

### ERC-F4: Hot-carrier susceptibility

**What it catches.** A minimum-length transistor used in both directions, such as a pass gate between two driven nodes. Current that flows either way stresses both ends of the channel with hot carriers. GF180MCU asks for a longer than minimum channel in that case.

**How GPurify measures it.** GPurify looks at each transistor of the listed models whose drawn length is at most `max_length`. It flags one when neither channel end is a supply, and each end still reaches both a power and a ground supply through other transistors' channels with this transistor cut out. Any other transistor joining the same two nets is cut out too. The finding measures the drawn length against `max_length`.

![Two inverters drive Y1 and Y2; a 200 nm nfet with gate EN joins them and is flagged as used both ways](../../diagrams/erc-f4.svg)

**In the deck.**

```text
rule <id> warning hot_carrier(; models: [<model>, ..], max_length: <length>)
```

```text
grid 5nm
layer nwell = gds(1, 0)
layer diff = gds(2, 0)
layer poly = gds(3, 0)
layer cont = gds(4, 0)
layer met1 = gds(5, 0)
layer text = gds(5, 1)
layer sd = diff not poly
layer ngate = (poly and diff) not nwell
layer pgate = poly and diff and nwell
connect conductors [sd, poly, met1]
connect touch_within_layer
connect via cont [sd, met1]
connect via cont [poly, met1]
connect label text names met1
device mos ngate model "nfet" terminals [poly, sd, sd]
device mos pgate model "pfet" terminals [poly, sd, sd]
rule hci warning hot_carrier(; models: ["nfet"], max_length: 200nm)
```

Write it as a `warning` row: GF180MCU states it as a guideline. The intent declares VDD and VSS, `core.json`:

```json
{
  "domains": { "core": { "voltage_mv": 1800 } },
  "supplies": [
    { "net": "VDD", "domain": "core", "role": "power" },
    { "net": "VSS", "domain": "core", "role": "ground" }
  ]
}
```

```sh
gpurify erc hc.gds --deck hci.deck --intent core.json
```

**Example violation.**

```text
rules:
  hci: ran, examined 3 shapes, found 1 violations
violations: 1
  hci warning layer ngate at (5400 nm, 2500 nm) measured 200 nm against limit 200 nm on shape 55
...
```

The pass transistor at (5400 nm, 2500 nm) is 200 nm long, at the 200 nm limit, and each of its ends reaches VDD and VSS through its own inverter. The two inverter n-channel transistors are examined too but have one end on VSS.

**Options.**

| Parameter | Value | Meaning |
|---|---|---|
| `models` | list of models | The transistor models to check. |
| `max_length` | length | A transistor this long or shorter counts as minimum length. |

**Status and limits.** Partial. GPurify checks the bi-directional case of GF180MCU §14.1.4.1 (e) only. It does not check a static stress condition, which no public source defines, or the case below the maximum supply voltage, which needs a hot-carrier voltage no public source states. At the maximum supply, [ERC-F3](#erc-f3-drain-source-overstress) covers the stress. It does not check speed-critical nets, which need timing data.

**Sources.** [GlobalFoundries GF180MCU design manual](https://gf180mcu-pdk.readthedocs.io/en/latest/physical_verification/design_man.html) §14.1.4.1 (e); Siemens white paper 81822 (Calibre PERC), equation 1.

### ERC-F5: Voltage-stress lifetime

**What it catches.** A supply that runs above the voltage its devices are qualified at, by enough to shorten their life below the product's target. Dielectric breakdown (TDDB), bias-temperature instability (BTI) and hot-carrier wear all speed up steeply with voltage and temperature.

**How GPurify measures it.** GPurify solves the resistive grid of each declared supply, as the IR-drop checks do, and judges every node of it at its solved voltage. A node's predicted lifetime is

\\[ t = t_\text{ref} \left( \frac{V_\text{ref}}{|V|} \right)^{n} \exp\left( \frac{E_a}{k} \left( \frac{1}{T} - \frac{1}{T_\text{ref}} \right) \right) \frac{1}{d} \\]

where \\( t_\text{ref} \\) is `reference_lifetime`, \\( V_\text{ref} \\) is `reference_stress`, \\( |V| \\) is the node's voltage, \\( n \\) is `stress_exponent`, \\( E_a \\) is `activation_energy`, \\( k \\) is Boltzmann's constant, \\( T \\) is the run's temperature, \\( T_\text{ref} \\) is `reference_temperature`, and \\( d \\) is `duty_cycle`. A node whose lifetime is below `required_lifetime` is flagged, and so is a node above `max_abs_voltage`. A node at 0 V, a ground, is not stressed.

In the example, every node of VDD sits at 1.98 V, the run is at the 125 °C reference, and the duty cycle is 1. The lifetime is 100000 h × (1.8 V / 1.98 V)^40 = 2209 h, below the 87600 h required.

![The VDD grid as a resistor ladder from a 1.98 V supply, every node flagged at 2209 h against 87600 h](../../diagrams/erc-f5.svg)

**In the deck.**

```text
rule <id> reliability(; required_lifetime: <time>, reference_lifetime: <time>,
    reference_stress: <voltage>, stress_exponent: <number>, reference_temperature: <temperature>,
    activation_energy: <energy>, max_abs_voltage: <voltage>, duty_cycle: <fraction>)
```

The grid needs a sheet resistance for every layer that carries the supply's current, from the deck's `pex` rows:

```text
grid 5nm
layer nwell = gds(1, 0)
layer diff = gds(2, 0)
layer poly = gds(3, 0)
layer cont = gds(4, 0)
layer met1 = gds(5, 0)
layer text = gds(5, 1)
layer sd = diff not poly
layer ngate = (poly and diff) not nwell
layer pgate = poly and diff and nwell
connect conductors [sd, poly, met1]
connect touch_within_layer
connect via cont [sd, met1]
connect via cont [poly, met1]
connect label text names met1
device mos ngate model "nfet" terminals [poly, sd, sd]
device mos pgate model "pfet" terminals [poly, sd, sd]
pex sd thickness 100nm height 0nm sheet 120ohm dielectric 3.9 area_cap 0aF/um2 fringe_cap 0aF/um
pex poly thickness 200nm height 200nm sheet 48ohm dielectric 3.9 area_cap 0aF/um2 fringe_cap 0aF/um
pex cont thickness 500nm height 400nm sheet 15ohm dielectric 3.9 area_cap 0aF/um2 fringe_cap 0aF/um
pex met1 thickness 400nm height 900nm sheet 0.1ohm dielectric 3.9 area_cap 0aF/um2 fringe_cap 0aF/um
rule tddb reliability(; required_lifetime: 87600h, reference_lifetime: 100000h,
    reference_stress: 1.8V, stress_exponent: 40, reference_temperature: 125C,
    activation_energy: 0.6eV, max_abs_voltage: 1.98V, duty_cycle: 1)
```

The intent sets the run's temperature and a supply driven 10% above its 1.8 V rating, `hot.json`:

```json
{
  "temperature_c": 125,
  "domains": { "core": { "voltage_mv": 1980 } },
  "supplies": [
    { "net": "VDD", "domain": "core", "role": "power" },
    { "net": "VSS", "domain": "core", "role": "ground" }
  ]
}
```

```sh
gpurify erc inv.gds --deck life.deck --intent hot.json
```

**Example violation.**

```text
rules:
  tddb: ran, examined 10 shapes, found 5 violations
violations: 5
  tddb error layer met1 at (-150 nm, 3500 nm) measured 2209.492815217995 against limit 87600 on shape 8
  tddb error layer met1 at (450 nm, 3500 nm) measured 2209.492815218009 against limit 87600 on shape 8
  tddb error layer sd at (450 nm, 3500 nm) measured 2209.4928152180196 against limit 87600 on shape 15
...
```

Each of the five VDD nodes, on met1 and on the p-channel source, lasts 2209 hours against the 87600 hours required. The five VSS nodes sit at 0 V and pass. The lifetime is in hours.

**Options.**

| Parameter | Value | Meaning |
|---|---|---|
| `required_lifetime` | time | The lifetime every node must reach, in `h`. |
| `reference_lifetime` | time | The lifetime at the reference stress and temperature. |
| `reference_stress` | voltage | The voltage the reference lifetime was measured at. |
| `stress_exponent` | number | The power-law exponent in voltage. |
| `reference_temperature` | temperature | The temperature the reference lifetime was measured at, in `K` or `C`. |
| `activation_energy` | energy | The Arrhenius activation energy, in `eV`. |
| `max_abs_voltage` | voltage | The highest voltage any node may reach, whatever its lifetime. |
| `duty_cycle` | fraction | The fraction of time the stress is applied, from 0 to 1. |

**Status and limits.** Implemented. The run's temperature is the intent's `temperature_c`, or else the deck's `temperature`; with neither, the rule reports `refused`. A layer that carries supply current with no `pex` sheet resistance also makes it `refused`. The check judges supply-grid nodes, not individual devices or signal nets. With no current budget on a supply, every node sits at its nominal voltage, the largest stress.

**Sources.** JEDEC JEP122H (failure mechanisms and models); JEDEC JESD263, JESD241, JESD28 and JESD60 (dielectric and transistor reliability test methods).

## Power domains

### ERC-F6: Missing level shifter

**What it catches.** A transistor whose gate is driven from a power domain that powers neither end of its channel, with no level shifter between them. A low-swing signal into a higher-voltage gate leaves the receiving p-channel transistor partly on, which leaks static current and slows or blocks the switch.

**How GPurify measures it.** For each transistor not of a `shifters` model, GPurify compares the power domains that reach its gate with the power domains that reach its source or drain. The finding counts the domains at the gate that reach neither channel end, against a limit of 0. A transistor whose gate or channel no power supply reaches is not examined. Give every separately powered supply its own domain in the intent.

![A core inverter on VDD at 1.8 V drives an io inverter on VDDH at 3.3 V; the io inverter is flagged for a gate in core and a channel in io](../../diagrams/erc-f6.svg)

**In the deck.**

```text
rule <id> missing_level_shifter(; shifters: [<model>, ..] | none)
```

```text
grid 5nm
layer nwell = gds(1, 0)
layer diff = gds(2, 0)
layer poly = gds(3, 0)
layer cont = gds(4, 0)
layer met1 = gds(5, 0)
layer text = gds(5, 1)
layer sd = diff not poly
layer ngate = (poly and diff) not nwell
layer pgate = poly and diff and nwell
connect conductors [sd, poly, met1]
connect touch_within_layer
connect via cont [sd, met1]
connect via cont [poly, met1]
connect label text names met1
device mos ngate model "nfet" terminals [poly, sd, sd]
device mos pgate model "pfet" terminals [poly, sd, sd]
rule ls missing_level_shifter(; shifters: none)
```

The intent is `two.json` from [ERC-F1](#erc-f1-static-voltage-propagation): VDD in domain `core`, VDDH in domain `io`.

```sh
gpurify erc domains.gds --deck shifter.deck --intent two.json
```

**Example violation.**

```text
rules:
  ls: ran, examined 2 shapes, found 2 violations
violations: 2
  ls error layer ngate at (7400 nm, 1000 nm) measured 1 against limit 0 on shape 44
  ls error layer pgate at (7400 nm, 4000 nm) measured 1 against limit 0 on shape 46
...
```

Both transistors of the io inverter at x = 7400 nm have one domain, `core`, at the gate that reaches neither channel end. The core inverter's gate is a cell input that no supply reaches, so it is not examined.

**Options.**

| Parameter | Value | Meaning |
|---|---|---|
| `shifters` | list of models, or `none` | Transistor models that are level shifters by design, and are not flagged. |

**Status and limits.** Implemented. Only power supplies count: a domain's ground does not mark a net as belonging to the domain.

**Sources.** Siemens white paper 81822 (Calibre PERC); IEEE 1801 (UPF), level-shifter strategy.

### ERC-F7: Missing isolation at switchable-domain outputs

**What it catches.** A powered transistor whose gate floats in some power state, because the domain or driver feeding it is off. A floating input lets both transistors of a gate conduct, which draws static current and passes an unknown value on. An isolation cell clamps the signal in that state.

**How GPurify measures it.** GPurify propagates voltages again in each power state the intent declares. In a state, a switched-off supply holds no voltage, and a held input is a supply at its voltage, a ground at 0 V. A transistor not of an `isolation` model is flagged when, in some state, no supply reaches its gate while a power supply still reaches its source or drain. The finding counts those states against 0. Only transistors whose gate some supply reaches with every supply on are examined.

![A switch from VDD2 with EN held at 0 V leaves X floating; the inverter on always-on VDD is flagged](../../diagrams/erc-f7.svg)

**In the deck.**

```text
rule <id> missing_isolation(; isolation: [<model>, ..] | none)
```

The gate conditions make the switch turn off when EN is held low:

```text
grid 5nm
layer nwell = gds(1, 0)
layer diff = gds(2, 0)
layer poly = gds(3, 0)
layer cont = gds(4, 0)
layer met1 = gds(5, 0)
layer text = gds(5, 1)
layer sd = diff not poly
layer ngate = (poly and diff) not nwell
layer pgate = poly and diff and nwell
connect conductors [sd, poly, met1]
connect touch_within_layer
connect via cont [sd, met1]
connect via cont [poly, met1]
connect label text names met1
device mos ngate model "nfet" terminals [poly, sd, sd] on_gate_min 0.5V
device mos pgate model "pfet" terminals [poly, sd, sd] on_gate_max 1.3V
rule iso missing_isolation(; isolation: none)
```

The intent declares the power state `disable`, with EN held at 0 V, `tri.json`:

```json
{
  "domains": { "core": { "voltage_mv": 1800 } },
  "supplies": [
    { "net": "VDD", "domain": "core", "role": "power" },
    { "net": "VDD2", "domain": "core", "role": "power" },
    { "net": "VSS", "domain": "core", "role": "ground" }
  ],
  "states": [
    { "name": "disable", "inputs": [{ "net": "EN", "voltage_mv": 0 }] }
  ]
}
```

```sh
gpurify erc tristate.gds --deck isolation.deck --intent tri.json
```

**Example violation.**

```text
rules:
  iso: ran, examined 2 shapes, found 2 violations
violations: 2
  iso error layer ngate at (1400 nm, 1000 nm) measured 1 against limit 0 on shape 35
  iso error layer pgate at (1400 nm, 4000 nm) measured 1 against limit 0 on shape 37
...
```

In state `disable` the switch is off and X floats, while VDD and VSS still power the inverter at x = 1400 nm: one state each, against 0.

**Options.**

| Parameter | Value | Meaning |
|---|---|---|
| `isolation` | list of models, or `none` | Transistor models of isolation cells, which are built to take a floating input. |

**Status and limits.** Implemented. Only the power states the intent declares are examined, never every input vector. Without `states` in the intent, the rule reports `skipped`.

**Sources.** IEEE 1801 (UPF), isolation strategy; Si2 Common Power Format 2.1.

### ERC-F8: Power-state-dependent undriven gates

**What it catches.** A net that drives transistor gates and is driven with every supply on, but floats in some power state. A tristate driver whose enable is held low, or a driver in a domain that is switched off, leaves the gates it feeds at an unknown voltage.

**How GPurify measures it.** GPurify propagates voltages in each declared power state, as [ERC-F7](#erc-f7-missing-isolation-at-switchable-domain-outputs) does. A gate net that some supply reaches with every supply on, and no supply reaches in a state, is flagged. The finding counts those states against 0, at the net's lowest shape.

![The tristate example with net X circled: driven with every supply on, undriven in state disable](../../diagrams/erc-f8.svg)

**In the deck.**

```text
rule <id> undriven_gate()
```

```text
grid 5nm
layer nwell = gds(1, 0)
layer diff = gds(2, 0)
layer poly = gds(3, 0)
layer cont = gds(4, 0)
layer met1 = gds(5, 0)
layer text = gds(5, 1)
layer sd = diff not poly
layer ngate = (poly and diff) not nwell
layer pgate = poly and diff and nwell
connect conductors [sd, poly, met1]
connect touch_within_layer
connect via cont [sd, met1]
connect via cont [poly, met1]
connect label text names met1
device mos ngate model "nfet" terminals [poly, sd, sd] on_gate_min 0.5V
device mos pgate model "pfet" terminals [poly, sd, sd] on_gate_max 1.3V
rule float undriven_gate()
```

The intent is `tri.json` from [ERC-F7](#erc-f7-missing-isolation-at-switchable-domain-outputs).

```sh
gpurify erc tristate.gds --deck undriven.deck --intent tri.json
```

**Example violation.**

```text
rules:
  float: ran, examined 1 shapes, found 1 violations
violations: 1
  float error layer met1 at (8300 nm, -5700 nm) measured 1 against limit 0 on shape 18
...
```

Net X, reported at its lowest met1 shape at (8300 nm, -5700 nm), floats in one state, `disable`, against 0.

**Status and limits.** Implemented. Only the power states the intent declares are examined, never every input vector. Without `states` in the intent, the rule reports `skipped`.

**Sources.** Siemens white paper 81822 (Calibre PERC), figure 3, a tristate driver; IEEE 1801 (UPF); Siemens Insight Analyzer public material.

### ERC-F9: DC sneak path between domains

**What it catches.** A device whose channel joins nets of two power domains, such as a transistor or resistor between a 1.8 V and a 3.3 V supply. Whenever it conducts it carries DC current from one domain into the other. That wastes power, and it back-powers a domain that is meant to be off.

**How GPurify measures it.** For each device, GPurify collects the power domains that reach any of its conducting terminals: a transistor's source and drain, or every pin of a resistor, inductor, diode or bipolar transistor. The finding counts the domains against a limit of 1. A device whose channel no power supply reaches is not examined.

![An nfet with gate EN whose channel joins VDD at 1.8 V and VDDH at 3.3 V, flagged as reaching two power domains](../../diagrams/erc-f9.svg)

**In the deck.**

```text
rule <id> domain_crossing()
```

```text
grid 5nm
layer nwell = gds(1, 0)
layer diff = gds(2, 0)
layer poly = gds(3, 0)
layer cont = gds(4, 0)
layer met1 = gds(5, 0)
layer text = gds(5, 1)
layer sd = diff not poly
layer ngate = (poly and diff) not nwell
layer pgate = poly and diff and nwell
connect conductors [sd, poly, met1]
connect touch_within_layer
connect via cont [sd, met1]
connect via cont [poly, met1]
connect label text names met1
device mos ngate model "nfet" terminals [poly, sd, sd]
device mos pgate model "pfet" terminals [poly, sd, sd]
rule xing domain_crossing()
```

The intent is `two.json` from [ERC-F1](#erc-f1-static-voltage-propagation).

```sh
gpurify erc crossing.gds --deck crossing.deck --intent two.json
```

**Example violation.**

```text
rules:
  xing: ran, examined 5 shapes, found 1 violations
violations: 1
  xing error layer ngate at (4400 nm, 9000 nm) measured 2 against limit 1 on shape 56
...
```

The transistor at (4400 nm, 9000 nm) joins VDD and VDDH: two power domains against a limit of 1. The level-shift buffer beside it keeps each channel in one domain and passes.

**Status and limits.** Implemented. Only power supplies count: a device between a domain's power net and another domain's ground is not flagged.

**Sources.** Siemens Calibre PERC datasheet; Siemens white paper 81822 (Calibre PERC), figure 2.

## High-voltage layout

### ERC-F10: High-voltage tag consistency

**What it catches.** Two related mistakes in a layout with high-voltage devices. A device whose terminals reach supply domains too far apart, unless it sits inside an isolation marker. And a well, or another conductor, on the same net as a high-voltage-tagged one but drawn without the tag, so the high-voltage spacing and enclosure rules miss it.

**How GPurify measures it.** `hv_domain` takes, for each device whose every terminal some supply reaches, the domain voltages of the supplies that reach any terminal. A ground counts its domain's voltage here, not 0 V. The spread from the lowest to the highest is held to `max_delta`. A device whose marker lies entirely inside one `isolation` shape is exempt.

`mixed_tag` looks at each shape of the conductor layer, touching shapes as one. A shape that shares no area with the tag layer is flagged when its net also holds a shape that does. Nets joined through a resistor count as one net. The finding counts the tagged shapes on the net against 0.

![A core inverter whose untagged n-well is tied to VDDH, and an io inverter in a tagged well spanning 1.5 V; both flagged](../../diagrams/erc-f10.svg)

**In the deck.**

```text
rule <id> hv_domain(; max_delta: <voltage>, isolation: <layer> | none)
rule <id> mixed_tag(<conductor>, <tag>)
```

The wells are conductors here, tied by n-taps:

```text
grid 5nm
layer nwell = gds(1, 0)
layer diff = gds(2, 0)
layer poly = gds(3, 0)
layer cont = gds(4, 0)
layer met1 = gds(5, 0)
layer text = gds(5, 1)
layer tap = gds(6, 0)
layer hv = gds(9, 0)
layer sd = diff not poly
layer ngate = (poly and diff) not nwell
layer pgate = poly and diff and nwell
layer ntap = tap and nwell
connect conductors [sd, poly, met1, ntap, nwell]
connect touch_within_layer
connect via cont [sd, met1]
connect via cont [poly, met1]
connect via cont [ntap, met1]
connect via ntap [ntap, nwell]
connect label text names met1
device mos ngate model "nfet" terminals [poly, sd, sd]
device mos pgate model "pfet" terminals [poly, sd, sd]
rule hv.span hv_domain(; max_delta: 1V, isolation: none)
rule hvnwell.10 mixed_tag(nwell, hv)
```

The intent is `two.json` from [ERC-F1](#erc-f1-static-voltage-propagation).

```sh
gpurify erc hv.gds --deck hv.deck --intent two.json
```

**Example violation.**

```text
rules:
  hv.span: ran, examined 2 shapes, found 2 violations
  hvnwell.10: ran, examined 2 shapes, found 1 violations
violations: 3
  hv.span error layer ngate at (7400 nm, 1000 nm) measured 1500 mV against limit 1000 mV on shape 52
  hv.span error layer pgate at (7400 nm, 4000 nm) measured 1500 mV against limit 1000 mV on shape 54
  hvnwell.10 error layer nwell at (-500 nm, 2500 nm) measured 1 against limit 0 on shape 29 and shape 30
...
```

The io inverter at x = 7400 nm spans 1.8 V at its gate to 3.3 V at its source, 1.5 V against 1 V. The core inverter's n-well at (-500 nm, 2500 nm) is tied to VDDH, which also holds the tagged well, but it carries no `hv` tag.

**Options.**

| Parameter | Value | Meaning |
|---|---|---|
| `max_delta` | voltage | The largest spread of domain voltages one device may reach. |
| `isolation` | layer, or `none` | A device whose marker lies inside one shape of this layer is exempt. |

**Status and limits.** Implemented. `hv_domain` judges only devices whose every terminal some supply reaches. SkyWater SKY130 hvnwell.9 and GF180MCU DV.9 are DRC rules on derived layers, written with `inside` and `forbidden` (see [DRC checks](../drc/README.md)).

**Sources.** [SkyWater SKY130](https://skywater-pdk.readthedocs.io/en/main/rules/periphery.html) rules hv.X.1, hvnwell.9 and hvnwell.10; [GlobalFoundries GF180MCU design manual](https://gf180mcu-pdk.readthedocs.io/en/latest/physical_verification/design_man.html) rule DV.9.

### ERC-F11: Voltage-dependent spacing

**What it catches.** Two wires on different nets placed closer than the voltage between them allows. A higher voltage across a gap needs more space to avoid dielectric breakdown and leakage. This is the same check as DRC-082, listed with the [DRC checks](../drc/README.md).

**How GPurify measures it.** For each pair of shapes on two different nets, GPurify takes the worst-case voltage between the nets: the highest one can reach minus the lowest the other can. The table's step with the largest voltage at or below that difference sets the space the pair needs. Space is measured edge to edge. A pair below the first voltage needs nothing, and a pair with a net no supply reaches is not judged.

![Three met1 lines 300 nm apart: VDDH to VSS needs 500 nm and is flagged, VSS to VDD needs 200 nm and passes](../../diagrams/erc-f11.svg)

**In the deck.**

```text
rule <id> voltage_space(<conductor>; voltage: [<voltage>, ..], space: [<length>, ..])
rule <id> voltage_space(<conductor>, <conductor>; voltage: [<voltage>, ..], space: [<length>, ..])
```

```text
grid 5nm
layer met1 = gds(5, 0)
layer text = gds(5, 1)
connect conductors [met1]
connect touch_within_layer
connect label text names met1
rule m1.vs voltage_space(met1; voltage: [0V, 2V], space: [200nm, 500nm])
```

The intent is `two.json` from [ERC-F1](#erc-f1-static-voltage-propagation).

```sh
gpurify erc lines.gds --deck vspace.deck --intent two.json
```

**Example violation.**

```text
rules:
  m1.vs: ran, examined 2 shapes, found 1 violations
violations: 1
  m1.vs error layer met1 at (5000 nm, 650 nm) measured 300 nm against limit 500 nm on shape 0 and shape 1
...
```

VDDH and VSS are 3.3 V apart, which reaches the 2 V step, so their 300 nm gap breaks the 500 nm limit. The point is midway across the gap. VSS and VDD are 1.8 V apart and need only 200 nm.

**Options.**

| Parameter | Value | Meaning |
|---|---|---|
| `voltage` | list of voltages | The step voltages, from 0 V up, rising. |
| `space` | list of lengths | The space from each step up, one per voltage, never falling. |

**Status and limits.** Implemented. A difference exactly at a step's voltage needs that step's space, and a gap exactly at the space passes. The layers must be conductors; any other layer is an error when the deck loads. With two layers, overlapping shapes count as a gap of 0.

**Sources.** [SkyWater SKY130](https://skywater-pdk.readthedocs.io/en/main/rules/periphery.html) rule hvnwell.8 and the hv rules; LEF `LEF58_VOLTAGESPACING`.

## Junction bias and dielectric field

### ERC-F12: Well and body bias

**What it catches.** A p-channel transistor whose source or drain can rise above its n-well, or an n-channel transistor whose source or drain can fall below its p-well or substrate. That forward-biases the junction between them. It injects current into the well, which wastes power and risks latch-up.

**How GPurify measures it.** For a `pmos` model, GPurify takes the highest voltage the source or drain can reach, minus the lowest the bulk can. For an `nmos` model, the highest the bulk can reach, minus the lowest of the source or drain. Anything above 0 V is flagged. A transistor whose bulk, or both of whose channel ends, no supply reaches is not examined. The bulk is the fourth terminal of the `device` row, so the wells must be nets.

![A pfet with its source on VDDH at 3.3 V and its n-well on VDD at 1.8 V; the source-to-well diode is forward-biased by 1.5 V](../../diagrams/erc-f12.svg)

**In the deck.**

```text
rule <id> well_bias(; pmos: [<model>, ..] | none, nmos: [<model>, ..] | none)
```

```text
grid 5nm
layer nwell = gds(1, 0)
layer diff = gds(2, 0)
layer poly = gds(3, 0)
layer cont = gds(4, 0)
layer met1 = gds(5, 0)
layer text = gds(5, 1)
layer tap = gds(6, 0)
layer sd = diff not poly
layer ngate = (poly and diff) not nwell
layer pgate = poly and diff and nwell
layer ntap = tap and nwell
connect conductors [sd, poly, met1, ntap, nwell]
connect touch_within_layer
connect via cont [sd, met1]
connect via cont [poly, met1]
connect via cont [ntap, met1]
connect via ntap [ntap, nwell]
connect label text names met1
device mos ngate model "nfet" terminals [poly, sd, sd]
device mos pgate model "pfet" terminals [poly, sd, sd, nwell]
rule wb well_bias(; pmos: ["pfet"], nmos: none)
```

The intent is `two.json` from [ERC-F1](#erc-f1-static-voltage-propagation).

```sh
gpurify erc well.gds --deck well.deck --intent two.json
```

**Example violation.**

```text
rules:
  wb: ran, examined 1 shapes, found 1 violations
violations: 1
  wb error layer pgate at (1400 nm, 4000 nm) measured 1500 mV against limit 0 mV on shape 27
...
```

The p-channel transistor's source sits on VDDH at 3.3 V, while an n-tap ties its well to VDD at 1.8 V: 1.5 V of forward bias against 0 mV.

**Options.**

| Parameter | Value | Meaning |
|---|---|---|
| `pmos` | list of models, or `none` | P-channel models, whose well must not sit below the source or drain. |
| `nmos` | list of models, or `none` | N-channel models, whose well or substrate must not sit above the source or drain. |

**Status and limits.** Implemented. Of the shipped decks, only `sky130` gives its transistors a bulk terminal, so only it carries this check.

**Sources.** [GlobalFoundries GF180MCU design manual](https://gf180mcu-pdk.readthedocs.io/en/latest/physical_verification/design_man.html) rules LU.9 and LU.10.

### ERC-F13: Inter-metal dielectric breakdown

**What it catches.** Two wires on different nets whose voltage apart, over the dielectric between them, exceeds the field the dielectric is rated for. Too high a field breaks the dielectric down, at once or over the chip's life.

**How GPurify measures it.** For each pair of shapes on two different nets, GPurify takes the worst-case voltage between the nets, \\( \Delta V \\), and the separation it needs, \\( \Delta V / E_\text{max} \\). Between two layers, the dielectric thickness \\( t \\) between them carries part of it, so the lateral gap needed is

\\[ g = \sqrt{ \left( \frac{\Delta V}{E_\text{max}} \right)^2 - t^2 } \\]

where \\( E_\text{max} \\) is `max_field` and \\( t \\) is the upper layer's `pex` height less the lower layer's height and thickness. On one layer \\( t = 0 \\). The gap needed is rounded up to the grid, and a pair the vertical dielectric alone holds needs no gap. In the example, 3.3 V / 10 V/µm = 330 nm.

![The three met1 lines: VDDH to VSS needs 330 nm and is flagged at 300 nm, VSS to VDD needs 180 nm and passes](../../diagrams/erc-f13.svg)

**In the deck.**

```text
rule <id> dielectric_field(<conductor>; max_field: <field>)
rule <id> dielectric_field(<lower>, <upper>; max_field: <field>)
```

```text
grid 5nm
layer met1 = gds(5, 0)
layer text = gds(5, 1)
connect conductors [met1]
connect touch_within_layer
connect label text names met1
rule m1.field dielectric_field(met1; max_field: 10V/um)
```

The intent is `two.json` from [ERC-F1](#erc-f1-static-voltage-propagation).

```sh
gpurify erc lines.gds --deck field.deck --intent two.json
```

**Example violation.**

```text
rules:
  m1.field: ran, examined 2 shapes, found 1 violations
violations: 1
  m1.field error layer met1 at (5000 nm, 650 nm) measured 300 nm against limit 330 nm on shape 0 and shape 1
...
```

VDDH and VSS are 3.3 V apart, so they need 330 nm at 10 V/µm and are 300 nm apart. The report shows the gap against the gap the field needs.

**Options.**

| Parameter | Value | Meaning |
|---|---|---|
| `max_field` | field | The highest field the dielectric may carry, in `V/um`, `V/nm` or `MV/cm`. |

**Status and limits.** Implemented. The check is a field limit, not a time-dependent breakdown lifetime. The two-layer form needs a `pex` row with a height and a thickness for both layers, with dielectric between them; without them it reports `refused`.

**Sources.** Synopsys IC Validator public material; JEDEC JEP159A (inter-metal dielectric breakdown).

## Power intent

### ERC-F14: Power-intent supply connectivity

**What it catches.** A power switch that is wired or controlled wrongly. A switch must join an always-on supply to a switched one of the same role, a header between two power nets or a footer between two grounds. Its control must come from logic that stays powered, or the switch's state is unknown when the domain is off.

**How GPurify measures it.** A supply that some declared power state turns off is switched; every other supply is always on. For each transistor of the listed models, GPurify flags two things:

- The channel does not join an always-on supply to a switched supply of the same role. That finding measures 0 against 1.
- The gate floats in some power state: no supply reaches it there. That finding counts those states against 0.

![A p-channel header from always-on VDD to VDD_SW, switched off in state sleep; its gate EN floats and is flagged](../../diagrams/erc-f14.svg)

**In the deck.**

```text
rule <id> power_switch(; models: [<model>, ..])
```

```text
grid 5nm
layer nwell = gds(1, 0)
layer diff = gds(2, 0)
layer poly = gds(3, 0)
layer cont = gds(4, 0)
layer met1 = gds(5, 0)
layer text = gds(5, 1)
layer sd = diff not poly
layer ngate = (poly and diff) not nwell
layer pgate = poly and diff and nwell
connect conductors [sd, poly, met1]
connect touch_within_layer
connect via cont [sd, met1]
connect via cont [poly, met1]
connect label text names met1
device mos ngate model "nfet" terminals [poly, sd, sd] on_gate_min 0.5V
device mos pgate model "pfet" terminals [poly, sd, sd] on_gate_max 1.3V
rule psw power_switch(; models: ["pfet"])
```

The intent declares VDD_SW and a state that switches it off, `sleep.json`:

```json
{
  "domains": { "core": { "voltage_mv": 1800 } },
  "supplies": [
    { "net": "VDD", "domain": "core", "role": "power" },
    { "net": "VDD_SW", "domain": "core", "role": "power" },
    { "net": "VSS", "domain": "core", "role": "ground" }
  ],
  "states": [
    { "name": "sleep", "off": ["VDD_SW"] }
  ]
}
```

```sh
gpurify erc header.gds --deck header.deck --intent sleep.json
```

**Example violation.**

```text
rules:
  psw: ran, examined 1 shapes, found 1 violations
violations: 1
  psw error layer pgate at (4400 nm, 9000 nm) measured 1 against limit 0 on shape 15
...
```

The header joins VDD to VDD_SW as it should, but its gate EN is reached by no supply, so it floats in the one declared state, `sleep`.

**Options.**

| Parameter | Value | Meaning |
|---|---|---|
| `models` | list of models | The transistor models that are power switches. |

**Status and limits.** Partial. The power intent is the design intent, not a UPF file, which GPurify does not read. GPurify does not check retention cells (save and restore from always-on logic, the retention supply), always-on cells in a switched domain, or standard cells tied to the real rather than the virtual supply: the intent does not say which cells are which. Without `states` in the intent, the rule reports `skipped`.

**Sources.** IEEE 1801 (UPF), power-switch strategy; Liu et al., ["Low Power Verification with UPF: Principle and Practice"](https://dvcon-proceedings.org/wp-content/uploads/low-power-verification-with-upf-principle-and-practice.pdf), DVCon, power-switch rule 3; ["Failing to Fail" UPF tutorial](https://islped.org/2014/files/Failing%20to%20fail%20UPF%20tutorial%20.pdf), ISLPED 2014, `create_power_switch`.
