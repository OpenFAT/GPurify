//! The engine's load and extract stages, stage statuses and the pass
//! criterion, custom rules through a run, and device-region capacitance.
//! Ported from tests/engine/{main, custom, device_region}.rs.

const std = @import("std");
const testing = std.testing;
const Allocator = std.mem.Allocator;
const paths = @import("paths");
const geom = @import("geom");
const ingest = @import("ingest");
const check = @import("check");
const testgen = @import("testgen");
const gpurify = @import("gpurify");
const gpa = testing.allocator;
const io = testing.io;

const fixtures = "tests/fixtures";

const params_deck = @embedFile("../fixtures/params.deck");

/// Two touching rectangles (one net) and a third apart (another).
const rails = [_][4]i64{ .{ 0, 0, 100, 100 }, .{ 90, 0, 200, 100 }, .{ 500, 0, 600, 100 } };

/// A run over a store built by hand: one conductor layer, rectangles,
/// labels as (rectangle, name), and nothing else read.
const Hand = struct {
    arena: std.heap.ArenaAllocator,
    loaded: gpurify.Loaded,
    ids: testgen.shapes.Ids,
    rects: [3]testgen.shapes.Handle,

    fn init(boxes: []const [4]i64, labels: []const struct { usize, []const u8 }) !Hand {
        var w: Hand = .{ .arena = .init(gpa), .loaded = undefined, .ids = .{}, .rects = undefined };
        errdefer w.arena.deinit();
        const a = w.arena.allocator();
        var lb: testgen.shapes.LayoutBuilder = .init(1);
        for (boxes, 0..) |b, i| w.rects[i] = try lb.rect(a, 0, b[0], b[1], b[2], b[3]);
        var store: geom.GeometryStore = .empty;
        try lb.finish(a, &store, &w.ids);
        var d: ingest.deck.Deck = .{};
        d.connectivity = .{ .conductors = &.{@fromBackingInt(0)}, .intra_layer_touch = true };
        var strings: geom.StrTable = .empty;
        var diag: check.deck.compile.Diag = .{};
        const grid: geom.Grid = try .init(1000);
        w.loaded = .{ .strings = strings, .grid = grid, .deck = undefined, .store = store, .provenance = .{}, .reference = null, .intent = null, .design = null };
        w.loaded.deck = try check.deck.compile.fromDeck(a, d, grid, &w.loaded.strings, &diag);
        _ = &strings;
        for (labels) |l| try w.loaded.provenance.label(a, w.ids.of(w.rects[l[0]]), try w.loaded.strings.intern(a, l[1]));
        return w;
    }

    fn deinit(w: *Hand) void {
        w.arena.deinit();
    }

    fn alloc(w: *Hand) Allocator {
        return w.arena.allocator();
    }

    fn extract(w: *Hand) !gpurify.Extracted {
        var diag: gpurify.ExtractDiagnostic = .none;
        return gpurify.extract(w.alloc(), &w.loaded, &diag);
    }

    const Checked = struct { outputs: gpurify.Outputs, summary: gpurify.Summary };

    fn checks(w: *Hand, ex: *const gpurify.Extracted, options: gpurify.RunOptions) !Checked {
        var out: Checked = .{ .outputs = .{}, .summary = undefined };
        out.summary = try gpurify.runChecks(gpa, w.alloc(), &w.loaded, ex, options, &out.outputs);
        return out;
    }
};

const Rect = struct { []const u8, i64, i64, i64, i64 };

const Lvs = struct { verdict: check.lvs.Verdict, rules: []const []const u8 };

/// A consumer holding the sky130 deck once, checking edits in memory
/// (FLOW-005): its own string table and compiled DRC rows.
const Consumer = struct {
    strings: geom.StrTable,
    deck: check.deck.CompiledDeck,

    const Report = struct {
        text: []const []const u8,
        rules: []const []const u8,
        measured: []const i128,

        fn count(r: Report, rule: []const u8) usize {
            var n: usize = 0;
            for (r.rules) |x| n += @intFromBool(std.mem.eql(u8, x, rule));
            return n;
        }

        fn of(r: Report, a: Allocator, rule: []const u8) ![]const i128 {
            var out: std.ArrayList(i128) = .empty;
            for (r.rules, r.measured) |x, m| if (std.mem.eql(u8, x, rule)) try out.append(a, m);
            return out.items;
        }
    };

    fn init(a: Allocator) !Consumer {
        var c: Consumer = .{ .strings = .empty, .deck = undefined };
        var diag: check.deck.compile.Diag = .{};
        c.deck = try check.deck.compile.compile(a, a, gpurify.pdks.sky130, try .init(1000), &c.strings, &diag);
        return c;
    }

    /// Two met1 wires 2 um tall, the first `width` wide and the second
    /// 140 nm, `gap` apart: the report as sorted text lines.
    fn edit(c: *Consumer, a: Allocator, width: i64, gap: i64) !Report {
        const met1 = c.deck.deck.layers.id(&c.strings, "met1").?;
        var builder: geom.GeometryStoreBuilder = .{};
        for ([_][2]i64{ .{ 0, width }, .{ width + gap, width + gap + 140 } }) |x| _ = try builder.push(a, met1, &.{ x[0], x[1], x[1], x[0] }, &.{ 0, 0, 2000, 2000 });
        var store: geom.GeometryStore = .empty;
        var order: std.ArrayList(u32) = .empty;
        try builder.finish(a, @intCast(c.deck.deck.layers.len()), &store, &order);
        try ingest.layout.deriveLayersInto(a, &store, &c.deck.deck.layers, &.{}, &c.strings, &.{});
        var out: check.report.Violations = .{};
        var runs: std.ArrayList(check.report.RuleRun) = .empty;
        try check.drc.run(a, .cpu, null, &c.deck.drc, &store, null, &out, &runs);
        var text: std.ArrayList([]const u8) = .empty;
        for (runs.items) |r| try text.append(a, try std.fmt.allocPrint(a, "{s} {t} {d}", .{ c.strings.resolve(r.rule), std.meta.activeTag(r.outcome), r.examined }));
        const rules = try a.alloc([]const u8, out.len());
        const measured = try a.alloc(i128, out.len());
        for (0..out.len()) |row| {
            const v = out.get(@intCast(row));
            rules[row] = c.strings.resolve(v.rule);
            measured[row] = v.measured.exact();
            try text.append(a, try std.fmt.allocPrint(a, "{s} {f} {d},{d}", .{ rules[row], v.measured, v.at.x, v.at.y }));
        }
        std.mem.sort([]const u8, text.items, {}, lessString);
        return .{ .text = text.items, .rules = rules, .measured = measured };
    }
};

var calls: std.atomic.Value(u32) = .init(0);

const Width = struct { um: f64, apart: bool };

const Widths = struct { coupling: f64, widths: []const Width };

// ---- private ----

/// PEX_COUPLING_C's (inductance, capacitive) element counts, analytical or
/// with both its nets field-solved.
fn countKinds(quasistatic: bool) ![2]usize {
    var arena: std.heap.ArenaAllocator = .init(gpa);
    defer arena.deinit();
    var root = try std.Io.Dir.cwd().openDir(io, paths.root, .{});
    defer root.close(io);
    var diag: gpurify.RunDiagnostic = .{};
    const device: geom.Device = .{ .backend = .cpu, .min_work = .never, .threads = 8 };
    const options: gpurify.RunOptions = .{ .checks = .{ .pex = true }, .quasistatic_nets = if (quasistatic) &.{ "PEX_CC_n0", "PEX_CC_n1" } else &.{}, .device = device };
    const r = try gpurify.run(gpa, arena.allocator(), io, root, .{ .layout = fixtures ++ "/pex/PEX_COUPLING_C.gds", .deck = fixtures ++ "/params.deck" }, options, &.{}, &diag);
    try testing.expect(r.summary.pex == .ran);
    var out: [2]usize = .{ 0, 0 };
    for (r.outputs.parasitics.?.kind.items) |k| switch (k) {
        .inductance, .mutual_inductance => out[0] += 1,
        else => out[1] += 1,
    };
    return out;
}

/// LVS of `rects` on the shipped sky130 deck against the SPICE `reference`.
fn sky130Lvs(a: Allocator, rects: []const Rect, reference: []const u8) !Lvs {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    var strings: geom.StrTable = .empty;
    var diag: ingest.deck.Diag = .{};
    const d = try ingest.deck.parseDeck(a, a, gpurify.pdks.sky130, try .init(1000), &strings, &diag);
    var lb: testgen.shapes.LayoutBuilder = .init(@intCast(d.layers.len()));
    for (rects) |r| _ = try lb.rect(a, @backingInt(d.layers.id(&strings, r[0]).?), r[1], r[2], r[3], r[4]);
    var store: geom.GeometryStore = .empty;
    var ids: testgen.shapes.Ids = .{};
    try lb.finish(a, &store, &ids);
    var bytes: std.ArrayList(u8) = .empty;
    try testgen.gds.writeStore(a, &store, &d.layers, "TOP", &bytes);
    try tmp.dir.writeFile(io, .{ .sub_path = "top.gds", .data = bytes.items });
    try tmp.dir.writeFile(io, .{ .sub_path = "ref.spice", .data = reference });
    var rdiag: gpurify.RunDiagnostic = .{};
    const r = try gpurify.run(gpa, a, io, tmp.dir, .{ .layout = "top.gds", .deck = "sky130", .reference = &.{"ref.spice"} }, .{ .checks = .{ .lvs = true } }, &gpurify.pdks.decks, &rdiag);
    try testing.expect(r.summary.lvs == .ran);
    const rules = try a.alloc([]const u8, r.outputs.violations.len());
    for (rules, r.outputs.violations.rule.items) |*n, id| n.* = r.loaded.strings.resolve(id);
    return .{ .verdict = r.outputs.lvs.?.verdict, .rules = rules };
}

fn lessString(_: void, x: []const u8, y: []const u8) bool {
    return std.mem.order(u8, x, y) == .lt;
}

fn expectSameLines(x: []const []const u8, y: []const []const u8) !void {
    try testing.expectEqual(x.len, y.len);
    for (x, y) |p, q| try testing.expectEqualStrings(p, q);
}

/// Flags every shape of its input.
fn flagsEach(ctx: *const check.deck.custom.CustomCtx, out: *check.deck.custom.Findings) Allocator.Error!void {
    const rows = ctx.shapes(ctx.input(0));
    for (rows.start..rows.end) |r| try out.flag(ctx, @fromBackingInt(@as(u32, @intCast(r))), .count(1));
}

/// Flags a different shape on every call: a call counter in place of a
/// time seed, without the chance of two equal reads.
fn nondeterministic(ctx: *const check.deck.custom.CustomCtx, out: *check.deck.custom.Findings) Allocator.Error!void {
    const rows = ctx.shapes(ctx.input(0));
    const at = calls.fetchAdd(1, .monotonic) % rows.len();
    try out.flag(ctx, @fromBackingInt(rows.start + at), .count(1));
}

/// tests/fixtures/params.deck with one custom rule over met1.
fn Custom(comptime custom_check: check.deck.custom.CustomCheck) type {
    return struct {
        fn build(g: Allocator, arena: Allocator, grid: geom.Grid, strings: *geom.StrTable, diag: *check.deck.compile.Diag) check.deck.compile.Error!check.deck.CompiledDeck {
            const base = try check.deck.compile.compile(g, arena, params_deck, grid, strings, diag);
            var b = try check.deck.DeckBuilder.fromDeck(arena, &base, strings);
            try b.custom("met1.custom", &.{"met1"}, .@"error", custom_check);
            return b.finish(g, diag);
        }
    };
}

/// One DRC run of PEX_COUPLING_C under the deck named `deck`.
fn customRun(a: Allocator, decks: []const gpurify.NamedDeck, deck: []const u8) !gpurify.Run {
    var root = try std.Io.Dir.cwd().openDir(io, paths.root, .{});
    defer root.close(io);
    var diag: gpurify.RunDiagnostic = .{};
    return gpurify.run(gpa, a, io, root, .{ .layout = fixtures ++ "/pex/PEX_COUPLING_C.gds", .deck = deck }, .{ .checks = .{ .drc = true } }, decks, &diag);
}

/// One DRC run's JSON report: the bytes the golden test compares twice.
fn report(a: Allocator, decks: []const gpurify.NamedDeck, deck: []const u8) ![]const u8 {
    const r = try customRun(a, decks, deck);
    const header: gpurify.@"export".Header = .{ .tool_version = "test", .deck_path = deck, .layout_path = "" };
    var out: std.Io.Writer.Allocating = .init(a);
    try gpurify.@"export".json.writeReport(&out.writer, &header, &r.loaded.strings, &r.loaded.deck.deck.layers, r.loaded.grid, &r.outputs.violations, &r.outputs.waived, r.outputs.runs.items, r.outputs.run_domain.items, r.summary);
    return out.written();
}

/// The inverter's coupling, summed, with the params deck plus `extra`, and
/// each nfet's width in µm with whether its source and drain are off its
/// gate's net.
fn couplingAndWidths(a: Allocator, extra: []const u8) !Widths {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.writeFile(io, .{ .sub_path = "params.deck", .data = try std.fmt.allocPrint(a, "{s}\n{s}\n", .{ params_deck, extra }) });
    const layout = try std.fmt.allocPrint(a, "{s}/" ++ fixtures ++ "/lvs/LVS_CLEAN_MATCH.gds", .{paths.root});
    var diag: gpurify.RunDiagnostic = .{};
    const r = try gpurify.run(gpa, a, io, tmp.dir, .{ .layout = layout, .deck = "params.deck" }, .{ .checks = .{ .pex = true } }, &.{}, &diag);
    const network = r.outputs.parasitics.?;
    var coupling: f64 = 0;
    for (network.kind.items, network.value.items) |k, v| if (k == .coupling_cap) {
        coupling += v;
    };
    const devices = &r.extracted.devices;
    const nfet = r.loaded.strings.get("nfet_01v8").?;
    var widths: std.ArrayList(Width) = .empty;
    for (0..devices.len()) |d| {
        if (devices.model.items[d] != nfet) continue;
        const id: check.topology.DeviceId = @fromBackingInt(@as(u32, @intCast(d)));
        const params = devices.paramsOf(id);
        const w = for (params.names, params.measures) |n, m| {
            if (n == .width) switch (m) {
                .length => |l| break l,
                else => {},
            };
        } else unreachable;
        const t = devices.terminalsOf(id);
        const gate = roleNet(t, .gate);
        try widths.append(a, .{ .um = @as(f64, @floatFromInt(w)) / @as(f64, @floatFromInt(r.loaded.grid.dbu_per_um)), .apart = roleNet(t, .source) != gate and roleNet(t, .drain) != gate });
    }
    return .{ .coupling = coupling, .widths = widths.items };
}

fn roleNet(t: check.topology.device.Terminals, role: std.meta.Tag(check.topology.TerminalRole)) ?check.topology.NetId {
    for (t.nets, t.roles) |n, r| if (r == role) return n;
    return null;
}

test "a load reports the input at fault and reaches no stage" {
    // Oracle: `load`'s documented errors, which name the stage for each
    // input, and construct-from-answer: each case pairs one missing file with
    // a fixture pair the engine loads, so only that input can be at fault.
    var arena: std.heap.ArenaAllocator = .init(gpa);
    defer arena.deinit();
    var root = try std.Io.Dir.cwd().openDir(io, paths.root, .{});
    defer root.close(io);
    const layout = fixtures ++ "/pex/PEX_COUPLING_C.gds";
    const deck = fixtures ++ "/params.deck";
    const missing = "/nonexistent/missing";
    var diag: gpurify.LoadDiagnostic = .{};
    try testing.expectError(error.Unreadable, gpurify.load(gpa, arena.allocator(), io, root, .{ .layout = layout, .deck = missing }, &.{}, &diag));
    try testing.expectEqual(.deck, diag.stage);
    try testing.expectError(error.Io, gpurify.load(gpa, arena.allocator(), io, root, .{ .layout = missing, .deck = deck }, &.{}, &diag));
    try testing.expectEqual(.layout, diag.stage);
    var rdiag: gpurify.RunDiagnostic = .{};
    _ = gpurify.run(gpa, arena.allocator(), io, root, .{ .layout = missing, .deck = missing }, .{ .checks = .all }, &.{}, &rdiag) catch |err| switch (err) {
        error.Unreadable, error.Io => return,
        else => return err,
    };
    return error.TestExpectedLoadFailure;
}

test "extraction partitions by touch and accepts an empty design" {
    // Oracle: construct-from-answer. The first two rectangles overlap at x
    // 90..100 and the third is 300 away: two nets. An empty design has no
    // net, device or port.
    var w: Hand = try .init(&.{ .{ 0, 0, 100, 100 }, .{ 90, 0, 200, 100 }, .{ 500, 0, 600, 100 } }, &.{});
    defer w.deinit();
    const ex = try w.extract();
    try testing.expectEqual(2, ex.nets.netCount());
    try testing.expect(ex.nets.sameNet(w.ids.of(w.rects[0]), w.ids.of(w.rects[1])));
    try testing.expect(!ex.nets.sameNet(w.ids.of(w.rects[0]), w.ids.of(w.rects[2])));
    var empty: Hand = try .init(&.{}, &.{});
    defer empty.deinit();
    const none = try empty.extract();
    try testing.expectEqual(0, none.nets.netCount());
    try testing.expectEqual(0, none.devices.len());
    try testing.expectEqual(0, none.ports.len());
}

test "a deck that leaves raw diffusion conducting under a mos marker is refused" {
    // Oracle: `extract`'s documented `ConductingChannel`: `diff` is a
    // conductor and the transistor's source and drain under the `nsdm` marker.
    var arena: std.heap.ArenaAllocator = .init(gpa);
    defer arena.deinit();
    const a = arena.allocator();
    var strings: geom.StrTable = .empty;
    var ddiag: ingest.deck.Diag = .{};
    const d = try ingest.deck.parseDeck(a, a,
        \\grid 1nm
        \\layer diff = gds(65, 20)
        \\layer poly = gds(66, 20)
        \\layer nsdm = gds(93, 44)
        \\connect conductors [diff, poly]
        \\connect touch_within_layer
        \\device mos nsdm model "nfet" terminals [poly, diff, diff]
        \\
    , try .init(1000), &strings, &ddiag);
    var builder: geom.GeometryStoreBuilder = .{};
    for ([_]struct { []const u8, [4]i64 }{ .{ "diff", .{ 0, 0, 500, 200 } }, .{ "poly", .{ 200, -50, 250, 250 } }, .{ "nsdm", .{ -50, -50, 550, 250 } } }) |row| {
        const r = row[1];
        _ = try builder.push(a, d.layers.id(&strings, row[0]).?, &.{ r[0], r[2], r[2], r[0] }, &.{ r[1], r[1], r[3], r[3] });
    }
    var store: geom.GeometryStore = .empty;
    var order: std.ArrayList(u32) = .empty;
    try builder.finish(a, @intCast(d.layers.len()), &store, &order);
    var diag: gpurify.ExtractDiagnostic = .none;
    const provenance: ingest.Provenance = .{};
    try testing.expectError(error.ConductingChannel, gpurify.extractLayout(a, &store, &d, &provenance, &diag));
}

test "a short between labelled nets extracts and intent on it is refused" {
    // Oracle: construct-from-answer, with `runChecks`' doc (a net with two
    // labels keeps both): rectangles 0 and 1 touch, so VDD and VSS on them
    // are one net and ERC refuses intent on it; on 0 and 2 they are two nets
    // and ERC runs (testing-plan F14).
    const intent =
        \\{"domains": {"core": {"voltage_mv": 1800}},
        \\ "supplies": [{"net": "VDD", "domain": "core", "role": "power"},
        \\              {"net": "VSS", "domain": "core", "role": "ground"}]}
    ;
    for ([_]struct { [2]usize, bool }{ .{ .{ 0, 1 }, true }, .{ .{ 0, 2 }, false } }) |row| {
        var w: Hand = try .init(&rails, &.{ .{ row[0][0], "VDD" }, .{ row[0][1], "VSS" } });
        defer w.deinit();
        const ex = try w.extract();
        const net = ex.ports.netOf(w.loaded.strings.get("VDD").?).?;
        try testing.expectEqual(@as(usize, if (row[1]) 2 else 1), ex.ports.namesOf(net).len);
        var idiag: ingest.intent.Diagnostic = .{};
        w.loaded.intent = try ingest.intent.parseIntent(w.alloc(), w.alloc(), intent, &w.loaded.strings, &idiag);
        const s = try w.checks(&ex, .{ .checks = .{ .erc = true } });
        if (row[1]) {
            try testing.expect(std.mem.indexOf(u8, s.summary.erc.refused, "VDD, VSS") != null);
        } else try testing.expect(s.summary.erc == .ran);
    }
}

test "a quasistatic name on two nets is refused" {
    // Oracle: construct-from-answer (testing-plan F14). Rectangles 0 and 2
    // are apart, so `A` names two nets, and the field solve refuses it by
    // name rather than solve one piece.
    var w: Hand = try .init(&rails, &.{ .{ 0, "A" }, .{ 2, "A" } });
    defer w.deinit();
    const ex = try w.extract();
    const s = try w.checks(&ex, .{ .checks = .{ .pex = true }, .quasistatic_nets = &.{"A"} });
    try testing.expect(std.mem.indexOf(u8, s.summary.pex.refused, "A labels 2 disconnected nets") != null);
}

test "a run selecting no check reports four declines and passes" {
    // Oracle: `Summary.passed`'s documented criterion: with nothing selected
    // each stage is not selected, nothing is produced, and the run passes.
    var w: Hand = try .init(&.{}, &.{});
    defer w.deinit();
    const ex = try w.extract();
    const s = try w.checks(&ex, .{});
    for ([_]gpurify.StageStatus{ s.summary.drc, s.summary.erc, s.summary.lvs, s.summary.pex }) |st| try testing.expect(st == .not_selected);
    try testing.expectEqual(0, s.outputs.runs.items.len);
    try testing.expectEqual(0, s.outputs.violations.len());
    try testing.expect(s.outputs.lvs == null and s.outputs.parasitics == null);
    try testing.expect(s.summary.passed());
}

test "lvs is skipped without a reference and a mismatch fails the run with one" {
    // Oracle: docs/usage.md ("a check whose input is missing is reported as
    // skipped, never as passed") and construct-from-answer: a one-transistor
    // reference against an empty layout leaves that device unpaired and
    // nothing on the layout side, each discrepancy an error.
    var w: Hand = try .init(&.{}, &.{});
    defer w.deinit();
    const ex = try w.extract();
    const lvs: gpurify.RunOptions = .{ .checks = .{ .lvs = true } };
    var s = try w.checks(&ex, lvs);
    try testing.expect(s.summary.lvs == .skipped);
    try testing.expect(s.outputs.lvs == null);
    try testing.expect(!s.summary.passed());

    // A deck stating no default parameter tolerance cannot compare.
    var ndiag: ingest.netlist.Diagnostic = .{};
    const read = try ingest.netlist.readSpice(w.alloc(), ".subckt top a b c d\nM1 a b c d nch\n.ends\n", &w.loaded.strings, &w.loaded.deck.deck.devices, &ndiag);
    w.loaded.reference = read;
    try gpurify.internReportIds(w.alloc(), &w.loaded.strings);
    s = try w.checks(&ex, lvs);
    try testing.expect(s.summary.lvs == .refused);
    try testing.expect(s.outputs.lvs == null);

    w.loaded.deck.deck.lvs.default_tolerance = 0.02;
    s = try w.checks(&ex, lvs);
    try testing.expect(s.summary.lvs == .ran);
    // The five layout checks, every one run and clean.
    try testing.expectEqual(5, s.outputs.runs.items.len);
    try testing.expectEqual(5, s.summary.rules_clean);
    try testing.expectEqual(0, s.summary.rules_skipped);
    const traced = s.outputs.lvs.?;
    try testing.expect(traced.verdict == .mismatch);
    var reference_device = false;
    for (traced.found.items) |d| switch (d) {
        .unpaired_device => |u| {
            try testing.expect(u.side == .reference);
            reference_device = reference_device or u.device == 0;
        },
        else => {},
    };
    try testing.expect(reference_device);
    try testing.expectEqual(traced.found.items.len, s.outputs.violations.len());
    try testing.expectEqual(traced.found.items.len, s.summary.errors);
    try testing.expectEqual(0, s.summary.warnings);
    try testing.expect(!s.summary.passed());
}

test "a kind in neither domain is refused when the deck compiles" {
    // Oracle: construct-from-answer: `min_widht` is no kind; `width` and
    // `ir_drop` are one domain's each, so a deck of both compiles.
    var arena: std.heap.ArenaAllocator = .init(gpa);
    defer arena.deinit();
    const a = arena.allocator();
    const text = "grid 1nm\nlayer m = gds(1, 0)\nrule a width(m) >= 10nm\nrule b ir_drop()\n";
    var strings: geom.StrTable = .empty;
    var pdiag: ingest.deck.Diag = .{};
    const both = try ingest.deck.parseDeck(a, a, text, try .init(1000), &strings, &pdiag);
    var cdiag: check.deck.compile.Diag = .{};
    const compiled = try check.deck.compile.fromDeck(a, both, try .init(1000), &strings, &cdiag);
    try testing.expectEqual(1, compiled.drc.len());
    var misspelled = try ingest.deck.parseDeck(a, a, text, try .init(1000), &strings, &pdiag);
    const spec = try a.dupe(ingest.deck.RuleSpec, misspelled.rules.spec);
    spec[0].kind = try strings.intern(a, "min_widht");
    misspelled.rules.spec = spec;
    try testing.expectError(error.UnknownKind, check.deck.compile.fromDeck(a, misspelled, try .init(1000), &strings, &cdiag));
    try testing.expectEqualStrings("min_widht", strings.resolve(cdiag.rule.kind));
}

test "a quasistatic net is solved for inductance too" {
    // Oracle: docs/usage.md's `--quasistatic` ("Field-solve this net's
    // capacitance and inductance"): the analytical run carries no
    // inductance, the field-solved one at least one, and no fewer
    // capacitive elements.
    const none = try countKinds(false);
    const solved = try countKinds(true);
    try testing.expectEqual(0, none[0]);
    try testing.expect(solved[0] >= 1);
    try testing.expect(solved[1] >= none[1]);
}

test "the pass criterion table" {
    // Oracle: `Summary.passed`'s documented criterion, one row per clause:
    // an error, a skipped rule and a skipped or refused stage each fail it;
    // warnings do not, nor does a stage not selected.
    const clean: gpurify.Summary = .{ .drc = .ran, .erc = .ran, .lvs = .ran, .pex = .ran, .violations = 0, .errors = 0, .warnings = 0, .rules_clean = 17, .rules_skipped = 0 };
    var cases: [9]struct { gpurify.Summary, bool } = @splat(.{ clean, true });
    cases[1][0].rules_skipped = 1;
    cases[2][0].violations = 1;
    cases[2][0].errors = 1;
    cases[3][0].violations = 1;
    cases[3][0].warnings = 1;
    cases[4][0].drc = .{ .skipped = "a required input was absent" };
    cases[5][0].erc = .{ .refused = "not rectilinear" };
    cases[6][0].lvs = .{ .skipped = "a required input was absent" };
    cases[7][0].pex = .{ .refused = "not rectilinear" };
    cases[8][0] = .{ .drc = .not_selected, .erc = .not_selected, .lvs = .not_selected, .pex = .not_selected, .violations = 0, .errors = 0, .warnings = 0, .rules_clean = 0, .rules_skipped = 0 };
    for ([_]bool{ true, false, false, true, false, false, false, false, true }, cases) |passes, c| try testing.expectEqual(passes, c[0].passed());
}

test "an nmos bulk on the untapped substrate does not fail lvs" {
    // Oracle: construct-from-answer, on the shipped sky130 deck. One NMOS and
    // no p-tap: its bulk is the substrate under the diffusion (`connect
    // global psub`), a net with no tap and no label; the reference states
    // the bulk on a net of its own, so the NMOS matches and nothing floats.
    var arena: std.heap.ArenaAllocator = .init(gpa);
    defer arena.deinit();
    const r = try sky130Lvs(arena.allocator(), &.{ .{ "diff", 0, 0, 1000, 1000 }, .{ "nsdm", -200, -200, 1200, 1200 }, .{ "poly", 450, -200, 600, 1200 } }, ".subckt top\nM1 d g s b sky130_fd_pr__nfet_01v8\n.ends\n");
    try testing.expect(r.verdict == .match);
    try testing.expectEqual(0, r.rules.len);
}

test "a pmos in an untapped well fails lvs and a tapped one matches" {
    // Oracle: the field report's floating-well strongarm, reduced to one
    // device: with no n-tap the well is a net of its own and LVS must not
    // match (netgen fails the same layout); an n-tap strapped to the source
    // by li matches.
    var arena: std.heap.ArenaAllocator = .init(gpa);
    defer arena.deinit();
    const pmos = [_]Rect{ .{ "nwell", -1500, -500, 1500, 1500 }, .{ "diff", 0, 0, 1000, 1000 }, .{ "psdm", -100, -200, 1200, 1200 }, .{ "poly", 450, -200, 600, 1200 }, .{ "licon", 100, 400, 270, 570 }, .{ "li", 50, 350, 320, 620 } };
    const tap = [_]Rect{ .{ "tap", -1000, 0, -500, 1000 }, .{ "nsdm", -1125, -125, -375, 1125 }, .{ "licon", -850, 400, -680, 570 }, .{ "li", -900, 350, 320, 620 } };
    const reference = ".subckt top\nM1 d g s s sky130_fd_pr__pfet_01v8\n.ends\n";
    try testing.expect((try sky130Lvs(arena.allocator(), &pmos, reference)).verdict != .match);
    try testing.expect((try sky130Lvs(arena.allocator(), &(pmos ++ tap), reference)).verdict == .match);
}

test "a consumer checks each edit against one shared deck" {
    // Oracle: the foundry rule at the limit, sky130 periphery m1.1 and m1.2
    // (met1 width and spacing 0.14 um, pdks/sky130.deck): two met1 wires at
    // the limits break neither; the first narrowed one 5 nm step is one m1.1
    // finding of 135 nm, the gap closed one step one m1.2 finding of 135 nm.
    // And a metamorphic relation (FLOW-005): the shared deck gives each edit
    // the report a fresh deck gives, and undoing an edit gives back the
    // report from before it.
    var arena: std.heap.ArenaAllocator = .init(gpa);
    defer arena.deinit();
    const a = arena.allocator();
    var shared: Consumer = try .init(a);
    const edits = [_][2]i64{ .{ 140, 140 }, .{ 135, 140 }, .{ 140, 140 }, .{ 140, 135 }, .{ 140, 140 } };
    var reports: [edits.len]Consumer.Report = undefined;
    for (edits, &reports) |e, *r| {
        r.* = try shared.edit(a, e[0], e[1]);
        var fresh: Consumer = try .init(a);
        try expectSameLines(r.text, (try fresh.edit(a, e[0], e[1])).text);
    }
    try expectSameLines(reports[0].text, reports[2].text);
    try expectSameLines(reports[0].text, reports[4].text);
    for ([_][]const u8{ "m1.1", "m1.2" }) |rule| {
        const prefix = try std.fmt.allocPrint(a, "{s} ran ", .{rule});
        const ran = for (reports[0].text) |l| (if (std.mem.startsWith(u8, l, prefix)) break true) else false;
        try testing.expect(ran);
    }
    try testing.expectEqual(0, reports[0].count("m1.1") + reports[0].count("m1.2"));
    try testing.expectEqualSlices(i128, &.{135}, try reports[1].of(a, "m1.1"));
    try testing.expectEqual(0, reports[1].count("m1.2"));
    try testing.expectEqual(0, reports[3].count("m1.1"));
    try testing.expectEqualSlices(i128, &.{135}, try reports[3].of(a, "m1.2"));
}

test "a binary's own deck runs its custom rules by name" {
    // Oracle: construct-from-answer (FLOW-006): the cell holds two met1
    // shapes (its golden PEX_COUPLING_C.all reports met1.min_width examined
    // 2), and the rule flags each once; without the binary's decks the same
    // name is a file that does not exist.
    var arena: std.heap.ArenaAllocator = .init(gpa);
    defer arena.deinit();
    const decks = [_]gpurify.NamedDeck{.{ .name = "params-custom", .build = Custom(flagsEach).build }};
    const r = try customRun(arena.allocator(), &decks, "params-custom");
    const row = for (r.outputs.runs.items) |run| (if (std.mem.eql(u8, r.loaded.strings.resolve(run.rule), "met1.custom")) break run) else unreachable;
    try testing.expectEqual(.ran, row.outcome);
    try testing.expectEqual(2, row.examined);
    try testing.expectEqual(2, row.violations);
    try testing.expect(!r.summary.passed());
    try testing.expectError(error.Unreadable, customRun(arena.allocator(), &.{}, "params-custom"));
}

test "the report bytes catch a nondeterministic custom rule" {
    // Oracle: determinism, "determinism survives user code": a deterministic
    // custom rule gives the same report bytes twice; a nondeterministic one
    // does not, so the golden test's run-twice comparison catches it.
    var arena: std.heap.ArenaAllocator = .init(gpa);
    defer arena.deinit();
    const a = arena.allocator();
    const decks = [_]gpurify.NamedDeck{ .{ .name = "flagging", .build = Custom(flagsEach).build }, .{ .name = "nondeterministic", .build = Custom(nondeterministic).build } };
    try testing.expectEqualStrings(try report(a, &decks, "flagging"), try report(a, &decks, "flagging"));
    try testing.expect(!std.mem.eql(u8, try report(a, &decks, "nondeterministic"), try report(a, &decks, "nondeterministic")));
}

test "a pex_device line adds gate to contact and diffusion capacitance" {
    // Oracle: the deck's definition (extract.device_region, catalog PEX-011):
    // with 0.3 and 0.2 aF/µm each nfet side is 0.5 aF/µm · W; the run without
    // the line is the reference, so the difference is exactly
    // Σ 2 · 0.5 · W / 1000 fF over the nfets (only the stated model gains).
    var arena: std.heap.ArenaAllocator = .init(gpa);
    defer arena.deinit();
    const a = arena.allocator();
    const base = try couplingAndWidths(a, "");
    const with = try couplingAndWidths(a, "pex_device \"nfet_01v8\" gate_contact_cap 0.3aF/um gate_diffusion_cap 0.2aF/um");
    try testing.expect(base.widths.len != 0);
    var want: f64 = 0;
    for (base.widths) |wd| {
        try testing.expect(wd.apart);
        want += 2.0 * 0.5 * wd.um / 1000.0;
    }
    try testing.expect(want > 0);
    try testing.expect(@abs((with.coupling - base.coupling) - want) < 1e-12);
}
