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
//! - `provenance` (provenance.zig), `Provenance`
//! - `globMatches` (glob.zig)

pub const gds = @import("gds.zig");
pub const deck = @import("deck/deck.zig");
pub const provenance = @import("provenance.zig");
pub const globMatches = @import("glob.zig").globMatches;

pub const Provenance = provenance.Provenance;

test {
    _ = @import("glob.zig");
    _ = @import("gds.zig");
    _ = @import("gds_records.zig");
    _ = @import("gds_elements.zig");
    _ = @import("provenance.zig");
    _ = @import("deck/deck.zig");
}
