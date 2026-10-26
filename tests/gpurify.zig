//! gpurify suite: the report writers (tests/export/main.rs) and the
//! engine's spines (tests/engine, tests/golden.rs, tests/test_all.rs).
test {
    _ = @import("gpurify");
    _ = @import("gpurify/export.zig");
    _ = @import("gpurify/engine.zig");
    _ = @import("gpurify/fixtures.zig");
    _ = @import("gpurify/golden.zig");
    _ = @import("gpurify/test_all.zig");
    _ = @import("gpurify/triage.zig");
    _ = @import("gpurify/edits.zig");
    _ = @import("gpurify/incremental.zig");
    _ = @import("gpurify/def.zig");
    _ = @import("gpurify/system_checks.zig");
    _ = @import("gpurify/pdk_decks.zig");
    _ = @import("gpurify/sky130_rules.zig");
    _ = @import("gpurify/flow.zig");
    _ = @import("gpurify/metamorphic.zig");
    _ = @import("gpurify/bitmap.zig");
    _ = @import("gpurify/drc_common.zig");
    _ = @import("gpurify/dim_width.zig");
    _ = @import("gpurify/dim_max_width.zig");
    _ = @import("gpurify/dim_cut.zig");
    _ = @import("gpurify/dim_step.zig");
    _ = @import("gpurify/dim_edge.zig");
    _ = @import("gpurify/dim_notch.zig");
    _ = @import("gpurify/dim_spacing.zig");
    _ = @import("gpurify/dim_eol.zig");
    _ = @import("gpurify/dim_eol_within.zig");
    _ = @import("gpurify/dim_eol58.zig");
    _ = @import("gpurify/dim_keep_out.zig");
    _ = @import("gpurify/dim_prl.zig");
    _ = @import("gpurify/dim_corner.zig");
    _ = @import("gpurify/dim_wide.zig");
    _ = @import("gpurify/dim_net.zig");
    _ = @import("gpurify/dim_tables.zig");
    _ = @import("gpurify/dim_pitch.zig");
    _ = @import("gpurify/dim_area.zig");
    _ = @import("gpurify/dim_grid_angle.zig");
    _ = @import("gpurify/dim_forbidden.zig");
    _ = @import("gpurify/dim_directional.zig");
    _ = @import("gpurify/dim_integrity.zig");
}
