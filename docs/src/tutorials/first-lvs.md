# Run your first LVS

In this tutorial you compare a SKY130 layout with its schematic netlist, read a match, change the
schematic so that it no longer agrees with the layout, and read the mismatch GPurify reports. It
takes about 10 minutes.

## What you need

- GPurify on your `PATH`. [Install GPurify](../how-to/install.md) covers it.
- `diffpair.gds`, the DRC-clean differential pair from
  [Check your first layout](first-layout.md), in your working directory. Finish that tutorial
  first, including the fix.

## Write the schematic

LVS (layout versus schematic) compares two netlists: the one GPurify extracts from the layout's
shapes, and the reference netlist you give it. Save this SPICE netlist as `diffpair.spice`:

```text
* Two sky130 nfets on a shared source, bulk on the substrate tap.
.subckt diffpair inp inn outp outn tail vss
XM1 outp inp tail vss sky130_fd_pr__nfet_01v8 W=2 L=0.5
XM2 outn inn tail vss sky130_fd_pr__nfet_01v8 W=2 L=0.5
.ends diffpair
```

Each `XM` card is one transistor: drain, gate, source and bulk, then the SKY130 model name and its
width and length in micrometres. The model is the one the shipped deck recognises for a thin-oxide
n-channel transistor drawn on `diff` under `nsdm`.

## Compare

```sh
gpurify lvs diffpair.gds --deck sky130 --reference diffpair.spice
```

```text
rules:
  lvs.floating_net: ran, examined 6 shapes, found 0 violations
  lvs.label_conflict: ran, examined 6 shapes, found 0 violations
  lvs.net_seed_conflict: ran, examined 6 shapes, found 0 violations
  lvs.terminal_net: ran, examined 8 shapes, found 0 violations
  lvs.terminal_count: ran, examined 2 shapes, found 0 violations
violations: 0
lvs: Match
summary:
  drc: not selected
  erc: not selected
  lvs: ran
  pex: not selected
  0 rules skipped
  5 rules clean
  0 violations: 0 errors, 0 warnings
```

The exit code is 0. The report has two parts that matter for LVS.

- **The `lvs.` rules** check the layout's own connectivity before any comparison: no floating
  net, no label on two nets, no net with two labels, every device terminal on a net, and every
  device with its full set of terminals.
- **The line `lvs: Match`** is the verdict of the comparison. GPurify found two transistors on
  six nets in the layout, the same two in the netlist, wired the same way, with the same model,
  width and length.

## Break it

A schematic that changes after the layout is drawn is the common cause of an LVS failure. Change
`XM2`'s model to the low-threshold transistor, `sky130_fd_pr__nfet_01v8_lvt`, as a designer
retuning the pair might:

```text
XM2 outn inn tail vss sky130_fd_pr__nfet_01v8_lvt W=2 L=0.5
```

Compare again:

```sh
gpurify lvs diffpair.gds --deck sky130 --reference diffpair.spice
```

```text
...
violations: 1
  lvs.model_mismatch error at (0 nm, 0 nm) measured 1 against limit 0
lvs: Mismatch([ModelMismatch { layout_device: 1, ref_device: 1, layout_model: "sky130_fd_pr__nfet_01v8", ref_model: "sky130_fd_pr__nfet_01v8_lvt" }])
summary:
  drc: not selected
  erc: not selected
  lvs: ran
  pex: not selected
  0 rules skipped
  5 rules clean
  1 violations: 1 errors, 0 warnings
```

The exit code is 1.

## Read the mismatch

The verdict is now `Mismatch`, and it lists each discrepancy it found. Here there is one,
`ModelMismatch`:

- `layout_device: 1` and `ref_device: 1` are the two devices GPurify paired, counted from 0. On
  the reference side, device 1 is the second card, `XM2`.
- `layout_model` is what the layout draws, a standard thin-oxide transistor, and `ref_model` is
  what the schematic asks for, the low-threshold one.

GPurify reports a model mismatch, rather than two unpaired devices, because the two transistors are
wired the same way and nothing else about them differs. The same discrepancy appears as an error row
of the rule `lvs.model_mismatch`, so it counts towards the summary and the exit code. One
discrepancy was found against a limit of none allowed.

To fix a model mismatch, change whichever side is wrong. Here the layout would need the SKY130
low-threshold implant (`lvtn`) over `XM2`'s channel, or the schematic goes back to
`sky130_fd_pr__nfet_01v8`. Put the netlist back and compare once more to see `lvs: Match` again.

## What you did

You compared a layout with its schematic, read a match, introduced a change on one side and traced
the discrepancy back to the device and the parameter that differ.

To read further:

- [Run LVS against a SPICE or CDL netlist](../how-to/run-lvs.md) covers hierarchical netlists,
  CDL, Verilog tops and the deck's LVS controls.
- [LVS checks](../reference/lvs/README.md) lists every discrepancy LVS reports.
- [How LVS matches devices](../explanation/how-lvs-matches.md) explains the pairing.
