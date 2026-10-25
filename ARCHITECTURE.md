# Architecture

GPurify is a physical-verification engine: one run reads a GDSII layout and a
process deck and answers DRC, ERC, LVS and PEX, each rule saying whether it ran
and how many shapes it examined. This is the Zig rewrite of the Rust tool at
`../GPurify` (176k lines: 106k source, 130k tests). The Rust code is the
specification and one of the oracles; it is not the design. Where the Rust
layout fights the rules below, the rules win.

Every file here follows the skills `data-oriented-design`, `codebase-clean-code`,
`api-design`, `code-style`, `simd-loops`, `zig` and `ponytail` (ultra). Data
layout beats code brevity; `ponytail` decides how little code to write, never
what shape the data takes.

## Modules

Five `build.zig` modules, each imported by name, each listed below everything
it imports (`owners` in `build.zig`; a back edge fails `zig build`). A module
is a Rust crate's worth of tables with one owner; inside it, files are owners
of narrower tables.

```
geom ──► ingest ──► check ──► extract ──► gpurify ──► gpurify (exe, src/main.zig)
  ▲                   │          │
  └── gompute ────────┴──────────┘          tests/testgen.zig (test-only)
```

| Module | Owns (writes) | Rust source |
|---|---|---|
| `geom` | units (`Dbu` i64 ±2^40, `DbuArea` i128, `Grid`, `Qty`), `StrTable`, `GeometryStore`, `ValidatedLayer`, spatial index, candidate pairs, booleans, derived layers, width, connectivity labels, `linalg`, the `Device` (backend choice) | `crates/geom/src` + the pieces moved down below |
| `ingest` | `gds.Library`, `Provenance`, `Deck`, `Netlist`, `DesignIntent`, `System`, LEF/DEF `Design` | `crates/ingest/src` |
| `check` | `Violations`, `RuleRun`s, `NetTable`, `DeviceTable`, `PortTable`, compiled DRC/ERC rule tables, power grid, LVS graph/partition/verdict, `CompiledDeck` | `crates/check/src` |
| `extract` | `ParasiticNetwork`, conductor regions, field mesh, `CapMatrix`, `InductMatrix`, substrate admittance | `crates/extract/src` |
| `gpurify` | `Loaded`, `Extracted`, `Outputs`, `Summary`; the spines; report writers (text, JSON, SPEF, DSPF, GDS); Liberty; shipped decks | `src/{engine,export,liberty,pdks.rs}` |
| exe | argument parsing, formatting, exit code | `src/cli`, `src/bin` |

`src/<module>/root.zig` is the module's public surface and only re-exports.
Leaves import siblings by relative path and never their own `root.zig`.

### Inside `check`: one direction

The Rust `check` crate has cycles (deck↔drc↔erc, topology↔drc, lvs→erc). In
Zig they are legal inside one module but still forbidden: files import only
files above them in this order, and a test in `tests/check.zig` greps for back
edges.

```
report.zig ─► rects.zig ─► proximity.zig ─► topology/ ─► drc/ ─► erc/ ─► lvs/ ─► deck/
```

| Moved | From (Rust) | To |
|---|---|---|
| `LayerRects`, `SortedRects`, `figure_rects`, `owners_of`, `owners_by_point`, `figures_holding`, `bbox_gap2`, `gap_midpoint`, `poly_dist2` | `drc/rules/mod.rs` | `check/rects.zig` |
| `Validated`, slim `Scratch`, `pair_distances_into`, `join_nested`, `label_pairs_into`, `prepare*`, `cross_pairs`, `pair_spacing_by_net`, `net_pair_spacing`, `nearest`, `inside_where`, `tagged_figures` | `drc/rules/{mod,spacing,presence}.rs`, `drc/mod.rs` | `check/proximity.zig` |
| `Holes`, `in_material` | `topology/net.rs` | `check/rects.zig` |
| `untied_points`, `TapGrid`, `point_in_region` | `erc/rules/supply.rs` | `check/topology/taps.zig` |
| `first_vertex`, `centre`, `ring_edge` | `erc`, `topology` | `geom` |
| `DRC_KINDS`, `ERC_KINDS` | `deck/rules.rs` | `drc/kinds.zig`, `erc/kinds.zig` |
| `point_in_ring` takes `xs, ys` (breaks ops↔view) | `geom/ops.rs` | `geom/ops.zig` |
| `glob_matches` (breaks deck↔layout) | `ingest/layout.rs` | `ingest/glob.zig` |
| `check/system.rs` (multi-die) | `check` | `gpurify/system.zig` |

The engine→cli and report→drc "edges" in Rust are rustdoc links; they vanish.

## Data

Rules from `data-oriented-design`, applied once here so no file re-decides them:

- **SoA by default**, CSR (`start: []u32` + payload) for ragged rows. Widths
  from the spec: `LayerId` u16, `PolyId`/`NetId`/`DeviceId`/`StrId` u32,
  `Dbu` i64, `DbuArea` i128 (exact; never f64). Row counts are u32 and asserted.
- **Handles, not pointers**: every cross-table reference is an index.
- **Rule tables per kind.** Rust's 83-variant fat `Rule` enum becomes one SoA
  table per kind plus `order: []struct { kind: Kind, row: u32 }` in deck order;
  the spine switches exhaustively on `kind` (ladder rung 4). ERC already looks
  like this in Rust (57 kind tables). No `else =>` on a boundary enum.
- **`*Into(out, …)`**: a transform clears and refills a caller-owned output, so
  a loop over layers reuses one allocation. Allocators are parameters named for
  their lifetime (`gpa`, `run_arena`, `scratch`); allocation is split from
  initialization.
- **Lifetimes**: a run has three phases with their own arenas: load
  (`Loaded`, lives to the end), extract (`Extracted`, lives to the end), check
  (per-domain scratch, freed after each domain). Parser token buffers and file
  bytes die at the end of their reader.
- **Determinism**: the same inputs give the same report bytes on every machine,
  thread count and backend. Ids follow interning order; outputs are sorted
  canonically; float reductions have a fixed order (GPU section).

## Spines

One function per pipeline, one line per transform; every branch that picks
*which* work runs lives in the spine.

```
gpurify.run(inputs, options):            load → extract → checks → report
  load:     gds.parse → grid → deck.compile → flatten → deriveLayers → resolveLabels → netlist/intent
  extract:  refuseConductingChannels → extractNets → recogniseDevices → bindPorts
  checks:   integration(DEF) → drc → erc → holdBackStages → lvs → pex → netSeedShorts → waivers → summarize
  drc:      for rule in order: switch (kind) { … } → recordRun → forget(last use)
  erc:      classifyNets → intent → netTypes → propagateVoltage → powerGrid → solveIrDrop → rules
  lvs:      fromLayout → lde → checkLayout → blackBoxes → fromReference → reduce → refine → interpret
  pex:      analytical → [quasistatic → reciprocity → inductance → overlay] → deviceRegion → tsv → substrate → fill → reduce
```

## GPU (Gompute)

The engine runs on the CPU or the GPU from one source. Gompute specializes the
backend at compile time, and a machine without a driver falls back to the CPU.

**Two kernel shapes, both written once:**

1. **Elementwise**: `g.map`/`zip`/`mapIndexed`/`gather`/`scatter` specs in
   the module's `kernels.zig`. On the CPU the generic body runs at `@Vector`
   width. Examples: per-edge length, per-vertex off-grid, per-region R and C,
   per-edge current density, `axpy`.
2. **Row kernels** (ESPice's `lu_device.zig` pattern): the body is a generic
   function in `kernels.zig` over the row index and `g.GlobalPtr`-style
   slices. The device root exports it with `g.exportRaw`; the CPU calls the
   same body across a `std.Thread.Pool` of row blocks. One body for both
   backends means the results agree bit for bit.

**Where the GPU earns it**, ranked by measured or estimated work. Everything
not listed stays on the CPU until a profile says otherwise.

| Kernel | Work | Shape | Exactness |
|---|---|---|---|
| BEM matvec + dielectric rows (`extract`) | dense O(P²) per GMRES iteration, P = 10³–10⁵ (cap 2²⁰), ~50–1000 iterations × conductors: 10⁸–10¹² evals | row kernel, strict ascending-j fold per row | f64, no FMA contraction (strict float mode), so bit-identical to the CPU |
| Near-pair Galerkin build (`extract`) | O(rows·P) distance test + 4×4 quadrature per near pair | row kernel, count → host scan → fill (CSR) | same |
| Henry Zb assembly (`extract`) | dense nb² mutual inductances, three formulas | row kernel; pairs binned by formula first so warps don't diverge | same |
| Candidate-pair exact distance (`check/proximity`) | per pair O(edgesA·edgesB), every spacing/enclosure/net rule | row kernel over the pair list | integer / f64 exact below 2²⁶: bit-identical |
| Density windows (`check/drc/area`, antenna) | windows × rects binned by row | row kernel per window | integer areas: exact |
| `axpy`, `xpay` (`geom`) | O(n) per CG/GMRES step | `zip` spec | no FMA: exact |

**Ordered reductions stay on the CPU.** `dot`/`nrm2` keep Rust's strict
left-fold order, because the order decides CG/GMRES convergence and the golden
bytes. They are O(n) next to an O(n²) matvec, so only `x` goes up and `y` comes
down per iteration. A GPU reduction would need a fixed blocked order on both
backends; add it only when a profile shows `dot` dominating.

**Selection.** `geom.Device` is a small value: `{ backend: .cpu | .cuda | .hip,
min_gpu_work: u64, threads: u16 }`, built once by the spine from
`--backend auto|cpu|cuda|hip` and passed down as a parameter (no global). A
kernel call goes to the GPU when `backend != .cpu` and its work estimate is at
least `min_gpu_work`. That threshold is a calibration knob, measured by
`zig build bench`, not a constant.

**Verification.** Every row kernel has a differential test: CPU body against
GPU body, bit-equal, at sizes 0, 1, block−1, block, 3·block+1. It runs where a
driver exists and fails rather than skips with `--backend cuda`. CI compiles
every kernel for nvptx and amdgcn on every push.

**Device math limits:** i128 and the 256-bit `wide` integers must lower on
nvptx/amdgcn. Probe them in wave 1 before any i128 kernel ships. If they don't
lower, carry areas as two u64 limbs in the kernel only.

## Tests

The Rust suite moves over with its data, because the Rust tool is not fully
correct and the port needs a net from the first file.

- **Layout.** A module's unit tests live in its files; its integration suite
  is `tests/<module>.zig`, which imports `tests/<module>/*.zig`
  (`zig build test-<module>`). Generators and oracles are the `testgen` module
  (`tests/testgen.zig`, ported from `crates/testgen`). Data lives in `tests/`:
  `fixtures/` (incl. `_source/conformance.gds`), `golden/`, `foundry/`,
  `fuzz/{regressions,seeds}`, plus `pdks/` and `docs/` (catalog, deck
  language), reached through the `paths` build option.
- **Every test names its oracle** in an `// Oracle:` line: a hand-worked value,
  a closed form, a law (metamorphic, round trip), a brute-force reference
  (bitmap DRC, O(n²) pairs, dense nodal solve), or a reference tool. A
  meta-test fails a test without one, ported from `tests/oracles.rs`.
- **Rust is an oracle, not the truth.** The goldens (`tests/golden`, 237 files)
  are Rust's bytes. A Zig run that matches them is ported faithfully. A Zig run
  that differs and agrees with an independent oracle exposes a Rust bug: fix it
  here, regenerate the golden, and note it in `CHANGELOGS.md`.
- **Unsupported fails, never skips.** A known gap carries `KNOWN GAP: <cause>`
  and an issue.
- **Tiers.** Merge: `zig build test -Doptimize=ReleaseSafe` on Linux and macOS,
  plus the GPU compile. Nightly, later: `--fuzz` over the ten readers, live
  differentials in a `.#oracles` shell (KLayout, Netgen, Magic, FastCap,
  FastHenry, OpenROAD, ngspice), CPU vs GPU on a GPU runner, scaling.

## Porting rules

- Rust → Zig: `Result` + `thiserror` → a named error set plus a `Diagnostic`
  out-parameter that carries location and values. `Vec` → unmanaged
  `std.ArrayList` with the allocator passed in. `HashMap` → unmanaged hash
  map, or a sorted array when the keys are dense ids. `serde_json` →
  `std.json`. `flate2` → `std.compress.flate`. `rayon` → `std.Thread.Pool`.
  `fearless_simd` → a plain loop on 0.18 (autovectorized, checked in asm), or
  `@Vector` with the scalar loop kept as its oracle (`simd-loops`). Phantom
  `Qty<D, P>` → `Qty(dim, prefix)`, a comptime type function.
- A file holds one transformation and at most 500 code lines; Rust's
  6805-line `drc/ruleset.rs` splits by kind family. Each file opens with a
  `//!` in → out header and Contents (`code-style`).
- Port a file's tests with the file. A file is done when its ported tests pass
  in Debug and ReleaseSafe, `zig fmt` is clean and `check_style.py` passes.
- Commit at every green step, with a message saying what moved.

## Port plan

Agents work in waves along the DAG. Each agent runs in its own git worktree on
`port/<scope>`, loads the skills above, reads this file and its Rust source,
and commits each green step. At the end of a wave its branch merges into
`main`. At most four agents run at once, each with one zig process (31 GB of
RAM, 32 cores).

| Wave | Agents (parallel) | Scope | Rust lines src + tests |
|---|---|---|---|
| 0 | lead | data copy, this file, `AGENTS.md`, CI, `geom` units (`dbu`, `qty`, `arith`, `intern`, `ids`, `bbox`) and `Device` | ~1k |
| 1 | **geom**, **ingest**, **testgen** (shapes, rng, gds writer, assertions first) | rest of geom + i128 device probe; every reader | 7.6k+7.4k, 21.6k+4.3k, 3.7k |
| 2 | **check-base**, **extract-field** | `report`, `rects`, `proximity`, `topology`, check kernels; field mesh/solve/matvec/dielectric/henry + GPU row kernels | ~4k+6k, ~5k+2k |
| 3 | **drc+deck**, **lvs**, **extract-pex** | drc families + deck compile/builder/print/query (ERC rows compile to an empty table until wave 4); lvs; analytical, network, reduce, compare, foreign, substrate, fill, tsv | ~23k+25k, ~6k+8k, ~4.5k+1.5k |
| 4 | **erc** | erc + deck's ERC rows | ~19k+20k |
| 5 | **engine**, **liberty+export**, **cli** | gpurify spines, system, fill/enhance/incremental/xor; writers; Liberty; CLI | ~14k+61k |
| 6 | **gpu**, **fuzz** | calibrate `min_gpu_work`, CPU vs GPU differentials, bench; `std.testing.fuzz` targets, nightly workflow | — |

## Change drills

| Change | Edits | Radius |
|---|---|---|
| A new DRC rule kind | `drc/kinds.zig` row, a new kind table + its transform file in `drc/`, one `switch` arm the compiler lists, the deck builder row, its test | 1 switch site |
| Move a CPU loop to the GPU | its body moves into `kernels.zig` as a spec or row kernel, the call site picks a backend through `Device`, plus a differential test | 1 call site |
| A new input format (OASIS) | `ingest/oasis.zig` producing the same `gds.Library` rows, one line in the load spine | 1 spine line |
