# Rules and stages

A `rule` line names one check, the layers it reads and its limit, under an id the report prints.
Every DRC and ERC check is written this way. This page covers what all rules share; each check's
own syntax is on its check page: [DRC checks](../drc/README.md), [ERC checks](../erc/README.md).

```text
rule <id> [warning] <check>(<layer>, ...; <name>: <value>, ...) [<comparison> <value>]
```

```text
rule M1.W    width(met1) >= 140nm
rule M1.WMAX width(met1) <= 10um
rule V1.SZ   size(via1) == 150nm x 150nm
rule M1.EOL  eol_space(met1; eol_width: 200nm) >= 170nm
rule M1.EN   enclosure(via1, met1, opposite) >= 50nm
rule V1.OUT  forbidden(via1 not met1)
rule M1.SR   warning space(met1) >= 400nm
rule GRID    off_grid(; pitch: 5nm)
```

## The id

The id is your name for the rule, and the report lists every violation under it. Use the foundry's
rule numbers (`m1.1`, `licon.5a`) so the report reads like the design manual. Each id appears once
in a deck; a second rule with the same id is an error. An id holds letters, digits, `_` and `.`
(see [Names](README.md#names)), and inside a `for` loop it may hold `{name}`
(see [Names, loops and switches](reuse.md#for)).

## Severity

A rule is an error rule unless it says `warning` after its id. A warning rule's violations are
listed and counted as warnings, and they do not fail the run.

This is how a foundry's recommended rules are carried beside the required rule they relax: the
rules IHP marks with an `R` suffix (`TM2.bR`), the ones SkyWater flags `RR` or `RC`, and ASAP7's
rule type `R`.

```text
rule M1.S   space(met1) >= 140nm
rule M1.SR  warning space(met1) >= 400nm
```

A warning rule that could not look at the layout, because it was skipped or refused, still fails
the run.

## Arguments

Inside the parentheses come the layers first, then the named parameters:

- **Layers** are positional, separated by commas. A layer argument can be a layer expression:
  `forbidden(via1 not met1)` reads the same as a derived layer declared for it. A check with no
  layer argument starts its parentheses with the `;`, as `off_grid(; pitch: 5nm)` does.
- **A modifier** is a bare word after the layers that picks a form of the check, such as
  `opposite` in `enclosure(via1, met1, opposite)`.
- **Named parameters** follow the layers after a `;` (or a `,`), each written `name: value`, in any
  order. A parameter whose value has parts of its own takes a group:
  `parallel: (space: 100nm, within: 50nm, two_edges: false)`. The named parameters may also go in a
  second pair of parentheses: `eol_space(met1)(eol_width: 200nm)`.

Every parameter a check lists is required. Where the check allows a parameter to be absent, write
`none` for it; leaving it out is still an error. An unknown parameter, or one given twice, is an
error that lists the parameters the check takes.

## The comparison

A check with one limit takes it as a comparison after the parentheses:

| Comparison | Means |
|---|---|
| `>= value` | A minimum: a measurement below the value is a violation |
| `<= value` | A maximum: a measurement above the value is a violation |
| `== value` | An exact value: any other measurement is a violation |

Each check accepts only the comparisons it lists: `space` takes `>=` alone, `width` takes `>=` or
`<=`, `size` takes `==`. A comparison a check does not take is an error, never a flipped rule.
Some checks take no comparison and state every value as a named parameter, as `off_grid` does,
and some have a form of each kind, as `width(met1; allowed: [..])` lists legal widths.

GPurify picks the check's form from its name, the number of layers, the modifier, the comparison
and the named parameters given. When no form fits, the error says what the check takes:

```text
error: deck rerr.deck: Invalid
...
  line 4:8: B: `width` needs a comparison: `>=` or `<=`
...
  line 6:8: D: `eol_space` is missing parameter `eol_width`
  line 7:42: E: unknown parameter `eol` for `eol_space`; expected eol_width
  line 8:8: F: `width` takes 1 layers, got 2
  line 9:8: G: unknown check kind `frobnicate`
```

## Outcomes

Every rule reports one of three outcomes, with the number of items it examined:

- `ran`: the rule looked at the layout. Its violations are listed.
- `skipped`: the rule did not run, and the reason is given: a layer it cannot do without holds no
  geometry (the die a density rule divides by), it needs
  [design intent](../design-intent.md) the run did not get, or an earlier stage found errors. A
  rule whose layer is merely empty, such as `width` on a layer with no shapes, runs and finds
  nothing.
- `refused`: the input is outside what the check can measure exactly, such as an angled edge on a
  check that reads only horizontal and vertical edges. GPurify does not guess.

> [!WARNING]
> A rule reported `skipped` or `refused` looked at nothing. Its zero violations prove nothing, and
> the run fails.

## Stages

```text
stage <name>
```

A `stage` line starts a stage: the rules written after it, up to the next `stage` line, are
checked together, stages in the order written. Once a stage finds an error, the rules of every
later stage are not checked and report `skipped`. On an early, dirty layout you fix the gross
errors first, and the report does not bury them under thousands of fine ones. This is the early
run of Calibre nmDRC-Recon and IC Validator Explorer, with the subset written in the deck rather
than picked by the tool.

- A deck with no `stage` line checks every rule.
- In a staged deck, every rule belongs to a stage: no rule comes before the first `stage` line.
- Each stage's rules are written together, so a stage name appears once.
- Warnings do not stop the next stage; errors do.
- DRC stops at the first stage with an error. ERC runs every rule and withdraws the later stages'
  results.

```text
grid 5nm
layer met1       = gds(10, 0)
layer via1       = gds(11, 0)
layer met2       = gds(12, 0)
layer met1_label = gds(10, 5)

stage gross
rule M1.W   width(met1) >= 140nm
rule M2.W   width(met2) >= 200nm
stage signoff
rule M1.S   space(met1) >= 140nm
rule V1.EN  enclosure(via1, met1) >= 30nm
```

On the layout of the [first-deck tutorial](../../tutorials/first-deck.md), the `gross` stage finds
a narrow wire, so the `signoff` rules wait:

```text
rules:
  M1.W: ran, examined 2 shapes, found 1 violations
  M2.W: ran, examined 1 shapes, found 0 violations
  M1.S: skipped, an earlier stage of the deck found errors; fix those first, examined 0 shapes, found 0 violations
  V1.EN: skipped, an earlier stage of the deck found errors; fix those first, examined 0 shapes, found 0 violations
violations: 1
  M1.W error layer met1 at (1000 nm, 550 nm) measured 100 nm against limit 140 nm on shape 1
summary:
...
```

`M1.W` finds wire B 100 nm wide against a 140 nm minimum, at (1000 nm, 550 nm), the middle of the
wire. `V1.EN` would have found the via's 25 nm enclosure, and does once `M1.W` is fixed.
