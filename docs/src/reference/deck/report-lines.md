# Report lines

`report` lines add measurements to the text report, after the summary. None is a check: each
prints a number and passes or fails nothing, and none reaches the JSON, SPEF or DSPF output.

```text
report p2p "<net>" at [(<x>, <y>), (<x>, <y>), ...]
report coupling "<net>" "<net>"
report cluster <len>
```

## Point-to-point resistance

`report p2p "<net>" at [...]` prints, after a PEX run (`gpurify pex` or `gpurify all`), the
effective resistance of the net between every two of the points. Give two points or more, each an
`(x, y)` pair of lengths on the deck's grid that lies on a conducting shape of the net. Repeat the
line for more nets.

## Coupling between two nets

`report coupling "<net>" "<net>"` prints, after a PEX run, the total coupling capacitance between
the two nets in the extracted network. Repeat the line for more pairs.

A net is named as its labels name it. A net the layout lacks, or a name whose labels sit on two
pieces, is an error when the measurement is made.

## Violation clusters

`report cluster <len>`, at most once, lists after any check's violations one line per cluster: the
violations of one rule whose reported points lie within that distance of each other, chained,
largest cluster first, with their count and bounding box. The distance is zero or more.

## Example

The [tutorial deck](../../tutorials/first-deck.md) with the stack of
[Parasitic extraction](extraction.md#the-stack), `extraction rcc coupling_halo 10`, and:

```text
report p2p "A" at [(100nm, 100nm), (1900nm, 800nm)]
report coupling "A" "B"
report cluster 2um
```

```sh
gpurify pex two_metal.gds --deck lines.deck
```

```text
...
p2p A (0.1, 0.1) um to (1.9, 0.8) um: 5.959375 ohm
coupling A B: 0.086073 fF
```

From the start of met1 wire A to the top of the met2 strap, net A measures 5.96 Ω: about 1.11 Ω
of met1, the 4.5 Ω via cut and 0.35 Ω of met2. The two nets couple by 0.086 fF.

```sh
gpurify drc two_metal.gds --deck lines.deck
```

```text
...
cluster M1.W 1 violations within (1, 0.55)-(1, 0.55) um
cluster V1.EN 1 violations within (1.875, 0.012)-(1.875, 0.012) um
```

Each rule's one violation is a cluster of its own.
