# Choose a deck

Every run needs a deck: the layers, rules, connectivity, devices and parasitic stack of one
process. Use a shipped deck as it is, start your own from a copy of one, or write a small deck of
your own.

## Before you start

- GPurify installed ([Install GPurify](install.md)).
- A layout in GDS (or DEF with its LEFs) for the process.

## Use a shipped deck

1. Find your process in [Shipped decks](../reference/shipped-decks.md): `sky130`, `gf180mcu`,
   `ihp_sg13g2` or `asap7`. Read what the deck does not cover before you rely on a clean result.
2. Pass its name to `--deck`:

   ```sh
   gpurify drc diffpair.gds --deck sky130
   ```

   GPurify builds the deck in; no file is read. A file named `sky130` in the working directory
   is ignored. Give a path, such as `./sky130`, to read a file instead.

## Start from a copy of a shipped deck

Use this when you need a line the shipped deck does not have: a waiver, metal fill, a
`report` line, a stage, or an LVS control.

1. Copy the deck file from the repository's `pdks/` directory:

   ```sh
   cp GPurify/pdks/sky130.deck my.deck
   ```

2. Run with the copy to confirm it gives the same report as the shipped name:

   ```sh
   gpurify drc diffpair.gds --deck my.deck
   ```

   ```text
   ...
   summary:
     drc: ran
     erc: not selected
     lvs: not selected
     pex: not selected
     0 rules skipped
     265 rules clean
     0 violations: 0 errors, 0 warnings
   ```

3. Add your lines at the end of `my.deck`. [Waive a violation](waive.md) and
   [Add metal fill](add-metal-fill.md) show two common additions.

## Write a small deck of your own

Use this to check a few rules quickly, or for a process GPurify does not ship.

1. Write the grid, the layers you check and the rules. This deck holds metal 1 to the SkyWater
   SKY130 width and spacing rules:

   ```text
   # Metal 1 width and spacing only, SkyWater SKY130 m1.1 and m1.2.
   grid 5nm
   layer met1 = gds(68, 20)
   ignore gds(65, 20)
   ignore gds(65, 44)
   ignore gds(66, 20)
   ignore gds(66, 44)
   ignore gds(67, 20)
   ignore gds(67, 44)
   ignore gds(68, 5)
   ignore gds(93, 44)
   ignore gds(94, 20)
   ignore gds(95, 20)
   rule m1.1 width(met1) >= 140nm
   rule m1.2 space(met1) >= 140nm
   ```

2. Declare or ignore every GDS layer the layout draws. GPurify refuses a layout that draws on a
   layer the deck neither declares nor ignores, so a layer is never left out of the check by
   accident. The `ignore` lines above cover the other layers of the tutorial's differential pair.
3. Run it:

   ```sh
   gpurify drc diffpair.gds --deck met1.deck
   ```

   ```text
   rules:
     m1.1: ran, examined 6 shapes, found 0 violations
     m1.2: ran, examined 0 shapes, found 0 violations
   violations: 0
   summary:
     drc: ran
     erc: not selected
     lvs: not selected
     pex: not selected
     0 rules skipped
     2 rules clean
     0 violations: 0 errors, 0 warnings
   ```

   `m1.2` examined no pair of shapes, because no two `met1` shapes are within 140 nm of each
   other.

4. If GPurify refuses the deck, it lists every problem with its line and column. Fix them all and
   run again.

## Related

- [Shipped decks](../reference/shipped-decks.md)
- [Deck language](../reference/deck/README.md)
- [Command line](../reference/cli.md)
