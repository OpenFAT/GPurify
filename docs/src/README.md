# GPurify

GPurify is a physical verification tool for integrated circuits. It reads a layout (GDS, or DEF
with its LEFs) and a deck describing the process, and checks the layout four ways: design rules
(DRC), electrical rules (ERC), layout against schematic (LVS) and parasitic extraction (PEX). It
runs on the CPU, or on a CUDA or HIP GPU, and gives the same report on either.

These pages are for layout and analog designers who check their own blocks, for PDK and deck
authors who write the rules, and for CAD engineers who run GPurify in a flow. They assume you know
physical verification. They do not assume you know GPurify.

## What it checks

- **DRC**: widths, spacings, enclosures, extensions, areas, densities, grid and angle rules,
  multi-patterning, and rules composed from derived layers.
- **ERC**: antenna ratios, floating gates and wells, voltage stress across domains, ESD and
  latch-up paths, electromigration and IR drop, from current budgets or simulated currents.
- **LVS**: the layout's devices and nets against a SPICE, CDL, Spectre or Verilog netlist, with
  device parameters within tolerance.
- **PEX**: resistance and capacitance of every net, and inductance for nets you field-solve,
  written as SPEF, DSPF or a SPICE netlist.

Beside the checks, GPurify adds metal fill, redundant vias and widened power straps to a layout,
compares two layouts, checks a multi-die assembly, and characterises a cell into Liberty files.
It also writes a deck's layers, rules and limits as JSON, for layout generators that need the
process rules without parsing the deck.

Four decks ship with it, for SkyWater SKY130, GlobalFoundries GF180MCU, IHP SG13G2 and ASAP7.
[Shipped decks](reference/shipped-decks.md) says what each covers and what it does not.

## How a run passes

```sh
gpurify drc diffpair.gds --deck sky130
```

Every rule in the report ends `ran`, `skipped` or `refused`. Only `ran` means the rule looked at
your layout. A run passes, and exits 0, only when every check you selected ran, no rule was
skipped or refused, and no error was found. Everything else exits 1, including a report with zero
violations from rules that never looked.
[How a run passes](explanation/outcomes.md) explains why.

## Where to go next

- New to GPurify: [Check your first layout](tutorials/first-layout.md), then
  [Run your first LVS](tutorials/first-lvs.md).
- Installing: [Install GPurify](how-to/install.md).
- A task in mind: the how-to guides, starting with [Choose a deck](how-to/choose-a-deck.md).
- Looking something up: [Command line](reference/cli.md), [Report format](reference/report.md),
  the [Deck language](reference/deck/README.md), and the check pages for
  [DRC](reference/drc/README.md), [ERC](reference/erc/README.md), [LVS](reference/lvs/README.md)
  and [PEX](reference/pex/README.md).
- Understanding a result: the explanation pages, starting with
  [How a run passes](explanation/outcomes.md).
