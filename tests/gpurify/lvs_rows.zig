//! The rows `check_layout` records from the layout alone, and device
//! recognition's corner cases, as exhaustive fixtures. Ported from
//! tests/exhaustive/lvs.rs (`layout_rows`).
//!
//! Contents:
//! - `pub fn fixturesInto(arena: Allocator, depth: Depth, out: *std.ArrayList(Fixture)) !void`

const std = @import("std");
const Allocator = std.mem.Allocator;
const harness = @import("harness.zig");
const Depth = harness.Depth;
const Expect = harness.Expect;
const Finding = harness.Finding;
const Fixture = harness.Fixture;
const Layout = harness.Layout;
const Shape = harness.Shape;
const circuit = @import("lvs_circuit.zig");
const Dev = circuit.Dev;
const Circuit = circuit.Circuit;
const track = circuit.track;
const lf = @import("lvs_fixture.zig");
const step = lf.step;

/// The rows `check_layout` records from the layout alone (its doc
/// comment), and device recognition's corner cases.
pub fn fixturesInto(arena: Allocator, depth: Depth, out: *std.ArrayList(Fixture)) !void {
    _ = depth;
    const one = try Circuit.init(arena, 3, &.{Dev.mos(.n, 0, 1, 2)});
    try rangesInto(arena, &one, out);
    try countsInto(arena, out);
    try netsInto(arena, &one, out);
    try recognitionInto(arena, &one, out);
    try softInto(arena, out);
}

// ---- private ----

/// A fixture on `full_deck` plus `extra`, `layout` against `reference`.
fn ruled(arena: Allocator, name: []const u8, catalog: []const []const u8, extra: []const u8, layout: Layout, reference: []const u8) !Fixture {
    var f: Fixture = .init(name, catalog, try std.mem.concat(arena, u8, &.{ circuit.full_deck, extra }), lf.lvs);
    f.layout = layout;
    f.reference = reference;
    return f;
}

/// LVS-068: a deck's `lvs range` holds every device of the model to the
/// bounds on what is drawn: the `nmos` 1000 by 150 nm, the capacitor's
/// marker 0.32 um² (the drawer). A value at its bound is legal, a model
/// with no device is examined zero times, and another model is not held.
fn rangesInto(arena: Allocator, one: *const Circuit, out: *std.ArrayList(Fixture)) !void {
    const cap = try Circuit.init(arena, 2, &.{Dev.onPins(.c, &.{ 0, 1 })});
    const ranged = [_]struct { []const u8, *const Circuit, []const u8, []const Finding }{
        .{ "w_below_min", one, "\"nmos\" w >= 1100nm", &.{.length(1000)} },
        .{ "w_at_both_bounds", one, "\"nmos\" w >= 1000nm <= 1000nm", &.{} },
        .{ "l_above_max", one, "\"nmos\" l <= 100nm", &.{.length(150)} },
        .{ "nf_below_min", one, "\"nmos\" nf >= 2", &.{.any()} },
        .{ "other_model", one, "\"pmos\" w >= 1100nm", &.{} },
        .{ "C_area_below_min", &cap, "\"cmim\" area >= 0.4um2", &.{.area(320_000)} },
        .{ "C_area_within", &cap, "\"cmim\" area <= 0.32um2", &.{} },
    };
    for (ranged) |r| {
        var f = try ruled(arena, try std.fmt.allocPrint(arena, "lvs/range/{s}", .{r[0]}), &.{"LVS-068"}, try std.fmt.allocPrint(arena, "lvs range {s}\n", .{r[2]}), try circuit.draw(arena, r[1]), try circuit.spice(arena, r[1]));
        try f.claim(arena, .rule("lvs.param_range", r[3]));
        try out.append(arena, f);
    }
}

/// LVS-068: device counts. Three `nmos` and a `pmos` drawn: within `<= 3`
/// and `>= 3`, one over `<= 2` (measured 3), one under `>= 4` (measured
/// 3), and none of a model the layout lacks against `>= 1` (measured 0);
/// `pmos` is not held to an `nmos` row. The counts are the drawing's, by
/// construction.
fn countsInto(arena: Allocator, out: *std.ArrayList(Fixture)) !void {
    const three = try Circuit.init(arena, 3, &.{ Dev.mos(.n, 0, 1, 2), Dev.mos(.n, 1, 0, 2), Dev.mos(.n, 2, 0, 1), Dev.mos(.p, 0, 1, 2) });
    const counted = [_]struct { []const u8, []const u8, []const Finding }{
        .{ "within", "\"nmos\" >= 3 <= 3", &.{} },
        .{ "over", "\"nmos\" <= 2", &.{step(3)} },
        .{ "under", "\"nmos\" >= 4", &.{step(3)} },
        .{ "absent_model", "\"nmosb\" >= 1", &.{step(0)} },
        .{ "other_model", "\"pmos\" <= 1", &.{} },
    };
    for (counted) |r| {
        var f = try ruled(arena, try std.fmt.allocPrint(arena, "lvs/count/{s}", .{r[0]}), &.{"LVS-068"}, try std.fmt.allocPrint(arena, "lvs count {s}\n", .{r[1]}), try circuit.draw(arena, &three), try circuit.spice(arena, &three));
        try f.claim(arena, .rule("lvs.device_count", r[2]));
        try out.append(arena, f);
    }
}

/// `c` with one more net, `name`.
fn withNet(arena: Allocator, c: *const Circuit, name: []const u8, port: bool) !Circuit {
    var out = try c.clone(arena);
    out.names = try std.mem.concat(arena, []const u8, &.{ c.names, &.{name} });
    out.ports = try std.mem.concat(arena, bool, &.{ c.ports, &.{port} });
    return out;
}

/// Floating nets, label conflicts and shorts between named nets.
fn netsInto(arena: Allocator, one: *const Circuit, out: *std.ArrayList(Fixture)) !void {
    // LVS-006: an unlabelled track no terminal lands on floats; a labelled
    // one is a port and does not.
    const floating = try withNet(arena, one, "n3", false);
    var f = try lf.compared(arena, "checks/floating_net", &.{ "LVS-006", "LVS-015" }, &floating, one);
    // `lvs.floating_net` examines every net: the four tracks drawn.
    try f.claim(arena, Expect.rule("lvs.floating_net", &.{.any()}).examined(floating.nets()));
    try out.append(arena, f);
    var port = try floating.clone(arena);
    port.ports[3] = true;
    f = try lf.compared(arena, "checks/unused_port_is_not_floating", &.{ "LVS-006", "LVS-016" }, &port, &port);
    try f.claim(arena, Expect.clean("lvs.floating_net").examined(port.nets()));
    try out.append(arena, f);

    // LVS-001, LVS-002: one label on two nets is an open, not a join.
    // DRC-084: a pin's ports (its label on disjoint shapes) left unjoined,
    // what LEF58 MUSTJOINALLPORTS forbids at the top.
    var split = try Circuit.init(arena, 4, &.{ Dev.mos(.n, 0, 1, 2), Dev.mos(.n, 3, 1, 2) });
    split.names[3] = "n0";
    const joined = try Circuit.init(arena, 3, &.{ Dev.mos(.n, 0, 1, 2), Dev.mos(.n, 0, 1, 2) });
    f = try lf.compared(arena, "checks/label_on_two_nets", &.{ "LVS-001", "LVS-002", "LVS-015", "DRC-084" }, &split, &joined);
    try f.claim(arena, .rule("lvs.label_conflict", &.{.any()}));
    try out.append(arena, f);

    // LVS-002: the same open with n0 a must-connect label (KLayout's
    // `connect_implicit`): the two nets are one to compare, so the verdict
    // is a match, and the open is still reported, as a warning, so the run
    // passes.
    f = try ruled(arena, "lvs/checks/label_on_two_nets_must_connect", &.{ "LVS-002", "LVS-001" }, "lvs connect_implicit \"n*\"\n", try circuit.draw(arena, &split), try circuit.spice(arena, &joined));
    try f.claim(arena, .{ .lvs = true });
    try f.claim(arena, .rule("lvs.label_conflict", &.{.any()}));
    try f.claim(arena, .{ .passes = true });
    try out.append(arena, f);

    // F13, F14, LVS-001, LVS-005: two labels on one net is a short between
    // named nets, which must be reported, not abort the run.
    var shorted = try circuit.draw(arena, one);
    try shorted.label(arena, "met2_label", -800, track(0) + 100, "other");
    f = try lf.withText(arena, "checks/two_labels_on_one_net", &.{ "LVS-001", "LVS-005" }, shorted, try circuit.spice(arena, one));
    try f.claim(arena, .rule("lvs.net_seed_conflict", &.{.any()}));
    try f.claim(arena, .rule("lvs.short_path", &.{step(1)}));
    try out.append(arena, f);
    // LVS-005: where the short runs. A met1 bridge, a via1 at each end,
    // joins track n0 to track n1, so labels n0 and n1 are on one net, and
    // the fewest polygons between their tracks are the track, the bridge
    // and the other track: two steps, each reported (derived by hand; the
    // transistor joins n0 to no other track).
    const x = -600;
    var bridged = try circuit.draw(arena, one);
    try bridged.rect(arena, "met1", x, track(0), x + 200, track(1) + 200);
    try bridged.rect(arena, "via1", x, track(0), x + 200, track(0) + 200);
    try bridged.rect(arena, "via1", x, track(1), x + 200, track(1) + 200);
    f = try lf.withText(arena, "checks/short_path_through_a_bridge", &.{"LVS-005"}, bridged, try circuit.spice(arena, one));
    try f.claim(arena, .rule("lvs.net_seed_conflict", &.{.any()}));
    try f.claim(arena, .rule("lvs.short_path", &.{ step(1), step(2) }));
    try out.append(arena, f);
}

/// The pad of pin `k` of a device in the column at `x0`, as a rectangle
/// outline.
fn pad(arena: Allocator, x0: i64, k: i64) ![]const [2]i64 {
    const x = x0 + 800 * k;
    return arena.dupe([2]i64, &.{ .{ x, 0 }, .{ x + 400, 0 }, .{ x + 400, 400 }, .{ x, 400 } });
}

fn samePoints(a: []const [2]i64, b: []const [2]i64) bool {
    if (a.len != b.len) return false;
    for (a, b) |p, q| if (p[0] != q[0] or p[1] != q[1]) return false;
    return true;
}

/// Device recognition's corner cases.
fn recognitionInto(arena: Allocator, one: *const Circuit, out: *std.ArrayList(Fixture)) !void {
    // LVS-004: a MOS recogniser with two terminals. Its source and drain
    // share a net, so the second diffusion is the first drawn twice and the
    // device is recognised with two terminals.
    const shorted = try Circuit.init(arena, 2, &.{Dev.mos(.n, 0, 1, 1)});
    const layout = try circuit.draw(arena, &shorted);
    for (layout.shapes.items) |*shape| if (std.mem.eql(u8, shape.layer, "nsdm")) {
        shape.layer = "tsdm";
    };
    var f = try ruled(arena, "lvs/checks/two_terminal_mos", &.{"LVS-004"}, "layer tsdm = gds(20, 0)\nlayer gate_t = gate and tsdm\ndevice mos gate_t model \"nmos2\" terminals [poly, diff_active]\n", layout, try circuit.spice(arena, &shorted));
    // `lvs.terminal_count` examines every device: the one transistor drawn.
    try f.claim(arena, Expect.rule("lvs.terminal_count", &.{.any()}).examined(shorted.devs.len));
    try out.append(arena, f);

    // F32 (fixed in B9), LVS-004: a MOS drawn without its drain is
    // malformed, and is reported rather than silently not a device.
    const drawn = try circuit.draw(arena, one);
    var no_drain: Layout = .{};
    for (drawn.shapes.items) |shape| if (!std.mem.eql(u8, shape.layer, "diff")) try no_drain.shapes.append(arena, shape);
    no_drain.labels = drawn.labels;
    try no_drain.rect(arena, "diff", 0, 0, circuit.sd + 150, 1000);
    f = try lf.withText(arena, "checks/mos_without_drain", &.{ "LVS-004", "LVS-012" }, no_drain, try circuit.spice(arena, one));
    try f.claim(arena, .rule("lvs.terminal_net", &.{.any()}));
    try out.append(arena, f);

    // F33 (fixed in B9), LVS-004: a resistor pad drawn twice is one pad,
    // whichever copy comes first.
    const res = try Circuit.init(arena, 2, &.{Dev.onPins(.r, &.{ 0, 1 })});
    const twice: Shape = .{ .layer = "pina", .points = try pad(arena, 0, 0) };
    var first = try circuit.draw(arena, &res);
    try first.shapes.insert(arena, 0, twice);
    var last = try circuit.draw(arena, &res);
    try last.shapes.append(arena, twice);
    // F69 (fixed in B21), LVS-004: the first pad drawn twice and the second
    // missing is one shape for two ends. The resistor is no device and is
    // reported, where it used to bind with both ends on the first pad's net.
    const second = try pad(arena, 0, 1);
    const res_drawn = try circuit.draw(arena, &res);
    var lonely: Layout = .{ .labels = res_drawn.labels };
    for (res_drawn.shapes.items) |shape| if (!(std.mem.eql(u8, shape.layer, "pina") and samePoints(shape.points, second))) try lonely.shapes.append(arena, shape);
    try lonely.shapes.append(arena, twice);
    f = try lf.withText(arena, "checks/pad_drawn_twice_other_missing", &.{ "LVS-004", "LVS-012" }, lonely, try circuit.spice(arena, &res));
    try f.claim(arena, .rule("lvs.terminal_net", &.{.any()}));
    try out.append(arena, f);
    const rows: []const []const u8 = &.{ "LVS-004", "LVS-012" };
    f = try lf.withText(arena, "checks/pad_drawn_twice_last", rows, last, try circuit.spice(arena, &res));
    try f.claim(arena, .{ .lvs = true });
    try out.append(arena, f);
    f = try lf.withText(arena, "checks/pad_drawn_twice_first", rows, first, try circuit.spice(arena, &res));
    try f.claim(arena, .{ .lvs = true });
    try out.append(arena, f);
}

/// LVS-003: two unlabelled tracks joined only through `pwell`, a soft
/// layer, are one net held together by it; one tap into the well is not.
/// With `crossing`, the second stub passes under the first track with no
/// via, which is no join (F27, fixed).
fn softInto(arena: Allocator, out: *std.ArrayList(Fixture)) !void {
    const deck = circuit.full_deck ++ "rule soft soft_connection(pwell)\n";
    const cases = [_]struct { []const u8, []const usize, bool, ?[]const u8 }{
        .{ "checks/soft_connection", &.{ 0, 1 }, false, null },
        .{ "checks/soft_connection_under_a_track", &.{ 0, 1 }, true, null },
        .{ "checks/one_tap_is_not_soft", &.{0}, false, null },
    };
    for (cases) |case| {
        var layout: Layout = .{};
        try layout.rect(arena, "pwell", 0, 0, 3000, 1000);
        for (case[1]) |net| {
            const x = 100 + 2500 * @as(i64, @intCast(net));
            try layout.rect(arena, "tap", x, 100, x + 300, 400);
            // A met1 stub up to the net's track, with the via there.
            const t = track(net);
            try layout.rect(arena, "met1", x, 100, x + 300, t + 200);
            try layout.rect(arena, "via1", x, t, x + 300, t + 200);
            const left: i64 = if (case[2]) -1000 else x - 200;
            const right: i64 = if (case[2]) 3000 else x + 500;
            try layout.rect(arena, "met2", left, t, right, t + 200);
        }
        const findings: []const Finding = if (case[1].len == 2) &.{.any()} else &.{};
        var f: Fixture = .init(try std.fmt.allocPrint(arena, "lvs/{s}", .{case[0]}), &.{"LVS-003"}, deck, .{ .erc = true });
        f.layout = layout;
        try f.claim(arena, .rule("soft", findings));
        f.known = case[3];
        try out.append(arena, f);
    }
}

test "every layout-row fixture holds" {
    // Oracle: hand-derived from each row's definition (the comments above):
    // ranges and counts against the drawing by construction, floating and
    // conflicting labels, recognition's corner cases, soft connections.
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    var fixtures: std.ArrayList(Fixture) = .empty;
    try fixturesInto(arena.allocator(), .merge, &fixtures);
    try harness.checkAll(fixtures.items);
}
