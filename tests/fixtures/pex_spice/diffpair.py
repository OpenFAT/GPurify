# A sky130 nfet differential pair, the PEX-017 gate's layout: two
# sky130_fd_pr__nfet_01v8, W 2 um, L 0.5 um, on one diffusion strip whose
# middle is their shared source `tail`; drains `outp`, `outn`; gates `inp`,
# `inn` on poly pads above; a p-tap `vss` beside them ties the substrate
# (their bulk). Every terminal climbs licon, li, mcon to a met1 pad carrying
# its label (68/5). Layers are SKY130's GDS pairs (docs: sky130.deck [S2]).
#
#   nix develop .#comparison -c klayout -b -r tests/fixtures/pex_spice/diffpair.py \
#       -rd out=tests/fixtures/pex_spice/diffpair.gds
import pya

L = {"diff": (65, 20), "tap": (65, 44), "poly": (66, 20), "licon": (66, 44), "li": (67, 20),
     "mcon": (67, 44), "met1": (68, 20), "met1_label": (68, 5), "nsdm": (93, 44), "psdm": (94, 20)}

layout = pya.Layout()
layout.dbu = 0.001
top = layout.create_cell("diffpair")
idx = {k: layout.layer(*v) for k, v in L.items()}


def box(layer, x0, y0, x1, y1):
    top.shapes(idx[layer]).insert(pya.DBox(x0, y0, x1, y1))


def contact(x, y, cut, name):
    """A cut (licon) of 0.17 at (x, y), li and met1 pads over it, mcon, the label."""
    h = 0.085
    box(cut, x - h, y - h, x + h, y + h)
    box("li", x - 0.2, y - 0.2, x + 0.2, y + 0.2)
    box("mcon", x - h, y - h, x + h, y + h)
    box("met1", x - 0.25, y - 0.25, x + 0.25, y + 0.25)
    top.shapes(idx["met1_label"]).insert(pya.DText(name, pya.DTrans(x, y)))


# The strip: drain 1 | gate 1 | shared source | gate 2 | drain 2.
box("diff", 0.0, 0.0, 4.0, 2.0)
box("nsdm", -0.2, -0.2, 4.2, 2.2)
for x0, name in ((1.0, "inp"), (2.5, "inn")):
    box("poly", x0, -0.15, x0 + 0.5, 2.6)
    box("poly", x0 - 0.1, 2.6, x0 + 0.6, 3.3)
    contact(x0 + 0.25, 2.95, "licon", name)
for x, name in ((0.5, "outp"), (2.0, "tail"), (3.5, "outn")):
    contact(x, 1.0, "licon", name)
# The substrate tap.
box("tap", 5.0, 0.5, 5.6, 1.5)
box("psdm", 4.8, 0.3, 5.8, 1.7)
contact(5.3, 1.0, "licon", "vss")

layout.write(out)
