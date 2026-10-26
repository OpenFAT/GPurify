//! Liberty's circuit reads the diffusions LVS compares: a drawn nmos whose
//! source diffusion has a hole, through the engine's load and extract, into
//! the lumped circuit's `as`, `ps`, `ad`, `pd`. Ported from
//! tests/exhaustive/lvs.rs (`liberty_reads_the_diffusions_lvs_compares`,
//! with `full_deck`, `draw_mos` and `stub` for its one device).
//!
//! Contents: tests only.

const std = @import("std");
const Allocator = std.mem.Allocator;
const testing = std.testing;
const geom = @import("geom");
const ingest = @import("ingest");
const check = @import("check");
const testgen = @import("testgen");
const gpurify = @import("gpurify");
const liberty = gpurify.liberty;

/// tests/exhaustive/lvs.rs `full_deck()`: `MOS_DECK` then `EXTRA_DECK`.
const full_deck =
    \\grid 1nm
    \\layer diff = gds(1, 0)
    \\layer poly = gds(2, 0)
    \\layer nsdm = gds(3, 0)
    \\layer psdm = gds(4, 0)
    \\layer hvt = gds(5, 0)
    \\layer cont = gds(8, 0)
    \\layer met1 = gds(10, 0)
    \\layer via1 = gds(11, 0)
    \\layer met2 = gds(12, 0)
    \\layer met2_label = gds(12, 5)
    \\layer diff_active = diff not poly
    \\layer gate = poly and diff
    \\layer gate_n = gate and nsdm
    \\layer gate_nl = gate_n not hvt
    \\layer gate_p = gate and psdm
    \\connect conductors [diff_active, poly, met1, met2]
    \\connect touch_within_layer
    \\connect via cont [diff_active, met1]
    \\connect via cont [poly, met1]
    \\connect via via1 [met1, met2]
    \\connect label met2_label names met2
    \\device mos gate_nl model "nmos" terminals [poly, diff_active, diff_active]
    \\device mos gate_p model "pmos" terminals [poly, diff_active, diff_active]
    \\lvs tolerance default relative 2%
    \\layer bsdm = gds(6, 0)
    \\layer pwell = gds(7, 0)
    \\layer tap = gds(9, 0)
    \\layer pina = gds(13, 0)
    \\layer pinb = gds(14, 0)
    \\layer pinc = gds(15, 0)
    \\layer resm = gds(16, 0)
    \\layer capm = gds(17, 0)
    \\layer diom = gds(18, 0)
    \\layer bjtm = gds(19, 0)
    \\layer indm = gds(30, 0)
    \\layer gate_nh = gate_n and hvt
    \\layer gate_b = gate and bsdm
    \\connect conductors [pwell, pina, pinb, pinc]
    \\connect via cont [pina, met1]
    \\connect via cont [pinb, met1]
    \\connect via cont [pinc, met1]
    \\connect via tap [pwell, met1]
    \\device mos gate_nh model "nmos_hvt" terminals [poly, diff_active, diff_active]
    \\device mos gate_b model "nmosb" terminals [poly, diff_active, diff_active, pwell]
    \\device resistor resm model "rpoly" terminals [pina, pina] sheet 100ohm
    \\device capacitor capm model "cmim" terminals [pina, pinb] area_cap 1fF/um2 fringe_cap 100aF/um
    \\device diode diom model "dpn" terminals [pina, pinb]
    \\device bjt bjtm model "npn" terminals [pina, pinb, pinc]
    \\device inductor indm model "spiral" terminals [pina, pina] inductance 2nH
    \\
;

// ---- private ----

fn fullDeck(gpa: Allocator, arena: Allocator, grid: geom.Grid, strings: *geom.StrTable, diag: *check.deck.compile.Diag) check.deck.compile.Error!check.deck.compile.CompiledDeck {
    return check.deck.compile.compile(gpa, arena, full_deck, grid, strings, diag);
}

/// The layout of `nmos n0 n1 n2` (gate, source, drain), 1000 by 150 nm, its
/// source diffusion redrawn round a 200 nm square hole at (150, 400), each
/// net a met2 track labelled with its name.
fn drawInto(gpa: Allocator, layers: *const ingest.deck.LayerTable, strings: *const geom.StrTable, out: *std.ArrayList(u8)) !void {
    var lb: testgen.shapes.LayoutBuilder = .init(@intCast(layers.len()));
    defer lb.deinit(gpa);
    const id = struct {
        fn of(l: *const ingest.deck.LayerTable, s: *const geom.StrTable, name: []const u8) u16 {
            return @backingInt(l.id(s, name).?);
        }
    }.of;
    // draw_mos at x0 = 0, w = 1000, l = 150, source/drain 500 long.
    const w = 1000;
    const xd = 500 + 150;
    for ([_][4]i64{ .{ 0, 0, 1150, 400 }, .{ 0, 600, 1150, 1000 }, .{ 0, 400, 150, 600 }, .{ 350, 400, 1150, 600 } }) |r|
        _ = try lb.rect(gpa, id(layers, strings, "diff"), r[0], r[1], r[2], r[3]);
    _ = try lb.rect(gpa, id(layers, strings, "poly"), 500, -200, xd, w + 500);
    _ = try lb.rect(gpa, id(layers, strings, "nsdm"), -200, -300, xd + 500 + 200, w + 200);
    _ = try lb.rect(gpa, id(layers, strings, "cont"), 100, 100, 400, 400);
    _ = try lb.rect(gpa, id(layers, strings, "cont"), xd + 100, 100, xd + 400, 400);
    _ = try lb.rect(gpa, id(layers, strings, "cont"), 500, w + 250, xd, w + 400);
    // Stubs up to each net's track: source, drain, gate.
    for ([_][4]i64{ .{ 100, 400, 100, 1 }, .{ xd + 100, xd + 400, 100, 2 }, .{ 500, xd, w + 250, 0 } }) |s| {
        const t = 4000 + 400 * s[3];
        _ = try lb.rect(gpa, id(layers, strings, "met1"), s[0], s[2], s[1], t + 200);
        _ = try lb.rect(gpa, id(layers, strings, "via1"), s[0], t, s[1], t + 200);
    }
    var labels: [3]testgen.gds.Label = undefined;
    for (&labels, [_][]const u8{ "n0", "n1", "n2" }, 0..) |*label, name, k| {
        const t: i64 = 4000 + 400 * @as(i64, @intCast(k));
        _ = try lb.rect(gpa, id(layers, strings, "met2"), -1000, t, 3000, t + 200);
        label.* = .{ .layer = @fromBackingInt(id(layers, strings, "met2_label")), .x = -900, .y = t + 100, .text = name };
    }
    var store: geom.GeometryStore = .empty;
    defer store.deinit(gpa);
    var handles: testgen.shapes.Ids = .{};
    defer handles.deinit(gpa);
    try lb.finish(gpa, &store, &handles);
    try testgen.gds.writeStoreLabelled(gpa, &store, layers, &labels, "TOP", out);
}

test "liberty reads the diffusions lvs compares" {
    // Oracle: hand-derived from the drawing, testing-plan F100. Liberty's
    // circuit gives a MOS the diffusions LVS compares, topology's, not a
    // measure of its own. The nmos, 1000 by 150 nm, its diffusion redrawn
    // round a 200 nm square hole at (150, 400) in its source: the source,
    // 500 by 1000 nm, has `as` = 500 · 1000 − 200 · 200 = 460 000 nm² and
    // `ps` = 2 (500 + 1000) + 4 · 200 = 3800 nm, the hole's edge an edge of
    // the diffusion; the drain, whole, `ad` = 500 000 nm² and `pd` = 3000
    // nm. Liberty used to measure the outer ring alone, 500 000 nm² and
    // 3000 nm at the source.
    const gpa = testing.allocator;
    var arena: std.heap.ArenaAllocator = .init(gpa);
    defer arena.deinit();
    const a = arena.allocator();
    var strings: geom.StrTable = .empty;
    defer strings.deinit(gpa);
    var deck_diag: ingest.deck.Diag = .{};
    const dk = try ingest.deck.parseDeck(a, gpa, full_deck, try geom.Grid.init(1000), &strings, &deck_diag);
    var bytes: std.ArrayList(u8) = .empty;
    defer bytes.deinit(gpa);
    try drawInto(gpa, &dk.layers, &strings, &bytes);

    var load_diag: gpurify.LoadDiagnostic = .{};
    const decks = [_]gpurify.NamedDeck{.{ .name = "full", .build = fullDeck }};
    const loaded = try gpurify.loadBytes(gpa, a, testing.io, std.Io.Dir.cwd(), .{ .layout = "liberty_diffusions.gds", .deck = "full" }, bytes.items, &decks, &load_diag);
    var ediag: gpurify.ExtractDiagnostic = .none;
    const extracted = try gpurify.extract(a, &loaded, &ediag);
    var diag: liberty.Diagnostic = .{};
    const macro = try liberty.spec.parse(a,
        \\{"cell": "TOP", "pins": [
        \\    {"name": "n0", "role": "input", "power": "n1", "ground": "n2"},
        \\    {"name": "n1", "role": "power"}, {"name": "n2", "role": "ground"}],
        \\ "corners": [{"name": "tt", "temperature": 25,
        \\              "supplies": {"n1": 1.8, "n2": 0}, "models": []}]}
    , &diag);
    const built = try liberty.circuit.build(a, &loaded, &extracted, &macro, .lumped, &diag);
    try testing.expectEqual(1, built.deviceCount());
    const params = built.paramsOf(0);
    for ([_]struct { []const u8, liberty.circuit.Param }{
        .{ "as", .{ .area = 4.6e-13 } },
        .{ "ps", .{ .length = 3.8e-6 } },
        .{ "ad", .{ .area = 5e-13 } },
        .{ "pd", .{ .length = 3e-6 } },
    }) |want| {
        const i = for (params.names, 0..) |n, i| (if (std.mem.eql(u8, n, want[0])) break i) else return error.TestMissingParam;
        const got = params.values[i];
        const close = switch (want[1]) {
            .area => |b| got == .area and @abs(got.area - b) <= 1e-9 * b,
            .length => |b| got == .length and @abs(got.length - b) <= 1e-9 * b,
            .count => false,
        };
        if (!close) {
            std.debug.print("{s}: {any}, want {any}\n", .{ want[0], got, want[1] });
            return error.TestWrongDiffusion;
        }
    }
}
