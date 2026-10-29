# Device matching

A `matching` statement gives a device model's mismatch coefficients: how far two identical devices
of that model differ at random, by their size. The coefficients are those of Pelgrom's law, as a
foundry's matching measurements state them.

```text
matching "<model>" pair|single <key> <value> [<key> <value> ...]
```

```text
matching "nfet"  pair   avt 5mV·um abeta 1%·um svt 0.3uV/um
matching "pfet"  single avt 3.9mV.um abeta 0.5%.um
matching "rpoly" pair   ar 1.5%·um
matching "npn"   pair   ka 0.4%·um
```

## Keys

Two identical transistors of gate area \\( W L \\), a distance \\( D \\) apart, differ in threshold
voltage by

\\[ \sigma^2(\Delta V_T) = \frac{A_{VT}^2}{W L} + S_{VT}^2 D^2 \\]

where \\( A_{VT} \\) is the `avt` key and \\( S_{VT} \\) the `svt` key (M. J. M. Pelgrom,
A. C. J. Duinmaijer and A. P. G. Welbers, "Matching properties of MOS transistors", IEEE JSSC
24(5), 1989). For a pair with `avt 5mV·um` and \\( W L = 1 \\) µm², the first term gives
\\( \sigma(\Delta V_T) = 5 \\) mV.

| Key | Device | Unit | Meaning |
|---|---|---|---|
| `avt` | `mos` | `mV·um` | \\( \sigma(\Delta V_T) = A_{VT} / \sqrt{W L} \\) |
| `abeta` | `mos` | `%·um` | \\( \sigma(\Delta\beta / \beta) = A_\beta / \sqrt{W L} \\), \\( \beta \\) the current factor |
| `svt` | `mos` | `uV/um` | \\( \sigma(\Delta V_T) = S_{VT} D \\), the gradient term |
| `ar` | `resistor` | `%·um` | \\( \sigma(\Delta R / R) = A_R / \sqrt{W L} \\), of the body |
| `ka` | `bjt` | `%·um` | \\( \sigma(\Delta I_S / I_S) = K_A / \sqrt{A_E} \\), the collector currents' at one base-emitter voltage, \\( A_E \\) the emitter area |

The middle dot in a unit may be written as a full stop: `mV.um`, `%.um`.

## Pair or single

The word after the model says what the area coefficients (every key but `svt`) describe:

- `pair`: the difference between two devices, as Pelgrom and a foundry's matching measurements
  state it.
- `single`: one device's own variation, as a SPICE model's mismatch parameter is drawn once per
  instance. A pair then differs by \\( \sqrt{2} \\) times as much.

The word is required. A source states one or the other, and writing which keeps the deck's number
the source's own, never one multiplied by hand.

## Rules

- A statement gives at least one key, each once, each value positive.
- The model is in quotes, and a `device` statement of each key's kind declares it: `avt`, `abeta`
  and `svt` need a `device mos` with that model, `ar` a `device resistor`, `ka` a `device bjt`.
- A model has one `matching` statement. A second is an error at its line that names the first
  one's line.
- A model with no statement, or a key its statement leaves out, has no coefficient. It is unknown,
  never 0.

```text
error: deck match.deck: Malformed
  matching "rpoly": avt needs a `device mos` statement with that model
```

## Shipped decks

The shipped decks state what a public source gives, and each line's comment names the source:

| Deck | Models and keys | Basis | Source |
|---|---|---|---|
| `ihp_sg13g2` | `rppd`, `rhigh`: `ar` | `pair` | The process specification's matching coefficients for resistor pairs |
| `ihp_sg13g2` | `sg13_lv_nmos`, `sg13_lv_pmos`, `sg13_hv_nmos`, `sg13_hv_pmos`: `avt`, `abeta` | `single` | The ngspice mismatch models' `delvto_mm` and `factuo_mm` |
| `sky130` | `sky130_fd_pr__res_high_po`, `sky130_fd_pr__res_xhigh_po`: `ar` | `single` | The resistor models' `body_pelgrom` |

A process with no public value carries no line. No shipped deck states `svt` or `ka`, and
`gf180mcu` and `asap7` state no coefficients.

## Status and limits

GPurify reads, checks and keeps the coefficients with the deck, but no command reports from them
yet: a deck with `matching` lines produces the same reports as one without. The layout matching
check, which holds a matched group to one model, size, orientation and centroid, is the ERC
`matching` rule (see the [ERC checks](../erc/README.md)) and reads no coefficient. See
[issue 25](https://github.com/OpenFAT/GPurify/issues/25).
