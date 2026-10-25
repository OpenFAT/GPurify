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
//! - `globMatches` (glob.zig)

pub const gds = @import("gds.zig");
pub const globMatches = @import("glob.zig").globMatches;

test {
    _ = @import("glob.zig");
    _ = @import("gds.zig");
    _ = @import("gds_records.zig");
    _ = @import("gds_elements.zig");
}
