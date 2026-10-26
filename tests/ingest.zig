//! ingest suite: the readers on whole inputs, ported from crates/ingest/tests.
test {
    _ = @import("ingest/layout.zig");
    _ = @import("ingest/flatten.zig");
    _ = @import("ingest/provenance.zig");
    _ = @import("ingest/deck.zig");
    _ = @import("ingest/deck_rules.zig");
    _ = @import("ingest/deck_lvs.zig");
    _ = @import("ingest/deck_errors.zig");
    _ = @import("ingest/netlist.zig");
    _ = @import("ingest/verilog.zig");
    _ = @import("ingest/intent.zig");
}
