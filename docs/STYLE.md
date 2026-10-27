# GPurify user docs: style guide

The rules every page of the user docs follows (`docs/src`, built with mdBook). One voice across every writer. When a rule here and your taste disagree, follow the rule.

## 1. Readers and what to leave out

You write for layout and analog designers, PDK and deck authors, and CAD engineers. They know
physical verification, not GPurify's code. Each page answers what a check catches, why it matters,
how to turn it on in a deck, what a violation looks like, and what GPurify doesn't cover yet.

**Never write about internals.** That means source paths, Zig or Rust names, internal function or
kind names that aren't deck syntax, test names, build flags, and catalog bookkeeping (oracle codes
such as `TX:KL`, finding ids such as `F50`).

No: "`attached_wide_spacing` in `src/check/spacing.zig` grows the wide part by a square." Yes:
"GPurify grows the wide part of the shape by the `attached` distance, square at the corners."

**Describe algorithms only to predict a result.** One sentence that tells the reader what gets
measured is enough. Yes: "Spacing is measured edge to edge, Euclidean at corners."

**Describe the correct behaviour.** Sometimes the tool does something wrong: a wrong number, a
missed violation, a misleading message. When that happens, the page still says what GPurify
*should* do. Don't document the bug as behaviour, and don't change code. Write a finding for the
maintainers instead: the deck, the layout, the command, what it printed, what it should print and
why (cite the foundry rule or standard), and the code change you believe fixes it. The maintainers
fix the code, file an issue if the fix waits, and link it under **Status and limits**. A known gap
is different from a bug: if the catalog marks a check `partial` and names what it lacks, that gap
is a limit, and you document it as one.

## 2. Page types (Diátaxis)

Every page is one of four types, never a mix: a tutorial that lists every option should link to
the reference instead.

| Type | Serves | Title form | GPurify pages |
|---|---|---|---|
| Tutorial | Learning, start to finish | "Check your first layout" | First DRC and LVS run on a shipped sky130 cell; write your first deck |
| How-to guide | One task for a competent user | Verb first: "Waive a violation" | Run LVS against a SPICE netlist, give ERC its design intent, extract parasitics to SPEF, stage a deck, add metal fill, compare two layouts |
| Reference | Lookup, describe and only describe | Noun: "Spacing checks" | Command line, deck language, report format, the check pages, shipped decks, limitations, glossary |
| Explanation | Understanding why | Noun phrase or question | How a run passes (ran, skipped, refused), how distances are measured, how LVS matches devices, how parasitics are modelled, why CPU and GPU agree |

``docs/src/SUMMARY.md` has one part per type. Its structure mirrors the product. Check pages go under
Reference, one page for each catalog category, with plain-word titles: `mpt` becomes
"Multi-patterning checks" and `em` becomes "Electromigration checks".

```text
[Introduction](README.md)
# Tutorials
- [Check your first layout](tutorials/first-layout.md)
# How-to guides
- [Waive a violation](how-to/waive.md)
# Reference
- [DRC checks](reference/drc/README.md)
  - [Spacing checks](reference/drc/spacing.md)
# Explanation
- [How a run passes](explanation/outcomes.md)
```

A how-to states its preconditions first, then lists numbered steps. A reference page holds no
steps. The flow rows (`FLOW-`) go on one reference page, "Run features".

## 3. The check entry template

Each of the catalog's 265 rows, every status included, gets exactly one entry, on its category
page, in catalog row order. A check page has an `#` title, a two-sentence intro, and
one or more `##` groups of related checks. The entries sit under those groups:

````markdown
### DRC-028: Influence spacing near wide metal

**What it catches.** A wire that runs too close to a wide metal plate, or to a stub that leaves the
plate. Wide metal etches differently, so the foundry asks for more space near it than between
narrow wires. A stub within the influence distance of the plate inherits the plate's spacing.

**How GPurify measures it.** GPurify finds the parts of each shape where a square of side `width`
fits. It grows those parts by `attached`, square at the corners, then measures spacing from the
result, edge to edge and Euclidean at corners.

**In the deck.**

```text
rule <id> wide_space(<layer>; width: <length>, attached: <length>) >= <length>
```

```text
grid 5nm
layer met1 = gds(68, 20)
rule m1.3a wide_space(met1; width: 3um, attached: 280nm) >= 280nm
```

**Example violation.**

```text
rules:
  m1.3a: ran, examined 1 shapes, found 1 violations
violations: 1
  m1.3a error layer 0 at (4100 nm, 2000 nm) measured 200 nm against limit 280 nm on shape 0 and shape 1
...
```

A wire 200 nm from a 4 µm plate breaks the 280 nm limit. The point is midway across the gap.

**Options.**

| Parameter | Value | Meaning |
|---|---|---|
| `width` | length | A part is wide where a square this size fits inside the shape. |
| `attached` | length | How far from the wide part a stub still counts as wide. |

**Status and limits.** Partial. The stub-width `RANGE` form and the two-stub
`SPACINGTABLE INFLUENCE` form are not checked. Near a wide corner, the square growth flags a little
more than the foundry rule does. That errs toward a false violation, never a missed one.

**Sources.** SkyWater SKY130 rule m1.3a; LEF 5.8 `SPACING RANGE INFLUENCE`.
````

Rules for the entry:

- **The heading must be exactly `### <ID>: <name>`.** A test looks for this form. Copy the id from
  the catalog exactly (`DRC-028`, `ERC-D1a`). Write the name in sentence case. Use no backticks, and
  no punctuation besides the colon and hyphens (the catalog's "Influence / stub spacing" becomes
  "Influence spacing"). Never add `{#id}` to the heading.
- **The labels are bold lead-ins, not headings**, and always come in this order. mdBook's search
  returns a whole entry under its check name. Seven sub-headings per check would bury the result.
- **What it catches** takes two to four sentences: the defect, then the yield or reliability reason.
- **In the deck** shows the syntax line with `<placeholders>`, then one complete example that loads
  on its own (`grid`, the layers, the rule). Run it before you publish. If the check is turned on by
  a flag or an intent file, keep the label and show that: "Nothing to write in the deck. Run with
  `--intent power.json`." For an `expressible` check, show the composition of general deck
  operations that does the job.
- **Example violation** is real output (section 5) and one sentence that reads it. LVS shows a
  mismatch line. PEX entries say **Example output.** and show a few SPEF or SPICE lines.
- **Status and limits** opens with the catalog status word: Implemented, Partial, Expressible or
  Missing. Then come the limits, with an issue link if one exists. "Implemented. No known limits."
  is a complete entry.
- **Sources** gives the foundry rule ids and the standards, with names in full: "SkyWater SKY130",
  not `SKY`; "ESDA TR18.0-01", not `TR18`. Link the public ones. "GPurify-specific." is allowed when
  no source exists.

**What you may leave out:** **Options**, when the syntax has no named parameters. **Example
violation**, when the check reports nothing on its own, as with flow features. **How GPurify
measures it**, only for a `missing` check. A `missing` entry keeps three parts: What it catches,
Status and limits, and Sources. Every other label is required.

## 4. Writing rules

1. **Use second person, present tense and active voice.** No: "The deck will be rejected by GPurify."
   Yes: "GPurify refuses the deck and names the line."
2. **Lead with the point, and put conditions before instructions.** Yes: "To waive one violation,
   draw a shape on the waiver layer over its marker."
3. **Keep sentences under about 25 words**, with one idea and at most four sentences per paragraph.
4. **Be exact, and say what happens.** Give the number, the unit and the rule id. Drop "can",
   "may", "simply" and "just". No: "GPurify may flag a small gap." Yes: "GPurify flags a gap under
   140 nm."
5. **Write headings in sentence case, unpunctuated, without skipping a level.** How-tos start with a verb.
6. **Use one term for one thing** (section 6), never "polygon", "shape" and "geometry" in turn.
7. **Write for a global audience.** Use British spelling, as the existing docs do (colour,
   modelled, labelled). Use the serial comma only when an item itself contains "and". No idioms,
   and no Latin abbreviations: write "for example", not "e.g.".
8. **Write descriptive link text** that names the target and still makes sense read alone.
   No: "see [here](...)". Yes: "see [Waivers](../reference/deck/waivers.md)".
9. **Make it accessible.** Every image gets alt text under 155 characters that says what the image
   shows, with no "image of". Never carry meaning by colour alone ("the red shape"), and give every
   table a header row.
10. **Don't promote.** No "fast", "powerful" or "seamless". A speed claim cites a measured number
    and the machine it was measured on, or it stays out.

## 5. Conventions

**Units.** In prose, put a space between the number and the SI symbol: 140 nm, 0.083 µm², 1.8 V,
25.8 aF/µm², 378 K. Percent and degrees take no space: 50%, 45°. In code, use the deck's spelling:
`140nm`, `0.083um2`. Repeat the unit in a range: "0.14 µm to 0.28 µm". Quote the foundry's number
in the foundry's unit, and don't convert it.

**Code blocks.** Always give the language. Deck snippets, netlists, SPEF and report output use
`text`. Shell commands use `sh` and have no `$` prompt. JSON uses `json`. Put a command and its
output in separate blocks. Use inline code for anything the reader types or the tool prints, such as
`space`, `--deck` and `ran`. Don't use it for emphasis.

**Report excerpts.** Paste the text output of a real run verbatim, and never hand-edit a number.
Keep the rule's status line and at least one violation line, and mark cut lines with `...` on a
line of its own. After the excerpt, write one sentence that names the place, the measured value and
the limit. Show JSON only where a page is about JSON. If the tool prints the wrong thing, write what
it should print, in the same format, and say so in the issue.

**Notes and warnings.** Use GitHub alert syntax: a plain Markdown blockquote that mdBook 0.5 and
GitHub both render as a callout. Use only `NOTE` and `WARNING`, at most one per entry, and never for
steps or for anything the reader must know. Use `WARNING` when a clean result can mislead.

```markdown
> [!WARNING]
> A rule reported `skipped` looked at nothing. Its zero violations prove nothing.
```

**Math.** Use math only when the reader must compute or predict a result, as with antenna ratios,
density windows or EM limits. mdBook needs `mathjax-support = true`, and it uses doubled
backslashes: `\\( A_\text{gate} \\)` inline, `\\[ ... \\]` for display. `$$` doesn't work. Define
each symbol in prose right after the formula, then work one example with numbers.

```markdown
The antenna ratio is \\[ R = \frac{A_\text{metal}}{A_\text{gate}} \\]
where \\( A_\text{metal} \\) is the metal area connected to the gate, and \\( A_\text{gate} \\) is the gate area.
```

**Links and anchors.** Link between pages with relative `.md` paths, which mdBook turns into
`.html`. An anchor is the heading in lowercase, with punctuation dropped and each space made a
hyphen: `#drc-028-influence-spacing-near-wide-metal`. A spaced slash leaves a double hyphen. Before
you rename a heading, search the book for links to its old anchor.

**Images and tables.** Diagrams follow section 7; repeat their facts in prose. In tables, write "None" rather
than leaving a cell empty, and put the description column last.

## 6. Terms

Use these words with these meanings, and no others.

| Term | Meaning (not to be called) |
|---|---|
| layout | The GDS (or DEF) file a run checks (not "design file" or "database") |
| deck | The text file of layers, rules, connectivity and devices (not "rule file" or "runset") |
| layer | A named layer in the deck, drawn (`gds(L, D)`) or derived (`and`, `not`) |
| shape | One closed region on a layer, after touching pieces merge (not "geometry") |
| polygon | One GDS boundary as drawn, before merging. Use it only when that difference matters. |
| edge | One side of a shape |
| net | A set of shapes joined through conductors and vias, named by a label or by GPurify |
| device | A transistor, resistor, capacitor or diode that the deck's `device` lines recognise |
| reference netlist | The schematic netlist LVS compares against (not "source" or "golden") |
| design intent | The supply voltages and per-net limits that ERC reads from `--intent` |
| check | A kind of test GPurify can run, such as a catalog row (`DRC-028`) |
| rule | One `rule` line in a deck: an id, a check and its limit. The id is reported. |
| violation | One place where a rule's limit is broken. It is an error, or a warning for a `warning` rule. |
| waiver | A shape on a waiver layer that excuses the violations under it |
| ran / skipped / refused | A rule's three outcomes. Only `ran` means the rule looked at the layout. |
| status | A check's coverage: Implemented, Partial, Expressible (written with general deck operations) or Missing |

## 7. Diagrams (CircuiTikZ)

**Every check entry on a DRC, LVS, ERC or PEX page has a diagram** that shows what the check
looks at and where it fails. Explanation pages use them wherever a picture says it faster. Draw
them in CircuiTikZ (TikZ plus circuit symbols), never as hand-made SVG or screenshots.

- **Source:** one standalone file per diagram, `docs/diagrams/<name>.tex`, named by the entry's
  catalog id in lower case (`drc-028.tex`; a second one `drc-028-b.tex`) or by page for explanation
  pages (`measuring-1.tex`). Start from this template; the shared `preamble.tex` loads CircuiTikZ
  and the house styles:

  ```latex
  \documentclass[border=0pt]{standalone}
  \input{preamble}
  \begin{document}
  \begin{circuitikz}
    % the drawing
  \end{circuitikz}
  \end{document}
  ```

- **House styles** (from `preamble.tex`; don't restyle by hand): `layer a`, `layer b` (grey
  fills), `layer c` (hatched), `layer d` (dotted) for layout shapes, labelled with their deck layer
  name; `marker` (dashed outline) for markers and derived regions; `dim` with `dim label` for a
  measured distance; `violation` with `violation label` for where the rule fails, always labelled
  so colour is not the only cue; `caption` for a short note. Units with `\SI{0.14}{\micro\metre}`.
- **What to draw:**
  - DRC: the layout from above, the shapes the rule reads, the distance or area it measures as a
    `dim`, and the failing case as a `violation`. Add the passing case beside it when the boundary
    is the point (inclusive or exclusive limit, corner against edge).
  - LVS: the reference circuit and the layout's extracted circuit side by side, as CircuiTikZ
    schematics, with the mismatching device, pin or net marked.
  - ERC: the circuit (devices, nets, supplies, pads) with the failing path or node marked; a
    cross-section for physical effects (antenna charging, latch-up's parasitic thyristor, a well).
  - PEX: the wire or via as drawn and the R, C or L network GPurify extracts from it, with the
    nodes named as the output names them.
- **Numbers match the entry's example:** the same layer names and dimensions as its deck and layout.
- **Embed** the rendered SVG under **How GPurify measures it**, with alt text that says what the
  diagram shows: `![Two met1 shapes 0.12 µm apart, against a 0.14 µm minimum space](../../diagrams/drc-028.svg)`.
  The path is relative from the page to `docs/src/diagrams/`.
- **Render and look at it:** `nix develop .#docs -c docs/diagrams/render.sh` writes every SVG to
  `docs/src/diagrams/` (generated, not committed; the docs workflow renders them before
  `mdbook build`). Convert one to PNG (`nix shell nixpkgs#librsvg -c rsvg-convert -z 2 x.svg -o x.png`)
  and look at it: no overlapping labels, nothing clipped, readable at page width.

## 8. Before you submit

1. Run every deck snippet and command on the page. The excerpts come from those runs.
2. Check that each catalog id in your category appears once, as `### <ID>: <name>`, and that a
   search of the page for `src/`, `.zig`, `.rs` and catalog codes comes back empty.
3. Read your page in `mdbook build` output. Every link resolves, every image has alt text, and no
   heading skips a level.
4. Every check entry has its diagram, rendered and looked at.

## 9. Sources

- Diátaxis: <https://diataxis.fr/>, <https://diataxis.fr/reference/>, <https://diataxis.fr/how-to-guides/>
- Google: <https://developers.google.com/style/highlights>, <https://developers.google.com/style/units-of-measure>,
  <https://developers.google.com/style/link-text>, <https://developers.google.com/style/notices>,
  <https://developers.google.com/style/images>
- Microsoft: <https://learn.microsoft.com/en-us/style-guide/top-10-tips-style-voice>; GitLab:
  <https://docs.gitlab.com/development/documentation/styleguide/>; Write the Docs:
  <https://www.writethedocs.org/guide/writing/style-guides/>
- Rule references (usage, description, metric options, figures; synopsis, options, limitations; rule
  id, description, value): <https://www.klayout.de/doc/about/drc_ref_layer.html>,
  <https://openroad.readthedocs.io/en/latest/main/src/drt/README.html>,
  <https://skywater-pdk.readthedocs.io/en/main/rules/periphery.html>,
  <https://gf180mcu-pdk.readthedocs.io/en/latest/physical_verification/design_manual/drm_07_09.html>
- Calibre's results view, which shows each rule id with its comment text:
  <http://class.ece.iastate.edu/ee330/labs/Calibre_guide.pdf>. The Calibre, IC Validator and Pegasus
  manuals are available to customers only, and this guide does not use them.
- mdBook: <https://rust-lang.github.io/mdBook/format/summary.html>,
  <https://rust-lang.github.io/mdBook/format/markdown.html>, <https://rust-lang.github.io/mdBook/format/mathjax.html>,
  <https://github.com/rust-lang/mdBook/blob/master/CHANGELOG.md> (admonitions since 0.5.0)
