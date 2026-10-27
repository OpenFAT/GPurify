# Connectivity

The `connect` statements say which layers carry current and how they join, so GPurify can build
the layout's nets. LVS, ERC, PEX and the net-aware DRC rules all read these nets, and they name
them by the text labels in the layout.

```text
connect conductors [<layer>, ...]
connect touch_within_layer
connect via <cut layer> [<layer>, <layer>]
connect global <layer>
connect label <text layer> names <layer>
```

![The tutorial layout: met1 wire A joined to a met2 strap through a via1 cut, labelled A; met1 wire B, labelled B, crossed by the strap with no via, so it stays a separate net](../../diagrams/deck-connectivity-1.svg)

## Conductors

`connect conductors [...]` lists the layers whose shapes carry a net. Only a shape on a conductor
(or a global layer) is on a net. A deck may write several `connect conductors` lines; they add up.

A derived layer can be a conductor, and usually is: the source and drain diffusion is
`diff not poly`, not `diff`. An edge layer cannot.

## Touching shapes

`connect touch_within_layer`, written once, joins shapes on one conductor layer that touch or
overlap, a shared corner point included.

> [!WARNING]
> Without `connect touch_within_layer`, two touching shapes on one conductor are two nets unless a
> via joins them. A wire drawn as two abutting rectangles is then an open. Every shipped deck
> states the line.

## Vias

`connect via <cut> [<a>, <b>]` joins a shape on `a` and a shape on `b` wherever a shape on the cut
layer shares a point with both. The cut itself is on no net. Write one line per cut layer and
layer pair; a cut layer that joins different pairs in different places (a contact landing on
diffusion or on poly) gets one line for each pair.

```text
connect via licon [diff_active, li]
connect via licon [poly, li]
connect via mcon  [li, met1]
```

Both joined layers are conductors or global layers: a shape on any other layer is on no net, so
the via joins nothing there.

## Global nets

`connect global <layer>` makes every shape on the layer one net, however many there are and
wherever they lie. This is the substrate: a well tap reaches it through a via like any other cut.

```text
connect global psub
connect via psub_tie [ptap, psub]
```

A global layer is net-only. It carries no modelled current and no parasitics, so neither it nor a
via into it needs a `pex` line. It cannot also be listed in `connect conductors`. A device terminal
can name it, as a diode's anode on the substrate does.

## Labels

`connect label <text layer> names <layer>` names nets from the layout's text: a text on the text
layer names the net of the shape on `<layer>` it sits on, its edge included. The text layer is a
drawn layer, since only a GDS layer carries text records, and the named layer is a conductor. A
text layer may be the conductor's own layer, and one conductor may take names from several text
layers:

```text
connect label met1       names met1
connect label met1_label names met1
connect label met1_pin   names met1
```

A text on a label layer that lies on no shape of the layer it names refuses the layout, with the
text and its position: a dropped label would leave its net without its name.

LVS, SPEF and the intent file all refer to nets by these names. A net with no label gets a name
from GPurify.

**One name on two nets** that the layout does not join is an open. LVS reports it as
`lvs.label_conflict`, as a warning when the name is a must-connect name (see
[LVS controls](lvs-controls.md#must-connect-nets)).

**Two names on one net** is a short between them. Every run reports it as
`lvs.net_seed_conflict`, followed by `lvs.short_path`: the fewest shapes that join the two
labelled ones, one row per step from shape to shape. A via joins the shapes it lands on and is no
step itself.

## Example

```text
grid 5nm
layer met1       = gds(10, 0)
layer via1       = gds(11, 0)
layer met2       = gds(12, 0)
layer met1_label = gds(10, 5)

connect conductors [met1, met2]
connect touch_within_layer
connect via via1 [met1, met2]
connect label met1_label names met1
```

In this layout, a met2 strap and two vias join a wire labelled `A` to a wire labelled `B`:

```sh
gpurify erc conn.gds --deck conn.deck
```

```text
rules:
  lvs.net_seed_conflict: ran, examined 3 shapes, found 1 violations
  lvs.short_path: ran, examined 1 shapes, found 2 violations
violations: 3
  lvs.net_seed_conflict error layer met1 at (0 nm, 0 nm) measured 2 against limit 1 on shape 0 and shape 1
  lvs.short_path error layer met1 at (0 nm, 0 nm) measured 1 against limit 2 on shape 0 and shape 3
  lvs.short_path error layer met2 at (1750 nm, -200 nm) measured 2 against limit 2 on shape 3 and shape 1
...
```

The net holds 2 names where 1 is allowed. The short path runs from wire A (shape 0) to the met2
strap (shape 3) and from the strap to wire B (shape 1). The [LVS checks](../lvs/README.md) page
describes each of these reports.
