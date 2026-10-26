//! Windowed metal density and its CMP excursion (`density_cmp`): windows of
//! a row's size start at the die's lower-left corner and step while their
//! origin is inside the die; each window's density is the merged layer's
//! exact area inside it over its die-clipped area; a row flags windows
//! below `min`, above `max`, a neighbour step above `max_delta`, and a CMP
//! excursion `|sensitivity (density - target)|` above the model's limit.
//! In: the store, the die, one table. Out: violations and each row's run.
//! Ported from crates/check/src/erc/rules/antenna.rs (`check_density_cmp`,
//! `positions`, `window_span`, `window_boxes`, `window_touch_span`,
//! `window_owners_into`, `window_owner`).
//!
//! ponytail: CPU windows. drc's density row kernel (drc/density.zig) takes
//! square, unclipped windows; these are rectangular and clipped to the die.
//! A GPU path would generalise that kernel's grid to `(wx, wy, sx, sy)` and
//! a clip, uploading through `geom.bulk`.
//!
//! Contents:
//! - `pub fn densityRows(r: Record, design: Design, die: Bbox, t: *const DensityCmpTable, scratch: *Scratch) Allocator.Error!void`
//! - `pub fn positions(span: i64, step: i64) usize`, `pub fn windowBoxes(die: Bbox, i: usize, j: usize, window: [2]Dbu, step: [2]Dbu) [2]Bbox`
//! - `pub fn windowOwnersInto(gpa: Allocator, boxes: []const Bbox, first_row: u32, die: Bbox, window: [2]Dbu, step: [2]Dbu, nx: usize, ny: usize, out: *std.ArrayList(u32)) Allocator.Error!void`

const std = @import("std");
const Allocator = std.mem.Allocator;
const geom = @import("geom");
const Dbu = geom.Dbu;
const DbuArea = geom.DbuArea;
const Bbox = geom.Bbox;
const PolyId = geom.PolyId;
const report = @import("../report.zig");
const Measurement = report.Measurement;
const head_ = @import("head.zig");
const Record = head_.Record;
const Design = head_.Design;
const Scratch = @import("scratch.zig").Scratch;
const DensityCmpTable = @import("antenna_tables.zig").DensityCmpTable;

/// Where a window finding reports.
const Head = struct {
    r: Record,
    rule: geom.StrId,
    severity: report.Severity,
    layer: geom.LayerId,

    fn push(h: Head, clipped: Bbox, owner: PolyId, measured: Measurement, limit: Measurement) Allocator.Error!void {
        try h.r.out.push(h.r.gpa, .{ .rule = h.rule, .layer = h.layer, .severity = h.severity, .at = geom.ops.centre(clipped), .measured = measured, .limit = limit, .shape_a = owner, .shape_b = report.no_shape });
    }
};

/// Every row over the window grid laid on `die`. `examined` counts windows
/// held to the limits (every window with `partial_windows`, else those
/// wholly inside the die). A violation sits at the die-clipped window's
/// centre and names the lowest polygon whose box touches it (the layer's
/// first for an empty window). A row refuses when its window or step is not
/// positive or its layer will not validate.
pub fn densityRows(r: Record, design: Design, die: Bbox, t: *const DensityCmpTable, scratch: *Scratch) Allocator.Error!void {
    const gpa = r.gpa;
    var boxes: std.ArrayList(Bbox) = .empty;
    defer boxes.deinit(gpa);
    var rect_start: std.ArrayList(u32) = .empty;
    defer rect_start.deinit(gpa);
    var density: std.ArrayList(f64) = .empty;
    defer density.deinit(gpa);
    var held: std.ArrayList(bool) = .empty;
    defer held.deinit(gpa);
    var owners: std.ArrayList(u32) = .empty;
    defer owners.deinit(gpa);
    for (t.head.rule.items, t.head.severity.items, 0..) |rule, severity, row| {
        const window = t.window.items[row];
        const step = t.step.items[row];
        const before = r.out.len();
        const layer = t.layer.items[row];
        // A non-positive window has no density; a non-positive step never advances.
        if (window[0] <= 0 or window[1] <= 0 or step[0] <= 0 or step[1] <= 0) {
            try r.run(rule, before, .refused, 0);
            continue;
        }
        // Self-union merges overlaps, so a density stays inside `0 ..= 1`.
        if (try geom.view.validateLayer(gpa, design.store, layer, .rectilinear, &scratch.layer_a) != null) {
            try r.run(rule, before, .refused, 0);
            continue;
        }
        try geom.boolean.unionInto(gpa, &scratch.layer_a, &scratch.layer_a, &scratch.layer_b);
        try geom.rects.decomposeInto(gpa, &scratch.layer_b, &boxes, &rect_start);
        const nx = positions(die.xhi - die.xlo, step[0]);
        const ny = positions(die.yhi - die.ylo, step[1]);
        const count = nx * ny;
        const areas = &scratch.areas;
        areas.clearRetainingCapacity();
        try areas.appendNTimes(gpa, 0, count);
        // Rasterise the merged layer into the window grid.
        for (boxes.items) |rect| {
            const xs = windowSpan(rect.xlo, rect.xhi, die.xlo, window[0], step[0], nx);
            const ys = windowSpan(rect.ylo, rect.yhi, die.ylo, window[1], step[1], ny);
            for (ys[0]..ys[1]) |j| for (xs[0]..xs[1]) |i| {
                const clipped = windowBoxes(die, i, j, window, step)[1];
                areas.items[j * nx + i] += geom.rects.clippedArea(&.{rect}, clipped);
            };
        }
        const store_rows = design.store.polysOnLayer(layer);
        // A window holding no geometry is attributed to the layer's lowest row.
        const fallback: u32 = if (store_rows.start < store_rows.end) store_rows.start else 0;
        try windowOwnersInto(gpa, design.store.layerBboxes(layer), store_rows.start, die, window, step, nx, ny, &owners);
        const cmp = t.cmp.items[row];
        const partial = t.include_partial_windows.items[row];
        // Row-major from the die's lower-left; the delta pass relies on it.
        density.clearRetainingCapacity();
        held.clearRetainingCapacity();
        var examined: u64 = 0;
        const head: Head = .{ .r = r, .rule = rule, .severity = severity, .layer = layer };
        for (0..ny) |j| for (0..nx) |i| {
            const pair = windowBoxes(die, i, j, window, step);
            const clipped = pair[1];
            const counted = partial or die.contains(pair[0]);
            const value = @as(f64, @floatFromInt(areas.items[j * nx + i])) / @as(f64, @floatFromInt(@max(clipped.area(), 1)));
            try density.append(gpa, value);
            try held.append(gpa, counted);
            examined += @intFromBool(counted);
            const owner = windowOwner(owners.items, j * nx + i, fallback);
            const measured = Measurement.ratio(value);
            // An absent bound is not checked.
            if (t.min_density.items[row]) |min| if (counted and measured.violates(Measurement.ratio(min), .minimum)) try head.push(clipped, owner, measured, Measurement.ratio(min));
            if (t.max_density.items[row]) |max| if (counted and measured.violates(Measurement.ratio(max), .maximum)) try head.push(clipped, owner, measured, Measurement.ratio(max));
            if (cmp) |model| {
                const excursion = @as(f64, @floatFromInt(model.thickness_sensitivity)) * (value - model.target_density);
                // Saturated at the coordinate domain: violates every limit.
                const magnitude: Dbu = @intFromFloat(@min(@abs(excursion), @as(f64, @floatFromInt(geom.max_abs_dbu))));
                const m = Measurement.length(magnitude);
                const l = Measurement.length(model.max_abs_thickness_delta);
                if (counted and m.violates(l, .maximum)) try head.push(clipped, owner, m, l);
            }
        };
        // Gradient to the two windows ahead (`+1`, `+nx`) the row holds;
        // `min` clamps the last column and row onto themselves.
        if (t.max_neighbour_delta.items[row]) |delta| {
            const limit = Measurement.ratio(delta);
            for (0..ny) |j| for (0..nx) |i| {
                const slot = j * nx + i;
                for ([2]usize{ j * nx + @min(i + 1, nx - 1), @min(j + 1, ny - 1) * nx + i }) |nb| {
                    if (!(held.items[slot] and held.items[nb])) continue;
                    const gap = Measurement.ratio(@abs(density.items[slot] - density.items[nb]));
                    if (gap.violates(limit, .maximum)) try head.push(windowBoxes(die, i, j, window, step)[1], windowOwner(owners.items, slot, fallback), gap, limit);
                }
            };
        }
        try r.run(rule, before, .ran, examined);
    }
}

/// Window positions along a span: every window starts inside the die.
pub fn positions(span: i64, step: i64) usize {
    if (span <= 0) return 0;
    return @intCast(@divTrunc(span - 1, step) + 1);
}

/// Window `(i, j)`, and the same window clipped to the die. Asserts the
/// window meets the die (every window from `positions` does).
pub fn windowBoxes(die: Bbox, i: usize, j: usize, window: [2]Dbu, step: [2]Dbu) [2]Bbox {
    const xlo = die.xlo + @as(i64, @intCast(i)) * step[0];
    const ylo = die.ylo + @as(i64, @intCast(j)) * step[1];
    const full: Bbox = .{ .xlo = xlo, .ylo = ylo, .xhi = xlo + window[0], .yhi = ylo + window[1] };
    return .{ full, full.intersection(die).? };
}

/// `out[j * nx + i]`: the lowest store row whose box touches die-clipped
/// window `(i, j)`, or `maxInt(u32)`. `boxes[k]` is row `first_row + k`.
pub fn windowOwnersInto(gpa: Allocator, boxes: []const Bbox, first_row: u32, die: Bbox, window: [2]Dbu, step: [2]Dbu, nx: usize, ny: usize, out: *std.ArrayList(u32)) Allocator.Error!void {
    out.clearRetainingCapacity();
    try out.appendNTimes(gpa, std.math.maxInt(u32), nx * ny);
    for (boxes, 0..) |b, k| {
        const row = first_row + @as(u32, @intCast(k));
        const xs = touchSpan(b.xlo, b.xhi, die.xlo, die.xhi, window[0], step[0], nx);
        const ys = touchSpan(b.ylo, b.yhi, die.ylo, die.yhi, window[1], step[1], ny);
        for (ys[0]..ys[1]) |j| for (xs[0]..xs[1]) |i| {
            out.items[j * nx + i] = @min(out.items[j * nx + i], row);
        };
    }
}

// ---- private ----

/// The half-open range of windows the interval `[lo, hi]` contributes area
/// to (an edge-on touch contributes none).
fn windowSpan(lo: i64, hi: i64, origin: i64, window: i64, step: i64, count: usize) [2]usize {
    const n: i64 = @intCast(count);
    const first = std.math.clamp(@divFloor(lo - window - origin, step) + 1, 0, n);
    // `ceil((hi - origin) / step)`, as a negated floor.
    const end = std.math.clamp(-@divFloor(origin - hi, step), first, n);
    return .{ @intCast(first), @intCast(end) };
}

/// The half-open range of windows whose die-clipped box `[lo, hi]`
/// touches, boundary included; an interval starting past the die's far
/// edge touches nothing.
fn touchSpan(lo: i64, hi: i64, origin: i64, far: i64, window: i64, step: i64, count: usize) [2]usize {
    const n: i64 = @intCast(count);
    const past: i64 = @as(i64, @intFromBool(lo > far)) * n;
    const first = @max(std.math.clamp(-@divFloor(window + origin - lo, step), 0, n), past);
    const end = std.math.clamp(@divFloor(hi - origin, step) + 1, first, n);
    return .{ @intCast(first), @intCast(end) };
}

/// The store row a window finding names; `fallback` for an empty window.
fn windowOwner(owners: []const u32, slot: usize, fallback: u32) PolyId {
    const best = owners[slot];
    return @fromBackingInt(if (best == std.math.maxInt(u32)) fallback else best);
}

fn bbox(xlo: i64, ylo: i64, xhi: i64, yhi: i64) Bbox {
    return .{ .xlo = xlo, .ylo = ylo, .xhi = xhi, .yhi = yhi };
}

test "the owner grid answers what the linear scan did" {
    // Oracle: differential against the linear scan it replaced (the lowest
    // row whose box overlaps the die-clipped window), on every window of five
    // window/step layouts, with edge-on, clipped and off-die boxes.
    const gpa = std.testing.allocator;
    const die = bbox(0, 0, 300, 200);
    const boxes = [_]Bbox{ bbox(320, 250, 340, 260), bbox(400, 10, 500, 20), bbox(-500, -500, -400, -400), bbox(100, 0, 100, 200), bbox(10, 10, 40, 40), bbox(250, 150, 400, 400), bbox(0, 0, 300, 200) };
    const first_row = 7;
    var owners: std.ArrayList(u32) = .empty;
    defer owners.deinit(gpa);
    for ([_][4]i64{ .{ 100, 100, 100, 100 }, .{ 100, 100, 50, 50 }, .{ 150, 200, 100, 100 }, .{ 300, 200, 300, 200 }, .{ 7, 11, 13, 17 } }) |c| {
        const window = [2]Dbu{ c[0], c[1] };
        const step = [2]Dbu{ c[2], c[3] };
        const nx = positions(die.xhi - die.xlo, c[2]);
        const ny = positions(die.yhi - die.ylo, c[3]);
        try windowOwnersInto(gpa, &boxes, first_row, die, window, step, nx, ny, &owners);
        try std.testing.expectEqual(nx * ny, owners.items.len);
        for (0..ny) |j| for (0..nx) |i| {
            const clipped = windowBoxes(die, i, j, window, step)[1];
            var want: u32 = std.math.maxInt(u32);
            for (boxes, 0..) |b, k| if (b.overlaps(clipped)) {
                want = first_row + @as(u32, @intCast(k));
                break;
            };
            try std.testing.expectEqual(want, owners.items[j * nx + i]);
        };
    }
}
