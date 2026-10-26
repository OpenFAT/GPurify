//! The ERC rows the catalog marks expressible as DRC kinds, each a deck and
//! a layout run through the DRC deck harness (drc/common.zig) with DRC
//! alone. Ported from tests/exhaustive/erc.rs (`expressible`).

const std = @import("std");
const common = @import("../drc/common.zig");
const F = common.Finding;
const Layout = common.Layout;

const a10 = "grid 1nm\nlayer nwell = gds(1, 0)\nlayer dant = gds(2, 0)\nrule Ant.h forbidden(dant and nwell)\n";

const c11 = "grid 1nm\nlayer poly = gds(1, 0)\nlayer esd = gds(2, 0)\nlayer esd_poly = poly and esd\nrule LVESD.w width(esd_poly) >= 500nm\n";

const e12 = "grid 1nm\nlayer met1 = gds(1, 0)\nrule slot cheesing(met1) <= 10um2\n";

// Oracle: IHP Ant.h (no antenna diode in an n-well, `forbidden`, ERC-A10):
// a 1 x 1 µm diode half inside the well is 500 000 nm² of overlap; moved
// out of it, clean.
test "expressible ERC-A10 forbids an antenna diode in an n-well" {
    var in_well: Layout = .{};
    defer in_well.deinit();
    try in_well.rect("nwell", -500, -500, 500, 1500);
    try in_well.rect("dant", 0, 0, 1000, 1000);
    try common.checkCase("erc/expressible/ant_h/in_well", a10, &in_well, &.{.{ .id = "Ant.h", .findings = &.{F.area(500_000)} }});
    var outside: Layout = .{};
    defer outside.deinit();
    try outside.rect("nwell", -2000, -500, -1000, 1500);
    try outside.rect("dant", 0, 0, 1000, 1000);
    try common.checkCase("erc/expressible/ant_h/outside", a10, &outside, &.{.{ .id = "Ant.h", .findings = &.{} }});
}

// Oracle: an ESD device's poly width under its marker (`width` on a derived
// layer, ERC-C11): a poly line w nm wide inside the marker is flagged at w
// when w < 500 nm; the 400 nm line outside the marker is not ESD poly.
test "expressible ERC-C11 measures ESD poly width under its marker" {
    for ([_]i64{ 499, 500, 501 }) |w| {
        var l: Layout = .{};
        defer l.deinit();
        try l.rect("esd", -1000, -1000, 3000, 5000);
        try l.rect("poly", 0, 0, w, 4000);
        try l.rect("poly", 5000, 0, 5400, 4000);
        var name_buf: [64]u8 = undefined;
        const name = try std.fmt.bufPrint(&name_buf, "erc/expressible/esd_width/{d}", .{w});
        const want: []const F = if (w < 500) &.{F.length(w)} else &.{};
        try common.checkCase(name, c11, &l, &.{.{ .id = "LVESD.w", .findings = want }});
    }
}

// Oracle: slotting of a wide plate (`cheesing`, ERC-E12) at 10 µm²: a solid
// 4 x 4 µm plate is 16 µm², flagged at its area; the same plate with a
// 2 x 2 µm slot (a ring of four bars) and a 3 x 3 µm plate (9 µm²) are clean.
test "expressible ERC-E12 flags an unslotted wide plate" {
    var solid: Layout = .{};
    defer solid.deinit();
    try solid.rect("met1", 0, 0, 4000, 4000);
    try common.checkCase("erc/expressible/cheesing/solid", e12, &solid, &.{.{ .id = "slot", .findings = &.{F.area(16_000_000)} }});
    var slotted: Layout = .{};
    defer slotted.deinit();
    try slotted.rects("met1", &.{ .{ 0, 0, 4000, 1000 }, .{ 0, 3000, 4000, 4000 }, .{ 0, 1000, 1000, 3000 }, .{ 3000, 1000, 4000, 3000 } });
    try common.checkCase("erc/expressible/cheesing/slotted", e12, &slotted, &.{.{ .id = "slot", .findings = &.{} }});
    var small: Layout = .{};
    defer small.deinit();
    try small.rect("met1", 0, 0, 3000, 3000);
    try common.checkCase("erc/expressible/cheesing/small", e12, &small, &.{.{ .id = "slot", .findings = &.{} }});
}
