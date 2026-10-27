//! Layout edits the deck configures: density fill (FLOW-007) and DRC-clean
//! enhancement (FLOW-009), each written as GDSII and checked again by the
//! deck it was made for. Ported from tests/engine/edits.rs.

const std = @import("std");
const testing = std.testing;
const Allocator = std.mem.Allocator;
const geom = @import("geom");
const ingest = @import("ingest");
const testgen = @import("testgen");
const gpurify = @import("gpurify");
const gpa = testing.allocator;
const io = testing.io;

/// A rectangle in nm on a deck layer, by name.
const Rect = struct { []const u8, i64, i64, i64, i64 };

/// A label: layer, text, x, y.
const Label = struct { []const u8, []const u8, i64, i64 };

const die: Rect = .{ "die", 0, 0, 10_000, 10_000 };

const met1: Rect = .{ "met1", 0, 0, 2_000, 10_000 };

/// DRC findings per rule name, and their total.
const Drc = struct {
    total: u32,
    rules: []const []const u8,
    loaded: gpurify.Loaded,
    extracted: gpurify.Extracted,
    outputs: gpurify.Outputs,

    fn count(d: Drc, rule: []const u8) usize {
        var n: usize = 0;
        for (d.rules) |r| n += @intFromBool(std.mem.eql(u8, r, rule));
        return n;
    }
};

/// A deck (owned, freed with the work) and a layout written to a
/// temporary directory as `test.deck` and `in.gds`; an edit's output as
/// `out.gds`.
const Work = struct {
    tmp: testing.TmpDir,
    arena_state: std.heap.ArenaAllocator,

    fn init(deck: []u8, rects: []const Rect, labels: []const Label) !Work {
        defer testing.allocator.free(deck);
        var w: Work = .{ .tmp = testing.tmpDir(.{}), .arena_state = .init(gpa) };
        errdefer w.deinit();
        const a = w.arena();
        var strings: geom.StrTable = .empty;
        var diag: ingest.deck.Diag = .{};
        const parsed = try ingest.deck.parseDeck(a, a, deck, try .init(1000), &strings, &diag);
        var builder: geom.GeometryStoreBuilder = .{};
        for (rects) |r| _ = try builder.push(a, parsed.layers.id(&strings, r[0]).?, &.{ r[1], r[3], r[3], r[1] }, &.{ r[2], r[2], r[4], r[4] });
        var store: geom.GeometryStore = .empty;
        var order: std.ArrayList(u32) = .empty;
        try builder.finish(a, @intCast(parsed.layers.len()), &store, &order);
        const ls = try a.alloc(testgen.gds.Label, labels.len);
        for (labels, ls) |l, *o| o.* = .{ .layer = parsed.layers.id(&strings, l[0]).?, .x = l[2], .y = l[3], .text = l[1] };
        var bytes: std.ArrayList(u8) = .empty;
        try testgen.gds.writeStoreLabelled(a, &store, &parsed.layers, ls, "top", &bytes);
        try w.tmp.dir.writeFile(io, .{ .sub_path = "in.gds", .data = bytes.items });
        try w.tmp.dir.writeFile(io, .{ .sub_path = "test.deck", .data = deck });
        return w;
    }

    fn deinit(w: *Work) void {
        w.arena_state.deinit();
        w.tmp.cleanup();
    }

    fn arena(w: *Work) Allocator {
        return w.arena_state.allocator();
    }

    fn inputs(layout: []const u8) gpurify.Inputs {
        return .{ .layout = layout, .deck = "test.deck" };
    }

    /// Fills in.gds into out.gds; each line's square count.
    fn fill(w: *Work) ![]const u32 {
        var counts: std.ArrayList(u32) = .empty;
        var diag: gpurify.fill.Diagnostic = .{};
        const bytes = try gpurify.fill.fillGds(gpa, w.arena(), io, w.tmp.dir, inputs("in.gds"), &.{}, &counts, &diag);
        try w.tmp.dir.writeFile(io, .{ .sub_path = "out.gds", .data = bytes });
        return counts.items;
    }

    /// Enhances in.gds into out.gds.
    fn enhance(w: *Work) !gpurify.enhance.Enhanced {
        var kept: gpurify.enhance.Enhanced = .{};
        var diag: gpurify.RunDiagnostic = .{};
        const bytes = try gpurify.enhance.enhanceGds(gpa, w.arena(), io, w.tmp.dir, inputs("in.gds"), &.{}, &kept, &diag);
        try w.tmp.dir.writeFile(io, .{ .sub_path = "out.gds", .data = bytes });
        return kept;
    }

    /// The boxes on `layer` of `layout`, sorted.
    fn boxes(w: *Work, layout: []const u8, layer: []const u8) ![]const [4]i64 {
        var diag: gpurify.LoadDiagnostic = .{};
        const loaded = try gpurify.load(gpa, w.arena(), io, w.tmp.dir, inputs(layout), &.{}, &diag);
        const id = loaded.deck.deck.layers.id(&loaded.strings, layer).?;
        var out: std.ArrayList([4]i64) = .empty;
        for (loaded.store.layerBboxes(id)) |b| try out.append(w.arena(), .{ b.xlo, b.ylo, b.xhi, b.yhi });
        std.mem.sort([4]i64, out.items, {}, lessBox);
        return out.items;
    }

    /// DRC of `layout`: every finding's rule name, sorted.
    fn drc(w: *Work, layout: []const u8) !Drc {
        var diag: gpurify.RunDiagnostic = .{};
        const r = try gpurify.run(gpa, w.arena(), io, w.tmp.dir, inputs(layout), .{ .checks = .{ .drc = true } }, &.{}, &diag);
        const rules = try w.arena().alloc([]const u8, r.outputs.violations.len());
        for (rules, r.outputs.violations.rule.items) |*n, id| n.* = r.loaded.strings.resolve(id);
        std.mem.sort([]const u8, rules, {}, lessString);
        return .{ .total = @intCast(rules.len), .rules = rules, .loaded = r.loaded, .extracted = r.extracted, .outputs = r.outputs };
    }
};

// ---- private ----

/// A 10 um die, met1 down its left 2 um, density over met1 and its fill.
fn fillDeck(gpa_: Allocator, window: []const u8, max: []const u8, extra: []const u8) ![]u8 {
    return std.fmt.allocPrint(gpa_,
        \\grid 1nm
        \\layer met1 = gds(1, 0)
        \\layer fill1 = gds(1, 1)
        \\layer nofill = gds(2, 0)
        \\layer die = gds(3, 0)
        \\layer m1all = met1 or fill1
        \\rule pd.min density(m1all, die; window: {s}, step: {s}) >= 0.3
        \\rule pd.max density(m1all, die; window: {s}, step: {s}) <= {s}
        \\rule f.w width(fill1) >= 1um
        \\rule f.s space(fill1) >= 1um
        \\rule f.d space(fill1, met1) >= 1um
        \\rule f.x forbidden(fill1 and nofill)
        \\fill fill1 for m1all size 1um space 1um keep 1um avoid [met1, nofill]
        \\{s}
        \\
    , .{ window, window, window, window, max, extra });
}

/// Two metals joined by vias, a redundant-via rule on them, and a strap.
fn enhanceDeck(gpa_: Allocator, extra: []const u8) ![]u8 {
    return std.fmt.allocPrint(gpa_,
        \\grid 1nm
        \\layer met1 = gds(1, 0)
        \\layer via1 = gds(2, 0)
        \\layer met2 = gds(3, 0)
        \\layer m1lbl = gds(1, 5)
        \\connect conductors [met1, met2]
        \\connect touch_within_layer
        \\connect via via1 [met1, met2]
        \\connect label m1lbl names met1
        \\rule v.r via_redundancy(via1, met1, met2; pitch: 200nm, space: 100nm) >= 1
        \\rule v.s space(via1) >= 100nm
        \\rule m1.s space(met1) >= 140nm
        \\{s}
        \\
    , .{extra});
}

/// The 1 um squares at these (x, y) corners in um, sorted.
fn squares(arena: Allocator, corners: []const [2]i64) ![]const [4]i64 {
    const out = try arena.alloc([4]i64, corners.len);
    for (corners, out) |c, *o| o.* = .{ c[0] * 1000, c[1] * 1000, c[0] * 1000 + 1000, c[1] * 1000 + 1000 };
    std.mem.sort([4]i64, out, {}, lessBox);
    return out;
}

fn lessBox(_: void, a: [4]i64, b: [4]i64) bool {
    return std.mem.order(i64, &a, &b) == .lt;
}

fn lessString(_: void, a: []const u8, b: []const u8) bool {
    return std.mem.order(u8, a, b) == .lt;
}

/// The rate `v.r` measures: 1 when the rule reports nothing.
fn rate(d: *const Drc) f64 {
    const v = &d.outputs.violations;
    for (v.rule.items, 0..) |id, row| if (std.mem.eql(u8, d.loaded.strings.resolve(id), "v.r")) return v.get(@intCast(row)).measured.float();
    return 1.0;
}

/// Every finding but `v.r` by (rule, x, y), counted.
fn places(arena: Allocator, d: *const Drc) !std.StringHashMapUnmanaged(u32) {
    var out: std.StringHashMapUnmanaged(u32) = .empty;
    const v = &d.outputs.violations;
    for (v.rule.items, v.at.items) |id, at| {
        const rule = d.loaded.strings.resolve(id);
        if (std.mem.eql(u8, rule, "v.r")) continue;
        const got = try out.getOrPut(arena, try std.fmt.allocPrint(arena, "{s} {d} {d}", .{ rule, at.x, at.y }));
        if (!got.found_existing) got.value_ptr.* = 0;
        got.value_ptr.* += 1;
    }
    return out;
}

/// One seed: random vias, pads and wires; enhance; the laws.
fn enhanceLaws(seed: u64) !void {
    var rng: testgen.Rng = .init(seed);
    var rects: std.ArrayList(Rect) = .empty;
    defer rects.deinit(gpa);
    var labels: std.ArrayList(Label) = .empty;
    defer labels.deinit(gpa);
    for (0..@intCast(rng.range(1, 8))) |_| {
        const x = rng.range(0, 40) * 100;
        const y = rng.range(0, 40) * 100;
        try rects.append(gpa, .{ "via1", x, y, x + 100, y + 100 });
        for ([_][]const u8{ "met1", "met2" }) |metal| {
            var e: [4]i64 = undefined;
            for (&e) |*v| v.* = rng.range(0, 4) * 20;
            const long = rng.below(3) == 0;
            const reach: i64 = if (long) rng.range(2, 8) * 100 else 0;
            try rects.append(gpa, .{ metal, x - e[0], y - e[1], x + 100 + e[2] + reach, y + 100 + e[3] });
        }
    }
    for (0..@intCast(rng.range(0, 4))) |k| {
        const x = rng.range(0, 40) * 100;
        const y = rng.range(0, 40) * 100;
        const wd = rng.range(2, 6) * 100;
        try rects.append(gpa, .{ "met1", x, y, x + wd, y + 2000 });
        if (k == 0) try labels.append(gpa, .{ "m1lbl", "VDD", x + @divTrunc(wd, 2), y + 1000 });
    }
    var w: Work = try .init(try enhanceDeck(testing.allocator, "rule v.e enclosure(via1, met1) >= 20nm\nrule m2.s space(met2) >= 140nm\nwiden met1 net \"V*\" by 100nm"), rects.items, labels.items);
    defer w.deinit();
    // A label on two touching shapes of different names, say.
    const before = w.drc("in.gds") catch return;
    const kept = try w.enhance();
    const after = try w.drc("out.gds");
    const was = try places(w.arena(), &before);
    var now = try places(w.arena(), &after);
    var it = now.iterator();
    while (it.next()) |e| {
        const old = was.get(e.key_ptr.*) orelse 0;
        if (old < e.value_ptr.*) {
            std.debug.print("seed {d}: new {s}\n", .{ seed, e.key_ptr.* });
            return error.TestNewFinding;
        }
    }
    try testing.expect(rate(&after) >= rate(&before));
    try testing.expectEqual(before.extracted.nets.netCount(), after.extracted.nets.netCount());
    try testing.expectEqual((try w.boxes("in.gds", "via1")).len + kept.cuts, (try w.boxes("out.gds", "via1")).len);
}

test "fill tops a window up to its minimum and the result is drc clean" {
    // Oracle: hand-derived. One 10 um window holds met1's 20 um² of 100;
    // sites are 1 um squares on a 2 um pitch, those at x = 0 and 2 um within
    // 1 um of met1, leaving columns 4, 6, 8 um. Ten squares bring the window
    // to exactly 0.3: three rows of three and (4, 6). And a law: the output
    // has no DRC finding at all.
    var w: Work = try .init(try fillDeck(testing.allocator, "10um", "0.6", ""), &.{ die, met1 }, &.{});
    defer w.deinit();
    const counts = try w.fill();
    try testing.expectEqualSlices(u32, &.{10}, counts);
    try testing.expectEqualDeep(try squares(w.arena(), &.{ .{ 4, 0 }, .{ 6, 0 }, .{ 8, 0 }, .{ 4, 2 }, .{ 6, 2 }, .{ 8, 2 }, .{ 4, 4 }, .{ 6, 4 }, .{ 8, 4 }, .{ 4, 6 } }), try w.boxes("out.gds", "fill1"));
    try testing.expectEqual(0, (try w.drc("out.gds")).total);
    // The input is short of the minimum: the fill is what fixed it.
    try testing.expectEqual(1, (try w.drc("in.gds")).count("pd.min"));
}

test "fill stops at a maximum even below the minimum" {
    // Oracle: hand-derived. With the maximum at 0.25 over met1's 0.2, five
    // squares of 1 % reach it exactly (a limit is inclusive) and a sixth
    // would pass it; the window stays below its 0.3 minimum.
    var w: Work = try .init(try fillDeck(testing.allocator, "10um", "0.25", ""), &.{ die, met1 }, &.{});
    defer w.deinit();
    try testing.expectEqualSlices(u32, &.{5}, try w.fill());
    try testing.expectEqualDeep(try squares(w.arena(), &.{ .{ 4, 0 }, .{ 6, 0 }, .{ 8, 0 }, .{ 4, 2 }, .{ 6, 2 } }), try w.boxes("out.gds", "fill1"));
    const d = try w.drc("out.gds");
    try testing.expectEqual(1, d.count("pd.min"));
    try testing.expectEqual(0, d.count("pd.max"));
}

test "fill avoids no-fill regions and fills window by window" {
    // Oracle: hand-derived. A no-fill box over x = 7 to 10 um blocks the
    // columns at 6 and 8 um, leaving x = 4 um: five squares, short of the
    // minimum, none on the box. With 5 um windows only the right two want
    // fill, from x = 6 and 8 um: ten squares, both windows still short.
    {
        var w: Work = try .init(try fillDeck(testing.allocator, "10um", "0.6", ""), &.{ die, met1, .{ "nofill", 7000, 0, 10000, 10000 } }, &.{});
        defer w.deinit();
        try testing.expectEqualSlices(u32, &.{5}, try w.fill());
        try testing.expectEqualDeep(try squares(w.arena(), &.{ .{ 4, 0 }, .{ 4, 2 }, .{ 4, 4 }, .{ 4, 6 }, .{ 4, 8 } }), try w.boxes("out.gds", "fill1"));
        const d = try w.drc("out.gds");
        try testing.expectEqual(1, d.count("pd.min"));
        try testing.expectEqual(0, d.count("f.x"));
    }
    var w: Work = try .init(try fillDeck(testing.allocator, "5um", "0.6", ""), &.{ die, met1 }, &.{});
    defer w.deinit();
    try testing.expectEqualSlices(u32, &.{10}, try w.fill());
    var right: [10][2]i64 = undefined;
    for (0..5) |y| for (0..2) |x| {
        right[y * 2 + x] = .{ 6 + 2 * @as(i64, @intCast(x)), 2 * @as(i64, @intCast(y)) };
    };
    try testing.expectEqualDeep(try squares(w.arena(), &right), try w.boxes("out.gds", "fill1"));
    try testing.expectEqual(2, (try w.drc("out.gds")).count("pd.min"));
}

test "fill without a density rule is refused" {
    // Oracle: the refusal docs/src/reference/deck/fill-and-enhance.md (Density
    // fill) states for a `fill` line: no rule measures met1, so nothing says
    // how much to fill.
    const text = try fillDeck(testing.allocator, "10um", "0.6", "");
    const deck = try std.mem.replaceOwned(u8, testing.allocator, text, "for m1all", "for met1");
    testing.allocator.free(text);
    var w: Work = try .init(deck, &.{ die, met1 }, &.{});
    defer w.deinit();
    try testing.expectError(error.NoDensityRule, w.fill());
}

test "a redundant cut is added where the rule finds room and taken back on a new finding" {
    // Oracle: hand-derived. A 100 nm cut at (0, 0) on 500 x 100 nm plates
    // has room only to its right, one 200 nm pitch: (200, 0)-(300, 100),
    // 100 nm from the first. The output is clean. With `enclosure(via1,
    // met1) >= 10nm` the new cut is 0 nm from met1's edge, a new finding,
    // so it is taken back and the output's findings are the input's.
    const rects = [_]Rect{ .{ "met1", 0, 0, 500, 100 }, .{ "met2", 0, 0, 500, 100 }, .{ "via1", 0, 0, 100, 100 } };
    {
        var w: Work = try .init(try enhanceDeck(testing.allocator, ""), &rects, &.{});
        defer w.deinit();
        try testing.expectEqual(0, (try w.drc("in.gds")).total);
        const kept = try w.enhance();
        try testing.expectEqual(gpurify.enhance.Enhanced{ .cuts = 1, .sides = 0 }, kept);
        try testing.expectEqualDeep(@as([]const [4]i64, &.{ .{ 0, 0, 100, 100 }, .{ 200, 0, 300, 100 } }), try w.boxes("out.gds", "via1"));
        try testing.expectEqual(0, (try w.drc("out.gds")).total);
    }
    var w: Work = try .init(try enhanceDeck(testing.allocator, "rule v.e enclosure(via1, met1) >= 10nm"), &rects, &.{});
    defer w.deinit();
    const before = try w.drc("in.gds");
    try testing.expectEqual(0, (try w.enhance()).cuts);
    try testing.expectEqualDeep(@as([]const [4]i64, &.{.{ 0, 0, 100, 100 }}), try w.boxes("out.gds", "via1"));
    try testing.expectEqualDeep(before.rules, (try w.drc("out.gds")).rules);
}

test "a dead via gets a second cut and its metal and the rate rises" {
    // Oracle: hand-derived (catalog FLOW-009). A cut on pads enclosing it by
    // 20 nm is dead (rate 0, one `v.r`); the first neighbour (200, 0)-(300,
    // 100) goes in with each metal's box round both cuts grown by its 20 nm
    // margin, (-20, -20)-(320, 120), so `v.e` holds and the rate is 1.
    const rects = [_]Rect{ .{ "met1", -20, -20, 120, 120 }, .{ "met2", -20, -20, 120, 120 }, .{ "via1", 0, 0, 100, 100 } };
    var w: Work = try .init(try enhanceDeck(testing.allocator, "rule v.e enclosure(via1, met1) >= 20nm"), &rects, &.{});
    defer w.deinit();
    const before = try w.drc("in.gds");
    try testing.expectEqual(1, before.count("v.r"));
    try testing.expectEqual(1, (try w.enhance()).cuts);
    try testing.expectEqualDeep(@as([]const [4]i64, &.{ .{ 0, 0, 100, 100 }, .{ 200, 0, 300, 100 } }), try w.boxes("out.gds", "via1"));
    for ([_][]const u8{ "met1", "met2" }) |metal| try testing.expectEqualDeep(@as([]const [4]i64, &.{ .{ -20, -20, 120, 120 }, .{ -20, -20, 320, 120 } }), try w.boxes("out.gds", metal));
    try testing.expectEqual(0, (try w.drc("out.gds")).total);
}

test "enhancement adds no finding and never lowers the rate" {
    // Oracle: law (catalog FLOW-009). On 15 random layouts of vias (pads of
    // random enclosure, some on long wires), loose met1 wires and a labelled
    // supply strap, the enhanced layout has no finding the input lacked
    // (rule and place), a redundant-via rate no lower, the same nets, and
    // exactly the input's cuts plus those it says it added.
    for (0..15) |seed| try enhanceLaws(seed);
}

test "a strap widens only where no finding follows" {
    // Oracle: hand-derived. A 1 um VPWR strap widened 200 nm a side: its
    // left strip is clear and kept; on its right a wire of another net
    // 300 nm away would be 100 nm from the strip, under `m1.s` (140 nm), so
    // that side is taken back. A strip that would touch another net, and a
    // strap matching no pattern, are never candidates.
    const deck_text = "widen met1 net \"VP*\" by 200nm";
    const labels = [_]Label{ .{ "m1lbl", "VPWR", 500, 5000 }, .{ "m1lbl", "sig", 1400, 5000 } };
    {
        var w: Work = try .init(try enhanceDeck(testing.allocator, deck_text), &.{ .{ "met1", 0, 0, 1000, 10000 }, .{ "met1", 1300, 0, 1500, 10000 } }, &labels);
        defer w.deinit();
        try testing.expectEqual(gpurify.enhance.Enhanced{ .cuts = 0, .sides = 1 }, try w.enhance());
        const rows = try w.boxes("out.gds", "met1");
        try testing.expectEqual(3, rows.len);
        const strip = for (rows) |b| (if (b[0] == -200 and b[2] == 0) break true) else false;
        try testing.expect(strip);
        try testing.expectEqual(0, (try w.drc("out.gds")).total);
    }
    {
        var w: Work = try .init(try enhanceDeck(testing.allocator, deck_text), &.{ .{ "met1", 0, 0, 1000, 10000 }, .{ "met1", 1150, 0, 1500, 10000 } }, &labels);
        defer w.deinit();
        try testing.expectEqual(1, (try w.enhance()).sides);
    }
    var w: Work = try .init(try enhanceDeck(testing.allocator, "widen met1 net \"VGND\" by 200nm"), &.{ .{ "met1", 0, 0, 1000, 10000 }, .{ "met1", 1300, 0, 1500, 10000 } }, &labels);
    defer w.deinit();
    try testing.expectEqual(0, (try w.enhance()).sides);
}
