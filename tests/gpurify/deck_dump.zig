//! The deck dump (`gpurify deck`) against the query layer: every shipped
//! deck dumps, and each value in its `answers` reads back, through a JSON
//! parse, as the value the query function returns when called again here.
//! No Rust source: the dump is new in the Zig port.

const std = @import("std");
const testing = std.testing;
const Allocator = std.mem.Allocator;
const Value = std.json.Value;
const geom = @import("geom");
const LayerId = geom.LayerId;
const check = @import("check");
const query = check.deck.query;
const CompiledDeck = check.deck.CompiledDeck;
const gpurify = @import("gpurify");

// ---- private ----

fn layerAnswers(arena: Allocator, cd: *const CompiledDeck, strings: *const geom.StrTable, entries: []const Value) !void {
    try testing.expectEqual(cd.deck.layers.len(), entries.len);
    for (entries, 0..) |entry, i| {
        const e = entry.object;
        const l: LayerId = @fromBackingInt(@as(u16, @intCast(i)));
        try expectInt(e.get("layer").?, @as(?u16, @intCast(i)));
        try expectInt(e.get("min_width_nm").?, query.minWidth(cd, l));
        try expectInt(e.get("min_area_nm2").?, query.minArea(cd, l));
        try expectInt(e.get("min_enclosed_area_nm2").?, query.minEnclosedArea(cd, l));
        try expectInt(e.get("min_step_nm").?, query.minStep(cd, l));
        try expectFloat(e.get("max_aspect_ratio").?, query.maxAspectRatio(cd, l));
        try expectInt(e.get("max_total_area_nm2").?, query.maxTotalArea(cd, l));
        try expectInts(e.get("allowed_widths_nm").?, query.allowedWidths(cd, l));
        try expectInt(e.get("allowed_widths_from_nm").?, query.allowedWidthsFrom(cd, l));
        if (query.cutClasses(cd, l)) |classes| {
            const got = e.get("cut_classes_nm").?.array.items;
            try testing.expectEqual(classes.len, got.len);
            for (classes, got) |c, g| try expectInts(g, @as(?[]const i64, &c));
        } else try testing.expect(e.get("cut_classes_nm").? == .null);
        // The documented queries: two min-width shapes with no run, and two
        // shapes as wide as a coordinate reaches, running as far, on line ends.
        const narrow = query.minWidth(cd, l) orelse 0;
        const far: geom.Dbu = geom.max_abs_dbu;
        const spacing = e.get("spacing_nm").?.object;
        try expectInt(spacing.get("min_width").?, query.requiredSpacing(cd, l, .{ .width_a = narrow, .width_b = narrow, .run_length = 0 }));
        try expectInt(spacing.get("strictest").?, query.requiredSpacing(cd, l, .{ .width_a = far, .width_b = far, .run_length = far, .end_of_line = 0 }));
        try expectInt(e.get("cut_spacing_nm").?, query.cutSpacing(cd, l, false));
        try expectInt(e.get("cut_spacing_center_nm").?, query.cutSpacing(cd, l, true));
        try expectInt(e.get("max_via_stack").?, query.maxViaStack(cd, l));
        for (e.get("via_array_spacing").?.array.items) |v| {
            const cuts: u32 = @intCast(v.object.get("cuts").?.integer);
            try expectInt(v.object.get("spacing_nm").?, query.viaArraySpacing(cd, l, cuts));
        }
        if (query.cutClassSpacing(cd, l)) |t| {
            const got = e.get("cut_class_spacing").?.object;
            try expectInts(got.get("short_nm").?, @as(?[]const i64, t.short));
            try expectInts(got.get("long_nm").?, @as(?[]const i64, t.long));
            try expectInts(got.get("space_nm").?, @as(?[]const i64, t.space));
        } else try testing.expect(e.get("cut_class_spacing").? == .null);
        try listAnswers(arena, cd, strings, l, e);
    }
}

fn listAnswers(arena: Allocator, cd: *const CompiledDeck, strings: *const geom.StrTable, l: LayerId, e: std.json.ObjectMap) !void {
    var density: std.ArrayList(query.DensityLimit) = .empty;
    try query.densityInto(arena, cd, l, &density);
    const got_density = e.get("density").?.array.items;
    try testing.expectEqual(density.items.len, got_density.len);
    for (density.items, got_density) |want, got| {
        const g = got.object;
        try testing.expectEqualStrings(strings.resolve(want.rule), g.get("rule").?.string);
        try expectInts(g.get("window_nm").?, if (want.window) |win| @as(?[]const i64, &win) else null);
        try expectFloat(g.get("limit").?, want.limit);
        try testing.expectEqualStrings(@tagName(want.sense), g.get("sense").?.string);
    }
    var antenna: std.ArrayList(query.AntennaLimit) = .empty;
    try query.antennaInto(arena, cd, l, &antenna);
    const got_antenna = e.get("antenna").?.array.items;
    try testing.expectEqual(antenna.items.len, got_antenna.len);
    for (antenna.items, got_antenna) |want, got| {
        const g = got.object;
        try testing.expectEqualStrings(strings.resolve(want.rule), g.get("rule").?.string);
        try expectInt(g.get("gate").?, @as(?u16, @backingInt(want.gate)));
        try expectFloat(g.get("max_ratio").?, want.max_ratio);
        try expectInt(g.get("sidewall_nm").?, switch (want.measure) {
            .area => @as(?geom.Dbu, null),
            .sidewall => |h| h,
        });
        try expectInt(g.get("diode").?, if (want.diode) |d| @as(?u16, @backingInt(d)) else null);
    }
    var em: std.ArrayList(query.EmLimit) = .empty;
    try query.emLimitInto(arena, cd, l, &em);
    const got_em = e.get("em").?.array.items;
    try testing.expectEqual(em.items.len, got_em.len);
    for (em.items, got_em) |want, got| {
        const g = got.object;
        try testing.expectEqualStrings(strings.resolve(want.rule), g.get("rule").?.string);
        try expectFloat(g.get("max_density_a_per_m").?, want.max_density.raw);
        try expectFloat(g.get("max_current_per_cut_ua").?, want.max_current_per_cut.raw);
    }
}

/// Every enclosure-kind rule's (inner, outer) has an `enclosures` entry and
/// every entry is some rule's; each pair's values are the query's.
fn pairAnswers(cd: *const CompiledDeck, rules: []const Value, answers: std.json.ObjectMap) !void {
    const enclosures = answers.get("enclosures").?.array.items;
    const enclosure_kinds = [_][]const u8{ "min_enclosure", "asymmetric_enclosure", "adjacent_enclosure", "noncoincident_enclosure", "max_enclosure", "full_width" };
    var named: usize = 0;
    for (rules) |rule| {
        const kind = rule.object.get("kind").?.string;
        const is_enclosure = for (enclosure_kinds) |k| (if (std.mem.eql(u8, k, kind)) break true) else false;
        if (!is_enclosure) continue;
        named += 1;
        const layers = rule.object.get("layers").?.array.items;
        const found = for (enclosures) |p| {
            if (p.object.get("outer").?.integer == layers[0].integer and p.object.get("inner").?.integer == layers[1].integer) break true;
        } else false;
        try testing.expect(found);
    }
    try testing.expect(enclosures.len <= named);
    for (enclosures) |p| {
        const o = p.object;
        const e = query.enclosure(cd, layerOf(o.get("inner").?), layerOf(o.get("outer").?));
        try expectInt(o.get("all_sides_nm").?, e.all_sides);
        try expectInt(o.get("opposite_nm").?, e.opposite);
        try expectInt(o.get("noncoincident_nm").?, e.noncoincident);
        try expectInt(o.get("at_most_nm").?, e.at_most);
        try testing.expectEqual(e.full_width, o.get("full_width").?.bool);
    }
    for (answers.get("projection_spacing").?.array.items) |p| {
        const o = p.object;
        try expectInt(o.get("spacing_nm").?, query.projectionSpacing(cd, layerOf(o.get("a").?), layerOf(o.get("b").?)));
    }
    for (answers.get("contains").?.array.items) |p| {
        const o = p.object;
        const bounds = query.contains(cd, layerOf(o.get("outer").?), layerOf(o.get("inner").?)).?;
        try expectInt(o.get("min").?, @as(?u32, bounds[0]));
        try expectInt(o.get("max").?, if (bounds[1] == std.math.maxInt(u32)) null else @as(?u32, bounds[1]));
    }
    for (answers.get("minimum_cuts").?.array.items) |p| {
        const o = p.object;
        const width: geom.Dbu = o.get("wire_width_nm").?.integer;
        try expectInt(o.get("cuts").?, query.minimumCuts(cd, layerOf(o.get("cut").?), layerOf(o.get("wide").?), width));
    }
}

/// Every device row's model has a `models` entry, whose values are the query's.
fn modelAnswers(cd: *const CompiledDeck, strings: *const geom.StrTable, devices: []const Value, models: []const Value) !void {
    for (devices) |d| {
        const model = d.object.get("model").?.string;
        const found = for (models) |m| (if (std.mem.eql(u8, m.object.get("model").?.string, model)) break true) else false;
        try testing.expect(found);
    }
    for (models) |m| {
        const o = m.object;
        const id = strings.get(o.get("model").?.string).?;
        const fet = query.fetLimits(cd, id);
        try expectFloat(o.get("gate_oxide_mv").?, if (fet.gate_oxide) |v| v.raw else null);
        try expectFloat(o.get("drain_source_mv").?, if (fet.drain_source) |v| v.raw else null);
        if (query.matching(cd, id)) |want| {
            const got = o.get("matching").?.object;
            try expectFloat(got.get("avt_v_m").?, want.avt);
            try expectFloat(got.get("abeta_m").?, want.abeta);
            try expectFloat(got.get("ar_m").?, want.ar);
            try expectFloat(got.get("svt_v_per_m").?, want.svt);
            try expectFloat(got.get("ka_m").?, want.ka);
        } else try testing.expect(o.get("matching").? == .null);
    }
}

fn layerOf(v: Value) LayerId {
    return @fromBackingInt(@as(u16, @intCast(v.integer)));
}

fn expectInt(got: Value, want: anytype) !void {
    if (want) |x| {
        try testing.expect(got == .integer);
        try testing.expectEqual(@as(i128, x), @as(i128, got.integer));
    } else try testing.expect(got == .null);
}

fn expectFloat(got: Value, want: ?f64) !void {
    const x = want orelse return testing.expect(got == .null);
    const g: f64 = switch (got) {
        .float => |f| f,
        .integer => |n| @floatFromInt(n),
        else => return error.TestUnexpectedResult,
    };
    try testing.expectEqual(x, g);
}

fn expectInts(got: Value, want: ?[]const i64) !void {
    const w = want orelse return testing.expect(got == .null);
    try testing.expect(got == .array);
    try testing.expectEqual(w.len, got.array.items.len);
    for (w, got.array.items) |a, b| try testing.expectEqual(a, b.integer);
}

test "every answer in each shipped deck's dump is its query's return value" {
    // Oracle: the query layer (check/deck/query.zig), called again per value
    // and compared with the dump's value after a JSON round trip; the pairs
    // the dump answers for are checked against the dump's own rule rows,
    // and the two spacing queries are rebuilt from their documentation.
    for (gpurify.pdks.all) |pdk| {
        var arena_state: std.heap.ArenaAllocator = .init(testing.allocator);
        defer arena_state.deinit();
        const arena = arena_state.allocator();
        var strings: geom.StrTable = .empty;
        var diag: check.deck.compile.Diag = .{};
        const cd = try check.deck.compile.compile(arena, arena, pdk.text, .{ .dbu_per_um = 1000 }, &strings, &diag);
        var out: std.Io.Writer.Allocating = .init(arena);
        try gpurify.@"export".deck.writeDeck(&out.writer, arena, &cd, &strings, pdk.name);
        const root = try std.json.parseFromSliceLeaky(Value, arena, out.written(), .{});
        const answers = root.object.get("answers").?.object;
        try layerAnswers(arena, &cd, &strings, answers.get("layers").?.array.items);
        try pairAnswers(&cd, root.object.get("rules").?.array.items, answers);
        try modelAnswers(&cd, &strings, root.object.get("devices").?.array.items, answers.get("models").?.array.items);
    }
}

test "a dump is the same bytes every time" {
    // Oracle: determinism (ARCHITECTURE.md, Data): two compiles of one deck
    // into fresh tables dump identically.
    var arena_state: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var dumps: [2][]const u8 = undefined;
    for (&dumps) |*d| {
        var strings: geom.StrTable = .empty;
        var diag: check.deck.compile.Diag = .{};
        const cd = try check.deck.compile.compile(arena, arena, gpurify.pdks.sky130, .{ .dbu_per_um = 1000 }, &strings, &diag);
        var out: std.Io.Writer.Allocating = .init(arena);
        try gpurify.@"export".deck.writeDeck(&out.writer, arena, &cd, &strings, "sky130");
        d.* = out.written();
    }
    try testing.expectEqualStrings(dumps[0], dumps[1]);
}
