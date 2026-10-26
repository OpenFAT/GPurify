//! The scored and matched kinds through deck text: `dfm_score` (the
//! design's score over a check's findings) and `pattern` (a window of
//! shapes matched in any orientation). Each case is the root
//! `tests/exhaustive/drc_overlay.rs` fixture of the same name, its oracle
//! restated on the test. Ported from crates/check/tests/drc/dfm_deck.rs.

const std = @import("std");
const testing = std.testing;
const check = @import("check");
const common = @import("common.zig");
const Measurement = check.report.Measurement;
const F = common.Finding;
const Layout = common.Layout;
const gpa = common.gpa;
const Arena = std.heap.ArenaAllocator;

const dfm_rules = "rule ds dfm_score(m; check: space, required: 100nm, recommended: 200nm, rate: 0.5) >= 0.9\n" ++
    "rule dw dfm_score(m; check: width, required: 100nm, recommended: 200nm, rate: 0.5) >= 0.9\n" ++
    "rule de dfm_score(v, m; check: enclosure, required: 100nm, recommended: 200nm, rate: 0.5) >= 0.9\n";

const ell_shapes = "shapes: [0nm x 0nm, 300nm x 100nm, 0nm x 100nm, 100nm x 300nm]";

const pattern_rules = "rule p pattern(m; window: 300nm x 300nm, " ++ ell_shapes ++ ", ignore: none)\n" ++
    "rule pd pattern(m; window: 300nm x 300nm, " ++ ell_shapes ++ ", ignore: [150nm x 150nm, 300nm x 300nm])\n";

/// No finding.
const none = common.opt(false, F.any());

// ---- private ----

/// The design score over findings at `gaps`; none when it passes.
fn score(gaps: []const i64) common.Opt {
    var design: f64 = 1;
    for (gaps) |g| design *= 1.0 - 0.5 * (1.0 - std.math.clamp(@as(f64, @floatFromInt(g - 100)) / 100.0, 0.0, 1.0));
    return common.opt(gaps.len > 0 and design < 0.9, F.ratio(design));
}

/// Runs the three DFM rules over `layout` plus a far plate holding a via
/// 300 inside it.
fn dfmCase(name: []const u8, layout: *Layout, ds: common.Opt, dw: common.Opt, de: common.Opt) !void {
    try layout.rect("m", 9000, 0, 10_000, 1000);
    try layout.rect("v", 9300, 300, 9400, 400);
    var arena: Arena = .init(gpa);
    defer arena.deinit();
    const d = try common.newDeck(arena.allocator(), &.{ "m", "v" }, dfm_rules);
    try common.checkEverywhere(name, d, layout, &.{
        .{ .id = "ds", .findings = common.slice(&ds) },
        .{ .id = "dw", .findings = common.slice(&dw) },
        .{ .id = "de", .findings = common.slice(&de) },
    });
}

fn bars(gaps: []const i64) !Layout {
    var l = try common.layoutOf("m", &.{.{ 0, 0, 1000, 1000 }});
    errdefer l.deinit();
    var x: i64 = 0;
    for (gaps) |g| {
        x += 1000 + g;
        try l.rect("m", x, 0, x + 1000, 1000);
    }
    return l;
}

/// An L at `x`: a bar `run` long and `arm` tall, and a 100 wide arm up to
/// `run`.
fn ell(l: *Layout, x: i64, arm: i64, run: i64) !void {
    try l.rect("m", x, 0, x + run, arm);
    try l.rect("m", x, arm, x + 100, run);
}

/// `p` and `pd` each find `n` windows measuring the L's 50000 nm².
fn patternCase(name: []const u8, layout: *Layout, p: usize, pd: usize) !void {
    var arena: Arena = .init(gpa);
    defer arena.deinit();
    const al = arena.allocator();
    const d = try common.newDeck(al, &.{"m"}, pattern_rules);
    const found = try al.alloc(F, 2);
    @memset(found, F.area(50_000));
    try common.checkEverywhere(name, d, layout, &.{ .{ .id = "p", .findings = found[0..p] }, .{ .id = "pd", .findings = found[0..pd] } });
}

test "dfm score multiplies each findings survival" {
    // Oracle: the score by hand: a finding at `g` scores `(g - 100) / 100`
    // clamped to `[0, 1]`, the design `Π 1 - 0.5 (1 - score)`: gaps of 179,
    // 180, 181 (0.895 found; 0.9 and 0.905 pass), 200 (no finding of the
    // check), two gaps of 150 (0.75², 0.5625, though each alone passes 0.75),
    // a gap of 50 (below the required value: 0.5); a bar 150 wide (0.75); a via
    // enclosed by 150 (0.75). Every layout also holds a plate with a via 300
    // inside it far off, which each check reads and finds clean.
    const gap_sets = [_][]const i64{ &.{179}, &.{180}, &.{181}, &.{200}, &.{ 150, 150 }, &.{50} };
    for (gap_sets) |gaps| {
        var l = try bars(gaps);
        defer l.deinit();
        try dfmCase("space", &l, score(gaps), none, none);
    }
    var bar = try common.layoutOf("m", &.{.{ 0, 0, 150, 1000 }});
    defer bar.deinit();
    try dfmCase("width", &bar, none, score(&.{150}), none);
    var enc = try common.layoutOf("m", &.{.{ 0, 0, 400, 400 }});
    defer enc.deinit();
    try enc.rect("v", 150, 150, 250, 250);
    try dfmCase("enclosure", &enc, none, none, score(&.{150}));
}

test "dfm score reports at the worst finding" {
    // Oracle: `Rule::DfmScore`'s rustdoc: one finding at the lowest-scoring
    // finding's marker, measuring the design's score against the sign-off.
    // Bars 150 apart then 120 apart: scores 0.5 and 0.2, survivals 0.75 and
    // 0.6, design 0.45, at the 120 gap's middle, (2180, 500), held to 0.9.
    var arena: Arena = .init(gpa);
    defer arena.deinit();
    const d = try common.newDeck(arena.allocator(), &.{"m"}, "rule ds dfm_score(m; check: space, required: 100nm, recommended: 200nm, rate: 0.5) >= 0.9\n");
    var l = try common.layoutOf("m", &.{ .{ 0, 0, 1000, 1000 }, .{ 1150, 0, 2120, 1000 }, .{ 2240, 0, 3240, 1000 } });
    defer l.deinit();
    var r = try common.run(d, &l);
    defer r.deinit();
    const found = r.row("ds").findings;
    try testing.expectEqual(@as(usize, 1), found.len);
    try testing.expectEqual(Measurement.ratio(0).kind, found[0].measured.kind);
    try testing.expectApproxEqAbs(0.75 * 0.6, found[0].measured.float(), 1e-12);
    try testing.expect(found[0].limit.eql(.ratio(0.9)));
    try testing.expectEqual([2]i64{ 2180, 500 }, found[0].at);
}

test "pattern matches the window in every orientation" {
    // Oracle: matches by construction from the definition (the layout inside
    // the window equals the pattern in any of the eight orientations,
    // don't-care regions matching anything): the L drawn exactly (both), with
    // arms running past the window (both), its arm 99, 100, 101 wide (only
    // 100), a square in the don't-care (only `pd`), one by the inner corner
    // (neither), two Ls apart (two each), a solid square (neither).
    for ([_]i64{ 99, 100, 101 }) |arm| {
        var l: Layout = .{};
        defer l.deinit();
        try ell(&l, 0, arm, 300);
        const n: usize = @intFromBool(arm == 100);
        try patternCase("arm", &l, n, n);
    }
    const Extra = struct { []const u8, ?[4]i64, usize, usize };
    for ([_]Extra{ .{ "square_in_the_dont_care", .{ 200, 200, 250, 250 }, 0, 1 }, .{ "square_by_the_corner", .{ 120, 120, 140, 140 }, 0, 0 } }) |cs| {
        var l: Layout = .{};
        defer l.deinit();
        try ell(&l, 0, 100, 300);
        const b = cs[1].?;
        try l.rect("m", b[0], b[1], b[2], b[3]);
        try patternCase(cs[0], &l, cs[2], cs[3]);
    }
    {
        var l: Layout = .{};
        defer l.deinit();
        try ell(&l, 0, 100, 600);
        try patternCase("long_arms", &l, 1, 1);
    }
    {
        var l: Layout = .{};
        defer l.deinit();
        try ell(&l, 0, 100, 300);
        try ell(&l, 2000, 100, 300);
        try patternCase("two", &l, 2, 2);
    }
    var solid = try common.layoutOf("m", &.{.{ 0, 0, 300, 300 }});
    defer solid.deinit();
    try patternCase("solid", &solid, 0, 0);
}
