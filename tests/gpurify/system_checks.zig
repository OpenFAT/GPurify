//! The multi-die checks against hand-derived answers. Ported from
//! crates/check/src/system.rs's tests.

const std = @import("std");
const testing = std.testing;
const Allocator = std.mem.Allocator;
const geom = @import("geom");
const Bbox = geom.Bbox;
const check = @import("check");
const report = check.report;
const Graph = check.lvs.Graph;
const testgen = @import("testgen");
const sys = @import("gpurify").system_checks;
const gpa = testing.allocator;

const Dev = struct { u32, []const u32 };

const World = struct {
    arena_state: std.heap.ArenaAllocator,
    strings: geom.StrTable = .empty,
    out: report.Violations = .{},
    runs: std.ArrayList(report.RuleRun) = .empty,

    fn init() !World {
        var w: World = .{ .arena_state = .init(gpa) };
        try sys.internRuleIds(w.arena(), &w.strings);
        return w;
    }

    fn deinit(w: *World) void {
        w.arena_state.deinit();
    }

    fn arena(w: *World) Allocator {
        return w.arena_state.allocator();
    }
};

const Face = struct { err: ?anyerror, bumps: []const sys.Bump, net: check.topology.NetId };

// ---- private ----

fn rect(xlo: i64, ylo: i64, xhi: i64, yhi: i64) Bbox {
    return Bbox.point(xlo, ylo).include(xhi, yhi);
}

fn bump(net: u32, at: Bbox) sys.Bump {
    return .{ .poly = @fromBackingInt(net), .net = @fromBackingInt(net), .at = at };
}

fn pin(reference: u32, layout: u32, x: i64) sys.Pin {
    return .{ .reference = reference, .layout = layout, .at = .{ .x = x, .y = 0 } };
}

/// A die graph by hand: devices as (model, terminal nets), all pin roles,
/// one parameter (0, model); names per net; ports the named nets.
fn die(a: Allocator, devices: []const Dev, names_in: []const ?u32) !Graph {
    var g: Graph = .{};
    try g.device_terminal_start.append(a, 0);
    try g.device_param_start.append(a, 0);
    for (devices) |d| {
        try g.device_kind.append(a, .diode);
        try g.device_model.append(a, @fromBackingInt(d[0]));
        for (d[1], 0..) |n, k| {
            try g.terminal_net.append(a, n);
            try g.terminal_role.append(a, .{ .pin = @intCast(k) });
        }
        try g.device_terminal_start.append(a, @intCast(g.terminal_net.items.len));
        try g.param.append(a, .{ .name = @fromBackingInt(0), .value = @floatFromInt(d[0]) });
        try g.device_param_start.append(a, @intCast(g.param.items.len));
    }
    for (names_in, 0..) |n, i| {
        try g.net_name.append(a, if (n) |v| @fromBackingInt(v) else null);
        if (n != null) try g.port_net.append(a, @intCast(i));
    }
    try check.lvs.graph.transposeInto(a, &g, @intCast(names_in.len));
    return g;
}

fn names(a: Allocator, g: *const Graph) ![]const ?u32 {
    const out = try a.alloc(?u32, g.net_name.items.len);
    for (g.net_name.items, out) |n, *o| o.* = if (n) |v| @backingInt(v) else null;
    return out;
}

fn rowsOf(a: Allocator, out: *const report.Violations, rule: geom.StrId) ![]const report.Violation {
    var rows: std.ArrayList(report.Violation) = .empty;
    for (0..out.len()) |i| if (out.rule.items[i] == rule) try rows.append(a, out.get(@intCast(i)));
    return rows.items;
}

/// A one-layer face: a 10 x 20 rectangle on layer 0 and maybe one more
/// shape, layer 0 a conductor when `connected`, bumps placed by (100, 200).
fn face(a: Allocator, extra: ?struct { []const i64, []const i64 }, connected: bool) !Face {
    var lb: testgen.shapes.LayoutBuilder = .init(1);
    _ = try lb.rect(a, 0, 0, 0, 10, 20);
    if (extra) |e| _ = try lb.push(a, 0, e[0], e[1]);
    var store: geom.GeometryStore = .empty;
    var ids: testgen.shapes.Ids = .{};
    try lb.finish(a, &store, &ids);
    const metal: geom.LayerId = @fromBackingInt(0);
    var nets: check.topology.NetTable = .{};
    try check.topology.extractNetsInto(a, &store, &.{ .conductors = if (connected) &.{metal} else &.{}, .intra_layer_touch = true }, &nets);
    const devices: check.topology.DeviceTable = .{};
    const design: check.lvs.Design = .{ .store = &store, .nets = &nets, .devices = &devices };
    const placement: sys.Placement = .{ .dx = 100, .dy = 200 };
    var out: std.ArrayList(sys.Bump) = .empty;
    var bad: geom.PolyId = undefined;
    try out.append(a, bump(9, rect(0, 0, 1, 1)));
    try sys.bumpsInto(a, design, @fromBackingInt(7), placement, &out, &bad);
    try testing.expectEqual(0, out.items.len);
    var err: ?anyerror = null;
    sys.bumpsInto(a, design, metal, placement, &out, &bad) catch |e| {
        err = e;
    };
    return .{ .err = err, .bumps = out.items, .net = nets.netOf(ids.of(@fromBackingInt(@intCast(0)))) };
}

test "a placement reflects then turns then moves" {
    // Oracle: hand-derived. (3, 1) reflected in x is (3, -1); a quarter turn
    // counter-clockwise takes (x, y) to (-y, x): (-1, 3), two turns (-3, -1),
    // five turns are one; the move is added last. A box maps to a box.
    const at = struct {
        fn f(p: sys.Placement) [2]i64 {
            const q = p.apply(.{ .x = 3, .y = 1 });
            return .{ q.x, q.y };
        }
    }.f;
    try testing.expectEqual([2]i64{ 3, 1 }, at(.{}));
    try testing.expectEqual([2]i64{ 3, -1 }, at(.{ .mirror = true }));
    try testing.expectEqual([2]i64{ -1, 3 }, at(.{ .quarter_turns = 1 }));
    try testing.expectEqual([2]i64{ -3, -1 }, at(.{ .quarter_turns = 2 }));
    try testing.expectEqual([2]i64{ -1, 3 }, at(.{ .quarter_turns = 5 }));
    // Reflected to (3, -1), then turned to (1, 3), then moved.
    const p: sys.Placement = .{ .mirror = true, .quarter_turns = 1, .dx = 10, .dy = 20 };
    try testing.expectEqual([2]i64{ 11, 23 }, at(p));
    try testing.expectEqual(rect(10, 20, 12, 24), p.applyBox(rect(0, 0, 4, 2)));
}

test "bumps bond where they share area and not where they touch" {
    // Oracle: hand-derived overlaps: each of `a` overlaps the one of `b`
    // drawn on it, a bump shifted half a width still shares area, one only
    // touching shares none, one far away nothing; ascending whatever order
    // `b` is in; a pad wider than `b`'s cells finds every bump under it.
    const a = [_]sys.Bump{ bump(0, rect(0, 0, 10, 10)), bump(1, rect(100, 0, 110, 10)), bump(2, rect(200, 0, 210, 10)), bump(3, rect(300, 0, 310, 10)) };
    const b = [_]sys.Bump{ bump(9, rect(305, 5, 315, 15)), bump(8, rect(210, 0, 220, 10)), bump(7, rect(100, 0, 110, 10)), bump(6, rect(0, 0, 10, 10)), bump(5, rect(5000, 0, 5010, 10)) };
    var out: std.ArrayList([2]u32) = .empty;
    defer out.deinit(gpa);
    try sys.bondedPairsInto(gpa, &a, &b, &out);
    try testing.expectEqualSlices([2]u32, &.{ .{ 0, 3 }, .{ 1, 2 }, .{ 3, 0 } }, out.items);
    try sys.bondedPairsInto(gpa, &a, &.{}, &out);
    try testing.expectEqual(0, out.items.len);
    try sys.bondedPairsInto(gpa, &.{}, &b, &out);
    try testing.expectEqual(0, out.items.len);
    try sys.bondedPairsInto(gpa, &.{bump(0, rect(-50, -50, 400, 60))}, &b, &out);
    try testing.expectEqualSlices([2]u32, &.{ .{ 0, 0 }, .{ 0, 1 }, .{ 0, 2 }, .{ 0, 3 } }, out.items);
}

test "a bump with no mate is unbonded" {
    // Oracle: hand-derived from `checkBonds`' doc: of two faces of two bumps
    // each one pair bonds, so the other bump of each face is a row at its
    // centre, measured 0 against 1; all four were examined.
    var w: World = try .init();
    defer w.deinit();
    const a = [_]sys.Bump{ bump(0, rect(0, 0, 10, 10)), bump(1, rect(100, 0, 110, 10)) };
    const b = [_]sys.Bump{ bump(2, rect(0, 0, 10, 10)), bump(3, rect(200, 0, 210, 10)) };
    var pairs: [1][]const [2]u32 = undefined;
    try sys.checkBonds(w.arena(), &.{.{ &a, &b }}, &w.strings, &w.out, &w.runs, &pairs);
    try testing.expectEqualSlices([2]u32, &.{.{ 0, 0 }}, pairs[0]);
    try testing.expectEqual(1, w.runs.items.len);
    try testing.expectEqual(4, w.runs.items[0].examined);
    try testing.expectEqual(2, w.runs.items[0].violations);
    try testing.expectEqual(geom.Point{ .x = 105, .y = 5 }, w.out.at.items[0]);
    try testing.expectEqual(@as(u32, 1), @backingInt(w.out.shape_a.items[0]));
    try testing.expectEqual(geom.Point{ .x = 205, .y = 5 }, w.out.at.items[1]);
    try testing.expectEqual(@as(u32, 3), @backingInt(w.out.shape_a.items[1]));
    for (0..2) |i| try testing.expect(w.out.get(@intCast(i)).measured.eql(.count(0)));
}

test "assembling merges bonded nets and keeps every device" {
    // Oracle: hand-derived. Die A (nets 0..3) and die B (3..5) with A's 1
    // joined to B's 0 and A's 2 to B's 1: five nets become classes {0},
    // {1, 3}, {2, 4}; B's device lands on 1 and 2; A's unnamed net 1 takes
    // B's name, and is a port. Nothing joined: the dies side by side.
    var w: World = try .init();
    defer w.deinit();
    const a = try die(w.arena(), &.{ .{ 7, &.{ 0, 1 } }, .{ 8, &.{ 1, 2 } } }, &.{ 10, null, 12 });
    const b = try die(w.arena(), &.{.{ 9, &.{ 0, 1 } }}, &.{ 20, 21 });
    var g: Graph = .{};
    var class: std.ArrayList(u32) = .empty;
    try sys.assemble(w.arena(), &.{ &a, &b }, &.{ .{ 1, 3 }, .{ 4, 2 } }, &g, &class);
    try testing.expectEqualSlices(u32, &.{ 0, 1, 2, 1, 2 }, class.items);
    try testing.expectEqual(3, g.netCount());
    try testing.expectEqual(3, g.deviceCount());
    try testing.expectEqualSlices(u32, &.{ 1, 2 }, g.terminalsOf(2).nets);
    try testing.expectEqualSlices(u32, &.{ 1, 2 }, g.terminalsOf(1).nets);
    try testing.expectEqualSlices(u32, &.{ 7, 8, 9 }, std.mem.bytesAsSlice(u32, std.mem.sliceAsBytes(g.device_model.items)));
    try testing.expectEqual(@as(f64, 9.0), g.paramsOf(2)[0].value);
    try testing.expectEqualSlices(?u32, &.{ 10, 20, 12 }, try names(w.arena(), &g));
    try testing.expectEqualSlices(u32, &.{ 0, 1, 2 }, g.port_net.items);
    try testing.expectEqualSlices(u32, &.{ 0, 1, 2 }, g.terminalsOn(1).devices);
    var apart: Graph = .{};
    try sys.assemble(w.arena(), &.{ &a, &b }, &.{}, &apart, &class);
    try testing.expectEqualSlices(u32, &.{ 0, 1, 2, 3, 4 }, class.items);
    try testing.expectEqualSlices(u32, &.{ 3, 4 }, apart.terminalsOf(2).nets);
}

test "pins split or joined against the netlist are opens and shorts" {
    // Oracle: hand-derived from `checkPins`' doc: p0, p1 on system net 0 land
    // on assembled 5 and 6 (an open at p1, measured 2); p2 on system net 1
    // lands on 6 with p1 (a short at p2); p3 has no label (an open measured
    // 0); p4 on system net 1 lands on 6 too.
    var w: World = try .init();
    defer w.deinit();
    const none = std.math.maxInt(u32);
    try sys.checkPins(w.arena(), &.{ pin(0, 5, 0), pin(0, 6, 1), pin(1, 6, 2), pin(1, none, 3), pin(1, 6, 4) }, &w.strings, &w.out, &w.runs);
    const want = [_]struct { []const u8, i64, u32 }{ .{ "system.open", 1, 2 }, .{ "system.open", 3, 0 }, .{ "system.short", 2, 2 } };
    try testing.expectEqual(want.len, w.out.len());
    for (want, 0..) |row, i| {
        const v = w.out.get(@intCast(i));
        try testing.expectEqualStrings(row[0], w.strings.resolve(v.rule));
        try testing.expectEqual(row[1], v.at.x);
        try testing.expect(v.measured.eql(.count(row[2])));
    }
    try testing.expectEqual(2, w.runs.items.len);
    for (w.runs.items) |r| try testing.expectEqual(5, r.examined);
    w.out = .{};
    try sys.checkPins(w.arena(), &.{ pin(0, 5, 0), pin(0, 5, 1), pin(1, 6, 2) }, &w.strings, &w.out, &w.runs);
    try testing.expectEqual(0, w.out.len());
}

test "rails are reached through clamps and supplies only" {
    // Oracle: hand-derived on the documented search. Nets: 0 pad, 1 power,
    // 2 ground, 3 a signal, 4 a second ground; model 1 is a clamp, model 2
    // none. Through a signal net nothing passes, and a clamp joins every
    // terminal it has.
    var w: World = try .init();
    defer w.deinit();
    const supply = [_]u8{ 0, sys.power, sys.ground, 0, sys.ground };
    const clamp = [_]geom.StrId{@fromBackingInt(1)};
    const cases = [_]struct { []const Dev, []const geom.StrId, u32 }{
        .{ &.{ .{ 1, &.{ 0, 1 } }, .{ 1, &.{ 1, 2 } } }, &clamp, 2 },
        .{ &.{.{ 1, &.{ 0, 1 } }}, &clamp, 1 },
        .{ &.{ .{ 2, &.{ 0, 1 } }, .{ 2, &.{ 1, 2 } } }, &clamp, 0 },
        // Pad to a signal net, the signal net clamped to both rails: blocked.
        .{ &.{ .{ 1, &.{ 0, 3 } }, .{ 1, &.{ 3, 1 } }, .{ 1, &.{ 3, 2 } } }, &clamp, 0 },
        // One three-terminal clamp from the pad to both rails.
        .{ &.{.{ 1, &.{ 1, 0, 4 } }}, &clamp, 2 },
        .{ &.{.{ 1, &.{ 1, 0, 4 } }}, &.{}, 0 },
    };
    var seen: std.ArrayList(bool) = .empty;
    var stack: std.ArrayList(u32) = .empty;
    for (cases) |c| {
        const unnamed: [5]?u32 = @splat(null);
        const g = try die(w.arena(), c[0], &unnamed);
        try testing.expectEqual(c[2], try sys.railsReached(w.arena(), &g, &supply, c[1], 0, &seen, &stack));
    }
}

test "an esd row holds each pad net once" {
    // Oracle: hand-derived from `esdPadsInto`'s doc: of pads on nets 0
    // (clamped to power only), 0 again, 3 (no device) and 5 (clamped to
    // both), net 0 is one row measured 1 at its first place, net 3 is not
    // examined, and two nets were.
    var w: World = try .init();
    defer w.deinit();
    const rule = report.ruleId(&w.strings, "system.esd_package");
    const unnamed: [6]?u32 = @splat(null);
    const g = try die(w.arena(), &.{ .{ 1, &.{ 0, 1 } }, .{ 1, &.{ 5, 1 } }, .{ 1, &.{ 5, 2 } } }, &unnamed);
    const supply = [_]u8{ 0, sys.power, sys.ground, 0, 0, 0 };
    const examined = try sys.esdPadsInto(w.arena(), rule, &g, &supply, &.{@fromBackingInt(1)}, &.{ .{ .net = 0, .at = .{ .x = 1, .y = 0 } }, .{ .net = 0, .at = .{ .x = 2, .y = 0 } }, .{ .net = 3, .at = .{ .x = 3, .y = 0 } }, .{ .net = 5, .at = .{ .x = 4, .y = 0 } } }, &w.out);
    try testing.expectEqual(2, examined);
    try testing.expectEqual(1, w.out.len());
    try testing.expectEqual(1, w.out.at.items[0].x);
    try testing.expect(w.out.get(0).measured.eql(.count(1)));
}

test "a bond offset over its limit is one row at the middle of the centres" {
    // Oracle: hand-derived from `checkAlignment`'s doc. Bonded bumps [0, 10]²
    // and [3, 13] x [4, 14] have centres (5, 5) and (8, 9), 5 apart (3-4-5):
    // over a 4 offset one row at the floored middle (6, 7), measured 5; at a
    // 5 offset none. A bond stating no offset adds nothing and is not
    // examined; with no bond stating one there is no row at all.
    var w: World = try .init();
    defer w.deinit();
    const rule = report.ruleId(&w.strings, "system.bump_offset");
    const a = [_]sys.Bump{bump(1, rect(0, 0, 10, 10))};
    const b = [_]sys.Bump{bump(2, rect(3, 4, 13, 14))};
    const bonds = [2][2][]const sys.Bump{ .{ &a, &b }, .{ &a, &b } };
    const pairs = [2][]const [2]u32{ &.{.{ 0, 0 }}, &.{.{ 0, 0 }} };
    for ([_]struct { i64, bool }{ .{ 4, true }, .{ 5, false } }) |row| {
        w.out = .{};
        w.runs = .empty;
        try sys.checkAlignment(w.arena(), &bonds, &pairs, &.{ .{ row[0], null }, .{ null, 1 } }, &w.strings, &w.out, &w.runs);
        const found = try rowsOf(w.arena(), &w.out, rule);
        if (row[1]) {
            try testing.expectEqual(1, found.len);
            try testing.expectEqual(geom.Point{ .x = 6, .y = 7 }, found[0].at);
            try testing.expect(found[0].measured.eql(.length(5)) and found[0].limit.eql(.length(4)));
            try testing.expectEqual(@as(u32, 1), @backingInt(found[0].shape_a));
            try testing.expectEqual(@as(u32, 2), @backingInt(found[0].shape_b));
        } else try testing.expectEqual(0, found.len);
        const run = for (w.runs.items) |r| (if (r.rule == rule) break r) else unreachable;
        try testing.expectEqual(1, run.examined);
    }
    w.out = .{};
    w.runs = .empty;
    try sys.checkAlignment(w.arena(), bonds[0..1], pairs[0..1], &.{.{ null, null }}, &w.strings, &w.out, &w.runs);
    try testing.expect(w.runs.items.len == 0 and w.out.len() == 0);
}

test "a facing bump closer than the space is a row at the middle of the gap" {
    // Oracle: hand-derived from `checkAlignment`'s doc and the box gap. Bump
    // [0, 10]² faces one it bonds (skipped), one at [13, 23] x [14, 24]
    // (gaps 3 and 4: 5 apart, middle (11, 12) floored) and one at [-5, -2] x
    // [2, 8] (2 apart, middle (-1, 5)). Under a 6 space both are rows, in
    // facing order; under 5 only the 2; every bump of both faces examined.
    var w: World = try .init();
    defer w.deinit();
    const rule = report.ruleId(&w.strings, "system.bump_space");
    const a = [_]sys.Bump{bump(1, rect(0, 0, 10, 10))};
    const b = [_]sys.Bump{ bump(2, rect(0, 0, 10, 10)), bump(3, rect(13, 14, 23, 24)), bump(4, rect(-5, 2, -2, 8)) };
    for ([_]struct { i64, []const [4]i64 }{ .{ 6, &.{ .{ 11, 12, 5, 3 }, .{ -1, 5, 2, 4 } } }, .{ 5, &.{.{ -1, 5, 2, 4 }} } }) |row| {
        w.out = .{};
        w.runs = .empty;
        try sys.checkAlignment(w.arena(), &.{.{ &a, &b }}, &.{&.{.{ 0, 0 }}}, &.{.{ null, row[0] }}, &w.strings, &w.out, &w.runs);
        const found = try rowsOf(w.arena(), &w.out, rule);
        try testing.expectEqual(row[1].len, found.len);
        for (row[1], found) |want, v| {
            try testing.expectEqual(geom.Point{ .x = want[0], .y = want[1] }, v.at);
            try testing.expect(v.measured.eql(.length(want[2])) and v.limit.eql(.length(row[0])));
            try testing.expectEqual(@as(u32, @intCast(want[3])), @backingInt(v.shape_b));
        }
        try testing.expectEqual(1, w.runs.items.len);
        try testing.expectEqual(4, w.runs.items[0].examined);
    }
    // The gap and its middle are symmetric in the two boxes.
    const p = rect(0, 0, 10, 10);
    const q = rect(13, 14, 23, 24);
    try testing.expectEqual(check.rects.gapMidpoint(p, q), check.rects.gapMidpoint(q, p));
    try testing.expectEqual(@as(i128, 25), check.rects.bboxGap2(q, p));
    try testing.expectEqual(@as(i128, 4), check.rects.bboxGap2(rect(-5, 2, -2, 8), p));
    try testing.expectEqual(@as(i128, 0), check.rects.bboxGap2(p, rect(5, 5, 20, 20)));
}

test "a face is its rectangles on nets and nothing else" {
    // Oracle: `bumpsInto`'s doc. On a conductor a rectangle is a bump on its
    // net, placed; a quadrilateral that is no rectangle and an L of six
    // vertices refuse as not rectangles; on a layer the deck does not
    // connect the rectangle is on no net; a layer past the store's holds none.
    var w: World = try .init();
    defer w.deinit();
    {
        const f = try face(w.arena(), null, true);
        try testing.expect(f.err == null);
        try testing.expect(f.net != .none);
        try testing.expectEqual(1, f.bumps.len);
        try testing.expectEqual(rect(100, 200, 110, 220), f.bumps[0].at);
        try testing.expectEqual(f.net, f.bumps[0].net);
    }
    try testing.expectEqual(error.NotRectangle, (try face(w.arena(), .{ &.{ 30, 40, 30, 20 }, &.{ 0, 10, 20, 10 } }, true)).err.?);
    try testing.expectEqual(error.NotRectangle, (try face(w.arena(), .{ &.{ 20, 40, 40, 30, 30, 20 }, &.{ 0, 0, 20, 20, 10, 10 } }, true)).err.?);
    try testing.expectEqual(error.NoNet, (try face(w.arena(), null, false)).err.?);
}
