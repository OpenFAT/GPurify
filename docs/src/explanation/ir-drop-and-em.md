# How GPurify computes IR drop and electromigration

The [electromigration and IR-drop checks](../reference/erc/electromigration.md) all read one model: the
supply wiring as a network of resistors, loaded with currents and solved once. This page explains how
GPurify builds that network, where its currents come from, and how a solved current or voltage becomes
a verdict, so you can predict a result and know when to question one.

## From layout to a resistor network

GPurify builds a network for every declared supply in the [design intent](../reference/design-intent.md),
and, with simulated currents, for every net those currents load. It takes each net's shapes on the
deck's conducting layers and turns each shape into a chain of resistors along its longer side.

A chain has a node wherever something connects to the shape: a device on it, a cut, a touching shape on
the same layer, and the shape's own centre. Between two neighbouring nodes lies one segment, with the
resistance

\\[ R = R_s \frac{L}{W} \\]

where \\( R_s \\) is the layer's `sheet` from its `pex` row, \\( L \\) is the distance between the
nodes and \\( W \\) is the shape's width there. GPurify counts the squares exactly, slice by slice, so
an L-shaped or tapered shape gets its true resistance. The width a current check reads is the narrowest
cross-section the segment passes through, where the current density peaks. Every cut is a resistor of
its own, the cut layer's `sheet` in ohms per cut, so four cuts side by side carry a quarter of the
current each.

![A 100 µm met1 rail with loads at 40 µm and 90 µm becomes a 1.25 Ω and a 5 Ω resistor between three nodes, fed at the centre](../diagrams/ir-drop-and-em-1.svg)

A layer that carries current must state a positive sheet resistance; one that does not makes every
grid rule report `refused`, because a zero would short the rail. A `connect global` layer, such as the
substrate, carries no modelled current.

## The feed point

Each net is held at its supply voltage at one point: the centre of its shape on the highest layer,
by the `pex` heights, and among those the shape with the largest bounding box. A ground is held at
0 V. Supply current enters from the top metal in most designs, so this is usually the pad or the top
strap.

One feed point is a simplification. A rail fed from several pads, or from a mesh of straps, reads more
drop, and more current near the feed, than it really has. The error is on the safe side, but it can be
large. To check one region at a time, label the supply on the strap that feeds it.

## Where the current comes from

### A budget from the design intent

Without simulated currents, a net's `budget_current_ua` is shared equally among the device terminals
on it. A transistor with both source and drain on the rail counts twice. Each share is drawn at the
device's tap: the point of the net's shape under the device's marker. On a ground net each share is
injected rather than drawn, so the ground rises.

`em_rms` and `em_peak` solve the same network again, with the net's `rms_current_ua` or
`peak_current_ua` in place of the budget. Every load is taken to draw one waveform in phase with the
others, so the currents add, which is an upper bound.

An even share is a model of a digital supply grid, where thousands of cells draw alike. It hides the
one device that draws more than its share.

### Simulated currents

With `--currents`, each schematic terminal's current from a simulation is drawn at the tap of the layout
device LVS pairs with its instance, on the net LVS pairs with its net. The file gives four values per
terminal, and each rule reads one:

- the **average** current loads the network `ir_drop` reads;
- the **electromigration average** loads the network `em_current_density`, `electromigration` and
  `em_thermal` read. Electromigration under alternating current partly heals, so the simulator reports
  an average that counts reverse current at a discount;
- the **RMS** current loads the network `em_rms` reads, summed in phase over the net's loads;
- the **peak** current loads the network `em_peak` reads, summed the same way.

`dynamic_ir_drop` and `reliability` keep reading the budget. A net the file does not reach keeps its
budget too.

![Simulated loads of 0.5, 0.5 and 2 mA on the rail: one segment carries 2500 µA where an even 1 mA share would give 2000 µA](../diagrams/erc-e14.svg)

The same 3 mA total, shared evenly, passes a 2200 µA limit and a 10 mV drop. Placed where the simulation
puts it, it fails both.

## Solving for drops and currents

GPurify solves the network by Kirchhoff's current law: at every node, the currents in the resistors
meeting there and the load drawn there sum to zero, with the feed held at its voltage. The solution
gives every node's voltage and every segment's current.

A node's drop is how far it sits below its supply on a power net, or above 0 V on a ground net. For a
chain without branches, it is the sum of each segment's resistance times the current through it. In
the [ERC-E8 example](../reference/erc/electromigration.md#erc-e8-static-ir-drop-against-a-budget), the far
load on the bottom rail is reached through the met2 strap, one cut and two met1 segments:

\\[ \Delta V = 0.594 \times 2 + 4.5 \times 2 + 3 \times 2 + 2.875 \times 1 = 19.06\ \text{mV} \\]

with resistances in ohms and currents in milliamperes. The run reports 19.06 mV.

![The ERC-E8 grid from the feed through met2 and via1 to two met1 rails, each node with its drop in mV](../diagrams/erc-e8.svg)

`ir_drop` holds each node to its net's `max_drop_mv`, to `max_drop_fraction` times its domain's
voltage, and to `max_overvoltage_mv` above the supply. A net that is no supply, loaded by simulated
currents, has no domain: its drop to its feed point, either way, is held to `max_drop_mv` alone.

## Current-density verdicts

A metal segment may carry `max_density` times its width. A segment no wider than a `narrow` band may
carry the band's current instead. A cut may carry `max_current_per_cut`. The current compared is the
magnitude of the segment's current, whichever way it flows.

## Temperature and Black's equation

Black's equation gives the median time to failure of a wire:

\\[ t_{50} = A \, J^{-n} \exp\left( \frac{E_a}{k T} \right) \\]

where \\( A \\) is a constant of the process, \\( J \\) is the current density, \\( n \\) is the current
exponent, \\( E_a \\) is the activation energy, \\( k \\) is Boltzmann's constant,
8.617 × 10⁻⁵ eV/K, and \\( T \\) is the temperature in kelvin. A foundry rates a limit
\\( I_\text{ref} \\) at one temperature \\( T_\text{ref} \\). Asking for the same lifetime at \\( T \\)
gives the current allowed there:

\\[ I_\text{allowed} = I_\text{ref} \exp\left( \frac{E_a}{n k} \left( \frac{1}{T} - \frac{1}{T_\text{ref}} \right) \right) \\]

This is the form of GF180MCU's §14.2.2. Below \\( T_\text{ref} \\) the factor is above 1, and above it
the factor is below 1.

For example, GF180MCU rates Metal1 at 2.09 mA/µm at 85 °C (358.15 K), with \\( E_a = 0.7 \\) eV and
\\( n = 2 \\). At 125 °C (398.15 K):

\\[ \frac{0.7}{2 \times 8.617 \times 10^{-5}} \left( \frac{1}{398.15} - \frac{1}{358.15} \right) = -1.139, \qquad e^{-1.139} = 0.320 \\]

so a 1 µm wire may carry 2090 µA × 0.320 = 669 µA. The run reports `668.8803850984727 uA`, and the
manual's table gives 0.67 mA/µm.

![Allowed current of a 1 µm met1 wire against temperature, from 2090 µA at 85 °C to 669 µA at 125 °C](../diagrams/erc-e4.svg)

The temperature is the intent's `temperature_c`, else the deck's `temperature`. With neither, the rules
that derate are refused, because no temperature is right for everyone. The whole run uses one
temperature, except under `em_thermal`.

## Blech length

A current pushes metal atoms toward one end of a line. Where they pile up against a barrier, such as a
via's liner, the stress pushes them back. In a short enough line the back-stress balances the
current, and the line never fails. Blech found the threshold is a product: a line is immortal when
\\( j L \le (jL)_c \\), with \\( j \\) its current density and \\( L \\) its length.

GPurify measures a line from barrier to barrier: the feed point, every loaded tap and every cut landing
end a line. With \\( j = I / (W t) \\), it compares

\\[ P = \frac{|I| \, L}{W} \\]

with `blech_limit`, which is therefore \\( (jL)_c \\) times the layer's thickness \\( t \\). With a
\\( (jL)_c \\) of 0.3 A/µm and a 0.36 µm thick layer, `blech_limit` is 108 mA. Every segment of the line
carries its own current, and the line's \\( P \\) is the largest of them. A branched line's \\( L \\)
counts every branch, which errs toward mortal.

![A met1 rail cut by barriers into a 10 µm immortal line at 10 mA and a 40 µm mortal line at 40 mA, against a 20 mA limit](../diagrams/erc-e6.svg)

## Self-heating

A wire dissipates \\( I^2 R \\) and sheds the heat down through the dielectric to the substrate.
`em_thermal` gives each segment the rise of Banerjee and others:

\\[ \Delta T = I^2 R \, \theta, \qquad \theta = \frac{t}{K L (W + \varphi t)} \\]

where \\( R \\) is the segment's resistance, \\( t \\) its layer's height above the substrate,
\\( K \\) the dielectric's thermal conductivity, \\( L \\) and \\( W \\) its length and width, and
\\( \varphi \\) how far the heat spreads sideways. With \\( R = R_s L / W \\) the length cancels. In the
[ERC-E13 example](../reference/erc/electromigration.md#erc-e13-thermal-aware-and-statistical-em), 10 mA
in a 1 µm met1 wire at 0.125 Ω/sq, 1.376 µm up, with \\( K = 1.4 \\) W/(m·K) and \\( \varphi = 0.88 \\):

\\[ \Delta T = \frac{(0.01)^2 \times 0.125 \times 1.376 \times 10^{-6}}{1.4 \times 10^{-6} \times 2.211 \times 10^{-6}} = 5.56\ \text{K} \\]

Each segment's limit is then derated by Black's equation at its own temperature. A cut takes the hotter
of the two metals it joins.

![Cross-section of a met1 wire above the substrate, heat spreading over W + φt; 10 mA heats it 5.56 K](../diagrams/erc-e13.svg)

### The chip's failure probability

A wire's time to failure is lognormal about Black's median. A wire carrying exactly its limit fails
within the rated life with probability `limit_failure`. A wire carrying \\( u \\) times its limit fails
with probability

\\[ F = \Phi\left( z + \frac{n}{\sigma} \ln u \right) \\]

where \\( \Phi \\) is the standard normal distribution, \\( z = \Phi^{-1}(\texttt{limit\_failure}) \\)
and \\( \sigma \\) is `sigma`. The chip fails when any wire does, so its probability is
\\( 1 - \prod_i (1 - F_i) \\), checked against `max_failure`. In the ERC-E13 example each segment runs
at \\( u = 10000 / 9397 = 1.064 \\), so \\( F = \Phi(-3.090 + 4 \times 0.0622) = 0.22\% \\), and the
two together give 0.45%.

## The worst switching cycle

`dynamic_ir_drop` asks what happens in the net's worst clock cycle, when every load switches at once.
A load whose share of the budget is \\( I \\) and which switches in a fraction \\( \alpha \\) of cycles
of period \\( T \\) moves a charge \\( Q = I T / \alpha \\) each time. GPurify draws it as a triangle
\\( t_r \\) wide, peaking at \\( 2Q / t_r \\), while the net's decap, shared in proportion to the
loads, holds the node up. It follows the resistor and capacitor network through that cycle and adds the
static drop. No timing windows spread the loads apart, so the result errs high.

## What is not modelled

- More than one feed point per net.
- Package, bump and wire inductance: no \\( L \, di/dt \\) in the dynamic drop.
- Heat from neighbouring wires, heat carried along a line to cooler vias, and resistance rising with
  temperature.
- Current crowding at a cut's edge, and the spread of a terminal's current over its own shapes: it is
  drawn at the device's tap.
- Loads out of phase: RMS and peak currents add as if in phase.
- Signal nets, unless simulated currents load them.
- Rescaling a limit to a lifetime other than the one the foundry rated it for.

## Sources

- J. R. Black, "Electromigration: a brief survey and some recent results", IEEE Trans. Electron
  Devices 16(4), 1969, [doi:10.1109/T-ED.1969.16754](https://doi.org/10.1109/T-ED.1969.16754).
- I. A. Blech, "Electromigration in thin aluminum films on titanium nitride", J. Appl. Phys. 47(4),
  1976, [doi:10.1063/1.322842](https://doi.org/10.1063/1.322842).
- K. Banerjee, A. Mehrotra, A. Sangiovanni-Vincentelli and C. Hu, "On thermal effects in deep
  sub-micron VLSI interconnects", DAC 1999,
  [doi:10.1145/309847.310093](https://doi.org/10.1145/309847.310093).
- S. Kouroussis and F. N. Najm, "A static pattern-independent technique for power grid voltage
  integrity verification", DAC 2003, [doi:10.1145/775832.775861](https://dl.acm.org/doi/10.1145/775832.775861).
- [GF180MCU Design Rule Manual](https://gf180mcu-pdk.readthedocs.io/en/latest/physical_verification/design_man.html) §14.2.
- JEDEC JEP122, failure mechanisms and models for semiconductor devices.
