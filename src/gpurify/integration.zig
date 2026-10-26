//! System-on-chip integration checks on a DEF design (catalog FLOW-003):
//! what a placed-and-routed block must satisfy beyond its shapes' design
//! rules, run with DRC when the layout is a DEF. In: the DEF and its LEF
//! library. Out: violations (error, on no layer, at the offending shape's
//! or component's lower-left corner) and one `RuleRun` per check, under
//! `rule_ids`. Ported from src/engine/integration.rs.
//!
//! | Id | Flags |
//! |---|---|
//! | `def.fill_outside_die` | a `FILLS` shape not wholly inside the `DIEAREA` |
//! | `def.component_outside_die` | a placed component's `SIZE` box not wholly inside the `DIEAREA` |
//! | `def.component_overlap` | two placed components' boxes overlapping in area, `COVER` macros aside (LEF `CLASS COVER`) |
//! | `def.off_site` | a placed `CORE` component on no site of any `ROW` (`origin + k·step`) |
//! | `def.pin_off_track` | a placed pin's shape centre on no routing track of its layer |
//! | `def.off_manufacturing_grid` | a shape vertex off the LEF `MANUFACTURINGGRID` |
//! | `def.cell_edge_spacing` | two placed cells' typed edges closer than `LEF58_CELLEDGESPACINGTABLE` allows (catalog DRC-127; ISPD 2014 Suite A slides 16, 27; ICCAD 2017 Problem C) |
//!
//! Cell edge spacing: a macro's `LEF58_EDGETYPE` types a side of its
//! `SIZE` box or a stretch of it (`CELLROW n`, `HALFROW n` of the first DEF
//! row's site height; `RANGE b e` along a top or bottom side); each typed
//! edge moves with its component, so a mirrored cell's `LEFT` edge lies on
//! its right. Any two parallel typed edges of different components sharing
//! a stretch of positive length are held to the last table entry naming
//! their pair; `EXCEPTABUTTED` exempts a zero gap; a filler has no edges;
//! an entry carrying an option no public text defines is not checked. A
//! check with nothing to examine runs and examines nothing.
//!
//! Contents:
//! - `pub const rule_ids: [7][]const u8`
//! - `pub fn check(scratch: Allocator, design: *const Design, strings: *const StrTable, out: *Violations, runs: *std.ArrayList(RuleRun)) Allocator.Error!void`

const std = @import("std");
const Allocator = std.mem.Allocator;
const geom = @import("geom");
const StrTable = geom.StrTable;
const lefdef = @import("ingest").lefdef;
const Design = lefdef.Design;
const Pt = lefdef.Pt;
const report = @import("check").report;
const Measurement = report.Measurement;
const Violations = report.Violations;
const RuleRun = report.RuleRun;

/// The checks' ids, in report order.
pub const rule_ids = [7][]const u8{
    "def.fill_outside_die",
    "def.component_outside_die",
    "def.component_overlap",
    "def.off_site",
    "def.pin_off_track",
    "def.off_manufacturing_grid",
    "def.cell_edge_spacing",
};

/// Findings gathered for the next `row`.
const Rows = struct {
    gpa: Allocator,
    strings: *const StrTable,
    out: *Violations,
    runs: *std.ArrayList(RuleRun),
    pending: std.ArrayList(Finding) = .empty,

    const Finding = struct { at: Pt, measured: Measurement, limit: Measurement };

    fn found(r: *Rows, at: Pt, measured: Measurement, limit: Measurement) Allocator.Error!void {
        try r.pending.append(r.gpa, .{ .at = at, .measured = measured, .limit = limit });
    }

    fn row(r: *Rows, name: []const u8, examined: u64) Allocator.Error!void {
        const rule = r.strings.get(name).?; // `internReportIds` interned it
        for (r.pending.items) |f| try r.out.push(r.gpa, .{ .rule = rule, .layer = report.no_layer, .severity = .@"error", .at = .{ .x = f.at[0], .y = f.at[1] }, .measured = f.measured, .limit = f.limit, .shape_a = report.no_shape, .shape_b = report.no_shape });
        try r.runs.append(r.gpa, .{ .rule = rule, .outcome = .ran, .examined = examined, .violations = std.math.lossyCast(u32, r.pending.items.len) });
        r.pending.clearRetainingCapacity();
    }
};

/// A placed component's box `{xlo, ylo, xhi, yhi}` and its macro's class.
const ComponentBox = struct { box: [4]i64, class: []const u8 };

/// One typed cell edge as placed: on the line `x = at` (vertical) or
/// `y = at`, from `lo` to `hi`, of type `kind` (an index into the table's
/// names), on component `comp`.
const PlacedEdge = struct { vertical: bool, at: i64, lo: i64, hi: i64, kind: u32, comp: u32 };

/// Appends every check's findings and one run each. Asserts the ids are
/// interned (`load.internReportIds`).
pub fn check(scratch: Allocator, design: *const Design, strings: *const StrTable, out: *Violations, runs: *std.ArrayList(RuleRun)) Allocator.Error!void {
    var r: Rows = .{ .gpa = scratch, .strings = strings, .out = out, .runs = runs };
    const zero: Measurement = .area(0);
    const die = design.def.die_area;
    var diag: lefdef.Diagnostic = .{};
    const shapes = lefdef.flatten(scratch, &design.def, &design.lef, &diag) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        error.Invalid => &.{},
    };

    // Fill outside the die: the area of the shape's box, against none.
    var examined: u64 = 0;
    for (shapes) |s| if (s.origin == .fill) {
        examined += 1;
        if (die.len != 0 and !contained(s.shape.ring, die)) {
            const b = s.shape.bbox();
            try r.found(.{ b[0], b[1] }, .area(@as(i128, b[2] - b[0]) * (b[3] - b[1])), zero);
        }
    };
    try r.row("def.fill_outside_die", examined);

    const boxes = try componentBoxes(scratch, design);
    examined = 0;
    for (boxes) |maybe| if (maybe) |cb| {
        examined += 1;
        const b = cb.box;
        const ring = [4]Pt{ .{ b[0], b[1] }, .{ b[2], b[1] }, .{ b[2], b[3] }, .{ b[0], b[3] } };
        if (die.len != 0 and !contained(&ring, die)) try r.found(.{ b[0], b[1] }, .area(@as(i128, b[2] - b[0]) * (b[3] - b[1])), zero);
    };
    try r.row("def.component_outside_die", examined);

    // Overlaps: a sweep in x over the boxes, COVER macros aside.
    var solid: std.ArrayList([4]i64) = .empty;
    for (boxes) |maybe| if (maybe) |cb| if (!std.mem.eql(u8, cb.class, "COVER")) try solid.append(scratch, cb.box);
    std.mem.sort([4]i64, solid.items, {}, lessBox);
    for (solid.items, 0..) |a, k| for (solid.items[k + 1 ..]) |b| {
        if (b[0] >= a[2]) break;
        const w = @min(a[2], b[2]) - b[0];
        const h = @min(a[3], b[3]) - @max(a[1], b[1]);
        if (w > 0 and h > 0) try r.found(.{ b[0], @max(a[1], b[1]) }, .area(@as(i128, w) * h), zero);
    };
    try r.row("def.component_overlap", solid.items.len);

    // Off site: a CORE component's placement point on no row's site.
    examined = 0;
    if (design.def.rows.len != 0) for (design.def.components, boxes) |comp, placed| {
        const p = comp.placement orelse continue;
        const cb = placed orelse continue;
        if (!std.mem.eql(u8, cb.class, "CORE")) continue;
        examined += 1;
        if (!onSite(design.def.rows, p.at)) try r.found(p.at, .count(0), .count(1));
    };
    try r.row("def.off_site", examined);

    // Pins off track: the shape's centre on a track of its layer.
    examined = 0;
    for (design.def.pins) |pin| for (pin.shapes) |shape| {
        const b = shape.bbox();
        // A centre between two grid points is on no track.
        if (@rem(b[0] + b[2], 2) != 0 or @rem(b[1] + b[3], 2) != 0) {
            examined += 1;
            try r.found(.{ b[0], b[1] }, .count(0), .count(1));
            continue;
        }
        const on = onTrack(design.def.tracks, shape.layer, .{ @divTrunc(b[0] + b[2], 2), @divTrunc(b[1] + b[3], 2) }) orelse continue;
        examined += 1;
        if (!on) try r.found(.{ b[0], b[1] }, .count(0), .count(1));
    };
    try r.row("def.pin_off_track", examined);

    // Manufacturing grid: every vertex of every shape drawn.
    examined = 0;
    if (design.lef.manufacturing_grid) |grid| if (grid > 0) for (shapes) |s| {
        examined += 1;
        for (s.shape.ring) |p| if (@rem(p[0], grid) != 0 or @rem(p[1], grid) != 0) {
            try r.found(p, .length(@max(@mod(p[0], grid), @mod(p[1], grid))), .length(0));
            break;
        };
    };
    try r.row("def.off_manufacturing_grid", examined);

    try r.row("def.cell_edge_spacing", try cellEdgeSpacing(scratch, design, &r));
}

// ---- private ----

/// Per component: its box, null when unplaced or of an unknown macro.
fn componentBoxes(scratch: Allocator, design: *const Design) Allocator.Error![]const ?ComponentBox {
    const out = try scratch.alloc(?ComponentBox, design.def.components.len);
    for (design.def.components, out) |comp, *o| {
        o.* = null;
        const p = comp.placement orelse continue;
        const m = findMacro(design, comp.model) orelse continue;
        const a = p.orient.apply(.{ 0, 0 });
        const b = p.orient.apply(m.size);
        const w = @abs(a[0] - b[0]);
        const h = @abs(a[1] - b[1]);
        o.* = .{ .box = .{ p.at[0], p.at[1], p.at[0] + @as(i64, @intCast(w)), p.at[1] + @as(i64, @intCast(h)) }, .class = m.class };
    }
    return out;
}

fn findMacro(design: *const Design, name: []const u8) ?*const lefdef.Macro {
    for (design.lef.macros.items) |*m| if (std.mem.eql(u8, m.name, name)) return m;
    return null;
}

fn lessBox(_: void, a: [4]i64, b: [4]i64) bool {
    return std.mem.order(i64, &a, &b) == .lt;
}

fn onSite(rows: []const lefdef.Row, p: Pt) bool {
    for (rows) |row| {
        if (onAxis(p[0], row.origin[0], row.step[0], row.num[0]) and onAxis(p[1], row.origin[1], row.step[1], row.num[1])) return true;
    }
    return false;
}

fn onAxis(v: i64, origin: i64, step: i64, num: i64) bool {
    const d = v - origin;
    if (step == 0) return d == 0;
    const k = @divTrunc(d, step);
    return @rem(d, step) == 0 and 0 <= k and k < num;
}

/// Whether the point is on a track of `layer`; null when `layer` has none.
fn onTrack(tracks: []const lefdef.Track, layer: []const u8, p: Pt) ?bool {
    var any = false;
    for (tracks) |t| {
        const has = for (t.layers) |l| (if (std.mem.eql(u8, l, layer)) break true) else false;
        if (!has) continue;
        any = true;
        const d = (if (t.x) p[0] else p[1]) - t.start;
        if (t.step > 0 and @rem(d, t.step) == 0 and 0 <= @divTrunc(d, t.step) and @divTrunc(d, t.step) < t.count) return true;
    }
    return if (any) false else null;
}

/// Whether `p` is inside the rectilinear ring or on its boundary.
fn inside(ring: []const Pt, p: Pt) bool {
    if (onBoundary(ring, p)) return true;
    var crossings = false;
    for (ring, 0..) |a, k| {
        const b = ring[(k + 1) % ring.len];
        // A vertical edge right of p crossing its row (half-open in y).
        if (a[0] == b[0] and a[0] > p[0] and @min(a[1], b[1]) <= p[1] and p[1] < @max(a[1], b[1])) crossings = !crossings;
    }
    return crossings;
}

fn onBoundary(ring: []const Pt, p: Pt) bool {
    for (ring, 0..) |a, k| {
        const b = ring[(k + 1) % ring.len];
        if (a[0] == b[0] and p[0] == a[0] and @min(a[1], b[1]) <= p[1] and p[1] <= @max(a[1], b[1])) return true;
        if (a[1] == b[1] and p[1] == a[1] and @min(a[0], b[0]) <= p[0] and p[0] <= @max(a[0], b[0])) return true;
    }
    return false;
}

/// Whether simple rectilinear `ring` lies wholly inside `die`: every vertex
/// of `ring` in `die`, no vertex of `die` strictly inside `ring`, and no
/// edge of `die` crossing an edge of `ring` inside both. Had `ring` left
/// `die`, the die's boundary would enter `ring` through one of those.
fn contained(ring: []const Pt, die: []const Pt) bool {
    for (ring) |p| if (!inside(die, p)) return false;
    for (die) |p| if (inside(ring, p) and !onBoundary(ring, p)) return false;
    for (ring, 0..) |a0, i| {
        const a1 = ring[(i + 1) % ring.len];
        for (die, 0..) |b0, j| {
            const b1 = die[(j + 1) % die.len];
            if (cross(a0, a1, b0, b1) or cross(b0, b1, a0, a1)) return false;
        }
    }
    return true;
}

/// A vertical edge `v` and a horizontal edge `h` crossing inside both.
fn cross(v0: Pt, v1: Pt, h0: Pt, h1: Pt) bool {
    const x = v0[0];
    const y = h0[1];
    return v0[0] == v1[0] and h0[1] == h1[1] and @min(h0[0], h1[0]) < x and x < @max(h0[0], h1[0]) and @min(v0[1], v1[1]) < y and y < @max(v0[1], v1[1]);
}

/// Every typed edge of every placed, non-filler component whose type the
/// table names; `names` filled with the table's type names.
fn placedEdgesInto(scratch: Allocator, design: *const Design, names: *std.ArrayList([]const u8), edges: *std.ArrayList(PlacedEdge)) Allocator.Error!void {
    const lef = &design.lef;
    for (lef.cell_edge_spacing.items) |e| for ([2][]const u8{ e.first, e.second }) |name| {
        if (indexOf(names.items, name) == null) try names.append(scratch, name);
    };
    // A cell spans whole rows of the first row's site.
    const row_height: i64 = if (design.def.rows.len == 0) 0 else for (lef.sites.items) |s| {
        if (std.mem.eql(u8, s.name, design.def.rows[0].site)) break s.size[1];
    } else 0;
    for (design.def.components, 0..) |component, comp| {
        const p = component.placement orelse continue;
        const cell = findMacro(design, component.model) orelse continue;
        if (cell.spacer) continue;
        const w = cell.size[0];
        const h = cell.size[1];
        const rows = if (row_height > 0) @max(@divTrunc(h, row_height), 1) else 1;
        const per_row = @divTrunc(h, rows);
        const a = p.orient.apply(.{ 0, 0 });
        const b = p.orient.apply(.{ w, h });
        const corner: Pt = .{ @min(a[0], b[0]), @min(a[1], b[1]) };
        for (cell.edge_types) |edge| {
            const kind = indexOf(names.items, edge.name) orelse continue;
            const vertical = edge.side == .left or edge.side == .right;
            const span: [2]i64 = switch (edge.span) {
                .cell_row => |k| if (vertical) .{ (@as(i64, k) - 1) * per_row, @min(@as(i64, k) * per_row, h) } else .{ 0, w },
                .half_row => |k| if (vertical) .{ @divTrunc((@as(i64, k) - 1) * per_row, 2), @min(@divTrunc(@as(i64, k) * per_row, 2), h) } else .{ 0, w },
                .range => |r| if (!vertical) r else .{ 0, h },
                .whole => if (vertical) .{ 0, h } else .{ 0, w },
            };
            const ends: [2]Pt = switch (edge.side) {
                .left => .{ .{ 0, span[0] }, .{ 0, span[1] } },
                .right => .{ .{ w, span[0] }, .{ w, span[1] } },
                .bottom => .{ .{ span[0], 0 }, .{ span[1], 0 } },
                .top => .{ .{ span[0], h }, .{ span[1], h } },
            };
            var placed: [2]Pt = undefined;
            for (ends, &placed) |e, *o| {
                const q = p.orient.apply(e);
                o.* = .{ p.at[0] + q[0] - corner[0], p.at[1] + q[1] - corner[1] };
            }
            const v = placed[0][0] == placed[1][0];
            const ax: usize = if (v) 1 else 0;
            try edges.append(scratch, .{ .vertical = v, .at = placed[0][1 - ax], .lo = @min(placed[0][ax], placed[1][ax]), .hi = @max(placed[0][ax], placed[1][ax]), .kind = @intCast(kind), .comp = @intCast(comp) });
        }
    }
}

fn indexOf(names: []const []const u8, name: []const u8) ?usize {
    for (names, 0..) |n, i| if (std.mem.eql(u8, n, name)) return i;
    return null;
}

/// `def.cell_edge_spacing`: each pair too close as a finding of `r`;
/// returns the typed edges examined.
fn cellEdgeSpacing(scratch: Allocator, design: *const Design, r: *Rows) Allocator.Error!u64 {
    var names: std.ArrayList([]const u8) = .empty;
    var edges: std.ArrayList(PlacedEdge) = .empty;
    try placedEdgesInto(scratch, design, &names, &edges);
    const table = design.lef.cell_edge_spacing.items;
    var reach: i64 = 0;
    for (table) |e| reach = @max(reach, e.spacing);
    std.mem.sort(PlacedEdge, edges.items, {}, lessEdge);
    for (edges.items, 0..) |a, i| for (edges.items[i + 1 ..]) |b| {
        if (b.vertical != a.vertical or b.at - a.at >= reach) break;
        const lo = @max(a.lo, b.lo);
        const hi = @min(a.hi, b.hi);
        if (a.comp == b.comp or lo >= hi) continue;
        // The last entry naming the pair either way round, unless it
        // carries an undefined option.
        const entry = for (0..table.len) |k| {
            const e = table[table.len - 1 - k];
            const x = names.items[a.kind];
            const y = names.items[b.kind];
            if ((std.mem.eql(u8, e.first, x) and std.mem.eql(u8, e.second, y)) or (std.mem.eql(u8, e.second, x) and std.mem.eql(u8, e.first, y))) break e;
        } else continue;
        if (entry.undefined.len != 0) continue;
        const gap = b.at - a.at;
        if (gap >= entry.spacing or (gap == 0 and entry.except_abutted)) continue;
        const along = @divTrunc(lo + hi, 2);
        const mid = @divTrunc(a.at + b.at, 2);
        try r.found(if (a.vertical) .{ mid, along } else .{ along, mid }, .length(gap), .length(entry.spacing));
    };
    return edges.items.len;
}

fn lessEdge(_: void, a: PlacedEdge, b: PlacedEdge) bool {
    const ka = [6]i64{ @intFromBool(a.vertical), a.at, a.lo, a.hi, a.comp, a.kind };
    const kb = [6]i64{ @intFromBool(b.vertical), b.at, b.lo, b.hi, b.comp, b.kind };
    return std.mem.order(i64, &ka, &kb) == .lt;
}

test "containment in an L- and a U-shaped die" {
    // Oracle: hand-derived on an L-shaped die (0,0)-(100,0)-(100,50)-
    // (50,50)-(50,100)-(0,100) and a U-shaped one with a notch from x = 30
    // to 70 down to y = 40: a box in the L's foot is inside, the boundary
    // counts as inside (DEF lets a shape touch the die edge), and a box
    // bridging the U's notch is outside although all four of its corners
    // are inside and no die vertex is in it.
    const die = [_]Pt{ .{ 0, 0 }, .{ 100, 0 }, .{ 100, 50 }, .{ 50, 50 }, .{ 50, 100 }, .{ 0, 100 } };
    const rect = struct {
        fn f(x0: i64, y0: i64, x1: i64, y1: i64) [4]Pt {
            return .{ .{ x0, y0 }, .{ x1, y0 }, .{ x1, y1 }, .{ x0, y1 } };
        }
    }.f;
    try std.testing.expect(inside(&die, .{ 100, 50 }) and inside(&die, .{ 10, 10 }));
    try std.testing.expect(!inside(&die, .{ 75, 75 }));
    try std.testing.expect(contained(&rect(0, 0, 100, 50), &die));
    try std.testing.expect(contained(&rect(10, 10, 40, 90), &die));
    try std.testing.expect(!contained(&rect(40, 40, 60, 60), &die));
    try std.testing.expect(!contained(&rect(90, 40, 110, 45), &die));
    const u = [_]Pt{ .{ 0, 0 }, .{ 100, 0 }, .{ 100, 100 }, .{ 70, 100 }, .{ 70, 40 }, .{ 30, 40 }, .{ 30, 100 }, .{ 0, 100 } };
    try std.testing.expect(!contained(&rect(10, 50, 90, 60), &u));
    try std.testing.expect(contained(&rect(10, 10, 90, 40), &u));
    try std.testing.expect(contained(&rect(70, 50, 100, 60), &u));
}
