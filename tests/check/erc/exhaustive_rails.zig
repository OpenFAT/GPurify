//! The power-grid helpers of the exhaustive electrical groups: met1 rails
//! loaded by resistor markers (closed_form.zig's process and `loadAt`), the
//! series ladder's closed-form drops and edge currents, the limits between
//! a set of values, and the sign-off intent. Ported from
//! tests/exhaustive/erc.rs (`rail_deck`, `rail`, `ladder`, `between`,
//! `intent`, `vdd_intent`, `microamps`, `ohms`, `MET1_SHEET`, `K_EV`,
//! `T_SIGNOFF`).
//!
//! Every slice here is the caller's arena's or a constant.
//!
//! Contents:
//! - `pub const met1_sheet`, `pub const k_ev`, `pub const t_signoff`, `pub const Node`, `pub const Edge`, `pub const Ladder`
//! - `pub fn railDeck(arena, rules) ![]const u8`, `pub fn rail(l: *Layout, arena, net, len, y, width, loads: []const i64) !void`
//! - `pub fn ladder(arena, len: i64, width: i64, loads: []const i64, budget: f64) !Ladder`, `pub fn between(arena, values: []const f64) ![]const f64`
//! - `pub fn intent(arena, supplies: []const [2][]const u8, limits) ![]const u8`, `pub fn vddIntent(arena, budget: f64) ![]const u8`, `pub fn intentAt(arena, mv: f64, supplies, limits) ![]const u8`
//! - `pub fn microamps(x: f64) Finding`, `pub fn ohms(x: f64) Finding`, `pub fn at(f: Finding, x: i64, y: i64) Finding`
//! - `pub fn rules(arena, comptime fmt, args) ![]const u8`, `pub fn claim(arena, id, findings: []const Finding) ![]const Expect`, `pub fn checkGroup(comptime group) !void`

const std = @import("std");
const Allocator = std.mem.Allocator;
const fixture = @import("fixture.zig");
const Layout = fixture.Layout;
const Finding = fixture.Finding;
const Expect = fixture.Expect;
const Fixture = fixture.Fixture;
const cf = @import("closed_form.zig");

/// met1 sheet resistance, Ω per square.
pub const met1_sheet: f64 = 0.125;

/// Boltzmann's constant in eV/K (CODATA 2018).
pub const k_ev: f64 = 8.617_333_262e-5;

/// The intents' sign-off temperature, 85 °C, in kelvin.
pub const t_signoff: f64 = 85.0 + 273.15;

/// A ladder node: its x and its drop, mV.
pub const Node = struct { x: i64, drop: f64 };

/// A rail segment between adjacent nodes: lower x, upper x, current µA.
pub const Edge = struct { a: i64, b: i64, current: f64 };

pub const Ladder = struct { nodes: []const Node, edges: []const Edge };

/// closed_form.zig's process, its poly row included, then `rules`.
pub fn railDeck(arena: Allocator, rule_text: []const u8) ![]const u8 {
    return std.mem.concat(arena, u8, &.{ cf.process, rule_text, "\n" });
}

/// `railDeck` of formatted rule text.
pub fn rules(arena: Allocator, comptime fmt: []const u8, args: anytype) ![]const u8 {
    return railDeck(arena, try std.fmt.allocPrint(arena, fmt, args));
}

/// A met1 rail `[0, len] × [y, y + width]` named `net`, with loads on its
/// lower edge at `loads`.
pub fn rail(l: *Layout, arena: Allocator, net: []const u8, len: i64, y: i64, width: i64, loads: []const i64) !void {
    try l.rect(arena, "met1", 0, y, len, y + width);
    try l.label(arena, "met1_text", @divTrunc(len, 4), y + @divTrunc(width, 2), net);
    for (loads) |x| try cf.loadAt(arena, l, x, y);
}

/// One rail fed at its centre `len / 2`, each of its loads drawing
/// `budget / loads` µA: Ohm's law along the series ladder. Returns the nodes
/// (the pad and every load) with their drop, mV, and the edges between
/// adjacent nodes.
pub fn ladder(arena: Allocator, len: i64, width: i64, loads: []const i64, budget: f64) !Ladder {
    const pad = @divTrunc(len, 2);
    const share = budget / @as(f64, @floatFromInt(loads.len));
    var xs: std.ArrayList(i64) = .empty;
    try xs.appendSlice(arena, loads);
    try xs.append(arena, pad);
    std.mem.sortUnstable(i64, xs.items, {}, std.sort.asc(i64));
    var kept: usize = 0;
    for (xs.items) |x| if (kept == 0 or xs.items[kept - 1] != x) {
        xs.items[kept] = x;
        kept += 1;
    };
    const nodes_x = xs.items[0..kept];
    const edges = try arena.alloc(Edge, nodes_x.len - 1);
    for (edges, nodes_x[0 .. nodes_x.len - 1], nodes_x[1..]) |*e, a, b| {
        // The loads on the far side of the edge from the pad.
        var beyond: usize = 0;
        for (loads) |x| beyond += @intFromBool(if (b <= pad) x <= a else x >= b);
        e.* = .{ .a = a, .b = b, .current = share * @as(f64, @floatFromInt(beyond)) };
    }
    const nodes = try arena.alloc(Node, nodes_x.len);
    for (nodes, nodes_x) |*n, x| {
        var drop: f64 = 0.0;
        for (edges) |e| {
            const on_path = if (x > pad) e.a >= pad and e.b <= x else e.b <= pad and e.a >= x;
            if (on_path) drop += met1_sheet * @as(f64, @floatFromInt(e.b - e.a)) / @as(f64, @floatFromInt(width)) * e.current / 1000.0;
        }
        n.* = .{ .x = x, .drop = drop };
    }
    return .{ .nodes = nodes, .edges = edges };
}

/// The limits between and around a set of values: below the least, between
/// each adjacent distinct pair, above the greatest. Values within a part in a
/// million are one value: equal in exact arithmetic, they differ only by the
/// order of a floating-point sum, and a limit between them would sit on both.
pub fn between(arena: Allocator, values: []const f64) ![]const f64 {
    const v = try arena.dupe(f64, values);
    std.mem.sortUnstable(f64, v, {}, std.sort.asc(f64));
    var kept: usize = 1;
    for (v[1..]) |x| if (@abs(x - v[kept - 1]) > 1e-6 * @abs(v[kept - 1])) {
        v[kept] = x;
        kept += 1;
    };
    var out: std.ArrayList(f64) = .empty;
    try out.append(arena, v[0] * 0.5);
    for (v[0 .. kept - 1], v[1..kept]) |a, b| try out.append(arena, (a + b) / 2.0);
    try out.append(arena, v[kept - 1] * 1.5 + 1.0);
    return out.items;
}

/// A design-intent file at the 85 °C sign-off: `supplies` as `(net, role)`
/// in one 1.8 V domain `core`, `limits` the JSON inside the limits array.
pub fn intent(arena: Allocator, supplies: []const [2][]const u8, limits: []const u8) ![]const u8 {
    return intentAt(arena, 1800.0, supplies, limits);
}

/// One VDD power rail in a 1.8 V domain carrying `budget` µA.
pub fn vddIntent(arena: Allocator, budget: f64) ![]const u8 {
    return intent(arena, &.{.{ "VDD", "power" }}, try std.fmt.allocPrint(arena, "{{\"net\":\"VDD\",\"budget_current_ua\":{d}}}", .{budget}));
}

/// `intent` in a domain of `mv`.
pub fn intentAt(arena: Allocator, mv: f64, supplies: []const [2][]const u8, limits: []const u8) ![]const u8 {
    const text = try cf.intentOf(arena, mv, supplies, limits);
    return std.mem.concat(arena, u8, &.{ "{\"temperature_c\":85,", text[1..] });
}

/// Inline, so a literal argument makes `&.{...}` of findings static, not a dead stack temporary.
pub inline fn microamps(x: f64) Finding {
    return .{ .measured = .current(.{ .raw = x }) };
}

/// Inline, so a literal argument makes `&.{...}` of findings static, not a dead stack temporary.
pub inline fn ohms(x: f64) Finding {
    return .{ .measured = .resistance(.{ .raw = x }) };
}

/// `f` pinned at `(x, y)`.
pub inline fn at(f: Finding, x: i64, y: i64) Finding {
    var out = f;
    out.at = .{ x, y };
    return out;
}

/// One claim, `id` reports exactly `findings`, copied into the arena.
pub fn claim(arena: Allocator, id: []const u8, findings: []const Finding) ![]const Expect {
    return arena.dupe(Expect, &.{.{ .id = id, .findings = try arena.dupe(Finding, findings) }});
}

/// Runs `group`'s fixtures through `fixture.checkAll` in a fresh arena.
pub fn checkGroup(comptime group: fn (Allocator, *std.ArrayList(Fixture)) anyerror!void) !void {
    var arena_state: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var all: std.ArrayList(Fixture) = .empty;
    try group(arena, &all);
    try fixture.checkAll(all.items);
}
