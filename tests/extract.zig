//! extract suite, ported from crates/extract/tests/field and the field
//! solver's parts of tests/exhaustive/pex.rs. `-Dgpu-tests=true` adds the
//! CPU-vs-GPU differentials, which fail without a driver.
const paths = @import("paths");

test {
    _ = @import("extract");
    _ = @import("extract/solve.zig");
    _ = @import("extract/kernels.zig");
    if (paths.gpu_tests) _ = @import("extract/gpu.zig");
}
