//! Multi-patterning: can a layer be split across `colors` masks, honour its
//! anchors, or be decomposed for self-aligned double patterning? In: one
//! layer; touching rows merge into one figure (node), figures closer than
//! the spacing conflict (edge), and a figure whose own notch is narrower
//! conflicts with itself (a loop). Out: one violation per uncolourable
//! layer, anchor conflict, odd SADP cycle, even-track width or line-end
//! fault. A colouring search out of budget is refused, never clean. Ported
//! from crates/check/src/drc/rules/patterning.rs (`conflict_graph`,
//! `multi_patterning`, `anchored_patterning`, `sadp`, `sadp_line_end`,
//! `root_of`); the colouring itself is `patterning_color.zig`'s.
//!
//! Contents:
//! - `pub fn multiPatterning(c: *const Ctx, r: MultiPatterning) Error!Verdict`
//! - `pub fn anchoredPatterning(c: *const Ctx, r: AnchoredPatterning) Error!Verdict`
//! - `pub fn sadp(c: *const Ctx, r: Sadp) Error!Verdict`
//! - `pub fn sadpLineEnd(c: *const Ctx, r: SadpLineEnd) Error!Verdict`

const std = @import("std");
const Allocator = std.mem.Allocator;
const geom = @import("geom");
const Dbu = geom.Dbu;
const Bbox = geom.Bbox;
const LayerId = geom.LayerId;
const PolyId = geom.PolyId;
const ValidatedLayer = geom.ValidatedLayer;
const report = @import("../report.zig");
const Verdict = report.Verdict;
const rects = @import("../rects.zig");
const proximity = @import("../proximity.zig");
const rows = @import("rows.zig");
const scratch = @import("scratch.zig");
const Ctx = scratch.Ctx;
const Error = scratch.Error;
const color = @import("patterning_color.zig");

/// An SADP band edge: different colours (`odd`) or the same.
const BandEdge = struct { a: u32, b: u32, odd: bool };

/// A line: along x (`horizontal`) or y, and its box.
const Line = struct { horizontal: bool, b: Bbox };

/// An empty layer's verdict.
const skipped: Verdict = .{ .outcome = .{ .skipped = .empty_layer }, .examined = 0 };

/// Colourability of one layer's merged figures. One violation (on the node
/// `infeasible` names, measured `colors + 1`) per uncolourable layer.
/// `examined` counts shapes, also when refused; an empty layer is skipped.
pub fn multiPatterning(c: *const Ctx, r: rows.MultiPatterning) Error!Verdict {
    const shapes = c.store.polysOnLayer(r.layer);
    if (shapes.len() == 0) return skipped;
    var figure_node: std.ArrayList(u32) = .empty;
    defer figure_node.deinit(c.gpa);
    if (!try conflictGraph(c, r.layer, r.color_spacing, &figure_node)) return refusedAfter(shapes.len());
    var colours: std.ArrayList(u8) = .empty;
    defer colours.deinit(c.gpa);
    switch (try color.colorInto(c.gpa, shapes.len(), c.s.p.edges.items, r.colors, &colours)) {
        .complete => {},
        .exhausted => return refusedAfter(shapes.len()),
        .infeasible => |node| {
            const poly: PolyId = @fromBackingInt(shapes.start + node);
            try c.finding(r.layer, rects.centre(c.store.polyBbox(poly)), .count(@as(u32, r.colors) + 1), .count(r.colors), poly);
        },
    }
    return scratch.ran(shapes.len());
}

/// Anchor conflicts of one layer: per component of its conflict graph that
/// `colors` masks can split, but not with every anchored figure on its
/// anchor's mask, one violation. Figure `f` is anchored to mask `i + 1`
/// when it shares area with a shape of `anchors[i]`. Two masks name the
/// pair whose parity contradicts their anchors (Calibre's anchor path) at
/// their boxes' gap, or a figure on two masks' anchors at its centre; more
/// name the lowest anchored figure. A component no colouring splits is
/// `multi_patterning`'s. `examined` counts the layer's shapes.
pub fn anchoredPatterning(c: *const Ctx, r: rows.AnchoredPatterning) Error!Verdict {
    const gpa = c.gpa;
    const store = c.store;
    const s = c.s;
    const shapes = store.polysOnLayer(r.layer);
    if (shapes.len() == 0) return skipped;
    var figure_node: std.ArrayList(u32) = .empty;
    defer figure_node.deinit(gpa);
    if (!try conflictGraph(c, r.layer, r.color_spacing, &figure_node)) return refusedAfter(shapes.len());
    const n = shapes.len();
    // Anchor bits per node, bit `i` for `anchors[i]`.
    const anchor = try gpa.alloc(u8, n);
    defer gpa.free(anchor);
    @memset(anchor, 0);
    const hit = try gpa.alloc(bool, s.p.layer_out.len());
    defer gpa.free(hit);
    var merged: ValidatedLayer = .empty;
    defer merged.deinit(gpa);
    for (r.anchors, 0..) |maybe, bit| {
        const marker = maybe orelse continue;
        const drawn = try s.p.validated.get(gpa, store, marker) orelse return refusedAfter(n);
        try geom.boolean.unionInto(gpa, drawn, &ValidatedLayer.empty, &merged);
        try geom.derive.overlappingFlags(gpa, &s.p.layer_out, &merged, hit);
        for (figure_node.items, hit) |node, h| if (h) {
            anchor[node] |= @as(u8, 1) << @intCast(bit);
        };
    }
    // Components by union-find over the conflicts, each in node order.
    const parent = try gpa.alloc(u32, n);
    defer gpa.free(parent);
    for (parent, 0..) |*p, i| p.* = @intCast(i);
    const edges = s.p.edges.items;
    for (edges) |e| {
        const ra = rootOf(parent, e[0]);
        const rb = rootOf(parent, e[1]);
        parent[@max(ra, rb)] = @min(ra, rb);
    }
    const members = try gpa.alloc([2]u32, n);
    defer gpa.free(members);
    for (members, 0..) |*m, node| m.* = .{ rootOf(parent, @intCast(node)), @intCast(node) };
    std.mem.sortUnstable([2]u32, members, {}, lessPair);
    const local = try gpa.alloc(u32, n);
    defer gpa.free(local);
    var group_edges: std.ArrayList([2]u32) = .empty;
    defer group_edges.deinit(gpa);
    var held: std.ArrayList(u8) = .empty;
    defer held.deinit(gpa);
    var colours: std.ArrayList(u8) = .empty;
    defer colours.deinit(gpa);
    var outcome: report.Outcome = .ran;
    var at: usize = 0;
    while (at < members.len) {
        var end = at + 1;
        while (end < members.len and members[end][0] == members[at][0]) end += 1;
        const group = members[at..end];
        at = end;
        var anchored = false;
        for (group) |m| anchored = anchored or anchor[m[1]] != 0;
        if (!anchored) continue;
        for (group, 0..) |m, i| local[m[1]] = @intCast(i);
        group_edges.clearRetainingCapacity();
        held.clearRetainingCapacity();
        // ponytail: each component rescans every conflict; a CSR by root if
        // anchored layers grow large.
        for (edges) |e| if (rootOf(parent, e[0]) == group[0][0]) try group_edges.append(gpa, .{ local[e[0]], local[e[1]] });
        for (group) |m| try held.append(gpa, anchor[m[1]]);
        const conflict = switch (try color.anchorConflict(gpa, @intCast(group.len), group_edges.items, held.items, r.colors, &colours)) {
            .honoured, .unsplittable => continue,
            .exhausted => {
                outcome = .refused;
                continue;
            },
            .conflict => |k| k,
        };
        const pa: PolyId = @fromBackingInt(shapes.start + group[conflict.node][1]);
        const pb: PolyId = if (conflict.other) |o| @fromBackingInt(shapes.start + group[o][1]) else report.no_shape;
        const where = if (conflict.other != null) rects.gapMidpoint(store.polyBbox(pa), store.polyBbox(pb)) else rects.centre(store.polyBbox(pa));
        try c.push(.{ .rule = c.rule, .layer = r.layer, .severity = .@"error", .at = where, .measured = .count(@as(u32, r.colors) + 1), .limit = .count(r.colors), .shape_a = pa, .shape_b = pb });
    }
    return .{ .outcome = outcome, .examined = n };
}

/// Self-aligned double patterning decomposability of one layer: the
/// colour-band graph and, with `track`, the odd-track width rule. Two
/// figures closer than `different` take different colours, two at least
/// that far but closer than `same` one colour; union-find with parity finds
/// the first edge, in ascending figure order, closing an odd cycle of a
/// component, reported once per component between its two figures, at
/// their boxes' gap. A figure whose own notch is under `different` is
/// reported at its centre. Each measures 1 odd cycle against 0. With
/// `track = (w, s)`, a figure whose narrowest width is over `w` and not
/// `(2k + 1) w + 2k s` spans an even number of tracks: reported at its
/// centre, measuring its width against the largest legal width under it.
/// `examined` counts the layer's rows.
pub fn sadp(c: *const Ctx, r: rows.Sadp) Error!Verdict {
    const gpa = c.gpa;
    const store = c.store;
    const s = c.s;
    const shapes = store.polysOnLayer(r.layer);
    if (shapes.len() == 0) return skipped;
    var figure_node: std.ArrayList(u32) = .empty;
    defer figure_node.deinit(gpa);
    if (!try conflictGraph(c, r.layer, @max(r.same, r.different), &figure_node)) return refusedAfter(shapes.len());
    const n = shapes.len();
    const different2 = geom.mulWide(r.different, r.different);
    const reach2 = @max(geom.mulWide(r.same, r.same), different2);
    // One edge per pair of figures, at their least distance.
    var edges: std.ArrayList(BandEdge) = .empty;
    defer edges.deinit(gpa);
    for (s.p.pairs.items, s.p.dists.items) |p, d2| {
        const fa = s.p.labels.items[@backingInt(p.a) - shapes.start];
        const fb = s.p.labels.items[@backingInt(p.b) - shapes.start];
        if (fa != fb and d2 < reach2) try edges.append(gpa, .{ .a = @min(fa, fb), .b = @max(fa, fb), .odd = d2 < different2 });
    }
    // The least distance decides a pair's band: odd sorts first.
    std.mem.sortUnstable(BandEdge, edges.items, {}, struct {
        fn less(_: void, p: BandEdge, q: BandEdge) bool {
            if (p.a != q.a) return p.a < q.a;
            if (p.b != q.b) return p.b < q.b;
            return p.odd and !q.odd;
        }
    }.less);
    const parent = try gpa.alloc(u32, n);
    defer gpa.free(parent);
    for (parent, 0..) |*p, i| p.* = @intCast(i);
    const parity = try gpa.alloc(bool, n);
    defer gpa.free(parity);
    @memset(parity, false);
    const reported = try gpa.alloc(bool, n);
    defer gpa.free(reported);
    @memset(reported, false);
    for (edges.items, 0..) |e, i| {
        if (i > 0 and edges.items[i - 1].a == e.a and edges.items[i - 1].b == e.b) continue;
        const ra, const pa = find(parent, parity, e.a);
        const rb, const pb = find(parent, parity, e.b);
        if (ra != rb) {
            const lo = @min(ra, rb);
            const hi = @max(ra, rb);
            parent[hi] = lo;
            parity[hi] = (pa != pb) != e.odd;
            reported[lo] = reported[lo] or reported[hi];
            continue;
        }
        if ((pa != pb) == e.odd or reported[ra]) continue;
        reported[ra] = true;
        const sa: PolyId = @fromBackingInt(shapes.start + e.a);
        const sb: PolyId = @fromBackingInt(shapes.start + e.b);
        try c.push(.{ .rule = c.rule, .layer = r.layer, .severity = .@"error", .at = rects.gapMidpoint(store.polyBbox(sa), store.polyBbox(sb)), .measured = .count(1), .limit = .count(0), .shape_a = sa, .shape_b = sb });
    }
    // Per merged figure, in node order: a notch under `different` (a
    // self-conflict) and, with a track, its width.
    const figures = try gpa.alloc([2]u32, figure_node.items.len);
    defer gpa.free(figures);
    for (figures, figure_node.items, 0..) |*f, node, idx| f.* = .{ node, @intCast(idx) };
    std.mem.sortUnstable([2]u32, figures, {}, lessPair);
    for (figures) |f| {
        const figure = s.p.layer_out.get(f[1]);
        const poly: PolyId = @fromBackingInt(shapes.start + f[0]);
        const centre = rects.centre(store.polyBbox(poly));
        if (try geom.width.narrowestFacing(gpa, figure, .notch, &s.facing)) |notch| if (notch.gap < r.different) {
            try c.finding(r.layer, centre, .count(1), .count(0), poly);
        };
        const track = r.track orelse continue;
        const w = try geom.width.narrowestWidth(gpa, figure, &s.facing);
        const step = 2 * (track[0] + track[1]);
        const over = w - track[0];
        if (over > 0 and @mod(over, step) != 0) try c.finding(r.layer, centre, .length(w), .length(track[0] + @divTrunc(over, step) * step), poly);
    }
    return scratch.ran(n);
}

/// Line ends of one gridded SADP layer (Xu et al.'s rules 1 to 4). Each
/// merged figure that is a rectangle longer than wide is a line along its
/// long side; other figures are not examined. For two lines along one axis,
/// with `across` the gap between their sides (negative when they share a
/// track's span) and `[a0, a1]`, `[b0, b1]` their spans along it, `a`
/// first: on one track, an end-to-end gap under `tip`; on adjacent tracks
/// (`0 < across <= adjacent`), anti-parallel ends overlapping by less than
/// `overlap`, or apart closer than `corner`, and same-facing ends offset by
/// more than 0 and less than `offset`. Each finding is between the two
/// lines, at their boxes' gap. `examined` counts the layer's rows.
pub fn sadpLineEnd(c: *const Ctx, r: rows.SadpLineEnd) Error!Verdict {
    const gpa = c.gpa;
    const store = c.store;
    const s = c.s;
    const lim = r.ends;
    const shapes = store.polysOnLayer(r.layer);
    if (shapes.len() == 0) return skipped;
    const corner_reach = @max(lim.adjacent, lim.corner);
    const reach = 1 + @max(@max(lim.tip, lim.adjacent + corner_reach), lim.offset);
    var figure_node: std.ArrayList(u32) = .empty;
    defer figure_node.deinit(gpa);
    if (!try conflictGraph(c, r.layer, reach, &figure_node)) return refusedAfter(shapes.len());
    const line = try gpa.alloc(?Line, shapes.len());
    defer gpa.free(line);
    @memset(line, null);
    for (figure_node.items, 0..) |node, idx| {
        const figure = s.p.layer_out.get(@intCast(idx));
        const b = figure.bbox();
        const outer = figure.outer();
        const rectangle = figure.ringCount() == 1 and geom.ops.area2(outer.xs, outer.ys) == 2 * geom.mulWide(b.width(), b.height());
        if (rectangle and b.width() != b.height()) line[node] = .{ .horizontal = b.width() > b.height(), .b = b };
    }
    var pairs: std.ArrayList([2]u32) = .empty;
    defer pairs.deinit(gpa);
    for (s.p.pairs.items) |p| {
        const fa = s.p.labels.items[@backingInt(p.a) - shapes.start];
        const fb = s.p.labels.items[@backingInt(p.b) - shapes.start];
        if (fa != fb) try pairs.append(gpa, .{ @min(fa, fb), @max(fa, fb) });
    }
    std.mem.sortUnstable([2]u32, pairs.items, {}, lessPair);
    for (pairs.items, 0..) |pr, i| {
        if (i > 0 and std.mem.eql(u32, &pairs.items[i - 1], &pr)) continue;
        const la = line[pr[0]] orelse continue;
        const lb = line[pr[1]] orelse continue;
        if (la.horizontal != lb.horizontal) continue;
        // Spans along the line and across it, `a` before `b` along it.
        var sa = along(la);
        var sb = along(lb);
        if (sb[0] < sa[0] or (sb[0] == sa[0] and sb[1] < sa[1])) std.mem.swap([2]i64, &sa, &sb);
        const ca = cross(la);
        const cb = cross(lb);
        const across = @max(ca[0], cb[0]) - @min(ca[1], cb[1]);
        const pa: PolyId = @fromBackingInt(shapes.start + pr[0]);
        const pb: PolyId = @fromBackingInt(shapes.start + pr[1]);
        const at = rects.gapMidpoint(store.polyBbox(pa), store.polyBbox(pb));
        const gap = sb[0] - sa[1];
        var found: [4]?[2]i64 = @splat(null);
        if (across < 0) {
            if (gap >= 0 and gap < lim.tip) found[0] = .{ gap, lim.tip };
        } else if (across != 0 and across <= lim.adjacent) {
            if (gap >= 0) {
                if (gap < lim.corner) found[0] = .{ gap, lim.corner };
            } else if (sa[0] < sb[0] and sa[1] < sb[1] and -gap < lim.overlap) found[0] = .{ -gap, lim.overlap };
            for ([2]i64{ sb[0] - sa[0], @intCast(@abs(sb[1] - sa[1])) }, 1..) |shift, k| {
                if (shift > 0 and shift < lim.offset) found[k] = .{ shift, lim.offset };
            }
        }
        for (found) |maybe| if (maybe) |f| {
            try c.push(.{ .rule = c.rule, .layer = r.layer, .severity = .@"error", .at = at, .measured = .length(f[0]), .limit = .length(f[1]), .shape_a = pa, .shape_b = pb });
        };
    }
    return scratch.ran(shapes.len());
}

// ---- private ----

fn refusedAfter(examined: u64) Verdict {
    return .{ .outcome = .refused, .examined = examined };
}

fn lessPair(_: void, p: [2]u32, q: [2]u32) bool {
    return p[0] < q[0] or (p[0] == q[0] and p[1] < q[1]);
}

/// One layer's conflict graph: its figures (touching rows merged, a figure
/// named by its lowest row, node `row - first_row`) into `s.p.labels`, an
/// edge per pair of figures closer than `spacing` and a loop per figure
/// whose own notch is narrower into `s.p.edges`, the merged figures into
/// `s.p.layer_out`, and each merged figure's node into `figure_node`. False
/// when the layer fails validation.
fn conflictGraph(c: *const Ctx, layer: LayerId, spacing: Dbu, figure_node: *std.ArrayList(u32)) Error!bool {
    const gpa = c.gpa;
    const s = c.s;
    const first_row = c.store.polysOnLayer(layer).start;
    // Touching rows print as one shape: merge them (skipping this could
    // create an odd cycle).
    if (!try proximity.prepare(gpa, c.store, layer, spacing, &s.p)) return false;
    const limit2 = geom.mulWide(spacing, spacing);
    s.p.edges.clearRetainingCapacity();
    for (s.p.pairs.items, s.p.dists.items) |p, d2| {
        const fa = s.p.labels.items[@backingInt(p.a) - first_row];
        const fb = s.p.labels.items[@backingInt(p.b) - first_row];
        if (d2 < limit2 and fa != fb) try s.p.edges.append(gpa, .{ fa, fb });
    }
    // A figure whose own notch is narrower than `spacing` holds two parts
    // closer than one mask allows (Calibre's self-conflict, "an odd cycle
    // of one"): a loop on its node, which no palette colours.
    if (!try scratch.mergedOwners(c, layer)) return false;
    figure_node.clearRetainingCapacity();
    for (s.owners.items, 0..) |owner, idx| {
        const node = s.p.labels.items[@backingInt(owner) - first_row];
        try figure_node.append(gpa, node);
        const notch = try geom.width.narrowestFacing(gpa, s.p.layer_out.get(@intCast(idx)), .notch, &s.facing);
        if (notch) |f| if (f.gap < spacing) try s.p.edges.append(gpa, .{ node, node });
    }
    return true;
}

/// The root of `x`'s set in a union-find forest, halving the path.
fn rootOf(parent: []u32, x_: u32) u32 {
    var x = x_;
    while (parent[x] != x) {
        parent[x] = parent[parent[x]];
        x = parent[x];
    }
    return x;
}

/// The root of `x` and `x`'s parity to it, pointing the path at the root.
fn find(parent: []u32, parity: []bool, x: u32) struct { u32, bool } {
    var root = x;
    var to_root = false;
    while (parent[root] != root) {
        to_root = to_root != parity[root];
        root = parent[root];
    }
    var at = x;
    var here = to_root;
    while (at != root and parent[at] != root) {
        const next = parent[at];
        const up = parity[at];
        parent[at] = root;
        parity[at] = here;
        here = here != up;
        at = next;
    }
    return .{ root, to_root };
}

fn along(l: Line) [2]i64 {
    return if (l.horizontal) .{ l.b.xlo, l.b.xhi } else .{ l.b.ylo, l.b.yhi };
}

fn cross(l: Line) [2]i64 {
    return if (l.horizontal) .{ l.b.ylo, l.b.yhi } else .{ l.b.xlo, l.b.xhi };
}
