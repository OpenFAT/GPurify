//! Metamorphic relations on the corpus: every real corpus cell, turned,
//! mirrored or moved, must report what the cell reports where it was
//! drawn. Ported from tests/exhaustive/corpus.rs.
//!
//! This is the one place a fixture's expectation comes from a run: the
//! relation is the oracle, so the untransformed run states what every
//! transformed run must say. A rule that measures the same thing in a
//! rotated layout must find the same violations with the same
//! measurements, LVS must reach the same verdict, and a net's resistance
//! and capacitance must not change. The exceptions are stated where they
//! are made: density windows are tiled from the die's lower-left corner, so
//! a rotation or mirror legitimately moves them, and translations are
//! multiples of every grid pitch, so `off_grid` keeps its verdict. Each
//! fixture proves the catalog rows of the rule kinds its case exercises:
//! invariance is part of a rule's definition.
//!
//! Contents:
//! - `pub fn fixturesInto(arena: Allocator, depth: Depth, out: *std.ArrayList(Fixture)) !void`

const std = @import("std");
const Allocator = std.mem.Allocator;
const testing = std.testing;
const paths = @import("paths");
const gpurify = @import("gpurify");
const harness = @import("harness.zig");
const Depth = harness.Depth;
const Expect = harness.Expect;
const Finding = harness.Finding;
const Fixture = harness.Fixture;
const Layout = harness.Layout;
const Symmetry = harness.Symmetry;
const corpus = @import("corpus.zig");
const gpa = testing.allocator;
const io = testing.io;

/// A translation every grid pitch in the corpus deck divides.
const offset = [2]i64{ -370_000, 520_000 };

/// The kinds whose result depends on where the die's corner falls.
const oriented = [_][]const u8{ "density", "global_density", "density_cmp" };

/// A claim and the rule kind (or domain) it exercises.
const Claim = struct { expect: Expect, kind: []const u8 };

/// Rule kind to the catalog rows that name it.
const Rows = std.StringHashMapUnmanaged(std.ArrayList([]const u8));

/// Every corpus case, each under the seven other symmetries at `offset`;
/// nightly also at the origin.
pub fn fixturesInto(arena: Allocator, depth: Depth, out: *std.ArrayList(Fixture)) !void {
    var root = try std.Io.Dir.cwd().openDir(io, paths.root, .{});
    defer root.close(io);
    const expectations = try corpus.corpus(arena);
    const deck = try root.readFileAlloc(io, "tests/fixtures/params.deck", arena, .unlimited);
    const rows = try catalogRows(arena, root);
    const domains = [_]struct { []const u8, gpurify.Checks }{ .{ "drc", .{ .drc = true } }, .{ "erc", .{ .erc = true } }, .{ "lvs", .{ .lvs = true } }, .{ "pex", .{ .pex = true } } };
    for (domains) |dc| {
        const domain = dc[0];
        for (expectations.object.get(domain).?.object.get("cases").?.array.items) |case| {
            const id = case.object.get("id").?.string;
            var base: Fixture = .init(try std.fmt.allocPrint(arena, "corpus/{s}/{s}", .{ domain, id }), &.{}, deck, dc[1]);
            base.layout = try layoutOf(arena, root, try std.fmt.allocPrint(arena, "tests/fixtures/{s}/{s}.gds", .{ domain, id }));
            if (std.mem.eql(u8, domain, "lvs")) base.reference = try root.readFileAlloc(io, try std.fmt.allocPrint(arena, "tests/fixtures/lvs_refs/{s}.spice", .{id}), arena, .unlimited);
            var scratch: std.heap.ArenaAllocator = .init(gpa);
            defer scratch.deinit();
            const ran = harness.run(scratch.allocator(), &base) catch {
                // A cell the pipeline refuses is refused wherever it is drawn.
                try base.claim(arena, .{ .passes = false });
                base.catalog = &.{"DRC-120"};
                for (Symmetry.all[1..]) |s| try out.append(arena, try base.transformed(arena, s, offset[0], offset[1]));
                continue;
            };
            const claims = try claimsOf(arena, &ran, &base.layout);
            base.catalog = try catalogOf(arena, &rows, claims, domain);
            for (Symmetry.all[1..]) |s| {
                var moved = try base.transformed(arena, s, offset[0], offset[1]);
                for (claims) |c| if (!isOriented(c.kind)) try moved.claim(arena, c.expect);
                try out.append(arena, moved);
            }
            if (depth == .nightly) {
                var moved = try base.transformed(arena, .identity, offset[0], offset[1]);
                for (claims) |c| try moved.claim(arena, c.expect);
                try out.append(arena, moved);
            }
        }
    }
}

// ---- private ----

/// docs/check-catalog.tsv: column 5 lists each row's kinds.
fn catalogRows(arena: Allocator, root: std.Io.Dir) !Rows {
    const text = try root.readFileAlloc(io, "docs/check-catalog.tsv", arena, .unlimited);
    var rows: Rows = .empty;
    var lines = std.mem.splitScalar(u8, text, '\n');
    _ = lines.next();
    while (lines.next()) |line| {
        if (line.len == 0) continue;
        var cells: [6][]const u8 = undefined;
        var it = std.mem.splitScalar(u8, line, '\t');
        for (&cells) |*c| c.* = it.next() orelse "";
        var kinds = std.mem.splitScalar(u8, cells[5], ',');
        while (kinds.next()) |raw| {
            const got = try rows.getOrPut(arena, std.mem.trim(u8, raw, " "));
            if (!got.found_existing) got.value_ptr.* = .empty;
            try got.value_ptr.append(arena, cells[0]);
        }
    }
    return rows;
}

/// A corpus cell as a harness layout: drawn-layer polygons as flattened
/// (holes included, in their own orientation) and every placed label.
fn layoutOf(arena: Allocator, root: std.Io.Dir, gds: []const u8) !Layout {
    var diag: gpurify.LoadDiagnostic = .{};
    const loaded = try gpurify.load(gpa, arena, io, root, .{ .layout = gds, .deck = "tests/fixtures/params.deck" }, &.{}, &diag);
    const layers = &loaded.deck.deck.layers;
    var layout: Layout = .{};
    for (0..loaded.store.polyCount()) |row| {
        const poly: @import("geom").PolyId = @fromBackingInt(@as(u32, @intCast(row)));
        const layer = loaded.store.polyLayer(poly);
        if (layers.isDerived(layer)) continue;
        const ring = loaded.store.polyVerts(poly);
        const points = try arena.alloc([2]i64, ring.xs.len);
        for (points, ring.xs, ring.ys) |*p, x, y| p.* = .{ x, y };
        try layout.shapes.append(arena, .{ .layer = loaded.strings.resolve(layers.name(layer)), .points = points });
    }
    const placed = loaded.provenance.placed.slice();
    for (placed.items(.x), placed.items(.y), placed.items(.layer), placed.items(.name)) |x, y, layer, name| {
        try layout.label(arena, loaded.strings.resolve(layers.name(layer)), x, y, loaded.strings.resolve(name));
    }
    return layout;
}

/// The run's own report, as the claims every transformed run must repeat.
fn claimsOf(arena: Allocator, ran: *const gpurify.Run, layout: *const Layout) ![]const Claim {
    const strings = &ran.loaded.strings;
    const specs = ran.loaded.deck.deck.rules.spec;
    var claims: std.ArrayList(Claim) = .empty;
    for (ran.outputs.runs.items) |row| {
        var findings: std.ArrayList(Finding) = .empty;
        const v = &ran.outputs.violations;
        for (v.rule.items, 0..) |rule, i| if (rule == row.rule) try findings.append(arena, .{ .measured = v.get(@intCast(i)).measured, .at = null });
        const want: harness.Want = switch (row.outcome) {
            .ran => .ran,
            .skipped => .skipped,
            .refused => .refused,
        };
        const kind = for (specs) |spec| (if (spec.id == row.rule) break strings.resolve(spec.kind)) else strings.resolve(row.rule);
        // The examined count is not carried over: the corpus case states its
        // own floor, and a count a run reported is not a definition.
        const id = try arena.dupe(u8, strings.resolve(row.rule));
        try claims.append(arena, .{ .expect = .{ .row = .{ .id = id, .outcome = want, .findings = findings.items, .examined = null } }, .kind = try arena.dupe(u8, kind) });
    }
    if (ran.outputs.lvs) |t| try claims.append(arena, .{ .expect = .{ .lvs = t.verdict == .match }, .kind = "lvs" });
    for (layout.labels.items) |l| for ([_]harness.Quantity{ .resistance, .ground_cap }) |q| {
        const value = harness.parasiticTotal(ran, l.text, q) orelse continue;
        try claims.append(arena, .{ .expect = .{ .parasitic = .{ .net = l.text, .quantity = q, .value = value, .rel = 1e-9 } }, .kind = "pex" });
    };
    return claims.items;
}

/// The sorted, deduplicated catalog rows of the claims' kinds; a domain's
/// own row when no kind is in the catalog.
fn catalogOf(arena: Allocator, rows: *const Rows, claims: []const Claim, domain: []const u8) ![]const []const u8 {
    var ids: std.ArrayList([]const u8) = .empty;
    for (claims) |c| if (rows.get(c.kind)) |named| for (named.items) |id| {
        if (!for (ids.items) |have| (if (std.mem.eql(u8, have, id)) break true) else false) try ids.append(arena, id);
    };
    std.mem.sort([]const u8, ids.items, {}, lessString);
    if (ids.items.len == 0) try ids.append(arena, if (std.mem.eql(u8, domain, "lvs")) "LVS-019" else if (std.mem.eql(u8, domain, "pex")) "PEX-001" else "DRC-120");
    return ids.items;
}

fn isOriented(kind: []const u8) bool {
    for (oriented) |o| if (std.mem.eql(u8, o, kind)) return true;
    return false;
}

fn lessString(_: void, a: []const u8, b: []const u8) bool {
    return std.mem.order(u8, a, b) == .lt;
}

test "every corpus cell reports the same under every symmetry" {
    // Oracle: metamorphic relation: the untransformed run of each corpus
    // cell states what each of its seven other symmetries, moved by a
    // translation every grid pitch divides, must report: the same rows,
    // the same measured findings, the same LVS verdict, the same net
    // resistance and ground capacitance (density kinds aside, whose windows
    // tile from the die's corner).
    var arena: std.heap.ArenaAllocator = .init(gpa);
    defer arena.deinit();
    var fixtures: std.ArrayList(Fixture) = .empty;
    try fixturesInto(arena.allocator(), .merge, &fixtures);
    try testing.expectEqual(167 * 7, fixtures.items.len);
    try harness.checkAll(fixtures.items);
}
