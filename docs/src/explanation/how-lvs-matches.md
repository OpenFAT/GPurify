# How LVS matches devices

LVS answers one question: do the layout and the reference netlist describe the same circuit? This page explains how GPurify decides, so that you can read a mismatch and know where to look. The checks themselves are listed under [LVS checks](../reference/lvs/README.md).

## Two circuits as two graphs

GPurify turns each side into a graph. Every device is a node, every net is a node, and every device terminal is an edge between the two. Each edge carries the terminal's role: a transistor's gate, its channel (source or drain), and its bulk where the deck extracts one.

On the layout side, the devices are the markers the deck's `device` lines recognise, and the nets are the shapes the `connect` lines join. On the reference side, they are the cards and nodes of the netlist's top subcircuit, with every subcircuit call below it expanded in place.

![An inverter's schematic beside its graph: device nodes M1 and M2, net nodes A, Y, VDD and VSS, edges marked gate and channel](../diagrams/how-lvs-matches-1.svg)

Two graphs describe the same circuit when you can pair every node of one with a node of the other so that every edge has a partner of the same role. Net names play no part in that definition. A layout and a reference that differ only in what their nets are called match.

## Reduction comes first

A layout and its schematic often draw the same circuit in different ways. A wide transistor is drawn as four fingers and written as one card with `nf=4`, or as one card with `m=4`. A resistor is drawn as two segments in series and written as one. Comparing such graphs node by node would report differences that are not real.

So, before pairing anything, GPurify reduces both sides by the same rules:

- Devices of one model with every terminal on the same nets merge in parallel. Transistor widths add, and other values follow the deck's topology policy.
- Transistors stacked through a net that nothing else touches, with one gate net, merge in series. Their lengths add.
- A card's `m` multiplies a transistor's width, or counts devices in parallel.

The report lists every merge under `lvs merges:`, so a paired device traces back to what was drawn. [Netlist reduction](../reference/lvs/reduction.md) gives every rule and its conditions.

## Pairing by refinement

GPurify pairs the two reduced graphs by partition refinement, the method of the Gemini LVS program (Ebeling, ICCAD 1988):

1. Every node starts in a class with the nodes that look alike from outside: devices by kind and model, nets all together, except nets the deck holds to a name (`lvs ports_by_name`, `lvs same_nets`).
2. In each pass, a node's signature is the classes of its neighbours, each with the role of the edge that reaches it. A class whose members' signatures differ splits.
3. Passes repeat until nothing splits. Each class then holding one node of each side is a pair.

Some circuits are symmetric: the two halves of a differential pair look alike from every node. Refinement stops with classes of two or more nodes per side, and no structure tells them apart. GPurify then pairs one node by trial and refines again. It keeps the trial when no class comes up short and every device pair it formed agrees on its parameters; otherwise it undoes the trial and tries the next candidate, up to eight. Candidates rank by closeness: for a device, its parameters; for a net, how well the diffusions of the transistors at its channel ends agree. Between equally close candidates, the reference net that the layout net's label names comes first.

That is the only place names matter. A layout label decides which of two interchangeable nets is which; it never forces a pairing that the wiring contradicts. The sky130 differential pair below shows the consequence. Its reference wires `M2`'s source to `outp` where the layout has `tail`:

```text
.subckt diffpair inp inn outp outn tail vss
XM1 outp inp tail vss sky130_fd_pr__nfet_01v8 W=2 L=0.5
XM2 outn inn outp vss sky130_fd_pr__nfet_01v8 W=2 L=0.5
.ends diffpair
```

```sh
gpurify lvs diffpair.gds --deck sky130 --reference dp_swap.spice
```

```text
violations: 0
lvs: Match
```

Both circuits are two transistors that share one channel net, each with its own gate and its own other channel net. Rename the reference's `outp` as `tail` and its `tail` as `outp` and the two are identical, so they match. The labels `tail` and `outp` are only tie-breakers.

![Reference with M2's source on outp beside the layout with both sources on tail: the same graph with two nets renamed, paired as a match](../diagrams/how-lvs-matches-2.svg)

To make names count, add `lvs ports_by_name` to the deck. Each port of the reference's top subcircuit then pairs only with the layout net its label names. In the run above, `outp` and `tail` no longer fit, and the run reports a mismatch. Inside a cell whose inner nets carry no label, structure decides alone; that is what lets a schematic and a layout name their internal nets differently.

## What is compared exactly and what within a tolerance

Once two devices are paired, GPurify compares them.

Compared exactly:

- the device kind and model; two devices wired alike with different models are reported as `lvs.model_mismatch`;
- each terminal's net, by role: the paired device's gate must be on the partner of the reference gate's net. A transistor's source and drain are interchangeable unless the deck declares the model `lvs asymmetric`, and so are a resistor's two ends;
- the counts `m`, `nf` and `nfin`, which are whole numbers.

Compared within a tolerance: every other parameter the reference card states, such as `w`, `l`, `as`, `r` or `c`. Two values agree when the gap between them is at most the tolerance times the larger of the two. With the 2% tolerance most decks state, a 1 µm transistor agrees with a card of 1.02 µm (gap 0.02 µm, 2% of 1.02 µm is 0.0204 µm) and not with 1.03 µm. A deck's `lvs tolerance` for one parameter of one model adds an absolute part, and the two parts add up.

Not compared: a parameter the reference card leaves out, whatever the layout measures. A parameter the card states and the layout does not measure is reported as `lvs.undeclared_param`, never passed in silence. Where the deck extracts no bulk terminal, the reference's bulks are dropped.

## Where a difference shows up

Read a mismatch from the kind of difference it lists.

A parameter outside its tolerance is the most local report. The devices pair by their wiring, and only that pair is reported. In a chain of three inverters whose reference states 0.3 µm for the last pfet's length, the report names that one pair:

```sh
gpurify lvs chain3.gds --deck example.deck --reference chain3_l.spice
```

```text
violations: 1
...
lvs: Mismatch([ParameterMismatch { layout_device: 5, ref_device: 5, param: "l", layout_value: 1.4999999999999997e-7, ref_value: 3e-7 }])
```

The layout's sixth device, its 0.15 µm pfet, pairs with the reference's sixth and differs from it in `l`.

A wrong connection changes the circuit's shape. One terminal on the wrong net changes the fanout of two nets: the net it should reach and the net it does reach. Those two nets have no partner with the same neighbours, so they are reported as `lvs.unpaired_net` on each side. The device whose terminal moved still pairs by its other terminals, and reports that terminal as `lvs.terminal_mismatch`. Everything else pairs. So look at the two unpaired nets: the wrong connection runs between them.

![Two inverter chains: the reference's last pfet gate on n6, the layout's on n7; nets n6 and n7 marked as the unpaired pair](../diagrams/how-lvs-matches-3.svg)

A missing or extra device leaves its model's class one short on one side. It is reported as `lvs.unpaired_device`, and the nets it alone touched as `lvs.unpaired_net`. Where several devices of the model look alike, the report adds a `lvs.class_imbalance`: the class of look-alike devices has a different size on each side, and GPurify cannot say which one is extra.

A device of the wrong model, wired as its counterpart, is reported once as `lvs.model_mismatch` naming both models.

## Read more

- [LVS checks](../reference/lvs/README.md): what LVS needs, the verdicts and the report.
- [Comparison checks](../reference/lvs/compare.md): each kind of difference.
- [Equivalence, swappable pins and black boxes](../reference/lvs/equivalence.md): pins that swap, and how names seed the pairing.
- [LVS controls](../reference/deck/lvs-controls.md): every `lvs` statement in the deck.
