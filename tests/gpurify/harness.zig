//! The exhaustive fixture type, the run, and the comparison every domain
//! file shares. Ported from tests/exhaustive/harness.rs.
//!
//! A `Fixture` is everything one run needs and everything it must report:
//! a deck, a layout drawn in nanometres (flat, or a GDSII hierarchy of
//! rectangles under `TOP`), an optional reference netlist (with Verilog
//! over it) and design intent, the catalog rows it proves, and its claims.
//! A claim is derived from the rule's definition (the deck language, the
//! doc comments, the foundry rule), never from a run of the tool. Each
//! fixture runs through the real reader and engine: the layout written as
//! GDSII, deck, reference and intent written beside it in a scratch
//! directory, and `gpurify.run` over the files, exactly as the CLI runs
//! them. Every parasitic network is also held to passivity (C6). Every
//! fixture lives in the caller's arena.
//!
//! Contents:
//! - `pub const Depth`, `pub const Shape`, `pub const Text`, `pub const Instance`, `pub const Cell`
//! - `pub const Layout = struct`, `rect`, `polygon`, `label`, `cell`, `place`, `transformed`
//! - `pub const Symmetry = struct`, `Symmetry.all`, `identity`, `apply`, `then`, `gds`, `name`
//! - `pub const Want`, `pub const Finding = struct`, `length`, `area`, `any`, `pinned`
//! - `pub const Quantity`, `pub const RuleClaim`, `pub const Expect = union(enum)`, `rule`, `clean`, `outcome`, `examined`
//! - `pub const Fixture = struct`, `init`, `claim`, `transformed`, `everySymmetryInto`
//! - `pub const none: Checks`, `pub const drc: Checks`
//! - `pub fn run(arena: Allocator, f: *const Fixture) !gpurify.Run`
//! - `pub fn brokenInto(arena: Allocator, f: *const Fixture, ran_in: anyerror!gpurify.Run, out: *std.ArrayList([]const u8)) !void`
//! - `pub fn parasiticTotal(r: *const gpurify.Run, net: []const u8, quantity: Quantity) ?f64`
//! - `pub fn check(arena: Allocator, f: *const Fixture) !?[]const u8`
//! - `pub fn checkAll(fixtures: []const Fixture) !void`
//! - `pub fn same(a: Measurement, b: Measurement) bool`
//! - `pub fn written(arena: Allocator, deck: []const u8, layout: *const Layout) ![]const u8`
//! - `Listed.format`, `Wanted.format`: failure messages

const std = @import("std");
const Allocator = std.mem.Allocator;
const testing = std.testing;
const geom = @import("geom");
const ingest = @import("ingest");
const check_ = @import("check");
const report = check_.report;
const Measurement = report.Measurement;
const extract_ = @import("extract");
const ParasiticNetwork = extract_.network.ParasiticNetwork;
const NodeId = extract_.network.NodeId;
const testgen = @import("testgen");
const gpurify = @import("gpurify");
const Checks = gpurify.Checks;
const gpa = testing.allocator;
const io = testing.io;

/// How much to generate: the merge gate's share, or the nightly's (every
/// enumeration in full, run under `-Dslow-tests`).
pub const Depth = enum { merge, nightly };

/// One polygon on a deck layer name, counter-clockwise, at least three
/// vertices, in nanometres.
pub const Shape = struct { layer: []const u8, points: []const [2]i64 };

/// A text label naming the net under it.
pub const Text = struct { layer: []const u8, x: i64, y: i64, text: []const u8 };

/// A placement: the cell's points under `orientation`, then moved.
pub const Instance = struct { cell: []const u8, orientation: Symmetry, dx: i64, dy: i64 };

/// A cell a layout (or a cell below it) may place, in its own frame.
pub const Cell = struct { name: []const u8, layout: Layout };

/// A layout; with neither instances nor cells it is written as one flat
/// cell, else as a GDSII hierarchy under `TOP` (rectangles only). Built in
/// place in an arena, then copied by value into a fixture and not mutated.
pub const Layout = struct {
    shapes: std.ArrayList(Shape) = .empty,
    labels: std.ArrayList(Text) = .empty,
    instances: std.ArrayList(Instance) = .empty,
    cells: std.ArrayList(Cell) = .empty,

    /// Adds an axis-aligned rectangle, counter-clockwise from its lower
    /// left corner.
    pub fn rect(l: *Layout, arena: Allocator, layer: []const u8, xlo: i64, ylo: i64, xhi: i64, yhi: i64) Allocator.Error!void {
        std.debug.assert(xlo < xhi and ylo < yhi);
        try l.polygon(arena, layer, &.{ .{ xlo, ylo }, .{ xhi, ylo }, .{ xhi, yhi }, .{ xlo, yhi } });
    }

    /// Adds a polygon, counter-clockwise; the points are copied.
    pub fn polygon(l: *Layout, arena: Allocator, layer: []const u8, points: []const [2]i64) Allocator.Error!void {
        try l.shapes.append(arena, .{ .layer = layer, .points = try arena.dupe([2]i64, points) });
    }

    pub fn label(l: *Layout, arena: Allocator, layer: []const u8, x: i64, y: i64, text: []const u8) Allocator.Error!void {
        try l.labels.append(arena, .{ .layer = layer, .x = x, .y = y, .text = text });
    }

    /// Defines a cell this layout, or a cell below it, may place.
    pub fn cell(l: *Layout, arena: Allocator, name: []const u8, layout: Layout) Allocator.Error!void {
        try l.cells.append(arena, .{ .name = name, .layout = layout });
    }

    pub fn place(l: *Layout, arena: Allocator, name: []const u8, orientation: Symmetry, dx: i64, dy: i64) Allocator.Error!void {
        try l.instances.append(arena, .{ .cell = name, .orientation = orientation, .dx = dx, .dy = dy });
    }

    /// The layout under one of the eight symmetries, then translated;
    /// outlines stay counter-clockwise, each placement composes with the
    /// transform, and a cell's own frame is untouched.
    pub fn transformed(l: *const Layout, arena: Allocator, s: Symmetry, dx: i64, dy: i64) Allocator.Error!Layout {
        var out: Layout = .{ .cells = l.cells };
        for (l.shapes.items) |sh| {
            const points = try arena.alloc([2]i64, sh.points.len);
            for (points, 0..) |*p, i| {
                const q = s.apply(sh.points[if (s.mirror) sh.points.len - 1 - i else i]);
                p.* = .{ q[0] + dx, q[1] + dy };
            }
            try out.shapes.append(arena, .{ .layer = sh.layer, .points = points });
        }
        for (l.labels.items) |t| {
            const p = s.apply(.{ t.x, t.y });
            try out.labels.append(arena, .{ .layer = t.layer, .x = p[0] + dx, .y = p[1] + dy, .text = t.text });
        }
        for (l.instances.items) |inst| {
            const p = s.apply(.{ inst.dx, inst.dy });
            try out.instances.append(arena, .{ .cell = inst.cell, .orientation = inst.orientation.then(s), .dx = p[0] + dx, .dy = p[1] + dy });
        }
        return out;
    }
};

/// One of the eight symmetries of the square: counter-clockwise quarter
/// turns, then an optional mirror of x.
pub const Symmetry = struct {
    turns: u8,
    mirror: bool,

    /// All eight, identity first.
    pub const all = [8]Symmetry{
        .{ .turns = 0, .mirror = false }, .{ .turns = 1, .mirror = false }, .{ .turns = 2, .mirror = false }, .{ .turns = 3, .mirror = false },
        .{ .turns = 0, .mirror = true },  .{ .turns = 1, .mirror = true },  .{ .turns = 2, .mirror = true },  .{ .turns = 3, .mirror = true },
    };
    pub const identity = all[0];

    pub fn apply(s: Symmetry, p: [2]i64) [2]i64 {
        var x = p[0];
        var y = p[1];
        for (0..s.turns) |_| {
            const nx = -y;
            y = x;
            x = nx;
        }
        if (s.mirror) x = -x;
        return .{ x, y };
    }

    /// `s`, then `outer`: the one of the eight mapping both unit vectors
    /// as the two in turn do.
    pub fn then(s: Symmetry, outer: Symmetry) Symmetry {
        const ex = outer.apply(s.apply(.{ 1, 0 }));
        const ey = outer.apply(s.apply(.{ 0, 1 }));
        for (all) |c| if (std.mem.eql(i64, &c.apply(.{ 1, 0 }), &ex) and std.mem.eql(i64, &c.apply(.{ 0, 1 }), &ey)) return c;
        unreachable; // the eight are closed under composition
    }

    /// As a GDSII placement: `STRANS` reflects about the x axis before the
    /// quarter turns. A mirror in y after `t` turns is the reflection
    /// followed by `2 - t` turns, since `x → -x` is a half turn after
    /// `y → -y`, and a reflection reverses the turns it passes.
    pub fn gds(s: Symmetry) struct { bool, u2 } {
        return if (s.mirror) .{ true, @intCast((6 - s.turns) % 4) } else .{ false, @intCast(s.turns) };
    }

    /// `r0`, `r90`, `m180`, ...
    pub fn name(s: Symmetry, arena: Allocator) Allocator.Error![]const u8 {
        return std.fmt.allocPrint(arena, "{s}{d}", .{ if (s.mirror) "m" else "r", @as(u32, s.turns) * 90 });
    }
};

/// What a rule's row must say: `ran`, `skipped` for any reason, `refused`.
pub const Want = enum { ran, skipped, refused };

/// One finding a rule must report: its measured value (exact for lengths,
/// areas and counts) and its marker in nm (moved with the layout), either
/// unpinned.
pub const Finding = struct {
    measured: ?Measurement,
    at: ?[2]i64,

    pub fn length(nm: i64) Finding {
        return .{ .measured = .length(nm), .at = null };
    }

    pub fn area(nm2: i128) Finding {
        return .{ .measured = .area(nm2), .at = null };
    }

    /// A finding with nothing pinned but its existence.
    pub fn any() Finding {
        return .{ .measured = null, .at = null };
    }

    /// The finding with its marker pinned.
    pub fn pinned(f: Finding, x: i64, y: i64) Finding {
        return .{ .measured = f.measured, .at = .{ x, y } };
    }
};

/// A parasitic quantity of one net: resistance (Ω), ground capacitance
/// (fF), inductance (pH), or the mutuals on either of its ends (pH).
pub const Quantity = enum { resistance, ground_cap, inductance, mutual };

/// A rule's row: its outcome, exactly these findings in any order, and
/// (when the definition fixes it) its examined count: a clean row from a
/// rule that examined nothing is not a clean layout.
pub const RuleClaim = struct { id: []const u8, outcome: Want, findings: []const Finding, examined: ?u64 };

/// One claim about the run.
pub const Expect = union(enum) {
    /// A rule's row and findings.
    row: RuleClaim,
    /// The LVS verdict: matched, or not.
    lvs: bool,
    /// A parasitic total on a labelled net, within a relative tolerance.
    parasitic: struct { net: []const u8, quantity: Quantity, value: f64, rel: f64 },
    /// Whether the whole run passes.
    passes: bool,

    /// A rule that runs and finds exactly `found` (copied by `claim`).
    pub fn rule(id: []const u8, found: []const Finding) Expect {
        return .{ .row = .{ .id = id, .outcome = .ran, .findings = found, .examined = null } };
    }

    pub fn clean(id: []const u8) Expect {
        return rule(id, &.{});
    }

    /// A rule that records `want` and finds nothing.
    pub fn outcome(id: []const u8, want: Want) Expect {
        return .{ .row = .{ .id = id, .outcome = want, .findings = &.{}, .examined = null } };
    }

    /// This rule claim, also claiming exactly `count` items examined; a
    /// symmetry or translation keeps the count. Asserts a rule claim.
    pub fn examined(e: Expect, count: u64) Expect {
        var out = e.row;
        out.examined = count;
        return .{ .row = out };
    }
};

/// One run's inputs and what it must report.
pub const Fixture = struct {
    /// Unique and path-like: `min_width/l_shape/below/r90`.
    name: []const u8,
    /// The catalog rows (tests/check-catalog.tsv) this fixture proves.
    catalog: []const []const u8,
    deck: []const u8,
    layout: Layout = .{},
    /// SPICE text for LVS.
    reference: ?[]const u8 = null,
    /// Structural Verilog read over `reference` as its cell library.
    verilog: []const []const u8 = &.{},
    /// Design-intent JSON for the intent-gated ERC rules.
    intent: ?[]const u8 = null,
    /// A simulator's terminal currents (`espice-emir/1`), placed through LVS.
    currents: ?[]const u8 = null,
    /// Nets to field-solve.
    quasistatic: []const []const u8 = &.{},
    checks: Checks,
    expect: std.ArrayList(Expect) = .empty,
    /// A finding (`"F18"`) that makes this fixture fail today; one that
    /// holds is reported, so a fix is recorded rather than unnoticed.
    known: ?[]const u8 = null,

    pub fn init(name: []const u8, catalog: []const []const u8, deck: []const u8, checks: Checks) Fixture {
        return .{ .name = name, .catalog = catalog, .deck = deck, .checks = checks };
    }

    /// Adds a claim, copying a rule claim's findings into `arena`.
    pub fn claim(f: *Fixture, arena: Allocator, e: Expect) Allocator.Error!void {
        var owned = e;
        switch (owned) {
            .row => |*r| r.findings = try arena.dupe(Finding, r.findings),
            .lvs, .parasitic, .passes => {},
        }
        try f.expect.append(arena, owned);
    }

    /// The fixture under `s` and a translation; every pinned marker moves
    /// with it (a rule's numbers are invariant under these).
    pub fn transformed(f: *const Fixture, arena: Allocator, s: Symmetry, dx: i64, dy: i64) Allocator.Error!Fixture {
        var out = f.*;
        const offset = if (dx == 0 and dy == 0) "" else try std.fmt.allocPrint(arena, "+({d},{d})", .{ dx, dy });
        out.name = try std.fmt.allocPrint(arena, "{s}/{s}{s}", .{ f.name, try s.name(arena), offset });
        out.layout = try f.layout.transformed(arena, s, dx, dy);
        out.expect = .empty;
        for (f.expect.items) |e| {
            var moved = e;
            switch (moved) {
                .row => |*r| {
                    const found = try arena.dupe(Finding, r.findings);
                    for (found) |*fd| if (fd.at) |at| {
                        const p = s.apply(at);
                        fd.at = .{ p[0] + dx, p[1] + dy };
                    };
                    r.findings = found;
                },
                .lvs, .parasitic, .passes => {},
            }
            try out.expect.append(arena, moved);
        }
        return out;
    }

    /// The fixture under all eight symmetries, each also translated.
    pub fn everySymmetryInto(f: *const Fixture, arena: Allocator, dx: i64, dy: i64, out: *std.ArrayList(Fixture)) Allocator.Error!void {
        for (Symmetry.all) |s| try out.append(arena, try f.transformed(arena, s, dx, dy));
    }
};

pub const none: Checks = .{};

/// DRC alone.
pub const drc: Checks = .{ .drc = true };

/// Findings as `measured at (x, y)`, for a failure message.
const Listed = struct {
    rows: []const report.Violation,

    pub fn format(l: Listed, w: *std.Io.Writer) std.Io.Writer.Error!void {
        try w.writeAll("[");
        for (l.rows, 0..) |v, i| try w.print("{s}{f} at ({d}, {d})", .{ if (i > 0) ", " else "", v.measured, v.at.x, v.at.y });
        try w.writeAll("]");
    }
};

/// A claimed finding as `measured at (x, y)`, either part `any`.
const Wanted = struct {
    f: Finding,

    pub fn format(x: Wanted, w: *std.Io.Writer) std.Io.Writer.Error!void {
        if (x.f.measured) |m| try w.print("{f}", .{m}) else try w.writeAll("any");
        if (x.f.at) |p| try w.print(" at ({d}, {d})", .{ p[0], p[1] });
    }
};

/// Runs a fixture through the real reader and engine; the run lives in
/// `arena`. An error is a stage that refused the inputs.
pub fn run(arena: Allocator, f: *const Fixture) !gpurify.Run {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const dir = tmp.dir;
    try dir.writeFile(io, .{ .sub_path = "fixture.deck", .data = f.deck });
    try dir.writeFile(io, .{ .sub_path = "fixture.gds", .data = try written(arena, f.deck, &f.layout) });
    var refs: std.ArrayList([]const u8) = .empty;
    if (f.reference) |text| {
        try dir.writeFile(io, .{ .sub_path = "ref.spice", .data = text });
        try refs.append(arena, "ref.spice");
    }
    for (f.verilog, 0..) |text, i| {
        const path = try std.fmt.allocPrint(arena, "lib{d}.v", .{i});
        try dir.writeFile(io, .{ .sub_path = path, .data = text });
        try refs.append(arena, path);
    }
    var inputs: gpurify.Inputs = .{ .layout = "fixture.gds", .deck = "fixture.deck", .reference = refs.items };
    if (f.intent) |text| {
        try dir.writeFile(io, .{ .sub_path = "intent.json", .data = text });
        inputs.intent = "intent.json";
    }
    if (f.currents) |text| {
        try dir.writeFile(io, .{ .sub_path = "currents.json", .data = text });
        inputs.currents = "currents.json";
    }
    var diag: gpurify.RunDiagnostic = .{};
    return gpurify.run(gpa, arena, io, dir, inputs, .{ .checks = f.checks, .quasistatic_nets = f.quasistatic }, &.{}, &diag);
}

/// Appends every claim of `f` that `ran_in` breaks (or the run's error),
/// and, whatever it claims, every element of its parasitic network that
/// is not passive.
pub fn brokenInto(arena: Allocator, f: *const Fixture, ran_in: anyerror!gpurify.Run, out: *std.ArrayList([]const u8)) !void {
    const ran = ran_in catch |err| {
        // A refused input satisfies only `passes = false` and nothing else.
        for (f.expect.items) |e| switch (e) {
            .passes => |pass| if (!pass) continue else break,
            .row, .lvs, .parasitic => break,
        } else return;
        return out.append(arena, try std.fmt.allocPrint(arena, "the run did not complete: {t}", .{err}));
    };
    for (f.expect.items) |e| switch (e) {
        .row => |want| try ruleBrokenInto(arena, &ran, want, out),
        .lvs => |matched| {
            const got: ?bool = if (ran.outputs.lvs) |t| t.verdict == .match else null;
            if (got != matched) try out.append(arena, try std.fmt.allocPrint(arena, "lvs: verdict {?}, want match = {}", .{ got, matched }));
        },
        .parasitic => |p| {
            const total = parasiticTotal(&ran, p.net, p.quantity) orelse {
                try out.append(arena, try std.fmt.allocPrint(arena, "pex: no net {s} in the parasitic network", .{p.net}));
                continue;
            };
            if (@abs(total - p.value) > p.rel * @max(@abs(p.value), 1e-30)) try out.append(arena, try std.fmt.allocPrint(arena, "pex {s} {t}: {d}, want {d} ±{d}", .{ p.net, p.quantity, total, p.value, p.rel }));
        },
        .passes => |pass| if (ran.summary.passed() != pass) try out.append(arena, try std.fmt.allocPrint(arena, "passes: {}, want {}", .{ ran.summary.passed(), pass })),
    };
    try passivityInto(arena, &ran, out);
}

/// The total of one quantity over a net's elements, by the net's label;
/// a mutual inductance belongs to both of its nets.
pub fn parasiticTotal(r: *const gpurify.Run, net: []const u8, quantity: Quantity) ?f64 {
    const network = &(r.outputs.parasitics orelse return null);
    const wanted = r.loaded.strings.get(net) orelse return null;
    const id = @backingInt(r.extracted.ports.netOf(wanted) orelse return null);
    const summed: extract_.network.Kind = switch (quantity) {
        .resistance => .resistance,
        .ground_cap => .ground_cap,
        .inductance => .inductance,
        .mutual => .mutual_inductance,
    };
    var total: f64 = 0;
    var seen = false;
    for (network.from.items, network.to.items, network.kind.items, network.value.items) |from, to, k, v| {
        const near = network.node_net.items[@backingInt(from)] == id;
        const far = quantity == .mutual and to != .ground and network.node_net.items[@backingInt(to)] == id;
        if (!near and !far) continue;
        seen = true;
        if (k == summed) total += v;
    }
    return if (seen) total else null;
}

/// Runs a fixture and reports what is wrong with it, honouring `known`.
pub fn check(arena: Allocator, f: *const Fixture) !?[]const u8 {
    var broken: std.ArrayList([]const u8) = .empty;
    try brokenInto(arena, f, run(arena, f), &broken);
    if (f.known) |finding| {
        if (broken.items.len != 0) return null;
        return try std.fmt.allocPrint(arena, "{s}: expected to fail until {s} is fixed, and it now holds; drop the `known` marker and record {s} as fixed", .{ f.name, finding, finding });
    }
    if (broken.items.len == 0) return null;
    return try std.fmt.allocPrint(arena, "{s}: {s}", .{ f.name, try std.mem.join(arena, "; ", broken.items) });
}

/// Every fixture has a unique name, proves a row and claims something;
/// then runs each, and fails listing every broken one (the first 60).
pub fn checkAll(fixtures: []const Fixture) !void {
    var keep: std.heap.ArenaAllocator = .init(gpa);
    defer keep.deinit();
    var names: std.StringHashMapUnmanaged(void) = .empty;
    for (fixtures) |*f| {
        if ((try names.getOrPut(keep.allocator(), f.name)).found_existing) {
            std.debug.print("{s} is generated twice\n", .{f.name});
            return error.TestDuplicateFixture;
        }
        if (f.catalog.len == 0 or f.expect.items.len == 0) {
            std.debug.print("{s} proves no catalog row or claims nothing\n", .{f.name});
            return error.TestEmptyFixture;
        }
    }
    var failures: std.ArrayList([]const u8) = .empty;
    for (fixtures) |*f| {
        var arena: std.heap.ArenaAllocator = .init(gpa);
        defer arena.deinit();
        if (try check(arena.allocator(), f)) |failure| try failures.append(keep.allocator(), try keep.allocator().dupe(u8, failure));
    }
    if (failures.items.len == 0) return;
    std.mem.sort([]const u8, failures.items, {}, lessString);
    for (failures.items[0..@min(60, failures.items.len)]) |line| std.debug.print("{s}\n", .{line});
    std.debug.print("{d} of {d} fixtures failed\n", .{ failures.items.len, fixtures.len });
    return error.TestFixturesFailed;
}

/// Whether two measurements agree: exactly for lengths, areas and counts,
/// to a relative 1e-9 for the floating kinds.
pub fn same(a: Measurement, b: Measurement) bool {
    if (a.kind != b.kind) return false;
    switch (a.kind) {
        .length, .area, .count => return a.raw == b.raw,
        .ratio, .voltage, .current, .resistance => {},
    }
    const x = a.float();
    const y = b.float();
    return @abs(x - y) <= 1e-9 * @max(@abs(x), @abs(y), 1e-30);
}

/// `layout` as GDSII on `deck`'s layers (parsed on 1 nm): one flat cell
/// `TOP`, or a hierarchy when it places cells.
pub fn written(arena: Allocator, deck: []const u8, layout: *const Layout) ![]const u8 {
    var strings: geom.StrTable = .empty;
    var diag: ingest.deck.Diag = .{};
    const d = try ingest.deck.parseDeck(arena, arena, deck, try .init(1000), &strings, &diag);
    var bytes: std.ArrayList(u8) = .empty;
    if (layout.instances.items.len != 0 or layout.cells.items.len != 0) {
        var cells: std.ArrayList(testgen.gds.Structure) = .empty;
        try structuresInto(arena, "TOP", layout, &d, &strings, &cells);
        try testgen.gds.writeLibrary(arena, cells.items, &bytes);
        return bytes.items;
    }
    var lb: testgen.shapes.LayoutBuilder = .init(@intCast(d.layers.len()));
    for (layout.shapes.items) |sh| {
        const xs = try arena.alloc(i64, sh.points.len);
        const ys = try arena.alloc(i64, sh.points.len);
        for (sh.points, xs, ys) |p, *x, *y| {
            x.* = p[0];
            y.* = p[1];
        }
        _ = try lb.push(arena, @backingInt(try layerOf(&d, &strings, sh.layer)), xs, ys);
    }
    var store: geom.GeometryStore = .empty;
    var ids: testgen.shapes.Ids = .{};
    try lb.finish(arena, &store, &ids);
    const labels = try arena.alloc(testgen.gds.Label, layout.labels.items.len);
    for (layout.labels.items, labels) |t, *o| o.* = .{ .layer = try layerOf(&d, &strings, t.layer), .x = t.x, .y = t.y, .text = t.text };
    try testgen.gds.writeStoreLabelled(arena, &store, &d.layers, labels, "TOP", &bytes);
    return bytes.items;
}

// ---- private ----

fn layerOf(d: *const ingest.deck.Deck, strings: *const geom.StrTable, name: []const u8) !geom.LayerId {
    return d.layers.id(strings, name) orelse {
        std.debug.print("layout: {s} is not a deck layer\n", .{name});
        return error.TestUnknownLayer;
    };
}

/// `layout` as the structure `name`, then every cell it defines, each
/// name once: rectangles, placements, and each label a `TEXT` of its cell
/// (the top's name its nets, a cell's are its own, a black box's pins).
fn structuresInto(arena: Allocator, name: []const u8, layout: *const Layout, d: *const ingest.deck.Deck, strings: *const geom.StrTable, out: *std.ArrayList(testgen.gds.Structure)) !void {
    const rects = try arena.alloc(struct { u16, u16, [4]i32 }, layout.shapes.items.len);
    for (layout.shapes.items, rects) |sh, *o| {
        var lo: [2]i64 = sh.points[0];
        var hi: [2]i64 = sh.points[0];
        for (sh.points) |p| for (0..2) |k| {
            lo[k] = @min(lo[k], p[k]);
            hi[k] = @max(hi[k], p[k]);
        };
        const corners = [4][2]i64{ lo, .{ hi[0], lo[1] }, hi, .{ lo[0], hi[1] } };
        const rectangle = sh.points.len == 4 and for (corners) |c| {
            if (!for (sh.points) |p| (if (p[0] == c[0] and p[1] == c[1]) break true) else false) break false;
        } else true;
        if (!rectangle) return error.TestHierarchyHoldsRectanglesOnly;
        const pair = d.layers.streamOf(try layerOf(d, strings, sh.layer));
        o.* = .{ pair[0], pair[1], .{ try coordinate(lo[0]), try coordinate(lo[1]), try coordinate(hi[0]), try coordinate(hi[1]) } };
    }
    const refs = try arena.alloc(testgen.gds.Placement, layout.instances.items.len);
    for (layout.instances.items, refs) |inst, *o| {
        const g = inst.orientation.gds();
        o.* = .{ .cell = inst.cell, .reflect = g[0], .quarter_turns = g[1], .at = .{ try coordinate(inst.dx), try coordinate(inst.dy) } };
    }
    const texts = try arena.alloc(struct { u16, u16, i32, i32, []const u8 }, layout.labels.items.len);
    for (layout.labels.items, texts) |t, *o| {
        const pair = d.layers.streamOf(try layerOf(d, strings, t.layer));
        o.* = .{ pair[0], pair[1], try coordinate(t.x), try coordinate(t.y), t.text };
    }
    try out.append(arena, .{ .name = name, .rects = rects, .refs = refs, .texts = texts });
    for (layout.cells.items) |*c| {
        const seen = for (out.items) |s| (if (std.mem.eql(u8, s.name, c.name)) break true) else false;
        if (!seen) try structuresInto(arena, c.name, &c.layout, d, strings, out);
    }
}

fn coordinate(v: i64) !i32 {
    return std.math.cast(i32, v) orelse error.TestCoordinatePastI32;
}

/// One rule claim against its rows and findings.
fn ruleBrokenInto(arena: Allocator, ran: *const gpurify.Run, want: RuleClaim, out: *std.ArrayList([]const u8)) !void {
    const strings = &ran.loaded.strings;
    var hits: u32 = 0;
    var row: report.RuleRun = undefined;
    for (ran.outputs.runs.items) |r| if (std.mem.eql(u8, strings.resolve(r.rule), want.id)) {
        hits += 1;
        row = r;
    };
    if (hits == 0) return out.append(arena, try std.fmt.allocPrint(arena, "{s}: no row", .{want.id}));
    if (hits > 1) return out.append(arena, try std.fmt.allocPrint(arena, "{s}: {d} rows", .{ want.id, hits }));
    const ok = switch (row.outcome) {
        .ran => want.outcome == .ran,
        .skipped => want.outcome == .skipped,
        .refused => want.outcome == .refused,
    };
    if (!ok) try out.append(arena, try std.fmt.allocPrint(arena, "{s}: outcome {t}, want {t}", .{ want.id, row.outcome, want.outcome }));
    if (want.examined) |n| if (n != row.examined) try out.append(arena, try std.fmt.allocPrint(arena, "{s}: examined {d}, want {d}", .{ want.id, row.examined, n }));
    var actual: std.ArrayList(report.Violation) = .empty;
    const v = &ran.outputs.violations;
    for (v.rule.items, 0..) |rule, i| if (std.mem.eql(u8, strings.resolve(rule), want.id)) try actual.append(arena, v.get(@intCast(i)));
    if (actual.items.len != want.findings.len) return out.append(arena, try std.fmt.allocPrint(arena, "{s}: {d} findings, want {d}: {f}", .{ want.id, actual.items.len, want.findings.len, Listed{ .rows = actual.items } }));
    // Greedy one-to-one pairing; findings are few per rule.
    for (want.findings) |w| {
        const index = for (actual.items, 0..) |fd, k| {
            if (w.measured) |m| if (!same(m, fd.measured)) continue;
            if (w.at) |p| if (p[0] != fd.at.x or p[1] != fd.at.y) continue;
            break k;
        } else null;
        if (index) |k| {
            _ = actual.swapRemove(k);
        } else try out.append(arena, try std.fmt.allocPrint(arena, "{s}: no finding {f} among {f}", .{ want.id, Wanted{ .f = w }, Listed{ .rows = actual.items } }));
    }
}

/// C6: an extracted network is passive, element by element. A resistance,
/// a capacitance to ground or another net, or an inductance below zero
/// returns more energy than it stores, so each is zero or more (NaN fails
/// too). A mutual inductance is signed by its ports' orientation, so its
/// law is the pair's: `M² ≤ L₁L₂`, each `L` the series inductance on the
/// mutual's node.
fn passivityInto(arena: Allocator, r: *const gpurify.Run, out: *std.ArrayList([]const u8)) !void {
    const network = &(r.outputs.parasitics orelse return);
    for (network.from.items, network.to.items, network.kind.items, network.value.items, 0..) |from, to, k, v, row| {
        const passive = switch (k) {
            .resistance, .substrate_resistance, .ground_cap, .coupling_cap, .inductance => v >= 0,
            .mutual_inductance => v * v <= inductanceAt(network, from) * (if (to == .ground) std.math.nan(f64) else inductanceAt(network, to)),
        };
        if (!passive) try out.append(arena, try std.fmt.allocPrint(arena, "pex: element {d}, {t} {d}, is not passive", .{ row, k, v }));
    }
}

fn inductanceAt(network: *const ParasiticNetwork, node: NodeId) f64 {
    for (network.from.items, network.kind.items, network.value.items) |f, k, v| if (k == .inductance and f == node) return v;
    return std.math.nan(f64);
}

fn lessString(_: void, a: []const u8, b: []const u8) bool {
    return std.mem.order(u8, a, b) == .lt;
}
