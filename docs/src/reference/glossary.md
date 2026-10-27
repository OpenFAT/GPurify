# Glossary

The words these pages use, each with one meaning.

| Term | Meaning |
|---|---|
| backend | The device a computation runs on: the CPU, or a CUDA or HIP GPU. Chosen with `--backend`. |
| black box | A cell LVS compares by its pins alone, its contents ignored on both sides. |
| CDL | Circuit Description Language, a SPICE dialect used for LVS netlists. GPurify reads it as SPICE. |
| check | A kind of test GPurify runs, such as minimum spacing or a floating gate. Also each of the four check families: DRC, ERC, LVS and PEX. |
| corner | A process corner: a variant of the deck's parasitic stack, extracted beside the nominal one. |
| deck | The text file of layers, rules, connectivity, devices and the parasitic stack for one process. |
| design intent | The supply voltages and per-net limits that ERC reads from `--intent`. |
| device | A transistor, resistor, capacitor or diode that the deck's `device` lines recognise. |
| DRC | Design rule checking: widths, spacings, enclosures, areas, densities and other geometric rules. |
| DSPF | Detailed Standard Parasitic Format, a parasitic netlist for circuit simulators. |
| edge | One side of a shape. |
| ERC | Electrical rule checking: antenna, floating gates and wells, voltage stress, electromigration, IR drop and other electrical rules. |
| examined | The count of items a rule looked at: shapes, pairs of shapes, edges or windows, by rule. |
| field solve | Computing a net's capacitance and inductance from the electric and magnetic field, for nets named with `--quasistatic`. |
| grid | The layout's database unit, from its GDS `UNITS` record. Every coordinate is a whole number of grid steps. |
| label | A text element in the layout that names the net of the shape it sits on. |
| layer | A named layer in the deck, drawn (`gds(L, D)`) or derived from others (`and`, `not`). |
| layout | The GDS (or DEF) file a run checks. |
| LVS | Layout versus schematic: comparing the devices and nets extracted from the layout with the reference netlist. |
| net | A set of shapes joined through conductors and vias, named by a label or by GPurify. |
| PEX | Parasitic extraction: the resistance, capacitance and inductance of the layout's nets. |
| polygon | One GDS boundary as drawn, before touching pieces merge. |
| ran, skipped, refused | A rule's three outcomes. Only `ran` means the rule looked at the layout. |
| reference netlist | The schematic netlist LVS compares against, given with `--reference`. |
| rule | One `rule` line in a deck: an id, a check and its limit. The id is what the report prints. |
| shape | One closed region on a layer, after touching pieces merge. |
| shipped deck | One of the four decks built into GPurify: `sky130`, `gf180mcu`, `ihp_sg13g2` and `asap7`. |
| SPEF | Standard Parasitic Exchange Format (IEEE 1481), a parasitic netlist for timing tools. |
| stage | A group of rules in a staged deck. A stage's rules run only when every earlier stage found no error. |
| status | How far GPurify covers a check: Implemented, Partial, Expressible (written with general deck operations) or Missing. |
| verdict | The LVS result: `Match`, `Mismatch` with its discrepancies, or `Inconclusive` with its reason. |
| violation | One place where a rule's limit is broken. It is an error, or a warning for a `warning` rule. |
| waiver | A shape on a waiver layer that excuses the violations of a rule under it. |
