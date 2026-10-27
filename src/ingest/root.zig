//! ingest: every reader — GDSII layout, process deck, reference netlists,
//! design intent, multi-die system, LEF/DEF. Only re-exports.
//!
//! Readers fail closed: a malformed file, an unrepresentable coordinate or an
//! off-grid limit is an error with its location, never a partial result; a
//! construct a reader does not support is refused, never skipped. Every
//! reader interns its names into the run's one `StrTable`, so reading in the
//! same order (layout, deck, netlist, intent) gives the same ids.
//!
//! Contents:
//! - `gds` (gds.zig): `Library`, `Xform`, `readGdsBytes`
//! - `deck` (deck/deck.zig): `parseDeck`, `Deck`, `print`, ...
//! - `netlist`: the `Netlist` tables with `Error`, `Diagnostic`, `SubcktId`,
//!   `RefNetId`, `Param`, `Placement`, `max_flat_elements`, `max_cell_pins`,
//!   `max_hierarchy_depth` (netlist.zig), `readSpice`, `readSpectre`
//!   (netlist_read.zig), `flattenTop`, `flattenTopWith` (netlist_flatten.zig),
//!   `readVerilogInto` (verilog.zig)
//! - `intent` (intent.zig): `parseIntent`, `readIntent`, `DesignIntent`
//! - `currents` (currents.zig): `parseCurrents`, `readCurrents`, `Currents`
//! - `system` (system.zig): `parseSystem`, `readSystem`, `System`
//! - `lefdef` (lefdef.zig): `readLefInto`, `readDef`, `defUnits`, `flatten`, `toGds`
//! - `provenance` (provenance.zig), `Provenance`; `resolveLabels`, `LabelError` (label_bind.zig)
//! - `layout`: `flattenInto`, `UnknownLayers`, `LabelDepth` (flatten.zig),
//!   `flatPolygons`, `max_hierarchy_depth`, `max_flat_polygons` (flat_count.zig),
//!   `deriveLayersInto` (derive_layers.zig), `blackBoxesInto` (black_boxes.zig),
//!   `withBoxes`, `StreamBox` (gds_edit.zig)
//! - `gds_fixture` (gds_fixture.zig): GDSII bytes for tests, never for a run
//! - `globMatches` (glob.zig)

const flatten = @import("flatten.zig");
const counting = @import("flat_count.zig");
const edit = @import("gds_edit.zig");

pub const gds = @import("gds.zig");
pub const deck = @import("deck/deck.zig");
pub const intent = @import("intent.zig");
pub const currents = @import("currents.zig");
pub const system = @import("system.zig");
pub const lefdef = @import("lefdef.zig");
pub const provenance = @import("provenance.zig");
pub const globMatches = @import("glob.zig").globMatches;
pub const resolveLabels = @import("label_bind.zig").resolveLabels;
pub const LabelError = @import("label_bind.zig").Error;
pub const gds_fixture = @import("gds_fixture.zig");

pub const Provenance = provenance.Provenance;

/// Flattening a parsed `gds.Library` into a `GeometryStore`, and its edits.
pub const layout = struct {
    pub const flattenInto = flatten.flattenInto;
    pub const UnknownLayers = flatten.UnknownLayers;
    pub const LabelDepth = flatten.LabelDepth;
    pub const flatPolygons = counting.flatPolygons;
    pub const max_hierarchy_depth = counting.max_hierarchy_depth;
    pub const max_flat_polygons = counting.max_flat_polygons;
    pub const deriveLayersInto = @import("derive_layers.zig").deriveLayersInto;
    pub const blackBoxesInto = @import("black_boxes.zig").blackBoxesInto;
    pub const withBoxes = edit.withBoxes;
    pub const StreamBox = edit.StreamBox;
};

/// The reference-netlist readers and their tables.
pub const netlist = struct {
    const tables = @import("netlist.zig");
    pub const Netlist = tables.Netlist;
    pub const Error = tables.Error;
    pub const Diagnostic = tables.Diagnostic;
    pub const SubcktId = tables.SubcktId;
    pub const RefNetId = tables.RefNetId;
    pub const Param = tables.Param;
    pub const Placement = tables.Placement;
    pub const max_flat_elements = tables.max_flat_elements;
    pub const max_cell_pins = tables.max_cell_pins;
    pub const max_hierarchy_depth = tables.max_hierarchy_depth;
    pub const readSpice = @import("netlist_read.zig").readSpice;
    pub const readSpectre = @import("netlist_read.zig").readSpectre;
    pub const flattenTop = @import("netlist_flatten.zig").flattenTop;
    pub const flattenTopWith = @import("netlist_flatten.zig").flattenTopWith;
    pub const readVerilogInto = @import("verilog.zig").readInto;
};

test {
    _ = @import("glob.zig");
    _ = @import("gds.zig");
    _ = @import("gds_records.zig");
    _ = @import("gds_elements.zig");
    _ = @import("gds_keyhole.zig");
    _ = @import("gds_edit.zig");
    _ = @import("flat_count.zig");
    _ = @import("flatten.zig");
    _ = @import("derive_layers.zig");
    _ = @import("label_bind.zig");
    _ = @import("black_boxes.zig");
    _ = @import("intent.zig");
    _ = @import("currents.zig");
    _ = @import("system.zig");
    _ = @import("lefdef_tests.zig");
    _ = @import("provenance.zig");
    _ = @import("deck/deck.zig");
    _ = @import("netlist_lex.zig");
    _ = @import("verilog_parse.zig");
    _ = @import("verilog.zig");
}
