//! Facing runs: edges of different merged figures that face each other,
//! and how far they run alongside. In: a merged layer, each figure's owner
//! and the component labels of the prepared layer. Out: `Facing` rows sorted
//! by figure pair, and per pair the longest run within a gap. The edge-on-
//! its-line view (`Line`) the end-of-line rules share lives here too.
//! Ported from crates/check/src/drc/rules/spacing.rs (`Line`, `line_of`,
//! `on_line`, `facing_runs`, `run_within`).
//!
//! Contents:
//! - `pub const Line = struct`, `pub fn lineOf(edge: Seg) Line`, `pub fn lessLine(_: void, a: Line, b: Line) bool`
//! - `pub fn onLine(vertical: bool, pos: i64, from: i64, to: i64) Seg`
//! - `pub fn ringSeg(xs: []const Dbu, ys: []const Dbu, i: usize) Seg`
//! - `pub const Facing = struct { p: u32, q: u32, gap: i64, run: i64 }`
//! - `pub fn facingRunsInto(gpa: Allocator, store: *const GeometryStore, layer: LayerId, within: Dbu, figures: *const ValidatedLayer, owners: []const PolyId, labels: []const u32, out: *std.ArrayList(Facing)) Allocator.Error!void`
//! - `pub fn runWithin(runs: []const Facing, a: u32, b: u32, spacing: Dbu) i64`

const std = @import("std");
const Allocator = std.mem.Allocator;
const geom = @import("geom");
const Dbu = geom.Dbu;
const Point = geom.Point;
const Seg = geom.Seg;
const LayerId = geom.LayerId;
const PolyId = geom.PolyId;
const GeometryStore = geom.GeometryStore;
const ValidatedLayer = geom.ValidatedLayer;
const no_shape = @import("../report.zig").no_shape;

/// An axis-parallel edge on its line: whether it is vertical, its fixed
/// coordinate, whether it travels toward higher coordinates, and its span
/// `lo < hi`. Ordered field by field.
pub const Line = struct { vertical: bool, pos: i64, forward: bool, lo: i64, hi: i64 };

/// Two edges of different merged figures facing each other: the figures'
/// labels (lower first), the gap and the run they project onto each other.
pub const Facing = struct { p: u32, q: u32, gap: i64, run: i64 };

/// An edge of one orientation and side, for the facing sweep.
const Side = struct {
    vertical: bool,
    pos: i64,
    lo: i64,
    hi: i64,
    label: u32,

    fn less(_: void, x: Side, y: Side) bool {
        const kx = [5]i64{ @intFromBool(x.vertical), x.pos, x.lo, x.hi, x.label };
        const ky = [5]i64{ @intFromBool(y.vertical), y.pos, y.lo, y.hi, y.label };
        return std.mem.order(i64, &kx, &ky) == .lt;
    }

    /// `(vertical, pos)` at or before the probe's.
    fn atOrBefore(probe: Side, x: Side) bool {
        return @intFromBool(x.vertical) < @intFromBool(probe.vertical) or (x.vertical == probe.vertical and x.pos <= probe.pos);
    }
};

pub fn lineOf(edge: Seg) Line {
    const vertical = edge.a.x == edge.b.x;
    const pos = if (vertical) edge.a.x else edge.a.y;
    const from = if (vertical) edge.a.y else edge.a.x;
    const to = if (vertical) edge.b.y else edge.b.x;
    return .{ .vertical = vertical, .pos = pos, .forward = to > from, .lo = @min(from, to), .hi = @max(from, to) };
}

pub fn lessLine(_: void, a: Line, b: Line) bool {
    return keyOf(a) < keyOf(b) or (keyOf(a) == keyOf(b) and (a.lo < b.lo or (a.lo == b.lo and a.hi < b.hi)));
}

/// The segment from `from` to `to` along the line `pos`.
pub fn onLine(vertical: bool, pos: i64, from: i64, to: i64) Seg {
    return if (vertical)
        .{ .a = .{ .x = pos, .y = from }, .b = .{ .x = pos, .y = to } }
    else
        .{ .a = .{ .x = from, .y = pos }, .b = .{ .x = to, .y = pos } };
}

/// Edge `i` of a closed ring, the closing edge last.
pub fn ringSeg(xs: []const Dbu, ys: []const Dbu, i: usize) Seg {
    return geom.ops.ringEdge(xs, ys, i);
}

/// Every two edges of the merged `figures`, in different figures, facing
/// each other across a gap of at most `within` and running alongside for a
/// positive length, sorted by figure pair, into `out`. A figure is labelled
/// as the prepared layer labelled its owner (`labels`, by row offset).
/// Facing: parallel, out of their material toward each other, the one
/// facing up below the one facing down.
pub fn facingRunsInto(gpa: Allocator, store: *const GeometryStore, layer: LayerId, within: Dbu, figures: *const ValidatedLayer, owners: []const PolyId, labels: []const u32, out: *std.ArrayList(Facing)) Allocator.Error!void {
    const first_row = store.polysOnLayer(layer).start;
    var up: std.ArrayList(Side) = .empty;
    defer up.deinit(gpa);
    var down: std.ArrayList(Side) = .empty;
    defer down.deinit(gpa);
    for (owners, 0..) |owner, figure| {
        if (owner == no_shape) continue;
        const label = labels[@backingInt(owner) - first_row];
        const poly = figures.get(@intCast(figure));
        for (0..poly.ringCount()) |k| {
            const ring = poly.ring(@intCast(k));
            for (0..ring.xs.len) |i| {
                const l = lineOf(ringSeg(ring.xs, ring.ys, i));
                // Material on the left: up-travelling vertical, left-travelling horizontal.
                const side: Side = .{ .vertical = l.vertical, .pos = l.pos, .lo = l.lo, .hi = l.hi, .label = label };
                try (if (l.forward == l.vertical) &up else &down).append(gpa, side);
            }
        }
    }
    std.mem.sortUnstable(Side, down.items, {}, Side.less);
    out.clearRetainingCapacity();
    // ponytail: every down edge within `within` above each up edge;
    // quadratic only when many edges share one `within`-wide band.
    for (up.items) |u| {
        var at = std.sort.partitionPoint(Side, down.items, u, Side.atOrBefore);
        while (at < down.items.len) : (at += 1) {
            const d = down.items[at];
            if (d.vertical != u.vertical or d.pos - u.pos > within) break;
            const run = @min(u.hi, d.hi) - @max(u.lo, d.lo);
            if (run > 0 and d.label != u.label) try out.append(gpa, .{ .p = @min(u.label, d.label), .q = @max(u.label, d.label), .gap = d.pos - u.pos, .run = run });
        }
    }
    std.mem.sortUnstable(Facing, out.items, {}, lessFacing);
}

/// The run of figures `a` and `b`: the longest their facing edges at most
/// `spacing` apart project onto each other, or 0.
pub fn runWithin(runs: []const Facing, a: u32, b: u32, spacing: Dbu) i64 {
    const p = @min(a, b);
    const q = @max(a, b);
    var at = std.sort.partitionPoint(Facing, runs, [2]u32{ p, q }, struct {
        fn before(pair: [2]u32, f: Facing) bool {
            return f.p < pair[0] or (f.p == pair[0] and f.q < pair[1]);
        }
    }.before);
    var best: i64 = 0;
    while (at < runs.len and runs[at].p == p and runs[at].q == q) : (at += 1) {
        if (runs[at].gap <= spacing) best = @max(best, runs[at].run);
    }
    return best;
}

// ---- private ----

fn keyOf(l: Line) i128 {
    return (@as(i128, @intFromBool(l.vertical)) << 100) + (@as(i128, l.pos) << 2) + @intFromBool(l.forward);
}

fn lessFacing(_: void, x: Facing, y: Facing) bool {
    const kx = [4]i64{ x.p, x.q, x.gap, x.run };
    const ky = [4]i64{ y.p, y.q, y.gap, y.run };
    return std.mem.order(i64, &kx, &ky) == .lt;
}
