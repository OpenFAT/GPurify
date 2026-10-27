# Add metal fill

`gpurify fill` draws dummy metal squares into a copy of your layout until every density window reaches its minimum, then checks the copy. When you finish, you have a filled GDS file and a DRC report on it.

## Before you start

- Your layout is a GDS file. `fill` does not edit a DEF layout.
- You have your own copy of the deck. The shipped decks carry no `fill` lines and no minimum-density rule for fill to meet, so copy the deck file from the repository (`pdks/sky130.deck` for `--deck sky130`) and add them. A copy of `pdks/sky130.deck` with no lines added gives the same report as `--deck sky130`.
- You know the foundry's density window, step and limits for the layer, and the GDS layer and datatype its fill goes on. The numbers below are for illustration, not SkyWater's.
- The layer you fill is rectilinear: `fill` refuses a layer with a diagonal edge.

## Steps

1. Declare the fill layer and a layer that holds the metal and its fill together, and write the density rules on that combined layer. Add these lines to your deck:

   ```text
   layer met1_fill = gds(68, 28)
   layer met1_all = met1 or met1_fill
   rule m1.fill.min density(met1_all; window: 50um, step: 25um) >= 0.2
   rule m1.fill.max density(met1_all; window: 50um, step: 25um) <= 0.7
   rule m1.fill.space space(met1_fill, met1) >= 1um
   ```

   The windows tile the die, here the `prBoundary` shape the sky130 deck names as its boundary. A window that hangs past the die's edge counts the outside as empty, so choose a die size the window and step tile, or that window stays under its minimum whatever fill adds.

2. Add a `fill` line: the layer to draw on, the density layer it serves, the square size, the space between squares, the distance to keep from other shapes, and the layers to keep away from.

   ```text
   fill met1_fill for met1_all size 1um space 1um keep 1um avoid [met1]
   ```

   Squares sit on a grid `size + space` apart from the lower-left corner of the die, wholly inside it. Each square keeps `keep` from every shape on the `avoid` layers, corners included, and `space` from other fill, and never overlaps the density layer.

   Every value is required. `size` and `space` are positive, and `keep` is zero or more. A `fill` line for a density layer that no `density` or `global_density` rule measures is refused when `fill` runs, because nothing says how much to draw:

   ```text
   error: fill met1_fill: layer met1_all: NoDensityRule
   ```

3. Check the layout before filling to see which windows are short.

   ```sh
   gpurify drc routing.gds --deck fill.deck
   ```

   ```text
   rules:
   ...
     m1.fill.min: ran, examined 9 shapes, found 9 violations
   ...
   violations: 9
     m1.fill.min error layer met1_all at (25000 nm, 25000 nm) measured 0.036 against limit 0.2 on shape 10
     m1.fill.min error layer met1_all at (50000 nm, 25000 nm) measured 0.04 against limit 0.2 on shape 10
   ...
   ```

   Nine 0.5 µm met1 wires on a 100 µm die cover 3.6% of the lower-left window, against a minimum of 20%.

4. Run `fill` with the layout to read and the file to write.

   ```sh
   gpurify fill routing.gds routing_filled.gds --deck fill.deck
   ```

   On standard error, `fill` says what it drew:

   ```text
   wrote routing_filled.gds: 1842 fill squares
   ```

   On standard output is the DRC report on the file it wrote:

   ```text
   rules:
   violations: 0
   summary:
     drc: ran
     erc: not selected
     lvs: not selected
     pex: not selected
     0 rules skipped
     268 rules clean
     0 violations: 0 errors, 0 warnings
   ```

   The exit code is the DRC run's, so exit 0 means the filled layout passes the deck. The input file is not changed. The output keeps every record of the input and adds the fill squares to its top cell.

5. If a window still reports below its minimum, it had no room left. Lower `keep` or `space`, or draw the fill yourself in that area. Fill never draws a square that would push a window past a maximum.

## What GPurify does not cover

- `fill` reads `density` and `global_density` rules only. It does not balance two masks, and it ignores cover-density and CMP density rules.
- Two `fill` lines for one density layer each fill as if the other drew nothing.
- A deck with no `fill` line writes the layout unchanged and reports `0 fill squares`.

## Related

- [Deck language](../reference/deck/README.md)
- [Command line](../reference/cli.md)
- [Run features](../reference/run-features.md)
- [Choose a deck](choose-a-deck.md)
