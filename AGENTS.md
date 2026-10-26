# AGENTS.md

GPurify: physical verification (DRC, ERC, LVS, PEX) on the CPU or the GPU, in
Zig. [ARCHITECTURE.md](ARCHITECTURE.md) is the design and the port plan. Read
it before writing code. The Rust original at `../GPurify` is the specification.

## Skills to load first

Load each with the Skill tool (other agents: read
`~/.claude/skills/<name>/SKILL.md` and the companion files it names).

| Skill | Use it for here |
|---|---|
| `data-oriented-design` | The six questions for every table, SoA, narrowest widths, handles |
| `codebase-clean-code` | Owners, one spine per pipeline, the check-internal file order, seams on the cheapest rung |
| `api-design` | Every `pub` function: usage code first, caller owns memory and flow |
| `code-style` | File order, ≤500 code lines per file, `check_style.py` |
| `simd-loops` | Hot loops on 0.18: the plain-loop forms, or `@Vector` with a scalar oracle |
| `zig` | Zig 0.18 idioms and the zero-cost probe |
| `ponytail` (ultra) | How little code; never what shape the data takes |

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
- `-Dslow-tests` runs the field-solve tests too slow for Debug; it defaults
  to on outside Debug, so `-Doptimize=ReleaseSafe` runs everything.
- Gate on the exit code. `cmd | tail` swallows it.
- Run one zig process per agent, and don't build while `free -g` shows under
  6 GB available.

## Testing

- Port a Rust file's tests with the file. Keep every `// Oracle:` line, and
  give each new test one.
- Unsupported fails and never skips.
- A golden or expected value that disagrees with an independent oracle is a
  Rust bug. Fix it, regenerate the golden, and say so in the commit.
- Check that a new test goes red on the bug before trusting it green.

## Committing

Commit at every green step: a file or family ported with its tests passing,
`zig fmt --check` clean. The message says what moved and from which Rust file.
Never commit red to `main`.
