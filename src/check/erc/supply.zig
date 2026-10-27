//! The supply kinds: `supply_short` (two tap kinds on one net),
//! `soft_connection` (a net held together only through a resistive layer),
//! `missing_tie` (a region point too far from every tap), `tie_high_low` (a
//! gate straight on a rail), `esd_topological` (a pad without clamps to
//! both rail kinds, ESDA TR18.0-01), `mixed_tag` (SKY130 hvnwell.10: tagged
//! and untagged figures on one net, through resistors) and
//! `floating_supply` (OpenROAD `check_power_grid`: a supply piece cut off
//! from its feed). In: nets, devices, geometry, the intent, the deck's
//! connectivity and stack. Out: violations and one run per row. Ported
//! from crates/check/src/erc/rules/supply.rs (`untied_points`,
//! `clamp_rails`, `point_in_region` live in topology/taps.zig and
//! clamp_reach.zig).
//!
//! Contents:
//! - `pub fn checkSupplyShort(r: Record, design: Design, t: *const SupplyShortTable, scratch: *Scratch) Allocator.Error!void`
//! - `pub fn checkSoftConnection(r: Record, design: Design, t: *const SoftConnectionTable, connectivity: *const Connectivity, scratch: *Scratch) Allocator.Error!void`
//! - `pub fn checkMissingTie(r: Record, design: Design, t: *const MissingTieTable, scratch: *Scratch) Allocator.Error!void`
//! - `pub fn checkTieHighLow(r: Record, design: Design, facts: *const NetFacts, intent: *const IntentMap, t: *const TieHighLowTable) Allocator.Error!void`
//! - `pub fn checkEsdTopological(r: Record, design: Design, intent: *const IntentMap, t: *const EsdTopologicalTable) Allocator.Error!void`
//! - `pub fn checkFloatingSupply(r: Record, design: Design, ports: *const PortTable, intent: *const IntentMap, process: Process, t: *const FloatingSupplyTable) Allocator.Error!void`
//! - `pub fn checkMixedTag(r: Record, design: Design, t: *const MixedTagTable) Allocator.Error!void`

const std = @import("std");
const Allocator = std.mem.Allocator;
const geom = @import("geom");
const LayerId = geom.LayerId;
const PolyId = geom.PolyId;
const StrId = geom.StrId;
const Connectivity = @import("ingest").deck.Connectivity;
const report = @import("../report.zig");
const proximity = @import("../proximity.zig");
const proximity_inside = @import("../proximity_inside.zig");
const net_ = @import("../topology/net.zig");
const NetId = net_.NetId;
const PortTable = @import("../topology/port.zig").PortTable;
const taps = @import("../topology/taps.zig");
const head = @import("head.zig");
const Record = head.Record;
const Design = head.Design;
const facts_ = @import("facts.zig");
const NetFacts = facts_.NetFacts;
const IntentMap = facts_.IntentMap;
const Process = @import("power_grid.zig").Process;
const feedShape = @import("power_links.zig").feedShape;
const clamp_reach = @import("clamp_reach.zig");
const Scratch = @import("scratch.zig").Scratch;
const tables = @import("supply_tables.zig");
const EsdTopologicalTable = tables.EsdTopologicalTable;
const FloatingSupplyTable = tables.FloatingSupplyTable;
const MissingTieTable = tables.MissingTieTable;
const MixedTagTable = tables.MixedTagTable;
const SoftConnectionTable = tables.SoftConnectionTable;
const SupplyShortTable = tables.SupplyShortTable;
const TieHighLowTable = tables.TieHighLowTable;

/// A net holding both tap kinds (`tap_a` within `within` when stated).
/// `examined` counts every polygon on both tap layers; a finding measures
/// the 2 tap kinds against 1.
pub fn checkSupplyShort(r: Record, design: Design, t: *const SupplyShortTable, scratch: *Scratch) Allocator.Error!void {
    const nets = design.nets.netCount();
    var flagged: std.ArrayList(u32) = .empty;
    defer flagged.deinit(r.gpa);
    for (t.head.rule.items, t.head.severity.items, t.tap_a.items, t.tap_b.items, t.within.items) |rule, severity, tap_a, tap_b, within| {
        const before = r.out.len();
        scratch.net_marks.clearRetainingCapacity();
        try scratch.net_marks.appendNTimes(r.gpa, 0, nets + 1);
        markNetsWithin(design, tap_a, within, 1, scratch.net_marks.items);
        markNetsWithin(design, tap_b, null, 2, scratch.net_marks.items);
        const examined: u64 = @as(u64, design.store.polysOnLayer(tap_a).len()) + design.store.polysOnLayer(tap_b).len();
        try netsMarkedInto(r.gpa, scratch.net_marks.items, 3, &flagged);
        try r.netViolations(design, flagged.items, rule, severity, .count(2), .count(1));
        try r.run(rule, before, .ran, examined);
    }
}

/// A net with a polygon on a soft layer whose hard remainder (re-extracted
/// with the soft layers, every global layer and their cuts out: the
/// substrate is resistive too) falls into two or more pieces:
/// one finding at its lowest remaining polygon naming one in another piece,
/// measuring 2 against 1. `examined` counts nets on a soft layer.
pub fn checkSoftConnection(r: Record, design: Design, t: *const SoftConnectionTable, connectivity: *const Connectivity, scratch: *Scratch) Allocator.Error!void {
    const gpa = r.gpa;
    const nets = design.nets.netCount();
    var arena_state: std.heap.ArenaAllocator = .init(gpa);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const is_soft = try arena.alloc(bool, design.store.layerCount());
    var soft_nets: std.ArrayList(u32) = .empty;
    for (t.head.rule.items, t.head.severity.items, 0..) |rule, severity, row| {
        _ = arena_state.reset(.retain_capacity);
        const before = r.out.len();
        @memset(is_soft, false);
        scratch.net_marks.clearRetainingCapacity();
        try scratch.net_marks.appendNTimes(gpa, 0, nets + 1);
        // A layer named twice is marked once.
        for (t.soft.items[t.soft_start.items[row]..t.soft_start.items[row + 1]]) |layer| {
            if (is_soft[@backingInt(layer)]) continue;
            is_soft[@backingInt(layer)] = true;
            markNetsWithin(design, layer, null, 1, scratch.net_marks.items);
        }
        soft_nets = .empty;
        try netsMarkedInto(arena, scratch.net_marks.items, 1, &soft_nets);
        // What is left without the resistive bodies, joined only as declared:
        // a global layer (the substrate) is one of them, listed or not.
        for (connectivity.global) |layer| is_soft[@backingInt(layer)] = true;
        var hard = connectivity.*;
        hard.conductors = try keepHard(arena, is_soft, connectivity.conductors);
        hard.global = try keepHard(arena, is_soft, connectivity.global);
        var cuts: std.ArrayList(LayerId) = .empty;
        var joins: std.ArrayList([2]LayerId) = .empty;
        for (connectivity.via_cut, connectivity.via_connects) |cut, ends| {
            if (soft(is_soft, cut) or soft(is_soft, ends[0]) or soft(is_soft, ends[1])) continue;
            try cuts.append(arena, cut);
            try joins.append(arena, ends);
        }
        hard.via_cut = cuts.items;
        hard.via_connects = joins.items;
        try net_.extractNetsInto(gpa, design.store, &hard, &scratch.staged_nets);
        const pieces = &scratch.staged_nets;
        for (soft_nets.items) |n| {
            // The lowest polygon off the soft layers, and the lowest one in
            // another piece.
            var near: ?PolyId = null;
            var near_piece: NetId = .none;
            var far: ?PolyId = null;
            for (design.nets.polysOf(@fromBackingInt(n))) |poly| {
                const piece = pieces.netOf(poly);
                if (soft(is_soft, design.store.polyLayer(poly)) or piece == .none) continue;
                if (near == null) {
                    near = poly;
                    near_piece = piece;
                } else if (piece != near_piece) {
                    far = poly;
                    break;
                }
            }
            const first = near orelse continue;
            const other = far orelse continue;
            try r.out.push(gpa, .{ .rule = rule, .layer = design.store.polyLayer(first), .severity = severity, .at = design.store.firstVertex(first), .measured = .count(2), .limit = .count(1), .shape_a = first, .shape_b = other });
        }
        try r.run(rule, before, .ran, soft_nets.items.len);
    }
}

/// Every region polygon whose furthest point from the tap layer is more
/// than `max_distance`: a finding at that point measuring its distance
/// (rounded down; `max_abs_dbu` with no tap) against the limit. `examined`
/// counts region polygons; refused when the tap layer will not validate.
pub fn checkMissingTie(r: Record, design: Design, t: *const MissingTieTable, scratch: *Scratch) Allocator.Error!void {
    var untied: taps.Untied = .{};
    defer untied.deinit(r.gpa);
    for (t.head.rule.items, t.head.severity.items, t.region.items, t.tap.items, t.max_distance.items) |rule, severity, region, tap, limit| {
        const before = r.out.len();
        const examined = try taps.untiedPoints(r.gpa, design.store, region, tap, limit, &scratch.layer_b, &untied) orelse {
            try r.run(rule, before, .refused, 0);
            continue;
        };
        for (untied.poly.items, untied.at.items, untied.worst2.items) |poly, at, worst| {
            try r.out.push(r.gpa, .{ .rule = rule, .layer = design.store.polyLayer(poly), .severity = severity, .at = at, .measured = .length(geom.ops.isqrt(worst)), .limit = .length(limit), .shape_a = poly, .shape_b = report.no_shape });
        }
        try r.run(rule, before, .ran, examined);
    }
}

/// Every declared supply carrying a gate terminal: a gate tied straight to
/// a rail with no tie cell, measuring 0 against 1. `examined` counts nets
/// with a gate. Skipped without a declared supply.
pub fn checkTieHighLow(r: Record, design: Design, facts: *const NetFacts, intent: *const IntentMap, t: *const TieHighLowTable) Allocator.Error!void {
    if (intent.supply_net.items.len == 0) return r.skipRows(&t.head);
    var examined: u64 = 0;
    for (facts.role.items) |m| examined += @intFromBool(m.gate);
    var flagged: std.ArrayList(u32) = .empty;
    defer flagged.deinit(r.gpa);
    for (intent.supply_net.items) |net| {
        const i = @backingInt(net);
        if (i < facts.role.items.len and facts.role.items[i].gate) try flagged.append(r.gpa, i);
    }
    for (t.head.rule.items, t.head.severity.items) |rule, severity| {
        const before = r.out.len();
        try r.netViolations(design, flagged.items, rule, severity, .count(0), .count(1));
        try r.run(rule, before, .ran, examined);
    }
}

/// Every pad net (a net with a polygon on `pad`) reaching fewer than both
/// rail kinds through clamp devices; a finding measures the kinds reached
/// against 2. `examined` counts pad nets. Skipped without usable intent.
pub fn checkEsdTopological(r: Record, design: Design, intent: *const IntentMap, t: *const EsdTopologicalTable) Allocator.Error!void {
    if (!intent.isUsable()) return r.skipRows(&t.head);
    const gpa = r.gpa;
    const nets = design.nets.netCount();
    var marks: std.ArrayList(u32) = .empty;
    defer marks.deinit(gpa);
    var pad_nets: std.ArrayList(u32) = .empty;
    defer pad_nets.deinit(gpa);
    var walk: clamp_reach.Walk = .{};
    defer walk.deinit(gpa);
    for (t.head.rule.items, t.head.severity.items, t.pad.items, 0..) |rule, severity, pad, row| {
        const before = r.out.len();
        const clamps = t.clamp.items[t.clamp_start.items[row]..t.clamp_start.items[row + 1]];
        marks.clearRetainingCapacity();
        try marks.appendNTimes(gpa, 0, nets + 1);
        markNetsWithin(design, pad, null, 1, marks.items);
        try netsMarkedInto(gpa, marks.items, 1, &pad_nets);
        for (pad_nets.items) |n| {
            const rails = try clamp_reach.clampRails(gpa, design, intent, clamps, @fromBackingInt(n), &walk);
            if (rails < 2) try r.netViolations(design, &.{n}, rule, severity, .count(rails), .count(2));
        }
        try r.run(rule, before, .ran, pad_nets.items.len);
    }
}

/// Every piece of a declared supply (nets carrying one supply's name) other
/// than the piece holding the feed shape (highest, then largest, shape over
/// every piece), measuring 0 connections against 1. `examined` counts the
/// pieces. Skipped without a declared supply.
pub fn checkFloatingSupply(r: Record, design: Design, ports: *const PortTable, intent: *const IntentMap, process: Process, t: *const FloatingSupplyTable) Allocator.Error!void {
    if (intent.supply_net.items.len == 0) return r.skipRows(&t.head);
    const gpa = r.gpa;
    const nets = design.nets;
    // Supply pieces grouped by name: `(name, net)`, ascending.
    const Piece = struct { name: StrId, net: NetId };
    var pieces: std.ArrayList(Piece) = .empty;
    defer pieces.deinit(gpa);
    for (intent.supply_net.items) |net| if (ports.nameOf(net)) |name| try pieces.append(gpa, .{ .name = name, .net = net });
    std.mem.sortUnstable(Piece, pieces.items, {}, struct {
        fn less(_: void, a: Piece, b: Piece) bool {
            if (a.name != b.name) return @backingInt(a.name) < @backingInt(b.name);
            return @backingInt(a.net) < @backingInt(b.net);
        }
    }.less);
    var kept: usize = 0;
    for (pieces.items) |p| if (kept == 0 or !std.meta.eql(pieces.items[kept - 1], p)) {
        pieces.items[kept] = p;
        kept += 1;
    };
    pieces.shrinkRetainingCapacity(kept);
    var floating: std.ArrayList(u32) = .empty;
    defer floating.deinit(gpa);
    var shapes: std.ArrayList(PolyId) = .empty;
    defer shapes.deinit(gpa);
    var owner: std.ArrayList(NetId) = .empty;
    defer owner.deinit(gpa);
    var start: usize = 0;
    while (start < pieces.items.len) {
        var end = start + 1;
        while (end < pieces.items.len and pieces.items[end].name == pieces.items[start].name) end += 1;
        const group = pieces.items[start..end];
        start = end;
        if (group.len < 2) continue;
        shapes.clearRetainingCapacity();
        owner.clearRetainingCapacity();
        for (group) |p| for (nets.polysOf(p.net)) |poly| if (!nets.holes.isHole(poly)) {
            try shapes.append(gpa, poly);
            try owner.append(gpa, p.net);
        };
        if (shapes.items.len == 0) continue;
        const fed = owner.items[feedShape(design.store, process, shapes.items)];
        for (group) |p| if (p.net != fed) try floating.append(gpa, @backingInt(p.net));
    }
    std.mem.sortUnstable(u32, floating.items, {}, std.sort.asc(u32));
    for (t.head.rule.items, t.head.severity.items) |rule, severity| {
        const before = r.out.len();
        try r.netViolations(design, floating.items, rule, severity, .count(0), .count(1));
        try r.run(rule, before, .ran, pieces.items.len);
    }
}

/// Every untagged figure of `layer` whose net (joined through resistors)
/// holds a tagged figure: a finding at its lowest drawn polygon measuring
/// the tagged figures there against 0, naming the first as its second
/// shape. `examined` counts figures on a net; refused when a layer will not
/// validate.
pub fn checkMixedTag(r: Record, design: Design, t: *const MixedTagTable) Allocator.Error!void {
    const gpa = r.gpa;
    const devices = design.devices;
    // Nets joined through a resistor are one group.
    var edges: std.ArrayList([2]u32) = .empty;
    defer edges.deinit(gpa);
    for (0..devices.len()) |d| {
        if (devices.kind.items[d] != .resistor) continue;
        var prev: ?u32 = null;
        for (devices.terminalsOf(@fromBackingInt(@as(u32, @intCast(d)))).nets) |net| {
            if (net == .none) continue;
            if (prev) |p| try edges.append(gpa, .{ p, @backingInt(net) });
            prev = @backingInt(net);
        }
    }
    const count = design.nets.netCount();
    var group: std.ArrayList(u32) = .empty;
    defer group.deinit(gpa);
    try geom.connectivity.componentsInto(gpa, count, edges.items, &group);
    var s: proximity.Scratch = .{};
    defer s.deinit(gpa);
    var owner: std.ArrayList(PolyId) = .empty;
    defer owner.deinit(gpa);
    var shares: std.ArrayList(bool) = .empty;
    defer shares.deinit(gpa);
    const Tagged = struct { group: u32, poly: PolyId };
    var tagged: std.ArrayList(Tagged) = .empty;
    defer tagged.deinit(gpa);
    for (t.head.rule.items, t.head.severity.items, t.layer.items, t.tag.items) |rule, severity, layer, tag| {
        const before = r.out.len();
        if (!try proximity_inside.taggedFigures(gpa, design.store, layer, tag, &s, &owner, &shares)) {
            try r.run(rule, before, .refused, 0);
            continue;
        }
        tagged.clearRetainingCapacity();
        for (owner.items, shares.items) |poly, is_tagged| if (is_tagged) {
            if (groupOf(design, count, group.items, poly)) |g| try tagged.append(gpa, .{ .group = g, .poly = poly });
        };
        std.mem.sortUnstable(Tagged, tagged.items, {}, struct {
            fn less(_: void, a: Tagged, b: Tagged) bool {
                if (a.group != b.group) return a.group < b.group;
                return @backingInt(a.poly) < @backingInt(b.poly);
            }
        }.less);
        var examined: u64 = 0;
        for (owner.items, shares.items) |poly, is_tagged| {
            const mine = groupOf(design, count, group.items, poly) orelse continue;
            examined += 1;
            if (is_tagged) continue;
            var lo: usize = 0;
            while (lo < tagged.items.len and tagged.items[lo].group < mine) lo += 1;
            var hi = lo;
            while (hi < tagged.items.len and tagged.items[hi].group == mine) hi += 1;
            if (hi == lo) continue;
            try r.out.push(gpa, .{ .rule = rule, .layer = layer, .severity = severity, .at = design.store.firstVertex(poly), .measured = .count(@intCast(hi - lo)), .limit = .count(0), .shape_a = poly, .shape_b = tagged.items[lo].poly });
        }
        try r.run(rule, before, .ran, examined);
    }
}

// ---- private ----

/// Bit-ors `bit` into the net slot of every polygon of `layer` whose box
/// centre lies in a polygon of `within` (every polygon when null); `marks`
/// is `nets + 1` long, `.none` landing in the trash slot. Nothing on an
/// unextracted design.
/// ponytail: centre-in-polygon stands in for containment; taps are small
/// convex shapes inside their well.
fn markNetsWithin(design: Design, layer: LayerId, within: ?LayerId, bit: u32, marks: []u32) void {
    const nets = marks.len - 1;
    if (nets == 0) return;
    const store = design.store;
    const rows = store.polysOnLayer(layer);
    for (rows.start..rows.end) |p| {
        const poly: PolyId = @fromBackingInt(@as(u32, @intCast(p)));
        if (within) |scope| {
            const b = store.polyBbox(poly);
            const c = geom.ops.centre(b);
            const scope_rows = store.polysOnLayer(scope);
            const inside = for (scope_rows.start..scope_rows.end) |sp| {
                const s: PolyId = @fromBackingInt(@as(u32, @intCast(sp)));
                if (store.polyBbox(s).overlaps(b) and store.polyContainsPoint(s, c)) break true;
            } else false;
            if (!inside) continue;
        }
        const slot = @min(@as(usize, @backingInt(design.nets.netOf(poly))), nets);
        marks[slot] |= bit;
    }
}

/// The nets (ascending) whose mark equals `want`, the trash slot aside.
fn netsMarkedInto(gpa: Allocator, marks: []const u32, want: u32, out: *std.ArrayList(u32)) Allocator.Error!void {
    out.clearRetainingCapacity();
    for (marks[0 .. marks.len - 1], 0..) |m, n| if (m == want) try out.append(gpa, @intCast(n));
}

fn soft(is_soft: []const bool, layer: LayerId) bool {
    return @backingInt(layer) < is_soft.len and is_soft[@backingInt(layer)];
}

fn keepHard(arena: Allocator, is_soft: []const bool, layers: []const LayerId) Allocator.Error![]const LayerId {
    var out: std.ArrayList(LayerId) = .empty;
    for (layers) |l| if (!soft(is_soft, l)) try out.append(arena, l);
    return out.items;
}

/// A figure's resistor-joined net group; null on no net.
fn groupOf(design: Design, count: u32, group: []const u32, poly: PolyId) ?u32 {
    if (count == 0) return null;
    const net = design.nets.netOf(poly);
    return if (net == .none) null else group[@backingInt(net)];
}
