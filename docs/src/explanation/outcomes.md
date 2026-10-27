# How a run passes

A verification tool prints an empty list of violations for one of two reasons: it checked everything
and found nothing, or it did not check at all. The two look the same in most tools. GPurify keeps
them apart. This page explains how, and why a report with zero violations still fails when a rule did not look.

## Three outcomes for every rule

Every rule in the deck ends a run with one of three outcomes, and the report prints it beside the
rule:

- **`ran`**: the rule looked at the layout. Its violations, if any, are listed.
- **`skipped`**: the rule could not run, and the report says why. It needed design intent you did
  not give, a deck statement that is missing, geometry that is not there, or an earlier stage of a
  staged deck failed.
- **`refused`**: the layout holds something the rule cannot measure exactly, such as a 45° edge
  on a check that measures only horizontal and vertical edges. GPurify does not guess an answer.

Only `ran` means the rule looked at your layout. A skipped or refused rule reports zero
violations because it reported nothing at all, and that zero proves nothing.

## The same three outcomes for each check

The summary gives each of DRC, ERC, LVS and PEX a status of its own: `ran`, `not selected`,
`skipped` or `refused`. A check is skipped when its main input is missing, as LVS is under `all`
without a reference netlist. It is refused when its input is outside what it decides exactly, as
LVS is when the reference netlist has no single top cell.

## What passes

A run passes, and GPurify exits 0, when all of these hold:

- every check you selected ran,
- no rule was skipped or refused,
- no violation is an error.

Anything else exits 1. A layout that drew nothing wrong still fails when a rule could not look at
it.

Here is a DRC run of the IHP SG13G2 deck on a layout that holds one Metal1 square and nothing
else:

```sh
gpurify drc m1_ihp_sg13g2.gds --deck ihp_sg13g2
```

```text
rules:
...
  M1.j: skipped, the layer it names holds no geometry, examined 0 shapes, found 0 violations
  M1.k: skipped, the layer it names holds no geometry, examined 0 shapes, found 0 violations
...
violations: 0
summary:
  drc: ran
  erc: not selected
  lvs: not selected
  pex: not selected
  30 rules skipped
  386 rules clean
  0 violations: 0 errors, 0 warnings
```

There are no violations, and the exit code is 1. `M1.j` and `M1.k` are the Metal1 density rules.
They measure density inside the die boundary, the `prboundary` layer, and this layout draws none,
so there is no window to measure. A tool that counted only violations would call this layout
clean. GPurify reports that 30 rules did not look at it.

So read a report from the bottom up: first the check statuses, then `rules skipped`, and only then
the violations.

## Rules that ran on nothing

A rule that ran has sometimes examined nothing. `examined 0 shapes` beside `ran` means the rule found
nothing of its kind in the layout: a deep n-well rule on a layout with no deep n-well, or a spacing
rule whose shapes are all far apart. That is a correct result, and it passes. It is also the place
to look when a layer is mapped wrongly: a rule that should have examined hundreds of shapes and
examined 0 points at a layer the layout draws on a different GDS number than the deck expects.

GPurify refuses a layout that draws on a GDS layer the deck neither declares nor ignores, so a
misnumbered layer is caught when the layout is loaded rather than read as empty.

## Warnings

A rule the deck writes as `warning` reports its violations as warnings. They are listed and
counted, and they do not fail the run. This is how a foundry's recommended rules are carried. A
warning rule that is skipped or refused still fails the run: it was meant to look and did not.

## Waivers

A waiver excuses the violations of a rule under a waiver shape. A waived violation moves to its
own `waived` section of the report and does not count towards the summary or the exit code. Every
waived violation is still printed, so a reviewer sees what was excused.
[Waive a violation](../how-to/waive.md) shows how.

## Stages

A staged deck checks its rules in stages. Once a stage finds an error, the rules of every later
stage report `skipped`, so that the report is not buried under fine errors while gross ones
remain. The run fails anyway, because of the errors the early stage found.

## Related

- [Report format](../reference/report.md)
- [Use GPurify in CI](../how-to/use-in-ci.md)
