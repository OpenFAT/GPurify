//! LVS-033 black boxes, LVS-067's fixed cells and its marker route, as
//! exhaustive fixtures. Ported from tests/exhaustive/lvs.rs
//! (`boxed_layout`, `boxed_spice`, `black_boxes`, `subcircuit_devices`;
//! `BoxCase`'s Netgen-only fields, the drawn netlist and the controls, stay
//! with the skipped Netgen differential).
//!
//! Contents:
//! - `pub fn fixturesInto(arena: Allocator, depth: Depth, out: *std.ArrayList(Fixture)) !void`

const std = @import("std");
const Allocator = std.mem.Allocator;
const harness = @import("harness.zig");
const Depth = harness.Depth;
const Fixture = harness.Fixture;
const Layout = harness.Layout;
const Symmetry = harness.Symmetry;
const circuit = @import("lvs_circuit.zig");
const Dev = circuit.Dev;
const Circuit = circuit.Circuit;
const Controls = @import("lvs_controls.zig").Controls;
const oracle = @import("lvs_oracle.zig");
const lf = @import("lvs_fixture.zig");

pub fn fixturesInto(arena: Allocator, depth: Depth, out: *std.ArrayList(Fixture)) !void {
    _ = depth;
    try blackBoxesInto(arena, out);
    try subcircuitDevicesInto(arena, out);
}

// ---- private ----

/// A cell's circuit: `devs` on three pins named `names`, every one a port.
fn pins(arena: Allocator, names: [3][]const u8, devs: []const Dev) !Circuit {
    const ports = try arena.alloc(bool, 3);
    @memset(ports, true);
    return .{ .devs = try arena.dupe(Dev, devs), .names = try arena.dupe([]const u8, &names), .ports = ports };
}

/// `inner` drawn as the cell `name`, placed `count` times beside `top`'s
/// drawing at `(dx + k * 6000, 0)` under `orientation`, with `top`'s nets
/// `0..` extended under the cell's pin tracks, so the cell's pin `k` (its
/// net `k`, labelled with its name, `draw`) lands on `top`'s net `k`.
fn boxedLayout(arena: Allocator, top: *const Circuit, name: []const u8, inner: *const Circuit, count: usize, mirror: bool) !Layout {
    var layout = try circuit.draw(arena, top);
    // An unplaced cell would be a second root, flattened as drawn.
    if (count > 0) try layout.cell(arena, name, try circuit.draw(arena, inner));
    const first = column(top.devs.len) + 2000;
    // The cell's tracks run over x in -1000..column(devices) of its frame; a
    // mirror in y maps them to -column(devices)..1000, so it moves right.
    const width = column(inner.devs.len) + 1000;
    var reach = first;
    for (0..count) |k| {
        const at = first + 6000 * @as(i64, @intCast(k));
        if (mirror) try layout.place(arena, name, Symmetry.all[4], at + width - 1000, 0) else try layout.place(arena, name, .identity, at, 0);
        // Overlapping the cell's tracks, past its edge either way round.
        reach = at + 500;
    }
    for (0..inner.nets()) |k| {
        const t = circuit.track(k);
        try layout.rect(arena, "met2", -1000, t, reach, t + 200);
    }
    return layout;
}

fn column(i: usize) i64 {
    return 3000 * @as(i64, @intCast(i));
}

/// `TOP` placing `cell` once per row of `on` (each row the `TOP` nets of
/// the cell's ports, in order), with `cell` defined as `body`.
fn boxedSpice(arena: Allocator, top: *const Circuit, name: []const u8, body: *const Circuit, on: []const []const usize) ![]const u8 {
    var text = try circuit.spiceHier(arena, top, body, on[0]);
    for (on[1..], 1..) |nets, k| {
        var line: std.ArrayList(u8) = .empty;
        try line.print(arena, " BLK\nX{d}", .{k});
        for (nets) |n| try line.print(arena, " {s}", .{top.names[n]});
        try line.appendSlice(arena, " BLK\n.ends");
        text = try circuit.edited(arena, text, " BLK\n.ends", line.items);
    }
    return std.mem.replaceOwned(u8, arena, text, "BLK", name);
}

/// LVS-033 black boxes and LVS-067's fixed cells, each verdict derived by
/// hand from the definition (deck.md, `lvs blackbox`; Netgen's "will only
/// recognize the pin names and pin order but will otherwise ignore the
/// subcell contents"): a placement matches an instance of the same cell
/// whose pins land on the same nets by name, whatever either holds.
///
/// `TOP` is an `nmos` and a `pmos` on n0..n3; `BLK`, drawn, holds an
/// `nmos` on its pins `P`, `Q`, `R`, placed so they land on n0, n1, n2.
fn blackBoxesInto(arena: Allocator, out: *std.ArrayList(Fixture)) !void {
    const top = try Circuit.init(arena, 4, &.{ Dev.mos(.n, 3, 0, 1), Dev.mos(.p, 3, 1, 2) });
    const drawn = try pins(arena, .{ "P", "Q", "R" }, &.{Dev.mos(.n, 0, 1, 2)});
    const renamed = try pins(arena, .{ "P", "Z", "R" }, &.{Dev.mos(.n, 0, 1, 2)});
    const written = try pins(arena, .{ "P", "Q", "R" }, &.{Dev.mos(.p, 1, 0, 1)});
    const empty = try pins(arena, .{ "P", "Q", "R" }, &.{});
    const boxed: Controls = .{ .boxed = &.{"BLK"} };
    const none: Controls = .{};
    const one: []const []const usize = &.{&.{ 0, 1, 2 }};
    const cases = [_]struct { []const u8, Layout, []const u8, *const Controls, bool }{
        .{ "match", try boxedLayout(arena, &top, "BLK", &drawn, 1, false), try boxedSpice(arena, &top, "BLK", &written, one), &boxed, true },
        .{ "no_control", try boxedLayout(arena, &top, "BLK", &drawn, 1, false), try boxedSpice(arena, &top, "BLK", &written, one), &none, false },
        .{ "empty_body", try boxedLayout(arena, &top, "BLK", &drawn, 1, false), try boxedSpice(arena, &top, "BLK", &empty, one), &boxed, true },
        .{ "pins_swapped", try boxedLayout(arena, &top, "BLK", &drawn, 1, false), try boxedSpice(arena, &top, "BLK", &written, &.{&.{ 1, 0, 2 }}), &boxed, false },
        .{ "pin_renamed", try boxedLayout(arena, &top, "BLK", &renamed, 1, false), try boxedSpice(arena, &top, "BLK", &written, one), &boxed, false },
        .{ "not_drawn", try boxedLayout(arena, &top, "BLK", &drawn, 0, false), try boxedSpice(arena, &top, "BLK", &written, one), &boxed, false },
        .{ "mirrored", try boxedLayout(arena, &top, "BLK", &drawn, 1, true), try boxedSpice(arena, &top, "BLK", &written, one), &boxed, true },
        .{ "two", try boxedLayout(arena, &top, "BLK", &drawn, 2, false), try boxedSpice(arena, &top, "BLK", &written, &.{ &.{ 0, 1, 2 }, &.{ 0, 1, 2 } }), &boxed, true },
        .{ "two_drawn_one_written", try boxedLayout(arena, &top, "BLK", &drawn, 2, false), try boxedSpice(arena, &top, "BLK", &written, one), &boxed, false },
    };
    for (cases) |case| {
        var f: Fixture = .init(try std.fmt.allocPrint(arena, "lvs/blackbox/{s}", .{case[0]}), &.{"LVS-033"}, try std.mem.concat(arena, u8, &.{ circuit.full_deck, try case[3].deck(arena) }), lf.lvs);
        f.layout = case[1];
        try f.claim(arena, .{ .lvs = case[4] });
        f.reference = case[2];
        try out.append(arena, f);
    }

    // LVS-067: a foundry's fixed cell, a VPP capacitor drawn as plates and
    // no device (Magic's sky130 `cap_vpp_*` cells, recognised by name), is
    // one device by its pins `C0` and `C1`; written as a call to an empty
    // subcircuit of its name, it matches on n0, n1 and not reversed.
    const polar_top = try Circuit.init(arena, 3, &.{Dev.mos(.n, 0, 1, 2)});
    const plate_ports = try arena.alloc(bool, 2);
    @memset(plate_ports, true);
    const plates: Circuit = .{ .devs = try arena.alloc(Dev, 0), .names = try arena.dupe([]const u8, &.{ "C0", "C1" }), .ports = plate_ports };
    const vpp: Controls = .{ .boxed = &.{"cap_vpp_*"} };
    const vpp_cases = [_]struct { []const u8, [2]usize, bool }{ .{ "vpp/match", .{ 0, 1 }, true }, .{ "vpp/reversed", .{ 1, 0 }, false } };
    for (vpp_cases) |case| {
        var f: Fixture = .init(try std.fmt.allocPrint(arena, "lvs/{s}", .{case[0]}), &.{ "LVS-067", "LVS-033" }, try std.mem.concat(arena, u8, &.{ circuit.full_deck, try vpp.deck(arena) }), lf.lvs);
        f.layout = try boxedLayout(arena, &polar_top, "cap_vpp_4x4", &plates, 1, false);
        try f.claim(arena, .{ .lvs = case[2] });
        f.reference = try boxedSpice(arena, &polar_top, "cap_vpp_4x4", &plates, &.{&case[1]});
        try out.append(arena, f);
    }
}

/// LVS-067's marker route: a resistor the deck recognises by its marker
/// (`rpoly`) written as a call to a subcircuit of the model's name that the
/// netlist also defines, with a body of another model: it is that device,
/// the body unread, so it matches on its nets and not elsewhere.
/// Construct-from-answer: the card form, `R1 n0 n1 rpoly`, is the same
/// circuit, and the oracle's verdict for it is the expectation.
fn subcircuitDevicesInto(arena: Allocator, out: *std.ArrayList(Fixture)) !void {
    const drawn = try lf.polar(arena, Dev.onPins(.r, &.{ 0, 1 }));
    const defined = ".subckt rpoly a b\nR0 a b rinner\n.ends\n";
    const cases = [_]struct { []const u8, [2]usize }{ .{ "rsubckt/match", .{ 0, 1 } }, .{ "rsubckt/miswired", .{ 0, 2 } } };
    for (cases) |case| {
        const written = try lf.polar(arena, Dev.onPins(.r, &case[1]));
        const card = try std.fmt.allocPrint(arena, "R1 n{d} n{d} rpoly", .{ case[1][0], case[1][1] });
        const text = try std.mem.concat(arena, u8, &.{ defined, try circuit.edited(arena, try circuit.spice(arena, &written), card, try std.fmt.allocPrint(arena, "X{s}", .{card})) });
        var f = try lf.withText(arena, case[0], &.{"LVS-067"}, try circuit.draw(arena, &drawn), text);
        try f.claim(arena, .{ .lvs = try oracle.equivalent(arena, &drawn, &written) });
        try out.append(arena, f);
    }
}

test "every black box and fixed-cell fixture holds" {
    // Oracle: hand-derived from deck.md's `lvs blackbox` and Netgen's
    // stated black-box semantics (pins by name and order, contents
    // ignored), and the oracle's verdict on the marker route's card form.
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    var fixtures: std.ArrayList(Fixture) = .empty;
    try fixturesInto(arena.allocator(), .merge, &fixtures);
    try harness.checkAll(fixtures.items);
}
