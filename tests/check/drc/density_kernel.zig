//! The density-window row kernel from outside the module: CPU threads
//! against one thread, and the GPU body against the CPU's, bit for bit
//! (behind `-Dgpu-tests`). New tests for the Zig row kernel; the body's
//! clipping oracle is the in-file test of drc/density.zig.

const std = @import("std");
const testing = std.testing;
const geom = @import("geom");
const check = @import("check");
const testgen = @import("testgen");
const paths = @import("paths");
const Bbox = geom.Bbox;
const density = check.drc.density;

const gpa = testing.allocator;

// ---- private ----

/// Disjoint random rectangles, one per 40-high band, and a grid of exactly
/// `windows` windows (`cols` of them per row).
fn corpus(rng: *testgen.Rng, rects: *std.ArrayList(Bbox), cols: u32, windows: u32) !density.Grid {
    rects.clearRetainingCapacity();
    for (0..200) |k| {
        const x = rng.range(-500, 5000);
        const y = @as(i64, @intCast(k)) * 40 + rng.range(0, 10);
        try rects.append(gpa, .{ .xlo = x, .ylo = y, .xhi = x + 1 + rng.range(0, 900), .yhi = y + 1 + rng.range(0, 29) });
    }
    const ways = @max(1, std.math.divCeil(u32, windows, cols) catch unreachable);
    return .{ .x0 = -600, .y0 = -10, .side = 700, .stride = 300, .cols = cols, .ways = ways };
}

test "threaded window areas equal one thread's" {
    // Oracle: law. The body reads only its own window, so any partition of
    // the windows over threads gives the same bits as one thread.
    var rng = testgen.Rng.init(5);
    var rects: std.ArrayList(Bbox) = .empty;
    defer rects.deinit(gpa);
    const g = try corpus(&rng, &rects, 64, 64 * 40);
    var bins: density.Bins = .{};
    defer bins.deinit(gpa);
    try bins.fill(gpa, g, rects.items);
    const one = try gpa.alloc(i64, g.count());
    defer gpa.free(one);
    const many = try gpa.alloc(i64, g.count());
    defer gpa.free(many);
    try density.windowAreasCpu(g, &bins, 1, one);
    try density.windowAreasCpu(g, &bins, 7, many);
    try testing.expectEqualSlices(i64, one, many);
}

test "the GPU density-window kernel gives the CPU's bits (-Dgpu-tests)" {
    // Oracle: differential, CPU body against GPU body, bit-equal, at 0, 1,
    // block - 1, block and 3 * block + 1 windows (block = 256 lanes). Off by
    // default; with the gate on it fails without a driver, never skips.
    if (!paths.gpu_tests) return;
    var rng = testgen.Rng.init(11);
    var rects: std.ArrayList(Bbox) = .empty;
    defer rects.deinit(gpa);
    for ([_]u32{ 0, 1, 255, 256, 3 * 256 + 1 }) |n| {
        var g = try corpus(&rng, &rects, 1, n);
        g.ways = n;
        var bins: density.Bins = .{};
        defer bins.deinit(gpa);
        try bins.fill(gpa, g, rects.items);
        const cpu = try gpa.alloc(i64, n);
        defer gpa.free(cpu);
        const gpu = try gpa.alloc(i64, n);
        defer gpa.free(gpu);
        try density.windowAreasCpu(g, &bins, 1, cpu);
        density.windowAreasGpu(gpa, .cuda, g, &bins, gpu) catch |err| switch (err) {
            error.NotBuilt => try density.windowAreasGpu(gpa, .hip, g, &bins, gpu),
            else => return err,
        };
        try testing.expectEqualSlices(i64, cpu, gpu);
    }
}
