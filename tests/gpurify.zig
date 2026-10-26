//! gpurify suite: the report writers (tests/export/main.rs) and the
//! engine's spines (tests/engine, tests/golden.rs, tests/test_all.rs).
test {
    _ = @import("gpurify");
    _ = @import("gpurify/export.zig");
    _ = @import("gpurify/engine.zig");
}
