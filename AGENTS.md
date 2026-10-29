# AGENTS.md

GPurify: physical verification (DRC, ERC, LVS, PEX) on the CPU or the GPU, in
Zig. [ARCHITECTURE.md](ARCHITECTURE.md) is the design and the port plan. Read
it before writing code. The Rust original at `../GPurify` is the specification.

## Skills to load first

Load each with the Skill tool (other agents: read
`~/.claude/skills/<name>/SKILL.md` and the companion files it names). Source:
https://github.com/OmarSiwy/NixOSConfig/tree/main/skills

| Skill                  | Use it for here                                                                           |
| ---------------------- | ----------------------------------------------------------------------------------------- |
| `data-oriented-design` | The six questions for every table, SoA, narrowest widths, handles                         |
| `codebase-clean-code`  | Owners, one spine per pipeline, the check-internal file order, seams on the cheapest rung |
| `api-design`           | Every `pub` function: usage code first, caller owns memory and flow                       |
| `code-style`           | File order, ≤500 code lines per file, `check_style.py`                                    |
| `simd-loops`           | Hot loops on 0.18: the plain-loop forms, or `@Vector` with a scalar oracle                |
| `doc-comments`         | Every `pub` item                                                                          |
| `ponytail` (ultra)     | How little code; never what shape the data takes                                          |
| `assertions`           | Contracts, capacities, bounded loops                                                      |
| `test-plan`, `tdd`     | `docs/testing-plan.md`: the oracles, the gates, a feature's definition of done            |

Language:

| Skill | Use it for here                         |
| ----- | --------------------------------------- |
| `zig` | Zig 0.18 idioms and the zero-cost probe |

Project-specific:

| Skill                             | Use it for here                                                                                |
| --------------------------------- | ---------------------------------------------------------------------------------------------- |
| `compiler-construction`           | `src/ingest`: the rule-deck and netlist readers, rows plus `extra_data`, coded diagnostics     |
| `gpu-kernel-optimization`         | Gompute row kernels and `geom.bulk`: where the data lives on the device, the roofline          |
| `gpu-parallel-algorithm-thinking` | Porting a sequential Rust check to a row kernel: the dependency DAG, work and span             |
| `branchless`                      | Data-dependent branches in edge and shape scans, before `simd-loops`                           |

## The method

Binding on every change, in every project.

### Code

- Five commitments: lean storage, no runtime residue, cheap change,
  contained failure, proof by test.
- Answer the six data questions before writing code. Then: one array per
  field, the narrowest width the stated range allows, typed `u32` handles
  with a sentinel, existence tables instead of flags, hot/cold split, tables
  sized once from a named capacity, a compile-time size assertion on every
  hot struct.
- An abstraction on a hot path carries an assembly probe: FOLDED, IDENTICAL,
  EQUIVALENT or NEGATIVE pass; RESIDUE fails the build. A "no residue" claim
  cites the probe, a speed claim cites a benchmark. Dispatch per batch, never
  per element.
- A seam names what varies and needs a second case today; it sits on the
  cheapest rung (concrete, free function, table, closed enum with exhaustive
  switch, comptime, request table, function-pointer table, `dyn`, plugin).
- Tables, transforms, one spine per pipeline (ifs up, fors down), one owner
  writes each table and everyone else appends requests. Three likely changes
  each have a change radius of zero; the compiler lists every other site.
- APIs start from the caller's code. The caller owns memory and flow:
  requests instead of callbacks, an immediate twin for anything retained.
  Factor at the second real instance.
- Branches: delete, then branchless, then vectorize along a lane axis. The
  `W == 1` instantiation is the scalar oracle; vectorization is verified in
  the assembly.
- GPU: SoA always, the roofline ceiling named with its arithmetic before
  tuning, data kept on the device, fixed-order reductions, the dependency DAG
  recovered before porting. "This belongs on the CPU" is a valid verdict.
- An operating error returns to the caller that can decide; a bug hits an
  assertion. Two or more split, paired assertions per function, a bound on
  every loop, input validated once at the edge, fallible work before the
  commit.
- Pass order: boundary, placement, data, zero-cost proof, contracts, tests,
  branches, lanes. Data layout beats brevity. Every pass keeps NaN gates,
  allocation-failure paths, `errdefer`s, trust-boundary validation and
  tolerances.

### Testing

- The oracle is named before the code and never recomputes the answer the
  way the code does. Cheapest first: assertions, a reference
  implementation, a round trip, a certificate, a metamorphic relation, a
  model, a golden with recorded provenance, a spec example.
- The main bug class is a wrong number with no crash, which coverage and
  fuzzing cannot see. A bug found by a person is a hole in the oracle set:
  it lands with its regression test and the oracle or generator that would
  have caught its class.
- A new test goes red on the bug before it is trusted green.
- Unsupported fails and never skips. A known failure is a named marker in
  the tree; an unexpected pass fails until the marker goes. Name lists are
  compared, never counts.
- A tolerance follows the oracle's own accuracy. Determinism is a test:
  1 job and N jobs give the same bytes, and the order is fixed, not the test.
- A flaky test is fixed or quarantined the same day, never retried
  silently.
- Tiers: pre-commit under 10 s, merge under 15 min, nightly, release. A
  release ships on numbers a script checks. The map lives in `TESTING.md`.

### Builds

- A build is a cache keyed on its declared inputs. Every producing step has
  an output argument, every checking step an exit-code check, every file
  read at run time is declared (`addFileInput`) or the step says
  `has_side_effects`. Keys hash contents, never absolute paths.
- Cut the artifact graph where edits land: one object per generated unit,
  narrow imports for shared ones, kernels out of host graphs.
- Zig edit loop: `zig build check --watch -fincremental`, one watch per
  artifact across all worktrees; the result that counts comes from a plain
  build. One global cache per toolchain store path; a worktree symlinks its
  `.zig-cache` to the main checkout's.
- Rust: flags live in `.cargo/config.toml`, never a one-off `RUSTFLAGS`;
  `check`, `build`, `test` and rust-analyzer agree on features, profile and
  target directory (rust-analyzer gets its own).
- Nothing collects a cache. Keep a byte budget per cache and delete old
  entries only while no build runs (the `long-term-garbage-collection`
  skill); a warm cache is kept, never wiped by routine.
- Gate on the exit code: `cmd | tail` swallows it, so use
  `exit "${PIPESTATUS[0]}"`.

### Maintaining

- `main` is green by machine: work lands through a pull request whose merge
  result passed the required checks. No `dev` branch; topic branches are
  deleted after the merge.
- Bots never push to `main`. Generated output ships as a release asset or
  through a gated pull request.
- Every dependency is pinned by commit and content hash, the toolchain by
  `flake.lock`, actions by SHA. A third-party input you hash is mirrored
  somewhere you control.
- The changelog is written by hand, one line per change citing its issue,
  every number in it measured. A release refuses a version mismatch, builds
  every target, checks every artifact and smokes the bundle.
- CI holds: the merge gate, every target compiled, docs that execute,
  reference suites gated by name, a nightly, the downstream contracts, the
  release job.

## Building

- Every `zig build` runs inside `nix develop -c …`. The shell pins Zig
  0.18.0-dev.349 (ESPice's, and Gompute's) with its own global cache.
- `zig build test-<module>` runs one module's unit tests and its
  `tests/<module>.zig` suite. Run your module's step, not `zig build test`,
  while siblings are mid-port.
- Pass `-Dgpu=false` for a fast loop. Run once without it before committing
  anything that touches a Gompute spec or row kernel: the device compile must
  stay green.
- `-Dgpu-tests=true` adds the CPU-vs-GPU row-kernel differentials (off by
  default). They fail, never skip, in a build without device kernels or on
  a machine without a CUDA/HIP driver.
- `-Dcomparison-tests=true` runs the comparisons against KLayout, Netgen,
  Magic, FastCap, FastHenry, OpenROAD, Yosys and ngspice, inside
  `nix develop .#comparison`. A missing tool fails, never skips.
- `-Dslow-tests` runs the field-solve tests too slow for Debug; it defaults
  to on outside Debug, so `-Doptimize=ReleaseSafe` runs everything.
- `zig build bench` (ReleaseFast whatever `-Doptimize` says, ~3 min, needs
  ~4 GB free) prints CPU 1 thread, CPU all threads and GPU times per kernel
  over a size sweep, and each kernel's crossover. Run it after touching a
  row kernel, `geom.bulk` or a work estimate, and before changing
  `auto_min_gpu_work` (src/main.zig) or the table in ARCHITECTURE.md's GPU
  section. Without a driver it prints the CPU columns only.
- Move data to the GPU in bulk: every upload goes through `geom.bulk.upload`
  (one allocation, one copy), never one `Buffer.upload` per column.
- Run one zig process per agent, and don't build while `free -g` shows under
  6 GB available.

## Testing

- Port a Rust file's tests with the file. Keep every `// Oracle:` line, and
  give each new test one.
- A golden or expected value that disagrees with an independent oracle is a
  Rust bug. Fix it, regenerate the golden, and say so in the commit.

## Committing

Commit at every green step: a file or family ported with its tests passing,
`zig fmt --check` clean. The message says what moved and from which Rust file.
Never commit red to `main`.
