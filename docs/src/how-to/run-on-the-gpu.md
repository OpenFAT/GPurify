# Run on the GPU

Send GPurify's heavy kernels to an NVIDIA (CUDA) or AMD (HIP) GPU. The report is the same, byte for
byte, whichever device runs it.

## Before you start

- A GPurify build with GPU kernels, which a default build has
  ([Install GPurify](install.md#gpu-support)).
- An NVIDIA GPU with its driver, or an AMD GPU with ROCm's HIP runtime. GPurify needs the driver
  at run time, not a CUDA or ROCm toolkit.

## Steps

1. Run as usual. The default, `--backend auto`, uses the first GPU that loads, CUDA before HIP,
   and falls back to the CPU when none does:

   ```sh
   gpurify drc diffpair.gds --deck sky130
   ```

   On a GPU, `auto` first measures each kind of kernel on the CPU and on the GPU, which took about
   170 ms on an RTX 4060 Laptop GPU, and sends a call to the GPU only where the GPU measured
   faster for its size. [CPU and GPU](../explanation/cpu-and-gpu.md) explains the choice.

2. To send every kernel call to the GPU, name the backend:

   ```sh
   gpurify drc diffpair.gds --deck sky130 --backend cuda
   ```

   Use `--backend hip` for an AMD GPU. A named backend that does not load is refused, never
   replaced by the CPU:

   ```text
   error: --backend cuda: this build carries no cuda kernels, or no cuda driver or device loads here
   ```

3. To keep everything on the CPU, use `--backend cpu`. Set the number of CPU threads with
   `--threads`; the default is one per CPU.

4. To confirm that the device does not change the result, compare the reports:

   ```sh
   gpurify drc diffpair_bad.gds --deck sky130 --backend cpu > cpu.txt
   gpurify drc diffpair_bad.gds --deck sky130 --backend cuda > cuda.txt
   cmp cpu.txt cuda.txt && echo identical
   ```

   ```text
   identical
   ```

## What runs on the GPU

On the RTX 4060 Laptop GPU, `auto` sends the exact distance between candidate shape pairs (the core
of the spacing rules) to the GPU and keeps density windows and the field solver on the CPU, where
they measured faster. A card with fast double precision moves the field solver to the GPU too,
without a change to the command. [CPU and GPU](../explanation/cpu-and-gpu.md) gives the measured
numbers.

## Related

- [Command line](../reference/cli.md)
- [CPU and GPU](../explanation/cpu-and-gpu.md)
