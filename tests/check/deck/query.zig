//! The query API answers what the checker enforces (deck-library plan P2,
//! ledger D3; testing-plan L9b). Ported from
//! crates/check/tests/deck/query.rs.
//!
//! Oracle: differential against the checker, on planted cases. For every
//! rule of every shipped deck that a query answers for, a layout is drawn
//! exactly at the queried value, which the rules of that query must pass,
//! and one grid step under it, which they must flag with the largest
//! violation `limit` equal to the query. Every shape is drawn straight onto
//! the rule's layer, derived or not, and only the rules the query reads run.

const std = @import("std");
const testing = std.testing;
const geom = @import("geom");
const check = @import("check");
const testgen = @import("testgen");
const common = @import("common.zig");
const drc_common = @import("../drc/common.zig");
const q = check.deck.query;
const CompiledDeck = check.deck.CompiledDeck;
const Rule = check.drc.Rule;
const Kind = check.drc.Kind;
const LayerId = geom.LayerId;
const gpa = testing.allocator;

const Box = struct { layer: LayerId, b: [4]i64 };

/// The rules of one kind on one layer (`layer`, `outer`/`inner` pair).
const OnLayer = struct {
    kinds: []const Kind,
    layer: LayerId,

    fn holds(k: OnLayer, rule: Rule) bool {
        if (std.mem.indexOfScalar(Kind, k.kinds, std.meta.activeTag(rule)) == null) return false;
        return switch (rule) {
            inline else => |r| if (@hasField(@TypeOf(r), "layer") and @TypeOf(r.layer) == LayerId) r.layer == k.layer else false,
        };
    }
};

const OnPair = struct {
    kinds: []const Kind,
    inner: LayerId,
    outer: LayerId,

    fn holds(k: OnPair, rule: Rule) bool {
        if (std.mem.indexOfScalar(Kind, k.kinds, std.meta.activeTag(rule)) == null) return false;
        return switch (rule) {
            inline else => |r| if (@hasField(@TypeOf(r), "outer") and @hasField(@TypeOf(r), "inner")) r.outer == k.outer and r.inner == k.inner else false,
        };
    }
};

// ---- private ----

/// Runs the rules of `cd` that `keep` holds over `boxes`, and returns the
/// largest violation limit (null for none). Every rule must run.
fn largest(cd: *const CompiledDeck, keep: anytype, boxes: []const Box) !?i128 {
    var set = cd.drc;
    set.order = .empty;
    set.id = .empty;
    set.severity = .empty;
    set.first_derived = null;
    defer {
        set.order.deinit(gpa);
        set.id.deinit(gpa);
        set.severity.deinit(gpa);
    }
    for (0..cd.drc.len()) |at| if (keep.holds(cd.drc.get(@intCast(at)))) {
        try set.order.append(gpa, cd.drc.order.items[at]);
        try set.id.append(gpa, cd.drc.id.items[at]);
        try set.severity.append(gpa, .@"error");
    };
    var lb = testgen.shapes.LayoutBuilder.init(@intCast(cd.deck.layers.len()));
    for (boxes) |x| _ = try lb.rect(gpa, @backingInt(x.layer), x.b[0], x.b[1], x.b[2], x.b[3]);
    var built = try drc_common.finish(&lb);
    defer built.deinit();
    var out: check.report.Violations = .{};
    defer out.deinit(gpa);
    var runs: std.ArrayList(check.report.RuleRun) = .empty;
    defer runs.deinit(gpa);
    try check.drc.run(gpa, .cpu, null, &set, &built.store, null, &out, &runs);
    for (runs.items) |r| try testing.expectEqual(check.report.Outcome.ran, r.outcome);
    var best: ?i128 = null;
    for (0..out.len()) |k| {
        const l = out.get(@intCast(k)).limit.exact();
        best = @max(best orelse l, l);
    }
    return best;
}

/// At the queried value nothing; one under, the query as the limit.
fn expectEdge(what: []const u8, at_q: ?i128, under: ?i128, want: i128) !void {
    if (at_q != null or under == null or under.? != want) {
        std.debug.print("{s}: at {d} found {?d}, one under found {?d}\n", .{ what, want, at_q, under });
        return error.TestUnexpectedResult;
    }
}

fn widthCase(cd: *const CompiledDeck, layer: LayerId, what: []const u8) !void {
    const w = q.minWidth(cd, layer).?;
    try testing.expect(w > 1);
    const keep: OnLayer = .{ .kinds = &.{.min_width}, .layer = layer };
    const long = 10 * w + 1000;
    try expectEdge(what, try largest(cd, keep, &.{.{ .layer = layer, .b = .{ 0, 0, w, long } }}), try largest(cd, keep, &.{.{ .layer = layer, .b = .{ 0, 0, w - 1, long } }}), w);
}

fn areaCase(cd: *const CompiledDeck, layer: LayerId, what: []const u8) !void {
    const a: i64 = @intCast(q.minArea(cd, layer).?);
    const keep: OnLayer = .{ .kinds = &.{.min_area}, .layer = layer };
    try expectEdge(what, try largest(cd, keep, &.{.{ .layer = layer, .b = .{ 0, 0, 1, a } }}), try largest(cd, keep, &.{.{ .layer = layer, .b = .{ 0, 0, 1, a - 1 } }}), a);
}

fn holeBoxes(layer: LayerId, h: i64) [4]Box {
    // A 1-wide hole `h` high, framed 10 deep on every side.
    return .{ .{ .layer = layer, .b = .{ -10, -10, 0, h + 10 } }, .{ .layer = layer, .b = .{ 1, -10, 11, h + 10 } }, .{ .layer = layer, .b = .{ 0, -10, 1, 0 } }, .{ .layer = layer, .b = .{ 0, h, 1, h + 10 } } };
}

fn holeCase(cd: *const CompiledDeck, layer: LayerId, what: []const u8) !void {
    const a: i64 = @intCast(q.minEnclosedArea(cd, layer).?);
    const keep: OnLayer = .{ .kinds = &.{.min_enclosed_area}, .layer = layer };
    try expectEdge(what, try largest(cd, keep, &holeBoxes(layer, a)), try largest(cd, keep, &holeBoxes(layer, a - 1)), a);
}

/// Side by side, `wa` and `wb` wide, running `run` (raised to the wider).
fn sideBySide(wa: i64, wb: i64, run: i64) q.SpacingQuery {
    const r = @max(run, wa, wb);
    return .{ .width_a = wa, .width_b = wb, .run_length = r, .end_of_line = r };
}

fn spacingCase(cd: *const CompiledDeck, layer: LayerId, query: q.SpacingQuery, what: []const u8) !void {
    const s = q.requiredSpacing(cd, layer, query) orelse {
        std.debug.print("{s}: no spacing\n", .{what});
        return error.TestUnexpectedResult;
    };
    try testing.expect(s > 1);
    const keep: OnLayer = .{ .kinds = &.{ .min_spacing, .wide_dependent_spacing, .attached_wide_spacing, .prl_spacing, .eol_spacing, .spacing_table }, .layer = layer };
    const wa = query.width_a;
    const wb = query.width_b;
    const run = query.run_length;
    const at = struct {
        fn f(c: *const CompiledDeck, k: OnLayer, l: LayerId, a: i64, b: i64, r: i64, gap: i64) !?i128 {
            return largest(c, k, &.{ .{ .layer = l, .b = .{ 0, 0, a, r } }, .{ .layer = l, .b = .{ a + gap, 0, a + gap + b, r } } });
        }
    }.f;
    try expectEdge(what, try at(cd, keep, layer, wa, wb, run, s), try at(cd, keep, layer, wa, wb, run, s - 1), s);
}

fn enclosureCase(cd: *const CompiledDeck, inner: LayerId, outer: LayerId, opposite: bool, what: []const u8) !void {
    const e = q.enclosure(cd, inner, outer);
    const v = (if (opposite) e.opposite else e.all_sides).?;
    const keep: OnPair = .{ .kinds = if (opposite) &.{ .asymmetric_enclosure, .adjacent_enclosure } else &.{.min_enclosure}, .inner = inner, .outer = outer };
    const side = 100;
    const vertical: i64 = if (opposite) 0 else v;
    const at = struct {
        fn f(c: *const CompiledDeck, k: OnPair, i: LayerId, o: LayerId, enc: i64, vert: i64, left: i64) !?i128 {
            return largest(c, k, &.{ .{ .layer = i, .b = .{ 0, 0, side, side } }, .{ .layer = o, .b = .{ -left, -vert, side + enc, side + vert } } });
        }
    }.f;
    try expectEdge(what, try at(cd, keep, inner, outer, v, vertical, v), try at(cd, keep, inner, outer, v, vertical, v - 1), v);
}

fn viaCase(cd: *const CompiledDeck, layer: LayerId, threshold: u16, what: []const u8) !void {
    const cuts: u32 = @as(u32, threshold) + 1;
    const s = q.viaArraySpacing(cd, layer, cuts).?;
    const keep: OnLayer = .{ .kinds = &.{.via_array_spacing}, .layer = layer };
    var boxes: std.ArrayList(Box) = .empty;
    defer boxes.deinit(gpa);
    var found: [2]?i128 = undefined;
    for ([2]i64{ s, s - 1 }, 0..) |gap, k| {
        boxes.clearRetainingCapacity();
        for (0..cuts) |i| {
            const x = @as(i64, @intCast(i)) * (10 + gap);
            try boxes.append(gpa, .{ .layer = layer, .b = .{ x, 0, x + 10, 10 } });
        }
        found[k] = try largest(cd, keep, boxes.items);
    }
    try expectEdge(what, found[0], found[1], s);
}

test "every query is the limit the checker reports" {
    // Oracle: differential against the checker on construct-from-answer
    // layouts: at the queried value it passes, one grid step under it it
    // flags with that value as its `limit`.
    var arena: std.heap.ArenaAllocator = .init(gpa);
    defer arena.deinit();
    for (common.shipped) |name| {
        var c = try common.compileText(try common.shippedText(arena.allocator(), name), 1000);
        defer c.deinit();
        const cd = &c.cd;
        var covered: u32 = 0;
        for (0..cd.drc.len()) |at| {
            const what = try std.fmt.allocPrint(arena.allocator(), "{s} {s}", .{ name, c.strings.resolve(cd.drc.id.items[at]) });
            const base = struct {
                fn f(d: *const CompiledDeck, l: LayerId) i64 {
                    return q.minWidth(d, l) orelse 100;
                }
            }.f;
            switch (cd.drc.get(@intCast(at))) {
                .min_width => |r| try widthCase(cd, r.layer, what),
                .min_area => |r| try areaCase(cd, r.layer, what),
                .min_enclosed_area => |r| try holeCase(cd, r.layer, what),
                .min_spacing => |r| {
                    const w = base(cd, r.layer);
                    try spacingCase(cd, r.layer, sideBySide(w, w, w), what);
                },
                .wide_dependent_spacing => |r| try spacingCase(cd, r.layer, sideBySide(r.width_threshold, base(cd, r.layer), base(cd, r.layer)), what),
                .attached_wide_spacing => |r| try spacingCase(cd, r.layer, sideBySide(r.width_threshold, base(cd, r.layer), base(cd, r.layer)), what),
                .prl_spacing => |r| {
                    const w = base(cd, r.layer);
                    try spacingCase(cd, r.layer, sideBySide(w, w, r.prl_threshold), what);
                },
                .eol_spacing => |r| {
                    const run = r.eol_width - 1;
                    const w = @min(base(cd, r.layer), run);
                    try spacingCase(cd, r.layer, sideBySide(w, w, run), what);
                },
                .spacing_table => |r| {
                    const t = cd.drc.spacingTable(r.table);
                    const w = base(cd, r.layer);
                    for (0..t.width.len) |row| for (0..t.prl.len) |column| {
                        const wide = if (row == 0) w else t.width[row] + 1;
                        try spacingCase(cd, r.layer, sideBySide(wide, w, t.prl[column] + 1), what);
                    };
                },
                .min_enclosure => |r| try enclosureCase(cd, r.inner, r.outer, false, what),
                .asymmetric_enclosure => |r| try enclosureCase(cd, r.inner, r.outer, true, what),
                .adjacent_enclosure => |r| try enclosureCase(cd, r.inner, r.outer, true, what),
                .via_array_spacing => |r| try viaCase(cd, r.layer, r.array_threshold, what),
                else => continue,
            }
            covered += 1;
        }
        try testing.expect(covered > 0);
    }
}

test "the queries keep to the layers they are asked about" {
    // Oracle: the queries' doc comments, on a deck written so each answer is
    // read off the text: every enclosure kind for a via in two metals with
    // different limits (the largest minimum per kind, the smallest maximum,
    // `full_width` on one pair only); an array spacing applies to arrays of
    // more cuts than its threshold; each density row answers for its layer.
    const text =
        \\grid 1nm
        \\layer m = gds(1, 0)
        \\layer n = gds(2, 0)
        \\layer v = gds(3, 0)
        \\rule e1 enclosure(v, m) >= 30nm
        \\rule e2 enclosure(v, n) >= 50nm
        \\rule e3 enclosure(v, m, opposite) >= 40nm
        \\rule e4 enclosure(v, n, opposite) >= 70nm
        \\rule e5 enclosure(v, m, adjacent) >= 45nm
        \\rule e6 enclosure(v, n, adjacent) >= 60nm
        \\rule e7 enclosure(v, m, noncoincident) >= 20nm
        \\rule e8 enclosure(v, n, noncoincident) >= 25nm
        \\rule e9 enclosure(v, m) <= 95nm
        \\rule e10 enclosure(v, n) <= 80nm
        \\rule e11 enclosure(v, n) <= 85nm
        \\rule fw full_width(v, n)
        \\rule va2 via_array_space(v; array: 2) >= 100nm
        \\rule va3 via_array_space(v; array: 3) >= 200nm
        \\rule d1 density(m; window: 500nm, step: 250nm) >= 0.3
        \\rule d2 global_density(n) <= 0.5
        \\
    ;
    var c = try common.compileText(text, 1000);
    defer c.deinit();
    const cd = &c.cd;
    const m = cd.deck.layers.id(&c.strings, "m").?;
    const n = cd.deck.layers.id(&c.strings, "n").?;
    const v = cd.deck.layers.id(&c.strings, "v").?;
    try testing.expectEqual(q.Enclosure{ .all_sides = 30, .opposite = 45, .noncoincident = 20, .at_most = 95, .full_width = false }, q.enclosure(cd, v, m));
    try testing.expectEqual(q.Enclosure{ .all_sides = 50, .opposite = 70, .noncoincident = 25, .at_most = 80, .full_width = true }, q.enclosure(cd, v, n));
    try testing.expectEqual(q.Enclosure{}, q.enclosure(cd, m, v));
    // "More than its threshold": 2 cuts are no array of either, 3 an array
    // of the first, 4 of both.
    try testing.expectEqual(@as(?i64, null), q.viaArraySpacing(cd, v, 2));
    try testing.expectEqual(@as(?i64, 100), q.viaArraySpacing(cd, v, 3));
    try testing.expectEqual(@as(?i64, 200), q.viaArraySpacing(cd, v, 4));
    try testing.expectEqual(@as(?i64, null), q.viaArraySpacing(cd, m, 4));
    var rows: std.ArrayList(q.DensityLimit) = .empty;
    defer rows.deinit(gpa);
    try q.densityInto(gpa, cd, m, &rows);
    try testing.expectEqual(@as(usize, 1), rows.items.len);
    try testing.expectEqualStrings("d1", c.strings.resolve(rows.items[0].rule));
    try testing.expectEqual(@as(?[2]i64, .{ 500, 250 }), rows.items[0].window);
    try q.densityInto(gpa, cd, n, &rows);
    try testing.expectEqual(@as(usize, 1), rows.items.len);
    try testing.expectEqualStrings("d2", c.strings.resolve(rows.items[0].rule));
    try testing.expectEqual(@as(?[2]i64, null), rows.items[0].window);
    try q.densityInto(gpa, cd, v, &rows);
    try testing.expectEqual(@as(usize, 0), rows.items.len);
}

test "the electrical queries read what the deck states" {
    // Oracle: the deck text, pdks/sky130.deck's `ar.met1.1`, `EM.met1_mcon`,
    // `vgs.esd_nfet`, `vds.d10v5`, `vgs.01v8` and `vds.01v8`.
    var arena: std.heap.ArenaAllocator = .init(gpa);
    defer arena.deinit();
    var c = try common.compileText(try common.shippedText(arena.allocator(), "sky130"), 1000);
    defer c.deinit();
    const cd = &c.cd;
    const layer = struct {
        fn of(cc: *const common.Compiled, name: []const u8) LayerId {
            return cc.cd.deck.layers.id(&cc.strings, name).?;
        }
    }.of;
    // rule ar.met1.1 antenna_electrical(gate, met1; max_ratio: 400,
    //     sidewall: 350nm, .. diode: antenna_diode, ..)
    var antenna: std.ArrayList(q.AntennaLimit) = .empty;
    defer antenna.deinit(gpa);
    try q.antennaInto(gpa, cd, layer(&c, "met1"), &antenna);
    try testing.expectEqual(@as(usize, 1), antenna.items.len);
    const a = antenna.items[0];
    try testing.expectEqual(c.strings.get("ar.met1.1").?, a.rule);
    try testing.expectEqual(layer(&c, "gate"), a.gate);
    try testing.expectEqual(@as(u64, @bitCast(@as(f64, 400.0))), @as(u64, @bitCast(a.max_ratio)));
    try testing.expectEqual(check.erc.antenna_tables.AntennaMeasure{ .sidewall = 350 }, a.measure);
    try testing.expectEqual(@as(?LayerId, layer(&c, "antenna_diode")), a.diode);
    // rule EM.met1_mcon em_current_density(met1, mcon; max_density:
    //     2.8mA/um, max_current_per_cut: 0.36mA, narrow: none)
    var em: std.ArrayList(q.EmLimit) = .empty;
    defer em.deinit(gpa);
    try q.emLimitInto(gpa, cd, layer(&c, "mcon"), &em);
    try testing.expectEqual(@as(usize, 1), em.items.len);
    try testing.expectEqual(c.strings.get("EM.met1_mcon").?, em.items[0].rule);
    // 2.8 mA/um is 2800 A/m; 0.36 mA is 360 uA.
    try testing.expectEqual(@as(u64, @bitCast(@as(f64, 2800.0))), @as(u64, @bitCast(em.items[0].max_density.raw)));
    try testing.expectEqual(@as(u64, @bitCast(@as(f64, 360.0))), @as(u64, @bitCast(em.items[0].max_current_per_cut.raw)));
    // vgs.esd_nfet gate_oxide 5V; vds.d10v5 drain_source 11V (g5d10_fets).
    const esd = q.fetLimits(cd, c.strings.get("sky130_fd_pr__esd_nfet_g5v0d10v5").?);
    try testing.expectEqual(@as(f64, 5000.0), esd.gate_oxide.?.raw);
    try testing.expectEqual(@as(f64, 11_000.0), esd.drain_source.?.raw);
    // vgs.01v8 and vds.01v8, 1.95 V each (lv_fets).
    const lv = q.fetLimits(cd, c.strings.get("sky130_fd_pr__nfet_01v8").?);
    try testing.expectEqual(@as(f64, 1950.0), lv.gate_oxide.?.raw);
    try testing.expectEqual(@as(f64, 1950.0), lv.drain_source.?.raw);
}
