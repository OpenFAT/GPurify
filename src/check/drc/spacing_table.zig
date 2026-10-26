//! Spacing by table: LEF `SPACINGTABLE PARALLELRUNLENGTH` (each width row a
//! shape's wide part reaches, the column its run exceeds) and `SPACINGTABLE
//! TWOWIDTHS` (a cell per pair of width classes). In: one rectilinear layer
//! and its table. Out: one violation per separate pair, at its highest
//! failing cell. Ported from crates/check/src/drc/rules/spacing.rs
//! (`spacing_table`, `wide_runs`, `two_width_table`, `class_part`,
//! `parts_gap`, `parts_at`, `rect_rect_pairs`).
//!
//! Contents:
//! - `pub fn spacingTable(c: *const Ctx, r: LayerTable) Error!Verdict`
//! - `pub fn twoWidthTable(c: *const Ctx, r: LayerTable) Error!Verdict`

const std = @import("std");
const Allocator = std.mem.Allocator;
const geom = @import("geom");
const Dbu = geom.Dbu;
const DbuArea = geom.DbuArea;
const Bbox = geom.Bbox;
const Point = geom.Point;
const PolyId = geom.PolyId;
const Polygon = geom.Polygon;
const GeometryStore = geom.GeometryStore;
const report = @import("../report.zig");
const Verdict = report.Verdict;
const rects = @import("../rects.zig");
const proximity = @import("../proximity.zig");
const Nearest = proximity.Nearest;
const rows = @import("rows.zig");
const scratch = @import("scratch.zig");
const Ctx = scratch.Ctx;
const Error = scratch.Error;
const runs_ = @import("runs.zig");
const parts = @import("parts.zig");

/// A run of a wide part facing an edge: its gap and length.
const Stretch = struct { gap: i64, run: i64 };

/// What a two-width cell measures of a shape: null the whole shape (the
/// first width), else its part wider than the cell's width.
const Part = ?[]const Bbox;

const Fail = struct { d2: DbuArea, at: Point, need: Dbu };

/// The run of two figures within a cell, as `SpacingTable.column` reads it.
const RunAt = struct {
    runs: []const runs_.Facing,
    a: u32,
    b: u32,

    pub fn run(r: RunAt, cell: Dbu) i64 {
        return runs_.runWithin(r.runs, r.a, r.b, cell);
    }
};

/// The layer prepared for a table: pairs and labels (in the scratch), the
/// drawn polygons, per width row above the first each polygon's wide parts,
/// the facing runs, and each label's merged figure.
const Prepared = struct {
    first_row: u32 = 0,
    poly_of_row: []const u32 = &.{},
    /// Per width above the first.
    parts: []parts.Parts = &.{},
    runs: std.ArrayList(runs_.Facing) = .empty,
    /// `(label, figure)`, sorted.
    figure_of: std.ArrayList([2]u32) = .empty,

    fn deinit(p: *Prepared, gpa: Allocator) void {
        for (p.parts) |*x| x.deinit(gpa);
        gpa.free(p.parts);
        p.runs.deinit(gpa);
        p.figure_of.deinit(gpa);
    }

    /// False (refused) when the layer does not validate. `squares` are the
    /// sides that make a part wide for each width row above the first.
    fn init(p: *Prepared, c: *const Ctx, layer: geom.LayerId, widest: Dbu, squares: []const Dbu) Error!bool {
        const gpa = c.gpa;
        const s = &c.s.p;
        if (!try proximity.prepareMerged(gpa, c.store, layer, widest, s)) return false;
        const drawn = (try s.validated.get(gpa, c.store, layer)).?;
        try s.rects_a.build(gpa, c.store, layer, drawn);
        p.first_row = c.store.polysOnLayer(layer).start;
        p.poly_of_row = s.rects_a.poly_of_row.items;
        p.parts = try gpa.alloc(parts.Parts, squares.len);
        for (p.parts) |*x| x.* = .{};
        var wide: std.ArrayList(Bbox) = .empty;
        defer wide.deinit(gpa);
        for (p.parts, squares) |*x, square| {
            try scratch.wideRectsInto(gpa, drawn, square, &wide);
            try parts.widePartsInto(gpa, &s.rects_a, s.labels.items, p.first_row, wide.items, 0, x);
        }
        try rects.ownersOfInto(gpa, &s.layer_out, &s.rects_a, &c.s.owners);
        try runs_.facingRunsInto(gpa, c.store, layer, widest, &s.layer_out, c.s.owners.items, s.labels.items, &p.runs);
        for (c.s.owners.items, 0..) |owner, f| {
            if (owner == report.no_shape) continue;
            try p.figure_of.append(gpa, .{ s.labels.items[@backingInt(owner) - p.first_row], @intCast(f) });
        }
        std.mem.sortUnstable([2]u32, p.figure_of.items, {}, lessPair);
        return true;
    }

    fn label(p: *const Prepared, s: *const proximity.Scratch, row: PolyId) u32 {
        return s.labels.items[@backingInt(row) - p.first_row];
    }

    fn polyOf(p: *const Prepared, row: PolyId) u32 {
        return p.poly_of_row[@backingInt(row) - p.first_row];
    }

    /// Two different merged figures and two different polygons.
    fn separate(p: *const Prepared, s: *const proximity.Scratch, a: PolyId, b: PolyId) bool {
        return p.label(s, a) != p.label(s, b) and p.polyOf(a) != p.polyOf(b);
    }

    /// The merged figure holding `row`.
    fn figure(p: *const Prepared, s: *const proximity.Scratch, row: PolyId) Polygon {
        const l = p.label(s, row);
        const at = std.sort.partitionPoint([2]u32, p.figure_of.items, l, struct {
            fn before(want: u32, x: [2]u32) bool {
                return x[0] < want;
            }
        }.before);
        return s.layer_out.get(p.figure_of.items[at][1]);
    }

    /// Polygon `poly`'s part for width class `class`: the whole shape (null)
    /// for the first, its wide part for the rest, and none (outer null)
    /// when it has no part that wide.
    fn classPart(p: *const Prepared, class: usize, poly: u32) ?Part {
        if (class == 0) return @as(Part, null);
        const mine = p.parts[class - 1].of(poly);
        return if (mine.len == 0) null else @as(Part, mine);
    }
};

/// Each separate pair is held, in each width row either shape reaches
/// (measured from that shape's part at least as wide; row 0 from the whole
/// shape), to the cell of the last column whose run it exceeds, the run read
/// off the merged figures' edges facing each other at most that cell apart.
/// A pair reports once, at its highest failing row. `examined` counts
/// separate pairs.
pub fn spacingTable(c: *const Ctx, r: rows.LayerTable) Error!Verdict {
    const gpa = c.gpa;
    const table = c.rs.spacingTable(r.table);
    const widest = table.space[table.space.len - 1];
    const squares = try gpa.alloc(Dbu, table.width.len - 1);
    defer gpa.free(squares);
    for (squares, 1..) |*q, row| q.* = table.rowSquare(row);
    var p: Prepared = .{};
    defer p.deinit(gpa);
    if (!try p.init(c, r.layer, widest, squares)) return report.refused;
    const s = &c.s.p;
    var stretches: std.ArrayList(Stretch) = .empty;
    defer stretches.deinit(gpa);
    var examined: u64 = 0;
    for (s.pairs.items, s.dists.items) |pair, whole| {
        if (!p.separate(s, pair.a, pair.b)) continue;
        examined += 1;
        const la = p.label(s, pair.a);
        const lb = p.label(s, pair.b);
        const column0 = table.column(0, RunAt{ .runs = p.runs.items, .a = la, .b = lb });
        var failed: ?Fail = null;
        var row = table.width.len;
        while (row > 1 and failed == null) {
            row -= 1;
            const wide_a = p.parts[row - 1].of(p.polyOf(pair.a));
            const wide_b = p.parts[row - 1].of(p.polyOf(pair.b));
            if (wide_a.len == 0 and wide_b.len == 0) continue;
            // A wide row's columns past the first: a stretch of the wide part
            // facing the other figure, running past the column's length and
            // closer than its cell (IHP M1.e projects from the wide part).
            stretches.clearRetainingCapacity();
            try wideRunsInto(gpa, wide_a, p.figure(s, pair.b), widest, &stretches);
            try wideRunsInto(gpa, wide_b, p.figure(s, pair.a), widest, &stretches);
            var column = table.prl.len;
            while (column > 1 and failed == null) {
                column -= 1;
                const need = table.at(row, column);
                var least: ?i64 = null;
                for (stretches.items) |st| if (st.run > table.prl[column] and st.gap < need) {
                    least = if (least) |l| @min(l, st.gap) else st.gap;
                };
                if (least) |gap| {
                    const d2 = geom.mulWide(gap, gap);
                    failed = .{ .d2 = d2, .at = try parts.wideAt(gpa, c.store, pair.a, pair.b, wide_a, wide_b, d2), .need = need };
                }
            }
            if (failed != null) break;
            // The first column: any distance from the wide part.
            const d2 = @min(parts.rectsRingDist2(wide_a, c.store.polyVerts(pair.b)), parts.rectsRingDist2(wide_b, c.store.polyVerts(pair.a)));
            const need = table.at(row, 0);
            if (d2 < geom.mulWide(need, need)) failed = .{ .d2 = d2, .at = try parts.wideAt(gpa, c.store, pair.a, pair.b, wide_a, wide_b, d2), .need = need };
        }
        const need = table.at(0, column0);
        if (failed == null and whole < geom.mulWide(need, need)) failed = .{ .d2 = whole, .at = try proximity.wholeAt(gpa, c.store, pair.a, pair.b, whole), .need = need };
        if (failed) |f| try c.push(proximity.spacingViolation(c.rule, r.layer, pair.a, pair.b, .{ .d2 = f.d2, .at = f.at }, f.need));
    }
    return scratch.ran(examined);
}

/// Each separate pair is held, for every row whose width one shape has a
/// part wider than and every column whose width the other has, where the
/// figures' run within that cell exceeds both widths' runs (those stated),
/// to that cell, measured between the two parts. A pair reports once, at
/// its highest failing cell (the nearest of those). `examined` counts
/// separate pairs.
pub fn twoWidthTable(c: *const Ctx, r: rows.LayerTable) Error!Verdict {
    const gpa = c.gpa;
    const table = c.rs.classTable(r.table);
    const widest = std.mem.max(Dbu, table.space);
    const squares = try gpa.alloc(Dbu, table.class.len - 1);
    defer gpa.free(squares);
    for (squares, table.class[1..]) |*q, w| q.* = w + 1;
    var p: Prepared = .{};
    defer p.deinit(gpa);
    if (!try p.init(c, r.layer, widest, squares)) return report.refused;
    const s = &c.s.p;
    const n = table.class.len;
    var examined: u64 = 0;
    for (s.pairs.items, s.dists.items) |pair, whole| {
        if (!p.separate(s, pair.a, pair.b)) continue;
        examined += 1;
        const la = p.label(s, pair.a);
        const lb = p.label(s, pair.b);
        var worst: ?struct { need: Dbu, d2: DbuArea, pa: Part, pb: Part } = null;
        for (0..n) |row| {
            const pa = p.classPart(row, p.polyOf(pair.a)) orelse continue;
            for (0..n) |col| {
                const pb = p.classPart(col, p.polyOf(pair.b)) orelse continue;
                const need = table.at(row, col);
                const run = runs_.runWithin(p.runs.items, la, lb, need);
                const past_r = if (table.prl[row]) |prl| run > prl else true;
                const past_c = if (table.prl[col]) |prl| run > prl else true;
                if (!(past_r and past_c)) continue;
                const d2 = try partsGap(gpa, c.store, pair.a, pair.b, pa, pb, whole);
                const worse = if (worst) |w| need > w.need or (need == w.need and d2 < w.d2) else true;
                if (d2 < geom.mulWide(need, need) and worse) worst = .{ .need = need, .d2 = d2, .pa = pa, .pb = pb };
            }
        }
        const w = worst orelse continue;
        const at = try partsAt(gpa, c.store, pair.a, pair.b, w.pa, w.pb, w.d2);
        try c.push(proximity.spacingViolation(c.rule, r.layer, pair.a, pair.b, .{ .d2 = w.d2, .at = at }, w.need));
    }
    return scratch.ran(examined);
}

// ---- private ----

fn lessPair(_: void, x: [2]u32, y: [2]u32) bool {
    return x[0] < y[0] or (x[0] == y[0] and x[1] < y[1]);
}

/// The stretches of `wide` rectangles facing an edge of `other` at most
/// `within` away, into `out` (appended): per facing edge and gap, the union
/// of what the rectangles' facing sides project onto the edge.
fn wideRunsInto(gpa: Allocator, wide: []const Bbox, other: Polygon, within: Dbu, out: *std.ArrayList(Stretch)) Allocator.Error!void {
    var spans: std.ArrayList([4]i64) = .empty;
    defer spans.deinit(gpa);
    var k: i64 = 0;
    for (0..other.ringCount()) |ri| {
        const ring = other.ring(@intCast(ri));
        for (0..ring.xs.len) |i| {
            defer k += 1;
            const e = geom.ops.ringEdge(ring.xs, ring.ys, i);
            for (wide) |r| {
                var gap: i64 = undefined;
                var lo: i64 = undefined;
                var hi: i64 = undefined;
                if (e.a.x == e.b.x) {
                    gap = if (e.a.x >= r.xhi) e.a.x - r.xhi else if (e.a.x <= r.xlo) r.xlo - e.a.x else continue;
                    lo = @max(r.ylo, @min(e.a.y, e.b.y));
                    hi = @min(r.yhi, @max(e.a.y, e.b.y));
                } else {
                    gap = if (e.a.y >= r.yhi) e.a.y - r.yhi else if (e.a.y <= r.ylo) r.ylo - e.a.y else continue;
                    lo = @max(r.xlo, @min(e.a.x, e.b.x));
                    hi = @min(r.xhi, @max(e.a.x, e.b.x));
                }
                if (gap <= within and lo < hi) try spans.append(gpa, .{ k, gap, lo, hi });
            }
        }
    }
    std.mem.sortUnstable([4]i64, spans.items, {}, struct {
        fn less(_: void, x: [4]i64, y: [4]i64) bool {
            return std.mem.order(i64, &x, &y) == .lt;
        }
    }.less);
    var current: ?[4]i64 = null;
    for (spans.items) |sp| {
        if (current) |*cur| if (cur[0] == sp[0] and cur[1] == sp[1] and sp[2] <= cur[3]) {
            cur[3] = @max(cur[3], sp[3]);
            continue;
        };
        if (current) |cur| try out.append(gpa, .{ .gap = cur[1], .run = cur[3] - cur[2] });
        current = sp;
    }
    if (current) |cur| try out.append(gpa, .{ .gap = cur[1], .run = cur[3] - cur[2] });
}

/// The squared distance between parts `pa` of `a` and `pb` of `b`; `whole`
/// is the two rows' own.
fn partsGap(gpa: Allocator, store: *const GeometryStore, a: PolyId, b: PolyId, pa: Part, pb: Part, whole: DbuArea) Allocator.Error!DbuArea {
    if (pa == null and pb == null) return whole;
    if (pb == null) return parts.rectsRingDist2(pa.?, store.polyVerts(b));
    if (pa == null) return parts.rectsRingDist2(pb.?, store.polyVerts(a));
    var n: Nearest = .{};
    defer n.deinit(gpa);
    try addRectRect(&n, gpa, pa.?, pb.?);
    return if (n.result()) |f| f.d2 else std.math.maxInt(DbuArea);
}

/// Where a pair measured `d2` apart between parts `pa` and `pb` is marked.
fn partsAt(gpa: Allocator, store: *const GeometryStore, a: PolyId, b: PolyId, pa: Part, pb: Part, d2: DbuArea) Allocator.Error!Point {
    if (pa == null and pb == null) return proximity.wholeAt(gpa, store, a, b, d2);
    var n: Nearest = .{};
    defer n.deinit(gpa);
    if (pb == null) {
        try parts.addRectRing(&n, gpa, pa.?, store.polyVerts(b));
    } else if (pa == null) {
        try parts.addRectRing(&n, gpa, pb.?, store.polyVerts(a));
    } else try addRectRect(&n, gpa, pa.?, pb.?);
    return parts.marker(store, a, b, d2, n.result());
}

/// Every side of each of `ra` paired with every side of each of `rb`.
fn addRectRect(n: *Nearest, gpa: Allocator, ra: []const Bbox, rb: []const Bbox) Allocator.Error!void {
    for (ra) |p| for (rb) |q| for (parts.rectSides(p)) |side| for (parts.rectSides(q)) |other| {
        try n.add(gpa, side, other);
    };
}
