# Electromigration and IR-drop checks

These checks solve the resistance of your supply wiring with the current your design intent gives each
net, then hold every wire, cut and node to a current, voltage or lifetime limit. How the current is
shared out, derated for temperature and turned into a verdict is explained in
[How GPurify computes IR drop and electromigration](../../explanation/ir-drop-and-em.md).

The checks that solve the grid need `--intent` (see [Design intent](../design-intent.md)) and a `pex`
row with a sheet resistance on every conducting layer and cut. Without a declared supply they report
`skipped`; without a sheet resistance on a layer that carries current they report `refused`.

## Current density limits

### ERC-E1: DC current per width

**What it catches.** A wire that carries more direct current than its width allows. Metal atoms drift
with the electron flow, and above the foundry's current density a wire voids and opens, or extrudes
and shorts to a neighbour, within the product's life.

**How GPurify measures it.** GPurify cuts each shape of a supply net into segments between its taps,
solves the current through every segment, and compares that current with `max_density` times the
segment's width. The width is the narrowest cross-section the segment passes through. A violation sits
at the segment's first node and names the shapes at both ends.

![A met1 rail fed at 50 µm with 3 mA loads at 40 µm and 90 µm; both segments carry 3000 µA, over the 2800 µA limit](../../diagrams/erc-e1.svg)

**In the deck.**

```text
rule <id> em_current_density(<layer>, ...; max_density: <current per width>, max_current_per_cut: <current>, narrow: (width: <length>, current: <current>) | none)
```

The example deck `em.deck`: the layers, connectivity, a `load` device and the `pex` rows the grid reads,
then the rule. The other entries on this page add their rules to the same deck.

```text
grid 1nm
layer met1 = gds(1, 0)
layer via1 = gds(2, 0)
layer met2 = gds(3, 0)
layer poly = gds(4, 0)
layer mk = gds(5, 0)
layer met1_text = gds(11, 0)
layer met2_text = gds(13, 0)
layer poly_text = gds(14, 0)
connect conductors [met1, met2, poly]
connect touch_within_layer
connect via via1 [met1, met2]
connect label met1_text names met1
connect label met2_text names met2
connect label poly_text names poly
device resistor mk model "load" terminals [met1, poly]
pex met1 thickness 360nm height 1376nm sheet 0.125ohm dielectric 3.9 area_cap 25.8aF/um2 fringe_cap 40.5aF/um
pex via1 thickness 270nm height 1736nm sheet 4.5ohm dielectric 3.9 area_cap 1aF/um2 fringe_cap 1aF/um
pex met2 thickness 360nm height 2006nm sheet 0.125ohm dielectric 3.9 area_cap 17.5aF/um2 fringe_cap 37.6aF/um
pex poly thickness 180nm height 330nm sheet 48.2ohm dielectric 3.9 area_cap 106aF/um2 fringe_cap 55.3aF/um
rule EM.met1 em_current_density(met1; max_density: 2.8mA/um, max_current_per_cut: 0.36mA, narrow: none)
```

The intent file `rail.json` declares `VDD` and its current budget:

```json
{
  "temperature_c": 85,
  "domains": { "core": { "voltage_mv": 1800 } },
  "supplies": [ { "net": "VDD", "domain": "core", "role": "power" } ],
  "limits": [ { "net": "VDD", "budget_current_ua": 6000, "max_drop_mv": 10 } ]
}
```

```sh
gpurify erc rail.gds --deck em.deck --intent rail.json
```

**Example violation.** The layout `rail.gds` is a met1 rail 100 µm long and 1 µm wide, labelled `VDD`,
with a `load` at 40 µm and at 90 µm. Its only shape is fed at its centre, 50 µm.

```text
rules:
  EM.met1: ran, examined 2 shapes, found 2 violations
violations: 2
  EM.met1 error layer met1 at (40000 nm, 500 nm) measured 3000 uA against limit 2800.0000000000005 uA on shape 0 and shape 0
  EM.met1 error layer met1 at (50000 nm, 500 nm) measured 3000 uA against limit 2800.0000000000005 uA on shape 0 and shape 0
...
```

Each load draws half of the 6000 µA budget, so both segments from the feed carry 3000 µA against
2.8 mA/µm × 1 µm = 2800 µA.

**Options.**

| Parameter | Value | Meaning |
|---|---|---|
| `max_density` | current per width | The allowed current per unit of wire width, such as `2.8mA/um`. |
| `max_current_per_cut` | current | The allowed current through one cut on a cut layer the row lists. |
| `narrow` | `(width: <length>, current: <current>)` or `none` | An absolute current for wires at most `width` wide, in place of `max_density` times the width. |

**Status and limits.** Implemented. Each supply net is fed from one point, the centre of its highest,
then widest, shape, so a rail fed from several pads reads more current near that point than it has.
A net's budget is shared equally among the device terminals on it; simulated currents
([ERC-E14](#erc-e14-simulation-driven-em-and-ir-drop)) replace that share. Signal nets carry no
current unless simulated currents load them.

**Sources.** [GF180MCU Design Rule Manual](https://gf180mcu-pdk.readthedocs.io/en/latest/physical_verification/design_man.html)
Table 14.3; [IHP SG13G2 Process Specification](https://github.com/IHP-GmbH/IHP-Open-PDK/tree/main/ihp-sg13g2/libs.doc/doc)
§2.15; [OpenROAD `psm`](https://openroad.readthedocs.io/en/latest/main/src/psm/README.html).

### ERC-E2: Current per cut

**What it catches.** A via or contact cut that carries more current than one cut is rated for. A single
cut on a power path voids long before the wires beside it, and the foundry states a separate limit for
it.

**How GPurify measures it.** Every cut is its own resistor between the two shapes it joins, with the
cut layer's `sheet` as its resistance. GPurify compares the current through each cut with
`max_current_per_cut`. List the cut layer in the same row as its metal, or in a row of its own.

![A met2 pad feeds a met1 rail through one via1 cut; the cut carries 1000 µA against a 290 µA limit, the met1 segments pass](../../diagrams/erc-e2.svg)

**In the deck.**

```text
rule <id> em_current_density(<metal>, <cut>; max_density: <current per width>, max_current_per_cut: <current>, narrow: none)
```

Added to `em.deck`, with the limits the shipped `sky130` deck gives met2 and its via:

```text
rule EM.met1_via1 em_current_density(met1, via1; max_density: 2.8mA/um, max_current_per_cut: 0.29mA, narrow: none)
```

The intent is `rail.json` with `"budget_current_ua": 1000`.

**Example violation.** The layout `via.gds` is a met1 rail 20 µm × 1 µm with a 2 µm × 1 µm met2 pad over
its left end, joined by one 0.2 µm via1 cut. The pad is the feed, and one load sits at 18 µm.

```text
rules:
  EM.met1_via1: ran, examined 3 shapes, found 1 violations
violations: 1
  EM.met1_via1 error layer via1 at (1000 nm, 500 nm) measured 1000 uA against limit 290 uA on shape 0 and shape 1
...
```

The one cut at (1 µm, 0.5 µm) carries the whole 1000 µA against 290 µA. The met1 segments carry the
same 1000 µA against 2800 µA and pass.

**Options.** As for [ERC-E1](#erc-e1-dc-current-per-width): `max_density` applies to the metal layers
of the row and `max_current_per_cut` to its cut layers. A cut row must still state `max_density`; it is
not read.

**Status and limits.** Implemented. Each cut is one resistor of the cut layer's resistance, so an
array of cuts shares the current by count. Current crowding at the cut's edge is not modelled.

**Sources.** GF180MCU Design Rule Manual Table 14.4; IHP SG13G2 Process Specification §2.15;
SkyWater SKY130 `sky130_fd_sc_hd` technology LEF (average current at 90 °C).

### ERC-E3: Width-banded absolute current for narrow lines

**What it catches.** A narrow line that carries more than the absolute current its width band allows.
For the narrowest lines some foundries state a fixed current rather than a current per width.

**How GPurify measures it.** For a segment at most `narrow`'s `width` wide, the limit is `narrow`'s
`current`. For a wider segment, the limit is `max_density` times the width.

![A 300 nm met1 line carrying 400 µA from the feed to its load, over the 360 µA narrow-band limit](../../diagrams/erc-e3.svg)

**In the deck.**

```text
rule <id> em_current_density(<layer>; max_density: <current per width>, max_current_per_cut: <current>, narrow: (width: <length>, current: <current>))
```

Added to `em.deck`, as the shipped `ihp_sg13g2` deck states Metal1:

```text
rule EM.Metal1 em_current_density(met1; max_density: 1mA/um, max_current_per_cut: 0.3mA, narrow: (width: 360nm, current: 0.36mA))
```

The intent is `rail.json` with `"budget_current_ua": 400`.

**Example violation.** The layout `narrow.gds` is a met1 rail 20 µm long and 300 nm wide, fed at its
centre, with one load at 18 µm.

```text
rules:
  EM.Metal1: ran, examined 1 shapes, found 1 violations
violations: 1
  EM.Metal1 error layer met1 at (10000 nm, 150 nm) measured 399.99999999997726 uA against limit 360 uA on shape 0 and shape 0
...
```

The segment from the feed at 10 µm to the load carries 400 µA. At 300 nm it is inside the 360 nm band,
so its limit is 360 µA.

**Options.** As for [ERC-E1](#erc-e1-dc-current-per-width).

**Status and limits.** Implemented. One band per row: a foundry table with several narrow bands
keeps only the one you state.

**Sources.** IHP SG13G2 Process Specification §2.15.

## Derating and lifetime

### ERC-E4: Temperature derating

**What it catches.** A wire that is within its current limit at the temperature the foundry rated it,
but over it at the temperature your chip runs at. Electromigration speeds up with temperature, so a
limit rated at 85 °C allows less current at 125 °C.

**How GPurify measures it.** GPurify scales each limit by Black's equation, held at equal lifetime:

\\[ I_\text{allowed}(T) = I_\text{ref} \exp\left( \frac{E_a}{n k} \left( \frac{1}{T} - \frac{1}{T_\text{ref}} \right) \right) \\]

where \\( I_\text{ref} \\) is `max_density` times the width (or `max_current_per_cut`) rated at
\\( T_\text{ref} \\), `reference_temperature`; \\( E_a \\) is `activation_energy`; \\( n \\) is
`current_exponent`; \\( k \\) is Boltzmann's constant, 8.617 × 10⁻⁵ eV/K; and \\( T \\) is the run's
temperature in kelvin. That temperature is the intent's `temperature_c`, else the deck's `temperature`.
With neither, the rule reports `refused`. The derivation is in
[How GPurify computes IR drop and electromigration](../../explanation/ir-drop-and-em.md#temperature-and-blacks-equation).

![Allowed current of a 1 µm met1 wire against temperature: 2090 µA at 85 °C, 669 µA at 125 °C, under the segment's 1000 µA](../../diagrams/erc-e4.svg)

**In the deck.**

```text
rule <id> electromigration(<layer>, ...; max_density: <current per width>, max_current_per_cut: <current>, blech_limit: <current>, reference_temperature: <temperature>, activation_energy: <energy>, current_exponent: <number>)
```

Added to `em.deck`, with the GF180MCU Metal1 limit at 85 °C and the manual's own 0.7 eV and n = 2:

```text
rule EM.m1 electromigration(met1; max_density: 2.09mA/um, max_current_per_cut: 0.58mA, blech_limit: 20mA, reference_temperature: 85C, activation_energy: 0.7eV, current_exponent: 2)
```

The intent is `rail.json` with `"temperature_c": 125` and `"budget_current_ua": 2000`.

**Example violation.** The layout is `rail.gds` from ERC-E1, each load drawing 1000 µA.

```text
rules:
  EM.m1: ran, examined 1 shapes, found 1 violations
violations: 1
  EM.m1 error layer met1 at (50000 nm, 500 nm) measured 1000 uA against limit 668.8803850984727 uA on shape 0 and shape 0
...
```

At 125 °C the 2090 µA limit falls by a factor of 0.320 to 669 µA, and the segment from the feed at
50 µm carries 1000 µA. Run at `"temperature_c": 85`, the same layout passes. The 10 µm segment to the
load at 40 µm is not checked: it is short enough to be immortal ([ERC-E6](#erc-e6-blech-short-length-immortality)).

**Options.**

| Parameter | Value | Meaning |
|---|---|---|
| `max_density` | current per width | The current per width allowed at `reference_temperature`. |
| `max_current_per_cut` | current | The current per cut allowed at `reference_temperature`. |
| `blech_limit` | current | A segment whose current times its line length over its width is at or below this is immortal and not checked (ERC-E6). |
| `reference_temperature` | temperature | The temperature the limits are rated at, such as `85C` or `358.15K`. |
| `activation_energy` | energy | \\( E_a \\) in Black's equation, such as `0.7eV`. |
| `current_exponent` | number | \\( n \\) in Black's equation. |

**Status and limits.** Implemented. One temperature applies to the whole run, with no self-heating;
`em_thermal` adds each wire's own heating ([ERC-E13](#erc-e13-thermal-aware-and-statistical-em)).

**Sources.** GF180MCU Design Rule Manual §14.2.2; J. R. Black, IEEE Trans. Electron Devices 16(4), 1969,
[doi:10.1109/T-ED.1969.16754](https://doi.org/10.1109/T-ED.1969.16754); JEDEC JEP122; JEDEC JESD63.

### ERC-E5: Lifetime target and percentile

**What it catches.** A design held to a lifetime the foundry's limits were not rated for, or a supply
node whose voltage stress wears it out before the required lifetime. A foundry rates its current limits
for one lifetime at one failure percentile, and a product that must last longer needs more margin.

**How GPurify measures it.** The `electromigration` limit stands for the foundry's lifetime and
percentile, as the deck states it. `em_thermal`'s `limit_failure` names that percentile and its
`max_failure` sets a failure budget for the whole chip ([ERC-E13](#erc-e13-thermal-aware-and-statistical-em)).
`reliability` predicts each supply node's lifetime under its voltage stress:

\\[ t = \frac{t_\text{ref}}{d} \left( \frac{V_\text{ref}}{|V|} \right)^{m} \exp\left( \frac{E_a}{k} \left( \frac{1}{T} - \frac{1}{T_\text{ref}} \right) \right) \\]

where \\( t_\text{ref} \\) is `reference_lifetime` at the voltage \\( V_\text{ref} \\),
`reference_stress`, and the temperature \\( T_\text{ref} \\), `reference_temperature`; \\( d \\) is
`duty_cycle`; \\( m \\) is `stress_exponent`; \\( V \\) is the node's solved voltage; and \\( T \\) is
the run's temperature. A node is flagged when \\( t \\) is below `required_lifetime`, or when
\\( |V| \\) is above `max_abs_voltage`.

![The met1 rail's three nodes at 1975 mV to 1980 mV, each predicting about 68 000 h against 87 600 h required](../../diagrams/erc-e5.svg)

**In the deck.**

```text
rule <id> reliability(; required_lifetime: <hours>, reference_lifetime: <hours>, reference_stress: <voltage>, stress_exponent: <number>, reference_temperature: <temperature>, activation_energy: <energy>, max_abs_voltage: <voltage>, duty_cycle: <fraction>)
```

Added to `em.deck`, holding the grid to ten years:

```text
rule life reliability(; required_lifetime: 87600h, reference_lifetime: 100000h, reference_stress: 1.8V, stress_exponent: 4, reference_temperature: 125C, activation_energy: 0.7eV, max_abs_voltage: 2.2V, duty_cycle: 1)
```

The intent is `rail.json` with `"temperature_c": 125`, the domain at `"voltage_mv": 1980` and
`"budget_current_ua": 2000`.

**Example violation.** The layout is `rail.gds` from ERC-E1.

```text
rules:
  life: ran, examined 3 shapes, found 3 violations
violations: 3
  life error layer met1 at (40000 nm, 500 nm) measured 68474.09624518761 against limit 87600 on shape 0
  life error layer met1 at (50000 nm, 500 nm) measured 68301.34553650705 against limit 87600 on shape 0
  life error layer met1 at (90000 nm, 500 nm) measured 68995.63572152775 against limit 87600 on shape 0
...
```

The feed at 50 µm sits at 1980 mV, 10% over the rated 1.8 V, so it lasts
100 000 h × (1.8 / 1.98)⁴ = 68 301 h, under the 87 600 h required. The measured values are hours.

**Options.**

| Parameter | Value | Meaning |
|---|---|---|
| `required_lifetime` | hours | The lifetime every node must reach. |
| `reference_lifetime` | hours | The lifetime at `reference_stress` and `reference_temperature`. |
| `reference_stress` | voltage | The voltage the reference lifetime is stated at. |
| `stress_exponent` | number | \\( m \\), the power of the voltage ratio. |
| `reference_temperature` | temperature | The temperature the reference lifetime is stated at. |
| `activation_energy` | energy | \\( E_a \\) of the thermal term. |
| `max_abs_voltage` | voltage | The highest voltage any node may reach. |
| `duty_cycle` | fraction | The fraction of the lifetime the stress is applied, 0 to 1. |

**Status and limits.** Implemented. GPurify does not rescale an `electromigration` limit to another
lifetime. To sign off for a lifetime \\( t \\) other than the foundry's \\( t_0 \\), scale
`max_density` by \\( (t_0 / t)^{1/n} \\) yourself. `reliability` reads the supply grid solved with the
budgets, not simulated currents.

**Sources.** GF180MCU Design Rule Manual §14.2; IHP SG13G2 Process Specification §2.15 (limits for
11 years at 105 °C); JEDEC JESD202; JEDEC JEP122.

### ERC-E6: Blech short-length immortality

**What it catches.** Nothing extra: this check removes false violations. In a short line the stress
that builds up against a diffusion barrier pushes the metal back as fast as the current drives it, so
the line never fails. Foundries exempt such lines from the current limit.

**How GPurify measures it.** A line is the metal between diffusion barriers: the feed point, a loaded
tap and every via landing. For each segment GPurify computes the Blech product

\\[ P = \frac{|I| \, L}{W} \\]

where \\( I \\) is the segment's current, \\( L \\) is the length of the line it lies in and \\( W \\)
is its width. A segment with \\( P \\) at or below `blech_limit` is immortal: it is neither checked nor
counted as examined. Since \\( |I| / W = j \, t \\), with \\( j \\) the current density and \\( t \\)
the metal thickness, set `blech_limit` to the foundry's \\( (jL)_c \\) times the layer's thickness.

![A met1 rail cut into a 10 µm line, immortal at 10 mA against 20 mA, and a 40 µm line, mortal at 40 mA and over its limit](../../diagrams/erc-e6.svg)

**In the deck.** `blech_limit` on an `electromigration` or `em_thermal` row:

```text
rule <id> electromigration(<layer>; ..., blech_limit: <current>, ...)
```

The ERC-E4 row states `blech_limit: 20mA`:

```text
rule EM.m1 electromigration(met1; max_density: 2.09mA/um, max_current_per_cut: 0.58mA, blech_limit: 20mA, reference_temperature: 85C, activation_energy: 0.7eV, current_exponent: 2)
```

**Example violation.** The ERC-E4 run, on `rail.gds` at 125 °C:

```text
rules:
  EM.m1: ran, examined 1 shapes, found 1 violations
violations: 1
  EM.m1 error layer met1 at (50000 nm, 500 nm) measured 1000 uA against limit 668.8803850984727 uA on shape 0 and shape 0
...
```

The 10 µm line from the load at 40 µm to the feed has \\( P = 1000 \times 10 / 1 \\) µA = 10 mA, under
20 mA, so it is immortal and `examined` counts 1. The 40 µm line has \\( P = 40 \\) mA, is checked and
fails.

**Options.** `blech_limit`, as in the [ERC-E4 options](#erc-e4-temperature-derating). One value applies
to every layer of the row, so give layers of different thickness rows of their own.

**Status and limits.** Implemented. A branched line's \\( L \\) is the length of all its branches, which
errs toward mortal. A cut is a line of its own, \\( L \\) the height between the layers it joins.

**Sources.** I. A. Blech, J. Appl. Phys. 47(4), 1976,
[doi:10.1063/1.322842](https://doi.org/10.1063/1.322842).

## RMS and peak current

### ERC-E7: RMS and peak current limits

**What it catches.** A wire whose RMS current heats it beyond its rating, or whose peak current is over
the instantaneous limit. Alternating current causes little net drift, but Joule heating follows the
RMS current and a high peak melts or fuses a narrow wire.

**How GPurify measures it.** `em_rms` and `em_peak` solve the supply grid again with each net's
`rms_current_ua` or `peak_current_ua` from the intent in place of its budget. The allowed current is
the `density` table read at the wire's width and the net's `frequency_mhz`, linear between points on
both axes and held at the ends, times the width. A cut is held to `max_current_per_cut`. These are
LEF's `ACCURRENTDENSITY RMS` and `PEAK` tables.

![The met1 rail carrying 7000 µA RMS in each segment against a 6100 µA limit; the 15 000 µA peak passes 20 000 µA](../../diagrams/erc-e7.svg)

**In the deck.**

```text
rule <id> em_rms(<layer>, ...; frequency: [<frequency>, ...], width: [<length>, ...], density: [[<current per width>, ...], ...], max_current_per_cut: <current>)
rule <id> em_peak(<layer>, ...; frequency: [<frequency>, ...], width: [<length>, ...], density: [[<current per width>, ...], ...], max_current_per_cut: <current>)
```

Added to `em.deck`, the RMS row with the 6.1 mA/µm met1 value of the SkyWater SKY130 technology LEF:

```text
rule EM.met1.rms em_rms(met1; frequency: [100MHz], width: [0um], density: [[6.1mA/um]], max_current_per_cut: 1000uA)
rule EM.met1.peak em_peak(met1; frequency: [100MHz], width: [0um], density: [[20mA/um]], max_current_per_cut: 1000uA)
```

The intent's `VDD` limit adds the RMS and peak currents:

```json
{ "net": "VDD", "budget_current_ua": 2000, "rms_current_ua": 14000, "peak_current_ua": 30000 }
```

**Example violation.** The layout is `rail.gds` from ERC-E1.

```text
rules:
  EM.met1.rms: ran, examined 2 shapes, found 2 violations
  EM.met1.peak: ran, examined 2 shapes, found 0 violations
violations: 2
  EM.met1.rms error layer met1 at (40000 nm, 500 nm) measured 7000 uA against limit 6100.000000000001 uA on shape 0 and shape 0
  EM.met1.rms error layer met1 at (50000 nm, 500 nm) measured 7000 uA against limit 6100.000000000001 uA on shape 0 and shape 0
...
```

Each load takes half of the 14 mA RMS current, so both segments carry 7000 µA RMS against
6.1 mA/µm × 1 µm = 6100 µA. The 15 000 µA peak is under 20 000 µA.

**Options.**

| Parameter | Value | Meaning |
|---|---|---|
| `frequency` | list of frequencies | The table's rows, rising, such as `[100MHz, 300MHz]`. |
| `width` | list of lengths | The table's columns, rising wire widths. |
| `density` | list of lists of current per width | One row per frequency, one value per width. |
| `max_current_per_cut` | current | The RMS or peak current allowed through one cut. |

With one frequency, `frequency_mhz` is not needed. With several, a net that states no `frequency_mhz`
makes the row `refused`. A table of `frequency: [100MHz, 300MHz], width: [0.5um, 1.5um]` and
`density: [[4mA/um, 5mA/um], [6mA/um, 7mA/um]]` gives a 1 µm wire on a 200 MHz net 5.5 mA/µm.

**Status and limits.** Implemented. Every load on a net draws one waveform in phase with the others, so
out-of-phase loads read strict. Signal nets carry no current unless simulated currents load them. A LEF
per-cut table by cut area is one value per cut layer. No public deck states a table; the values are
yours to supply. A row is `skipped` when no net states its current.

**Sources.** [LEF/DEF 5.8 Language Reference](https://coriolis.lip6.fr/doc/lefdef/lefdefref/lefdefref.pdf)
`ACCURRENTDENSITY PEAK`, `AVERAGE` and `RMS`; SkyWater SKY130 technology LEF `ACCURRENTDENSITY RMS`.

## Power-grid integrity

### ERC-E8: Static IR drop against a budget

**What it catches.** A point on a supply net whose voltage sags further below the supply, or a ground
that rises further above 0 V, than your design intent allows. Lost supply voltage slows logic, shifts
analog bias points and eats noise margin.

**How GPurify measures it.** GPurify solves the supply grid with each net's `budget_current_ua` shared
among its device terminals and the feed point held at the supply voltage. A node's drop is how far it
sits below the supply on a power net, or above 0 V on a ground net. A node is flagged when its drop
is over `max_drop_mv`, over `max_drop_fraction` times its domain's voltage, or when it rises over the
supply by more than `max_overvoltage_mv`. `examined` counts the nodes whose net states one of those
limits.

![A met2 strap feeding two met1 rails through via1 cuts; node drops from 0.59 mV to 19.06 mV, four over the 10 mV limit](../../diagrams/erc-e8.svg)

**In the deck.**

```text
rule <id> ir_drop()
```

Added to `em.deck`:

```text
rule ir ir_drop()
```

The limits are the intent's, here `pdn.json`, the same as `rail.json` but with a 3000 µA budget:

```json
{ "net": "VDD", "budget_current_ua": 3000, "max_drop_mv": 10 }
```

**Example violation.** The layout `pdn.gds` is a met2 strap 2 µm × 20 µm, the feed, joined by one via1
cut each to two met1 rails 50 µm × 1 µm. The bottom rail has loads at 25 µm and 48 µm, the top rail
one at 48 µm, each drawing 1000 µA.

```text
rules:
  ir: ran, examined 9 shapes, found 4 violations
violations: 4
  ir error layer met1 at (1000 nm, 500 nm) measured 10.187499999999545 mV against limit 10 mV on shape 0
  ir error layer met1 at (25000 nm, 500 nm) measured 16.18749999999909 mV against limit 10 mV on shape 0
  ir error layer met1 at (48000 nm, 500 nm) measured 19.06249999999909 mV against limit 10 mV on shape 0
  ir error layer met1 at (48000 nm, 19500 nm) measured 10.96874999999909 mV against limit 10 mV on shape 1
...
```

The far load on the bottom rail at (48 µm, 0.5 µm) sits 19.06 mV below the feed, against 10 mV:
0.59 Ω × 2 mA in the strap, 4.5 Ω × 2 mA in the cut, then 3 Ω × 2 mA and 2.875 Ω × 1 mA along met1.

**Options.** None in the rule. The limits are the intent's `max_drop_mv`, `max_drop_fraction`
and `max_overvoltage_mv` per net (see [Design intent](../design-intent.md)).

**Status and limits.** Implemented. Each supply is fed at one point, the centre of its highest, then
widest, shape, so a rail fed from several pads reads more drop than it has. A limit left out on a net
is not checked for that net. A `budget_current_ua` on a net no device terminal reaches refuses every
current and drop rule, since zero current would pass every limit.

**Sources.** OpenROAD `psm`; N. Weste and D. Harris, *CMOS VLSI Design*, 4th edition, §13.3.2; Ansys
RedHawk-SC, Cadence Voltus and Siemens mPower static IR analysis.

### ERC-E9: Power-grid integrity

**What it catches.** A piece of a supply net cut off from its feed, and wiring that reaches no device.
A floating stripe leaves the cells on it unpowered, and an orphan stub is often a missing via.

**How GPurify measures it.** `floating_supply` gathers the pieces that carry one supply's label and
flags every piece other than the one holding the feed shape, the highest, then widest, shape over all
pieces. `unconnected_pin` flags every shape on its layers whose net reaches no device terminal. Both
report 0 connections against 1.

![A fed met1 VDD rail, a second VDD rail never joined to it flagged as floating, and an unlabelled met1 stub flagged as reaching no device](../../diagrams/erc-e9.svg)

**In the deck.**

```text
rule <id> floating_supply()
rule <id> unconnected_pin(<layer>, ...)
```

Added to `em.deck`:

```text
rule pdn.floating floating_supply()
rule pdn.unconnected unconnected_pin(met1, met2)
```

The intent is `rail.json` (`floating_supply` needs the declared supplies; `unconnected_pin` does not).

**Example violation.** The layout `floating.gds` has a met2 pad labelled `VDD` joined by one cut to a
met1 rail with a load, a second met1 rail labelled `VDD` with a load that nothing joins to the first,
and an unlabelled met1 stub at y = 20 µm.

```text
rules:
  pdn.floating: ran, examined 2 shapes, found 1 violations
  pdn.unconnected: ran, examined 4 shapes, found 1 violations
violations: 2
  pdn.floating error layer met1 at (0 nm, 10000 nm) measured 0 against limit 1 on shape 1
  pdn.unconnected error layer met1 at (0 nm, 20000 nm) measured 0 against limit 1 on shape 2
...
```

The rail at y = 10 µm carries `VDD` but the feed on the met2 pad never reaches it. The stub at
y = 20 µm reaches no device.

**Options.** None.

**Status and limits.** Implemented. A labelled piece reached only through a device is still floating.
An unlabelled cell rail that devices reach but no supply does is `supply_path`'s to find, a
[connectivity check](classic.md).

**Sources.** [OpenROAD `check_power_grid`](https://openroad.readthedocs.io/en/latest/main/src/psm/README.html).

### ERC-E10: Per-segment power-grid EM

**What it catches.** One overloaded segment or cut anywhere in a power grid, rather than one number per
net. A grid fails at its weakest segment, typically the first cut and wire out of the feed.

**How GPurify measures it.** `em_current_density` on every layer of the grid, metal and cuts, in one
row. Each segment and each cut is checked and reported on its own, at its first node.

![The ERC-E8 grid with each segment's and cut's current; the bottom via1 cut and first met1 segment carry 2000 µA over 1500 µA](../../diagrams/erc-e10.svg)

**In the deck.**

```text
rule <id> em_current_density(<layer>, ...; max_density: <current per width>, max_current_per_cut: <current>, narrow: none)
```

Added to `em.deck`:

```text
rule pdn.em em_current_density(met1, via1, met2; max_density: 1.5mA/um, max_current_per_cut: 1.5mA, narrow: none)
```

The intent is `pdn.json` from ERC-E8.

**Example violation.** The layout is `pdn.gds` from ERC-E8.

```text
rules:
  pdn.em: ran, examined 8 shapes, found 2 violations
violations: 2
  pdn.em error layer met1 at (1000 nm, 500 nm) measured 1999.9999999998483 uA against limit 1500.0000000000002 uA on shape 0 and shape 0
  pdn.em error layer via1 at (1000 nm, 500 nm) measured 1999.999999999899 uA against limit 1500 uA on shape 0 and shape 2
...
```

The bottom cut and the met1 segment after it carry the 2000 µA of both bottom loads, against 1500 µA.
The six other segments and cuts carry 1000 µA or are 2 µm wide, and pass.

**Options.** As for [ERC-E1](#erc-e1-dc-current-per-width).

**Status and limits.** Implemented. As for ERC-E1: one feed point per supply and the budget shared
equally among the terminals.

**Sources.** OpenROAD `psm` `analyze_power_grid -enable_em`.

### ERC-E11: Dynamic vectorless IR drop

**What it catches.** A node that sags too far during the worst clock cycle, when every load switches at
once. Switching current is far higher than the average, and only the decoupling capacitance and the
grid's resistance hold the supply up.

**How GPurify measures it.** In the net's worst cycle every load switches together. Each draws a
triangular pulse `rise_time_ps` wide that carries the charge its share of the budget delivers over the
cycles it switches in:

\\[ Q = \frac{I \, T}{\alpha}, \qquad I_\text{peak} = \frac{2 Q}{t_r} \\]

where \\( I \\) is the load's share of `budget_current_ua`, \\( T \\) is `clock_period_ps`,
\\( \alpha \\) is `toggle_rate` and \\( t_r \\) is `rise_time_ps`. Each load node holds its share of
`decap_pf`, in proportion to its current. GPurify simulates the resistor and capacitor grid through
the cycle, adds the static drop, and flags a node whose total is over the `dynamic` `max_drop_mv`.

![The rail with a 100 pF decap and a 200 mA, 100 ps pulse at each load; the far load drops 95.9 mV against 90 mV](../../diagrams/erc-e11.svg)

**In the deck.**

```text
rule <id> dynamic_ir_drop()
```

Added to `em.deck`:

```text
rule ir.dyn dynamic_ir_drop()
```

The intent's `VDD` limit carries a `dynamic` entry:

```json
{ "net": "VDD", "budget_current_ua": 2000, "max_drop_mv": 10,
  "dynamic": { "max_drop_mv": 90, "toggle_rate": 0.2, "clock_period_ps": 2000,
               "rise_time_ps": 100, "decap_pf": 200 } }
```

**Example violation.** The layout is `rail.gds` from ERC-E1.

```text
rules:
  ir.dyn: ran, examined 3 shapes, found 1 violations
violations: 1
  ir.dyn error layer met1 at (90000 nm, 500 nm) measured 95.90888921961366 mV against limit 90 mV on shape 0
...
```

Each load moves 1000 µA × 2000 ps / 0.2 = 10 pC in a 100 ps pulse peaking at 200 mA. Its 100 pF of
decap supplies most of it, and the far load at 90 µm reaches 95.9 mV, its 5 mV static drop included,
against 90 mV.

**Options.** None in the rule. The `dynamic` entry's fields are in [Design intent](../design-intent.md).

**Status and limits.** Partial. The analysis is vectorless: every load switches in phase once, with no
timing windows, which errs high. The grid is resistors and decap only, with no package, bump or wire
inductance, and one feed point per supply. Only the worst cycle is followed from the static drop. The
time step reads a pulse's peak up to 0.61% low on an RC node. An intent file with a `toggle_rate`
above 1, or a rise longer than the clock period, is refused. Simulated currents do not feed this
rule; it reads the budget.

**Sources.** S. Kouroussis and F. N. Najm, DAC 2003,
[doi:10.1145/775832.775861](https://dl.acm.org/doi/10.1145/775832.775861); Ansys RedHawk-SC and Totem,
Cadence Voltus, Siemens mPower dynamic analysis; Weste and Harris, *CMOS VLSI Design*.

## Stress voiding

### ERC-E12: Stress voiding and slotting

**What it catches.** A wide metal plate drawn solid where the foundry asks for slots. Wide copper or
aluminium plates trap stress and void under thermal cycling, and slots relieve it.

**How GPurify measures it.** `cheesing` is a design rule, run by `gpurify drc`. It merges each layer
into shapes and flags a shape whose area is over the limit and that has no hole. The slots' own width,
spacing and enclosure are ordinary width, spacing and enclosure rules.

![Two 40 µm met1 plates: the solid one is flagged at 1600 µm² with no slot, the slotted one passes](../../diagrams/erc-e12.svg)

**In the deck.**

```text
rule <id> cheesing(<layer>) <= <area>
```

Added to `em.deck`:

```text
rule met1.slot cheesing(met1) <= 1000um2
```

```sh
gpurify drc plate.gds --deck em.deck
```

**Example violation.** The layout `plate.gds` holds two 40 µm × 40 µm met1 plates, the right one with a
4 µm × 30 µm slot.

```text
rules:
  met1.slot: ran, examined 2 shapes, found 1 violations
violations: 1
  met1.slot error layer met1 at (20000 nm, 20000 nm) measured 1600000000 nm^2 against limit 1000000000 nm^2 on shape 0
...
```

The solid plate is 1600 µm² with no slot, over 1000 µm². The slotted plate is 1480 µm² and passes.

To require a slot by width rather than area, select the wide shapes first:

```text
layer met1_wide = met1.with_rect(30um x 30um)
rule met1.slot cheesing(met1_wide) <= 1nm2
```

**Options.** None.

**Status and limits.** Partial. The rule asks for a hole, not for a slot of the foundry's size, and
measures area, not width. JEDEC JEP139 and JESD214 are stress-migration test methods and state no
layout rule. SkyWater SKY130's slot rules m1.12 to m4.12 apply only to a copper back end the open PDK
does not offer. No public rule limits vias landing on wide metal, so that check does not exist.

**Sources.** GF180MCU Design Rule Manual §14.6 and MSLOT.1 to MSLOT.10; IHP SG13G2 Layout Rules Slt.a
to Slt.i; JEDEC JEP139; JEDEC JESD214.

## Self-heating and statistics

### ERC-E13: Thermal-aware and statistical EM

**What it catches.** A wire whose own Joule heating raises its temperature enough to lower its current
limit below what it carries, and a chip whose wires together are too likely to fail. Wires above a
thin dielectric run hotter than the chip, and a chip of millions of wires fails at its weakest one.

**How GPurify measures it.** Each metal segment runs at the chip temperature plus its own rise:

\\[ \Delta T = \frac{I^2 R_s \, t}{K \, W \, (W + \varphi t)} \\]

where \\( I \\) is the segment's current, \\( R_s \\) the layer's sheet resistance, \\( t \\) the
layer's `pex` height above the substrate, \\( K \\) is `thermal_conductivity`, \\( W \\) the width and
\\( \varphi \\) is `spreading`. A cut takes the hotter of the metals at its ends. Each limit is then
derated by Black's equation to that temperature, as in [ERC-E4](#erc-e4-temperature-derating). Each
wire fails lognormally, and a wire exactly at its limit fails with probability `limit_failure`. A
finding at the wire likeliest to fail measures the chip's chance of any failure against
`max_failure`.

![Cross-section of a 1 µm met1 wire 1.376 µm above the substrate: 10 mA heats it 5.56 K, cutting its limit to 9397 µA](../../diagrams/erc-e13.svg)

**In the deck.**

```text
rule <id> em_thermal(<layer>, ...; max_density: <current per width>, max_current_per_cut: <current>, blech_limit: <current>, reference_temperature: <temperature>, activation_energy: <energy>, current_exponent: <number>, thermal_conductivity: <W/mK>, spreading: <number>, sigma: <number>, limit_failure: <fraction>, max_failure: <fraction>)
```

Added to `em.deck`, beside the same limit without self-heating:

```text
rule EM.hot em_thermal(met1; max_density: 20mA/um, max_current_per_cut: 1mA, blech_limit: 1nA, reference_temperature: 85C, activation_energy: 0.7eV, current_exponent: 2, thermal_conductivity: 1.4W/mK, spreading: 0.88, sigma: 0.5, limit_failure: 0.001, max_failure: 0.01)
rule EM.cold electromigration(met1; max_density: 20mA/um, max_current_per_cut: 1mA, blech_limit: 1nA, reference_temperature: 85C, activation_energy: 0.7eV, current_exponent: 2)
```

The intent is `rail.json` with `"temperature_c": 105` and `"budget_current_ua": 20000`.

**Example violation.** The layout is `rail.gds` from ERC-E1, each segment carrying 10 mA.

```text
rules:
  EM.hot: ran, examined 2 shapes, found 2 violations
  EM.cold: ran, examined 2 shapes, found 0 violations
violations: 2
  EM.hot error layer met1 at (40000 nm, 500 nm) measured 10000 uA against limit 9397.0687338169 uA on shape 0 and shape 0
  EM.hot error layer met1 at (50000 nm, 500 nm) measured 10000 uA against limit 9397.0687338169 uA on shape 0 and shape 0
...
```

At 105 °C the limit is 10 978 µA and `EM.cold` passes. Self-heating adds 5.56 K, and at 110.6 °C the
limit falls to 9397 µA, under the 10 000 µA carried. The two segments each fail with probability
0.22%, so the chip's 0.45% is within `max_failure: 0.01`. With `max_failure: 0.004` a third finding
reports `measured 0.004485381519370887 against limit 0.004`.

**Options.**

| Parameter | Value | Meaning |
|---|---|---|
| `max_density`, `max_current_per_cut`, `blech_limit`, `reference_temperature`, `activation_energy`, `current_exponent` | as for `electromigration` | See [ERC-E4](#erc-e4-temperature-derating). |
| `thermal_conductivity` | W/mK | \\( K \\), the dielectric's thermal conductivity, such as `1.4W/mK` for silicon dioxide. |
| `spreading` | number | \\( \varphi \\), how far heat spreads sideways per unit of height. |
| `sigma` | number | The lognormal spread of a wire's failure time. |
| `limit_failure` | fraction | The failure probability of a wire exactly at its limit: the percentile the limit is rated at. |
| `max_failure` | fraction | The chip's allowed probability of any EM failure. |

**Status and limits.** Implemented. A wire heats only itself: heat from neighbouring wires, heat
carried along a line to cooler vias and resistance rising with temperature are not modelled, so a
dense bundle of wires reads cooler than it is. The current is the static one, from the budget or the
simulated EM average.

**Sources.** K. Banerjee, A. Mehrotra, A. Sangiovanni-Vincentelli and C. Hu, DAC 1999,
[doi:10.1145/309847.310093](https://doi.org/10.1145/309847.310093); J. Kitchin, Symposium on VLSI
Circuits 1995; Black 1969; JEDEC JEP122; JEDEC JESD63; Ansys RedHawk-SC and Totem, Cadence Voltus.

## Simulated currents

### ERC-E14: Simulation-driven EM and IR drop

**What it catches.** The same current, drop and lifetime violations as the checks above, with each
device's own simulated current in place of an even share of the budget. In an analog block one branch
of a mirror carries ten times another, and an even share hides the hot wire.

**How GPurify measures it.** `--currents` reads a simulator's per-terminal current file
(`espice-emir/1`, written by ESPice's `--emir`). LVS runs first. Each schematic terminal's current goes
onto the layout device LVS pairs with its instance, at that device's tap on the paired net. GPurify then
solves each net with those loads: `ir_drop` reads the average currents; `em_current_density`,
`electromigration` and `em_thermal` the electromigration average; `em_rms` and `em_peak` the RMS and
peak, summed in phase. Each finding names the terminal that loads it most.

![The met1 rail with simulated loads of 0.5, 0.5 and 2 mA; one segment carries 2500 µA over 2200 µA and the far node drops 11.25 mV](../../diagrams/erc-e14.svg)

**In the deck.** Nothing extra to write in the deck but an LVS tolerance, which the pairing needs. Run
with `--reference` and `--currents`. Added to `em.deck`:

```text
lvs tolerance default relative 2%
rule EM.met1 em_current_density(met1; max_density: 2.2mA/um, max_current_per_cut: 0.36mA, narrow: none)
rule ir ir_drop()
```

The reference netlist `top.spice`:

```text
.subckt top VDD n40 n70 n90
R40 VDD n40 load
R70 VDD n70 load
R90 VDD n90 load
.ends
```

The current file `top.emir.json`, from a testbench that placed `top` as `xdut` (amperes, positive into
the terminal):

```json
{"format": "espice-emir/1", "deck": "tb.sp", "variant": {"kind": "nominal"}, "analysis": "tran", "temp": 85,
 "window": [1e-06, 3e-06], "em_recovery": 1, "terminals": [
  {"instance": "xdut.r40", "model": "load", "terminal": "p", "net": "vdd", "avg": 0.5e-3, "em_avg": 0.5e-3, "rms": 0.8e-3, "peak": 2e-3},
  {"instance": "xdut.r40", "model": "load", "terminal": "n", "net": "xdut.n40", "avg": -0.5e-3, "em_avg": 0.5e-3, "rms": 0.8e-3, "peak": 2e-3},
  {"instance": "xdut.r70", "model": "load", "terminal": "p", "net": "vdd", "avg": 0.5e-3, "em_avg": 0.5e-3, "rms": 0.8e-3, "peak": 2e-3},
  {"instance": "xdut.r70", "model": "load", "terminal": "n", "net": "xdut.n70", "avg": -0.5e-3, "em_avg": 0.5e-3, "rms": 0.8e-3, "peak": 2e-3},
  {"instance": "xdut.r90", "model": "load", "terminal": "p", "net": "vdd", "avg": 2e-3, "em_avg": 2e-3, "rms": 2.5e-3, "peak": 6e-3},
  {"instance": "xdut.r90", "model": "load", "terminal": "n", "net": "xdut.n90", "avg": -2e-3, "em_avg": 2e-3, "rms": 2.5e-3, "peak": 6e-3}
 ], "sources": []}
```

The intent is `rail.json` with `"budget_current_ua": 3000`.

```sh
gpurify erc sim.gds --deck em.deck --intent rail.json --reference top.spice --currents top.emir.json
```

**Example violation.** The layout `sim.gds` is the `rail.gds` rail with loads at 40 µm, 70 µm and
90 µm, their far ends labelled `n40`, `n70` and `n90` on poly.

```text
rules:
  EM.met1: ran, examined 3 shapes, found 1 violations
  ir: ran, examined 4 shapes, found 1 violations
  erc.budget_unused: ran, examined 4 shapes, found 1 violations
violations: 3
  EM.met1 error layer met1 at (50000 nm, 500 nm) measured 2500 uA against limit 2200.0000000000005 uA on shape 0 and shape 0 loaded most by xdut.r90 p
  ir error layer met1 at (90000 nm, 500 nm) measured 11.25 mV against limit 10 mV on shape 0 loaded most by xdut.r90 p
  erc.budget_unused warning layer met1 at (0 nm, 0 nm) measured 3000 uA against limit 3000 uA on shape 0
...
```

The segment from the feed at 50 µm to 70 µm carries 2500 µA against 2200 µA, and the node at 90 µm
drops 11.25 mV against 10 mV, both mostly from `xdut.r90`. The same 3 mA as a budget, 1 mA a load,
gives 2000 µA and 7.5 mV and passes. The `erc.budget_unused` warning says the net's 3000 µA budget was
replaced by its simulated 3000 µA.

**Options.** None in the rule. A net the file does not reach keeps its budget.

**Status and limits.** Partial ([issue 23](https://github.com/OmarSiwy/GPurify/issues/23)). A
terminal's current is drawn at its device's tap, not spread over its terminal shapes, and each net is
fed at one point. A parallel or series group LVS reduced to one device shares the current evenly. A
device the deck's `lvs ignore` leaves out, and a net LVS reduction removes, carry no current.
`dynamic_ir_drop` and `reliability` still read the budget. The run is refused, naming the cause, for:

- `--currents` without `--reference`, or a deck with no `lvs tolerance default`;
- a comparison that could not be made, did not conclude, or found any mismatch;
- a terminal whose instance or net LVS left unmatched, or an instance paired with a black box;
- a current file whose instances are not the reference's devices, or whose terminal count is not the
  card's;
- a net with no label whose average currents do not sum to zero within 0.1%.

**Sources.** Cadence Voltus and Siemens Calibre PERC simulation-driven EM and IR; ESPice `--emir`
(`espice-emir/1`).
