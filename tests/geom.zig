//! geom suite, ported from crates/geom/tests (units and core).
test {
    _ = @import("geom/units.zig");
    _ = @import("geom/bbox_laws.zig");
    _ = @import("geom/connectivity_components.zig");
    _ = @import("geom/store_layout.zig");
    _ = @import("geom/view_validation.zig");
    _ = @import("geom/ops_predicates.zig");
    _ = @import("geom/index_pairs.zig");
    _ = @import("geom/rects_decomposition.zig");
    _ = @import("geom/boolean_laws.zig");
    _ = @import("geom/boolean_random.zig");
    _ = @import("geom/boolean_octilinear.zig");
    _ = @import("geom/boolean_anyangle.zig");
    _ = @import("geom/corner_model.zig");
    _ = @import("geom/width_pairs.zig");
    _ = @import("geom/derive_ops.zig");
    _ = @import("geom/width_anyangle.zig");
    _ = @import("geom/derive_anyangle.zig");
}
