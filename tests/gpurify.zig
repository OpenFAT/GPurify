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
}
