//! `width(L; allowed: [...])` (`allowed_width`, DRC-015, DRC-090) from deck
//! text, with and without `open_last`; each finding also states its limit,
//! the listed width nearest the measured one. Ported from
//! crates/check/tests/drc/allowed_width_rules.rs.

const std = @import("std");
const check = @import("check");
const common = @import("common.zig");
const gpa = common.gpa;
const Finding = common.Finding;
const Measurement = check.report.Measurement;

// ---- private ----

fn nearest(w: i64) Measurement {
    return .length(if (w < 150) 100 else 200);
}

fn bar(name: []const u8, text: []const u8, w: i64, legal: bool) !void {
    var label: [32]u8 = undefined;
    const want = common.opt(!legal, Finding.length(w).atHalf(w, 1000).limitOf(nearest(w)));
    try common.everywhere(try std.fmt.bufPrint(&label, "{s}/{d}", .{ name, w }), text, try common.met1(&.{.{ 0, 0, w, 1000 }}), "aw", want);
}

test "only the listed widths are legal" {
    // Oracle: widths fixed by construction (sky130 rpm.1b-1f's shape: a list
    // of legal widths): bars at 100 and 200 and one step either side, each
    // off width one finding at the bar's centre measuring its width against
    // the nearest listed width; a 150 square, between the two (its limit a
    // tie, left unstated); a 100 bar drawn as two abutting 50 halves (legal
    // once merged); an L of a 100 and a 200 arm, judged by its narrower; two
    // plates overlapping 100 x 100 at a corner, a neck of sqrt(20000) (141
    // floored).
    var arena: std.heap.ArenaAllocator = .init(gpa);
    defer arena.deinit();
    const text = try common.deck(arena.allocator(), "rule aw width(met1; allowed: [100nm, 200nm])");
    for ([_]i64{ 100, 200 }) |listed| for (common.steps(listed)) |w| try bar("bar", text, w, w == listed);
    try common.everywhere("between", text, try common.met1(&.{.{ 0, 0, 150, 150 }}), "aw", &[_]Finding{Finding.length(150).atPoint(75, 75)});
    try common.everywhere("halves", text, try common.met1(&.{ .{ 0, 0, 50, 1000 }, .{ 50, 0, 100, 1000 } }), "aw", &[_]Finding{});
    try common.everywhere("l_of_two_widths", text, try common.met1(&.{ .{ 0, 0, 1000, 100 }, .{ 0, 100, 200, 1000 } }), "aw", &[_]Finding{});
    try common.everywhere("corner_neck", text, try common.met1(&.{ .{ 0, 0, 1000, 1000 }, .{ 900, 900, 1900, 1900 } }), "aw", &[_]Finding{Finding.length(141).limitOf(nearest(141))});
}

test "an open last width admits everything wider" {
    // Oracle: LEF58 `WIDTHTABLE 0.10 0.20` with its last width open: "all the
    // given widths are exact width values, except for the last one, which is
    // equal to or greater than the value". Bars swept one step around 100
    // (exact: 99 and 101 fail) and 200 (open: 199 fails, 200 and 201 pass); a
    // 1000 square passes, as LEF's 0.42 under a last 0.40 does (Figure 1-32
    // b); a 150 square fails; an L of a 100 and a 1000 arm is judged by its
    // narrower, and passes.
    var arena: std.heap.ArenaAllocator = .init(gpa);
    defer arena.deinit();
    const text = try common.deck(arena.allocator(), "rule aw width(met1; allowed: [100nm, 200nm], open_last: true)");
    for ([_]i64{ 100, 200 }) |listed| for (common.steps(listed)) |w| try bar("open", text, w, w == 100 or w >= 200);
    try common.everywhere("wide", text, try common.met1(&.{.{ 0, 0, 1000, 1000 }}), "aw", &[_]Finding{});
    try common.everywhere("between", text, try common.met1(&.{.{ 0, 0, 150, 150 }}), "aw", &[_]Finding{Finding.length(150).atPoint(75, 75)});
    try common.everywhere("l_of_exact_and_wide", text, try common.met1(&.{ .{ 0, 0, 3000, 100 }, .{ 0, 100, 1000, 1100 } }), "aw", &[_]Finding{});
}
