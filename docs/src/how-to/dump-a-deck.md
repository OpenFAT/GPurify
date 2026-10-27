# Dump a deck as JSON

`gpurify deck` compiles a deck without a layout and writes what it read as one JSON document: its layers, its rules with their limits, its connectivity, devices, LVS and PEX settings, and the per-layer values a layout generator asks for, such as a layer's minimum width and spacing. Read this file instead of parsing the deck language yourself.

## Before you start

- You have a deck file, or you use a shipped deck by name: `sky130`, `gf180mcu`, `ihp_sg13g2` or `asap7`.
- The deck compiles. `gpurify deck` refuses a deck with the same message `gpurify drc` gives for it.
- Every length in the deck is a whole number of nanometres. The dump reads the deck as it would for a layout drawn on a 1 nm grid, so a limit such as `140.5nm` is refused as off the grid.

## Steps

1. Write the deck, or pick a shipped one. This guide uses a three-rule deck, `met1.deck`:

   ```text
   grid 5nm
   layer met1 = gds(68, 20)
   layer via = gds(68, 44)
   layer met2 = gds(69, 20)
   rule m1.1 width(met1) >= 140nm
   rule m1.2 space(met1) >= 140nm
   rule via.4a enclosure(via, met1) >= 55nm
   ```

2. Dump it. `--format json` is the only format, and the default, so you can leave it out.

   ```sh
   gpurify deck met1.deck --format json > met1.json
   ```

   The command writes nothing to standard output unless the whole dump succeeded, and exits 0. On a refused deck it exits 1 with the error on standard error.

3. Read the top of the document. Its first keys are the format version, the deck as you named it, and the grid, then one line per layer and per rule:

   ```json
   {"format":"gpurify-deck/1","deck":"met1.deck","grid_nm":5,
   "layers":[
   {"id":0,"name":"met1","gds":[68,20]},
   {"id":1,"name":"met2","gds":[69,20]},
   {"id":2,"name":"via","gds":[68,44]}
   ],
   "rules":[
   {"id":"m1.1","kind":"min_width","keyword":"width","domain":"drc","severity":"error","layers":[0],"params":[{"name":"limit","value":140,"unit":"nm"}]},
   {"id":"m1.2","kind":"min_spacing","keyword":"space","domain":"drc","severity":"error","layers":[0],"params":[{"name":"limit","value":140,"unit":"nm"}]},
   {"id":"via.4a","kind":"min_enclosure","keyword":"enclosure","domain":"drc","severity":"error","layers":[0,2],"params":[{"name":"limit","value":55,"unit":"nm"}]}
   ],
   ```

   A layer `id` is its index in `layers`, and every other key names layers by that id. Drawn layers come first, sorted by name, then derived layers in the order the deck declares them. A rule's `layers` are in the order the check takes them, which for an enclosure is outer first: `[0,2]` is `met1` around `via`, though the deck writes `enclosure(via, met1)`.

4. Read the answers for the layer you generate. `answers.layers` has one entry per layer id, with the deck's values already worked out:

   ```json
   {"layer":0,"min_width_nm":140,"min_area_nm2":null,"min_enclosed_area_nm2":null,"min_step_nm":null,"max_aspect_ratio":null,"max_total_area_nm2":null,"allowed_widths_nm":null,"allowed_widths_from_nm":null,"cut_classes_nm":null,"spacing_nm":{"min_width":140,"strictest":140},"cut_spacing_nm":null,"cut_spacing_center_nm":null,"max_via_stack":null,"via_array_spacing":[],"cut_class_spacing":null,"density":[],"antenna":[],"em":[]},
   ```

   `spacing_nm` gives two values: the spacing between two wires of minimum width, and the strictest spacing any rule on the layer asks for, such as a wide-metal rule. `null` means the deck states no such rule, never zero. `answers.enclosures` holds one entry per pair of layers an enclosure rule names.

5. Query a shipped deck the same way. With `jq`, this prints the SKY130 `met1` answers that a router needs:

   ```sh
   gpurify deck sky130 > sky130.json
   jq -c '(.layers[] | select(.name == "met1") | .id) as $m | .answers.layers[$m] | {min_width_nm, spacing_nm, min_area_nm2}' sky130.json
   ```

   ```json
   {"min_width_nm":140,"spacing_nm":{"min_width":140,"strictest":280},"min_area_nm2":83000}
   ```

   SKY130 asks for 0.14 µm between minimum-width `met1` wires and 0.28 µm near wide `met1`. The minimum area is 0.083 µm².

6. Pin the format in your reader. Check that `format` is `gpurify-deck/1` before you read anything else. A key changes meaning only in a new format version.

## Units

Lengths are whole nanometres (keys ending `_nm`) and areas whole square nanometres (`_nm2`). Any other number is in the unit its key names, or, in a rule's `params`, in its `unit` field. A fraction is written from 0 to 1, with a percent already divided by 100. The bytes depend only on the deck text, so the same deck always dumps the same file.

## What GPurify does not cover

- The dump leaves out the deck's stages, waivers, boundary layer, ignored GDS layers, layout edits (`fill`, `enhance`) and `report` lines.
- Only `json` is written. `--format text` is refused.

## Related

- [Deck language](../reference/deck/README.md)
- [Shipped decks](../reference/shipped-decks.md)
- [Command line](../reference/cli.md)
