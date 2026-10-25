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
//! - `system` (system.zig): `parseSystem`, `readSystem`, `System`
//! - `provenance` (provenance.zig), `Provenance`
//! - `globMatches` (glob.zig)

pub const gds = @import("gds.zig");
pub const deck = @import("deck/deck.zig");
pub const intent = @import("intent.zig");
pub const system = @import("system.zig");
pub const provenance = @import("provenance.zig");
pub const globMatches = @import("glob.zig").globMatches;

pub const Provenance = provenance.Provenance;

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
    _ = @import("intent.zig");
    _ = @import("system.zig");
    _ = @import("provenance.zig");
    _ = @import("deck/deck.zig");
    _ = @import("netlist_lex.zig");
    _ = @import("verilog_parse.zig");
    _ = @import("verilog.zig");
}
