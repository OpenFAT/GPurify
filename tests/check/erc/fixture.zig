//! A deck-and-layout fixture run through the engine's own path: the deck
//! parsed and compiled, the layout drawn in memory, layers derived, labels
//! bound, nets and devices extracted, and `erc.check` run as the engine
//! does after reading GDSII. The fixtures state what each run must report;
//! nothing here states an answer. Ported from
//! crates/check/tests/erc/fixture.rs (and the flat, ERC-only part of
//! tests/exhaustive/harness.rs).
//!
//! Everything a fixture holds lives in the caller's arena.
//!
//! Contents:
//! - `pub const Shape = struct`, `pub const Text = struct`, `pub const Row = struct`, `pub const Found = struct`
//! - `pub const Layout = struct`, `rect(l, arena, layer, xlo, ylo, xhi, yhi) !void`, `polygon(l, arena, layer, points) !void`,
//!   `label(l, arena, layer, x, y, text) !void`, `transformed(l, arena, s: Symmetry, dx, dy) !Layout`
//! - `pub const Symmetry = struct { turns: u8, mirror: bool }`, `Symmetry.identity`, `apply(s, p: [2]i64) [2]i64`
//! - `pub const Want = enum { ran, skipped, refused }`, `pub const Finding = struct`, `pub const Expect = struct`
//! - `pub const Fixture = struct`, `transformed(f, arena, s: Symmetry, dx, dy) !Fixture`
//! - `pub const Ran = struct`, `pub fn run(arena: Allocator, f: *const Fixture) !Ran`
//! - `pub fn brokenInto(arena: Allocator, f: *const Fixture, out: *std.ArrayList([]const u8)) !void`
//! - `pub fn checkAll(fixtures: []const Fixture) !void`
//! - `pub fn same(a: Measurement, b: Measurement) bool`

const std = @import("std");
const Allocator = std.mem.Allocator;
const testing = std.testing;
const geom = @import("geom");
const ingest = @import("ingest");
const check = @import("check");
const testgen = @import("testgen");
const Bbox = geom.Bbox;
const StrTable = geom.StrTable;
const GeometryStore = geom.GeometryStore;
const report = check.report;
const Measurement = report.Measurement;
const Outcome = report.Outcome;
const topology = check.topology;
const erc = check.erc;

const gpa = testing.allocator;

/// One polygon on a deck layer name, counter-clockwise, in nanometres.
pub const Shape = struct { layer: []const u8, xs: []const i64, ys: []const i64 };

/// A text label naming the net under it.
pub const Text = struct { layer: []const u8, x: i64, y: i64, text: []const u8 };

/// A flat layout, its slices in the caller's arena.
pub const Layout = struct {
    shapes: std.ArrayList(Shape) = .empty,
    labels: std.ArrayList(Text) = .empty,

    pub fn rect(l: *Layout, arena: Allocator, layer: []const u8, xlo: i64, ylo: i64, xhi: i64, yhi: i64) !void {
        std.debug.assert(xlo < xhi and ylo < yhi);
        try l.polygon(arena, layer, &.{ .{ xlo, ylo }, .{ xhi, ylo }, .{ xhi, yhi }, .{ xlo, yhi } });
    }

    pub fn polygon(l: *Layout, arena: Allocator, layer: []const u8, points: []const [2]i64) !void {
        const xs = try arena.alloc(i64, points.len);
        const ys = try arena.alloc(i64, points.len);
        for (points, xs, ys) |p, *x, *y| {
            x.* = p[0];
            y.* = p[1];
        }
        try l.shapes.append(arena, .{ .layer = layer, .xs = xs, .ys = ys });
    }

    pub fn label(l: *Layout, arena: Allocator, layer: []const u8, x: i64, y: i64, text: []const u8) !void {
        try l.labels.append(arena, .{ .layer = layer, .x = x, .y = y, .text = text });
    }

    /// The layout under `s`, then moved by `(dx, dy)`; outlines stay
    /// counter-clockwise.
    pub fn transformed(l: *const Layout, arena: Allocator, s: Symmetry, dx: i64, dy: i64) !Layout {
        var out: Layout = .{};
        for (l.shapes.items) |sh| {
            const n = sh.xs.len;
            const xs = try arena.alloc(i64, n);
            const ys = try arena.alloc(i64, n);
            for (0..n) |i| {
                const from = if (s.mirror) n - 1 - i else i;
                const p = s.apply(.{ sh.xs[from], sh.ys[from] });
                xs[i] = p[0] + dx;
                ys[i] = p[1] + dy;
            }
            try out.shapes.append(arena, .{ .layer = sh.layer, .xs = xs, .ys = ys });
        }
        for (l.labels.items) |t| {
            const p = s.apply(.{ t.x, t.y });
            try out.labels.append(arena, .{ .layer = t.layer, .x = p[0] + dx, .y = p[1] + dy, .text = t.text });
        }
        return out;
    }
};

/// One of the eight symmetries of the square: counter-clockwise quarter
/// turns, then an optional mirror of x.
pub const Symmetry = struct {
    turns: u8,
    mirror: bool,

    pub const identity: Symmetry = .{ .turns = 0, .mirror = false };

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
};

/// What a rule's row must say.
pub const Want = enum { ran, skipped, refused };

/// One finding a rule must report: its measured value (exact for lengths,
/// areas and counts) and its marker in nanometres, either unpinned.
pub const Finding = struct {
    measured: ?Measurement = null,
    at: ?[2]i64 = null,
};

/// One claim about a rule's row: its outcome, exactly these findings in
/// any order, and (when stated) its examined count.
pub const Expect = struct {
    id: []const u8,
    outcome: Want = .ran,
    findings: []const Finding = &.{},
    examined: ?u64 = null,
};

/// One ERC run's inputs and what it must report.
pub const Fixture = struct {
    /// Unique and path-like.
    name: []const u8,
    /// The whole deck.
    deck: []const u8,
    layout: Layout = .{},
    /// Design-intent JSON for the intent-gated rules.
    intent: ?[]const u8 = null,
    expect: []const Expect = &.{},

    /// The fixture under `s` and a translation; every pinned marker moves
    /// with it (a rule's numbers are invariant under these).
    pub fn transformed(f: *const Fixture, arena: Allocator, s: Symmetry, dx: i64, dy: i64) !Fixture {
        var out = f.*;
        out.name = try std.fmt.allocPrint(arena, "{s}/{s}{d}+({d},{d})", .{ f.name, if (s.mirror) "m" else "r", @as(u32, s.turns) * 90, dx, dy });
        out.layout = try f.layout.transformed(arena, s, dx, dy);
        const expect = try arena.dupe(Expect, f.expect);
        for (expect) |*e| {
            const findings = try arena.dupe(Finding, e.findings);
            for (findings) |*fd| if (fd.at) |at| {
                const p = s.apply(at);
                fd.at = .{ p[0] + dx, p[1] + dy };
            };
            e.findings = findings;
        }
        out.expect = expect;
        return out;
    }
};

/// One rule row of a run, names resolved.
pub const Row = struct { id: []const u8, outcome: Outcome, examined: u64 };

/// One finding of a run, names resolved, the marker in nanometres.
pub const Found = struct { id: []const u8, measured: Measurement, at: [2]i64 };

/// What a run produced, in the caller's arena.
pub const Ran = struct { rows: []const Row, findings: []const Found };

/// Runs a fixture's ERC rows in memory. A stage that refuses the inputs
/// is an error, its cause printed.
pub fn run(arena: Allocator, f: *const Fixture) !Ran {
    const grid = try geom.Grid.init(1000);
    var strings: StrTable = .empty;
    defer strings.deinit(gpa);
    var diag: check.deck.compile.Diag = .{};
    const parsed = ingest.deck.parseDeck(arena, gpa, f.deck, grid, &strings, &diag.deck) catch |e| {
        for (diag.deck.diagnostics) |d| std.debug.print("{s}: deck: {s}\n", .{ f.name, d.message });
        if (diag.deck.malformed.len > 0) std.debug.print("{s}: deck: {s}\n", .{ f.name, diag.deck.malformed });
        return e;
    };
    var lb = testgen.shapes.LayoutBuilder.init(@intCast(parsed.layers.len()));
    defer lb.deinit(gpa);
    for (f.layout.shapes.items) |sh| {
        const id = parsed.layers.id(&strings, sh.layer) orelse {
            std.debug.print("{s}: layout: {s} is not a deck layer\n", .{ f.name, sh.layer });
            return error.UnknownLayer;
        };
        _ = try lb.push(gpa, @backingInt(id), sh.xs, sh.ys);
    }
    var store: GeometryStore = .empty;
    defer store.deinit(gpa);
    var ids: testgen.shapes.Ids = .{};
    defer ids.deinit(gpa);
    try lb.finish(gpa, &store, &ids);
    var provenance: ingest.Provenance = .{};
    defer provenance.deinit(gpa);
    for (f.layout.labels.items) |t| {
        const id = parsed.layers.id(&strings, t.layer) orelse {
            std.debug.print("{s}: layout: {s} is not a deck layer\n", .{ f.name, t.layer });
            return error.UnknownLayer;
        };
        try provenance.placeLabel(gpa, .{ .x = t.x, .y = t.y, .layer = id, .name = try strings.intern(gpa, t.text) });
    }
    try ingest.layout.deriveLayersInto(gpa, &store, &parsed.layers, &provenance, &strings, &.{});
    var unplaced: ingest.provenance.PlacedLabel = undefined;
    ingest.resolveLabels(gpa, &provenance, &store, &parsed.connectivity, &unplaced) catch |e| {
        std.debug.print("{s}: labels: {t}\n", .{ f.name, e });
        return e;
    };
    var intent_diag: ingest.intent.Diagnostic = .{};
    const intent: ?ingest.intent.DesignIntent = if (f.intent) |text| ingest.intent.parseIntent(arena, gpa, text, &strings, &intent_diag) catch |e| {
        std.debug.print("{s}: intent: {t} {s}\n", .{ f.name, e, intent_diag.text() });
        return e;
    } else null;
    var cd = check.deck.compile.fromDeck(gpa, parsed, grid, &strings, &diag) catch |e| {
        std.debug.print("{s}: compile: {t} rule {s} param {s} {s}\n", .{ f.name, e, if (@backingInt(diag.rule.rule) != std.math.maxInt(u32)) strings.resolve(diag.rule.rule) else "?", diag.rule.param, diag.rule.why });
        return e;
    };
    defer cd.deinit(gpa);

    var channel_diag: topology.channel.ChannelDiagnostic = undefined;
    try topology.refuseConductingChannels(gpa, &store, &cd.deck.connectivity, &cd.deck.devices, &channel_diag);
    var nets: topology.NetTable = .{};
    defer nets.deinit(gpa);
    try topology.extractNetsInto(gpa, &store, &cd.deck.connectivity, &nets);
    var devices: topology.DeviceTable = .{};
    defer devices.deinit(gpa);
    try topology.recogniseInto(gpa, &store, &nets, &cd.deck.devices, &devices);
    var ports: topology.PortTable = .{};
    defer ports.deinit(gpa);
    try topology.bindPortsInto(gpa, &nets, provenance.labels(), &ports);
    if (intent != null and ports.shortedNet() != null) {
        std.debug.print("{s}: erc: one net carries two labels\n", .{f.name});
        return error.ShortedLabels;
    }

    // The deck's `boundary`, as the engine reads it; else every drawn layer.
    var die = Bbox.empty;
    if (cd.deck.boundary) |b| if (@backingInt(b) < store.layerCount()) {
        for (store.layerBboxes(b)) |box| die = die.merge(box);
    };
    if (die.isEmpty()) {
        die = Bbox.empty;
        for (0..store.layerCount()) |l| {
            const layer: geom.LayerId = @fromBackingInt(@as(u16, @intCast(l)));
            if (cd.deck.layers.isDerived(layer)) continue;
            for (store.layerBboxes(layer)) |box| die = die.merge(box);
        }
    }
    const temperature = (if (intent) |i| i.temperature else null) orelse cd.deck.temperature;
    var out: report.Violations = .{};
    defer out.deinit(gpa);
    var runs: std.ArrayList(report.RuleRun) = .empty;
    defer runs.deinit(gpa);
    try erc.check(gpa, &cd.erc, .{
        .design = .{ .store = &store, .nets = &nets, .devices = &devices },
        .ports = &ports,
        .intent = if (intent) |*i| i else null,
        .process = .{ .grid = grid, .stack = &cd.deck.stack, .connectivity = &cd.deck.connectivity },
        .die = die,
        .temperature = temperature,
        .strings = &strings,
    }, &out, &runs);

    const rows = try arena.alloc(Row, runs.items.len);
    for (rows, runs.items) |*r, rr| r.* = .{ .id = try arena.dupe(u8, strings.resolve(rr.rule)), .outcome = rr.outcome, .examined = rr.examined };
    const found = try arena.alloc(Found, out.len());
    for (found, 0..) |*fd, i| {
        const v = out.get(@intCast(i));
        fd.* = .{ .id = try arena.dupe(u8, strings.resolve(v.rule)), .measured = v.measured, .at = .{ v.at.x, v.at.y } };
    }
    return .{ .rows = rows, .findings = found };
}

/// Two measurements agree: exactly for lengths, areas and counts, to a
/// relative 1e-9 for the floating kinds.
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

/// Appends every claim of `f` its run breaks (or the run's error).
pub fn brokenInto(arena: Allocator, f: *const Fixture, out: *std.ArrayList([]const u8)) !void {
    const ran = run(arena, f) catch |e| {
        try out.append(arena, try std.fmt.allocPrint(arena, "the run did not complete: {t}", .{e}));
        return;
    };
    for (f.expect) |e| {
        var hits: u32 = 0;
        var row: Row = undefined;
        for (ran.rows) |r| if (std.mem.eql(u8, r.id, e.id)) {
            hits += 1;
            row = r;
        };
        if (hits != 1) {
            try out.append(arena, try std.fmt.allocPrint(arena, "{s}: {d} rows", .{ e.id, hits }));
            continue;
        }
        const ok = switch (e.outcome) {
            .ran => row.outcome == .ran,
            .skipped => row.outcome == .skipped,
            .refused => row.outcome == .refused,
        };
        if (!ok) try out.append(arena, try std.fmt.allocPrint(arena, "{s}: outcome {any}, want {t}", .{ e.id, row.outcome, e.outcome }));
        if (e.examined) |want| if (want != row.examined) try out.append(arena, try std.fmt.allocPrint(arena, "{s}: examined {d}, want {d}", .{ e.id, row.examined, want }));
        var actual: std.ArrayList(Found) = .empty;
        for (ran.findings) |fd| if (std.mem.eql(u8, fd.id, e.id)) try actual.append(arena, fd);
        if (actual.items.len != e.findings.len) {
            try out.append(arena, try std.fmt.allocPrint(arena, "{s}: {d} findings, want {d}: {any}", .{ e.id, actual.items.len, e.findings.len, actual.items }));
            continue;
        }
        // Greedy one-to-one pairing; findings are few per rule.
        for (e.findings) |want| {
            const at = for (actual.items, 0..) |fd, k| {
                if (want.measured) |m| if (!same(m, fd.measured)) continue;
                if (want.at) |p| if (p[0] != fd.at[0] or p[1] != fd.at[1]) continue;
                break k;
            } else null;
            if (at) |k| {
                _ = actual.swapRemove(k);
            } else try out.append(arena, try std.fmt.allocPrint(arena, "{s}: no finding {any} among {any}", .{ e.id, want, actual.items }));
        }
    }
}

/// Runs every fixture; fails with every broken claim printed.
pub fn checkAll(fixtures: []const Fixture) !void {
    var arena_state: std.heap.ArenaAllocator = .init(gpa);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    for (fixtures, 0..) |a, i| for (fixtures[i + 1 ..]) |b| if (std.mem.eql(u8, a.name, b.name)) {
        std.debug.print("fixture name {s} repeats\n", .{a.name});
        return error.DuplicateFixture;
    };
    var failed: u32 = 0;
    for (fixtures) |*f| {
        var broken: std.ArrayList([]const u8) = .empty;
        try brokenInto(arena, f, &broken);
        if (broken.items.len == 0) continue;
        failed += 1;
        std.debug.print("{s}:", .{f.name});
        for (broken.items) |b| std.debug.print(" {s};", .{b});
        std.debug.print("\n", .{});
    }
    if (failed > 0) {
        std.debug.print("{d} of {d} fixtures broke a claim\n", .{ failed, fixtures.len });
        return error.TestUnexpectedResult;
    }
}
