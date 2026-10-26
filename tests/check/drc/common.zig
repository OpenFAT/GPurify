//! Fixtures the DRC and deck suites share: rules run straight over a store
//! (`runRules`), and deck-text cases (`check*`): a deck parsed on a 1 nm
//! grid, a layout in nanometres, derived layers computed, nets extracted,
//! rules typed and run, each rule's findings matched against claims. Ported
//! from crates/check/tests/drc/common/{mod,deck}.rs. A case under
//! `checkEverywhere` repeats under the eight symmetries of the square at two
//! translations, every pinned marker moved with the layout.
//!
//! Contents:
//! - `pub const rule_id`, `other_rule`, `a`, `b`, `pub const gpa`
//! - `pub const Built`, `Built.deinit`, `Built.of`, `pub fn finish(lb: *LayoutBuilder) !Built`, `pub fn single(rule: Rule) [1]Item`
//! - `pub const Sink`, `Sink.deinit`, `pub fn runRules(sink: *Sink, store: *const GeometryStore, rules: []const Item) !void`, `pub const Item`
//! - `pub const Layout`, `Layout.deinit`, `rect`, `rects`, `polygon`, `transformed`
//! - `pub const Symmetry`, `pub const symmetries`, `pub const offsets`, `pub fn apply(s: Symmetry, p: [2]i64) [2]i64`
//! - `pub const Finding`, `length`, `area`, `count`, `ratio`, `any`, `atPoint`, `atHalf`, `limitOf`
//! - `pub const Row`, `pub const Run`, `Run.deinit`, `Run.row(r, id: []const u8) *const Row`, `pub fn run(text: []const u8, layout: *const Layout) !Run`
//! - `pub const Claim`, `pub fn checkCase(name: []const u8, text: []const u8, layout: *const Layout, expect: []const Claim) !void`,
//!   `checkEverywhere`, `checkUnder`, `checkAxes`, `byRule`
//! - `pub fn deck(arena: Allocator, rules: []const u8) ![]const u8`, `oneLayerDeck`, `newDeck`
//! - `pub fn floorSqrt(n: i64) i64`, `pub fn ring(l: *Layout, layer: []const u8, outer: [4]i64, hole: [4]i64) !void`,
//!   `pub fn met1(boxes: []const [4]i64) !Layout`, `layoutOf`, `everywhere`, `axes`, `steps`, `opt`, `below`, `slice`,
//!   `pub const Opt`

const std = @import("std");
const Allocator = std.mem.Allocator;
const testing = std.testing;
const geom = @import("geom");
const ingest = @import("ingest");
const check = @import("check");
const testgen = @import("testgen");
const LayerId = geom.LayerId;
const StrId = geom.StrId;
const StrTable = geom.StrTable;
const GeometryStore = geom.GeometryStore;
const report = check.report;
const Measurement = report.Measurement;
const Violations = report.Violations;
const RuleRun = report.RuleRun;
const drc = check.drc;

pub const gpa = testing.allocator;

pub const rule_id: StrId = @fromBackingInt(0);

pub const other_rule: StrId = @fromBackingInt(1);

/// Layer 0, then 1: `LayoutBuilder` sizes its table from the highest id.
pub const a: LayerId = @fromBackingInt(0);

pub const b: LayerId = @fromBackingInt(1);

/// A built store and its handles.
pub const Built = struct {
    store: GeometryStore = .empty,
    ids: testgen.shapes.Ids = .{},

    pub fn deinit(b_: *Built) void {
        b_.store.deinit(gpa);
        b_.ids.deinit(gpa);
    }

    pub fn of(b_: *const Built, h: testgen.shapes.Handle) geom.PolyId {
        return b_.ids.of(h);
    }
};

/// At most one finding, held by value.
pub const Opt = struct { f: [1]Finding, n: u1 };

/// A rule with its id, as a test states it.
pub const Item = struct { id: StrId, rule: drc.Rule };

/// What one run of some rules produced.
pub const Sink = struct {
    out: Violations = .{},
    runs: std.ArrayList(RuleRun) = .empty,

    pub fn deinit(s: *Sink) void {
        s.out.deinit(gpa);
        s.runs.deinit(gpa);
    }
};

/// A layout: polygons on deck layer names, counter-clockwise, in nanometres.
pub const Layout = struct {
    layer: std.ArrayList([]const u8) = .empty,
    xs: std.ArrayList([]const i64) = .empty,
    ys: std.ArrayList([]const i64) = .empty,
    arena: std.heap.ArenaAllocator = .init(gpa),

    pub fn deinit(l: *Layout) void {
        l.arena.deinit();
    }

    pub fn rect(l: *Layout, layer: []const u8, xlo: i64, ylo: i64, xhi: i64, yhi: i64) !void {
        std.debug.assert(xlo < xhi and ylo < yhi);
        try l.polygon(layer, &.{ .{ xlo, ylo }, .{ xhi, ylo }, .{ xhi, yhi }, .{ xlo, yhi } });
    }

    pub fn rects(l: *Layout, layer: []const u8, boxes: []const [4]i64) !void {
        for (boxes) |r| try l.rect(layer, r[0], r[1], r[2], r[3]);
    }

    pub fn polygon(l: *Layout, layer: []const u8, points: []const [2]i64) !void {
        const al = l.arena.allocator();
        const xs = try al.alloc(i64, points.len);
        const ys = try al.alloc(i64, points.len);
        for (points, xs, ys) |p, *x, *y| {
            x.* = p[0];
            y.* = p[1];
        }
        try l.layer.append(al, layer);
        try l.xs.append(al, xs);
        try l.ys.append(al, ys);
    }

    /// The layout under `s`, then moved by `(dx, dy)`; outlines stay
    /// counter-clockwise. The caller deinits it.
    pub fn transformed(l: *const Layout, s: Symmetry, dx: i64, dy: i64) !Layout {
        var out: Layout = .{};
        errdefer out.deinit();
        const al = out.arena.allocator();
        for (l.layer.items, l.xs.items, l.ys.items) |layer, xs, ys| {
            const points = try al.alloc([2]i64, xs.len);
            for (points, xs, ys) |*p, x, y| {
                const q = apply(s, .{ x, y });
                p.* = .{ q[0] + dx, q[1] + dy };
            }
            if (s.mirror) std.mem.reverse([2]i64, points);
            try out.polygon(layer, points);
        }
        return out;
    }
};

/// One of the eight symmetries of the square: counter-clockwise quarter
/// turns, then a mirror of x.
pub const Symmetry = struct { turns: u2, mirror: bool };

/// All eight, identity first.
pub const symmetries = [8]Symmetry{
    .{ .turns = 0, .mirror = false }, .{ .turns = 1, .mirror = false },
    .{ .turns = 2, .mirror = false }, .{ .turns = 3, .mirror = false },
    .{ .turns = 0, .mirror = true },  .{ .turns = 1, .mirror = true },
    .{ .turns = 2, .mirror = true },  .{ .turns = 3, .mirror = true },
};

/// The translations a case repeats at: the origin, and far off it in the
/// negative quadrant.
pub const offsets = [2][2]i64{ .{ 0, 0 }, .{ -1_234_567, 987_654 } };

/// One finding a rule must report, each part claimed only when set.
pub const Finding = struct {
    measured: ?Measurement = null,
    limit: ?Measurement = null,
    at: ?[2]i64 = null,

    pub fn length(nm: i64) Finding {
        return .{ .measured = .length(nm) };
    }
    pub fn area(nm2: i128) Finding {
        return .{ .measured = .area(nm2) };
    }
    pub fn count(n: u32) Finding {
        return .{ .measured = .count(n) };
    }
    pub fn ratio(r: f64) Finding {
        return .{ .measured = .ratio(r) };
    }
    pub fn any() Finding {
        return .{};
    }
    pub fn atPoint(f: Finding, x: i64, y: i64) Finding {
        var g = f;
        g.at = .{ x, y };
        return g;
    }
    /// Pins the marker at `(x2 / 2, y2 / 2)` when both halves are whole; a
    /// floored midpoint does not commute with a mirror, so stays unpinned.
    pub fn atHalf(f: Finding, x2: i64, y2: i64) Finding {
        return if (@mod(x2, 2) == 0 and @mod(y2, 2) == 0) f.atPoint(@divExact(x2, 2), @divExact(y2, 2)) else f;
    }
    pub fn limitOf(f: Finding, limit: Measurement) Finding {
        var g = f;
        g.limit = limit;
        return g;
    }
};

/// One rule's row of a run, with its findings.
pub const Row = struct {
    id: []const u8,
    outcome: report.Outcome,
    examined: u64,
    findings: []const struct { measured: Measurement, limit: Measurement, at: [2]i64 },
};

/// A whole deck run, its rows in deck order; owns everything.
pub const Run = struct {
    arena: std.heap.ArenaAllocator,
    rows: []const Row,

    pub fn deinit(r: *Run) void {
        r.arena.deinit();
    }

    pub fn row(r: *const Run, id: []const u8) *const Row {
        for (r.rows) |*x| if (std.mem.eql(u8, x.id, id)) return x;
        std.debug.panic("no row for rule {s}", .{id});
    }
};

/// A rule's claims: its id and every finding it must report, exactly.
pub const Claim = struct { id: []const u8, findings: []const Finding };

/// One rule under `rule_id`.
pub fn single(rule: drc.Rule) [1]Item {
    return .{.{ .id = rule_id, .rule = rule }};
}

/// A store and the ids its builder's handles became, freed together.
pub fn finish(lb: *testgen.shapes.LayoutBuilder) !Built {
    var out: Built = .{};
    errdefer out.deinit();
    try lb.finish(gpa, &out.store, &out.ids);
    lb.deinit(gpa);
    return out;
}

/// Runs `rules` over `store` on the CPU, no nets, replacing what the sink held.
pub fn runRules(sink: *Sink, store: *const GeometryStore, rules: []const Item) !void {
    var set: drc.RuleSet = .{};
    defer set.deinit(gpa);
    for (rules) |r| try set.push(gpa, r.id, r.rule, .@"error");
    try drc.run(gpa, .cpu, null, &set, store, null, &sink.out, &sink.runs);
}

pub fn apply(s: Symmetry, p: [2]i64) [2]i64 {
    var x = p[0];
    var y = p[1];
    for (0..s.turns) |_| {
        const t = x;
        x = -y;
        y = t;
    }
    if (s.mirror) x = -x;
    return .{ x, y };
}

/// Parses `text` on a 1 nm grid, draws `layout`, computes the derived
/// layers, extracts nets and runs every DRC rule: one row per rule.
pub fn run(text: []const u8, layout: *const Layout) !Run {
    var result: Run = .{ .arena = .init(gpa), .rows = &.{} };
    errdefer result.deinit();
    const arena = result.arena.allocator();
    var strings: StrTable = .empty;
    defer strings.deinit(gpa);
    var diag: check.deck.compile.Diag = .{};
    const grid = try geom.Grid.init(1000);
    const parsed = ingest.deck.parseDeck(arena, gpa, text, grid, &strings, &diag.deck) catch |e| {
        for (diag.deck.diagnostics) |d| std.debug.print("deck: {s}\n", .{d.message});
        if (diag.deck.malformed.len > 0) std.debug.print("deck: {s}\n", .{diag.deck.malformed});
        return e;
    };
    var lb = testgen.shapes.LayoutBuilder.init(@intCast(parsed.layers.len()));
    defer lb.deinit(gpa);
    for (layout.layer.items, layout.xs.items, layout.ys.items) |name, xs, ys| {
        const id = parsed.layers.id(&strings, name) orelse std.debug.panic("the deck has no layer {s}", .{name});
        _ = try lb.push(gpa, @backingInt(id), xs, ys);
    }
    var store: GeometryStore = .empty;
    defer store.deinit(gpa);
    var ids: testgen.shapes.Ids = .{};
    defer ids.deinit(gpa);
    try lb.finish(gpa, &store, &ids);
    var provenance: ingest.Provenance = .{};
    defer provenance.deinit(gpa);
    try ingest.layout.deriveLayersInto(gpa, &store, &parsed.layers, &provenance, &strings, &.{});
    var nets: check.topology.NetTable = .{};
    defer nets.deinit(gpa);
    try check.topology.extractNetsInto(gpa, &store, &parsed.connectivity, &nets);
    var compiled = check.deck.compile.fromDeck(gpa, parsed, grid, &strings, &diag) catch |e| {
        std.debug.print("compile: {t} rule {s} param {s}\n", .{ e, if (@backingInt(diag.rule.rule) != std.math.maxInt(u32)) strings.resolve(diag.rule.rule) else "?", diag.rule.param });
        return e;
    };
    defer compiled.deinit(gpa);
    var out: Violations = .{};
    defer out.deinit(gpa);
    var runs: std.ArrayList(RuleRun) = .empty;
    defer runs.deinit(gpa);
    try drc.run(gpa, .cpu, null, &compiled.drc, &store, nets.netColumn(), &out, &runs);
    const rows = try arena.alloc(Row, runs.items.len);
    for (rows, runs.items) |*r, rr| {
        var found: std.ArrayList(@typeInfo(@FieldType(Row, "findings")).pointer.child) = .empty;
        for (0..out.len()) |k| {
            const v = out.get(@intCast(k));
            if (v.rule != rr.rule) continue;
            try found.append(arena, .{ .measured = v.measured, .limit = v.limit, .at = .{ v.at.x, v.at.y } });
        }
        r.* = .{ .id = try arena.dupe(u8, strings.resolve(rr.rule)), .outcome = rr.outcome, .examined = rr.examined, .findings = found.items };
    }
    result.rows = rows;
    return result;
}

/// Asserts each claim's rule ran and found exactly its findings, in any
/// order; `name` labels a failure.
pub fn checkCase(name: []const u8, text: []const u8, layout: *const Layout, expect: []const Claim) !void {
    var r = try run(text, layout);
    defer r.deinit();
    for (expect) |claim| {
        const row = r.row(claim.id);
        if (row.outcome != .ran) {
            std.debug.print("{s}: {s} did not run: {any}\n", .{ name, claim.id, row.outcome });
            return error.TestUnexpectedResult;
        }
        // Pinned claims first, so an unpinned one cannot take a pinned one's match.
        const want = try gpa.dupe(Finding, claim.findings);
        defer gpa.free(want);
        std.mem.sort(Finding, want, {}, pinnedFirst);
        const free = try gpa.alloc(bool, row.findings.len);
        defer gpa.free(free);
        @memset(free, true);
        for (want) |w| {
            const hit = for (row.findings, 0..) |f, k| {
                if (!free[k]) continue;
                if (w.measured) |m| if (!same(m, f.measured)) continue;
                if (w.limit) |l| if (!same(l, f.limit)) continue;
                if (w.at) |p| if (p[0] != f.at[0] or p[1] != f.at[1]) continue;
                break k;
            } else null;
            if (hit) |k| free[k] = false else {
                std.debug.print("{s}: {s} lacks {any}; it found {any}\n", .{ name, claim.id, w, row.findings });
                return error.TestUnexpectedResult;
            }
        }
        if (std.mem.indexOfScalar(bool, free, true) != null) {
            std.debug.print("{s}: {s} found more than claimed: {any}\n", .{ name, claim.id, row.findings });
            return error.TestUnexpectedResult;
        }
    }
}

/// `check` under every symmetry at every offset.
pub fn checkEverywhere(name: []const u8, text: []const u8, layout: *const Layout, expect: []const Claim) !void {
    return checkUnder(name, text, layout, expect, everySymmetry);
}

/// `check` under the four symmetries without a quarter turn: for a rule
/// tied to an axis.
pub fn checkAxes(name: []const u8, text: []const u8, layout: *const Layout, expect: []const Claim) !void {
    return checkUnder(name, text, layout, expect, noQuarterTurn);
}

/// `check` under the symmetries `keep` accepts, at every offset.
pub fn checkUnder(name: []const u8, text: []const u8, layout: *const Layout, expect: []const Claim, comptime keep: fn (Symmetry) bool) !void {
    var label: std.ArrayList(u8) = .empty;
    defer label.deinit(gpa);
    for (offsets) |off| for (symmetries) |s| {
        if (!keep(s)) continue;
        var moved: Layout = try layout.transformed(s, off[0], off[1]);
        defer moved.deinit();
        const al = moved.arena.allocator();
        const claims = try al.alloc(Claim, expect.len);
        for (claims, expect) |*cl, e| {
            const fs = try al.dupe(Finding, e.findings);
            for (fs) |*f| if (f.at) |p| {
                const q = apply(s, p);
                f.at = .{ q[0] + off[0], q[1] + off[1] };
            };
            cl.* = .{ .id = e.id, .findings = fs };
        }
        label.clearRetainingCapacity();
        try label.print(gpa, "{s}/{d}{s}+({d},{d})", .{ name, s.turns, if (s.mirror) "m" else "", off[0], off[1] });
        try checkCase(label.items, text, &moved, claims);
    };
}

/// Groups `(rule, finding)` claims into rows, one per id in `ids` in order:
/// an id with no claim must run and find nothing. In `arena`.
pub fn byRule(arena: Allocator, ids: []const []const u8, claims: []const struct { []const u8, Finding }) ![]const Claim {
    const out = try arena.alloc(Claim, ids.len);
    for (out, ids) |*o, id| {
        var fs: std.ArrayList(Finding) = .empty;
        for (claims) |c| if (std.mem.eql(u8, c[0], id)) try fs.append(arena, c[1]);
        o.* = .{ .id = id, .findings = fs.items };
    }
    return out;
}

/// A deck of `met1`, `met2` and `region`, then `rules`, in `arena`.
pub fn deck(arena: Allocator, rules: []const u8) ![]const u8 {
    return std.fmt.allocPrint(arena, "grid 1nm\nlayer met1 = gds(68, 20)\nlayer met2 = gds(69, 20)\nlayer region = gds(81, 1)\n{s}\n", .{rules});
}

/// A deck of one layer, `met1`, then `rules`.
pub fn oneLayerDeck(arena: Allocator, rules: []const u8) ![]const u8 {
    return std.fmt.allocPrint(arena, "grid 1nm\nlayer met1 = gds(68, 20)\n{s}\n", .{rules});
}

/// A deck on a 1 nm grid with each of `layers` on its own GDS layer, then
/// `body`.
pub fn newDeck(arena: Allocator, layers: []const []const u8, body: []const u8) ![]const u8 {
    var out: std.ArrayList(u8) = .empty;
    try out.appendSlice(arena, "grid 1nm\n");
    for (layers, 1..) |name, gds| try out.print(arena, "layer {s} = gds({d}, 0)\n", .{ name, gds });
    try out.appendSlice(arena, body);
    return out.items;
}

/// The largest `r` with `r * r <= n`: a Euclidean gap as the report floors it.
pub fn floorSqrt(n: i64) i64 {
    return @intCast(std.math.sqrt(@as(u64, @intCast(n))));
}

/// `outer` with `hole` cut out, as four abutting bands on `layer` that merge
/// into one figure with a hole.
pub fn ring(l: *Layout, layer: []const u8, outer: [4]i64, hole: [4]i64) !void {
    try l.rect(layer, outer[0], outer[1], outer[2], hole[1]);
    try l.rect(layer, outer[0], hole[3], outer[2], outer[3]);
    try l.rect(layer, outer[0], hole[1], hole[0], hole[3]);
    try l.rect(layer, hole[2], hole[1], outer[2], hole[3]);
}

/// `met1` rectangles `[xlo, ylo, xhi, yhi]`.
pub fn met1(boxes: []const [4]i64) !Layout {
    return layoutOf("met1", boxes);
}

/// Rectangles `[xlo, ylo, xhi, yhi]` on `layer`, a new layout.
pub fn layoutOf(layer: []const u8, boxes: []const [4]i64) !Layout {
    var l: Layout = .{};
    errdefer l.deinit();
    try l.rects(layer, boxes);
    return l;
}

/// `checkEverywhere` of one rule's claims (a `[]const Finding` or an
/// `Opt`), the layout then freed.
pub fn everywhere(name: []const u8, text: []const u8, layout: Layout, id: []const u8, findings: anytype) !void {
    var l = layout;
    defer l.deinit();
    const held = findings;
    return checkEverywhere(name, text, &l, &.{.{ .id = id, .findings = slice(&held) }});
}

/// `checkAxes` of one rule's claims, the layout then freed.
pub fn axes(name: []const u8, text: []const u8, layout: Layout, id: []const u8, findings: anytype) !void {
    var l = layout;
    defer l.deinit();
    const held = findings;
    return checkAxes(name, text, &l, &.{.{ .id = id, .findings = slice(&held) }});
}

/// The limit swept one grid step either side.
pub fn steps(limit: i64) [3]i64 {
    return .{ limit - 1, limit, limit + 1 };
}

/// One finding when `cond`, none otherwise: a claim built in a branch.
pub fn opt(cond: bool, f: Finding) Opt {
    return .{ .f = .{f}, .n = @intFromBool(cond) };
}

/// One finding measuring `measured` when it is below `limit`.
pub fn below(measured: i64, limit: i64) Opt {
    return opt(measured < limit, .length(measured));
}

/// The findings of an `Opt` or a slice, as a slice into `held`.
pub fn slice(held: anytype) []const Finding {
    const T = @TypeOf(held.*);
    if (T == Opt) return held.f[0..held.n];
    return held.*;
}

// ---- private ----

/// Whether two measurements agree: exactly, or to 1e-9 relative for a ratio.
fn same(x: Measurement, y: Measurement) bool {
    if (x.kind == .ratio and y.kind == .ratio) {
        const p = x.float();
        const q = y.float();
        return @abs(p - q) <= 1e-9 * @max(@max(@abs(p), @abs(q)), 1e-30);
    }
    return x.eql(y);
}

fn pinnedFirst(_: void, p: Finding, q: Finding) bool {
    const kp = [2]bool{ p.at == null, p.measured == null };
    const kq = [2]bool{ q.at == null, q.measured == null };
    const rank = struct {
        fn of(k: [2]bool) u8 {
            return @as(u8, @intFromBool(k[0])) * 2 + @intFromBool(k[1]);
        }
    }.of;
    return rank(kp) < rank(kq);
}

fn everySymmetry(_: Symmetry) bool {
    return true;
}

fn noQuarterTurn(s: Symmetry) bool {
    return s.turns % 2 == 0;
}
