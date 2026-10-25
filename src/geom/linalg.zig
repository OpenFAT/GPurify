//! f64 vector algebra shared by the power-grid and field solvers: Gompute
//! specs, compiled for the CPU and for CUDA/HIP from this one source.
//! Placeholder until wave 1 ports `crates/geom/src/linalg.rs`.
//!
//! Contents:
//! - `pub const axpy`, `pub const Axpy = struct { a: f64 }`

const g = @import("gompute");

/// `out[i] = a * x[i] + y[i]`.
pub const axpy = g.zip("geom_axpy", f64, f64, f64, Axpy, axpyBody, .{});
pub const Axpy = struct { a: f64 };

comptime {
    g.exportKernels(@This());
}

// ---- private ----

fn axpyBody(x: anytype, y: anytype, p: Axpy) @TypeOf(x) {
    return x * g.splat(@TypeOf(x), p.a) + y;
}
