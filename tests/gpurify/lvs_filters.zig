//! LVS-048: `lvs filter_unused`, as exhaustive fixtures. Ported from
//! tests/exhaustive/lvs.rs (`unused_filters`).
//!
//! Contents:
//! - `pub fn fixturesInto(arena: Allocator, depth: Depth, out: *std.ArrayList(Fixture)) !void`

const std = @import("std");
const Allocator = std.mem.Allocator;
const harness = @import("harness.zig");
const Depth = harness.Depth;
const Fixture = harness.Fixture;
const circuit = @import("lvs_circuit.zig");
const Dev = circuit.Dev;
const Circuit = circuit.Circuit;
const Controls = @import("lvs_controls.zig").Controls;
const lf = @import("lvs_fixture.zig");

/// LVS-048: layout transistors an `lvs filter_unused` option matches leave the
/// comparison, judged as drawn, on the layout only. Beside one `nmos` on n0..n2
/// (every net a port, n0 the deck's `lvs supply`), the drawing adds one
/// transistor wired as each option describes, or nearly; the reference has only
/// the first. Each extra against every option and none, and one written but not
/// drawn, the verdict the oracle's (`Controls.kept` follows
/// docs/src/reference/deck/lvs-controls.md). Option `c`'s three cases follow
/// docs/src/reference/lvs/reduction.md (LVS-048, option `c`), by hand: gate on
/// the supply and drain floating is filtered; with the source on the supply
/// too, neither end floats; a gate on a signal net is not on the supply.
pub fn fixturesInto(arena: Allocator, depth: Depth, out: *std.ArrayList(Fixture)) !void {
    _ = depth;
    const base = try Circuit.init(arena, 3, &.{Dev.mos(.n, 0, 1, 2)});
    var chain = try Circuit.init(arena, 6, &.{ Dev.mos(.n, 0, 1, 2), Dev.mos(.n, 0, 3, 4), Dev.mos(.n, 0, 4, 5) });
    for ([_]usize{ 3, 4, 5 }) |net| chain = try chain.internal(arena, net);
    const extras = [_]struct { []const u8, Circuit }{
        .{ "all_floating", try with(arena, Dev.mos(.n, 3, 4, 5), &.{ 3, 4, 5 }) },
        .{ "ends_floating", try with(arena, Dev.mos(.n, 0, 3, 4), &.{ 3, 4 }) },
        .{ "ends_tied", try with(arena, Dev.mos(.n, 0, 1, 1), &.{}) },
        .{ "all_tied", try with(arena, Dev.mos(.n, 1, 1, 1), &.{}) },
        .{ "gate_on_supply_drain_floating", try with(arena, Dev.mos(.n, 0, 1, 3), &.{3}) },
        .{ "gate_on_supply_ends_held", try with(arena, Dev.mos(.n, 0, 0, 1), &.{}) },
        .{ "gate_on_signal_drain_floating", try with(arena, Dev.mos(.n, 1, 2, 3), &.{3}) },
        .{ "chain", chain },
    };
    for (&extras) |*extra| for ([_][]const u8{ "ae", "af", "ag", "c", "u", "none" }) |option| {
        const controls: Controls = .{
            .unused = if (std.mem.eql(u8, option, "none")) &.{} else try arena.dupe([]const u8, &.{option}),
            .supply = &.{"n0"},
        };
        try out.append(arena, try lf.comparedUnder(arena, try std.fmt.allocPrint(arena, "filter_unused/{s}/{s}", .{ extra[0], option }), &.{"LVS-048"}, &extra[1], &base, &controls));
    };
    // The schematic's own unused transistor stays: the filter is the layout's.
    const controls: Controls = .{ .unused = &.{ "ae", "af", "ag", "c", "u" }, .supply = &.{"n0"} };
    try out.append(arena, try lf.comparedUnder(arena, "filter_unused/written_only", &.{"LVS-048"}, &base, &extras[0][1], &controls));
}

// ---- private ----

/// The base `nmos` and `dev`, on as many nets as `dev` reaches (at least
/// three), with `internal` nets no port.
fn with(arena: Allocator, dev: Dev, internal: []const usize) !Circuit {
    const nets = @max(std.mem.max(usize, dev.pinsOf()), 2) + 1;
    var c = try Circuit.init(arena, nets, &.{ Dev.mos(.n, 0, 1, 2), dev });
    for (internal) |net| c = try c.internal(arena, net);
    return c;
}

test "every filter_unused fixture holds" {
    // Oracle: the oracle's verdict under each option (`filter_unused` in
    // docs/src/reference/lvs/reduction.md, LVS-048, judged on the drawing
    // alone) and option `c`'s definition there, by hand (above).
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    var fixtures: std.ArrayList(Fixture) = .empty;
    try fixturesInto(arena.allocator(), .merge, &fixtures);
    try harness.checkAll(fixtures.items);
}
