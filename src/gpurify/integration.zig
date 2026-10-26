//! System-on-chip integration checks on a DEF design (catalog FLOW-003),
//! run with DRC when the layout is a DEF. Ported from
//! src/engine/integration.rs.
//!
//! Contents:
//! - `pub const rule_ids: [7][]const u8`

/// The checks' ids, in report order.
pub const rule_ids = [7][]const u8{
    "def.fill_outside_die",
    "def.component_outside_die",
    "def.component_overlap",
    "def.off_site",
    "def.pin_off_track",
    "def.off_manufacturing_grid",
    "def.cell_edge_spacing",
};
