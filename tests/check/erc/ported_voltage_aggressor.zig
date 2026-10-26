//! `latchup_victim`'s voltage aggressor: a diffusion in a well whose net
//! can be forward-biased against the well's bias. Ported from
//! crates/check/tests/erc/ported.rs (`voltage_aggressor`). Unwired until
//! the latch-up family's `latchup_victim` lands (its rows refuse today);
//! add it to tests/check.zig then.

const std = @import("std");
const Allocator = std.mem.Allocator;
const testing = std.testing;
const fixture = @import("fixture.zig");
const Fixture = fixture.Fixture;
const Finding = fixture.Finding;
const Layout = fixture.Layout;
const board = @import("board.zig");
const rect = board.rect;
const length = @import("board_expect.zig").length;
const common = @import("ported_common.zig");
const gpa = testing.allocator;

// ---- private ----

fn deck(arena: Allocator, forward: []const u8) ![]const u8 {
    return std.fmt.allocPrint(arena,
        \\grid 1nm
        \\layer pdiff = gds(1, 0)
        \\layer nw = gds(2, 0)
        \\layer victim = gds(3, 0)
        \\layer tap = gds(4, 0)
        \\layer pdtxt = gds(1, 1)
        \\layer nwtxt = gds(2, 1)
        \\connect conductors [pdiff, nw]
        \\connect label pdtxt names pdiff
        \\connect label nwtxt names nw
        \\rule lv latchup_victim(pdiff, victim, tap; within: 2um, max_distance: 500nm, pad: none, bias: nw, forward: {s})
        \\
    , .{forward});
}

/// An n-well on VDD (round the diffusion, or drawn away from it), a p+
/// diffusion on `net` inside it, a victim 200 nm off the well and its tap
/// 1 µm beyond.
fn layout(arena: Allocator, net: []const u8, well_round: bool) !Layout {
    var l: Layout = .{};
    const well: board.Rect = if (well_round) .{ 0, 0, 2000, 2000 } else .{ -5000, 0, -3000, 2000 };
    try rect(&l, arena, "nw", well);
    try l.label(arena, "nwtxt", well[0] + 100, 100, "VDD");
    try rect(&l, arena, "pdiff", .{ 500, 500, 1000, 1000 });
    try l.label(arena, "pdtxt", 600, 600, net);
    try rect(&l, arena, "victim", .{ 2200, 0, 3200, 1000 });
    try rect(&l, arena, "tap", .{ 3200, 0, 3300, 1000 });
    return l;
}

/// `latchup_victim`'s `forward` (ERC-D5): a diffusion in an n-well biased
/// at VDD (1.8 V) is an aggressor when its net can sit above the bias
/// (`above`) or below it (`below`); the victim 1 µm from its tap is
/// flagged whenever the diffusion is an aggressor.
///
/// - `forward: above`, the diffusion on VDDH (3.3 V): 3300 > 1800, flagged;
/// - the diffusion on VDD itself: 1800 is not above 1800, clean;
/// - the diffusion on VDDH with the well drawn away from it: no well holds
///   it, clean;
/// - `forward: below`, the diffusion on VSS: 0 < 1800, flagged;
/// - without intent the row is skipped.
fn voltageAggressorInto(arena: Allocator, out: *std.ArrayList(Fixture)) !void {
    const intent = try board.intentText(arena, &.{ .{ .name = "a", .mv = 1800.0 }, .{ .name = "b", .mv = 3300.0 } }, &.{ .{ "VDD", "a", "power" }, .{ "VSS", "a", "ground" }, .{ "VDDH", "b", "power" } }, &.{});
    const Case = struct { []const u8, []const u8, []const u8, bool, bool };
    for ([_]Case{
        .{ "above", "above", "VDDH", true, true },
        .{ "same", "above", "VDD", true, false },
        .{ "no_well", "above", "VDDH", false, false },
        .{ "below", "below", "VSS", true, true },
    }) |case| {
        const name, const forward, const net, const round, const flagged = case;
        const findings: []const Finding = if (flagged) &.{length(1000)} else &.{};
        const f: Fixture = .{
            .name = try std.fmt.allocPrint(arena, "erc/latchup_victim/voltage/{s}", .{name}),
            .deck = try deck(arena, forward),
            .layout = try layout(arena, net, round),
            .intent = intent,
            .expect = try common.expects(arena, &.{try common.rule(arena, "lv", findings)}),
        };
        try common.everyPlacementInto(arena, &.{f}, out);
    }
    try out.append(arena, .{
        .name = "erc/latchup_victim/voltage/no_intent",
        .deck = try deck(arena, "above"),
        .layout = try layout(arena, "VDDH", true),
        .expect = try common.expects(arena, &.{.{ .id = "lv", .outcome = .skipped }}),
    });
}

test "a forward-biasable diffusion makes its well's victims aggressed" {
    // Oracle: the construction in `voltageAggressorInto`'s doc comment: the
    // diffusion's reachable voltage against the well's bias, by hand.
    var arena_state: std.heap.ArenaAllocator = .init(gpa);
    defer arena_state.deinit();
    var all: std.ArrayList(Fixture) = .empty;
    try voltageAggressorInto(arena_state.allocator(), &all);
    try fixture.checkAll(all.items);
}
