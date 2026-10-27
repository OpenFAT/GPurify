//! `erc.fromDeck`: each deck row filed under the kind it names, a duplicate
//! id refused, another domain's row stepped over, and the parameterised
//! kinds read into their columns. Oracle throughout: construct-from-answer,
//! the deck written by hand. Ported from crates/check/tests/erc/dispatch.rs
//! (its `RuleSet::from_deck` half; the `RuleSet::run` half is dispatch.zig).

const std = @import("std");
const testing = std.testing;
const geom = @import("geom");
const ingest = @import("ingest");
const check = @import("check");
const StrId = geom.StrId;
const StrTable = geom.StrTable;
const LayerId = geom.LayerId;
const erc = check.erc;
const RuleSet = erc.RuleSet;
const Diagnostic = check.drc.params.Diagnostic;
const common = @import("common.zig");
const gpa = common.gpa;

/// A deck and its interned names, for one test.
const Built = struct {
    strings: StrTable = .empty,
    arena: std.heap.ArenaAllocator = .init(gpa),
    deck: ingest.deck.Deck = .{},
    ids: []StrId = &.{},

    fn deinit(b: *Built) void {
        b.arena.deinit();
        b.strings.deinit(gpa);
    }
};

/// Five `electromigration` rows spanning 2 and 4 layers.
const em_deck =
    \\grid 5nm
    \\layer li = gds(1, 0)
    \\layer licon = gds(2, 0)
    \\layer met1 = gds(3, 0)
    \\layer mcon = gds(4, 0)
    \\layer met2 = gds(5, 0)
    \\layer via1 = gds(6, 0)
    \\layer met3 = gds(7, 0)
    \\layer via2 = gds(8, 0)
    \\layer met4 = gds(9, 0)
    \\layer via3 = gds(10, 0)
    \\layer met5 = gds(11, 0)
    \\layer via4 = gds(12, 0)
    \\rule em_li electromigration(li, licon; max_density: 280A/m, max_current_per_cut: 80uA, blech_limit: 15000uA, reference_temperature: 378K, activation_energy: 0.9eV, current_exponent: 2)
    \\rule em_met1 electromigration(met1, mcon; max_density: 1000A/m, max_current_per_cut: 80uA, blech_limit: 54000uA, reference_temperature: 378K, activation_energy: 0.9eV, current_exponent: 2)
    \\rule em_met2 electromigration(met2, via1; max_density: 1000A/m, max_current_per_cut: 60uA, blech_limit: 54000uA, reference_temperature: 378K, activation_energy: 0.9eV, current_exponent: 2)
    \\rule em_met3_met4 electromigration(met3, via2, met4, via3; max_density: 2350A/m, max_current_per_cut: 110uA, blech_limit: 126750uA, reference_temperature: 378K, activation_energy: 0.9eV, current_exponent: 2)
    \\rule em_met5 electromigration(met5, via4; max_density: 3500A/m, max_current_per_cut: 1800uA, blech_limit: 189000uA, reference_temperature: 378K, activation_energy: 0.9eV, current_exponent: 2)
    \\
;

/// met1 1.2 µm above the substrate and one `em_thermal` row on it and its
/// cut; `{limit}` and `{spreading}` are filled per case.
const thermal_deck =
    \\grid 5nm
    \\layer met1 = gds(1, 0)
    \\layer via1 = gds(2, 0)
    \\layer met2 = gds(3, 0)
    \\connect conductors [met1, met2]
    \\connect via via1 [met1, met2]
    \\pex met1 thickness 350nm height 1200nm sheet 0.1ohm dielectric 3.9 area_cap 1aF/um2 fringe_cap 1aF/um
    \\rule em.hot warning em_thermal(met1, via1; max_density: 1mA/um, max_current_per_cut: 0.2mA, blech_limit: 2000uA, reference_temperature: 110C, activation_energy: 0.9eV, current_exponent: 2, thermal_conductivity: 1.4W/mK, spreading: {spreading}, sigma: 0.4, limit_failure: {limit}, max_failure: 0.01%)
    \\
;

const voltage_head =
    \\grid 5nm
    \\layer met1 = gds(1, 0)
    \\layer met2 = gds(2, 0)
    \\connect conductors [met1, met2]
    \\
;

// ---- private ----

/// A deck of parameterless, layerless rows `(id, kind)`.
fn deckOf(rows: []const [2][]const u8) !Built {
    var b: Built = .{};
    errdefer b.deinit();
    const a = b.arena.allocator();
    const spec = try a.alloc(ingest.deck.RuleSpec, rows.len);
    b.ids = try a.alloc(StrId, rows.len);
    for (rows, spec, b.ids) |row, *s, *id| {
        id.* = try b.strings.intern(gpa, row[0]);
        s.* = .{ .id = id.*, .kind = try b.strings.intern(gpa, row[1]), .layer_start = 0, .layer_len = 0, .param_start = 0, .param_len = 0 };
    }
    b.deck.rules = .{ .spec = spec };
    return b;
}

/// A deck parsed from text on the 1 nm grid.
fn parse(text: []const u8) !Built {
    var b: Built = .{};
    errdefer b.deinit();
    var diag: ingest.deck.Diag = .{};
    b.deck = try ingest.deck.parseDeck(b.arena.allocator(), gpa, text, common.manufacturingGrid(), &b.strings, &diag);
    return b;
}

test "fromDeck files each row under the kind the deck named" {
    // Oracle: construct-from-answer. Two rows of two parameterless kinds
    // land in those two tables and nowhere else, with the deck's ids.
    var b = try deckOf(&.{ .{ "gate.floating", "floating_gate" }, .{ "net.tied", "tie_high_low" } });
    defer b.deinit();
    var diag: Diagnostic = .{};
    var rs = try erc.fromDeck(gpa, &b.deck, &b.strings, &diag);
    defer rs.deinit(gpa);
    try testing.expectEqual(@as(u32, 2), rs.len());
    try testing.expect(!rs.isEmpty());
    try testing.expectEqualSlices(StrId, b.ids[0..1], rs.tables.floating_gate.head.rule.items);
    try testing.expectEqualSlices(StrId, b.ids[1..2], rs.tables.tie_high_low.head.rule.items);
    try testing.expectEqual(@as(u32, 0), rs.tables.ir_drop.head.len());
    try testing.expectEqual(@as(u32, 0), rs.tables.multiple_drivers.head.len());
}

test "a deck naming a kind erc does not implement files no row" {
    // Oracle: construct-from-answer. `min_width` is DRC's row; one deck
    // feeds every domain, so ERC steps over it and files only its own.
    var b = try deckOf(&.{ .{ "met1.width", "min_width" }, .{ "gate.floating", "floating_gate" } });
    defer b.deinit();
    var diag: Diagnostic = .{};
    var rs = try erc.fromDeck(gpa, &b.deck, &b.strings, &diag);
    defer rs.deinit(gpa);
    try testing.expectEqual(@as(u32, 1), rs.len());
    try testing.expectEqual(@as(u32, 1), rs.tables.floating_gate.head.len());
}

test "a deck defining one rule id twice is refused" {
    // Oracle: construct-from-answer, fail closed. Two rows sharing an id
    // make run rows attributable to nothing: refused at load, by name.
    var b = try deckOf(&.{ .{ "gate.floating", "floating_gate" }, .{ "gate.floating", "tie_high_low" } });
    defer b.deinit();
    var diag: Diagnostic = .{};
    try testing.expectError(error.DuplicateRule, erc.fromDeck(gpa, &b.deck, &b.strings, &diag));
    try testing.expectEqualStrings("gate.floating", b.strings.resolve(diag.rule));
}

test "every kind the list names is a kind fromDeck recognises" {
    // Oracle: construct-from-answer. A name the list spells is a name
    // fromDeck files a row for: a bare row either files one row or is
    // refused for a missing parameter or layer, never stepped over.
    for (erc.kinds.names) |kind| {
        var b = try deckOf(&.{.{ "the.rule", kind }});
        defer b.deinit();
        var diag: Diagnostic = .{};
        var rs = erc.fromDeck(gpa, &b.deck, &b.strings, &diag) catch continue;
        defer rs.deinit(gpa);
        try testing.expectEqual(@as(u32, 1), rs.len());
    }
}

test "a voltage table lowers by step and an unordered one is refused" {
    // Oracle: construct-from-answer, on the deck grammar
    // (docs/src/reference/erc/voltage.md, ERC-F11, `voltage_space`): a table
    // lowers to its steps in mV and grid units, on one layer or two; voltages
    // that fall, repeat or go negative, spaces that fall, or lists of two
    // lengths are refused by name.
    const ok = voltage_head ++
        \\rule vs voltage_space(met1; voltage: [0V, 3.3V], space: [200nm, 450nm])
        \\rule vs2 voltage_space(met1, met2; voltage: [1.5V], space: [1um])
        \\
    ;
    var b = try parse(ok);
    defer b.deinit();
    var diag: Diagnostic = .{};
    var rs = try erc.fromDeck(gpa, &b.deck, &b.strings, &diag);
    defer rs.deinit(gpa);
    const t = &rs.tables.voltage_spacing;
    try testing.expectEqual(@as(u32, 2), t.head.len());
    try testing.expectEqualSlices(u32, &.{ 0, 2, 3 }, t.step_start.items);
    for (t.voltage.items, [_]f64{ 0.0, 3_300.0, 1_500.0 }) |v, want| try testing.expectEqual(want, v.raw);
    try testing.expectEqualSlices(geom.Dbu, &.{ 200, 450, 1_000 }, t.space.items);
    try testing.expectEqualSlices(LayerId, &.{ @fromBackingInt(0), @fromBackingInt(0) }, t.layer.items);
    try testing.expectEqual(@as(?LayerId, null), t.other.items[0]);
    try testing.expectEqual(@as(?LayerId, @fromBackingInt(1)), t.other.items[1]);
    const bad = [_][2][]const u8{
        .{ "rule vs voltage_space(met1; voltage: [3.3V, 1V], space: [200nm, 450nm])\n", "rise strictly" },
        .{ "rule vs voltage_space(met1; voltage: [1V, 1V], space: [200nm, 450nm])\n", "rise strictly" },
        .{ "rule vs voltage_space(met1; voltage: [-1V], space: [200nm])\n", "rise strictly" },
        .{ "rule vs voltage_space(met1; voltage: [0V, 1V], space: [450nm, 200nm])\n", "never fall" },
        .{ "rule vs voltage_space(met1; voltage: [0V, 1V], space: [200nm])\n", "one space per voltage" },
    };
    for (bad) |case| {
        const text = try std.mem.concat(gpa, u8, &.{ voltage_head, case[0] });
        defer gpa.free(text);
        var bb = try parse(text);
        defer bb.deinit();
        var d: Diagnostic = .{};
        try testing.expectError(error.BadTable, erc.fromDeck(gpa, &bb.deck, &bb.strings, &d));
        try testing.expectEqualStrings("vs", bb.strings.resolve(d.rule));
        try testing.expect(std.mem.indexOf(u8, d.why, case[1]) != null);
    }
}

test "a multi-layer electromigration row gives every layer its blech limit" {
    // Oracle: construct-from-answer. Rows spanning 2 and 4 layers; every
    // layer carries its own row's Blech limit.
    var b = try parse(em_deck);
    defer b.deinit();
    var diag: Diagnostic = .{};
    var rs = try erc.fromDeck(gpa, &b.deck, &b.strings, &diag);
    defer rs.deinit(gpa);
    const em = &rs.tables.electromigration;
    try testing.expectEqual(em.layer.items.len, em.blech_limit.items.len);
    const expected = [_]f64{ 15_000.0, 54_000.0, 54_000.0, 126_750.0, 189_000.0 };
    try testing.expectEqual(@as(u32, expected.len), em.head.len());
    for (expected, 0..) |want, row| {
        const span = em.blech_limit.items[em.layer_start.items[row]..em.layer_start.items[row + 1]];
        try testing.expect(span.len >= 2);
        for (span) |blech| try testing.expectEqual(@as(u64, @bitCast(want)), @as(u64, @bitCast(blech.raw)));
    }
}

test "an em_thermal row reads into its columns" {
    // Oracle: construct-from-answer, against `em_thermal` in
    // docs/src/reference/erc/electromigration.md (ERC-E13): every value lands
    // in its column in the engine's unit (A/m, µA, K, W/(m·K), fractions), the
    // rule set carries the deck's `pex` heights, and a characterisation at
    // 100 % failed or a negative spreading is refused.
    const Case = struct {
        fn text(limit: []const u8, spreading: []const u8) ![]u8 {
            const a = try std.mem.replaceOwned(u8, gpa, thermal_deck, "{limit}", limit);
            defer gpa.free(a);
            return std.mem.replaceOwned(u8, gpa, a, "{spreading}", spreading);
        }
    };
    const good = try Case.text("0.1%", "0.88");
    defer gpa.free(good);
    var b = try parse(good);
    defer b.deinit();
    var diag: Diagnostic = .{};
    var rs = try erc.fromDeck(gpa, &b.deck, &b.strings, &diag);
    defer rs.deinit(gpa);
    const t = &rs.tables.em_thermal;
    try testing.expectEqual(@as(u32, 1), t.head.len());
    try testing.expectEqual(check.report.Severity.warning, t.head.severity.items[0]);
    try testing.expectEqual(@as(usize, 2), t.layer.items.len);
    try testing.expectEqualSlices(u32, &.{ 0, 2 }, t.layer_start.items);
    for (t.max_density.items) |d| try testing.expectEqual(@as(f64, 1000.0), d.raw);
    for (t.max_current_per_cut.items) |c| try testing.expectEqual(@as(f64, 200.0), c.raw);
    for (t.blech_limit.items) |c| try testing.expectEqual(@as(f64, 2000.0), c.raw);
    try testing.expectEqual(@as(f64, 110.0 + 273.15), t.reference_temperature.items[0].raw);
    try testing.expectEqualSlices(f64, &.{0.9}, t.activation_energy_ev.items);
    try testing.expectEqualSlices(f64, &.{2.0}, t.current_exponent.items);
    try testing.expectEqualSlices(f64, &.{1.4}, t.thermal_conductivity.items);
    try testing.expectEqualSlices(f64, &.{0.88}, t.heat_spreading.items);
    try testing.expectEqualSlices(f64, &.{0.4}, t.sigma.items);
    try testing.expectEqualSlices(f64, &.{0.001}, t.limit_failure.items);
    try testing.expectEqualSlices(f64, &.{0.0001}, t.max_failure.items);
    try testing.expect(std.mem.indexOfScalar(f64, rs.height_nm, 1200.0) != null);
    for ([_][2][]const u8{ .{ "100%", "0.88" }, .{ "0.1%", "-1" } }, [_]anyerror{ error.NotAFraction, error.NonPositiveLimit }) |case, want| {
        const text = try Case.text(case[0], case[1]);
        defer gpa.free(text);
        var bb = try parse(text);
        defer bb.deinit();
        var d: Diagnostic = .{};
        try testing.expectError(want, erc.fromDeck(gpa, &bb.deck, &bb.strings, &d));
        if (want == error.NotAFraction) try testing.expectEqualStrings("limit_failure", d.param);
    }
}
