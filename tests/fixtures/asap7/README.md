# ASAP7 standard cells

Nine cells of the ASAP7 7.5-track library and their schematics, for
`tests/gpurify/asap7.zig` (LVS) and `tests/gpurify/asap7_klayout.zig`
(the KLayout DRC differential).

- `*.gds`: one cell each, written by KLayout from
  `GDS/asap7sc7p5t_28_{R,L,SL,SRAM}_220121a.gds`, and `*.cdl` that cell's
  `.SUBCKT` from `CDL/LVS/asap7sc7p5t_28_{R,L,SL,SRAM}.cdl`, both in
  https://github.com/The-OpenROAD-Project/asap7sc7p5t_28 at commit
  e5bd25da72cd297b8c0ec6f77600e0cbaa1124d0 (BSD-3-Clause, `LICENSE`).
- `asap7.lydrc`: OpenROAD-flow-scripts' KLayout DRC deck,
  `flow/platforms/asap7/drc/asap7.lydrc` at commit
  64939f3717ad7c694199ba04cb98924b98022868 (BSD-2-Clause, in its header).

The cells: `INVx1` at each threshold (`_R`, `_L`, `_SL`, `_SRAM`: one
transistor model each), `INVx2` (two fingers), `NAND2x1` (a stack),
`AOI21x1` (a stack drawn as split fingers), `TIEHIx1` (one fin, a tied
gate), `BUFx2` (two stages).
