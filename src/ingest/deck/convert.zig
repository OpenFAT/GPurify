//! Values → engine units: a number and its unit → an exact decimal in its
//! dimension's engine unit, a length on the deck grid → `Dbu` on the layout
//! grid, an area → square grid units, a bare whole number → a count. A
//! length off either grid is refused, never rounded (docs/deck.md, Basics).
//! Ported from crates/ingest/src/deck/parse.rs (`physical`, `quantity`,
//! `length`, `area`, `count`).
//!
//! Contents:
//! - `pub fn physical(p: *Parser, v: Val, dim: Dim, label: []const u8) PErr!f64`
//! - `pub fn quantity(p: *Parser, v: Val, dim: Dim, label: []const u8) PErr!Dec`
//! - `pub fn length(p: *Parser, v: Val, label: []const u8) PErr!Dbu`
//! - `pub fn area(p: *Parser, v: Val, label: []const u8) PErr!DbuArea`
//! - `pub fn count(p: *Parser, v: Val, label: []const u8) PErr!u32`

const std = @import("std");
const geom = @import("geom");
const Dbu = geom.Dbu;
const DbuArea = geom.DbuArea;
const parser = @import("parser.zig");
const Parser = parser.Parser;
const PErr = parser.PErr;
const Val = parser.Val;
const Dec = @import("units.zig").Dec;
const kinds = @import("kinds.zig");
const Dim = kinds.Dim;

/// A physical quantity in its engine unit; a temperature also takes `C`.
pub fn physical(p: *Parser, v: Val, dim: Dim, label: []const u8) PErr!f64 {
    if (dim == .temperature and v == .num and std.mem.eql(u8, v.num.unit, "C")) {
        const d = Dec.parse(v.num.text, v.num.neg) orelse return p.fail(v.num.span, "number too long", .{});
        return d.toF64() + 273.15;
    }
    return (try quantity(p, v, dim, label)).toF64();
}

/// A value's number converted to `dim`'s engine unit, exactly.
pub fn quantity(p: *Parser, v: Val, dim: Dim, label: []const u8) PErr!Dec {
    if (v != .num) return p.wrong(v, kinds.dimName(dim), label);
    const n = v.num;
    const shift: i32 = if (n.unit.len == 0) blk: {
        if (dim != .scalar and dim != .fraction and dim != .count) return p.wrong(v, kinds.dimName(dim), label);
        break :blk 0;
    } else blk: {
        for (kinds.units) |u| {
            if (!std.mem.eql(u8, u.name, n.unit)) continue;
            if (std.meta.activeTag(u.dim) == std.meta.activeTag(dim)) break :blk u.shift;
            return p.fail(n.span, "{s} needs {s}, got {s}{s} ({s})", .{ label, kinds.dimName(dim), n.text, n.unit, kinds.dimName(u.dim) });
        }
        if (std.mem.eql(u8, n.unit, "C")) return p.wrong(v, kinds.dimName(dim), label);
        return p.fail(n.span, "unknown unit `{s}`", .{n.unit});
    };
    const d = Dec.parse(n.text, n.neg) orelse return p.fail(n.span, "number too long", .{});
    return d.shifted(shift);
}

/// A rule length: on the deck grid, then converted to the layout grid.
pub fn length(p: *Parser, v: Val, label: []const u8) PErr!Dbu {
    const nm = try quantity(p, v, .length, label);
    const grid = p.deck_grid orelse return p.fail(v.span(), "no `grid` is stated before this length", .{});
    if (nm.isMultipleOf(grid) != true) return p.fail(v.span(), "{s} is not a multiple of the grid", .{try v.shown(p.scratch)});
    return p.layout.toDbu(geom.Qty(.length, .nano){ .raw = nm.toF64() }) catch
        p.fail(v.span(), "{s} is not on the layout's grid", .{try v.shown(p.scratch)});
}

/// An area: a multiple of the grid squared, in square layout units.
pub fn area(p: *Parser, v: Val, label: []const u8) PErr!DbuArea {
    const nm2 = try quantity(p, v, .area, label);
    const grid = p.deck_grid orelse return p.fail(v.span(), "no `grid` is stated before this area", .{});
    const gm = @mulWithOverflow(grid.m, grid.m);
    const ge = @mulWithOverflow(grid.e, 2);
    if (gm[1] != 0 or ge[1] != 0) return p.fail(v.span(), "the grid squared is too long a number", .{});
    if (nm2.isMultipleOf(.{ .m = gm[0], .e = ge[0] }) != true) return p.fail(v.span(), "{s} is not a multiple of the grid squared", .{try v.shown(p.scratch)});
    // nm2 * (dbu/um)^2 / 10^6 = square layout units.
    const per_um: i128 = p.layout.dbu_per_um;
    const scaled = @mulWithOverflow(nm2.m, per_um * per_um);
    if (scaled[1] == 0) {
        if ((Dec{ .m = scaled[0], .e = nm2.e - 6 }).integer()) |raw| return raw;
    }
    return p.fail(v.span(), "{s} is not on the layout's grid", .{try v.shown(p.scratch)});
}

/// A bare unsigned whole number.
pub fn count(p: *Parser, v: Val, label: []const u8) PErr!u32 {
    if (v == .num and !v.num.neg and v.num.unit.len == 0) {
        if (std.fmt.parseInt(u32, v.num.text, 10)) |n| return n else |_| {}
    }
    return p.wrong(v, "a count (a whole number, no unit)", label);
}
