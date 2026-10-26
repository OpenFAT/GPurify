# GPurify

Physical verification for integrated circuits: DRC, LVS, ERC and PEX, on the
CPU or the GPU, in Zig.

An empty violation table and a run that never executed look the same in most
tools. GPurify tells them apart: every rule says whether it ran and how many
shapes it examined, and a run that could not check everything you asked for
does not pass.

This is the Zig rewrite of the Rust tool. [ARCHITECTURE.md](ARCHITECTURE.md)
has the design and the port plan; [AGENTS.md](AGENTS.md) the working rules.

## Status

Rows of [docs/check-catalog.tsv](docs/check-catalog.tsv), the checks a signoff
verifier is expected to handle, by how far GPurify covers them. What a
`partial` or `missing` row lacks is in [docs/limitations.md](docs/limitations.md).

| Domain | Implemented | Expressible | Partial | Missing |
|---|---:|---:|---:|---:|
| DRC | 56 | 6 | 44 | 0 |
| LVS | 31 | 1 | 15 | 1 |
| ERC | 64 | 4 | 13 | 0 |
| PEX | 9 | 0 | 7 | 0 |
| Flow | 2 | 0 | 8 | 0 |

## Decks

A deck is a text file of layers, rules, connectivity and devices.
There are 83 design-rule kinds and 57 electrical-rule kinds.
[docs/deck.md](docs/deck.md) covers the language and every rule.

Four decks ship in `pdks/`:

| File | Drawn layers | Rules | Devices |
|---|---:|---:|---:|
| `ihp_sg13g2` | 75 | 465 | 12 |
| `gf180mcu` | 56 | 328 | 27 |
| `sky130` | 74 | 302 | 30 |
| `generic_finfet` (ASAP7) | 45 | 239 | 0 |

## Building

Every build runs in the pinned Nix shell:

```sh
nix develop -c zig build test -Dgpu=false                       # every suite, CPU only
nix develop -c zig build test -Dgpu=false -Doptimize=ReleaseSafe # with the slow tests
nix develop -c zig build test-check -Dgpu=false                  # one module's suites
```
