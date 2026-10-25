//! geom suite, ported from crates/geom/tests (units and core).
test {
    _ = @import("geom/units.zig");
    _ = @import("geom/bbox_laws.zig");
    _ = @import("geom/connectivity_components.zig");
}
