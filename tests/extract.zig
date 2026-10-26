//! extract suite, ported from crates/extract/tests/field and the field
//! solver's parts of tests/exhaustive/pex.rs. `-Dgpu-tests=true` adds the
//! CPU-vs-GPU differentials, which fail without a driver.
const paths = @import("paths");

test {
    _ = @import("extract");
    _ = @import("extract/solve.zig");
    _ = @import("extract/kernels.zig");
    _ = @import("extract/mesh.zig");
    _ = @import("extract/capacitance.zig");
    _ = @import("extract/henry.zig");
    _ = @import("extract/quasistatic.zig");
    _ = @import("extract/network.zig");
    if (paths.slow_tests) _ = @import("extract/capacitance_slow.zig");
    if (paths.gpu_tests) _ = @import("extract/gpu.zig");
}
