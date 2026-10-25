//! Gompute kernels for extract, compiled for the CPU and for CUDA/HIP from this
//! one source. A leaf: it imports only `gompute`. Placeholder until the port
//! lands its kernels (ARCHITECTURE.md, GPU).
const g = @import("gompute");

pub const sum = g.sum("extract_sum", f64, struct {}, .{});

comptime {
    g.exportKernels(@This());
}
