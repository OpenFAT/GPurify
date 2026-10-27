# Command line

Every GPurify command, its arguments and options, their defaults, and the exit codes.

## Synopsis

```text
gpurify <drc|erc|lvs|pex|all> <layout> --deck <deck> [options]
gpurify lib <layout> --deck <deck> --spec <spec.json> --output-dir <dir> [options]
gpurify xor <layout> <other> --deck <deck> [options]
gpurify <fill|enhance> <layout> <output.gds> --deck <deck> [options]
gpurify system <system.json> --reference <netlist> [options]
gpurify compare <reference> <candidate> [--spec <compare.json>]
```

The command comes first. Options and file arguments follow in any order. Every option that takes
a value takes it as the next argument (`--deck sky130`, not `--deck=sky130`), and an empty value
is refused. GPurify has no `--help`; run it with no arguments to list the commands.

## Commands

| Command | Arguments | What it does |
|---|---|---|
| `drc` | `<layout>` | Checks the deck's design rules. |
| `erc` | `<layout>` | Checks the deck's electrical rules. |
| `lvs` | `<layout>` | Checks the layout's connectivity and compares it with the reference netlist. Requires `--reference`. |
| `pex` | `<layout>` | Extracts parasitic resistance, capacitance and, for field-solved nets, inductance. |
| `all` | `<layout>` | Runs DRC, ERC, LVS and PEX. A check whose input is missing is skipped, which fails the run. |
| `lib` | `<layout>` | Writes a macro's Liberty files under `--output-dir`, as its spec asks. Runs no check. |
| `xor` | `<layout> <other>` | Reports every region where a drawn layer of the two layouts differs. |
| `fill` | `<layout> <output.gds>` | Writes the layout with density fill from the deck's `fill` lines, then runs DRC on the file it wrote. |
| `enhance` | `<layout> <output.gds>` | Writes the layout with redundant vias and widened straps, then runs DRC on the file it wrote. |
| `system` | `<system.json>` | Checks several dies, placed and bonded as the system file says, against one system netlist. |
| `compare` | `<reference> <candidate>` | Compares two parasitic netlists (SPEF or DSPF) net by net. |

A layout is a GDS file, or a DEF file when its name ends in `.def`. `fill`, `enhance` and `lib`
take GDS only.

## Options

| Option | Value | Default | Commands | Meaning |
|---|---|---|---|---|
| `--deck` | file or shipped name | None, required | every command but `system` and `compare` | The deck: a path, or `sky130`, `gf180mcu`, `ihp_sg13g2` or `asap7` (also `generic_finfet`). A shipped name wins over a file of that name. |
| `--reference` | file | None | `lvs` (required), `pex`, `all`, `lib`, `system` (exactly one), `erc` (only with `--currents`) | The reference netlist: SPICE, CDL or Spectre. Repeat it to give Verilog files (`.v`) for the top level beside one SPICE or Spectre cell library. |
| `--intent` | file | None | `erc`, `all` | The design intent file: supply voltages and per-net limits. Without it, the rules that need it are skipped. |
| `--currents` | file | None | `erc`, `all` | Simulated per-terminal currents (`espice-emir/1`) for the electromigration and IR-drop rules. Requires `--reference`. |
| `--quasistatic` | net name | None | `pex` | Field-solve this net's capacitance and inductance instead of using the closed-form estimate. Repeat for more nets. |
| `--format` | `text`, `json`, `spef`, `dspf`, `spice` | `text` | see below | What standard output carries. |
| `-o` | file | None | `pex` and `all` with `--format spice` | Also writes each process corner's netlist to `<file>.<corner>`. |
| `--lef` | file | None | any command on a `.def` layout; `lib` (at most one) | A LEF file the DEF layout reads, technology LEF first, then cell LEFs. Repeat for more. For `lib`, the macro's LEF, whose pins are checked against the spec. |
| `--spec` | file | None | `lib` (required), `compare` | `lib`: the macro spec. `compare`: a JSON file stating the tolerance, `{"tolerance": 5}` in percent. |
| `--output-dir` | directory | None | `lib` (required) | Where `lib` writes its Liberty files. |
| `--backend` | `auto`, `cpu`, `cuda`, `hip` | `auto` | every command but `compare` | Where kernels run. `auto` uses the first GPU that loads, CUDA before HIP, else the CPU. A named GPU backend that does not load is refused. |
| `--threads` | 1 to 65535 | one per CPU | every command but `compare` | CPU worker threads. |

### Formats

| Format | Commands | Output |
|---|---|---|
| `text` | every command but `lib` and `compare` | The text report. |
| `json` | every command but `lib` and `compare` | The JSON report. |
| `spef` | `pex`, `all` | A SPEF file, with `min:typ:max` triplets when the deck has process corners. |
| `dspf` | `pex`, `all` | A DSPF file with an instance section. |
| `spice` | `pex`, `all` | A `.subckt` of the extracted network and devices, for a simulator. |

[Report format](report.md) describes `text` and `json`. With `--format dspf` or `spice` and a
`--reference`, the run also does LVS, so that the netlist is named in the reference's terms.
Without a reference, GPurify writes the netlist with layout names and warns on standard error that
it cannot be back-annotated.

`compare` takes only `--spec`. Without it the tolerance is 5%.

### Refused options

An option a command has no use for is refused, never ignored:

```text
error: --format spef is not something this check produces
```

A few options have moved into the files that state them, and GPurify names where:

| Option | Now |
|---|---|
| `--p2p` | The deck's `report p2p "<net>" at [(x, y), ..]` line. |
| `--coupling` | The deck's `report coupling "<net>" "<net>"` line. |
| `--cluster` | The deck's `report cluster <len>` line. |
| `--accuracy` | The `lib` spec's `accuracy` field. |
| `--tolerance` | The `compare` spec's `tolerance` field. |

The grid is the layout's own (the GDS `UNITS` record, or the DEF's `UNITS DISTANCE MICRONS`),
and the temperature and the extra report lines are in the deck. No option sets them.

## Output

The report goes to standard output. GPurify builds the whole report before writing its first
byte, so a run that fails leaves standard output empty.

Standard error carries:

- errors, each starting `error: `, followed by indented lines that locate the problem,
- warnings, each starting `warning: `,
- what `fill` and `enhance` added, as `wrote <file>: ...`,
- each corner file `-o` wrote, as `wrote <file>: corner <name>`.

`lib` writes one line per file it wrote to standard output, as `<accuracy>: wrote <path>`.

## Exit codes

| Code | Meaning |
|---|---|
| 0 | Pass. Every selected check ran, no rule was skipped or refused, and no error was found. Warnings do not fail a run. For `lib`, every file was written. For `compare`, every compared value is within the tolerance and both files hold the same nets. |
| 1 | Anything else: an error found, a rule or check skipped or refused, an input missing or refused, a command line refused. |

[How a run passes](../explanation/outcomes.md) explains why a skipped rule fails the run.
