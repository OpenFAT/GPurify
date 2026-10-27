# CPU and GPU

GPurify runs its heavy computations on CPU threads or on a CUDA or HIP GPU, and gives the same
report either way. This page explains why the result does not depend on the device, how
`--backend auto` decides where each computation runs, and what the GPU gains on one measured
machine.

## One computation, two devices

Each GPU computation in GPurify is written once and compiled twice: for the CPU, where it runs
across a pool of threads, and for the GPU. Both devices run the same arithmetic in the same order.
Distances and areas are whole numbers on the layout's grid, which every device computes exactly.
The floating-point computations avoid fused multiply-add and keep a fixed order of summation, so
the CPU and the GPU round the same way at every step.

The result is that a report is bit-identical whichever device ran each part, and whatever the
number of threads. GPurify's own tests compare every GPU computation with its CPU twin bit for
bit, and rerun complete reports on the GPU to compare their bytes.

Sums whose order decides the result, such as the dot products inside an iterative solver, stay on
the CPU. They are small next to the work around them, and keeping them in one place keeps their
order fixed.

## How `--backend auto` decides

`--backend cuda` or `--backend hip` sends every GPU computation to that GPU. `--backend cpu` keeps
everything on the CPU. `--backend auto`, the default, decides per kind of computation:

1. It takes the first GPU that loads, CUDA before HIP. With none, everything runs on the CPU.
2. It measures one representative computation of each kind on both devices, at growing sizes,
   until a call takes 8 ms. From the last two sizes on each side it fits a cost line: a fixed
   cost per call plus a cost per unit of work, transfers included.
3. Where the two lines cross is that kind's threshold. A call at least that large goes to the
   GPU; a smaller one stays on the CPU. If the GPU's cost per unit of work is no lower, that kind
   never goes to the GPU.

On an RTX 4060 Laptop GPU the measurement takes about 170 ms. Because the device never changes the
result, the measurement changes only how long a run takes.

## What the GPU gains

These numbers come from GPurify's benchmark on one machine: an NVIDIA GeForce RTX 4060 Laptop GPU
(double precision at 1/64 of single precision, PCIe 4.0 x8) against 32 CPU threads on 16 cores,
in an optimised build. A GPU time includes moving the call's data to and from the GPU.

| Computation | Largest size measured | CPU, 1 thread | CPU, 32 threads | GPU | GPU against 32 threads |
|---|---|---:|---:|---:|---|
| Exact distance between candidate shape pairs (spacing rules) | 6.2 million pairs | 369 ms | 33 ms | 13.1 ms | 1.95 times faster; faster at every size measured |
| Density windows | 25 million rectangle visits | 44 ms | 7.4 ms | 190 ms | Never faster |
| Field solver, potential rows | 32768 panels | 3.4 s | 316 ms | 595 ms | Never faster (0.53 times the speed) |
| Field solver, field rows | 32768 panels | 2.8 s | 261 ms | 487 ms | Never faster (0.54 times the speed) |

On this machine `auto` therefore sends every pair-distance call to the GPU and keeps density and
the field solver on the CPU. A run with 30 spacing rules spent 508 ms on pair distances with the
GPU, against 989 ms on 32 threads. The layout's shapes go to the GPU once per run, which took
114 ms here, and every later call reuses them.

The GPU loses where moving data costs more than the computation saves. At the largest size, density windows move about
400 MB per call for little arithmetic, and even the computation alone, without the transfer, is no
faster than 32 threads. The field solver is limited by double-precision arithmetic, which this
GeForce card runs at 1/64 rate. On a card with fast double precision, such as a data-centre GPU,
`auto` measures a finite threshold for the field solver and moves it to the GPU without any change
to the command.

Everything else GPurify does runs on the CPU.

## Related

- [Run on the GPU](../how-to/run-on-the-gpu.md)
- [Command line](../reference/cli.md)
