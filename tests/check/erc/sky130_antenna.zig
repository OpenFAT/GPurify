//! The antenna rows the shipped PDK decks state, read back from the parsed
//! deck against the foundry tables they transcribe: sky130's Table Ig,
//! IHP SG13G2 §7.1 and GF180MCU tables 27 and 28. Ported from the root
//! tests/sky130_rules.rs (`the_sky130_antenna_rows_are_table_ig`,
//! `the_ihp_antenna_rows_switch_on_a_protection_diode`,
//! `the_gf180_antenna_rows_credit_comp_by_oxide`; deferred there from
//! tests/check/drc/sky130_rules.zig).

const std = @import("std");
const testing = std.testing;
const geom = @import("geom");
const ingest = @import("ingest");
const paths = @import("paths");
const RuleSpec = ingest.deck.RuleSpec;
const ParamValue = ingest.deck.ParamValue;
const LayerId = geom.LayerId;

/// A parsed shipped deck, its strings and arena.
const Loaded = struct {
    arena: std.heap.ArenaAllocator,
    strings: geom.StrTable = .empty,
    deck: ingest.deck.Deck = undefined,

    /// Parses `pdks/<name>.deck` on a 1 nm grid.
    fn init(l: *Loaded, name: []const u8) !void {
        l.* = .{ .arena = .init(testing.allocator) };
        const a = l.arena.allocator();
        const path = try std.fmt.allocPrint(a, "{s}/pdks/{s}.deck", .{ paths.root, name });
        const text = try std.Io.Dir.cwd().readFileAlloc(testing.io, path, a, .unlimited);
        var diag: ingest.deck.Diag = .{};
        l.deck = try ingest.deck.parseDeck(a, testing.allocator, text, try geom.Grid.init(1000), &l.strings, &diag);
    }

    fn deinit(l: *Loaded) void {
        l.strings.deinit(testing.allocator);
        l.arena.deinit();
    }

    /// The rule `id`; fails when the deck has none.
    fn rule(l: *const Loaded, id: []const u8) !RuleSpec {
        for (l.deck.rules.spec) |r| if (std.mem.eql(u8, l.strings.resolve(r.id), id)) return r;
        std.debug.print("the deck has no {s}\n", .{id});
        return error.NoSuchRule;
    }

    fn param(l: *const Loaded, r: RuleSpec, name: []const u8) ?ParamValue {
        const id = l.strings.get(name) orelse return null;
        return l.deck.rules.findParam(r, id);
    }

    fn ratio(l: *const Loaded, r: RuleSpec, name: []const u8) ?f64 {
        return switch (l.param(r, name) orelse return null) {
            .ratio => |v| v,
            else => null,
        };
    }

    fn layer(l: *const Loaded, r: RuleSpec, name: []const u8) ?LayerId {
        return switch (l.param(r, name) orelse return null) {
            .layer => |v| v,
            else => null,
        };
    }
};

test "the sky130 antenna rows are table ig" {
    // Oracle: SkyWater's Table Ig (S8PIR-10R), the antenna table for
    // sky130A's five-metal flow, row by row: MAX_EGAR without a diode, and
    // FLT, the film thickness the sidewall area is defined with (not Table
    // Ic's three-metal flow, nor Magic's drawn thicknesses). Then the diode
    // columns, K per µm² of AntennaDiode and the diode bonus: li 450, mcon
    // 18, the metals 400 with a 2200 bonus, the vias 36, and none for poly
    // and licon, whose rows only skip a net on a pAntennaShort (.ar.1).
    var l: Loaded = undefined;
    try l.init("sky130");
    defer l.deinit();
    const Row = struct { []const u8, f64, ?i64 };
    const table_ig = [_]Row{
        .{ "ar.poly.1", 50.0, 180 },   .{ "ar.licon.1", 3.0, null }, .{ "ar.li.1", 75.0, 100 },
        .{ "ar.mcon.1", 3.0, null },   .{ "ar.met1.1", 400.0, 350 }, .{ "ar.via.1", 6.0, null },
        .{ "ar.met2.1", 400.0, 350 },  .{ "ar.via2.1", 6.0, null },  .{ "ar.met3.1", 400.0, 800 },
        .{ "ar.via3.1", 6.0, null },   .{ "ar.met4.1", 400.0, 800 }, .{ "ar.via4.1", 6.0, null },
        .{ "ar.met5.1", 400.0, 1200 },
    };
    const short = l.deck.layers.id(&l.strings, "pantenna_short");
    for (table_ig) |row| {
        const r = try l.rule(row[0]);
        try testing.expectEqual(row[1], l.ratio(r, "max_ratio").?);
        const sidewall: ?i64 = if (l.param(r, "sidewall_thickness")) |v| switch (v) {
            .length => |len| len,
            else => null,
        } else null;
        try testing.expectEqual(row[2], sidewall);
        const id = row[0];
        const k: ?f64, const bonus: ?f64 = if (std.mem.eql(u8, id, "ar.poly.1") or std.mem.eql(u8, id, "ar.licon.1"))
            .{ null, null }
        else if (std.mem.eql(u8, id, "ar.li.1"))
            .{ 450.0, 0.0 }
        else if (std.mem.eql(u8, id, "ar.mcon.1"))
            .{ 18.0, 0.0 }
        else if (std.mem.startsWith(u8, id, "ar.met"))
            .{ 400.0, 2200.0 }
        else
            .{ 36.0, 0.0 };
        try testing.expectEqual(k, l.ratio(r, "diode_credit"));
        try testing.expectEqual(bonus, l.ratio(r, "diode_bonus"));
        const exempt = if (k != null) l.layer(r, "exempt_layer") else l.layer(r, "diode_layer");
        try testing.expectEqual(short, exempt);
    }
}

test "the ihp antenna rows switch on a protection diode" {
    // Oracle: IHP SG13G2 Layout Rules §7.1. Without a protection diode,
    // Ant.b (cumulative metal) 200 and Ant.d (cumulative via) 20; with one,
    // Ant.e 20000 and Ant.f 500. The no-diode rows leave a gate with a diode
    // to the protected rows, which credit the same diode layer, each row's
    // stage collecting Metal1 (or Via1) up to its own layer.
    var l: Loaded = undefined;
    try l.init("ihp_sg13g2");
    defer l.deinit();
    const diode = l.deck.layers.id(&l.strings, "ant_diode");
    try testing.expect(diode != null);
    const metals = [_][]const u8{ "Metal1", "Metal2", "Metal3", "Metal4", "Metal5", "TopMetal1", "TopMetal2" };
    const vias = [_][]const u8{ "Via1", "Via2", "Via3", "Via4", "TopVia1", "TopVia2" };
    var buf: [64]u8 = undefined;
    for ([_]struct { []const u8, []const u8, [2]f64, []const []const u8 }{
        .{ "Ant.b", "Ant.e", .{ 200.0, 20000.0 }, &metals },
        .{ "Ant.d", "Ant.f", .{ 20.0, 500.0 }, &vias },
    }) |c| for (c[3], 0..) |name, n| {
        for ([_]struct { []const u8, f64, []const u8 }{ .{ c[0], c[2][0], "antenna" }, .{ c[1], c[2][1], "antenna_electrical" } }) |row| {
            const id = try std.fmt.bufPrint(&buf, "{s}_{s}", .{ row[0], name });
            const r = try l.rule(id);
            try testing.expectEqualStrings(row[2], l.strings.resolve(r.kind));
            try testing.expectEqual(row[1], l.ratio(r, "max_ratio").?);
            try testing.expectEqual(diode, l.layer(r, "diode_layer"));
            try testing.expectEqual(n + 2, l.deck.rules.layersOf(r).len);
        }
    };
}

test "the gf180 antenna rows credit comp by oxide" {
    // Oracle: GF180MCU DRM tables 27 and 28. ANT.1-ANT.15 limit the ratio to
    // the "related gate oxide area", one row per oxide (thin `gate_thin`,
    // thick `gate_hv` suffixed `.DG`); ANT.16 adds MF times the COMP area on
    // the node to the gate area for a metal or via ratio, MF 2 thin and 15
    // thick, while the poly and contact rows take no credit.
    var l: Loaded = undefined;
    try l.init("gf180mcu");
    defer l.deinit();
    const thin = l.deck.layers.id(&l.strings, "gate_thin");
    const thick = l.deck.layers.id(&l.strings, "gate_hv");
    const rows = [_]struct { []const u8, f64, bool }{
        .{ "ANT.1", 200.0, false }, .{ "ANT.2", 400.0, true }, .{ "ANT.3", 400.0, true },
        .{ "ANT.4", 400.0, true },  .{ "ANT.5", 400.0, true }, .{ "ANT.6", 400.0, true },
        .{ "ANT.7", 400.0, true },  .{ "ANT.8", 10.0, false }, .{ "ANT.9", 20.0, true },
        .{ "ANT.10", 20.0, true },  .{ "ANT.11", 20.0, true }, .{ "ANT.12", 20.0, true },
        .{ "ANT.13", 20.0, true },
    };
    var buf: [32]u8 = undefined;
    for (rows) |c| {
        const dg = try std.fmt.bufPrint(&buf, "{s}.DG", .{c[0]});
        for ([_]struct { []const u8, ?LayerId, f64 }{ .{ c[0], thin, 2.0 }, .{ dg, thick, 15.0 } }) |row| {
            const r = try l.rule(row[0]);
            try testing.expectEqual(c[1], l.ratio(r, "max_ratio").?);
            try testing.expectEqual(row[1], l.deck.rules.layersOf(r)[0]);
            try testing.expectEqual(if (c[2]) row[2] else null, l.ratio(r, "gate_plus_diode"));
        }
    }
}
