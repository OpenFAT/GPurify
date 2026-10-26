//! The deck builders of the multi-layer kinds that need more than a line:
//! density windows and bands, enclosures with wire bands, and the via and
//! cut kinds (`density`, `global_density`, `density_balance`,
//! `cover_density`, `via_redundancy`, `cut_area_change`, `min_enclosure`,
//! `asymmetric_enclosure`, `minimum_cut`, `via_stack`, `metal_width_via`,
//! `cut_spacing`, `cut_class_spacing`, `keep_out_zone`). In: one row's
//! `Ctx`. Out: its `Rule`, side tables filed into the set. Ported from the
//! matching arms of crates/check/src/drc/ruleset.rs `RuleSet::from_deck`.
//!
//! Contents:
//! - `pub fn density(c: Ctx) Error!Rule`, `globalDensity`, `densityBalance`, `coverDensity`,
//!   `viaRedundancy`, `cutAreaChange`, `minimumCut`, `viaStack`, `metalWidthVia`, `cutSpacing`,
//!   `cutClassSpacing`, `keepOutZone`
//! - `pub fn enclosure(r: Reader, param: []const u8) Error!Enclosure`

const std = @import("std");
const geom = @import("geom");
const Dbu = geom.Dbu;
const LayerId = geom.LayerId;
const rows = @import("rows.zig");
const Rule = rows.Rule;
const params = @import("params.zig");
const Error = params.Error;
const Reader = params.Reader;
const Ctx = @import("compile.zig").Ctx;
const tables = @import("tables.zig");

pub fn density(c: Ctx) Error!Rule {
    const r = c.r;
    const l = try r.bounded();
    const window = try r.length("window");
    const step = try r.length("step");
    return .{ .density = .{ .layer = l.layer, .boundary = l.other, .window = window, .step = step, .limit = try r.ratio("limit"), .sense = try r.sense() } };
}

pub fn globalDensity(c: Ctx) Error!Rule {
    const r = c.r;
    const l = try r.bounded();
    return .{ .global_density = .{ .layer = l.layer, .boundary = l.other, .limit = try r.ratio("limit"), .sense = try r.sense() } };
}

pub fn densityBalance(c: Ctx) Error!Rule {
    const r = c.r;
    const boundary = try thirdLayer(r);
    return .{ .density_balance = .{
        .a = r.layer(0),
        .b = r.layer(1),
        .boundary = boundary,
        .window = try r.length("window"),
        .step = try r.length("step"),
        .limit = try r.ratio("limit"),
    } };
}

pub fn coverDensity(c: Ctx) Error!Rule {
    const r = c.r;
    const boundary = try thirdLayer(r);
    const bands: tables.CoverBands = .{ .cover = try r.list(.ratio, "cover"), .density = try r.list(.ratio, "density"), .inclusive = try r.flag("inclusive") };
    if (!bands.isValid()) return r.badTable();
    const index = try c.rs.addCoverBands(c.gpa, bands);
    return .{ .cover_density = .{
        .layer = r.layer(0),
        .cover = r.layer(1),
        .boundary = boundary,
        .window = try r.length("window"),
        .step = try r.length("step"),
        .bands = index,
    } };
}

pub fn viaRedundancy(c: Ctx) Error!Rule {
    const r = c.r;
    try r.layerCount(3);
    return .{ .via_redundancy = .{
        .cut = r.layer(0),
        .lower = r.layer(1),
        .upper = r.layer(2),
        .pitch = try r.length("pitch"),
        .space = try r.atLeastZero("space"),
        .limit = try r.ratio("limit"),
    } };
}

pub fn cutAreaChange(c: Ctx) Error!Rule {
    const r = c.r;
    try r.layerCount(4);
    const bands: tables.CutAreaBands = .{ .cuts = try r.list(.count, "cuts"), .change = try r.list(.area, "change") };
    if (!bands.isValid()) return r.badTable();
    const index = try c.rs.addCutAreaBands(c.gpa, bands);
    return .{ .cut_area_change = .{ .pre = r.layer(0), .post = r.layer(1), .lower = r.layer(2), .upper = r.layer(3), .bands = index } };
}

/// `min_enclosure` and `asymmetric_enclosure`: two layers, the limit under
/// `param`, and the wire band.
pub fn enclosure(r: Reader, param: []const u8) Error!rows.Enclosure {
    const l = try r.two();
    return .{ .outer = l[0], .inner = l[1], .limit = try r.length(param), .wire = try r.wire() };
}

pub fn minimumCut(c: Ctx) Error!Rule {
    const r = c.r;
    try r.layerCount(3);
    const width = try r.length("width");
    const within = try r.optLength("within");
    const min_count = try r.count("min_count", std.math.maxInt(u16));
    const thin: ?rows.Pair = if (r.stated("length")) .{ try r.length("length"), try r.length("distance") } else null;
    return .{ .minimum_cut = .{
        .cut = r.layer(0),
        .wide = r.layer(1),
        .other = r.layer(2),
        .width = width,
        .thin = thin,
        .within = within,
        .min_count = @intCast(min_count),
    } };
}

pub fn viaStack(c: Ctx) Error!Rule {
    const r = c.r;
    if (r.spec.layer_len < 2) return wrongCount(r, 2);
    const max_height = try r.count("max_height", std.math.maxInt(u16));
    const single = try r.optFlag("single");
    // Metals alternate with the cuts, a metal at each end.
    if (single and (r.spec.layer_len < 5 or r.spec.layer_len % 2 == 0)) return wrongCount(r, 5);
    const index = try c.rs.stacks.push(c.gpa, r.table.layersOf(r.spec));
    return .{ .via_stack = .{ .stack = index, .single = single, .max_height = @intCast(max_height) } };
}

pub fn metalWidthVia(c: Ctx) Error!Rule {
    const r = c.r;
    try r.layerCount(3);
    return .{ .metal_width_via = .{
        .cut = r.layer(0),
        .below = r.layer(1),
        .above = r.layer(2),
        .below_band = try band(r, "below_min", "below_max"),
        .above_band = try band(r, "above_min", "above_max"),
        .width = try r.length("cut_width"),
        .height = try r.length("cut_height"),
    } };
}

pub fn cutSpacing(c: Ctx) Error!Rule {
    const r = c.r;
    const layer = try r.one();
    const center = try r.flag("center");
    // No `adjacent` holds every cut.
    var adjacent: u16 = 0;
    var within: Dbu = 0;
    if (r.stated("adjacent")) {
        adjacent = @intCast(try r.count("adjacent", std.math.maxInt(u16)));
        within = try r.length("within");
    }
    return .{ .cut_spacing = .{ .layer = layer, .center = center, .adjacent = adjacent, .within = within, .limit = try r.length("limit") } };
}

pub fn cutClassSpacing(c: Ctx) Error!Rule {
    const r = c.r;
    const layer = try r.one();
    const t: tables.CutClassTable = .{ .short = try r.list(.length, "class_short"), .long = try r.list(.length, "class_long"), .space = try r.list(.length, "space") };
    if (!t.isValid()) return r.badTable();
    return .{ .cut_class_spacing = .{ .layer = layer, .table = try c.rs.addCutClassTable(c.gpa, t) } };
}

pub fn keepOutZone(c: Ctx) Error!Rule {
    const r = c.r;
    const layer = try r.one();
    // A class is a size either way round: shorter side first.
    const class = sorted(try r.length("short"), try r.length("long"));
    const to: ?rows.Pair = if (r.stated("to_short")) sorted(try r.length("to_short"), try r.length("to_long")) else null;
    return .{ .keep_out_zone = .{
        .layer = layer,
        .class = class,
        .to = to,
        .end = .{ try r.atLeastZero("end_side"), try r.atLeastZero("end_forward") },
        .side = .{ try r.atLeastZero("side_side"), try r.atLeastZero("side_forward") },
    } };
}

// ---- private ----

/// Two layers, then an optional third.
fn thirdLayer(r: Reader) Error!?LayerId {
    if (r.spec.layer_len == 2) return null;
    try r.layerCount(3);
    return r.layer(2);
}

fn wrongCount(r: Reader, expected: u32) Error {
    r.diag.* = .{ .rule = r.spec.id, .kind = r.spec.kind, .expected = expected, .found = r.spec.layer_len };
    return error.WrongLayerCount;
}

/// A `metal_width_via` band `[lo, hi]`: from `lo` up to `hi + 1`.
fn band(r: Reader, lo_name: []const u8, hi_name: []const u8) Error!rows.WireBand {
    const lo = try r.length(lo_name);
    const hi = try r.length(hi_name);
    if (lo > hi) return r.nonPositive(hi - lo);
    return .{ .from = lo, .below = hi + 1 };
}

fn sorted(a: Dbu, b: Dbu) rows.Pair {
    return .{ @min(a, b), @max(a, b) };
}
