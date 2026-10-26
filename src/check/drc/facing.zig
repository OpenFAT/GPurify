//! Spacing read off facing edges of the merged layer: by the classes of
//! both edges' lengths, in a forbidden range, and in front of an end of line
//! as LEF defines it (`SPACING ENDOFLINE ... WITHIN`, `PARALLELEDGE`,
//! `TWOEDGES`, `ENDTOEND` and the `LEF58_SPACING ENDOFLINE` qualifiers). In:
//! one rectilinear layer. Out: one violation per pair of figures, at the
//! middle of the stretch its nearest offending edges face over. Ported from
//! crates/check/src/drc/rules/facing.rs (`tip_spacing_table`,
//! `forbidden_spacing`, `eol_within_spacing`, `narrow_beyond`,
//! `encloses_cut`, `beside`).
//!
//! Contents:
//! - `pub fn tipSpacingTable(c: *const Ctx, r: LayerTable) Error!Verdict`
//! - `pub fn forbiddenSpacing(c: *const Ctx, r: ForbiddenSpacing) Error!Verdict`
//! - `pub fn eolWithinSpacing(c: *const Ctx, r: EolWithinSpacing) Error!Verdict`
//! - private visitors with the `visit` method `eachFacing` calls

const std = @import("std");
const Allocator = std.mem.Allocator;
const geom = @import("geom");
const Dbu = geom.Dbu;
const ValidatedLayer = geom.ValidatedLayer;
const report = @import("../report.zig");
const Verdict = report.Verdict;
const proximity_inside = @import("../proximity_inside.zig");
const rows = @import("rows.zig");
const tables = @import("tables.zig");
const scratch = @import("scratch.zig");
const Ctx = scratch.Ctx;
const Error = scratch.Error;
const fe = @import("facing_edges.zig");
const Edge = fe.Edge;
const Hit = fe.Hit;

/// Facing pairs judged by the classes of both edges' lengths.
const TipVisitor = struct {
    gpa: Allocator,
    table: tables.ClassTable,
    hits: *std.ArrayList(Hit),
    examined: u64 = 0,

    pub fn visit(v: *TipVisitor, e: Edge, f: Edge, gap: i64, lo: i64, hi: i64) Allocator.Error!void {
        if (e.figure == f.figure) return;
        v.examined += 1;
        const need = v.table.at(classOf(v.table, e.length()), classOf(v.table, f.length()));
        if (gap < need) try v.hits.append(v.gpa, fe.hit(e, f, gap, lo, hi, need));
    }

    /// The last class whose threshold the length reaches; the first is 0.
    fn classOf(t: tables.ClassTable, len: i64) usize {
        var k: usize = 0;
        while (k + 1 < t.class.len and t.class[k + 1] <= len) k += 1;
        return k;
    }
};

/// Facing pairs running past `prl` with a gap in `[min, max]`.
const ForbiddenVisitor = struct {
    gpa: Allocator,
    r: rows.ForbiddenSpacing,
    hits: *std.ArrayList(Hit),
    examined: u64 = 0,

    pub fn visit(v: *ForbiddenVisitor, e: Edge, f: Edge, gap: i64, lo: i64, hi: i64) Allocator.Error!void {
        if (e.figure == f.figure or hi - lo <= v.r.prl) return;
        v.examined += 1;
        if (gap >= v.r.min) try v.hits.append(v.gpa, fe.hit(e, f, gap, lo, hi, v.r.max + 1));
    }
};

/// Spacing between facing edges of different figures by the classes of both
/// edges' lengths (ASAP7 M1.S.1 to M1.S.5). `examined` counts facing pairs
/// in different figures closer than the table's largest cell.
pub fn tipSpacingTable(c: *const Ctx, r: rows.LayerTable) Error!Verdict {
    if (!try scratch.mergedOwners(c, r.layer)) return report.refused;
    const table = c.rs.classTable(r.table);
    var edges: std.ArrayList(Edge) = .empty;
    defer edges.deinit(c.gpa);
    try fe.figureEdgesInto(c.gpa, &c.s.p.layer_out, &edges);
    var hits: std.ArrayList(Hit) = .empty;
    defer hits.deinit(c.gpa);
    var v: TipVisitor = .{ .gpa = c.gpa, .table = table, .hits = &hits };
    try fe.eachFacing(edges.items, std.mem.max(Dbu, table.space) - 1, &v);
    try fe.reportPairs(c, r.layer, c.s.owners.items, hits.items);
    return scratch.ran(v.examined);
}

/// A gap from `min` to `max`, both included, between facing edges of
/// different figures running alongside for more than `prl`
/// (`LEF58_TWOWIRESFORBIDDENSPACING`). `examined` counts the facing pairs
/// in different figures at most `max` apart running more than `prl`.
pub fn forbiddenSpacing(c: *const Ctx, r: rows.ForbiddenSpacing) Error!Verdict {
    if (!try scratch.mergedOwners(c, r.layer)) return report.refused;
    var edges: std.ArrayList(Edge) = .empty;
    defer edges.deinit(c.gpa);
    try fe.figureEdgesInto(c.gpa, &c.s.p.layer_out, &edges);
    var hits: std.ArrayList(Hit) = .empty;
    defer hits.deinit(c.gpa);
    var v: ForbiddenVisitor = .{ .gpa = c.gpa, .r = r, .hits = &hits };
    try fe.eachFacing(edges.items, r.max, &v);
    try fe.reportPairs(c, r.layer, c.s.owners.items, hits.items);
    return scratch.ran(v.examined);
}

/// LEF end-of-line spacing: each end of line the rule applies to holds the
/// facing edges of other figures in its widened keep-out to `limit`, or to
/// `end_to_end` when the facing edge is an end too, with the LEF58
/// qualifiers. `examined` counts the ends the rule applies to.
pub fn eolWithinSpacing(c: *const Ctx, r: rows.EolWithinSpacing) Error!Verdict {
    const gpa = c.gpa;
    const q = r.lef58;
    var cut_edges: std.ArrayList(Edge) = .empty;
    defer cut_edges.deinit(gpa);
    if (q.enclose_cut) |cut| {
        var cuts: ValidatedLayer = .empty;
        defer cuts.deinit(gpa);
        if (!try proximity_inside.mergedInto(gpa, c.store, cut.cut, &c.s.p, &cuts)) return report.refused;
        try fe.figureEdgesInto(gpa, &cuts, &cut_edges);
    }
    if (!try scratch.mergedOwners(c, r.layer)) return report.refused;
    var edges: std.ArrayList(Edge) = .empty;
    defer edges.deinit(gpa);
    try fe.figureEdgesInto(gpa, &c.s.p.layer_out, &edges);
    var reach: i64 = r.limit;
    if (r.end_to_end) |v| reach = @max(reach, v);
    if (q.wrong_dir) |v| reach = @max(reach, v.space);
    if (q.end_prl) |v| reach = @max(reach, v[0]);
    var hits: std.ArrayList(Hit) = .empty;
    defer hits.deinit(gpa);
    var examined: u64 = 0;
    for (edges.items) |end| {
        if (!isEnd(end, r.eol_width)) continue;
        if (r.parallel) |p| if (!beside(edges.items, end, p, r.within, q)) continue;
        if (!fe.sidesHold(end, q.side_length)) continue;
        examined += 1;
        // The facing edges out in front: facing back at it, from depth 0 to
        // just under `reach`.
        const first = if (end.faces_up) end.pos else end.pos - reach + 1;
        const last = if (end.faces_up) end.pos + reach - 1 else end.pos;
        // WRONGDIRSPACING: an end lying along the preferred direction.
        const own = if (q.wrong_dir) |w| (if (end.vertical != w.horizontal) w.space else r.limit) else r.limit;
        var at = fe.bandStart(edges.items, end.vertical, !end.faces_up, first);
        while (at < edges.items.len) : (at += 1) {
            const f = edges.items[at];
            if (f.vertical != end.vertical or f.faces_up == end.faces_up or f.pos > last) break;
            if (f.figure == end.figure) continue;
            const depth: i64 = @intCast(@abs(f.pos - end.pos));
            var lo: i64 = undefined;
            var hi: i64 = undefined;
            var need: i64 = undefined;
            if (q.end_prl != null and depth >= own) {
                // ENDPRLSPACING: past the end's own space, a run along the
                // end itself, positive and at most `run`.
                const ep = q.end_prl.?;
                lo = @max(f.lo, end.lo);
                hi = @min(f.hi, end.hi);
                if (hi <= lo or hi - lo > ep[1]) continue;
                need = ep[0];
            } else {
                const ends: ?Dbu = if (isEnd(f, r.eol_width)) r.end_to_end else null;
                // ENDTOEND EXTENSION: both spans widened by it.
                const widen = if (ends != null and q.extension != null) 2 * q.extension.? else r.within;
                lo = @max(f.lo, end.lo - widen);
                hi = @min(f.hi, end.hi + widen);
                if (hi <= lo) continue;
                need = ends orelse own;
            }
            if (depth >= need) continue;
            if (q.opposite_width) |w| if (!narrowBeyond(edges.items, end, f, lo, hi, w)) continue;
            if (!enclosesCut(cut_edges.items, end, f, q.enclose_cut)) continue;
            try hits.append(gpa, fe.hit(end, f, depth, lo, hi, need));
        }
    }
    try fe.reportPairs(c, r.layer, c.s.owners.items, hits.items);
    return scratch.ran(examined);
}

// ---- private ----

fn isEnd(e: Edge, eol_width: Dbu) bool {
    return e.convex and e.length() < eol_width;
}

/// `OPPOSITEWIDTH`: whether the wire beyond the end, whose facing edge is
/// `f`, is narrower than `width` over part of `lo..hi`: an edge facing the
/// way `end` faces, less than `width` past `f` into its material,
/// overlapping the stretch by a positive length.
fn narrowBeyond(edges: []const Edge, end: Edge, f: Edge, lo: i64, hi: i64, width: i64) bool {
    // `f` faces back at the end, so its material lies further out.
    const from = if (end.faces_up) f.pos + 1 else f.pos - width + 1;
    const to = if (end.faces_up) f.pos + width - 1 else f.pos - 1;
    var at = fe.bandStart(edges, end.vertical, end.faces_up, from);
    while (at < edges.len) : (at += 1) {
        const g = edges[at];
        if (g.vertical != end.vertical or g.faces_up != end.faces_up or g.pos > to) break;
        if (@max(g.lo, lo) < @min(g.hi, hi)) return true;
    }
    return false;
}

/// `ENCLOSECUT`: whether a cut edge facing the way `end` faces, its line on
/// `end`'s or behind it into the material by less than `within`, its span
/// touching `end`'s, lies less than `space` from the facing edge `f`; with
/// `all`, every such edge, and at least one. True with no `ENCLOSECUT`.
fn enclosesCut(cuts: []const Edge, end: Edge, f: Edge, enclose: ?rows.EncloseCut) bool {
    const e = enclose orelse return true;
    // Behind the end is where its material lies: below a line facing up.
    const from = if (end.faces_up) end.pos - e.within + 1 else end.pos;
    const to = if (end.faces_up) end.pos else end.pos + e.within - 1;
    const space2 = geom.mulWide(e.space, e.space);
    var seen: u32 = 0;
    var near_count: u32 = 0;
    var at = fe.bandStart(cuts, end.vertical, end.faces_up, from);
    while (at < cuts.len) : (at += 1) {
        const cut = cuts[at];
        if (cut.vertical != end.vertical or cut.faces_up != end.faces_up or cut.pos > to) break;
        if (!(cut.lo <= end.hi and end.lo <= cut.hi)) continue;
        const across = cut.pos - f.pos;
        const along = @max(@max(cut.lo, f.lo) - @min(cut.hi, f.hi), 0);
        seen += 1;
        near_count += @intFromBool(geom.mulWide(across, across) + geom.mulWide(along, along) < space2);
    }
    return if (e.all) seen > 0 and near_count == seen else near_count > 0;
}

/// Whether a parallel edge runs beside the line ending at `end` (LEF
/// `PARALLELEDGE`): at its low corner an edge facing up toward the line's
/// side, at its high corner one facing down, its line less than `space` out
/// from the side's, its span overlapping the stretch from `within` behind
/// the end's line to `eol_within` past it. Both corners with `two_edges`.
fn beside(edges: []const Edge, end: Edge, parallel: rows.EolParallel, eol_within: i64, q: rows.Eol58) bool {
    const space = parallel.space - if (q.subtract_eol_width) end.length() else 0;
    const back = parallel.within;
    const wlo = if (end.faces_up) end.pos - back else end.pos - eol_within;
    const whi = if (end.faces_up) end.pos + eol_within else end.pos + back;
    const counts = struct {
        fn f(qq: rows.Eol58, side: i64) bool {
            return if (qq.parallel_min_length) |m| side >= m else true;
        }
    }.f;
    const low = counts(q, end.sides[0]) and acrossEdge(edges, end, true, end.lo - space + 1, end.lo, wlo, whi);
    const high = counts(q, end.sides[1]) and acrossEdge(edges, end, false, end.hi, end.hi + space - 1, wlo, whi);
    return if (parallel.two_edges) low and high else low or high;
}

/// An edge across the end, facing `faces_up`, its line from `from` to
/// `to`, overlapping `wlo..whi`.
fn acrossEdge(edges: []const Edge, end: Edge, faces_up: bool, from: i64, to: i64, wlo: i64, whi: i64) bool {
    var at = fe.bandStart(edges, !end.vertical, faces_up, from);
    while (at < edges.len) : (at += 1) {
        const f = edges[at];
        if (f.vertical == end.vertical or f.faces_up != faces_up or f.pos > to) break;
        if (@max(f.lo, wlo) < @min(f.hi, whi)) return true;
    }
    return false;
}
