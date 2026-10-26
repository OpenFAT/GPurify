//! The matching kinds' transforms. Stubs until the family is ported: each
//! records every row of its table refused, never clean. Ported from
//! crates/check/src/erc/rules/matching.rs.
//!
//! Contents:
//! - `pub fn checkMatching(r: Record, design: Design, t: *const MatchingTable) Allocator.Error!void`

const std = @import("std");
const Allocator = std.mem.Allocator;
const geom = @import("geom");
const Record = @import("head.zig").Record;
const Design = @import("head.zig").Design;
const tables = @import("latchup_tables.zig");
const MatchingTable = tables.MatchingTable;

/// `MatchingTable` rows. ponytail: not yet ported; every row refuses.
pub fn checkMatching(r: Record, design: Design, t: *const MatchingTable) Allocator.Error!void {
    _ = design;
    try r.fillRows(&t.head, .refused);
}
