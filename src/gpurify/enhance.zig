//! Automated DRC-clean layout enhancement (catalog FLOW-009): `gpurify
//! enhance` adds a second cut beside each single-cut via that has room for
//! one, and widens power straps, as the deck configures them, and keeps
//! only the edits that add no DRC finding. In: a GDSII layout and its deck.
//! Out: the layout's GDSII with the kept edits added (`enhanceGds`).
//! Ported from src/engine/enhance.rs.
//!
//! Candidates: for each `via_redundancy` rule on drawn layers, the cut its
//! definition finds room for beside each single-cut via
//! (`drc.via_connectors.redundantCutsInto`), wholly on the two shapes the
//! via joins; and for each `widen <layer> net "<pattern>" by <len>` line, a
//! strip `len` wide along each long side of every rectangle on the layer
//! whose net carries a matching label, where the strip touches no shape of
//! the layer, and no cut joining it, on another net. Neither joins two nets.
//!
//! All candidates are added and the layout checked as `gpurify drc` checks
//! it. A finding the input lacked, by rule and place (by rule alone for a
//! design-wide kind, whose place moves as vias are fixed; worse past its
//! limit counts as new), takes back every candidate within the deck's
//! reach of it (`incremental.reach`), or every candidate when none is that
//! near; this repeats until no new finding is left, so the output has no
//! finding the input lacked.
//!
//! Contents:
//! - `pub const Enhanced = struct { cuts, sides }`, `pub const Error`, `pub const Diagnostic`
//! - `pub fn enhanceGds(gpa: Allocator, arena: Allocator, io: std.Io, dir: std.Io.Dir, inputs: Inputs, decks: []const NamedDeck, kept: *Enhanced, diag: *Diagnostic) Error![]u8`

const std = @import("std");
const Allocator = std.mem.Allocator;
const geom = @import("geom");
const Bbox = geom.Bbox;
const Point = geom.Point;
const LayerId = geom.LayerId;
const PolyId = geom.PolyId;
const StrId = geom.StrId;
const ingest = @import("ingest");
const StreamBox = ingest.layout.StreamBox;
const check = @import("check");
const report = check.report;
const drc = check.drc;
const load_ = @import("load.zig");
const Inputs = load_.Inputs;
const Loaded = load_.Loaded;
const NamedDeck = load_.NamedDeck;
const extracted_ = @import("extracted.zig");
const Extracted = extracted_.Extracted;
const run_ = @import("run.zig");
const Outputs = run_.Outputs;
const incremental = @import("incremental.zig");

/// What `enhanceGds` kept.
pub const Enhanced = struct { cuts: u32 = 0, sides: u32 = 0 };

/// The layout or deck could not be read, its nets not extracted, or the
/// edited layout not written (`Diagnostic` says which input).
pub const Error = load_.Error || extracted_.Error || run_.Error;

pub const Diagnostic = run_.Diagnostic;

/// One edit, kept or taken back whole: boxes on stream pairs (a cut and its
/// metal patches, or a strap's strip), and whether it is a cut.
const Candidate = struct { boxes: []const StreamBox, cut: bool };

/// The kinds that report the design as a whole, at a place that moves as
/// the design changes: told apart by rule alone.
const design_kinds = [_][]const u8{ "via_redundancy", "dfm_score", "critical_area", "mean_critical_area", "global_density", "count", "total_area" };

/// One finding key's count, how far its worst lies past its limit (for a
/// design-wide kind; 0 for the rest), and a place.
const Count = struct { n: u32, past: f64, at: Point };

const Key = struct { rule: StrId, x: i64, y: i64 };

const Checked = struct { loaded: Loaded, extracted: Extracted, outputs: Outputs };

/// `inputs.layout`'s GDSII (in `arena`) with the deck's enhancements that
/// add no DRC finding, and how many of each it kept.
///
/// ponytail: each round reloads and rechecks the whole layout; check rounds
/// with `incremental.recheck` if large layouts need it.
pub fn enhanceGds(gpa: Allocator, arena: Allocator, io: std.Io, dir: std.Io.Dir, inputs: Inputs, decks: []const NamedDeck, kept_out: *Enhanced, diag: *Diagnostic) Error![]u8 {
    diag.load = .{ .stage = .layout, .path = inputs.layout };
    const bytes = try ingest.gds.readGdsBytes(gpa, io, dir, inputs.layout);
    defer gpa.free(bytes);
    var first: std.heap.ArenaAllocator = .init(gpa);
    defer first.deinit();
    const base = try checked(gpa, first.allocator(), io, dir, inputs, bytes, decks, diag);
    const before = try findings(first.allocator(), &base.loaded, &base.outputs);
    const nets = base.extracted.nets.netCount();
    const reach = try incremental.reach(first.allocator(), &base.loaded.deck, &base.loaded.strings);
    const all = try candidates(first.allocator(), &base.loaded, &base.extracted);
    const kept = try first.allocator().alloc(bool, all.len);
    @memset(kept, true);
    while (true) {
        var boxes: std.ArrayList(StreamBox) = .empty;
        defer boxes.deinit(gpa);
        for (all, kept) |c, k| if (k) try boxes.appendSlice(gpa, c.boxes);
        const edited = try ingest.layout.withBoxes(arena, bytes, boxes.items, &diag.load.gds);
        var round: std.heap.ArenaAllocator = .init(gpa);
        defer round.deinit();
        const r = round.allocator();
        const now = try checked(gpa, r, io, dir, inputs, edited, decks, diag);
        const after = try findings(r, &now.loaded, &now.outputs);
        var new: std.ArrayList(Point) = .empty;
        var it = after.iterator();
        while (it.next()) |e| {
            const was = before.get(e.key_ptr.*) orelse Count{ .n = 0, .past = 0, .at = e.value_ptr.at };
            if (e.value_ptr.n > was.n or e.value_ptr.past > was.past) try new.append(r, e.value_ptr.at);
        }
        // Nothing joins two nets by construction; were it to, every strap goes.
        if (now.extracted.nets.netCount() != nets) {
            var straps = false;
            for (all, kept) |c, k| straps = straps or (k and !c.cut);
            for (all, kept) |c, *k| k.* = k.* and c.cut and straps;
            continue;
        }
        if (new.items.len == 0) {
            kept_out.* = .{};
            for (all, kept) |c, k| if (k) {
                if (c.cut) kept_out.cuts += 1 else kept_out.sides += 1;
            };
            return edited;
        }
        var dropped = false;
        for (all, kept) |c, *k| {
            if (!k.* or !near(c, new.items, reach)) continue;
            k.* = false;
            dropped = true;
        }
        if (!dropped) @memset(kept, false);
    }
}

// ---- private ----

/// The layout given as bytes, loaded, extracted and DRC-checked in `arena`.
fn checked(gpa: Allocator, arena: Allocator, io: std.Io, dir: std.Io.Dir, inputs: Inputs, gds: []const u8, decks: []const NamedDeck, diag: *Diagnostic) Error!Checked {
    var out: Checked = undefined;
    out.loaded = try load_.loadBytes(gpa, arena, io, dir, inputs, gds, decks, &diag.load);
    out.extracted = try extracted_.extract(arena, &out.loaded, &diag.extract);
    out.outputs = .{};
    _ = try run_.runChecks(gpa, arena, &out.loaded, &out.extracted, .{ .checks = .{ .drc = true } }, &out.outputs);
    return out;
}

/// A measurement as a number, for how far past its limit it lies.
fn value(m: report.Measurement) f64 {
    return switch (m.kind) {
        .ratio => m.float(),
        .length, .area, .count => @floatFromInt(m.exact()),
        .voltage, .current, .resistance => 0,
    };
}

fn findings(arena: Allocator, loaded: *const Loaded, out: *const Outputs) Allocator.Error!std.AutoHashMapUnmanaged(Key, Count) {
    const rs = &loaded.deck.drc;
    var counts: std.AutoHashMapUnmanaged(Key, Count) = .empty;
    for (0..out.violations.len()) |row| {
        const v = out.violations.get(@intCast(row));
        const design = for (rs.id.items, rs.order.items) |id, slot| {
            if (id != v.rule) continue;
            const kind = @tagName(slot.kind);
            break for (design_kinds) |k| (if (std.mem.eql(u8, k, kind)) break true) else false;
        } else false;
        const key: Key = if (design) .{ .rule = v.rule, .x = 0, .y = 0 } else .{ .rule = v.rule, .x = v.at.x, .y = v.at.y };
        const past = if (design) @abs(value(v.measured) - value(v.limit)) else 0;
        const got = try counts.getOrPut(arena, key);
        if (!got.found_existing) got.value_ptr.* = .{ .n = 0, .past = 0, .at = v.at };
        got.value_ptr.n += 1;
        got.value_ptr.past = @max(got.value_ptr.past, past);
    }
    return counts;
}

/// Whether two boxes share a point, edges and corners included.
fn touch(a: Bbox, b: Bbox) bool {
    return a.xlo <= b.xhi and b.xlo <= a.xhi and a.ylo <= b.yhi and b.ylo <= a.yhi;
}

/// Whether metal added at `b` on `layer` joins nothing: the shapes it
/// touches there are on one net, and every cut joining the layer it
/// touches already lands on a shape of that net (a cut is on no net).
fn oneNet(loaded: *const Loaded, extracted: *const Extracted, layer: LayerId, b: Bbox) bool {
    const store = &loaded.store;
    const nets = &extracted.nets;
    var net: ?check.topology.NetId = null;
    const on = store.polysOnLayer(layer);
    for (on.start..on.end) |r| {
        const poly: PolyId = @fromBackingInt(@as(u32, @intCast(r)));
        if (!touch(store.polyBbox(poly), b)) continue;
        if (net) |n| (if (nets.netOf(poly) != n) return false) else net = nets.netOf(poly);
    }
    const the = net orelse return true;
    const conn = &loaded.deck.deck.connectivity;
    for (conn.via_cut, conn.via_connects) |cut, pair| {
        if (pair[0] != layer and pair[1] != layer) continue;
        const cuts = store.polysOnLayer(cut);
        for (cuts.start..cuts.end) |c| {
            const cb = store.polyBbox(@fromBackingInt(@as(u32, @intCast(c))));
            if (!touch(cb, b)) continue;
            const lands = for (on.start..on.end) |r| {
                const poly: PolyId = @fromBackingInt(@as(u32, @intCast(r)));
                if (touch(store.polyBbox(poly), cb) and nets.netOf(poly) == the) break true;
            } else false;
            if (!lands) return false;
        }
    }
    return true;
}

/// Every candidate the deck's rules and `widen` lines give (module doc).
fn candidates(arena: Allocator, loaded: *const Loaded, extracted: *const Extracted) Allocator.Error![]const Candidate {
    const store = &loaded.store;
    const deck = &loaded.deck;
    const layers = &deck.deck.layers;
    var out: std.ArrayList(Candidate) = .empty;
    var insertions: std.ArrayList(drc.via_connectors.Insertion) = .empty;
    for (deck.drc.order.items) |slot| {
        if (slot.kind != .via_redundancy) continue;
        const r = deck.drc.table(.via_redundancy).get(slot.row);
        if (layers.isDerived(r.cut) or layers.isDerived(r.lower) or layers.isDerived(r.upper)) continue;
        if (!try drc.via_connectors.redundantCutsInto(arena, store, .{ r.cut, r.lower, r.upper }, r.pitch, r.space, &insertions)) continue;
        for (insertions.items) |ins| {
            if (ins.lower) |p| if (!oneNet(loaded, extracted, r.lower, p)) continue;
            if (ins.upper) |p| if (!oneNet(loaded, extracted, r.upper, p)) continue;
            var boxes: std.ArrayList(StreamBox) = .empty;
            try boxes.append(arena, .{ .stream = layers.streamOf(r.cut), .box = ins.cut });
            if (ins.lower) |p| try boxes.append(arena, .{ .stream = layers.streamOf(r.lower), .box = p });
            if (ins.upper) |p| try boxes.append(arena, .{ .stream = layers.streamOf(r.upper), .box = p });
            try out.append(arena, .{ .boxes = boxes.items, .cut = true });
        }
    }
    for (deck.deck.edits.widen.items) |widen| {
        const layer = layers.id(&loaded.strings, widen.layer).?; // the deck checked its widen layers
        const pair = layers.streamOf(layer);
        const by = widen.by;
        const rows = store.polysOnLayer(layer);
        for (rows.start..rows.end) |row| {
            const poly: PolyId = @fromBackingInt(@as(u32, @intCast(row)));
            const named = for (extracted.ports.namesOf(extracted.nets.netOf(poly))) |name| {
                if (ingest.globMatches(widen.net, loaded.strings.resolve(name))) break true;
            } else false;
            const ring = store.polyVerts(poly);
            const b = store.polyBbox(poly);
            var rectangle = ring.xs.len == 4;
            for (ring.xs, ring.ys) |x, y| rectangle = rectangle and (x == b.xlo or x == b.xhi) and (y == b.ylo or y == b.yhi);
            if (!named or !rectangle) continue;
            const strips: [2]Bbox = if (b.xhi - b.xlo <= b.yhi - b.ylo)
                .{ .{ .xlo = b.xlo - by, .ylo = b.ylo, .xhi = b.xlo, .yhi = b.yhi }, .{ .xlo = b.xhi, .ylo = b.ylo, .xhi = b.xhi + by, .yhi = b.yhi } }
            else
                .{ .{ .xlo = b.xlo, .ylo = b.ylo - by, .xhi = b.xhi, .yhi = b.ylo }, .{ .xlo = b.xlo, .ylo = b.yhi, .xhi = b.xhi, .yhi = b.yhi + by } };
            for (strips) |strip| if (oneNet(loaded, extracted, layer, strip)) {
                try out.append(arena, .{ .boxes = try arena.dupe(StreamBox, &.{.{ .stream = pair, .box = strip }}), .cut = false });
            };
        }
    }
    return out.items;
}

/// Whether one of `c`'s boxes is within `reach` (Chebyshev) of a new finding.
fn near(c: Candidate, new: []const Point, reach: i64) bool {
    for (new) |p| for (c.boxes) |sb| {
        const b = sb.box;
        const gx = @max(b.xlo - p.x, p.x - b.xhi, 0);
        const gy = @max(b.ylo - p.y, p.y - b.yhi, 0);
        if (@max(gx, gy) <= reach) return true;
    };
    return false;
}
