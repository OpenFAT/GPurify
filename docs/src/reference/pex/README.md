# Parasitic extraction

Parasitic extraction (PEX) turns the layout's wires and vias into the resistance, capacitance and
inductance a timing tool or a simulator adds to the schematic. GPurify extracts every labelled net
of the layout in one run and writes the result as SPEF, DSPF or a simulator-ready SPICE subcircuit.

## What a run needs

```sh
gpurify pex <layout> --deck <deck> --format spef > layout.spef
```

- **The deck's parasitic stack.** Write one `pex` line for each conductor layer and each via layer
  that carries a net. It gives the layer's thickness, its height above the substrate, its sheet
  resistance (or resistance per cut, for a via), the dielectric it sits in, and its area and fringe
  capacitance to the substrate. A layer with no `pex` line has unknown parasitics, not zero ones,
  so GPurify refuses the run and names the layer.
- **The deck's `extraction` line.** It states the extraction type and the lateral coupling reach,
  `coupling_halo`, in thicknesses of each layer. Every type but `r` needs the reach. Without it,
  GPurify refuses the run, because no reach suits every process. The shipped decks state
  `extraction rcc coupling_halo 10`.
- **Text labels on the nets.** SPEF and DSPF name each net by its label. A net with no label has
  no name to write, so GPurify refuses the file rather than invent one.
- **Optionally, a reference netlist.** With `--reference`, `pex` also runs LVS. The
  `--format spice` netlist then uses the reference's subcircuit name, pin order, net names and
  device names.
- **Optionally, `--quasistatic <net>`.** It field-solves the named nets' capacitance and inductance
  instead of using the closed forms. Repeat it for more nets.

The text report of a `pex` run shows only whether extraction ran, was skipped or was refused. The
parasitics are in the `--format spef`, `dspf` or `spice` output. The deck's `report p2p` and
`report coupling` lines add measurements to the text report.

```text
summary:
  drc: not selected
  erc: not selected
  lvs: not selected
  pex: refused, layer via: no pex row gives this via layer a positive resistance per cut
```

## Outputs

| Format | For | Holds |
|---|---|---|
| `--format spef` | A timing tool | IEEE 1481 SPEF, one `*D_NET` per net. With process corners, every value is a `min:typ:max` triplet. |
| `--format dspf` | A simulator or a netlist comparison | DSPF 1.4, every element as a SPICE card, nominal corner only |
| `--format spice` | A simulator, in place of the schematic subcircuit | One `.subckt` with the devices on their extracted nodes and the R, C, L and K cards |

The same inputs always give a byte-identical file.

## Pages

| Page | Covers |
|---|---|
| [Resistance extraction](resistance.md) | Wire resistance from sheet resistance and squares, and via resistance per cut |
| [Capacitance extraction](capacitance.md) | Capacitance to the substrate, coupling between nets, and the substrate resistance network |
| [Inductance extraction](inductance.md) | Self and mutual inductance of field-solved nets |
| [Accuracy and field solving](accuracy.md) | The field solver, process corners, temperature, qualification against another extractor, device-region, fill and through-silicon via effects |
| [PEX output formats](output.md) | Extraction types, SPEF and DSPF, routed DEF designs, point-to-point reports and the simulator-ready netlist |

To understand how GPurify models a wire before reading the entries, see
[How parasitics are modelled](../../explanation/parasitics.md).
