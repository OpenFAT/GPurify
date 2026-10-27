# GPurify

Physical verification for integrated circuits: DRC, LVS, ERC and PEX in one
tool, on the CPU or the GPU.

An empty violation table and a run that never executed look the same in most
tools. GPurify tells them apart: every rule says whether it ran and how many
shapes it examined, and a run that could not check everything you asked for
does not pass. The same inputs give the same report bytes on any machine,
thread count or backend.

## Quick start

Every build runs in the pinned Nix shell (Zig 0.18-dev, ZLS):

```sh
nix develop -c zig build -Doptimize=ReleaseFast
./zig-out/bin/gpurify drc my_layout.gds --deck sky130
```

```
gpurify <drc|erc|lvs|pex|all|lib> <layout.gds> --deck <file|shipped deck>
gpurify xor <layout> <other>          gpurify fill|enhance <layout> <out.gds>
gpurify system <system.json> --reference <netlist>
gpurify compare <reference.spef> <candidate.spef>
```

Common flags: `--reference` (LVS netlist), `--intent` (ERC design intent),
`--quasistatic <net>` (field-solve a net in PEX), `--format text|json|spef|dspf`,
`--backend auto|cpu|cuda|hip`, `--threads N`. The exit code is 0 only when
every rule ran and passed.

## CPU or GPU

The heavy kernels are written once and run on CPU threads or CUDA/HIP
([Gompute](https://github.com/OmarSiwy/Gompute)), with bit-identical results
either way. `--backend auto` times each kernel class on the GPU it finds at
startup (~170 ms) and sends work there only where it wins. On an RTX 4060
Laptop, DRC pair distances run 1.95x faster than 32 CPU threads; f64 field
solves stay on the CPU there, and move to the GPU on cards with fast f64.
`zig build bench` prints the numbers for your machine.

## Status

Rows of [docs/check-catalog.tsv](docs/check-catalog.tsv), the checks a signoff
verifier is expected to handle, by how far GPurify covers them. What a
`partial` or `missing` row lacks is in [docs/limitations.md](docs/limitations.md).

| Domain | Implemented | Expressible | Partial | Missing |
|---|---:|---:|---:|---:|
| DRC | 56 | 6 | 44 | 0 |
| LVS | 31 | 1 | 15 | 1 |
| ERC | 64 | 4 | 13 | 0 |
| PEX | 9 | 0 | 8 | 0 |
| Flow | 2 | 0 | 8 | 0 |

## How it is tested

Every test names its oracle: a hand-worked value, a closed form, a law
(symmetry, round trip, conservation), or a brute-force reference (bitmap DRC,
exhaustive LVS isomorphism, dense nodal solve). 237 golden reports pin the
output byte for byte, ten readers are fuzzed, and CPU and GPU kernels are
compared bit for bit.

Against other tools:

| Tool | Status |
|---|---|
| ngspice | Agrees: Liberty delays and transitions within 0.13 %, leakage within 0.0003 % (`-Dngspice-tests=true`) |
| KLayout, Netgen, Magic, FastCap, FastHenry, OpenROAD, Yosys | Not yet run against this build; the differentials need those tools installed |

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

## Development

```sh
nix develop -c zig build test -Dgpu=false                        # every suite, CPU only
nix develop -c zig build test -Dgpu=false -Doptimize=ReleaseSafe # with the slow tests
nix develop -c zig build test -Doptimize=ReleaseSafe -Dgpu-tests=true # CPU vs GPU, needs a driver
```

[ARCHITECTURE.md](ARCHITECTURE.md) has the design; [AGENTS.md](AGENTS.md)
the working rules.

## License

MIT. See [LICENSE](LICENSE).
