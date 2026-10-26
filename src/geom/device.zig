//! The backend choice: which device a kernel call runs on (ARCHITECTURE.md,
//! GPU). Built once by the spine from `--backend` and passed down as a
//! parameter; there is no global.
//!
//! Contents:
//! - `pub const Device = struct`, `Device.Backend = enum`, `Device.cpu`,
//!   `Device.available(backend: Backend) bool`

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
