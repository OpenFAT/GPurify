//! Incremental DRC (catalog FLOW-008): after an edit, check again only the
//! part of the layout the edit can change, and keep the rest of the
//! previous run's findings. In: a deck, the previous run (`DrcState`) and
//! the edited layout's store, built as the previous one was (drawn layers,
//! then the deck's derived ones). Out: the edited layout's `DrcState`,
//! whose findings are the ones `check` gives it, every one naming the
//! edited store's rows. Ported from src/engine/incremental.rs.
//!
//! A rule is local when each finding depends only on shapes within its
//! reach H of the shapes it names, and lies within H of them: widths,
//! spacings, enclosures, areas, notches, cuts. H is the largest sum of a
//! local rule's lengths, plus twice every `sized` and `extended` length the
//! deck's derived layers apply. The drawn shapes the edit added or removed
//! are the seeds; the edited drawn shapes join into clusters H or less
//! apart (box to box); a cluster H or less from a seed is dirty, and so is
//! one whose zone (boxes grown by H) meets a dirty one's or a removed
//! seed's. A local rule runs again on the dirty clusters alone and keeps
//! every previous finding outside their zones. The rest run on the whole
//! layout: the density and whole-design kinds, the net, stack, pattern and
//! colouring kinds, a rule on a layer derived from texts or cell names, and
//! a local rule that did not run (before or on its dirty part). As
//! `drc.run` with no nets: no stages, waivers or custom rules.
//!
//! Contents:
//! - `pub const DrcState = struct { store, violations, runs }`
//! - `pub fn check(arena: Allocator, deck: *const CompiledDeck, store: GeometryStore) Error!DrcState`
//! - `pub fn recheck(scratch: Allocator, arena: Allocator, deck: *const CompiledDeck, strings: *const StrTable, previous: *const DrcState, store: GeometryStore) Error!DrcState`
//! - `pub fn reach(scratch: Allocator, deck: *const CompiledDeck, strings: *const StrTable) Allocator.Error!i64`
//! - `pub const Error`

const std = @import("std");
const Allocator = std.mem.Allocator;
const geom = @import("geom");
const Bbox = geom.Bbox;
const Point = geom.Point;
const LayerId = geom.LayerId;
const PolyId = geom.PolyId;
const StrTable = geom.StrTable;
const GeometryStore = geom.GeometryStore;
const ingest = @import("ingest");
const check_ = @import("check");
const report = check_.report;
const Violations = report.Violations;
const RuleRun = report.RuleRun;
const drc = check_.drc;
const RuleSet = drc.RuleSet;
const CompiledDeck = check_.deck.CompiledDeck;
const root = @import("triage.zig").root;

/// A DRC run's layout and findings, in the caller's arena.
pub const DrcState = struct {
    /// Drawn layers, then the deck's derived ones.
    store: GeometryStore,
    /// The findings, in rule order.
    violations: Violations,
    /// One row per rule, in deck order. After `recheck`, a local rule's
    /// `examined` counts what it looked at again, not the whole layout.
    runs: std.ArrayList(RuleRun),
};

pub const Error = drc.scratch.Error || Allocator.Error;

/// The kinds a finding of which can depend on shapes far from it, or that
/// report the design as a whole.
const whole_kinds = [_][]const u8{ "density", "global_density", "density_balance", "cover_density", "count", "total_area", "critical_area", "mean_critical_area", "via_redundancy", "dfm_score", "net_spacing", "origin", "via_stack", "multi_patterning", "anchored_patterning", "pattern_match" };

const Local = struct { local: []const bool, reach: i64 };

/// Per drawn row's geometry (layer, xs, ys as bytes), its rows ascending,
/// and how many a match has consumed.
const Queue = struct { rows: std.ArrayList(u32) = .empty, next: usize = 0 };

/// Maps a finding's row in the previous store or in the part to the
/// edited store's row: a drawn row by where it moved, a derived row by its
/// geometry; `no_shape` stays, and a row with no counterpart becomes it.
const Mapping = struct {
    scratch: Allocator,
    drawn: usize,
    derived: *const std.StringHashMapUnmanaged(Queue),

    const From = union(enum) { moved: []const u32, part: struct { pushed: []const u32, order: []const u32 } };

    fn toNew(m: Mapping, from: *const GeometryStore, row: PolyId, store: *const GeometryStore, how: From) Allocator.Error!PolyId {
        _ = store;
        const r = @backingInt(row);
        if (row == report.no_shape or r >= from.polyCount()) return row;
        const mapped: ?u32 = if (@backingInt(from.polyLayer(row)) < m.drawn) switch (how) {
            .moved => |moved| if (moved[r] == std.math.maxInt(u32)) null else moved[r],
            .part => |p| p.pushed[p.order[r]],
        } else if (m.derived.get(try keyOf(m.scratch, from, r))) |q| q.rows.items[0] else null;
        return @fromBackingInt(mapped orelse std.math.maxInt(u32));
    }
};

/// Every DRC rule of `deck` on `store`, as `drc.run` runs it with no nets.
pub fn check(arena: Allocator, deck: *const CompiledDeck, store: GeometryStore) Error!DrcState {
    var out: DrcState = .{ .store = store, .violations = .{}, .runs = .empty };
    try drc.run(arena, .cpu, null, &deck.drc, &out.store, null, &out.violations, &out.runs);
    return out;
}

/// How far a local rule of `deck` reaches (module doc), in grid units.
pub fn reach(scratch: Allocator, deck: *const CompiledDeck, strings: *const StrTable) Allocator.Error!i64 {
    return (try localRules(scratch, deck, strings)).reach;
}

/// The DRC findings of `store`, an edit of `previous.store`, as `check`
/// gives them, checking again only what the edit can change.
///
/// ponytail: clustering sweeps boxes by x and the zone closure is a
/// quadratic scan over dirty zones; a spatial index if edits on large
/// layouts make either show in a profile.
pub fn recheck(scratch: Allocator, arena: Allocator, deck: *const CompiledDeck, strings: *const StrTable, previous: *const DrcState, store_in: GeometryStore) Error!DrcState {
    var out: DrcState = .{ .store = store_in, .violations = .{}, .runs = .empty };
    const store = &out.store;
    const drawn: usize = if (deck.drc.first_derived) |l| @min(@backingInt(l), store.layerCount()) else store.layerCount();
    const local = try localRules(scratch, deck, strings);
    const h = local.reach;
    const old = &previous.store;

    // Seeds: drawn rows added and removed, matched by geometry; and where
    // each previous drawn row is now (`maxInt` for removed).
    var unmatched = try byKey(scratch, old, 0, drawn);
    const moved = try scratch.alloc(u32, old.polyCount());
    @memset(moved, std.math.maxInt(u32));
    var added: std.ArrayList(u32) = .empty;
    var rows: std.ArrayList(u32) = .empty;
    for (0..drawn) |l| {
        const r = store.polysOnLayer(@fromBackingInt(@as(u16, @intCast(l))));
        for (r.start..r.end) |row| try rows.append(scratch, @intCast(row));
    }
    for (rows.items) |row| {
        const entry = unmatched.getPtr(try keyOf(scratch, store, row));
        if (entry != null and entry.?.next < entry.?.rows.items.len) {
            moved[entry.?.rows.items[entry.?.next]] = row;
            entry.?.next += 1;
        } else try added.append(scratch, row);
    }
    var removed: std.ArrayList(Bbox) = .empty;
    var it = unmatched.valueIterator();
    while (it.next()) |e| for (e.rows.items[e.next..]) |row| try removed.append(scratch, old.polyBbox(@fromBackingInt(row)));

    // Clusters of the edited layout's drawn rows, `h` apart.
    const n = rows.items.len;
    const boxes = try scratch.alloc(Bbox, n);
    for (rows.items, boxes) |r, *b| b.* = store.polyBbox(@fromBackingInt(r));
    const parent = try scratch.alloc(u32, n);
    for (parent, 0..) |*p, i| p.* = @intCast(i);
    const by_x = try scratch.alloc(u32, n);
    for (by_x, 0..) |*p, i| p.* = @intCast(i);
    std.mem.sort(u32, by_x, boxes, lessXlo);
    for (by_x, 0..) |i, k| for (by_x[k + 1 ..]) |j| {
        if (boxes[j].xlo - boxes[i].xhi > h) break;
        if (gap(boxes[i], boxes[j]) <= h) {
            const a = root(parent, i);
            parent[a] = root(parent, j);
        }
    };
    const cluster = try scratch.alloc(u32, n);
    for (cluster, 0..) |*c, i| c.* = root(parent, @intCast(i));
    const dirty = try scratch.alloc(bool, n);
    @memset(dirty, false);
    var index: std.AutoHashMapUnmanaged(u32, u32) = .empty;
    for (rows.items, 0..) |r, i| try index.put(scratch, r, @intCast(i));
    for (added.items) |r| dirty[cluster[index.get(r).?]] = true;
    for (boxes, 0..) |b, i| for (removed.items) |seed| if (gap(b, seed) <= h) {
        dirty[cluster[i]] = true;
    };
    // Zones: a dirty cluster's and a removed seed's; a clean cluster whose
    // zone meets one is dirty too, until none does.
    var zones: std.ArrayList(Bbox) = .empty;
    for (removed.items) |b| try zones.append(scratch, grow(b, h));
    const taken = try scratch.alloc(bool, n);
    @memset(taken, false);
    while (true) {
        for (0..n) |i| if (dirty[cluster[i]] and !taken[i]) {
            taken[i] = true;
            try zones.append(scratch, grow(boxes[i], h));
        };
        var newly: std.ArrayList(u32) = .empty;
        for (0..n) |i| if (!dirty[cluster[i]]) {
            const z = grow(boxes[i], h);
            for (zones.items) |other| if (gap(z, other) == 0) {
                try newly.append(scratch, cluster[i]);
                break;
            };
        };
        if (newly.items.len == 0) break;
        for (newly.items) |c| dirty[c] = true;
    }

    // The dirty part, drawn, with the deck's layers derived from it.
    var builder: geom.GeometryStoreBuilder = .{};
    var pushed: std.ArrayList(u32) = .empty;
    for (rows.items, 0..) |row, i| if (dirty[cluster[i]]) {
        const ring = store.polyVerts(@fromBackingInt(row));
        _ = try builder.push(scratch, store.polyLayer(@fromBackingInt(row)), ring.xs, ring.ys);
        try pushed.append(scratch, row);
    };
    var part: GeometryStore = .empty;
    var order: std.ArrayList(u32) = .empty;
    try builder.finish(scratch, @intCast(store.layerCount()), &part, &order);
    try ingest.layout.deriveLayersInto(scratch, &part, &deck.deck.layers, &.{}, strings, &.{});
    const derived_rows = try byKey(scratch, store, drawn, store.layerCount());
    const map: Mapping = .{ .scratch = scratch, .drawn = drawn, .derived = &derived_rows };

    const any_dirty = std.mem.findScalar(bool, dirty, true) != null or removed.items.len != 0;
    const rs = &deck.drc;
    var part_out: Violations = .{};
    var part_runs: std.ArrayList(RuleRun) = .empty;
    if (any_dirty) try drc.run(scratch, .cpu, null, &try subset(scratch, rs, local.local), &part, null, &part_out, &part_runs);
    const again = try scratch.alloc(bool, rs.len());
    for (again, local.local, rs.id.items) |*a, l, id| {
        const was = findRun(previous.runs.items, id);
        const now = findRun(part_runs.items, id);
        a.* = !l or was == null or was.?.outcome != .ran or (any_dirty and (now == null or now.?.outcome != .ran));
    }
    var whole_out: Violations = .{};
    var whole_runs: std.ArrayList(RuleRun) = .empty;
    try drc.run(scratch, .cpu, null, &try subset(scratch, rs, again), store, null, &whole_out, &whole_runs);

    for (rs.id.items, again) |id, whole| {
        const before = out.violations.len();
        var run: RuleRun = undefined;
        if (whole) {
            for (0..whole_out.len()) |row| if (whole_out.rule.items[row] == id) try out.violations.pushRow(arena, &whole_out, @intCast(row));
            run = findRun(whole_runs.items, id).?;
        } else {
            for (0..previous.violations.len()) |row| {
                if (previous.violations.rule.items[row] != id) continue;
                var v = previous.violations.get(@intCast(row));
                if (inZone(zones.items, v.at)) continue;
                v.shape_a = try map.toNew(old, v.shape_a, store, .{ .moved = moved });
                v.shape_b = try map.toNew(old, v.shape_b, store, .{ .moved = moved });
                try out.violations.push(arena, v);
            }
            for (0..part_out.len()) |row| {
                if (part_out.rule.items[row] != id) continue;
                var v = part_out.get(@intCast(row));
                v.shape_a = try map.toNew(&part, v.shape_a, store, .{ .part = .{ .pushed = pushed.items, .order = order.items } });
                v.shape_b = try map.toNew(&part, v.shape_b, store, .{ .part = .{ .pushed = pushed.items, .order = order.items } });
                try out.violations.push(arena, v);
            }
            run = .{ .rule = id, .outcome = .ran, .examined = if (findRun(part_runs.items, id)) |r| r.examined else 0, .violations = 0 };
        }
        run.violations = std.math.lossyCast(u32, out.violations.len() - before);
        try out.runs.append(arena, run);
    }
    return out;
}

// ---- private ----

/// The local rules of `deck` (one flag per rule in deck order) and their
/// reach H, in grid units.
fn localRules(scratch: Allocator, deck: *const CompiledDeck, strings: *const StrTable) Allocator.Error!Local {
    const layers = &deck.deck.layers;
    // A layer computed from texts or cell names, which a store built in
    // memory does not hold.
    const labelled = try scratch.alloc(bool, layers.len());
    for (labelled, 0..) |*l, at| {
        const layer: LayerId = @fromBackingInt(@as(u16, @intCast(at)));
        l.* = if (layers.op(layer)) |op| switch (op) {
            .with_text, .texts_outside, .in_cells => true,
            else => false,
        } else false;
        for (layers.operands(layer)) |o| l.* = l.* or labelled[@backingInt(o)];
    }
    const source = try check_.deck.source.sourceOf(scratch, deck, strings);
    var grown: i64 = 0;
    for (source.derived.items) |row| grown += switch (row.op) {
        .sized => |s| @as(i64, @intCast(@abs(s.dx))) + @as(i64, @intCast(@abs(s.dy))),
        .extended => |e| e.begin + e.end + e.outside + e.inside,
        else => 0,
    };
    var h: i64 = 0;
    const rs = &deck.drc;
    const local = try scratch.alloc(bool, rs.len());
    for (local, rs.order.items, rs.id.items, 0..) |*l, slot, id, at| {
        const kind = @tagName(slot.kind);
        const whole = for (whole_kinds) |k| (if (std.mem.eql(u8, k, kind)) break true) else false;
        const reads = drc.rule_layers.layersOf(rs.get(@intCast(at))).main;
        const on_labelled = for (reads) |maybe| (if (maybe) |r| (if (labelled[@backingInt(r)]) break true)) else false;
        l.* = !whole and !on_labelled;
        if (!l.*) continue;
        const name = strings.resolve(id);
        var lengths: i64 = 0;
        for (source.rules.items) |row| if (std.mem.eql(u8, row.id, name)) for (row.params) |p| switch (p.value) {
            .value => |v| switch (v) {
                .length => |d| lengths += @intCast(@abs(d)),
                else => {},
            },
            .layer, .model => {},
        };
        h = @max(h, lengths);
    }
    return .{ .local = local, .reach = h + 2 * grown };
}

fn byKey(scratch: Allocator, store: *const GeometryStore, first: usize, end: usize) Allocator.Error!std.StringHashMapUnmanaged(Queue) {
    var out: std.StringHashMapUnmanaged(Queue) = .empty;
    for (first..end) |l| {
        const r = store.polysOnLayer(@fromBackingInt(@as(u16, @intCast(l))));
        for (r.start..r.end) |row| {
            const got = try out.getOrPut(scratch, try keyOf(scratch, store, @intCast(row)));
            if (!got.found_existing) got.value_ptr.* = .{};
            try got.value_ptr.rows.append(scratch, @intCast(row));
        }
    }
    return out;
}

fn keyOf(scratch: Allocator, store: *const GeometryStore, row: u32) Allocator.Error![]const u8 {
    const poly: PolyId = @fromBackingInt(row);
    const ring = store.polyVerts(poly);
    const layer = @backingInt(store.polyLayer(poly));
    const out = try scratch.alloc(u8, 2 + 8 * (ring.xs.len + ring.ys.len));
    std.mem.writeInt(u16, out[0..2], layer, .little);
    @memcpy(out[2..][0 .. 8 * ring.xs.len], std.mem.sliceAsBytes(ring.xs));
    @memcpy(out[2 + 8 * ring.xs.len ..], std.mem.sliceAsBytes(ring.ys));
    return out;
}

/// `rs` with only the rules `keep` flags, sharing its tables.
fn subset(scratch: Allocator, rs: *const RuleSet, keep: []const bool) Allocator.Error!RuleSet {
    var out = rs.*;
    out.order = .empty;
    out.id = .empty;
    out.severity = .empty;
    for (keep, rs.order.items, rs.id.items, rs.severity.items) |k, slot, id, sev| if (k) {
        try out.order.append(scratch, slot);
        try out.id.append(scratch, id);
        try out.severity.append(scratch, sev);
    };
    return out;
}

fn findRun(runs: []const RuleRun, id: geom.StrId) ?RuleRun {
    for (runs) |r| if (r.rule == id) return r;
    return null;
}

fn lessXlo(boxes: []const Bbox, a: u32, b: u32) bool {
    return boxes[a].xlo < boxes[b].xlo;
}

/// The Chebyshev gap between two boxes; 0 when they touch or overlap.
fn gap(a: Bbox, b: Bbox) i64 {
    return @max(@max(b.xlo - a.xhi, a.xlo - b.xhi, 0), @max(b.ylo - a.yhi, a.ylo - b.yhi, 0));
}

fn grow(b: Bbox, by: i64) Bbox {
    return .{ .xlo = b.xlo - by, .ylo = b.ylo - by, .xhi = b.xhi + by, .yhi = b.yhi + by };
}

fn inZone(zones: []const Bbox, p: Point) bool {
    for (zones) |z| if (z.xlo <= p.x and p.x <= z.xhi and z.ylo <= p.y and p.y <= z.yhi) return true;
    return false;
}
