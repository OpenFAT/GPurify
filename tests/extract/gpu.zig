//! The row kernels on the GPU against the host threads, bit for bit
//! (ARCHITECTURE.md, GPU: Verification). Compiled only under
//! `-Dgpu-tests=true`, where a build without device kernels, or a machine
//! without the driver, fails rather than skips.

const std = @import("std");
const testing = std.testing;
const extract = @import("extract");
const geom = @import("geom");
const testgen = @import("testgen");
const Rng = testgen.Rng;
const operators = @import("operators.zig");
const gpa = testing.allocator;

/// Zero, one, either side of the host row block and of the device block,
/// three device blocks and one.
const sizes = [_]usize{ 0, 1, 63, 64, 127, 128, 3 * 128 + 1, 600 };

// ---- private ----

fn gpuDevice() !geom.Device {
    const backend = extract.gpu.compiled orelse return error.BuiltWithoutGpuKernels;
    return .{ .backend = backend, .min_work = .always, .threads = 4 };
}

fn compare(n: usize, rng: *Rng, gpu: *extract.gpu.Gpu, m: *const extract.matvec.Potential, f: ?*const extract.dielectric.Field) !void {
    const x = try operators.randomCharges(gpa, rng, n);
    defer gpa.free(x);
    const want = try gpa.alloc(f64, n);
    defer gpa.free(want);
    const got = try gpa.alloc(f64, n);
    defer gpa.free(got);
    @memset(want, 0.0);
    @memset(got, 0.0);
    m.apply(x, want);
    if (f) |field| field.apply(x, want);
    try gpu.apply(x, got);
    try testing.expectEqualSlices(u64, @ptrCast(want), @ptrCast(got));
}

test "the potential rows on the gpu match the host bit for bit" {
    // Oracle: differential against the host threads, which kernels.zig holds
    // to the scalar fold: one row body, so every bit agrees.
    const device = try gpuDevice();
    var rng: Rng = .init(19);
    for (sizes) |n| {
        var m = try operators.randomPotential(gpa, &rng, n, 4);
        defer m.deinit(gpa);
        var gpu = extract.gpu.Gpu.init(std.testing.allocator, device, &m, null) orelse return error.NoGpuDriver;
        defer gpu.deinit();
        try compare(n, &rng, &gpu, &m, null);
    }
}

test "the field rows on the gpu match the host bit for bit" {
    // Oracle: differential against the host threads, as above, with the
    // interface rows after 0, 1 and 5 conductor panels.
    const device = try gpuDevice();
    var rng: Rng = .init(23);
    for ([_]usize{ 0, 1, 5 }) |first| {
        for (sizes) |rows| {
            var f = try operators.randomField(gpa, &rng, first, rows, 4);
            defer f.deinit(gpa);
            var m = try operators.randomPotential(gpa, &rng, first + rows, 4);
            defer m.deinit(gpa);
            // The potential rows are the conductors': `first` of them.
            m.near.start.shrinkRetainingCapacity(first + 1);
            var gpu = extract.gpu.Gpu.init(std.testing.allocator, device, &m, &f) orelse return error.NoGpuDriver;
            defer gpu.deinit();
            try compare(first + rows, &rng, &gpu, &m, &f);
        }
    }
}
