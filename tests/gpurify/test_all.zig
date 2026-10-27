//! End to end: a deck and a layout file in, a verification report out.
//! The hand-written cases place one violation at a chosen coordinate,
//! write it to a real GDS file and follow it through every seam; the corpus
//! cases read tests/fixtures and check each against its geometry-derived
//! expectation. Ported from tests/test_all.rs (and the `Run` fixture of
//! tests/common/mod.rs).

const std = @import("std");
const testing = std.testing;
const Allocator = std.mem.Allocator;
const paths = @import("paths");
const geom = @import("geom");
const ingest = @import("ingest");
const testgen = @import("testgen");
const gpurify = @import("gpurify");
const corpus = @import("corpus.zig");
const gpa = testing.allocator;
const io = testing.io;
const report = @import("check").report;

const limit_nm = 300;

const narrow_nm = 200;

const wide_nm = 400;

const run_nm = 2000;

const centre_nm = [2]i64{ 5000, 5000 };

const min_width_deck = deckWithRule("1nm", "width(met1) >= 300nm");

const min_width_and_ir_drop_deck = min_width_deck ++ "rule supply_ir_drop ir_drop()\n" ++
    "pex met1 thickness 200nm height 100nm sheet 0.08ohm dielectric 3.9 area_cap 40aF/um2 fringe_cap 20aF/um\n";

const hv_domain_intent =
    \\{ "temperature_c": 85.0, "domains": { "core": { "voltage_mv": 1800.0 } },
    \\  "supplies": [{ "net": "ERC_HV_n0", "domain": "core", "role": "power" }] }
;

const hv_overstress_intent =
    \\{ "temperature_c": 85.0, "domains": { "core": { "voltage_mv": 3300.0 } },
    \\  "supplies": [{ "net": "ERC_HV_n0", "domain": "core", "role": "power" }] }
;

/// A deck and a one-rectangle layout written to a temporary directory.
const Fixture = struct {
    tmp: testing.TmpDir,
    arena_state: std.heap.ArenaAllocator,
    inputs: gpurify.Inputs = .{ .layout = "layout.gds", .deck = "rules.deck" },

    const Draw = struct { extreme: ?i64 = null };

    /// `width_nm` across, `run_nm` along, centred at `centre_nm`.
    fn init(deck: []const u8, width_nm: i64, draw: Draw) !Fixture {
        var f: Fixture = .{ .tmp = testing.tmpDir(.{}), .arena_state = .init(gpa) };
        errdefer f.deinit();
        const a = f.arena();
        try f.tmp.dir.writeFile(io, .{ .sub_path = "rules.deck", .data = deck });
        var strings: geom.StrTable = .empty;
        var diag: ingest.deck.Diag = .{};
        const parsed: ?ingest.deck.Deck = ingest.deck.parseDeck(a, a, deck, try .init(1000), &strings, &diag) catch null;
        var lb: testgen.shapes.LayoutBuilder = .init(1);
        if (parsed != null) {
            if (draw.extreme) |e| {
                _ = try lb.rect(a, 0, -e, -e, e, e);
            } else _ = try lb.rect(a, 0, centre_nm[0] - @divTrunc(width_nm, 2), centre_nm[1] - run_nm / 2, centre_nm[0] + @divTrunc(width_nm, 2), centre_nm[1] + run_nm / 2);
        }
        var store: geom.GeometryStore = .empty;
        var ids: testgen.shapes.Ids = .{};
        try lb.finish(a, &store, &ids);
        var bytes: std.ArrayList(u8) = .empty;
        const no_layers: ingest.deck.LayerTable = .{};
        try testgen.gds.writeStore(a, &store, if (parsed) |*d| &d.layers else &no_layers, "TOP", &bytes);
        try f.tmp.dir.writeFile(io, .{ .sub_path = "layout.gds", .data = bytes.items });
        return f;
    }

    fn deinit(f: *Fixture) void {
        f.arena_state.deinit();
        f.tmp.cleanup();
    }

    fn arena(f: *Fixture) Allocator {
        return f.arena_state.allocator();
    }

    fn load(f: *Fixture) !gpurify.Loaded {
        var diag: gpurify.LoadDiagnostic = .{};
        return gpurify.load(gpa, f.arena(), io, f.tmp.dir, f.inputs, &.{}, &diag);
    }

    fn run(f: *Fixture, checks: gpurify.Checks) !gpurify.Run {
        var diag: gpurify.RunDiagnostic = .{};
        return gpurify.run(gpa, f.arena(), io, f.tmp.dir, f.inputs, .{ .checks = checks }, &.{}, &diag);
    }
};

// ---- private ----

/// The deck with one rule's check substituted.
fn deckWithRule(comptime grid: []const u8, comptime rule: []const u8) []const u8 {
    return "grid " ++ grid ++ "\nlayer met1 = gds(10, 0)\nrule narrow_metal " ++ rule ++ "\nconnect conductors [met1]\nconnect touch_within_layer\n";
}

/// A store read back from GDS bytes on `layers`, unknown layers refused.
fn loadBytes(arena: Allocator, bytes: []const u8, layers: *const ingest.deck.LayerTable) !geom.GeometryStore {
    var strings: geom.StrTable = .empty;
    var diag: ingest.gds.Diagnostic = .{};
    const lib = try ingest.gds.Library.parse(arena, bytes, &strings, &diag);
    var store: geom.GeometryStore = .empty;
    var provenance: ingest.Provenance = .{};
    var tags: std.ArrayList(u64) = .empty;
    try ingest.layout.flattenInto(arena, &lib, layers, &strings, .reject, .top, &store, &provenance, &tags, &diag);
    return store;
}

fn oneLayer(arena: Allocator) !ingest.deck.LayerTable {
    var strings: geom.StrTable = .empty;
    var diag: ingest.deck.Diag = .{};
    const d = try ingest.deck.parseDeck(arena, arena, "grid 1nm\nlayer m = gds(1, 0)\n", try .init(1000), &strings, &diag);
    return d.layers;
}

fn expectStoresEqual(left: *const geom.GeometryStore, right: *const geom.GeometryStore) !void {
    try testing.expectEqual(left.layerCount(), right.layerCount());
    try testing.expectEqual(left.polyCount(), right.polyCount());
    for (0..left.layerCount()) |l| {
        const layer: geom.LayerId = @fromBackingInt(@as(u16, @intCast(l)));
        try testing.expectEqual(left.polysOnLayer(layer), right.polysOnLayer(layer));
    }
    for (0..left.polyCount()) |p| {
        const poly: geom.PolyId = @fromBackingInt(@as(u32, @intCast(p)));
        try testing.expectEqual(left.polyLayer(poly), right.polyLayer(poly));
        try testing.expectEqualSlices(i64, left.polyVerts(poly).xs, right.polyVerts(poly).xs);
        try testing.expectEqualSlices(i64, left.polyVerts(poly).ys, right.polyVerts(poly).ys);
        try testing.expectEqual(left.polyBbox(poly), right.polyBbox(poly));
    }
}

/// Every case of `domain` through `check_fn`; one failure lists them all.
fn domainCases(domain: []const u8, comptime check_fn: anytype) !void {
    var arena: std.heap.ArenaAllocator = .init(gpa);
    defer arena.deinit();
    const a = arena.allocator();
    const c = try corpus.corpus(a);
    var failed: std.ArrayList([]const u8) = .empty;
    const cases = c.object.get(domain).?.object.get("cases").?.array.items;
    for (cases) |case| try check_fn(a, case, &failed);
    try corpus.report(domain, cases.len, failed.items);
}

/// Whether LVS of corpus cell `id` against `reference` matched.
fn matches(arena: Allocator, id: []const u8, reference: []const u8) !bool {
    const r = try corpus.runCase(arena, "lvs", id, .{ .lvs = true }, reference, null);
    return r.outputs.lvs.?.verdict == .match;
}

fn expectNear(got: f64, want: f64) !void {
    if (@abs(got - want) > 1e-9 * @max(@abs(want), 1.0)) {
        std.debug.print("got {d}, the closed form says {d}\n", .{ got, want });
        return error.TestExpectedApproxEqRel;
    }
}

fn irDropIntent(arena: Allocator, limits: []const u8) []const u8 {
    return std.fmt.allocPrint(arena,
        \\{{ "temperature_c": 85.0, "domains": {{ "core": {{ "voltage_mv": 1800.0 }} }},
        \\  "supplies": [{{ "net": "LVS_INV_n5", "domain": "core", "role": "power" }}],
        \\  "limits": [{{ "net": "LVS_INV_n5", {s} }}] }}
    , .{limits}) catch @panic("OOM");
}

fn emIntent(arena: Allocator, limits: []const u8) []const u8 {
    return std.fmt.allocPrint(arena,
        \\{{ "temperature_c": 85.0, "domains": {{ "core": {{ "voltage_mv": 1800.0 }} }},
        \\  "supplies": [{{ "net": "ERC_EM_n2", "domain": "core", "role": "power" }}],
        \\  "limits": [{{ "net": "ERC_EM_n2", {s} }}] }}
    , .{limits}) catch @panic("OOM");
}

fn emDevIntent(arena: Allocator, budget_ua: []const u8) []const u8 {
    return std.fmt.allocPrint(arena,
        \\{{ "temperature_c": 85.0, "domains": {{ "core": {{ "voltage_mv": 1800.0 }} }},
        \\  "supplies": [{{ "net": "ERC_EM_DEV_n0", "domain": "core", "role": "power" }}],
        \\  "limits": [{{ "net": "ERC_EM_DEV_n0", "budget_current_ua": {s} }}] }}
    , .{budget_ua}) catch @panic("OOM");
}

test "a deliberate min-width violation survives the whole pipeline" {
    // Oracle: construct-from-answer. One min-width violation, placed at a
    // coordinate this test chose, carried through every stage.
    var f = try Fixture.init(min_width_deck, narrow_nm, .{});
    defer f.deinit();
    const r = try f.run(.{ .drc = true, .lvs = true });
    try testing.expectEqual(1, r.outputs.violations.len());
    const v = r.outputs.violations.get(0);
    try testing.expectEqualStrings("narrow_metal", r.loaded.strings.resolve(v.rule));
    try testing.expectEqual(r.loaded.deck.deck.layers.id(&r.loaded.strings, "met1").?, v.layer);
    try testing.expectEqual(geom.Point{ .x = centre_nm[0], .y = centre_nm[1] }, v.at);
    try testing.expect(v.measured.eql(.length(narrow_nm)));
    try testing.expect(v.limit.eql(.length(limit_nm)));
    try testing.expectEqual(.@"error", v.severity);
}

test "a clean layout reports clean and says which rules examined what" {
    // Oracle: construct-from-answer. A correct layout comes back clean and
    // says what it checked: examined > 0 with `ran`.
    var f = try Fixture.init(min_width_deck, wide_nm, .{});
    defer f.deinit();
    const r = try f.run(.{ .drc = true, .lvs = true });
    try testing.expectEqual(0, r.outputs.violations.len());
    const width = try corpus.ruleRun(&r, "narrow_metal");
    try testing.expectEqual(.ran, width.outcome);
    try testing.expect(width.examined > 0);
}

test "a run missing its optional inputs reports skipped and does not pass" {
    // Oracle: construct-from-answer, on statuses: LVS selected with no
    // reference is skipped, the intent-gated ERC row cannot run, and a run
    // that could not check everything asked must not pass.
    var f = try Fixture.init(min_width_and_ir_drop_deck, wide_nm, .{});
    defer f.deinit();
    const r = try f.run(.{ .drc = true, .erc = true, .lvs = true });
    try testing.expect(r.summary.lvs == .skipped);
    try testing.expect(r.summary.rules_skipped > 0);
    try testing.expect(!r.summary.passed());
}

test "a layout written and read back yields the same store" {
    // Oracle: law, parse -> write -> parse is the identity on the store.
    var f = try Fixture.init(min_width_deck, narrow_nm, .{});
    defer f.deinit();
    const loaded = try f.load();
    var bytes: std.ArrayList(u8) = .empty;
    try testgen.gds.writeStore(f.arena(), &loaded.store, &loaded.deck.deck.layers, "TOP", &bytes);
    const again = try loadBytes(f.arena(), bytes.items, &loaded.deck.deck.layers);
    try expectStoresEqual(&loaded.store, &again);
}

test "a hole survives the file round trip" {
    // Oracle: law, on a hole. The reader splits a keyhole into its outer and
    // a clockwise hole row; written back, the hole goes inside its outer's
    // keyhole, since a BOUNDARY of its own reads back as material (E1).
    var arena: std.heap.ArenaAllocator = .init(gpa);
    defer arena.deinit();
    const a = arena.allocator();
    const layers = try oneLayer(a);
    var lb: testgen.shapes.LayoutBuilder = .init(1);
    _ = try lb.push(a, 0, &.{ 200, 1000, 1000, 0, 0, 200, 200, 200, 800, 800, 200 }, &.{ 0, 0, 1000, 1000, 0, 0, 200, 800, 800, 200, 200 });
    var store: geom.GeometryStore = .empty;
    var ids: testgen.shapes.Ids = .{};
    try lb.finish(a, &store, &ids);
    var bytes: std.ArrayList(u8) = .empty;
    try testgen.gds.writeStore(a, &store, &layers, "TOP", &bytes);
    const read = try loadBytes(a, bytes.items, &layers);
    try testing.expectEqual(2, read.polyCount());
    const r0 = read.polyVerts(@fromBackingInt(0));
    const r1 = read.polyVerts(@fromBackingInt(1));
    try testing.expectEqual(@as(i128, 2 * 1_000_000), geom.ops.area2(r0.xs, r0.ys));
    try testing.expectEqual(@as(i128, -2 * 360_000), geom.ops.area2(r1.xs, r1.ys));
    var again: std.ArrayList(u8) = .empty;
    try testgen.gds.writeStore(a, &read, &layers, "TOP", &again);
    try expectStoresEqual(&read, &(try loadBytes(a, again.items, &layers)));
}

test "coordinates at the domain edge survive the file round trip" {
    // Oracle: construct-from-answer. Coordinates at ±i32::MAX, the widest a
    // GDSII file carries, survive the round trip exactly.
    const extreme: i64 = std.math.maxInt(i32);
    var f = try Fixture.init(min_width_deck, 0, .{ .extreme = extreme });
    defer f.deinit();
    const loaded = try f.load();
    var low = false;
    var high = false;
    for (0..loaded.store.polyCount()) |p| {
        const ring = loaded.store.polyVerts(@fromBackingInt(@as(u32, @intCast(p))));
        for ([_][]const i64{ ring.xs, ring.ys }) |col| for (col) |c| {
            try testing.expect(@abs(c) <= extreme);
            low = low or c == -extreme;
            high = high or c == extreme;
        };
    }
    try testing.expect(low and high);
}

test "an off-grid deck limit is refused rather than rounded" {
    // Oracle: construct-from-answer. A limit the layout's 1 nm grid cannot
    // express (300.5 nm, on the deck's own 0.5 nm grid) is refused.
    var f = try Fixture.init(deckWithRule("0.5nm", "width(met1) >= 300.5nm"), wide_nm, .{});
    defer f.deinit();
    var diag: gpurify.LoadDiagnostic = .{};
    try testing.expectError(error.Invalid, gpurify.load(gpa, f.arena(), io, f.tmp.dir, f.inputs, &.{}, &diag));
    try testing.expectEqual(.deck, diag.stage);
    const message = diag.deck.deck.diagnostics[0].message;
    try testing.expect(std.mem.indexOf(u8, message, "not on the layout's grid") != null);
}

test "every rule in the deck appears in the run record exactly once" {
    // Oracle: law. Every rule the deck declares is accounted for once.
    var f = try Fixture.init(min_width_deck, wide_nm, .{});
    defer f.deinit();
    const r = try f.run(.{ .drc = true, .lvs = true });
    for (r.loaded.deck.deck.rules.spec) |spec| _ = try corpus.ruleRun(&r, r.loaded.strings.resolve(spec.id));
}

test "a reported length prints in nanometres against the run's grid" {
    // Oracle: construct-from-answer. A reported length reaches the reader in
    // nanometres, not database units.
    var f = try Fixture.init(min_width_deck, narrow_nm, .{});
    defer f.deinit();
    const r = try f.run(.{ .drc = true, .lvs = true });
    const v = r.outputs.violations.get(0);
    var buf: [64]u8 = undefined;
    const text = try std.fmt.bufPrint(&buf, "{f}", .{r.loaded.grid.toLength(@intCast(v.measured.exact()))});
    try testing.expectEqualStrings("200 nm", text);
}

test "every drc case in the corpus agrees with its geometry" {
    // Oracle: construct-from-answer, over 94 cells drawn with deliberate defects.
    try domainCases("drc", corpus.checkGeometryCase);
}

test "every erc case in the corpus agrees with its geometry" {
    // Oracle: construct-from-answer, on connectivity rather than on shapes.
    try domainCases("erc", corpus.checkGeometryCase);
}

test "every lvs cell in the corpus extracts the devices it draws" {
    // Oracle: construct-from-answer. Each LVS cell draws a stated number of
    // devices and nets, and matches its own reference (lvs_refs/) or not, as
    // expect_match derives from the geometry.
    var arena: std.heap.ArenaAllocator = .init(gpa);
    defer arena.deinit();
    const a = arena.allocator();
    const c = try corpus.corpus(a);
    var open: std.ArrayList([]const u8) = .empty;
    var it = c.object.get("blocking_findings").?.object.iterator();
    while (it.next()) |e| {
        const title = e.value_ptr.object.get("title").?.string;
        if (!std.mem.startsWith(u8, title, "RESOLVED") and !std.mem.startsWith(u8, title, "CLOSED")) try open.append(a, e.key_ptr.*);
    }
    var failed: std.ArrayList([]const u8) = .empty;
    const cases = c.object.get("lvs").?.object.get("cases").?.array.items;
    for (cases) |case| try corpus.checkLvsCase(a, case, open.items, &failed);
    try corpus.report("LVS", cases.len, failed.items);
}

test "a block placed by instance is compared like one drawn flat" {
    // Oracle: the circuit, not its hierarchy. LVS_INV's inverter placed by
    // instance matches the flat cell; a schematic that also places a
    // second, undrawn inverter does not (testing-plan F1).
    var arena: std.heap.ArenaAllocator = .init(gpa);
    defer arena.deinit();
    try testing.expectEqual(true, try matches(arena.allocator(), "LVS_CLEAN_MATCH", "lvs_refs/hier/inv_by_instance.spice"));
    try testing.expectEqual(false, try matches(arena.allocator(), "LVS_CLEAN_MATCH", "lvs_refs/hier/inv_and_missing_block.spice"));
}

test "a merge needs only the size it sums" {
    // Oracle: construct-from-answer, testing-plan F84: the stack is one card
    // of L=100n with no W, the pair one of W=400n with no L; the other size
    // alone leaves nothing to sum, so the two stay two.
    var arena: std.heap.ArenaAllocator = .init(gpa);
    defer arena.deinit();
    const a = arena.allocator();
    for ([_]struct { []const u8, []const u8, bool }{
        .{ "LVS_SERIES_MERGE", "series_l_only", true },
        .{ "LVS_SERIES_MERGE", "series_w_only", false },
        .{ "LVS_PARALLEL_MERGE", "parallel_w_only", true },
        .{ "LVS_PARALLEL_MERGE", "parallel_l_only", false },
    }) |row| {
        const path = try std.fmt.allocPrint(a, "lvs_refs/sized/{s}.spice", .{row[1]});
        try testing.expectEqual(row[2], try matches(a, row[0], path));
    }
}

test "a real extraction and a reference netlist reach a verdict and five run rows" {
    // Oracle: construct-from-answer. LVS_INV and lvs_inv.cdl (two MOS cards,
    // four nets) match; the five layout rows examine the extraction's own
    // counts; the JSON report names every row.
    var arena: std.heap.ArenaAllocator = .init(gpa);
    defer arena.deinit();
    const a = arena.allocator();
    const r = try corpus.runCase(a, "lvs", "LVS_CLEAN_MATCH", .{ .lvs = true }, "lvs_inv.cdl", null);
    const reference = r.loaded.reference.?;
    try testing.expectEqual(2, reference.device_kind.items.len);
    try testing.expectEqual(4, reference.net_name.items.len);
    try testing.expect(r.outputs.lvs.?.verdict == .match);
    try testing.expectEqual(0, r.outputs.violations.len());
    const expected = [_]struct { []const u8, u64 }{
        .{ "lvs.floating_net", r.extracted.nets.netCount() },
        .{ "lvs.label_conflict", r.extracted.nets.netCount() },
        .{ "lvs.net_seed_conflict", r.extracted.ports.len() },
        .{ "lvs.terminal_net", r.extracted.devices.terminal_net.items.len },
        .{ "lvs.terminal_count", r.extracted.devices.len() },
    };
    for (expected) |row| {
        const rr = try corpus.ruleRun(&r, row[0]);
        try testing.expectEqual(.ran, rr.outcome);
        try testing.expectEqual(row[1], rr.examined);
    }
    try testing.expectEqual(expected.len, r.outputs.runs.items.len);
    var out: std.Io.Writer.Allocating = .init(a);
    const header: gpurify.@"export".Header = .{ .tool_version = "test", .deck_path = "params.deck", .layout_path = "LVS_CLEAN_MATCH.gds" };
    try gpurify.@"export".json.writeReport(&out.writer, &header, &r.loaded.strings, &r.loaded.deck.deck.layers, r.loaded.grid, &r.outputs.violations, &r.outputs.waived, r.outputs.runs.items, r.outputs.run_domain.items, r.summary);
    for (expected) |row| try testing.expect(std.mem.indexOf(u8, out.written(), try std.fmt.allocPrint(a, "\"{s}\"", .{row[0]})) != null);
}

test "every pex case in the corpus agrees with its closed form" {
    // Oracle: closed form. Sheet resistance of a known rectangle,
    // parallel-plate and fringe capacitance of a known area, vias in parallel.
    try domainCases("pex", corpus.checkPexCase);
}

test "lateral coupling halves when the gap doubles and ignores the axis" {
    // Oracle: law. Lateral coupling goes as 1/S and does not depend on the axis.
    var arena: std.heap.ArenaAllocator = .init(gpa);
    defer arena.deinit();
    var failed: std.ArrayList([]const u8) = .empty;
    try corpus.checkCouplingLaws(arena.allocator(), &failed);
    try corpus.report("coupling law", 4, failed.items);
}

test "a field solve obeys the coupling laws a closed form cannot state" {
    // Oracle: law, against the field solve: PEX_VERT is PEX_CC turned a
    // quarter (the same field, to 1e-9); PEX_M2CC is PEX_CC 700 nm farther
    // from the grounded substrate, so it couples more; coupling falls as the
    // gap widens; and each is at least two facing plates' ε₀·k·t·L/S, which
    // has no fringe at all.
    if (!paths.slow_tests) return;
    var arena: std.heap.ArenaAllocator = .init(gpa);
    defer arena.deinit();
    const a = arena.allocator();
    const s100 = try corpus.fieldSolvedCouplingAf(a, "PEX_SPACING_100");
    const s200 = try corpus.fieldSolvedCouplingAf(a, "PEX_COUPLING_C");
    const s400 = try corpus.fieldSolvedCouplingAf(a, "PEX_SPACING_400");
    const vertical = try corpus.fieldSolvedCouplingAf(a, "PEX_VERT_COUPLING");
    const on_met2 = try corpus.fieldSolvedCouplingAf(a, "PEX_MET2_COUPLING");
    for ([_]f64{ s100, s200, s400 }) |v| try testing.expect(v > 0 and std.math.isFinite(v));
    try testing.expect(@abs(vertical - s200) <= 1e-9 * @max(@abs(vertical), @abs(s200)));
    try testing.expect(on_met2 > s200);
    try testing.expect(s100 > s200 and s200 > s400);
    const eps0_af_per_nm = 8.8541878128e-3;
    for ([_][2]f64{ .{ s100, 100 }, .{ s200, 200 }, .{ s400, 400 } }) |p| try testing.expect(p[0] >= eps0_af_per_nm * 3.9 * 400.0 * 2000.0 / p[1]);
}

test "a corpus case with design intent reaches an intent-gated rule" {
    // Oracle: construct-from-answer, on the harness: without intent hv_domain
    // is skipped for no intent; with one naming the cell's labelled net, it runs.
    var arena: std.heap.ArenaAllocator = .init(gpa);
    defer arena.deinit();
    const a = arena.allocator();
    const without = try corpus.runCase(a, "erc", "ERC_HV_CROSS", .{ .erc = true }, null, null);
    try testing.expectEqual(report.Outcome{ .skipped = .no_design_intent }, (try corpus.ruleRun(&without, "hv_domain")).outcome);
    const with = try corpus.runCase(a, "erc", "ERC_HV_CROSS", .{ .erc = true }, null, hv_domain_intent);
    try testing.expect(with.extracted.ports.netOf(with.loaded.strings.get("ERC_HV_n0").?) != null);
    try testing.expectEqual(.ran, (try corpus.ruleRun(&with, "hv_domain")).outcome);
}

test "a stated current budget drops ohm's law across a known poly rail" {
    // Oracle: closed form, V = I·R: 1000 µA (half the stated 2000) through
    // 5.0 squares of 48.2 Ω/sq is 241.0 mV over a 200 mV limit at both gate
    // taps; no budget drops nothing; a 300 mV limit holds the same drop.
    var arena: std.heap.ArenaAllocator = .init(gpa);
    defer arena.deinit();
    const a = arena.allocator();
    const r = try corpus.runCase(a, "erc", "ERC_IR_DROP_GATE", .{ .erc = true }, null, irDropIntent(a, "\"max_drop_mv\": 200.0, \"budget_current_ua\": 2000.0"));
    try testing.expect(r.extracted.ports.netOf(r.loaded.strings.get("LVS_INV_n5").?) != null);
    const ran = try corpus.ruleRun(&r, "ir_drop");
    try testing.expectEqual(.ran, ran.outcome);
    try testing.expectEqual(3, ran.examined);
    const found = try corpus.violationsOf(a, &r, "ir_drop");
    try testing.expectEqual(2, found.len);
    try expectNear(found[0].measured.float(), 241.0);
    try expectNear(found[0].limit.float(), 200.0);
    try testing.expectEqual(geom.Point{ .x = 225, .y = 100 }, found[0].at);
    try testing.expectEqual(r.loaded.deck.deck.layers.id(&r.loaded.strings, "poly").?, found[0].layer);
    try testing.expectEqual(.@"error", found[0].severity);
    for ([_][]const u8{ "\"max_drop_mv\": 200.0", "\"max_drop_mv\": 300.0, \"budget_current_ua\": 2000.0" }) |limits| {
        const other = try corpus.runCase(a, "erc", "ERC_IR_DROP_GATE", .{ .erc = true }, null, irDropIntent(a, limits));
        const rr = try corpus.ruleRun(&other, "ir_drop");
        try testing.expectEqual(.ran, rr.outcome);
        try testing.expectEqual(3, rr.examined);
        try testing.expectEqual(0, (try corpus.violationsOf(a, &other, "ir_drop")).len);
    }
}

test "the reliability model derates a cool part upward and an overstressed one below its floor" {
    // Oracle: closed form, the Arrhenius/inverse-power lifetime model on the
    // deck's own `bti` row: at the characterisation stress a part 40 K cool
    // predicts 5091.597 h over a 1000 h floor; at 3300 mV,
    // 5091.59717249751 h × (1800/3300)^4 = 450.70076740364533 h.
    var arena: std.heap.ArenaAllocator = .init(gpa);
    defer arena.deinit();
    const a = arena.allocator();
    const nominal = try corpus.runCase(a, "erc", "ERC_RELIABILITY", .{ .erc = true }, null, hv_domain_intent);
    try testing.expect(nominal.extracted.ports.netOf(nominal.loaded.strings.get("ERC_HV_n0").?) != null);
    const ran = try corpus.ruleRun(&nominal, "bti");
    try testing.expectEqual(.ran, ran.outcome);
    try testing.expectEqual(1, ran.examined);
    try testing.expectEqual(0, (try corpus.violationsOf(a, &nominal, "bti")).len);
    const stressed = try corpus.runCase(a, "erc", "ERC_RELIABILITY", .{ .erc = true }, null, hv_overstress_intent);
    try testing.expectEqual(1, (try corpus.ruleRun(&stressed, "bti")).examined);
    const found = try corpus.violationsOf(a, &stressed, "bti");
    try testing.expectEqual(1, found.len);
    try testing.expectEqual(report.Kind.ratio, found[0].measured.kind);
    try expectNear(found[0].measured.float(), 450.70076740364533);
    try testing.expect(found[0].limit.eql(.ratio(1000.0)));
    try testing.expectEqual(geom.Point{ .x = 500, .y = 250 }, found[0].at);
    try testing.expectEqual(stressed.loaded.deck.deck.layers.id(&stressed.loaded.strings, "met1").?, found[0].layer);
}

test "an unclamped pad and an undersized guard ring are both found on the same cell" {
    // Oracle: closed form on the geometry: the 500 nm ring against a 1000 nm
    // minimum, at its first vertex (0, 0); the pad reaches one rail of two
    // (it is the declared supply; ERC_HV has no clamp), at (200, 200).
    var arena: std.heap.ArenaAllocator = .init(gpa);
    defer arena.deinit();
    const a = arena.allocator();
    const r = try corpus.runCase(a, "erc", "ERC_ESD_LATCHUP", .{ .erc = true }, null, hv_domain_intent);
    try testing.expect(r.extracted.ports.netOf(r.loaded.strings.get("ERC_HV_n0").?) != null);
    const ran = try corpus.ruleRun(&r, "esd_latchup");
    try testing.expectEqual(.ran, ran.outcome);
    try testing.expectEqual(2, ran.examined);
    const found = try corpus.violationsOf(a, &r, "esd_latchup");
    try testing.expectEqual(2, found.len);
    try testing.expect(found[0].measured.eql(.length(500)) and found[0].limit.eql(.length(1000)));
    try testing.expectEqual(geom.Point{ .x = 0, .y = 0 }, found[0].at);
    try testing.expectEqual(r.loaded.deck.deck.layers.id(&r.loaded.strings, "nwell").?, found[0].layer);
    try testing.expect(found[1].measured.eql(.count(1)) and found[1].limit.eql(.count(2)));
    try testing.expectEqual(geom.Point{ .x = 200, .y = 200 }, found[1].at);
    try testing.expectEqual(r.loaded.deck.deck.layers.id(&r.loaded.strings, "met1").?, found[1].layer);
}

test "a discarded current budget refuses the rules that read a branch current" {
    // Oracle: law, a rule that cannot compute what it compares refuses: the
    // stated 1000 µA on a rail with no device terminal never reaches the
    // solve, so the three branch-current rows refuse with nothing examined,
    // while `bti`, which reads node voltage, still runs.
    var arena: std.heap.ArenaAllocator = .init(gpa);
    defer arena.deinit();
    const a = arena.allocator();
    const r = try corpus.runCase(a, "erc", "ERC_EMIG_MET1", .{ .erc = true }, null, emIntent(a, "\"budget_current_ua\": 1000.0"));
    const net = r.extracted.ports.netOf(r.loaded.strings.get("ERC_EM_n2").?).?;
    try testing.expectEqual(0, r.extracted.devices.devicesOn(net).len);
    for ([_][]const u8{ "met1.electromigration", "ir_drop", "em_current_density" }) |rule| {
        const rr = try corpus.ruleRun(&r, rule);
        try testing.expectEqual(.refused, rr.outcome);
        try testing.expectEqual(0, rr.examined);
        try testing.expectEqual(0, (try corpus.violationsOf(a, &r, rule)).len);
    }
    try testing.expectEqual(.ran, (try corpus.ruleRun(&r, "bti")).outcome);
}

test "a terminal-less rail with no stated budget still reaches a verdict" {
    // Oracle: the gate's own contract: the refusal is conditioned on a stated
    // budget, so no budget is no current; a Blech product of 0 exempts every
    // met1 edge (examined 0), and em_current_density examines every edge.
    var arena: std.heap.ArenaAllocator = .init(gpa);
    defer arena.deinit();
    const a = arena.allocator();
    const r = try corpus.runCase(a, "erc", "ERC_EMIG_MET1", .{ .erc = true }, null, emIntent(a, "\"max_drop_mv\": 200.0"));
    try testing.expect(r.extracted.ports.netOf(r.loaded.strings.get("ERC_EM_n2").?) != null);
    const em = try corpus.ruleRun(&r, "met1.electromigration");
    try testing.expectEqual(.ran, em.outcome);
    try testing.expectEqual(0, em.examined);
    try testing.expectEqual(0, (try corpus.violationsOf(a, &r, "met1.electromigration")).len);
    const density = try corpus.ruleRun(&r, "em_current_density");
    try testing.expectEqual(.ran, density.outcome);
    try testing.expect(density.examined > 0);
    try testing.expectEqual(0, (try corpus.violationsOf(a, &r, "em_current_density")).len);
}

test "black and blech decide a met1 rail that carries a device terminal" {
    // Oracle: closed form, Black's equation's Arrhenius derating: 1000 A/m ×
    // 100 nm = 100 µA, times exp(0.9/8.617333262e-5 × (1/358.15 − 1/383.15))
    // = 670.4133044734676 µA; 1000 µA exceeds it, 500 µA does not, and 1 µA
    // over a 900/100 slenderness is a Blech product of 9 ≤ 10: exempt.
    var arena: std.heap.ArenaAllocator = .init(gpa);
    defer arena.deinit();
    const a = arena.allocator();
    const hot = try corpus.runCase(a, "erc", "ERC_EMIG_DEV", .{ .erc = true }, null, emDevIntent(a, "1000.0"));
    const net = hot.extracted.ports.netOf(hot.loaded.strings.get("ERC_EM_DEV_n0").?).?;
    try testing.expect(hot.extracted.devices.devicesOn(net).len != 0);
    const ran = try corpus.ruleRun(&hot, "met1.electromigration");
    try testing.expectEqual(.ran, ran.outcome);
    try testing.expectEqual(1, ran.examined);
    const found = try corpus.violationsOf(a, &hot, "met1.electromigration");
    try testing.expectEqual(1, found.len);
    try testing.expectEqual(report.Kind.current, found[0].measured.kind);
    try expectNear(found[0].measured.float(), 1000.0);
    try expectNear(found[0].limit.float(), 670.4133044734676);
    try testing.expectEqual(geom.Point{ .x = 650, .y = 100 }, found[0].at);
    try testing.expectEqual(hot.loaded.deck.deck.layers.id(&hot.loaded.strings, "met1").?, found[0].layer);
    for ([_]struct { []const u8, u64 }{ .{ "500.0", 1 }, .{ "1.0", 0 } }) |row| {
        const r = try corpus.runCase(a, "erc", "ERC_EMIG_DEV", .{ .erc = true }, null, emDevIntent(a, row[0]));
        const rr = try corpus.ruleRun(&r, "met1.electromigration");
        try testing.expectEqual(.ran, rr.outcome);
        try testing.expectEqual(row[1], rr.examined);
        try testing.expectEqual(0, (try corpus.violationsOf(a, &r, "met1.electromigration")).len);
    }
}

test "extracting the split corpus twice is bit identical" {
    // Oracle: law, determinism on the split extraction path: two extractions
    // agree on nets, ports and every device column, and the split is in
    // force (a MOS's source and drain are distinct nets).
    var arena: std.heap.ArenaAllocator = .init(gpa);
    defer arena.deinit();
    const a = arena.allocator();
    const first = try corpus.runCase(a, "lvs", "LVS_CLEAN_MATCH", .{}, null, null);
    const second = try corpus.runCase(a, "lvs", "LVS_CLEAN_MATCH", .{}, null, null);
    const pa = try testgen.assertions.netPartition(a, &first.extracted.nets);
    const pb = try testgen.assertions.netPartition(a, &second.extracted.nets);
    try testing.expectEqual(pa.len, pb.len);
    for (pa, pb) |x, y| try testing.expectEqualSlices(geom.PolyId, x, y);
    try testing.expectEqualSlices(?geom.StrId, try testgen.assertions.portNames(a, &first.extracted.ports, &first.extracted.nets), try testgen.assertions.portNames(a, &second.extracted.ports, &second.extracted.nets));
    const d1 = &first.extracted.devices;
    const d2 = &second.extracted.devices;
    inline for (.{ "kind", "marker", "model", "terminal_start", "terminal_net", "terminal_role", "param_start", "param_name", "param_measure" }) |col|
        try testing.expectEqualDeep(@field(d1, col).items, @field(d2, col).items);
    const terms = d1.terminalsOf(@fromBackingInt(0));
    var source: ?usize = null;
    var drain: ?usize = null;
    for (terms.roles, 0..) |r, i| switch (r) {
        .source => source = i,
        .drain => drain = i,
        else => {},
    };
    try testing.expect(terms.nets[source.?] != terms.nets[drain.?]);
}

test "a keyhole keeps its hole under an overlapping shape" {
    // Oracle: construct-from-answer (N-s2-2): [35, 65]² less [45, 55] x
    // [50, 65], then [0, 100]² around the hole [40, 60]² as one keyhole:
    // areas 30² − 10·15 and 100² − 20², the hole bound to the second.
    var arena: std.heap.ArenaAllocator = .init(gpa);
    defer arena.deinit();
    const a = arena.allocator();
    const layers = try oneLayer(a);
    var lb: testgen.shapes.LayoutBuilder = .init(1);
    _ = try lb.push(a, 0, &.{ 35, 65, 65, 55, 55, 45, 45, 35 }, &.{ 35, 35, 65, 65, 50, 50, 65, 65 });
    _ = try lb.push(a, 0, &.{ 40, 100, 100, 0, 0, 40, 40, 40, 60, 60, 40 }, &.{ 0, 0, 100, 100, 0, 0, 40, 60, 60, 40, 40 });
    var store: geom.GeometryStore = .empty;
    var ids: testgen.shapes.Ids = .{};
    try lb.finish(a, &store, &ids);
    var bytes: std.ArrayList(u8) = .empty;
    try testgen.gds.writeStore(a, &store, &layers, "TOP", &bytes);
    const read = try loadBytes(a, bytes.items, &layers);
    var layer: geom.ValidatedLayer = .empty;
    try testing.expect(try geom.view.validateLayer(a, &read, @fromBackingInt(0), .rectilinear, &layer) == null);
    var rects: std.ArrayList(geom.Bbox) = .empty;
    var start: std.ArrayList(u32) = .empty;
    try geom.rects.decomposeInto(a, &layer, &rects, &start);
    for ([_]struct { u32, i128 }{ .{ 1, 30 * 30 - 10 * 15 }, .{ 2, 100 * 100 - 20 * 20 } }, 0..) |want, i| {
        try testing.expectEqual(want[0], layer.get(@intCast(i)).ringCount());
        try testing.expectEqual(want[1], geom.rects.coveredArea(rects.items[start.items[i]..start.items[i + 1]]));
    }
}

test "every pex case in the corpus also field solves" {
    // Oracle: closed form and law (`corpus.checkPexCaseFieldSolved`): the
    // stage outcome and drawn nets; a straight bar's resistance is Rs·L/W in
    // both methods; a field-solved coupling is at least the closed form's.
    if (!paths.slow_tests) return;
    try domainCases("pex", corpus.checkPexCaseFieldSolved);
}
