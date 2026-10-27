# Shipped decks

GPurify carries four decks for open process design kits. Name one with `--deck` and GPurify
builds it in, with no file to read. Each deck's source file is in the repository under `pdks/`,
with the sources of every number in its header.

| Name | Process | Grid | Design rules | Electrical rules | Device models |
|---|---|---|---:|---:|---:|
| `sky130` | SkyWater SKY130, 130 nm, five aluminium metals | 5 nm | 265 | 37 | 26 |
| `gf180mcu` | GlobalFoundries GF180MCU, 180 nm, 3.3 V, 5 V and 6 V | 5 nm | 272 | 56 | 27 |
| `ihp_sg13g2` | IHP SG13G2, 130 nm SiGe BiCMOS | 5 nm | 416 | 49 | 12 |
| `asap7` | ASAP7, predictive 7 nm FinFET | 1 nm | 238 | 4 | 8 |

The rule counts are the rule lines a `drc` run and an `erc` run report with the deck. `asap7` is
also accepted under its old name, `generic_finfet`.

A shipped name always means the shipped deck, even when a file of that name is in the working
directory. To read the file instead, give a path: `--deck ./sky130`.

Every shipped deck takes its rule ids from the foundry's manual, so a violation of `m1.1` is rule
m1.1 in that manual. Where one manual rule needs two checks, the second carries a suffix that says
what it covers, such as `<id>.notch` for the notch half of a spacing rule.

## sky130

SkyWater SKY130 (`sky130A`), the five-metal aluminium back end.

**Sources.** The SKY130 periphery rules and GDS layer map from google/skywater-pdk; the efabless
MPW precheck KLayout deck for the MiM capacitor numbers and derived layers; the SKY130 antenna rules,
table Ig; the open_pdks Magic technology file for layer heights, contact resistance and
capacitance; the SKY130 parasitic tables; the `sky130_fd_sc_hd` technology LEF for
electromigration limits and maximum density; Cadence's SKY130 rule manual of 22 July 2025 for
rules the periphery table leaves unclear.

**Covers.**

- Design rules for every drawn layer from deep n-well to `met5`, the MiM capacitors, the pad and
  nitride seal, high-voltage (`hvi`) rules, grid and angle rules, butting-edge rules.
- Antenna ratios (table Ig), electromigration limits per metal and via, and the operating voltage
  of each transistor family.
- Connectivity from the wells to `met5`, with the substrate as a net.
- 26 device models: the 1.8 V and 5 V transistors and their low- and high-threshold variants,
  the ESD transistors, poly, diffusion and local-interconnect resistors, varactors, MiM
  capacitors and the p-well diodes.
- A parasitic stack for every conductor and contact, from diffusion to `met5`.
- Resistor mismatch coefficients for the precision poly resistors.

**Does not cover.**

- The SRAM core: the deck applies the periphery numbers everywhere, `areaid.ce` included.
- The copper back end and its rules (`ct.irdrop` and `via.irdrop` among them).
- Recommended density rules (`m1.pd.1` to `m4.pd.1`, `x.18`) and the waffle-drop window rules.
- `difftap.6`, `difftap.16`, the `hv.*` and `vhvi.*` voltage-tag rules, `pwres.*`, `photo.*`,
  `tunm.*`, `denmos.*`, `depmos.*`, `extd.*`, `uhvi.*`, `vpp.*`, `mf.*`, `rdl.*`, `indm.*`, and the
  frame, die and seal-ring rules `x.12` to `x.29`.
- `nwell.7`, `nwell.8`, `hv.nwell.1` and `vhvi.8`, which space wells by net.
- The `pd2nw` diode, the bipolar transistors, the 20 V devices and the native transistors have no
  recogniser. VPP capacitors are fixed cells with no marker layer.
- Latch-up guard rings: the periphery rules give no guard-ring width or tap distance.

## gf180mcu

GlobalFoundries GF180MCU, 1P6M with a 9 kÅ top metal and MiM option B between Metal5 and
MetalTop: stack option 16 of the design manual.

**Sources.** The GF180MCU design manual from google/gf180mcu-pdk (layer map, rule tables 10 to 28,
55 and 56, device list, electromigration table); the GF180MCU KLayout DRC and LVS decks for rule
ids, derived layers and device recognition; the fossi-foundation KLayout DRC deck and its unit test
structures; the GF180MCU analog specifications for conductor thickness, dielectric constant and
sheet resistance; the open_pdks Magic technology file.

**Covers.**

- Design rules for every drawn layer from DNWELL to MetalTop and the MiM capacitor. Where the
  manual gives a 3.3 V and a 5 V limit, the rule id carries `_3.3V` or `_5V`, as the KLayout
  deck names them. The 3.3 V limit applies to every shape and the 5 V limit to shapes touching
  `Dualgate`.
- Antenna ratios, electromigration at 85 °C, latch-up rules (tables 55 and 56), butted-diffusion,
  end-of-line and guard-ring rules.
- 27 device models: the 3.3 V and 6 V transistors, the native 6 V transistor, the MOS capacitors,
  diffusion and poly resistors and the metal resistors.
- A parasitic stack from diffusion to MetalTop.

**Does not cover.**

- Another metal stack: the deck describes option 16 only.
- `SB.14a` to `SB.16`, `DV.9`, `NAT.6`, `NAT.9`, `MIMTM.11`, the 30 kÅ top metal (`MT30.*`), the
  MIM-area antenna rules, and the LDMOS, OTP, eFuse, SRAM and scribe-line sections.
- Every diode, the well resistors, the vertical bipolar transistors and the inversion-mode MOS
  capacitors, which take a terminal on a well. The MiM capacitor models, since the layout does
  not show the MIM option.
- Electromigration lifetime and absolute maximum device voltages, which the open manual does not
  state.

## ihp_sg13g2

IHP SG13G2, 130 nm SiGe BiCMOS with 1.2 V and 3.3 V CMOS, five thin and two thick aluminium
metals.

**Sources.** The SG13G2 layout rules, revision 0.4; the SG13G2 process specification, revision
1.2, for supply voltages, sheet and via resistance, current limits, layer thickness, capacitance
and resistor matching; IHP's open KLayout DRC and LVS decks; the SG13G2 typical ITF file; the
ngspice MOS mismatch models.

**Covers.**

- Design rules from the layout rules' tables, density and filler rules included.
- Current limits and supply voltages from the process specification.
- 12 device models: the low- and high-voltage MOS transistors, the ESD diodes and clamps, the
  MiM capacitor and the `rsil`, `rppd` and `rhigh` resistors.
- A parasitic stack from the diffusion contacts to TopMetal2, and MOS mismatch coefficients.

**Does not cover.**

- Metal-to-metal area capacitance beyond Metal1 to substrate, and electromigration lifetime:
  the process specification gives neither in a form the deck states.
- `well_bias`: the MOS recognisers carry no bulk terminal.
- `diodevdd_4kv`, `diodevss_4kv`, the isolated ESD diodes, `scr1`, `isolbox`, `rfmos`, `moscap`,
  `SVaricap`, the Schottky and antenna diodes, the npn13G2 bipolar transistors and the metal
  resistors have no recogniser. A pad protected only by an unrecognised device is reported
  unclamped.
- Recommended rules (an `R` suffix), seal-ring and pad-option rules, `Slt.i`, `GFil.i` and the
  TSV option.

## asap7

ASAP7, the predictive 7 nm FinFET PDK from Arizona State University and ARM. No fab builds it.

**Sources.** The ASAP7 design rule manual, PDK release 1p7, and its layer map; the BSIM-CMG model
cards; the `asap7sc7p5t` standard-cell CDL; the ASAP7 paper in the Microelectronics Journal (2016);
the OpenROAD-flow-scripts RC settings and OpenRCX extraction rules.

**Covers.**

- Design rules from the manual's tables 3.1 to 3.19.
- Eight transistor models (`nmos` and `pmos`, each in `lvt`, `rvt`, `slvt` and `sram`),
  recognised and sized by fin count (`nfin`). LVS matches the OpenROAD-flow-scripts ASAP7 standard
  cells against their CDL.
- Metal and via resistance and metal capacitance for M1 to M9.

**Does not cover.**

- Resistance for the middle of line (the gate, `LIG`, `LISD`, the diffusion and their contacts):
  no public source gives one. PEX on a layout that draws them is refused, naming the layer, and so
  is the IR-drop solve.
- Directional rules at their stricter limit: the deck language has no direction, so a pair of
  horizontal and vertical limits is one rule at the smaller limit. It flags only real violations
  and misses the stricter direction.
- Track and alignment rules, multi-patterning colour spacing, the 13.5 nm SRAM rules (off the
  1 nm grid), and antenna, density, electromigration, reliability, ESD and latch-up limits, which
  the manual does not state.

## Related

- [Choose a deck](../how-to/choose-a-deck.md)
- [Deck language](deck/README.md)
