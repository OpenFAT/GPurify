//! What the DRC typer (`drc.compile.fromDeck`, through `deck.compile`)
//! refuses, at each boundary the rule kinds state: each case one value
//! either side of the line, the refusal named with the value it reports.
//! Ported from crates/check/tests/drc/ruleset_refusals.rs.

const std = @import("std");
const testing = std.testing;
const geom = @import("geom");
const check = @import("check");
const common = @import("common.zig");
const gpa = common.gpa;

/// What compiling a deck came to: nothing (it built), or the error and the
/// diagnostic's row, value, layer counts and parameter.
const Outcome = struct {
    err: ?anyerror = null,
    rule: []const u8 = "",
    limit: i64 = 0,
    expected: u32 = 0,
    found: u32 = 0,
    param: []const u8 = "",
};

// ---- private ----

/// Parses `text` on a 1 nm grid and types its rules; `arena` holds the
/// names an outcome reports.
fn compile(arena: std.mem.Allocator, text: []const u8) !Outcome {
    var strings: geom.StrTable = .empty;
    defer strings.deinit(gpa);
    var diag: check.deck.compile.Diag = .{};
    var cd = check.deck.compile.compile(gpa, arena, text, try geom.Grid.init(1000), &strings, &diag) catch |e| {
        const d = diag.rule;
        const name = if (@backingInt(d.rule) != std.math.maxInt(u32)) try arena.dupe(u8, strings.resolve(d.rule)) else "";
        return .{ .err = e, .rule = name, .limit = d.limit, .expected = d.expected, .found = d.found, .param = d.param };
    };
    cd.deinit(gpa);
    return .{};
}

fn expectOk(o: Outcome) !void {
    try testing.expectEqual(@as(?anyerror, null), o.err);
}

fn expectNonPositive(o: Outcome, rule: []const u8, limit: i64) !void {
    try testing.expectEqual(@as(?anyerror, error.NonPositiveLimit), o.err);
    try testing.expectEqualStrings(rule, o.rule);
    try testing.expectEqual(limit, o.limit);
}

fn expectBadTable(o: Outcome, rule: []const u8) !void {
    try testing.expectEqual(@as(?anyerror, error.BadTable), o.err);
    try testing.expectEqualStrings(rule, o.rule);
}

fn expectLayerCount(o: Outcome, rule: []const u8, expected: u32, found: u32) !void {
    try testing.expectEqual(@as(?anyerror, error.WrongLayerCount), o.err);
    try testing.expectEqualStrings(rule, o.rule);
    try testing.expectEqual(expected, o.expected);
    try testing.expectEqual(found, o.found);
}

fn expectParamType(o: Outcome, rule: []const u8, param: []const u8) !void {
    try testing.expectEqual(@as(?anyerror, error.WrongParamType), o.err);
    try testing.expectEqualStrings(rule, o.rule);
    try testing.expectEqualStrings(param, o.param);
}

test "an enclosure band must end above where it starts" {
    // Oracle: `WireBand`'s rustdoc: `below` is "above `from`". A band whose
    // `below` is at or under its `from` is refused with the band's width,
    // `below - from`: -1000 for 2000 over 1000, 0 for equal ends; one unit
    // above is a band.
    var arena: std.heap.ArenaAllocator = .init(gpa);
    defer arena.deinit();
    const a = arena.allocator();
    const band = struct {
        fn f(al: std.mem.Allocator, w: i64, below: i64) !Outcome {
            return compile(al, try common.newDeck(al, &.{ "via", "met2" }, try std.fmt.allocPrint(al, "rule e enclosure(via, met2; width: {d}nm, below: {d}nm) >= 50nm", .{ w, below })));
        }
    }.f;
    try expectNonPositive(try band(a, 2000, 1000), "e", -1000);
    try expectNonPositive(try band(a, 1000, 1000), "e", 0);
    try expectOk(try band(a, 1000, 1001));
}

test "a via map band must not run backwards" {
    // Oracle: `via_map`'s grammar (OpenROAD's `VIA cutLayer w1 w2`): each
    // width band's low end at most its high end. A low end past its high end
    // is refused with `high - low`; equal ends are an exact width.
    var arena: std.heap.ArenaAllocator = .init(gpa);
    defer arena.deinit();
    const a = arena.allocator();
    const map = struct {
        fn f(al: std.mem.Allocator, below: [2]i64, above: [2]i64) !Outcome {
            return compile(al, try common.newDeck(al, &.{ "v1", "m1", "m2" }, try std.fmt.allocPrint(al, "rule vm via_map(v1, m1, m2; below_min: {d}nm, below_max: {d}nm, above_min: {d}nm, above_max: {d}nm, cut: 30nm x 30nm)", .{ below[0], below[1], above[0], above[1] })));
        }
    }.f;
    try expectNonPositive(try map(a, .{ 60, 50 }, .{ 80, 80 }), "vm", -10);
    try expectNonPositive(try map(a, .{ 50, 50 }, .{ 90, 80 }), "vm", -10);
    try expectOk(try map(a, .{ 50, 50 }, .{ 80, 80 }));
    try expectOk(try map(a, .{ 49, 50 }, .{ 80, 81 }));
}

test "a forbidden range must not run backwards" {
    // Oracle: `Rule::ForbiddenSpacing`'s range is "from `min` to `max`, both
    // included": `min` past `max` is no range (a bad table); `min` equal to
    // `max` forbids one gap.
    var arena: std.heap.ArenaAllocator = .init(gpa);
    defer arena.deinit();
    const a = arena.allocator();
    try expectBadTable(try compile(a, try common.oneLayerDeck(a, "rule f forbidden_space(met1; min: 151nm, max: 150nm, prl: 0nm)")), "f");
    try expectOk(try compile(a, try common.oneLayerDeck(a, "rule f forbidden_space(met1; min: 150nm, max: 150nm, prl: 0nm)")));
}

test "a single cut via stack alternates metal and cut" {
    // Oracle: `Rule::ViaStack` with `single` lists "the metals and cuts
    // alternating", a metal at each end: an odd count of at least 5 layers
    // (metal, cut, metal, cut, metal). Four or six layers are refused,
    // expecting 5; five and seven build.
    var arena: std.heap.ArenaAllocator = .init(gpa);
    defer arena.deinit();
    const a = arena.allocator();
    const all = [_][]const u8{ "m1", "v1", "m2", "v2", "m3", "v3", "m4" };
    const stack = struct {
        fn f(al: std.mem.Allocator, layers: []const []const u8) !Outcome {
            const names = try std.mem.join(al, ", ", layers);
            return compile(al, try common.newDeck(al, &all, try std.fmt.allocPrint(al, "rule s via_stack({s}, single) <= 2", .{names})));
        }
    }.f;
    try expectLayerCount(try stack(a, all[0..4]), "s", 5, 4);
    try expectOk(try stack(a, all[0..5]));
    try expectLayerCount(try stack(a, all[0..6]), "s", 5, 6);
    try expectOk(try stack(a, all[0..7]));
}

test "anchored patterning takes one anchor per colour" {
    // Oracle: `Rule::AnchoredPatterning`'s rustdoc: one layer split into
    // `colors` masks with one anchor layer per mask, at most four. With two
    // colours, one anchor and two build; none (one layer) and three anchors
    // are refused, expecting 1 + 2 = 3 layers.
    var arena: std.heap.ArenaAllocator = .init(gpa);
    defer arena.deinit();
    const a = arena.allocator();
    const all = [_][]const u8{ "met1", "c1", "c2", "c3" };
    const anchored = struct {
        fn f(al: std.mem.Allocator, layers: []const []const u8) !Outcome {
            const names = try std.mem.join(al, ", ", layers);
            return compile(al, try common.newDeck(al, &all, try std.fmt.allocPrint(al, "rule a patterning({s}; colors: 2) >= 100nm", .{names})));
        }
    }.f;
    try expectOk(try anchored(a, all[0..2]));
    try expectOk(try anchored(a, all[0..3]));
    try expectLayerCount(try anchored(a, all[0..4]), "a", 3, 4);
}

test "a cut class needs positive sides" {
    // Oracle: `Rule::CutClass`'s rustdoc: each class a positive width and
    // height. A side of 0 is refused with that side; 1 builds.
    var arena: std.heap.ArenaAllocator = .init(gpa);
    defer arena.deinit();
    const a = arena.allocator();
    const classes = struct {
        fn f(al: std.mem.Allocator, allowed: []const u8) !Outcome {
            return compile(al, try common.newDeck(al, &.{"via"}, try std.fmt.allocPrint(al, "rule cc size(via; allowed: [{s}])", .{allowed})));
        }
    }.f;
    try expectNonPositive(try classes(a, "100nm x 100nm, 0nm x 200nm"), "cc", 0);
    try expectNonPositive(try classes(a, "100nm x 100nm, 100nm x 0nm"), "cc", 0);
    try expectOk(try classes(a, "1nm x 1nm"));
}

test "an allowed width must be positive" {
    // Oracle: `Rule::AllowedWidth`'s rustdoc: every width positive. A width
    // of 0 is refused with it; 1 builds.
    var arena: std.heap.ArenaAllocator = .init(gpa);
    defer arena.deinit();
    const a = arena.allocator();
    try expectNonPositive(try compile(a, try common.oneLayerDeck(a, "rule aw width(met1; allowed: [100nm, 0nm])")), "aw", 0);
    try expectOk(try compile(a, try common.oneLayerDeck(a, "rule aw width(met1; allowed: [1nm])")));
}

test "a count must fit the rule that stores it" {
    // Oracle: each count a rule stores in a narrower integer is a value of
    // that integer: a via stack's height is a `u16` (65535 builds, 65536 is
    // the wrong kind of value), a patterning's colour count a `u8` (255
    // builds, 256 is refused).
    var arena: std.heap.ArenaAllocator = .init(gpa);
    defer arena.deinit();
    const a = arena.allocator();
    try expectOk(try compile(a, try common.newDeck(a, &.{ "v1", "v2" }, "rule s via_stack(v1, v2) <= 65535")));
    try expectParamType(try compile(a, try common.newDeck(a, &.{ "v1", "v2" }, "rule s via_stack(v1, v2) <= 65536")), "s", "max_height");
    try expectOk(try compile(a, try common.oneLayerDeck(a, "rule p patterning(met1; colors: 255) >= 100nm")));
    try expectParamType(try compile(a, try common.oneLayerDeck(a, "rule p patterning(met1; colors: 256) >= 100nm")), "p", "colors");
}

test "a pattern lists rectangles by corner pairs" {
    // Oracle: `pattern`'s shapes and don't-care boxes are rectangles by two
    // opposite corners each: an odd count of corners is no list of
    // rectangles (a bad table); the even L of the root fixture builds.
    var arena: std.heap.ArenaAllocator = .init(gpa);
    defer arena.deinit();
    const a = arena.allocator();
    try expectOk(try compile(a, try common.oneLayerDeck(a, "rule p pattern(met1; window: 300nm x 300nm, shapes: [0nm x 0nm, 300nm x 100nm, 0nm x 100nm, 100nm x 300nm], ignore: none)")));
    try expectBadTable(try compile(a, try common.oneLayerDeck(a, "rule p pattern(met1; window: 300nm x 300nm, shapes: [0nm x 0nm, 300nm x 100nm, 0nm x 100nm], ignore: none)")), "p");
}

test "off grid reads only the drawn layers" {
    // Oracle: `RuleSet::first_derived`'s rustdoc: "`Rule::OffGrid` ... check
    // drawn rows only". A 100 square on a 10 nm pitch grown by 5 nm is a
    // derived layer whose every vertex is off the pitch; the drawn square is
    // on it, so the rule finds nothing. Unmoved: the harness's far offset is
    // off the pitch itself.
    var arena: std.heap.ArenaAllocator = .init(gpa);
    defer arena.deinit();
    var layout = try common.met1(&.{.{ 0, 0, 100, 100 }});
    defer layout.deinit();
    try common.checkCase("sized", try common.oneLayerDeck(arena.allocator(), "layer fat = met1.sized(5nm)\nrule g off_grid(; pitch: 10nm)"), &layout, &.{.{ .id = "g", .findings = &.{} }});
}
