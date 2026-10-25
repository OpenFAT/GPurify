//! The backend choice: which device a kernel call runs on (ARCHITECTURE.md,
//! GPU). Built once by the spine from `--backend` and passed down as a
//! parameter; there is no global.
//!
//! Contents:
//! - `pub const Device = struct`, `Device.Backend = enum`, `Device.cpu`

/// A kernel call goes to the GPU when `backend != .cpu` and its work
/// estimate is at least `min_gpu_work`.
pub const Device = struct {
    backend: Backend,
    /// Calibration knob, measured by `zig build bench`, not a constant.
    min_gpu_work: u64,
    /// CPU worker threads for row kernels.
    threads: u16,

    pub const Backend = enum { cpu, cuda, hip };

    /// Single-threaded CPU: the deterministic default.
    pub const cpu: Device = .{ .backend = .cpu, .min_gpu_work = 0, .threads = 1 };
};
