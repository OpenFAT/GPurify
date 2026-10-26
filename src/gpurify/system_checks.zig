//! Several dies placed into one assembly (2.5D, 3D, chiplets on an
//! interposer), checked as one: the system LVS pieces (catalog LVS-073) and
//! the package- and system-level ESD checks (ERC-C12, ERC-C13). In: each
//! die's extraction and LVS graph, where it sits (`Placement`), and which
//! layers face another die or the package. Out: violation rows (no layer:
//! layer ids belong to one die's deck) and one `RuleRun` per check, in the
//! assembly's coordinates. Ported from crates/check/src/system.rs (moved
//! here per ARCHITECTURE.md).
//!
//! System LVS, as Calibre 3DSTACK's public material defines it (Siemens fact
//! sheet 82850-D2, 2022; "HDAP connectivity verification", 2018): a bump is
//! a rectangle on a net of a bonded face's layer (`bumpsInto`); two bumps of
//! facing dies bond when their placed rectangles share area
//! (`bondedPairs`), and one that bonds nothing is `system.unbonded_bump`
//! (`checkBonds`); the dies' graphs become one flat graph, bonded nets
//! merged (`assemble`), held to the flattened system netlist; names are
//! compared pin by pin (`checkPins`): `system.open`, `system.short`.
//! Bond alignment and spacing are `system.bump_offset`/`system.bump_space`
//! (DRC-129, `checkAlignment`).
//!
//! ESD (ESDA TR18.0-01-25 §6.3–6.7, §4.5.2–4.5.4; JEP196; Industry Council
//! White Papers 2 and 3): a pad's discharge path is a clamp from the pad to
//! a supply, then any chain of clamps between supplies, both a power and a
//! ground reached (`railsReached`); `esdPadsInto` holds a set of pads to
//! it. A pin whose net reaches no device terminal is not examined.
//!
//! Contents:
//! - `pub const rule_ids: [8][]const u8`, `pub fn internRuleIds(gpa: Allocator, strings: *StrTable) Allocator.Error!void`
//! - `pub const Placement = struct`, `Placement.apply(p, pt: Point) Point`, `Placement.applyBox(p, b: Bbox) Bbox`
//! - `pub const Bump = struct { poly, net, at }`, `pub const BumpError`
//! - `pub fn bumpsInto(gpa: Allocator, design: Design, layer: LayerId, placement: Placement, out: *std.ArrayList(Bump), bad: *PolyId) (BumpError || Allocator.Error)!void`
//! - `pub fn bondedPairsInto(gpa: Allocator, a: []const Bump, b: []const Bump, out: *std.ArrayList([2]u32)) Allocator.Error!void`
//! - `pub fn checkBonds(gpa: Allocator, bonds: []const [2][]const Bump, strings: *const StrTable, out: *Violations, runs: *std.ArrayList(RuleRun), pairs: [][]const [2]u32) Allocator.Error!void`
//! - `pub fn checkAlignment(gpa: Allocator, bonds: []const [2][]const Bump, pairs: []const []const [2]u32, limits: []const [2]?Dbu, strings: *const StrTable, out: *Violations, runs: *std.ArrayList(RuleRun)) Allocator.Error!void`
//! - `pub fn assemble(gpa: Allocator, dies: []const *const Graph, joins: []const [2]u32, out: *Graph, class: *std.ArrayList(u32)) Allocator.Error!void`
//! - `pub const Pin = struct { reference, layout, at }`, `pub fn checkPins(gpa: Allocator, pins: []const Pin, strings: *const StrTable, out: *Violations, runs: *std.ArrayList(RuleRun)) Allocator.Error!void`
//! - `pub const power: u8`, `pub const ground: u8`
//! - `pub fn railsReached(gpa: Allocator, graph: *const Graph, supply: []const u8, clamps: []const StrId, pad: u32, seen: *std.ArrayList(bool), stack: *std.ArrayList(u32)) Allocator.Error!u32`
//! - `pub fn esdPadsInto(gpa: Allocator, rule: StrId, graph: *const Graph, supply: []const u8, clamps: []const StrId, pads: []const Pad, out: *Violations) Allocator.Error!u64`, `pub const Pad`

const std = @import("std");
const Allocator = std.mem.Allocator;
const geom = @import("geom");
const Bbox = geom.Bbox;
const Dbu = geom.Dbu;
const Point = geom.Point;
const LayerId = geom.LayerId;
const PolyId = geom.PolyId;
const StrId = geom.StrId;
const StrTable = geom.StrTable;
const check = @import("check");
const report = check.report;
const Violations = report.Violations;
const RuleRun = report.RuleRun;
const rects = check.rects;
const NetId = check.topology.NetId;
const lvs = check.lvs;
const Graph = lvs.Graph;
const Design = lvs.Design;

/// Every rule id a system run reports under, besides the flat comparison's
/// `lvs.*` ids.
pub const rule_ids = [8][]const u8{ "system.unbonded_bump", "system.bump_offset", "system.bump_space", "system.open", "system.short", "system.esd_d2d", "system.esd_package", "system.esd_iec" };

/// Where one die sits: reflected in its x axis (`y` to `-y`) when
/// `mirror`, then turned counter-clockwise by `quarter_turns` (mod 4), then
/// moved by `(dx, dy)`, the order a GDSII reference applies them in.
pub const Placement = struct {
    mirror: bool = false,
    quarter_turns: u8 = 0,
    dx: Dbu = 0,
    dy: Dbu = 0,

    pub fn apply(p: Placement, pt: Point) Point {
        var x = pt.x;
        var y = pt.y;
        if (p.mirror) y = -y;
        for (0..p.quarter_turns % 4) |_| {
            const t = x;
            x = -y;
            y = t;
        }
        return .{ .x = x + p.dx, .y = y + p.dy };
    }

    /// A quarter turn and a reflection map a box onto a box.
    pub fn applyBox(p: Placement, b: Bbox) Bbox {
        const lo = p.apply(.{ .x = b.xlo, .y = b.ylo });
        const hi = p.apply(.{ .x = b.xhi, .y = b.yhi });
        return Bbox.point(lo.x, lo.y).include(hi.x, hi.y);
    }
};

/// One bump of a face: its shape and net on its own die, and where it lands.
pub const Bump = struct { poly: PolyId, net: NetId, at: Bbox };

/// `NotRectangle`: a shape that is not a counter-clockwise rectangle (overlap
/// is decided on rectangles exactly); `NoNet`: a shape on no net (the layer
/// is not a conductor). The shape is in the `bad` out-parameter.
pub const BumpError = error{ NotRectangle, NoNet };

/// One pin of the system netlist and where the assembly put it:
/// `reference` its system net, `layout` the assembled net of the label
/// naming it (`maxInt` when none does), `at` a bump of its net or `nowhere`.
pub const Pin = struct { reference: u32, layout: u32, at: Point };

/// A supply rail bit: the net is a power rail.
pub const power: u8 = 1;

/// A ground rail bit.
pub const ground: u8 = 2;

/// A pad: a net of the graph and where to report it.
pub const Pad = struct { net: u32, at: Point };

pub fn internRuleIds(gpa: Allocator, strings: *StrTable) Allocator.Error!void {
    for (rule_ids) |name| _ = try strings.intern(gpa, name);
}

/// Every shape of `layer` as a `Bump`, placed, in store order, into `out`
/// (cleared first). A layer the store does not have holds none.
pub fn bumpsInto(gpa: Allocator, design: Design, layer: LayerId, placement: Placement, out: *std.ArrayList(Bump), bad: *PolyId) (BumpError || Allocator.Error)!void {
    out.clearRetainingCapacity();
    const store = design.store;
    if (@backingInt(layer) >= store.layerCount()) return;
    const rows = store.polysOnLayer(layer);
    for (rows.start..rows.end) |r| {
        const poly: PolyId = @fromBackingInt(@as(u32, @intCast(r)));
        const ring = store.polyVerts(poly);
        const b = store.polyBbox(poly);
        bad.* = poly;
        // Four vertices enclosing the box's whole area, counter-clockwise.
        if (ring.xs.len != 4 or geom.ops.area2(ring.xs, ring.ys) != 2 * b.area()) return error.NotRectangle;
        const net = design.nets.netOf(poly);
        if (net == .none) return error.NoNet;
        try out.append(gpa, .{ .poly = poly, .net = net, .at = placement.applyBox(b) });
    }
}

/// Every `(i, j)` whose bumps `a[i]` and `b[j]` share area (touching is not
/// bonding), ascending, into `out` (cleared first). `b` is filed in a hash
/// grid whose cell is its widest bump, so the cost is linear for bumps of
/// one size.
pub fn bondedPairsInto(gpa: Allocator, a: []const Bump, b: []const Bump, out: *std.ArrayList([2]u32)) Allocator.Error!void {
    out.clearRetainingCapacity();
    var cell: i64 = 1;
    for (b) |bump| cell = @max(cell, bump.at.width(), bump.at.height());
    var grid: std.AutoHashMapUnmanaged([2]i64, std.ArrayList(u32)) = .empty;
    defer {
        var it = grid.valueIterator();
        while (it.next()) |v| v.deinit(gpa);
        grid.deinit(gpa);
    }
    for (b, 0..) |bump, j| {
        var x = @divFloor(bump.at.xlo, cell);
        while (x <= @divFloor(bump.at.xhi, cell)) : (x += 1) {
            var y = @divFloor(bump.at.ylo, cell);
            while (y <= @divFloor(bump.at.yhi, cell)) : (y += 1) {
                const got = try grid.getOrPut(gpa, .{ x, y });
                if (!got.found_existing) got.value_ptr.* = .empty;
                try got.value_ptr.append(gpa, @intCast(j));
            }
        }
    }
    for (a, 0..) |bump, i| {
        var x = @divFloor(bump.at.xlo, cell);
        while (x <= @divFloor(bump.at.xhi, cell)) : (x += 1) {
            var y = @divFloor(bump.at.ylo, cell);
            while (y <= @divFloor(bump.at.yhi, cell)) : (y += 1) {
                const js = grid.get(.{ x, y }) orelse continue;
                for (js.items) |j| if (bond(bump.at, b[j].at)) try out.append(gpa, .{ @intCast(i), j });
            }
        }
    }
    std.mem.sort([2]u32, out.items, {}, lessPair);
    var kept: usize = 0;
    for (out.items) |p| {
        if (kept > 0 and std.mem.eql(u32, &out.items[kept - 1], &p)) continue;
        out.items[kept] = p;
        kept += 1;
    }
    out.shrinkRetainingCapacity(kept);
}

/// Bonds each pair of facing faces, `pairs[k]` (in `gpa`, the caller's)
/// the bonded pairs of bond `k`, and records `system.unbonded_bump`: every
/// bump that bonds nothing on the facing die is a row at its placed centre,
/// measured 0 bumps against 1. One run, examining every bump of every bond.
pub fn checkBonds(gpa: Allocator, bonds: []const [2][]const Bump, strings: *const StrTable, out: *Violations, runs: *std.ArrayList(RuleRun), pairs: [][]const [2]u32) Allocator.Error!void {
    std.debug.assert(pairs.len == bonds.len);
    const rule = report.ruleId(strings, "system.unbonded_bump");
    const before = out.len();
    var examined: u64 = 0;
    for (bonds, pairs) |faces, *p| {
        var list: std.ArrayList([2]u32) = .empty;
        try bondedPairsInto(gpa, faces[0], faces[1], &list);
        p.* = list.items;
        for (faces, 0..) |face, side| {
            examined += face.len;
            for (face, 0..) |bump, k| {
                const paired = for (list.items) |pr| (if (pr[side] == k) break true) else false;
                if (!paired) try out.push(gpa, .{ .rule = rule, .layer = report.no_layer, .severity = .@"error", .at = geom.ops.centre(bump.at), .measured = .count(0), .limit = .count(1), .shape_a = bump.poly, .shape_b = report.no_shape });
            }
        }
    }
    try report.recordRun(gpa, runs, out, before, rule, .ran, examined);
}

/// Holds each bond's bumps to its `[max offset, min space]` (grid units,
/// null where unstated; catalog DRC-129): `system.bump_offset` for bonded
/// bumps whose centres are farther apart than the offset, at the floored
/// middle of the centres, measuring their floored distance;
/// `system.bump_space` for a bump closer than the space to a facing bump it
/// does not bond, at the middle of their gap, measuring it. A row is
/// recorded only when some bond states its limit.
///
/// ponytail: every facing pair of bumps, O(a·b) per bond; file the far face
/// in a hash grid as `bondedPairsInto` does if 10^5-bump packages make it slow.
pub fn checkAlignment(gpa: Allocator, bonds: []const [2][]const Bump, pairs: []const []const [2]u32, limits: []const [2]?Dbu, strings: *const StrTable, out: *Violations, runs: *std.ArrayList(RuleRun)) Allocator.Error!void {
    std.debug.assert(bonds.len == pairs.len and bonds.len == limits.len);
    const any_offset = for (limits) |l| (if (l[0] != null) break true) else false;
    if (any_offset) {
        const rule = report.ruleId(strings, "system.bump_offset");
        const before = out.len();
        var examined: u64 = 0;
        for (bonds, pairs, limits) |faces, ps, l| {
            const max = l[0] orelse continue;
            for (ps) |pr| {
                examined += 1;
                const p = twice(faces[0][pr[0]].at);
                const q = twice(faces[1][pr[1]].at);
                const dx = p[0] - q[0];
                const dy = p[1] - q[1];
                // At twice the scale: 4 d² against (2 max)².
                const d4 = dx * dx + dy * dy;
                if (d4 > 4 * geom.mulWide(max, max)) try out.push(gpa, .{ .rule = rule, .layer = report.no_layer, .severity = .@"error", .at = .{ .x = @intCast(@divFloor(p[0] + q[0], 4)), .y = @intCast(@divFloor(p[1] + q[1], 4)) }, .measured = .length(@divTrunc(geom.ops.isqrt(d4), 2)), .limit = .length(max), .shape_a = faces[0][pr[0]].poly, .shape_b = faces[1][pr[1]].poly });
            }
        }
        try report.recordRun(gpa, runs, out, before, rule, .ran, examined);
    }
    const any_space = for (limits) |l| (if (l[1] != null) break true) else false;
    if (!any_space) return;
    const rule = report.ruleId(strings, "system.bump_space");
    const before = out.len();
    var examined: u64 = 0;
    for (bonds, pairs, limits) |faces, ps, l| {
        const min = l[1] orelse continue;
        examined += faces[0].len + faces[1].len;
        for (faces[0], 0..) |bump, i| for (faces[1], 0..) |other, j| {
            const pr: [2]u32 = .{ @intCast(i), @intCast(j) };
            const bonded = for (ps) |x| (if (std.mem.eql(u32, &x, &pr)) break true) else false;
            if (bonded) continue;
            const gap2 = rects.bboxGap2(bump.at, other.at);
            if (gap2 < geom.mulWide(min, min)) try out.push(gpa, .{ .rule = rule, .layer = report.no_layer, .severity = .@"error", .at = rects.gapMidpoint(bump.at, other.at), .measured = .length(geom.ops.isqrt(gap2)), .limit = .length(min), .shape_a = bump.poly, .shape_b = other.poly });
        };
    }
    try report.recordRun(gpa, runs, out, before, rule, .ran, examined);
}

/// One flat graph of every die's into `out` (empty on entry), the nets of
/// each `joins` pair merged; die net `n` is joined net `offset + n`,
/// `offset` the nets of the dies before. `class` gets, per joined net, its
/// net in the graph. Classes are numbered by their lowest member and take
/// the name of their lowest named member; a class is a port when any member
/// is. Devices keep their order, die after die.
pub fn assemble(gpa: Allocator, dies: []const *const Graph, joins: []const [2]u32, out: *Graph, class: *std.ArrayList(u32)) Allocator.Error!void {
    var total: u32 = 0;
    for (dies) |d| total += d.netCount();
    const parent = try gpa.alloc(u32, total);
    defer gpa.free(parent);
    for (parent, 0..) |*p, i| p.* = @intCast(i);
    for (joins) |j| {
        const a = root(parent, j[0]);
        const b = root(parent, j[1]);
        // The lower root wins, so every root is its class's lowest member.
        parent[@max(a, b)] = @min(a, b);
    }
    try class.resize(gpa, total);
    @memset(class.items, std.math.maxInt(u32));
    for (0..total) |net| {
        const top = root(parent, @intCast(net));
        if (class.items[top] == std.math.maxInt(u32)) {
            class.items[top] = out.netCount();
            try out.net_name.append(gpa, null);
        }
        class.items[net] = class.items[top];
    }
    try out.device_terminal_start.append(gpa, 0);
    try out.device_param_start.append(gpa, 0);
    var offset: u32 = 0;
    for (dies) |die| {
        try out.device_kind.appendSlice(gpa, die.device_kind.items);
        try out.device_model.appendSlice(gpa, die.device_model.items);
        const terminals: u32 = @intCast(out.terminal_net.items.len);
        for (die.device_terminal_start.items[1..]) |s| try out.device_terminal_start.append(gpa, terminals + s);
        for (die.terminal_net.items) |net| try out.terminal_net.append(gpa, if (net == lvs.graph.no_net) net else class.items[offset + net]);
        try out.terminal_role.appendSlice(gpa, die.terminal_role.items);
        const params: u32 = @intCast(out.param.items.len);
        for (die.device_param_start.items[1..]) |s| try out.device_param_start.append(gpa, params + s);
        try out.param.appendSlice(gpa, die.param.items);
        for (die.net_name.items, 0..) |name, net| {
            const slot = &out.net_name.items[class.items[offset + net]];
            if (slot.* == null) slot.* = name;
        }
        for (die.port_net.items) |net| try out.port_net.append(gpa, class.items[offset + net]);
        offset += die.netCount();
    }
    std.mem.sort(u32, out.port_net.items, {}, std.sort.asc(u32));
    var kept: usize = 0;
    for (out.port_net.items) |p| {
        if (kept > 0 and out.port_net.items[kept - 1] == p) continue;
        out.port_net.items[kept] = p;
        kept += 1;
    }
    out.port_net.shrinkRetainingCapacity(kept);
    try lvs.graph.transposeInto(gpa, out, out.netCount());
}

/// Compares the assembly's connectivity with the system netlist's, pin by
/// pin: `system.open` for a pin no label names (0 against 1) and for a
/// system net whose pins land on several assembled nets (one row per net
/// past the first, at its first pin, 2 against 1); `system.short` for an
/// assembled net holding pins of several system nets (one row per system
/// net past the first). "First" is `pins` order; each run examines every pin.
pub fn checkPins(gpa: Allocator, pins: []const Pin, strings: *const StrTable, out: *Violations, runs: *std.ArrayList(RuleRun)) Allocator.Error!void {
    const examined: u64 = pins.len;
    const order = try gpa.alloc(u32, pins.len);
    defer gpa.free(order);
    for (order, 0..) |*o, i| o.* = @intCast(i);
    var seen: std.ArrayList(u32) = .empty;
    defer seen.deinit(gpa);

    const open = report.ruleId(strings, "system.open");
    var before = out.len();
    std.mem.sort(u32, order, pins, byReference);
    var s: usize = 0;
    while (s < order.len) {
        var e = s;
        while (e < order.len and pins[order[e]].reference == pins[order[s]].reference) e += 1;
        seen.clearRetainingCapacity();
        for (order[s..e]) |i| {
            const pin = pins[i];
            if (pin.layout == std.math.maxInt(u32)) {
                try out.push(gpa, pinRow(open, pin.at, 0));
            } else if (std.mem.findScalar(u32, seen.items, pin.layout) == null) {
                if (seen.items.len != 0) try out.push(gpa, pinRow(open, pin.at, 2));
                try seen.append(gpa, pin.layout);
            }
        }
        s = e;
    }
    try report.recordRun(gpa, runs, out, before, open, .ran, examined);

    const short = report.ruleId(strings, "system.short");
    before = out.len();
    std.mem.sort(u32, order, pins, byLayout);
    s = 0;
    while (s < order.len) {
        var e = s;
        while (e < order.len and pins[order[e]].layout == pins[order[s]].layout) e += 1;
        defer s = e;
        if (pins[order[s]].layout == std.math.maxInt(u32)) continue;
        seen.clearRetainingCapacity();
        for (order[s..e]) |i| {
            const pin = pins[i];
            if (std.mem.findScalar(u32, seen.items, pin.reference) != null) continue;
            if (seen.items.len != 0) try out.push(gpa, pinRow(short, pin.at, 2));
            try seen.append(gpa, pin.reference);
        }
    }
    try report.recordRun(gpa, runs, out, before, short, .ran, examined);
}

/// How many of the two rail kinds `pad` reaches through devices whose
/// model is in `clamps`: a clamp from the pad to a supply, then any chain
/// of clamps between supplies. A clamp joins all its terminals; another
/// signal net is not a path (ERC-C1's search, on a `Graph`). `supply` holds
/// `power`/`ground` bits per net; `seen` and `stack` are scratch.
pub fn railsReached(gpa: Allocator, graph: *const Graph, supply: []const u8, clamps: []const StrId, pad: u32, seen: *std.ArrayList(bool), stack: *std.ArrayList(u32)) Allocator.Error!u32 {
    // ponytail: O(nets) reset per pad; pads are few next to nets.
    try seen.resize(gpa, graph.netCount());
    @memset(seen.items, false);
    stack.clearRetainingCapacity();
    try stack.append(gpa, pad);
    seen.items[pad] = true;
    var reached: u8 = 0;
    while (stack.pop()) |net| {
        const rails = supply[net];
        reached |= rails;
        if (rails == 0 and net != pad) continue;
        for (graph.terminalsOn(net).devices) |device| {
            if (std.mem.findScalar(StrId, clamps, graph.device_model.items[device]) == null) continue;
            for (graph.terminalsOf(device).nets) |next| {
                if (next == lvs.graph.no_net or seen.items[next]) continue;
                seen.items[next] = true;
                try stack.append(gpa, next);
            }
        }
    }
    return @as(u32, @intFromBool(reached & power != 0)) + @intFromBool(reached & ground != 0);
}

/// Holds every pad to `railsReached` through `clamps`, appending a row under
/// `rule` for each reaching fewer than both kinds: at its first place,
/// measured the kinds reached against 2. A net listed twice is held once; a
/// net no device terminal reaches is not examined. Returns the nets examined.
pub fn esdPadsInto(gpa: Allocator, rule: StrId, graph: *const Graph, supply: []const u8, clamps: []const StrId, pads: []const Pad, out: *Violations) Allocator.Error!u64 {
    var seen: std.ArrayList(bool) = .empty;
    defer seen.deinit(gpa);
    var stack: std.ArrayList(u32) = .empty;
    defer stack.deinit(gpa);
    const held = try gpa.alloc(bool, graph.netCount());
    defer gpa.free(held);
    @memset(held, false);
    var examined: u64 = 0;
    for (pads) |p| {
        if (held[p.net] or graph.terminalsOn(p.net).devices.len == 0) continue;
        held[p.net] = true;
        examined += 1;
        const rails = try railsReached(gpa, graph, supply, clamps, p.net, &seen, &stack);
        if (rails < 2) try out.push(gpa, .{ .rule = rule, .layer = report.no_layer, .severity = .@"error", .at = p.at, .measured = .count(rails), .limit = .count(2), .shape_a = report.no_shape, .shape_b = report.no_shape });
    }
    return examined;
}

// ---- private ----

fn bond(a: Bbox, b: Bbox) bool {
    const meet = a.intersection(b) orelse return false;
    return meet.area() > 0;
}

fn lessPair(_: void, a: [2]u32, b: [2]u32) bool {
    return if (a[0] != b[0]) a[0] < b[0] else a[1] < b[1];
}

/// A box's centre at twice the scale.
fn twice(b: Bbox) [2]i128 {
    return .{ @as(i128, b.xlo) + b.xhi, @as(i128, b.ylo) + b.yhi };
}

fn root(parent: []u32, net_in: u32) u32 {
    var net = net_in;
    while (parent[net] != net) {
        const up = parent[parent[net]];
        parent[net] = up;
        net = up;
    }
    return net;
}

fn pinRow(rule: StrId, at: Point, measured: u32) report.Violation {
    return .{ .rule = rule, .layer = report.no_layer, .severity = .@"error", .at = at, .measured = .count(measured), .limit = .count(1), .shape_a = report.no_shape, .shape_b = report.no_shape };
}

fn byReference(pins: []const Pin, a: u32, b: u32) bool {
    return if (pins[a].reference != pins[b].reference) pins[a].reference < pins[b].reference else a < b;
}

fn byLayout(pins: []const Pin, a: u32, b: u32) bool {
    return if (pins[a].layout != pins[b].layout) pins[a].layout < pins[b].layout else a < b;
}
