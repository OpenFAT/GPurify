# Install GPurify

GPurify is built from source. You end up with one executable, `gpurify`, that carries the four
shipped decks and runs on the CPU, or on a CUDA or HIP GPU where a driver is present.

GPurify builds on Linux (x86-64 and AArch64) and macOS (x86-64 and Apple silicon).

## Install with Nix

### Before you start

- [Nix](https://nixos.org/download/) with flakes turned on (`experimental-features = nix-command
  flakes` in `nix.conf`).
- Git, and network access for the first build, which fetches the Zig compiler and GPurify's one
  dependency.

### Steps

1. Clone the repository:

   ```sh
   git clone https://github.com/OmarSiwy/GPurify
   cd GPurify
   ```

2. Build an optimised executable inside the pinned development shell:

   ```sh
   nix develop -c zig build -Doptimize=ReleaseFast
   ```

   The shell pins the exact Zig compiler GPurify needs, so you install nothing else.

3. Put `zig-out/bin` on your `PATH`, or copy `zig-out/bin/gpurify` to a directory that is on it.

4. Check the install by running GPurify with no arguments:

   ```sh
   gpurify
   ```

   ```text
   error: expected a subcommand: drc, erc, lvs, pex, all, lib, xor, fill, enhance, system, compare or deck
   ```

   The message lists every command. [Command line](../reference/cli.md) describes each one.

## Install without Nix

### Before you start

- Zig 0.18.0-dev.349+d924f83bf exactly. GPurify follows Zig's development branch, and a newer or
  older compiler refuses to build it. Get it from <https://ziglang.org/download/>, under the
  development builds.
- Git, and network access for the first build.

### Steps

1. Clone the repository:

   ```sh
   git clone https://github.com/OmarSiwy/GPurify
   cd GPurify
   ```

2. Build:

   ```sh
   zig build -Doptimize=ReleaseFast
   ```

3. Put `zig-out/bin` on your `PATH`, then run `gpurify` with no arguments to check it, as in step 4
   above.

## GPU support

A default build compiles the GPU kernels for CUDA and HIP. For CUDA it targets the GPU of the
machine you build on. To build for another NVIDIA card, name its architecture with
`-Dcuda-arch`, for example `-Dcuda-arch=sm_89`. For AMD, `-Dhip-arch` names the target and
defaults to `gfx1100`. [Run on the GPU](run-on-the-gpu.md) covers the rest.

## Related

- [Check your first layout](../tutorials/first-layout.md)
- [Command line](../reference/cli.md)
