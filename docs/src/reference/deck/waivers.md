# Waivers

A waiver excuses the violations of one rule at known places, such as an IP block's accepted
exceptions. In GPurify a waiver is geometry: a shape drawn in the layout on a layer the deck names
for the rule.

```text
waive <rule id> <layer>
```

```text
layer waive_m1 = gds(255, 1)
waive M1.W waive_m1
```

## What a waiver does

A violation of the rule whose reported point lies on a shape of the waiver layer, its edge
included, is waived. A waived violation:

- is listed after the others, under `waived` (the JSON report's `waived` key),
- does not count toward its rule's violations, and
- does not fail the run.

Because the waiver is a shape, a waiver drawn inside a cell waives at every placement of that cell,
however the placement is rotated or mirrored, as Calibre Auto-Waivers' waivers on their own
geometry layer do.

## Rules for waivers

- The waiver layer is a layer of the deck, usually a drawn layer kept for waivers alone.
- A rule may have several waiver layers, one `waive` line each. The same rule and layer twice is
  an error.
- The rule must be one of the deck's. A waiver for a misspelt rule would waive nothing, so the
  deck is refused instead. The `waive` line may come before or after its rule.
- Inside a `for` loop, the id may hold `{name}` like a rule id (see
  [Names, loops and switches](reuse.md#for)).

```text
error: deck bad2.deck: Malformed
  waive M1.X: no rule of the deck has that id
```

## Example

```text
grid 5nm
layer met1       = gds(10, 0)
layer via1       = gds(11, 0)
layer met2       = gds(12, 0)
layer met1_label = gds(10, 5)
layer waive_m1   = gds(255, 1)

rule M1.W  width(met1) >= 140nm
rule V1.EN enclosure(via1, met1) >= 30nm
waive M1.W waive_m1
```

The layout of the [first-deck tutorial](../../tutorials/first-deck.md), with a 200 nm square on
`gds(255, 1)` drawn over the middle of the narrow wire B:

```sh
gpurify drc two_metal_waived.gds --deck waive.deck
```

```text
rules:
  M1.W: ran, examined 2 shapes, found 0 violations
  V1.EN: ran, examined 1 shapes, found 1 violations
violations: 1
  V1.EN error layer via1 at (1875 nm, 12 nm) measured 25 nm against limit 30 nm on shape 3 and shape 0
waived: 1
  M1.W error layer met1 at (1000 nm, 550 nm) measured 100 nm against limit 140 nm on shape 1
...
```

The `M1.W` violation at (1000 nm, 550 nm) lies on the waiver square, so it is waived and `M1.W`
counts 0 violations. The `V1.EN` violation is not on a waiver shape and still fails the run.
