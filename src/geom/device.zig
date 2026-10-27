//! The backend choice: which device a kernel call runs on
//! (docs/src/explanation/cpu-and-gpu.md). Built once by the spine from
//! `--backend` and passed down as a parameter; there is no global.
//!
//! Contents:
//! - `pub const Device = struct`, `Device.Backend = enum`, `Device.MinWork = struct`,
//!   `MinWork.always`, `MinWork.never`, `Device.cpu`, `Device.available(backend: Backend) bool`

const std = @import("std");

/// A kernel call goes to the GPU when `backend != .cpu` and its work
/// estimate is at least its class's `min_work`. Where it runs never changes
/// what it returns: every GPU path is bit-identical to its CPU body.
pub const Device = struct {
    backend: Backend,
    /// Calibration knob: measured on this machine at startup for
    /// `--backend auto` (gpurify/calibrate.zig), 0 for a named GPU backend.
    min_work: MinWork,
    /// CPU worker threads for row kernels.
    threads: u16,

    pub const Backend = enum { cpu, cuda, hip };

    /// The smallest work, in each class's unit, that goes to the GPU. One
    /// field per ceiling the GPU hits, because a card's f64 rate and its
    /// integer-plus-PCIe rate are unrelated (a GeForce runs f64 at 1/64, a
    /// data-centre part at 1/2), and a kernel that uploads its whole input
    /// per call pays a transfer the resident-store kernels do not.
    pub const MinWork = struct {
        /// f64 row kernels (BEM potential and field rows), in P² pair
        /// evaluations per apply: bound by the card's f64 rate.
        float: u64,
        /// Integer row kernels over the run's resident store
        /// (`ResidentStore`), in edge pairs: only the pair list goes up and
        /// the distances come down per call.
        resident: u64,
        /// Integer row kernels whose whole input goes up per call (density
        /// windows), in rectangle visits: bound by that transfer.
        streamed: u64,

        /// Every call on the GPU: a named `--backend cuda|hip`.
        pub const always: MinWork = .{ .float = 0, .resident = 0, .streamed = 0 };
        /// Every call on the CPU.
        pub const never: MinWork = .{ .float = max, .resident = max, .streamed = max };

        const max = std.math.maxInt(u64);
    };

    /// Single-threaded CPU: the deterministic default.
    pub const cpu: Device = .{ .backend = .cpu, .min_work = .always, .threads = 1 };

    /// Whether `backend` runs here: the CPU always; CUDA or HIP when this
    /// build carries its device kernels and its driver loads with at least
    /// one device (what `--backend auto` asks of each in turn).
    pub fn available(backend: Backend) bool {
        const g = @import("gompute");
        const artifacts = @import("gompute_kernels");
        return switch (backend) {
            .cpu => true,
            .cuda => if (artifacts.has_cuda) (g.runtime.cuda.deviceCount() catch 0) > 0 else false,
            .hip => if (artifacts.has_hip) (g.runtime.hip.deviceCount() catch 0) > 0 else false,
        };
    }
};
