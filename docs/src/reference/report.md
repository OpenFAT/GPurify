# Report format

The text report (`--format text`, the default) and the JSON report (`--format json`), section by
section and field by field. The SPEF, DSPF and SPICE outputs of `--format spef`, `dspf` and
`spice` are standard formats, described with PEX.

Both reports are deterministic: the same inputs give the same bytes, whatever the thread count or
backend.

## Text report

A text report has up to seven sections, always in this order. Sections marked "when present"
appear only when they have something to say.

| Section | Starts with | When |
|---|---|---|
| Rules | `rules:` | Always. |
| Violations | `violations: <n>` | Always. |
| Waived | `waived: <n>` | When present. |
| LVS unpaired instances | `lvs unpaired instances:` | When present. |
| LVS merges | `lvs merges:` | When present. |
| LVS verdict | `lvs: ` | When LVS compared the layout with a reference. |
| Summary | `summary:` | Always. |

After the summary come the lines the deck's `report` statements ask for.

This report checks the tutorial's differential pair before its fix:

```text
rules:
  dnwell.2: ran, examined 0 shapes, found 0 violations
...
  licon.15: ran, examined 2 shapes, found 2 violations
...
violations: 4
  licon.15 error layer poly_licon at (1250 nm, 2950 nm) measured 0 nm against limit 100 nm on shape 84
  licon.15 error layer poly_licon at (2750 nm, 2950 nm) measured 0 nm against limit 100 nm on shape 85
  licon.18 error layer poly_licon at (1250 nm, 2950 nm) measured 28900 nm^2 against limit 0 nm^2 on shape 84
  licon.18 error layer poly_licon at (2750 nm, 2950 nm) measured 28900 nm^2 against limit 0 nm^2 on shape 85
summary:
  drc: ran
  erc: not selected
  lvs: not selected
  pex: not selected
  0 rules skipped
  263 rules clean
  4 violations: 4 errors, 0 warnings
```

### Rules

One line per rule the run selected, in the order the rule ids first appear in the deck:

```text
  <rule>: <outcome>, examined <n> shapes, found <m> violations
```

| Field | Meaning |
|---|---|
| `<rule>` | The rule id from the deck. |
| `<outcome>` | `ran`, `refused`, or `skipped, <reason>`. |
| `examined <n>` | How many items the rule looked at: shapes for a width or area rule, pairs of shapes within reach for a spacing rule, edges or density windows for others. 0 means the rule found nothing of its kind in the layout. |
| `found <m>` | How many violations it reported, waived ones not included. |

The reasons a rule is skipped:

| Reason | Meaning |
|---|---|
| `no design intent was supplied` | The rule needs `--intent`. |
| `the deck does not configure this rule` | The rule needs a deck statement that is missing. |
| `the layer it names holds no geometry` | The rule measures something that does not exist on an empty layer, such as a density window. |
| `an earlier stage of the deck found errors; fix those first` | The deck is staged, and an earlier stage failed. |

A rule is `refused` when the layout holds something the check cannot measure exactly, such as a
45° edge on a check that measures only horizontal and vertical edges. A run with no rules at all
prints `none recorded — nothing was checked` under `rules:`.

### Violations

The count, then one line per violation, sorted by rule (in the order above), then by layer, then
by y and x:

```text
  <rule> <severity> layer <layer> at (<x> nm, <y> nm) measured <value> against limit <value> on shape <a>
```

| Field | Meaning |
|---|---|
| `<rule>` | The rule id. |
| `<severity>` | `error`, or `warning` for a rule the deck marks `warning`. |
| `layer <layer>` | The deck layer the rule measured, by its name in the deck. A row with no layer, such as an LVS discrepancy, leaves this field out. |
| `at (<x> nm, <y> nm)` | A point on the offending shape, in nanometres from the layout's origin. Where the rule measures a gap, the point is midway across it. |
| `measured <value>` | What the rule measured, with its unit. |
| `against limit <value>` | The limit from the deck, in the same unit. |
| `on shape <a>` | A number that identifies the shape within this run. The same number in two rows is the same shape. A row with no shape leaves this field out. |
| `and shape <b>` | The second shape, for a rule that measures between two. |
| `loaded most by <instance> <terminal>` | With `--currents`: the simulated device terminal whose current loads the place most. |
| `fix <value>` | A hint, for the rules that give one: for an antenna violation, the protection diode area that would fix it. |

Values carry these units:

| Unit | Quantity |
|---|---|
| `nm` | Length. |
| `nm^2` | Area. |
| `mV` | Voltage. |
| `uA` | Current. |
| `ohm` | Resistance. |
| None | A count or a ratio. |

### Waived

`waived: <n>`, then the waived violations in the same form as above. A waived violation does not
count towards `found`, the summary or the exit code. [Waive a violation](../how-to/waive.md)
shows one.

### LVS sections

`lvs unpaired instances:` lists each placement of the reference netlist none of whose devices has
a partner in the layout:

```text
  <path> (<cell>): none of its <n> devices has a partner in the layout
```

`lvs merges:` lists each group of devices LVS reduced to one before comparing, layout first, so
that a paired device traces back to what was drawn or written:

```text
lvs merges:
  reference parallel: 2 devices of sky130_fd_pr__nfet_01v8 (0, 1) are one
```

The fields are the side, the kind of merge (`parallel` or `series`), the count, the model and the
device numbers on that side, counted from 0.

`lvs: ` gives the verdict: `Match`; `Mismatch([...])` with every discrepancy; or
`Inconclusive(<reason>)` when the comparison could not decide. Each discrepancy of a mismatch is
also a violation row, under the rule named for its kind. [LVS checks](lvs/README.md) lists the
kinds.

### Summary

```text
summary:
  drc: <status>
  erc: <status>
  lvs: <status>
  pex: <status>
  <n> rules skipped
  <n> rules clean
  <n> violations: <e> errors, <w> warnings
```

| Field | Meaning |
|---|---|
| `<status>` | `ran`; `not selected`; `skipped, <reason>` when the check's input is missing; `refused, <reason>` when its input is outside what it decides exactly. |
| `rules skipped` | Rules that did not run, skipped and refused together. |
| `rules clean` | Rules that ran and found no violation. |
| `violations` | Every violation not waived, split into errors and warnings. |

The run passes, and exits 0, only when no selected check is skipped or refused, `rules skipped`
is 0, and `errors` is 0.

### Report lines

A deck's `report` statements add lines after the summary. None of them passes or fails anything,
and none appears in the JSON report.

| Statement | Line |
|---|---|
| `report cluster <len>` | `cluster <rule> <n> violations within (<x>, <y>)-(<x>, <y>) um`, one per cluster of one rule's violations, largest first. |
| `report p2p "<net>" at [...]` | `p2p <net> (<x>, <y>) um to (<x>, <y>) um: <r> ohm`, one per pair of points, after a PEX run. |
| `report coupling "<a>" "<b>"` | `coupling <a> <b>: <c> fF`, after a PEX run. |

## JSON report

One JSON object on one line, with these keys in this order. Here is the same run as above,
indented for reading and cut to one violation and one rule:

```json
{
  "header": {
    "tool_version": "0.1.0",
    "deck_path": "sky130",
    "layout_path": "diffpair_bad.gds",
    "timestamp": null
  },
  "violations": [
    {
      "rule": "licon.15",
      "layer": "poly_licon",
      "severity": "error",
      "at": { "unit": "nm", "x": 1250.000000, "y": 2950.000000 },
      "measured": { "kind": "length", "unit": "nm", "value": 0.000000 },
      "limit": { "kind": "length", "unit": "nm", "value": 100.000000 },
      "shapes": [84, null]
    }
  ],
  "runs": [
    { "rule": "licon.15", "outcome": "ran", "examined": 2, "violations": 2 }
  ]
}
```

| Key | Content |
|---|---|
| `header` | `tool_version`; `deck_path` and `layout_path` as given on the command line; `timestamp`, always `null` so that the bytes depend only on the inputs. |
| `violations` | One object per violation, in the text report's order. |
| `waived` | The waived violations, in the same form. Present only when there are any. |
| `runs` | One object per rule, in the text report's order. |

A violation object:

| Key | Content |
|---|---|
| `rule` | The rule id. |
| `layer` | The deck layer's name. |
| `severity` | `"error"` or `"warning"`. |
| `at` | `{"unit": "nm", "x": ..., "y": ...}`, the point, as in the text report. |
| `measured`, `limit` | `{"kind": ..., "unit": ..., "value": ...}`. `kind` is `length`, `area`, `count`, `ratio`, `voltage`, `current` or `resistance`; `unit` is `nm`, `nm^2`, `mV`, `uA`, `ohm`, or `""` for a count or ratio. |
| `shapes` | `[a, b]`, the two shape numbers; `b` is `null` for a rule that measures one shape. |
| `fix` | The fix hint, in the form of `measured`. Present only when the rule gives one. |
| `load` | `{"instance": ..., "terminal": ...}`, the terminal that loads the place most. Present only with `--currents`. |

A run object has `rule`, `outcome`, `examined` and `violations`. `outcome` is `"ran"`,
`"refused"`, or `"skipped:<reason>"`, where the reason is `no_design_intent`, `not_in_deck`,
`empty_layer` or `earlier_stage`.

Numbers with a fraction have six decimals. A value JSON cannot hold (not a number, or infinite) is
refused before anything is written.

> [!WARNING]
> The JSON report has no summary. It does not say that a whole check was skipped or refused, as LVS
> is under `all` without a reference. Read the exit code for the verdict.
