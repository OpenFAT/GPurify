# Compare two layouts

`gpurify xor` compares two versions of a layout layer by layer and reports every region where they differ. When you finish, you know each layer and place that changed, and by how much area.

## Before you start

- Both layouts are GDS files on the same grid: their `UNITS` records agree. Two layouts on different grids are refused.
- You have a deck that declares every GDS layer both layouts draw. A shipped deck works. A shape on a layer the deck neither declares nor ignores refuses the layout, as it does for any check.

## Steps

1. Run `xor` with the two layouts and the deck.

   ```sh
   gpurify xor diffpair_bad.gds diffpair.gds --deck sky130
   ```

   ```text
   rules:
     xor.areaid_ce: ran, examined 0 shapes, found 0 violations
     xor.areaid_diode: ran, examined 0 shapes, found 0 violations
   ...
     xor.npc: ran, examined 1 shapes, found 1 violations
   ...
   violations: 1
     xor.npc error layer npc at (800 nm, 3400 nm) measured 2160000 nm^2 against limit 0 nm^2
   summary:
     drc: ran
     erc: not selected
     lvs: not selected
     pex: not selected
     0 rules skipped
     73 rules clean
     1 violations: 1 errors, 0 warnings
   ```

   The second layout adds a 2.4 µm by 0.9 µm `npc` shape, 2.16 µm² of area that only one layout has. The point (800 nm, 3400 nm) is a corner of that region.

2. Read the rules. Each drawn layer the deck declares has one rule, `xor.<layer>`, and each connected region where exactly one of the two layouts has material on that layer is one violation. The measured value is the region's area, holes excluded. A layer's violations add up to the area on which the two layouts disagree. The report does not say which layout holds the material.

3. Read the exit code. Two identical layouts pass with exit 0. Any difference fails the run with exit 1, as does a layer that cannot be compared.

   ```sh
   gpurify xor diffpair.gds diffpair.gds --deck sky130
   ```

   ```text
   ...
   summary:
     drc: ran
     erc: not selected
     lvs: not selected
     pex: not selected
     0 rules skipped
     74 rules clean
     0 violations: 0 errors, 0 warnings
   ```

4. For a machine-readable list, add `--format json`. `xor` takes `text` and `json` only.

   ```sh
   gpurify xor diffpair_bad.gds diffpair.gds --deck sky130 --format json
   ```

## What GPurify does not cover

- Only drawn layers are compared. Derived layers and text labels are not.
- A layer with a shape `xor` cannot compare exactly, such as a 45° edge, reports `refused` for that layer.
- `xor` reports the area that changed on a cut layer. It does not hold that change to a tolerance by the number of cuts, as the SkyWater SKY130 IR-drop rules do. Write that check as a deck rule instead; see the [Deck language](../reference/deck/README.md).

## Related

- [Command line](../reference/cli.md)
- [Report format](../reference/report.md)
- [DRC checks](../reference/drc/README.md)
- [How a run passes](../explanation/outcomes.md)
