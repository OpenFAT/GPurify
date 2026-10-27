# Waive a violation

A waiver excuses one rule's violations at the places you mark. When you finish, the waived violation is listed apart under `waived`, and it no longer fails the run.

## Before you start

- You have a layout and a deck that reports the violation, and you have agreed the exception with whoever signs off the design.
- You have your own copy of the deck. The shipped decks carry no waivers, so copy the deck file from the repository (`pdks/sky130.deck` for `--deck sky130`) and edit the copy. A copy of `pdks/sky130.deck` with no lines added gives the same report as `--deck sky130`.
- You know the rule id and the point of the violation, from the report line.

## Steps

1. Run the check and note the rule id and the point of the violation you want to waive.

   ```sh
   gpurify drc diffpair_bad.gds --deck sky130.deck
   ```

   ```text
   rules:
   ...
     licon.15: ran, examined 2 shapes, found 2 violations
   ...
   violations: 4
     licon.15 error layer poly_licon at (1250 nm, 2950 nm) measured 0 nm against limit 100 nm on shape 84
     licon.15 error layer poly_licon at (2750 nm, 2950 nm) measured 0 nm against limit 100 nm on shape 85
   ...
   ```

   This guide waives the first `licon.15` violation, at (1250 nm, 2950 nm).

2. Choose a GDS layer and datatype that nothing else in the layout uses, and declare it in your deck as a waiver layer for the rule. Add these lines at the end of the deck:

   ```text
   layer waive_licon15 = gds(255, 1)
   waive licon.15 waive_licon15
   ```

   The rule id must be one of the deck's rules. A misspelled id refuses the deck rather than waiving nothing:

   ```text
   error: deck bad.deck: Malformed
     waive licon.51: no rule of the deck has that id
   ```

3. Draw a shape on the waiver layer over the violation's point. The point counts as covered when it lies inside the shape or on its boundary. This script adds a 200 nm square centred on (1.25 µm, 2.95 µm):

   ```python
   import gdstk

   lib = gdstk.read_gds("diffpair_bad.gds")
   top = lib.top_level()[0]
   # A waiver shape over the licon.15 marker at (1.25 um, 2.95 um).
   top.add(gdstk.rectangle((1.15, 2.85), (1.35, 3.05), layer=255, datatype=1))
   lib.write_gds("diffpair_waived.gds")
   ```

   A waiver drawn inside a cell waives at every placement of that cell, however the placement is rotated or mirrored.

4. Run the check again on the layout with the waiver shape.

   ```sh
   gpurify drc diffpair_waived.gds --deck sky130.deck
   ```

   ```text
   rules:
   ...
     licon.15: ran, examined 2 shapes, found 1 violations
   ...
   violations: 3
     licon.15 error layer poly_licon at (2750 nm, 2950 nm) measured 0 nm against limit 100 nm on shape 86
     licon.18 error layer poly_licon at (1250 nm, 2950 nm) measured 28900 nm^2 against limit 0 nm^2 on shape 85
     licon.18 error layer poly_licon at (2750 nm, 2950 nm) measured 28900 nm^2 against limit 0 nm^2 on shape 86
   waived: 1
     licon.15 error layer poly_licon at (1250 nm, 2950 nm) measured 0 nm against limit 100 nm on shape 85
   summary:
     drc: ran
   ...
     3 violations: 3 errors, 0 warnings
   ```

   The `licon.15` violation at (1250 nm, 2950 nm) moved under `waived`, and the rule's count dropped from 2 to 1. The waiver covers only `licon.15`: the `licon.18` violation at the same point is still an error, and so is the second `licon.15` violation, so this run still exits 1.

5. To waive the same place for another rule, add a `waive` line for that rule. A rule takes several waiver layers, one `waive` line each, and one waiver layer serves several rules.

   ```text
   waive licon.18 waive_licon15
   ```

   With that line added, both violations at (1250 nm, 2950 nm) are waived:

   ```text
   waived: 2
     licon.15 error layer poly_licon at (1250 nm, 2950 nm) measured 0 nm against limit 100 nm on shape 85
     licon.18 error layer poly_licon at (1250 nm, 2950 nm) measured 28900 nm^2 against limit 0 nm^2 on shape 85
   ```

In the JSON report, waived violations are under the `waived` key, in the same form as `violations`.

## What GPurify does not cover

A waiver matches by rule id and position only. It does not record who approved it or why, and it does not expire. Keep that record beside the deck.

## Related

- [Deck language](../reference/deck/README.md)
- [Report format](../reference/report.md)
- [How a run passes](../explanation/outcomes.md)
- [Choose a deck](choose-a-deck.md)
