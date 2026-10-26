//! Multi-die systems (catalog LVS-073, DRC-129): dies drawn as the LVS
//! enumeration draws a circuit, with bumps wired to their nets' tracks,
//! read back through the real reader, placed and checked by
//! `gpurify.system.checkSystem`; and the hand-derived stacks. Ported from
//! tests/exhaustive/lvs/system.rs (its helpers and the hand-derived stack
//! tests; the brute-force stacks are lvs_system_stacks.zig, ESD
//! lvs_system_esd.zig, and `netgen_cases`, Netgen's live differential, is
//! not ported).
//!
//! - A two-die stack matches, and a missing or a mis-ordered bump does not,
//!   with the rows `system.unbonded_bump`, `system.open` and `system.short`
//!   the definitions give; the same stack under every symmetry of the whole
//!   assembly gives the same rows, moved (a metamorphic relation).
//!
//! Contents:
//! - `pub const deck`, `pub const Bump`, `pub const FaceOf`, `pub const Cell`, `pub const Instance`, `pub const Row`, `pub const RunRow`
//! - `pub const Place = struct`, `apply`, `undo`, `after`
//! - `pub const DieSpec = struct`, `pub const Ran = struct`, `rows`, `of`, `runOf`, `matched`
//! - `pub fn slotCentre(slot: usize) [2]i64`, `pub fn dieLayout(arena, c, bumps) !Layout`
//! - `pub fn die(name, layout) DieSpec`, `pub fn named(arena, names, devs) !Circuit`
//! - `pub fn systemJson(arena, dies, bonds, package, esd) ![]const u8`
//! - `pub fn systemSpice(arena, cells, ports, instances) ![]const u8`
//! - `pub fn checkDies(arena, dies, system, reference, diag) !Ran`, `pub fn ran(arena, dies, system, reference) !Ran`
//! - `pub fn expectRows(got, want) !void`

const std = @import("std");
const Allocator = std.mem.Allocator;
const testing = std.testing;
const geom = @import("geom");
const ingest = @import("ingest");
const check = @import("check");
const report = check.report;
const Measurement = report.Measurement;
const testgen = @import("testgen");
const gpurify = @import("gpurify");
const harness = @import("harness.zig");
const Layout = harness.Layout;
const circuit = @import("lvs_circuit.zig");
const Circuit = circuit.Circuit;
const Dev = circuit.Dev;
const gpa = testing.allocator;

/// The deck of every die: the enumeration's, with two bump faces, `bump`
/// toward the other die and `c4` toward the package, each reached from
/// met1 through its own cut.
pub const deck = circuit.mos_deck ++ circuit.extra_deck ++
    \\layer bump = gds(20, 0)
    \\layer vbump = gds(21, 0)
    \\layer c4 = gds(22, 0)
    \\layer vc4 = gds(23, 0)
    \\connect conductors [bump, c4]
    \\connect via vbump [met1, bump]
    \\connect via vc4 [met1, c4]
    \\
;

/// A bump to draw: a net, its slot, and its face (`bump` or `c4`).
pub const Bump = struct { net: usize, slot: usize, face: []const u8 };

/// A face of a die: `(die, layer)`.
pub const FaceOf = struct { []const u8, []const u8 };

/// A subcircuit of a system netlist: its name and its circuit.
pub const Cell = struct { []const u8, *const Circuit };

/// An instance of a system netlist's top: its name, its cell, its nets.
pub const Instance = struct { []const u8, []const u8, []const []const u8 };

/// A row of the report: rule, where, what it measured.
pub const Row = struct { rule: []const u8, at: [2]i64, measured: Measurement };

/// One rule's run row: outcome, examined, violations.
pub const RunRow = struct { outcome: report.Outcome, examined: u64, violations: u32 };

/// A placement as the system file states it: reflect in x when `mirror`,
/// turn `turns` quarter turns counter-clockwise, move by `(dx, dy)`.
pub const Place = struct {
    mirror: bool = false,
    turns: u8 = 0,
    dx: i64 = 0,
    dy: i64 = 0,

    pub fn apply(p: Place, at: [2]i64) [2]i64 {
        var x = at[0];
        var y = at[1];
        if (p.mirror) y = -y;
        for (0..p.turns) |_| {
            const nx = -y;
            y = x;
            x = nx;
        }
        return .{ x + p.dx, y + p.dy };
    }

    pub fn undo(p: Place, at: [2]i64) [2]i64 {
        var x = at[0] - p.dx;
        var y = at[1] - p.dy;
        for (0..p.turns) |_| {
            const nx = y;
            y = -x;
            x = nx;
        }
        if (p.mirror) y = -y;
        return .{ x, y };
    }

    /// `p` after `before`: one placement doing both, worked out from
    /// `g(p(q)) = R^g M^g (R^p M^p q + d_p) + d_g` and `M R^k = R^-k M`.
    pub fn after(p: Place, before: Place) Place {
        const turns = if (p.mirror) (p.turns + 4 - before.turns) % 4 else (p.turns + before.turns) % 4;
        const d = p.apply(.{ before.dx, before.dy });
        return .{ .mirror = p.mirror != before.mirror, .turns = turns, .dx = d[0], .dy = d[1] };
    }
};

/// One die of a test system.
pub const DieSpec = struct { name: []const u8, layout: Layout, place: Place = .{}, intent: ?[]const u8 = null };

/// What a system run gave, names resolved; everything in its arena.
pub const Ran = struct {
    outputs: gpurify.Outputs,
    summary: gpurify.Summary,
    strings: geom.StrTable,
    arena: Allocator,

    /// Every row, in report order.
    pub fn rows(r: *const Ran) ![]const Row {
        const v = &r.outputs.violations;
        const out = try r.arena.alloc(Row, v.len());
        for (out, 0..) |*o, i| {
            const row = v.get(@intCast(i));
            o.* = .{ .rule = r.strings.resolve(row.rule), .at = .{ row.at.x, row.at.y }, .measured = row.measured };
        }
        return out;
    }

    /// The rows of one rule, sorted by where.
    pub fn of(r: *const Ran, rule: []const u8) ![]const Row {
        var out: std.ArrayList(Row) = .empty;
        for (try r.rows()) |row| if (std.mem.eql(u8, row.rule, rule)) try out.append(r.arena, row);
        std.mem.sort(Row, out.items, {}, lessAt);
        return out.items;
    }

    pub fn runOf(r: *const Ran, rule: []const u8) !RunRow {
        for (r.outputs.runs.items) |run| if (std.mem.eql(u8, r.strings.resolve(run.rule), rule)) return .{ .outcome = run.outcome, .examined = run.examined, .violations = run.violations };
        std.debug.print("no {s} row\n", .{rule});
        return error.TestNoRow;
    }

    pub fn matched(r: *const Ran) !bool {
        const traced = r.outputs.lvs orelse return error.TestNoVerdict;
        return switch (traced.verdict) {
            .match => true,
            .mismatch => false,
            .inconclusive => error.TestNoVerdict,
        };
    }
};

/// `XB` reflected face down, turned a quarter, and moved off the origin.
const flip: Place = .{ .mirror = true, .turns = 1, .dx = 7000, .dy = -3000 };

/// The first bump slot's x; every device the drawer places lies left of it.
const bump_x: i64 = 40_000;

/// The placed centre of bump slot `slot`: slots are 200 nm squares 1000 nm
/// apart on y = 0.
pub fn slotCentre(slot: usize) [2]i64 {
    return .{ bump_x + 1000 * @as(i64, @intCast(slot)) + 100, 100 };
}

/// A circuit drawn, with `bumps`: each a 200 nm bump in its slot on its
/// face, wired to its net's met2 track: the track runs on to the slot, a
/// met1 strap drops from it through `via1` to the bump's cut.
pub fn dieLayout(arena: Allocator, c: *const Circuit, bumps: []const Bump) !Layout {
    var layout = try circuit.draw(arena, c);
    for (bumps) |b| {
        const x = slotCentre(b.slot)[0] - 100;
        const t = circuit.track(b.net);
        const cut = if (std.mem.eql(u8, b.face, "bump")) "vbump" else "vc4";
        try layout.rect(arena, "met2", -1000, t, x + 200, t + 200);
        try layout.rect(arena, "via1", x, t, x + 200, t + 200);
        try layout.rect(arena, "met1", x, 0, x + 200, t + 200);
        try layout.rect(arena, cut, x, 0, x + 200, 200);
        try layout.rect(arena, b.face, x, 0, x + 200, 200);
    }
    return layout;
}

/// A die at the origin, unturned, with no intent.
pub fn die(name: []const u8, layout: Layout) DieSpec {
    return .{ .name = name, .layout = layout };
}

/// A circuit whose nets are named `names`, every one a port.
pub fn named(arena: Allocator, names: []const []const u8, devs: []const Dev) !Circuit {
    const ports = try arena.alloc(bool, names.len);
    @memset(ports, true);
    return .{ .devs = try arena.dupe(Dev, devs), .names = try arena.dupe([]const u8, names), .ports = ports };
}

/// The system file for `dies`, its bonds (two faces each), an optional
/// package face and `esd` section.
pub fn systemJson(arena: Allocator, dies: []const DieSpec, bonds: []const [2]FaceOf, package: ?FaceOf, esd: ?[]const u8) ![]const u8 {
    var out: std.ArrayList(u8) = .empty;
    try out.appendSlice(arena, "{ \"dies\": [");
    for (dies, 0..) |d, i| {
        try out.print(arena, "{s}{{ \"name\": \"{s}\", \"layout\": \"{s}.gds\", \"deck\": \"d.deck\", \"origin_nm\": [{d}, {d}], \"rotate\": {d}, \"mirror\": {} }}", .{ if (i == 0) "" else ", ", d.name, d.name, d.place.dx, d.place.dy, @as(u32, d.place.turns) * 90, d.place.mirror });
    }
    try out.appendSlice(arena, "], \"bonds\": [");
    for (bonds, 0..) |b, i| {
        try out.print(arena, "{s}{{ \"a\": {{ \"die\": \"{s}\", \"layer\": \"{s}\" }}, \"b\": {{ \"die\": \"{s}\", \"layer\": \"{s}\" }} }}", .{ if (i == 0) "" else ", ", b[0][0], b[0][1], b[1][0], b[1][1] });
    }
    try out.append(arena, ']');
    if (package) |p| try out.print(arena, ", \"package\": {{ \"die\": \"{s}\", \"layer\": \"{s}\" }}", .{ p[0], p[1] });
    if (esd) |e| try out.print(arena, ", \"esd\": {s}", .{e});
    try out.appendSlice(arena, " }");
    return out.items;
}

/// A system netlist: one subcircuit per cell, then the top `SYS` with
/// `ports`, placing each instance of its cell on its nets.
pub fn systemSpice(arena: Allocator, cells: []const Cell, ports: []const []const u8, instances: []const Instance) ![]const u8 {
    var out: std.ArrayList(u8) = .empty;
    try out.appendSlice(arena, "* generated by tests/exhaustive/lvs/system.rs\n");
    for (cells) |cell| {
        const order = try arena.alloc(usize, cell[1].devs.len);
        for (order, 0..) |*o, i| o.* = i;
        try circuit.subcktInto(arena, &out, cell[0], cell[1], order);
        try out.appendSlice(arena, ".ends\n");
    }
    try out.print(arena, ".subckt SYS {s}\n", .{try std.mem.join(arena, " ", ports)});
    for (instances) |inst| try out.print(arena, "{s} {s} {s}\n", .{ inst[0], try std.mem.join(arena, " ", inst[2]), inst[1] });
    try out.appendSlice(arena, ".ends\n");
    return out.items;
}

/// The dies read back into one table and checked against `reference`; a
/// refusal's reason is `diag.why`.
pub fn checkDies(arena: Allocator, dies: []const DieSpec, system: []const u8, reference: []const u8, diag: *gpurify.system.Diagnostic) !Ran {
    var strings: geom.StrTable = .empty;
    const read = try arena.alloc(gpurify.Die, dies.len);
    const intents = try arena.alloc(?ingest.intent.DesignIntent, dies.len);
    for (dies, read, intents) |d, *r, *intent| {
        var load_diag: gpurify.LoadDiagnostic = .{};
        r.* = try gpurify.readDie(arena, try written(arena, &d.layout), deck, "system.deck", &strings, &load_diag);
        intent.* = null;
        if (d.intent) |text| {
            var intent_diag: ingest.intent.Diagnostic = .{};
            intent.* = try ingest.intent.parseIntent(arena, arena, text, &strings, &intent_diag);
        }
    }
    var system_diag: ingest.system.Diagnostic = .{};
    const spec = try ingest.system.parseSystem(arena, system, "", &system_diag);
    const models = try gpurify.system.allModels(arena, read);
    var netlist_diag: ingest.netlist.Diagnostic = .{};
    const netlist = try gpurify.reference.readReferenceText(arena, reference, false, &models, &strings, &netlist_diag);
    var out: Ran = .{ .outputs = .{}, .summary = undefined, .strings = undefined, .arena = arena };
    out.summary = try gpurify.system.checkSystem(gpa, arena, &spec, read, intents, &netlist, &strings, &out.outputs, diag);
    out.strings = strings;
    return out;
}

/// `checkDies`, printing the reason of a refusal.
pub fn ran(arena: Allocator, dies: []const DieSpec, system: []const u8, reference: []const u8) !Ran {
    var diag: gpurify.system.Diagnostic = .{};
    return checkDies(arena, dies, system, reference, &diag) catch |err| {
        std.debug.print("not an assembly: {t}: {s}\n", .{ err, diag.why });
        return err;
    };
}

/// `got` is `want`, place for place and measure for measure.
pub fn expectRows(got: []const Row, want: []const Row) !void {
    errdefer for (got) |g| std.debug.print("got {s} ({d}, {d}) {f}\n", .{ g.rule, g.at[0], g.at[1], g.measured });
    try testing.expectEqual(want.len, got.len);
    for (got, want) |g, w| {
        try testing.expectEqualStrings(w.rule, g.rule);
        try testing.expectEqual(w.at, g.at);
        try testing.expect(g.measured.eql(w.measured));
    }
}

// ---- private ----

fn lessAt(_: void, a: Row, b: Row) bool {
    return a.at[0] < b.at[0] or (a.at[0] == b.at[0] and a.at[1] < b.at[1]);
}

/// A flat die layout as GDSII on `deck`'s layers (parsed on 1 nm).
fn written(arena: Allocator, layout: *const Layout) ![]const u8 {
    var strings: geom.StrTable = .empty;
    var diag: ingest.deck.Diag = .{};
    const d = try ingest.deck.parseDeck(arena, arena, deck, try .init(1000), &strings, &diag);
    std.debug.assert(layout.cells.items.len == 0 and layout.instances.items.len == 0); // a flat die
    var lb: testgen.shapes.LayoutBuilder = .init(@intCast(d.layers.len()));
    for (layout.shapes.items) |sh| {
        const xs = try arena.alloc(i64, sh.points.len);
        const ys = try arena.alloc(i64, sh.points.len);
        for (sh.points, xs, ys) |p, *x, *y| {
            x.* = p[0];
            y.* = p[1];
        }
        _ = try lb.push(arena, @backingInt(d.layers.id(&strings, sh.layer).?), xs, ys);
    }
    var store: geom.GeometryStore = .empty;
    var ids: testgen.shapes.Ids = .{};
    try lb.finish(arena, &store, &ids);
    const labels = try arena.alloc(testgen.gds.Label, layout.labels.items.len);
    for (layout.labels.items, labels) |t, *o| o.* = .{ .layer = d.layers.id(&strings, t.layer).?, .x = t.x, .y = t.y, .text = t.text };
    var bytes: std.ArrayList(u8) = .empty;
    try testgen.gds.writeStoreLabelled(arena, &store, &d.layers, labels, "TOP", &bytes);
    return bytes.items;
}

/// `layout` drawn so that `place` puts it back where it was: every point
/// through `Place.undo`, a reflected outline reversed to stay
/// counter-clockwise. The drawer draws one flat cell, with no instances.
fn unplaced(arena: Allocator, layout: *const Layout, place: Place) !Layout {
    std.debug.assert(layout.cells.items.len == 0 and layout.instances.items.len == 0); // a flat die
    var out: Layout = .{};
    for (layout.shapes.items) |sh| {
        const points = try arena.alloc([2]i64, sh.points.len);
        for (points, 0..) |*p, i| p.* = place.undo(sh.points[if (place.mirror) sh.points.len - 1 - i else i]);
        try out.shapes.append(arena, .{ .layer = sh.layer, .points = points });
    }
    for (layout.labels.items) |t| {
        const p = place.undo(.{ t.x, t.y });
        try out.label(arena, t.layer, p[0], p[1], t.text);
    }
    return out;
}

/// Die `XA`: an inverter from `in` to `out`. Die `XB`: an inverter from
/// `a` to `q`. `XA.out` drives `XB.a` through bump slot 0; `vss` and `vdd`
/// meet in slots 1 and 2. Returns both circuits and the system netlist.
fn inverters(arena: Allocator) !struct { Circuit, Circuit, []const u8 } {
    const a = try named(arena, &.{ "in", "out", "vss", "vdd" }, &.{ Dev.mos(.n, 0, 2, 1), Dev.mos(.p, 0, 3, 1) });
    const b = try named(arena, &.{ "a", "q", "vss", "vdd" }, &.{ Dev.mos(.n, 0, 2, 1), Dev.mos(.p, 0, 3, 1) });
    const reference = try systemSpice(arena, &.{ .{ "INV_A", &a }, .{ "INV_B", &b } }, &.{ "in", "q", "vss", "vdd" }, &.{
        .{ "XA", "INV_A", &.{ "in", "mid", "vss", "vdd" } },
        .{ "XB", "INV_B", &.{ "mid", "q", "vss", "vdd" } },
    });
    return .{ a, b, reference };
}

/// `XA` and `XB` bonded face to face, `XB` drawn so that `place` puts its
/// bumps on `XA`'s; `b_slots` gives `XB`'s slot for `a`, `vss` and `vdd`
/// (null leaves the bump out). Returns the dies and the system file.
fn inverterStack(arena: Allocator, place: Place, b_slots: [3]?usize) !struct { []DieSpec, []const u8 } {
    const a, const b, _ = try inverters(arena);
    const top = try dieLayout(arena, &a, &.{ .{ .net = 1, .slot = 0, .face = "bump" }, .{ .net = 2, .slot = 1, .face = "bump" }, .{ .net = 3, .slot = 2, .face = "bump" } });
    var bumps: std.ArrayList(Bump) = .empty;
    for ([_]usize{ 0, 2, 3 }, b_slots) |net, slot| if (slot) |s| try bumps.append(arena, .{ .net = net, .slot = s, .face = "bump" });
    const bottom: DieSpec = .{ .name = "XB", .layout = try unplaced(arena, &try dieLayout(arena, &b, bumps.items), place), .place = place };
    const dies = try arena.dupe(DieSpec, &.{ die("XA", top), bottom });
    return .{ dies, try systemJson(arena, dies, &.{.{ .{ "XA", "bump" }, .{ "XB", "bump" } }}, null, null) };
}

/// The eight symmetries of the square, each with a move.
fn symmetries() [8]Place {
    var out: [8]Place = undefined;
    for (&out, 0..) |*p, k| p.* = .{ .mirror = k >= 4, .turns = @intCast(k % 4), .dx = 11_000 * @as(i64, @intCast(k)), .dy = -5_000 };
    return out;
}

fn lessRow(_: void, a: Row, b: Row) bool {
    return switch (std.mem.order(u8, a.rule, b.rule)) {
        .lt => true,
        .gt => false,
        .eq => lessAt({}, a, b),
    };
}

/// `XB` placed `e` further along x, with the system file's bond limits.
fn ranAt(a: Allocator, place: Place, e: i64, max: []const u8, space: []const u8, reference: []const u8) !Ran {
    const dies, _ = try inverterStack(a, place, .{ 0, 1, 2 });
    dies[1].place.dx += e;
    const system = try systemJson(a, dies, &.{.{ .{ "XA", "bump" }, .{ "XB", "bump" } }}, null, null);
    const limited = try std.mem.replaceOwned(u8, a, system, "\"layer\": \"bump\" } }", try std.fmt.allocPrint(a, "\"layer\": \"bump\" }}, \"max_offset_nm\": {s}, \"min_space_nm\": {s} }}", .{ max, space }));
    return ran(a, dies, limited, reference);
}

test "a two die stack matches and a missing or misordered bump does not" {
    // Catalog LVS-073: system LVS across dies.
    // Oracle: hand-derived from the system netlist and the bumps drawn (the
    // definitions in system_checks.zig). Correct: every bump bonds, every
    // pin is where the netlist puts it, and the flat circuits are the same,
    // so a match with no row. `XB.a`'s bump left out: `XA.out`'s bump (slot
    // 0) bonds nothing, the netlist's net `mid` is in two pieces (an open at
    // `XB.a`, which has no bump, so at the origin), and `XB`'s inverter
    // input floats: a mismatch. `XB.a` and `XB.vss` swapped (slots 1 and 0):
    // `XA.out` lands on `XB.vss` and `XA.vss` on `XB.a`, so `mid` and `vss`
    // are each split (two opens, at `XB.a`'s and `XB.vss`'s bumps) and each
    // assembled net joins two netlist nets (two shorts, at the second pin of
    // each, `XB.vss` and `XB.a`), and `XA` now drives `XB`'s source rail: a
    // mismatch.
    var state: std.heap.ArenaAllocator = .init(gpa);
    defer state.deinit();
    const a = state.allocator();
    _, _, const reference = try inverters(a);
    const count = Measurement.count;

    const good_dies, const good_system = try inverterStack(a, flip, .{ 0, 1, 2 });
    const good = try ran(a, good_dies, good_system, reference);
    try testing.expect(try good.matched());
    try expectRows(try good.rows(), &.{});
    try testing.expectEqual(RunRow{ .outcome = .ran, .examined = 6, .violations = 0 }, try good.runOf("system.unbonded_bump"));
    try testing.expectEqual(RunRow{ .outcome = .ran, .examined = 8, .violations = 0 }, try good.runOf("system.open"));
    try testing.expect(good.summary.passed());

    const missing_dies, const missing_system = try inverterStack(a, flip, .{ null, 1, 2 });
    const missing = try ran(a, missing_dies, missing_system, reference);
    try testing.expect(!try missing.matched());
    try expectRows(try missing.of("system.unbonded_bump"), &.{.{ .rule = "system.unbonded_bump", .at = slotCentre(0), .measured = count(0) }});
    try expectRows(try missing.of("system.open"), &.{.{ .rule = "system.open", .at = .{ 0, 0 }, .measured = count(2) }});
    try expectRows(try missing.of("system.short"), &.{});
    try testing.expect(!missing.summary.passed());

    const swapped_dies, const swapped_system = try inverterStack(a, flip, .{ 1, 0, 2 });
    const swapped = try ran(a, swapped_dies, swapped_system, reference);
    try testing.expect(!try swapped.matched());
    try expectRows(try swapped.of("system.unbonded_bump"), &.{});
    try expectRows(try swapped.of("system.open"), &.{ .{ .rule = "system.open", .at = slotCentre(0), .measured = count(2) }, .{ .rule = "system.open", .at = slotCentre(1), .measured = count(2) } });
    try expectRows(try swapped.of("system.short"), &.{ .{ .rule = "system.short", .at = slotCentre(0), .measured = count(2) }, .{ .rule = "system.short", .at = slotCentre(1), .measured = count(2) } });
}

test "bumps off their mates or near another die's bumps are found" {
    // Catalog DRC-129: inter-die alignment and cross-die spacing, with the
    // limits the system file states (`max_offset_nm`, `min_space_nm`; no
    // public source states them).
    // Oracle: hand-derived from the drawn bumps (200 nm squares 1000 nm
    // apart): `XB` placed `e` = 49, 50, 51 nm further along x than its
    // bumps' mates (still bonded) against a 50 nm offset: three
    // `system.bump_offset` rows of 51 at e = 51, each at the middle of the
    // two centres (25 past `XA`'s, floored), none below; aligned, the 800 nm
    // between a bump and its neighbour's mate against a space of 799, 800,
    // 801: four `system.bump_space` rows of 800 at 801 (slots 0 and 1, 1 and
    // 2, both ways), at the middle of the gap, none at or below 800; and no
    // row at all when the file states neither limit. Metamorphic: `XB`
    // placed unturned rather than flipped gives the same rows.
    var state: std.heap.ArenaAllocator = .init(gpa);
    defer state.deinit();
    const a = state.allocator();
    _, _, const reference = try inverters(a);
    // Metamorphic: placing XB unturned instead of flipped moves no row.
    try expectRows(try (try ranAt(a, .{}, 51, "50", "801", reference)).rows(), try (try ranAt(a, flip, 51, "50", "801", reference)).rows());
    for ([_]i64{ 49, 50, 51 }) |e| {
        const off = try ranAt(a, flip, e, "50", "0", reference);
        var want: std.ArrayList(Row) = .empty;
        if (e > 50) for (0..3) |slot| {
            const c = slotCentre(slot);
            try want.append(a, .{ .rule = "system.bump_offset", .at = .{ c[0] + @divTrunc(e, 2), c[1] }, .measured = .length(e) });
        };
        try expectRows(try off.of("system.bump_offset"), want.items);
        try testing.expectEqual(RunRow{ .outcome = .ran, .examined = 3, .violations = @intCast(want.items.len) }, try off.runOf("system.bump_offset"));
    }
    for ([_]i64{ 799, 800, 801 }) |space| {
        const near = try ranAt(a, flip, 0, "1000", try std.fmt.allocPrint(a, "{d}", .{space}), reference);
        var want: std.ArrayList(Row) = .empty;
        if (space > 800) for ([_]usize{ 0, 0, 1, 1 }) |left| {
            try want.append(a, .{ .rule = "system.bump_space", .at = .{ slotCentre(left)[0] + 500, 100 }, .measured = .length(800) });
        };
        try expectRows(try near.of("system.bump_space"), want.items);
        try expectRows(try near.of("system.bump_offset"), &.{});
    }
    const dies, const system = try inverterStack(a, flip, .{ 0, 1, 2 });
    const plain = try ran(a, dies, system, reference);
    for (plain.outputs.runs.items) |run| try testing.expect(!std.mem.startsWith(u8, plain.strings.resolve(run.rule), "system.bump_"));
}

test "placing the whole assembly anywhere changes nothing" {
    // Oracle: metamorphic. Placing the whole mis-ordered stack under any
    // symmetry of the square and a move (every die's placement composed
    // with it) bonds the same bumps, so it gives the same verdict and the
    // same rows, each system row moved with the assembly.
    var state: std.heap.ArenaAllocator = .init(gpa);
    defer state.deinit();
    const a = state.allocator();
    _, _, const reference = try inverters(a);
    const slots: [3]?usize = .{ 1, 0, 2 };
    const base_dies, const base_system = try inverterStack(a, flip, slots);
    const base = try ran(a, base_dies, base_system, reference);
    for (symmetries()) |g| {
        const dies, _ = try inverterStack(a, flip, slots);
        for (dies) |*d| d.place = g.after(d.place);
        const system = try systemJson(a, dies, &.{.{ .{ "XA", "bump" }, .{ "XB", "bump" } }}, null, null);
        const moved = try ran(a, dies, system, reference);
        try testing.expectEqual(try base.matched(), try moved.matched());
        const want = try a.dupe(Row, try base.rows());
        for (want) |*w| if (std.mem.startsWith(u8, w.rule, "system.")) {
            w.at = g.apply(w.at);
        };
        const have = try a.dupe(Row, try moved.rows());
        std.mem.sort(Row, want, {}, lessRow);
        std.mem.sort(Row, have, {}, lessRow);
        try expectRows(have, want);
    }
}

test "composed placements are one then the other" {
    // Oracle: hand-derived. `Place.after` composes as its doc comment
    // derives: for every pair of symmetries and a point, placing by the
    // composite is placing by one, then the other; and `undo` inverts
    // `apply`.
    const p: [2]i64 = .{ 123, -45 };
    for (symmetries()) |g| {
        try testing.expectEqual(p, g.undo(g.apply(p)));
        for (symmetries()) |h| try testing.expectEqual(g.apply(h.apply(p)), g.after(h).apply(p));
    }
}
