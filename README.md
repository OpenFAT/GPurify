# GPurify

[![test](https://github.com/OpenFAT/GPurify/actions/workflows/test.yml/badge.svg)](https://github.com/OpenFAT/GPurify/actions/workflows/test.yml)
[![cross](https://github.com/OpenFAT/GPurify/actions/workflows/cross.yml/badge.svg)](https://github.com/OpenFAT/GPurify/actions/workflows/cross.yml)
[![nightly](https://github.com/OpenFAT/GPurify/actions/workflows/nightly.yml/badge.svg)](https://github.com/OpenFAT/GPurify/actions/workflows/nightly.yml)
[![docs](https://github.com/OpenFAT/GPurify/actions/workflows/docs.yml/badge.svg)](https://openfat.github.io/GPurify/)
[![license: MIT](https://img.shields.io/badge/license-MIT-blue.svg)](LICENSE)

Physical verification for integrated circuits: DRC, LVS, ERC and PEX in one
tool, on the CPU or the GPU.

An empty violation table and a run that never executed look the same in most
tools. GPurify tells them apart: every rule says whether it ran and how many
shapes it examined, and a run that could not check everything you asked for
does not pass. The same inputs give the same report bytes on any machine,
thread count or backend.

**Documentation: <https://openfat.github.io/GPurify/>.** Tutorials, how-to
guides, the deck language, and every check GPurify runs: what it catches, how
it is measured, and how to write it in a deck.

## Quick start

GPurify builds from source in a pinned Nix shell, which brings the exact Zig
compiler it needs:

```sh
git clone https://github.com/OpenFAT/GPurify
cd GPurify
nix develop -c zig build -Doptimize=ReleaseFast
./zig-out/bin/gpurify drc my_layout.gds --deck sky130
```

On a layout holding one 100 nm wide `met1` wire, the report lists every rule
with what it examined, then the violation and a summary:

```text
rules:
  ...
  m1.1: ran, examined 1 shapes, found 1 violations
  ...
violations: 1
  m1.1 error layer met1 at (50 nm, 500 nm) measured 100 nm against limit 140 nm on shape 0
summary:
  drc: ran
  erc: not selected
  lvs: not selected
  pex: not selected
  0 rules skipped
  264 rules clean
  1 violations: 1 errors, 0 warnings
```

The exit code is 0 only when every selected check ran and passed, so a
script or CI job can gate on it. [Install GPurify](https://openfat.github.io/GPurify/how-to/install.html)
covers building without Nix and for a GPU, and
[Check your first layout](https://openfat.github.io/GPurify/tutorials/first-layout.html)
walks through a first run.

## What it checks

| Check | What it does | Needs |
|---|---|---|
| [DRC](https://openfat.github.io/GPurify/reference/drc/README.html) | Design rules: width, spacing, enclosure, area, density, cuts, multi-patterning and more | A layout and a deck |
| [LVS](https://openfat.github.io/GPurify/reference/lvs/README.html) | Extracts the layout's devices and nets and compares them with a schematic | A reference netlist (SPICE, CDL, Spectre or Verilog) |
| [ERC](https://openfat.github.io/GPurify/reference/erc/README.html) | Electrical rules: antenna, electromigration and IR drop, ESD, latch-up, voltage and connectivity | Design intent for the voltage- and current-based rules |
| [PEX](https://openfat.github.io/GPurify/reference/pex/README.html) | Extracts wire resistance, capacitance and inductance, written as SPEF, DSPF or a simulator-ready SPICE netlist | The deck's `pex` stack |

## Commands

```text
gpurify <drc|erc|lvs|pex|all> <layout> --deck <file|shipped deck>
gpurify lib <layout> --deck <deck> --spec <spec> --output-dir <dir>
gpurify xor <layout> <other> --deck <deck>
gpurify fill|enhance <layout> <out.gds> --deck <deck>
gpurify system <system.json> --reference <netlist>
gpurify compare <reference.spef> <candidate.spef>
gpurify deck <file|shipped deck> --format json
```

A layout is GDS, or DEF with `--lef`. Common options: `--reference` (the LVS
netlist), `--intent` (ERC design intent), `--currents` (simulated currents
for EM and IR drop), `--quasistatic <net>` (field-solve a net in PEX),
`--format text|json|spef|dspf|spice`, `--backend auto|cpu|cuda|hip` and
`--threads N`. The [command-line reference](https://openfat.github.io/GPurify/reference/cli.html)
lists every command and option.

## Status

Rows of [tests/check-catalog.tsv](tests/check-catalog.tsv), the checks a
signoff verifier is expected to handle, by how far GPurify covers them. Each
row has an entry in the [check reference](https://openfat.github.io/GPurify/reference/drc/README.html),
which says what a `partial` or `missing` row lacks.

| Domain | Implemented | Expressible | Partial | Missing |
|---|---:|---:|---:|---:|
| DRC | 56 | 6 | 44 | 0 |
| LVS | 33 | 1 | 15 | 1 |
| ERC | 64 | 4 | 14 | 0 |
| PEX | 9 | 0 | 8 | 0 |
| Flow | 2 | 0 | 8 | 0 |

`Expressible` means the check has no rule kind of its own but can be written
with general deck operations. Open work is tracked in
[issues](https://github.com/OpenFAT/GPurify/issues).

## Decks

A deck is a text file of layers, rules, connectivity and devices.
There are 83 design-rule kinds and 57 electrical-rule kinds.
The [deck language reference](https://openfat.github.io/GPurify/reference/deck/README.html)
covers the language, and `gpurify deck <deck> --format json` shows what a
deck compiles to.

Four decks ship in `pdks/`:

| File | Drawn layers | Rules | Devices |
|---|---:|---:|---:|
| `ihp_sg13g2` | 75 | 465 | 12 |
| `gf180mcu` | 56 | 328 | 27 |
| `sky130` | 74 | 302 | 30 |
| `asap7` (also `generic_finfet`) | 54 | 242 | 8 |

`asap7` recognises its FinFETs by fin count (`nfin`) and LVS-matches the
OpenROAD-flow-scripts ASAP7 standard cells against their CDL. Its middle of
line has no public resistance, so PEX and IR drop are refused on a layout
that draws it, naming the layer.

## CPU or GPU

The heavy kernels are written once and run on CPU threads or on CUDA or HIP
([Gompute](https://github.com/OmarSiwy/Gompute)), with bit-identical results
either way. `--backend auto` times each kernel class on the GPU it finds at
startup (about 170 ms) and sends work there only where it wins. On an RTX 4060
Laptop, DRC pair distances run 1.95 times faster than 32 CPU threads; f64 field
solves stay on the CPU there, and move to the GPU on cards with fast f64.
`zig build bench` prints the numbers for your machine.

## How it is tested

Every test names its oracle: a hand-worked value, a closed form, a law
(symmetry, round trip, conservation), or a brute-force reference (bitmap DRC,
exhaustive LVS isomorphism, dense nodal solve). Golden reports pin the output
byte for byte, ten readers are fuzzed, and CPU and GPU kernels are compared
bit for bit. A test checks that every catalog row has exactly one entry in
the documentation, carrying the row's status.

Against other tools:

| Tool | Status |
|---|---|
| ngspice | Agrees: Liberty delays and transitions within 0.13 %, leakage within 0.0003 % (`-Dngspice-tests=true`) |
| KLayout | asap7 DRC against OpenROAD-flow-scripts' `asap7.lydrc` on nine ASAP7 cells, rule by rule against the ledger [tests/xcheck/asap7.tsv](tests/xcheck/asap7.tsv): 193 paired rules, two that differ |
| Magic | A sky130 differential pair extracted by both, simulated in the same bench: equal gain, bandwidth within 5.2 % (Magic extracts no wire resistance) |
| Netgen, FastCap, FastHenry, OpenROAD, Yosys | Provided by `nix develop .#comparison`, not yet compared against this build |

The KLayout and Magic comparisons run with `-Dcomparison-tests=true` inside
`nix develop .#comparison`.

## Development

```sh
nix develop -c zig build test -Dgpu=false                        # every suite, CPU only
nix develop -c zig build test -Dgpu=false -Doptimize=ReleaseSafe # with the slow tests
nix develop -c zig build test -Doptimize=ReleaseSafe -Dgpu-tests=true # CPU against GPU, needs a driver
nix develop .#docs -c docs/diagrams/render.sh && nix develop .#docs -c mdbook serve docs
```

[AGENTS.md](AGENTS.md) holds the working rules for contributors, human or
agent, and [docs/STYLE.md](docs/STYLE.md) the style the documentation
follows. Bugs and feature requests go to
[issues](https://github.com/OpenFAT/GPurify/issues).

## License

MIT. See [LICENSE](LICENSE).
