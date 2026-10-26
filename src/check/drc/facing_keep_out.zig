//! The boxes in front of an end of line: LEF58 keep-out (`EOLKEEPOUT`, the
//! other figures' material or corners inside the end's box) and extension
//! spacing (`EOLEXTENSIONSPACING`, ends swept out of their figures and held
//! apart). In: one rectilinear layer. Out: one violation per end and
//! intruding figure. Ported from crates/check/src/drc/rules/facing.rs
//! (`eol_keep_out`, `side_zones`, `eol_extension_spacing`).
//!
//! Contents:
//! - `pub fn eolKeepOut(c: *const Ctx, r: EolKeepOut) Error!Verdict`
//! - `pub fn eolExtensionSpacing(c: *const Ctx, r: EolExtensionSpacing) Error!Verdict`

const std = @import("std");
const Allocator = std.mem.Allocator;
const geom = @import("geom");
const DbuArea = geom.DbuArea;
const Bbox = geom.Bbox;
const report = @import("../report.zig");
const Verdict = report.Verdict;
const Measurement = report.Measurement;
const rects = @import("../rects.zig");
const proximity = @import("../proximity.zig");
const rows = @import("rows.zig");
const scratch = @import("scratch.zig");
const Ctx = scratch.Ctx;
const Error = scratch.Error;
const fe = @import("facing_edges.zig");
const Edge = fe.Edge;

/// One figure found in an end's box: what it measures and the box of it.
const Found = struct { figure: u32, measured: Measurement, bounds: Bbox };

/// One figure closer than the spacing to a swept end: the squared gap and
/// the two swept boxes.
const Close = struct { figure: u32, d2: i128, a: Bbox, b: Bbox };

/// Every other figure whose material overlaps an end of line's box with a
/// positive area (with `corner_only`, whose corners lie strictly inside it),
/// one finding per end and figure, measuring that area (corner count).
/// `examined` counts ends of line.
pub fn eolKeepOut(c: *const Ctx, r: rows.EolKeepOut) Error!Verdict {
    const gpa = c.gpa;
    if (!try scratch.mergedOwners(c, r.layer)) return report.refused;
    const figures = &c.s.p.layer_out;
    const owners = c.s.owners.items;
    var edges: std.ArrayList(Edge) = .empty;
    defer edges.deinit(gpa);
    try fe.figureEdgesInto(gpa, figures, &edges);
    // CORNERONLY reads the figures' vertices, by x.
    var vertices: std.ArrayList([3]i64) = .empty;
    defer vertices.deinit(gpa);
    if (r.corner_only) {
        for (0..figures.len()) |figure| {
            const poly = figures.get(@intCast(figure));
            for (0..poly.ringCount()) |k| {
                const ring = poly.ring(@intCast(k));
                for (ring.xs, ring.ys) |x, y| try vertices.append(gpa, .{ x, y, @intCast(figure) });
            }
        }
        std.mem.sortUnstable([3]i64, vertices.items, {}, lessArr(3));
    }
    var material: rects.SortedRects = .{};
    defer material.deinit(gpa);
    try rects.figureRectsInto(gpa, figures, &material);
    var found: std.ArrayList(Found) = .empty;
    defer found.deinit(gpa);
    var inside: std.ArrayList([3]i64) = .empty;
    defer inside.deinit(gpa);
    var examined: u64 = 0;
    for (edges.items) |end| {
        if (!(end.convex and end.length() < r.eol_width)) continue;
        examined += 1;
        const zone = fe.keepOutBox(end, r.backward, r.side, r.forward);
        found.clearRetainingCapacity();
        inside.clearRetainingCapacity();
        if (r.corner_only) {
            for (vertices.items) |v| {
                if (v[0] <= zone.xlo) continue;
                if (v[0] >= zone.xhi) break;
                if (zone.ylo < v[1] and v[1] < zone.yhi and v[2] != end.figure) try inside.append(gpa, .{ v[2], v[0], v[1] });
            }
            std.mem.sortUnstable([3]i64, inside.items, {}, lessArr(3));
            var at: usize = 0;
            while (at < inside.items.len) {
                var stop = at;
                var bounds = Bbox.empty;
                while (stop < inside.items.len and inside.items[stop][0] == inside.items[at][0]) : (stop += 1) bounds = bounds.merge(Bbox.point(inside.items[stop][1], inside.items[stop][2]));
                try found.append(gpa, .{ .figure = @intCast(inside.items[at][0]), .measured = .count(@intCast(stop - at)), .bounds = bounds });
                at = stop;
            }
        } else {
            var parts: std.ArrayList(rects.SortedRects.Hit) = .empty;
            defer parts.deinit(gpa);
            var hits = material.overlapping(zone);
            while (hits.next()) |h| if (h.label != end.figure) try parts.append(gpa, h);
            std.mem.sort(rects.SortedRects.Hit, parts.items, {}, struct {
                fn less(_: void, x: rects.SortedRects.Hit, y: rects.SortedRects.Hit) bool {
                    return x.label < y.label;
                }
            }.less);
            var at: usize = 0;
            while (at < parts.items.len) {
                var stop = at;
                var area: DbuArea = 0;
                var bounds = Bbox.empty;
                while (stop < parts.items.len and parts.items[stop].label == parts.items[at].label) : (stop += 1) {
                    area += parts.items[stop].clip.area();
                    bounds = bounds.merge(parts.items[stop].clip);
                }
                try found.append(gpa, .{ .figure = parts.items[at].label, .measured = .area(area), .bounds = bounds });
                at = stop;
            }
        }
        for (found.items) |f| {
            // EXCEPTWITHIN: a figure reaching into a side zone is exempt.
            if (r.except_within) |w| if (inSideZone(&material, end, r, w, f.figure)) continue;
            const limit: Measurement = if (f.measured.kind == .count) .count(0) else .area(0);
            try c.push(.{ .rule = c.rule, .layer = r.layer, .severity = .@"error", .at = rects.centre(f.bounds), .measured = f.measured, .limit = limit, .shape_a = owners[end.figure], .shape_b = owners[f.figure] });
        }
    }
    return scratch.ran(examined);
}

/// Each end of line, swept out of its figure by its row's extension,
/// against the edges of other figures reaching past its line, each swept too
/// when it is an end (`end_to_end` for two ends head-on); one finding per
/// end and figure closer than the limit. `examined` counts ends.
pub fn eolExtensionSpacing(c: *const Ctx, r: rows.EolExtensionSpacing) Error!Verdict {
    const gpa = c.gpa;
    if (!try scratch.mergedOwners(c, r.layer)) return report.refused;
    const owners = c.s.owners.items;
    var edges: std.ArrayList(Edge) = .empty;
    defer edges.deinit(gpa);
    try fe.figureEdgesInto(gpa, &c.s.p.layer_out, &edges);
    const side: ?rows.SideLength = if (r.side_length) |s| .{ .length = s.length, .maximum = false, .two_sides = s.two_sides } else null;
    var longest: i64 = 0;
    for (r.rows) |maybe| if (maybe) |row| {
        longest = @max(longest, @max(sweep(row, true), sweep(row, false)));
    };
    const space = r.limit;
    var near: std.ArrayList(u32) = .empty;
    defer near.deinit(gpa);
    var found: std.ArrayList(Close) = .empty;
    defer found.deinit(gpa);
    var examined: u64 = 0;
    for (edges.items) |end| {
        const own = rowOf(r.rows, side, end) orelse continue;
        examined += 1;
        found.clearRetainingCapacity();
        // Whatever a sweep of up to `longest` can bring closer than `space`.
        try fe.nearInto(gpa, edges.items, fe.keepOutBox(end, 0, space + longest, 2 * longest + space), &near);
        for (near.items) |k| {
            const f = edges.items[k];
            if (f.figure == end.figure or !past(end, f)) continue;
            const theirs = rowOf(r.rows, side, f);
            const head_on = theirs != null and f.vertical == end.vertical and f.faces_up != end.faces_up and @max(f.lo, end.lo) < @min(f.hi, end.hi);
            const a = fe.keepOutBox(end, 0, 0, sweep(own, head_on));
            const b = fe.keepOutBox(f, 0, 0, if (theirs) |t| sweep(t, head_on) else 0);
            const dx: i128 = @max(@max(b.xlo - a.xhi, a.xlo - b.xhi), 0);
            const dy: i128 = @max(@max(b.ylo - a.yhi, a.ylo - b.yhi), 0);
            const d2 = dx * dx + dy * dy;
            if (d2 < geom.mulWide(space, space)) try found.append(gpa, .{ .figure = f.figure, .d2 = d2, .a = a, .b = b });
        }
        std.mem.sort(Close, found.items, {}, struct {
            fn less(_: void, x: Close, y: Close) bool {
                return x.figure < y.figure or (x.figure == y.figure and x.d2 < y.d2);
            }
        }.less);
        var at: usize = 0;
        while (at < found.items.len) {
            const first = found.items[at];
            // Marked between the unions of the nearest boxes on each side.
            var a = Bbox.empty;
            var b = Bbox.empty;
            var stop = at;
            while (stop < found.items.len and found.items[stop].figure == first.figure) : (stop += 1) {
                if (found.items[stop].d2 != first.d2) continue;
                a = a.merge(found.items[stop].a);
                b = b.merge(found.items[stop].b);
            }
            try c.push(proximity.spacingViolation(c.rule, r.layer, owners[end.figure], owners[first.figure], .{ .d2 = first.d2, .at = rects.gapMidpoint(a, b) }, space));
            at = stop;
        }
    }
    return scratch.ran(examined);
}

// ---- private ----

fn sweep(row: rows.EolExtension, head_on: bool) i64 {
    return if (head_on and row.end_to_end != null) row.end_to_end.? else row.extension;
}

/// The row an edge takes as an end: the first wider than it, for a convex
/// edge whose sides hold.
fn rowOf(table: [3]?rows.EolExtension, side: ?rows.SideLength, e: Edge) ?rows.EolExtension {
    if (!e.convex or !fe.sidesHold(e, side)) return null;
    for (table) |maybe| if (maybe) |row| if (e.length() < row.eol_width) return row;
    return null;
}

/// Whether `f` reaches strictly past `end`'s line, out of its figure.
fn past(end: Edge, f: Edge) bool {
    const lo = if (f.vertical == end.vertical) f.pos else f.lo;
    const hi = if (f.vertical == end.vertical) f.pos else f.hi;
    return if (end.faces_up) hi > end.pos else lo < end.pos;
}

/// Whether `figure`'s material reaches into a side zone of `end`: beside
/// each corner, from `low` to `high` past it along its line, across from
/// `backward` behind its line to `forward` past it.
fn inSideZone(material: *const rects.SortedRects, end: Edge, r: rows.EolKeepOut, w: rows.Pair, figure: u32) bool {
    const depth = fe.keepOutBox(end, r.backward, 0, r.forward);
    const spans = [2][2]i64{ .{ end.lo - w[1], end.lo - w[0] }, .{ end.hi + w[0], end.hi + w[1] } };
    for (spans) |span| {
        var zone = depth;
        const lo = clamped(span[0]);
        const hi = clamped(span[1]);
        if (end.vertical) {
            zone.ylo = lo;
            zone.yhi = hi;
        } else {
            zone.xlo = lo;
            zone.xhi = hi;
        }
        var hits = material.overlapping(zone);
        while (hits.next()) |h| if (h.label == figure) return true;
    }
    return false;
}

fn lessArr(comptime n: usize) fn (void, [n]i64, [n]i64) bool {
    return struct {
        fn less(_: void, x: [n]i64, y: [n]i64) bool {
            return std.mem.order(i64, &x, &y) == .lt;
        }
    }.less;
}

fn clamped(v: i64) i64 {
    return std.math.clamp(v, -geom.max_abs_dbu, geom.max_abs_dbu);
}
