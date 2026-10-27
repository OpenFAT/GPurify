# Add redundant vias and widen straps

`gpurify enhance` writes a copy of your layout with a second cut beside single-cut vias and with named power straps widened, then checks the copy. When you finish, you have the enhanced GDS file and a DRC report on it that has no finding the input lacked.

## Before you start

- Your layout is a GDS file. `enhance` does not edit a DEF layout.
- You have your own copy of the deck. The shipped decks carry no `via_redundancy` rule and no `widen` line, so copy the deck file from the repository (`pdks/sky130.deck` for `--deck sky130`) and add them. A copy of `pdks/sky130.deck` with no lines added gives the same report as `--deck sky130`.
- The straps you want widened carry a text label with their net name, on a label layer the deck connects to the metal.

## Steps

1. Add a `via_redundancy` rule for each cut layer to double. It names the cut, the metal below and the metal above, the `pitch` from a cut to its second cut, and the `space` a new cut keeps from every other cut.

   ```text
   rule via.redundant warning via_redundancy(via, met1, met2; pitch: 320nm, space: 170nm) >= 1
   ```

   Here the pitch is sky130's 150 nm `via` cut (via.1a) plus the 170 nm space between cuts (via.2). The rule reports the layout's redundant-via rate, the share of vias that are not dead. A dead via is a single-cut via with no room beside it for a second cut. The limit 1 asks for no dead via, and `warning` keeps the rule from failing the run.

2. Add a `widen` line for each strap layer and net. The net is a pattern: `*` matches any run of characters and `?` one character.

   ```text
   widen met1 net "VPWR" by 300nm
   ```

   Each rectangle on `met1` whose net carries a label matching `VPWR` gains a 300 nm strip along each of its two long sides.

3. Check the layout before you enhance it.

   ```sh
   gpurify drc vias.gds --deck enhance.deck
   ```

   ```text
   rules:
   ...
     via.redundant: ran, examined 2 shapes, found 1 violations
   ...
   violations: 1
     via.redundant warning layer via at (6160 nm, 1160 nm) measured 0.5 against limit 1
   ...
   ```

   Of the two vias in this layout, one is dead, so the rate is 0.5 against a limit of 1. The point is the first dead via. The layout's other via has room beside it.

4. Run `enhance` with the layout to read and the file to write.

   ```sh
   gpurify enhance vias.gds vias_enhanced.gds --deck enhance.deck
   ```

   On standard error, `enhance` says what it added:

   ```text
   wrote vias_enhanced.gds: 2 redundant cuts, 2 strap sides widened
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
     266 rules clean
     0 violations: 0 errors, 0 warnings
   ```

   Both vias now have two cuts. The via with room got its second cut 320 nm to the right of the first. The dead via got its second cut too: `enhance` extended the `met1` under it by a patch round both cuts, keeping the 85 nm margin `met1` already left round the first cut. The `met2` there already held the new cut, so it was not extended. Both long sides of the `VPWR` strap grew by 300 nm.

5. Read the exit code. It is the DRC run's, so exit 0 means the enhanced layout passes the deck. The input file is not changed, and the output keeps every record of the input with the new shapes added to its top cell.

## What enhance never does

- It never tries a cut, a patch or a strap strip that would touch a shape of another net, on the same layer or through a cut that joins it.
- It takes back any addition that creates a DRC finding the input did not have. The output therefore has no finding the input lacked, and its redundant-via rate does not fall.
- With no `via_redundancy` rule and no `widen` line in the deck, it adds nothing.

## Related

- [Deck language](../reference/deck/README.md)
- [Command line](../reference/cli.md)
- [Run features](../reference/run-features.md)
- [Add metal fill](add-metal-fill.md)
