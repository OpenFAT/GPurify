//! The units half of geom: the coordinate domain, the exact grid boundary,
//! interning, quantities and cross-dimension arithmetic. Ported from
//! crates/geom/tests/units/{dbu,grid,intern,qty,arith}.rs.
//!
//! The Rust suite drew from `gpurify_testgen::Rng`; until testgen's port
//! lands these draw from `std.Random.DefaultPrng` with the same seeds. Every
//! randomized test here is a law, so it holds on any stream.

const std = @import("std");
const testing = std.testing;
const geom = @import("geom");
const Dbu = geom.Dbu;
const DbuArea = geom.DbuArea;
const Grid = geom.Grid;
const Qty = geom.Qty;
const max = geom.max_abs_dbu;

fn prng(seed: u64) std.Random.DefaultPrng {
    return .init(seed);
}

/// A coordinate the test asserts is inside the domain.
fn coord(raw: i64) !Dbu {
    try testing.expect(geom.inDomain(raw));
    return raw;
}

fn nm(raw: f64) Qty(.length, .nano) {
    return .{ .raw = raw };
}

fn um(raw: f64) Qty(.length, .micro) {
    return .{ .raw = raw };
}

// ---- dbu.rs ----

test "the coordinate domain is closed at max_abs_dbu" {
    // Oracle: closed form. The domain is stated in the doc comment as
    // `±MAX_ABS_DBU`, so the table is that statement: the endpoints are legal and
    // round-trip through `raw`, and one unit past either endpoint is `None`.
    for ([_]i64{ 0, 1, -1, 4_096, -4_096, max - 1, max, -max }) |raw| {
        try testing.expect(geom.inDomain(raw));
    }
    for ([_]i64{ max + 1, -(max + 1), max * 2, std.math.maxInt(i64), std.math.minInt(i64) + 1, std.math.minInt(i64) }) |raw| {
        try testing.expect(!geom.inDomain(raw));
    }
}

test "the widening product at the domain corner is exactly two to the eighty" {
    // Oracle: closed form. The doc comment justifies `MAX_ABS_DBU` by saying the
    // product of two coordinates is at most `2^80`. That is a number, so it is
    // asserted as a number: the four sign combinations of the corner case land on
    // `±2^80` exactly, in `i128`, with no wrap.
    const corner: DbuArea = 1 << 80;
    try testing.expectEqual(corner, geom.mulWide(max, max));
    try testing.expectEqual(corner, geom.mulWide(-max, -max));
    try testing.expectEqual(-corner, geom.mulWide(max, -max));
    try testing.expectEqual(-corner, geom.mulWide(-max, max));
}

test "the widening product commutes and composes signs" {
    // Oracle: law. Multiplication commutes and negation distributes over it. Both
    // hold for every pair, and together they catch the argument transposition and
    // the dropped sign that the corner-case test above cannot see.
    var p = prng(97);
    const r = p.random();
    for (0..1024) |_| {
        const a = try coord(r.intRangeLessThan(i64, -max, max + 1));
        const b = try coord(r.intRangeLessThan(i64, -max, max + 1));
        try testing.expectEqual(geom.mulWide(a, b), geom.mulWide(b, a));
        try testing.expectEqual(-geom.mulWide(a, b), geom.mulWide(-a, b));
        try testing.expectEqual(geom.mulWide(a, b), geom.mulWide(-a, -b));
    }
}

test "coordinate addition and subtraction invert each other" {
    // Oracle: law. Coordinates form a group under addition: subtracting what was
    // added restores the original, a value minus itself is zero, and double
    // negation is the identity.
    var p = prng(13);
    const r = p.random();
    for (0..1024) |_| {
        const a = try coord(r.intRangeLessThan(i64, -max / 2, max / 2));
        const b = try coord(r.intRangeLessThan(i64, -max / 2, max / 2));
        try testing.expectEqual(a, (a + b) - b);
        try testing.expectEqual(a, (a - b) + b);
        try testing.expectEqual(a - b, a + (-b));
        try testing.expectEqual(0, a - a);
        try testing.expectEqual(a, -(-a));
    }
}

test "absolute value is the magnitude and stays inside the domain" {
    // Oracle: law. Absolute value is idempotent, sign-blind, and never leaves the
    // domain — the endpoints are where it would.
    try testing.expectEqual(@as(u64, max), @abs(@as(Dbu, -max)));
    var p = prng(23);
    const r = p.random();
    for (0..1024) |_| {
        const value = try coord(r.intRangeLessThan(i64, -max, max + 1));
        try testing.expectEqual(@abs(value), @abs(-value));
        try testing.expect(geom.inDomain(@intCast(@abs(value))));
    }
}

test "area addition and subtraction invert each other" {
    // Oracle: law. An area is a plain `i128`, so addition and subtraction cancel.
    // Drawn as full-domain products so the operands reach `±2^80`: an area that
    // had quietly become an `i64` passes at layout scale and wraps here.
    var p = prng(59);
    const r = p.random();
    for (0..1024) |_| {
        const a = geom.mulWide(r.intRangeLessThan(i64, -max, max + 1), r.intRangeLessThan(i64, -max, max + 1));
        const b = geom.mulWide(r.intRangeLessThan(i64, -max, max + 1), r.intRangeLessThan(i64, -max, max + 1));
        try testing.expectEqual(a, (a + b) - b);
        try testing.expectEqual(a, (a - b) + b);
        try testing.expectEqual(0, a - a);
    }
}

test "the widening product distributes over area addition" {
    // Oracle: law. The product of two coordinates and their sum-of-areas agree
    // with the distributive law, `a*(b+c) == a*b + a*c`, which ties `mul_wide` to
    // `DbuArea`'s addition.
    var p = prng(71);
    const r = p.random();
    for (0..1024) |_| {
        const a = try coord(r.intRangeLessThan(i64, -max, max + 1));
        const b = try coord(r.intRangeLessThan(i64, -max / 2, max / 2));
        const c = try coord(r.intRangeLessThan(i64, -max / 2, max / 2));
        try testing.expectEqual(geom.mulWide(a, b + c), geom.mulWide(a, b) + geom.mulWide(a, c));
    }
}

// ---- grid.rs ----

test "an on-grid length converts exactly" {
    // Oracle: closed form. `dbu = length_in_micrometres * dbu_per_um`, computed on
    // paper for each row, including a length of exactly one grid unit and zero.
    const Row = struct { i64, f64, i64 };
    const nanometres = [_]Row{
        .{ 1_000, 0.0, 0 },     .{ 1_000, 1.0, 1 },         .{ 1_000, -1.0, -1 }, .{ 1_000, 45.0, 45 },
        .{ 1_000, -45.0, -45 }, .{ 1_000, 1_000.0, 1_000 }, .{ 200, 0.0, 0 },     .{ 200, 5.0, 1 },
        .{ 200, -5.0, -1 },     .{ 200, 45.0, 9 },          .{ 200, -50.0, -10 }, .{ 200, 1_000.0, 200 },
    };
    // Every value here is exact in binary, keeping the test about the
    // conversion rather than about `f64` rounding.
    const micrometres = [_]Row{
        .{ 1_000, 1.0, 1_000 }, .{ 1_000, 2.0, 2_000 }, .{ 1_000, -0.25, -250 },
        .{ 200, 0.5, 100 },     .{ 200, 1.0, 200 },     .{ 200, -2.0, -400 },
    };
    for (nanometres) |row| try testing.expectEqual(row[2], try (try Grid.init(row[0])).toDbu(nm(row[1])));
    for (micrometres) |row| try testing.expectEqual(row[2], try (try Grid.init(row[0])).toDbu(um(row[1])));
}

test "an off-grid length is refused rather than rounded" {
    // Oracle: closed form. Each row lands strictly between two grid units, so
    // there is a nearby integer a rounding implementation would return. Half a
    // unit is where round-half-up and round-half-even disagree.
    const off_grid = [_]struct { i64, f64 }{
        .{ 1_000, 0.5 }, .{ 1_000, 2.5 }, .{ 1_000, -2.5 }, .{ 1_000, 0.25 },
        .{ 200, 1.0 },   .{ 200, -1.0 },  .{ 200, 47.0 },   .{ 200, 2.5 },
    };
    for (off_grid) |row| try testing.expectError(error.NotOnGrid, (try Grid.init(row[0])).toDbu(nm(row[1])));
}

test "a length beyond the coordinate domain is out of range" {
    // Oracle: closed form. The last legal coordinate is `MAX_ABS_DBU`, which on a
    // 1 nm grid is that many nanometres, so the boundary is stated on both sides.
    // The gross overshoot guards against a saturating float-to-int cast.
    const edge: f64 = @floatFromInt(max);
    const one_nm = try Grid.init(1_000);
    try testing.expectEqual(max, try one_nm.toDbu(nm(edge)));
    try testing.expectEqual(-max, try one_nm.toDbu(nm(-edge)));
    for ([_]f64{ edge + 1.0, -edge - 1.0, edge * 2.0, 1e18, -1e18, 1e30 }) |beyond| {
        try testing.expectError(error.OutOfRange, one_nm.toDbu(nm(beyond)));
    }
}

test "a non-finite length is refused before anything else" {
    // Oracle: closed form. NaN and the infinities are `NotFinite`, first in the
    // documented order, even where the scale would also make them out of range.
    const g = try Grid.init(1_000);
    for ([_]f64{ std.math.nan(f64), std.math.inf(f64), -std.math.inf(f64) }) |bad| {
        try testing.expectError(error.NotFinite, g.toDbu(nm(bad)));
    }
    // A length too small to reach one unit is off grid, also when the
    // scaling underflows it to exactly 0 (the fail-open case).
    try testing.expectError(error.NotOnGrid, g.toDbu(Qty(.length, .atto){ .raw = 1.0 }));
    try testing.expectError(error.NotOnGrid, (try Grid.init(1)).toDbu(nm(5e-324)));
}

test "a grid resolution must be a positive count" {
    // Oracle: closed form. A resolution is a count of database units per
    // micrometre, so zero and every negative are meaningless and one is the
    // smallest that is not.
    for ([_]i64{ 0, -1, -1_000, std.math.minInt(i64) }) |bad| {
        try testing.expectError(error.BadResolution, Grid.init(bad));
    }
    for ([_]i64{ 1, 2, 200, 1_000, 10_000 }) |good| {
        try testing.expectEqual(good, (try Grid.init(good)).dbu_per_um);
    }
}

test "converting a coordinate to a length and back is the identity" {
    // Oracle: law. `to_length` is total because every `Dbu` is on the grid by
    // construction, so converting out and back is the identity for every
    // coordinate on every grid. The resolutions all divide a thousand, so the
    // intermediate nanometre value is exact.
    for ([_]i64{ 1, 2, 5, 200, 1_000 }) |dbu_per_um| {
        const g = try Grid.init(dbu_per_um);
        for ([_]i64{ max, -max, max - 1, 0 }) |edge| {
            try testing.expectEqual(edge, try g.toDbu(g.toLength(edge)));
        }
        var p = prng(19);
        const r = p.random();
        for (0..256) |_| {
            const value = r.intRangeLessThan(i64, -1_000_000, 1_000_001);
            try testing.expectEqual(value, try g.toDbu(g.toLength(value)));
        }
    }
}

test "a coordinate measures a thousand nanometres over the resolution" {
    // Oracle: closed form. One database unit is `1000 / dbu_per_um` nanometres.
    // This pins the direction the round-trip law above cannot.
    const cases = [_]struct { i64, i64, f64 }{
        .{ 1_000, 0, 0.0 }, .{ 1_000, 1, 1.0 }, .{ 1_000, -45, -45.0 }, .{ 200, 1, 5.0 },
        .{ 200, 9, 45.0 },  .{ 1, 1, 1_000.0 }, .{ 2, 3, 1_500.0 },
    };
    for (cases) |c| {
        try testing.expectApproxEqAbs(c[2], (try Grid.init(c[0])).toLength(c[1]).raw, 1e-9);
    }
}

// ---- intern.rs ----

/// Distinct names, seeded. The index prefix guarantees distinctness; the random
/// suffix stops the corpus being sorted on arrival.
fn distinctNames(gpa: std.mem.Allocator, count: usize, seed: u64) ![][]u8 {
    var p = prng(seed);
    const names = try gpa.alloc([]u8, count);
    for (names, 0..) |*n, i| n.* = try std.fmt.allocPrint(gpa, "n{d}_{x}", .{ i, p.random().int(u64) });
    return names;
}

test "interning a name twice gives one id and resolve inverts it" {
    // Oracle: law. Interning is idempotent and `resolve` inverts it — the two
    // properties `crate::intern`'s doc comment states outright.
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const gpa = arena.allocator();
    const names = try distinctNames(gpa, 64, 7);
    var table: geom.StrTable = .empty;
    const first = try gpa.alloc(geom.StrId, names.len);
    for (names, first) |n, *id| id.* = try table.intern(gpa, n);
    for (names, first) |n, id| try testing.expectEqual(id, try table.intern(gpa, n));
    try testing.expectEqual(names.len, table.count());
    for (names, first) |n, id| try testing.expectEqualStrings(n, table.resolve(id));
}

test "interning order is id order" {
    // Oracle: closed form. ARCHITECTURE.md (Determinism): ids follow interning
    // order, so the k-th new name gets id k and a repeat issues nothing new.
    var table: geom.StrTable = .empty;
    defer table.deinit(testing.allocator);
    for ([_][]const u8{ "VDD", "VSS", "VDD", "", "net1" }, [_]u32{ 0, 1, 0, 2, 3 }) |n, want| {
        try testing.expectEqual(want, @backingInt(try table.intern(testing.allocator, n)));
    }
}

test "distinct names get distinct ids" {
    // Oracle: law. Two ids issued by one table are equal exactly when the names
    // were. A table that handed out one id for everything would satisfy
    // idempotence and fail this.
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const gpa = arena.allocator();
    const names = try distinctNames(gpa, 128, 13);
    var table: geom.StrTable = .empty;
    const ids = try gpa.alloc(u32, names.len);
    for (names, ids) |n, *id| id.* = @backingInt(try table.intern(gpa, n));
    std.mem.sort(u32, ids, {}, std.sort.asc(u32));
    for (ids[1..], ids[0 .. ids.len - 1]) |b, a| try testing.expect(a != b);
}

test "get finds every interned name in any arrival order and refuses the rest" {
    // Oracle: law. `get` finds every name that was interned, whatever order they
    // arrived in, and refuses every name that was not — a consumer that must not
    // grow the table gets null, not a fresh id.
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const gpa = arena.allocator();
    const names = try distinctNames(gpa, 96, 21);
    var p = prng(4);
    p.random().shuffle([]u8, names);
    var table: geom.StrTable = .empty;
    for (names) |n| _ = try table.intern(gpa, n);
    const before = table.count();
    for (names) |n| try testing.expectEqualStrings(n, table.resolve(table.get(n).?));
    try testing.expectEqual(null, table.get("a name that was never interned"));
    try testing.expectEqual(before, table.count());
}

test "two interning orders give the same set of ids and the same names back" {
    // Oracle: law. The id a name receives depends on the order names arrived in,
    // but the set of ids does not, and neither does what any of them resolve to.
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const gpa = arena.allocator();
    const names = try distinctNames(gpa, 48, 3);
    const shuffled = try gpa.dupe([]u8, names);
    var p = prng(9);
    p.random().shuffle([]u8, shuffled);

    var forward: geom.StrTable = .empty;
    var reverse: geom.StrTable = .empty;
    const forward_ids = try gpa.alloc(u32, names.len);
    const reverse_ids = try gpa.alloc(u32, names.len);
    for (names, forward_ids) |n, *id| id.* = @backingInt(try forward.intern(gpa, n));
    for (shuffled) |n| _ = try reverse.intern(gpa, n);
    for (names, reverse_ids) |n, *id| id.* = @backingInt(reverse.get(n).?);
    std.mem.sort(u32, forward_ids, {}, std.sort.asc(u32));
    std.mem.sort(u32, reverse_ids, {}, std.sort.asc(u32));
    try testing.expectEqualSlices(u32, forward_ids, reverse_ids);
    try testing.expectEqual(forward.count(), reverse.count());
    for (names) |n| try testing.expectEqualStrings(n, reverse.resolve(reverse.get(n).?));
}

// ---- qty.rs ----

/// Restate at prefix `q` and back at `p`.
fn expectRoundTrips(comptime dim: geom.Dimension, comptime p: geom.Prefix, comptime q: geom.Prefix, raw: f64) !void {
    const original: Qty(dim, p) = .{ .raw = raw };
    try testing.expectApproxEqRel(raw, original.to(q).to(p).raw, 1e-12);
}

/// Render one quantity and check it against its expected suffix. The numeric
/// head is parsed back rather than matched against a literal: the value's
/// spelling is a formatting choice, the prefix letter is not.
fn expectRendersAs(comptime dim: geom.Dimension, comptime p: geom.Prefix, raw: f64, suffix: []const u8) !void {
    var buf: [64]u8 = undefined;
    const shown = try std.fmt.bufPrint(&buf, "{f}", .{Qty(dim, p){ .raw = raw }});
    try testing.expect(std.mem.endsWith(u8, shown, suffix));
    const head = std.mem.trim(u8, shown[0 .. shown.len - suffix.len], " ");
    try testing.expectApproxEqAbs(raw, try std.fmt.parseFloat(f64, head), 1e-12);
}

test "a quantity prints its value followed by its prefixed symbol" {
    // Oracle: closed form. The SI prefix table is the oracle: `10^-18` is `a`,
    // `10^-15` is `f`, `10^-3` is `m`, `10^0` is nothing at all, `10^3` is `k`,
    // `10^6` is `M`. The dimension contributes its base symbol unprefixed.
    try expectRendersAs(.voltage, .base, 1.8, "V");
    try expectRendersAs(.voltage, .milli, -250.0, "mV");
    try expectRendersAs(.voltage, .kilo, 1.2, "kV");
    try expectRendersAs(.capacitance, .atto, 3.0, "aF");
    try expectRendersAs(.capacitance, .femto, -0.25, "fF");
    try expectRendersAs(.capacitance, .pico, 12.5, "pF");
    try expectRendersAs(.resistance, .milli, 200.0, "mohm");
    try expectRendersAs(.resistance, .base, 50.0, "ohm");
    try expectRendersAs(.resistance, .mega, 1.0, "Mohm");
    try expectRendersAs(.length, .nano, 45.0, "nm");
    try expectRendersAs(.length, .giga, 0.5, "Gm");
    // Micro is ASCII `u`, the choice the Zig port's doc comment makes.
    try expectRendersAs(.current, .micro, 7.0, "uA");
}

test "restating at the same prefix is exactly the identity" {
    // Oracle: closed form. Restating at the prefix a quantity already carries
    // scales it by `10^0`, which is multiplication by one, so the result is the
    // original bit for bit.
    for ([_]f64{ 0.0, 1.8, -3.5, 1e-18, 1e18, 123.456_789 }) |raw| {
        try testing.expectEqual(raw, (Qty(.voltage, .base){ .raw = raw }).to(.base).raw);
        try testing.expectEqual(raw, (Qty(.capacitance, .atto){ .raw = raw }).to(.atto).raw);
        try testing.expectEqual(raw, (Qty(.voltage, .kilo){ .raw = raw }).to(.kilo).raw);
    }
}

test "restating a prefix and restating it back returns the original" {
    // Oracle: law. Restating a quantity at another prefix and back is the
    // identity, for every value and every pair of prefixes, to a relative 1e-12.
    for ([_]f64{ 1.8, -3.5, 1e-6, 4.2e7, 6.022e23 }) |raw| {
        try expectRoundTrips(.capacitance, .atto, .femto, raw);
        try expectRoundTrips(.capacitance, .atto, .base, raw);
        try expectRoundTrips(.capacitance, .femto, .pico, raw);
        try expectRoundTrips(.voltage, .base, .micro, raw);
        try expectRoundTrips(.voltage, .milli, .kilo, raw);
        try expectRoundTrips(.voltage, .giga, .nano, raw);
        try expectRoundTrips(.voltage, .pico, .mega, raw);
    }
}

test "the value in base units does not depend on the prefix" {
    // Oracle: closed form, then law. `3 aF` is `3e-18 F`, and the value in base
    // units is what a quantity is, so restating its prefix cannot change it. A
    // `to` that scaled the wrong way passes the round-trip law, and fails here.
    try testing.expectApproxEqRel(3e-18, (Qty(.capacitance, .atto){ .raw = 3.0 }).base(), 1e-15);
    try testing.expectApproxEqRel(12.5e-15, (Qty(.capacitance, .femto){ .raw = 12.5 }).base(), 1e-15);
    try testing.expectApproxEqRel(12.5e-12, (Qty(.capacitance, .pico){ .raw = 12.5 }).base(), 1e-15);
    try testing.expectApproxEqRel(1.8, (Qty(.voltage, .base){ .raw = 1.8 }).base(), 1e-15);
    try testing.expectApproxEqRel(0.2, (Qty(.voltage, .milli){ .raw = 200.0 }).base(), 1e-15);

    const farads: Qty(.capacitance, .femto) = .{ .raw = 12.5 };
    for ([_]f64{ farads.to(.atto).base(), farads.to(.pico).base(), farads.to(.base).base(), farads.to(.mega).base() }) |restated| {
        try testing.expectApproxEqRel(farads.base(), restated, 1e-12);
    }
}

test "celsius puts absolute zero at zero kelvin" {
    // Oracle: closed form. The offset is 273.15: absolute zero at 0 K, the
    // freezing point at 273.15 K, and a negative reading that comes back positive.
    const readings = [_]struct { f64, f64 }{
        .{ -273.15, 0.0 },  .{ 0.0, 273.15 },  .{ 25.0, 298.15 },  .{ 100.0, 373.15 },
        .{ -40.0, 233.15 }, .{ -273.0, 0.15 }, .{ 125.0, 398.15 },
    };
    for (readings) |r| try testing.expectApproxEqAbs(r[1], geom.celsius(r[0]).raw, 1e-9);
}

test "a negative celsius reading is a positive kelvin with a finite reciprocal" {
    // Oracle: law. Every reading at or above absolute zero is a positive kelvin
    // with a finite, positive reciprocal — what an Arrhenius factor computes.
    for ([_]f64{ -273.0, -272.0, -40.0, -10.0, -0.001, 0.0, 25.0, 125.0 }) |degrees| {
        const kelvin = geom.celsius(degrees).raw;
        try testing.expect(kelvin > 0.0);
        try testing.expect(std.math.isFinite(1.0 / kelvin) and 1.0 / kelvin > 0.0);
    }
}

test "celsius preserves differences" {
    // Oracle: law. An offset conversion has unit slope, so a difference of two
    // readings survives it unchanged, for every pair. This separates `T + 273.15`
    // from a scaling mistake such as `T * 273.15`.
    var p = prng(53);
    const r = p.random();
    for (0..512) |_| {
        const a = r.float(f64) * 400.0 - 273.15;
        const b = r.float(f64) * 400.0 - 273.15;
        try testing.expectApproxEqAbs(b - a, geom.celsius(b).raw - geom.celsius(a).raw, 1e-9);
    }
}

test "adding a quantity and subtracting it restores the original" {
    // Oracle: law. Quantities of one dimension and prefix form a group under
    // addition. The tolerance is absolute because the values straddle zero, and
    // the draws are bounded by ten so `1e-12` is far above `f64` rounding.
    const MilliVolt = Qty(.voltage, .milli);
    const zero: MilliVolt = .{ .raw = 0.0 };
    var p = prng(67);
    const r = p.random();
    for (0..512) |_| {
        const a: MilliVolt = .{ .raw = r.float(f64) * 20.0 - 10.0 };
        const b: MilliVolt = .{ .raw = r.float(f64) * 20.0 - 10.0 };
        try testing.expectApproxEqAbs(a.raw, a.add(b).sub(b).raw, 1e-12);
        try testing.expectApproxEqAbs(a.raw, a.sub(b).add(b).raw, 1e-12);
        try testing.expectApproxEqAbs(a.sub(b).raw, a.add(b.neg()).raw, 1e-12);
        try testing.expectApproxEqAbs(0.0, a.add(a.neg()).raw, 1e-12);
        try testing.expectApproxEqAbs(a.raw, a.neg().neg().raw, 1e-12);
        try testing.expectApproxEqAbs(a.raw, a.add(zero).raw, 1e-12);
    }
}

test "scaling by a factor and dividing it out restores the original" {
    // Oracle: law. Scaling by a dimensionless factor and dividing the same factor
    // out is the identity, and scaling by one is exact.
    const Volt = Qty(.voltage, .base);
    const one: Volt = .{ .raw = 1.8 };
    try testing.expectEqual(one.raw, one.scale(1.0).raw);
    var p = prng(89);
    const r = p.random();
    for (0..512) |_| {
        const value: Volt = .{ .raw = r.float(f64) * 20.0 - 10.0 };
        const factor = r.float(f64) * 8.0 + 0.5;
        try testing.expectApproxEqAbs(value.raw, value.scale(factor).scale(1.0 / factor).raw, 1e-12);
        try testing.expectApproxEqAbs(value.raw, value.scale(2.0).sub(value).raw, 1e-12);
    }
}

test "the ratio of two quantities of one dimension is their bare ratio" {
    // Oracle: closed form, then law. Dividing two quantities of one dimension is
    // dimensionless — an antenna ratio — so `3 aF / 1.5 aF` is 2, exactly. The
    // ratio is prefix-free: restating both operands cannot move it.
    const numerator: Qty(.capacitance, .atto) = .{ .raw = 3.0 };
    const denominator: Qty(.capacitance, .atto) = .{ .raw = 1.5 };
    const ratio: f64 = geom.div(numerator, denominator);
    try testing.expectApproxEqAbs(2.0, ratio, 1e-15);
    for ([_]f64{
        geom.div(numerator.to(.femto), denominator.to(.femto)),
        geom.div(numerator.to(.base), denominator.to(.base)),
        geom.div(numerator.to(.mega), denominator.to(.mega)),
    }) |restated| try testing.expectApproxEqRel(ratio, restated, 1e-12);

    var p = prng(101);
    const r = p.random();
    for (0..512) |_| {
        const a: Qty(.capacitance, .femto) = .{ .raw = r.float(f64) * 9.0 + 1.0 };
        const b: Qty(.capacitance, .femto) = .{ .raw = r.float(f64) * 9.0 + 1.0 };
        try testing.expectApproxEqRel(a.raw / b.raw, geom.div(a, b), 1e-12);
        try testing.expectApproxEqRel(1.0, geom.div(a, b) * geom.div(b, a), 1e-12);
    }
}

test "only finite values are finite" {
    // Oracle: law. `is_finite` separates the values a report may carry from the
    // three that must never reach one. NaN compares false against every limit.
    for ([_]f64{ 0.0, -0.0, 1.8, -1e30, std.math.floatMin(f64), std.math.floatMax(f64), -std.math.floatMax(f64) }) |raw| {
        try testing.expect((Qty(.voltage, .base){ .raw = raw }).isFinite());
    }
    for ([_]f64{ std.math.nan(f64), std.math.inf(f64), -std.math.inf(f64) }) |raw| {
        try testing.expect(!(Qty(.capacitance, .atto){ .raw = raw }).isFinite());
    }
}

// ---- arith.rs ----

test "the three ohms law operators agree on one triple" {
    // Oracle: closed form. 1.8 V, 0.6 A and 3 ohms are one triple, and each
    // operator recovers the member it is missing. The type annotations assert at
    // compile time that results come back canonical, at `10^0`.
    const volts: Qty(.voltage, .base) = .{ .raw = 1.8 };
    const amps: Qty(.current, .base) = .{ .raw = 0.6 };
    const ohms: Qty(.resistance, .base) = .{ .raw = 3.0 };
    const resistance: Qty(.resistance, .base) = geom.div(volts, amps);
    const voltage: Qty(.voltage, .base) = geom.mul(amps, ohms);
    const current: Qty(.current, .base) = geom.div(volts, ohms);
    try testing.expectApproxEqRel(3.0, resistance.raw, 1e-12);
    try testing.expectApproxEqRel(1.8, voltage.raw, 1e-12);
    try testing.expectApproxEqRel(0.6, current.raw, 1e-12);
}

test "cross prefix operands give the same canonical answer as base prefix ones" {
    // Oracle: closed form. The same triple written with mixed prefixes: 1.8 V is
    // 1800 mV, 0.6 A is 600000 uA, 3 ohms is 0.003 kohm. Every operator must land
    // on the same canonical answer as the base-prefix form.
    const millivolts: Qty(.voltage, .milli) = .{ .raw = 1_800.0 };
    const microamps: Qty(.current, .micro) = .{ .raw = 600_000.0 };
    const kilohms: Qty(.resistance, .kilo) = .{ .raw = 0.003 };
    const milliamps: Qty(.current, .milli) = .{ .raw = 600.0 };
    const milliohms: Qty(.resistance, .milli) = .{ .raw = 3_000.0 };
    try testing.expectApproxEqRel(3.0, geom.div(millivolts, microamps).raw, 1e-12);
    try testing.expectApproxEqRel(0.6, geom.div(millivolts, milliohms).raw, 1e-12);
    try testing.expectApproxEqRel(1.8, geom.mul(milliamps, kilohms).raw, 1e-12);
    // The direction of the scale factor, stated where it is largest. A
    // conversion applied the wrong way round is out by 10^18 here.
    const gigavolts: Qty(.voltage, .giga) = .{ .raw = 1.8e-9 };
    const nanoamps: Qty(.current, .nano) = .{ .raw = 6e8 };
    try testing.expectApproxEqRel(3.0, geom.div(gigavolts, nanoamps).raw, 1e-12);
}

test "ohms law closes over arbitrary triples" {
    // Oracle: law. For any current and any resistance, the voltage they produce
    // divides back to both of them.
    var p = prng(37);
    const r = p.random();
    for (0..512) |_| {
        const amps: Qty(.current, .base) = .{ .raw = r.float(f64) * 2.0 + 0.01 };
        const ohms: Qty(.resistance, .base) = .{ .raw = r.float(f64) * 1_000.0 + 0.1 };
        const volts = geom.mul(amps, ohms);
        try testing.expectApproxEqRel(amps.raw, geom.div(volts, ohms).raw, 1e-12);
        try testing.expectApproxEqRel(ohms.raw, geom.div(volts, amps).raw, 1e-12);
        // Either operand order: a product commutes.
        try testing.expectApproxEqRel(volts.raw, geom.mul(ohms, amps).raw, 1e-12);
    }
}

test "ohms law is indifferent to the prefix its operands carry" {
    // Oracle: law. Ohm's law is prefix-blind: restating both operands and
    // comparing the canonical results, over arbitrary values.
    var p = prng(43);
    const r = p.random();
    for (0..512) |_| {
        const volts: Qty(.voltage, .base) = .{ .raw = r.float(f64) * 3.0 + 0.1 };
        const amps: Qty(.current, .base) = .{ .raw = r.float(f64) * 2.0 + 0.01 };
        const expected = geom.div(volts, amps).raw;
        try testing.expectApproxEqRel(expected, geom.div(volts.to(.milli), amps.to(.micro)).raw, 1e-12);
        try testing.expectApproxEqRel(expected, geom.div(volts.to(.kilo), amps.to(.milli)).raw, 1e-12);
    }
}

test "a length times a length is an area in base units" {
    // Oracle: closed form. Two metres by three metres is six square metres, and
    // 2000 mm by 3000000 um is the same six; 500 nm by 200 nm is 1e-13 m^2.
    const area: Qty(.area, .base) = geom.mul(Qty(.length, .base){ .raw = 2.0 }, Qty(.length, .base){ .raw = 3.0 });
    try testing.expectApproxEqRel(6.0, area.raw, 1e-12);
    try testing.expectApproxEqRel(6.0, geom.mul(Qty(.length, .milli){ .raw = 2_000.0 }, Qty(.length, .micro){ .raw = 3_000_000.0 }).raw, 1e-12);
    try testing.expectApproxEqRel(1e-13, geom.mul(nm(500.0), nm(200.0)).raw, 1e-12);
}

test "area is symmetric in its factors and linear in each" {
    // Oracle: law. Area is symmetric in its factors and linear in each, which is
    // what "this is a product" means.
    var p = prng(61);
    const r = p.random();
    for (0..512) |_| {
        const a = um(r.float(f64) * 100.0 + 1.0);
        const b = nm(r.float(f64) * 1_000.0 + 1.0);
        try testing.expectApproxEqRel(geom.mul(b, a).raw, geom.mul(a, b).raw, 1e-12);
        try testing.expectApproxEqRel(geom.mul(a, b).raw * 2.0, geom.mul(a.scale(2.0), b).raw, 1e-12);
    }
}

test "a current over a length is a current density" {
    // Oracle: closed form. 1.2 A through a 0.4 m conductor is 3 A/m; 1.2 mA
    // through a 400 nm wire is 3000 A/m.
    const density: Qty(.current_density, .base) = geom.div(Qty(.current, .base){ .raw = 1.2 }, Qty(.length, .base){ .raw = 0.4 });
    try testing.expectApproxEqRel(3.0, density.raw, 1e-12);
    try testing.expectApproxEqRel(3_000.0, geom.div(Qty(.current, .milli){ .raw = 1.2 }, nm(400.0)).raw, 1e-12);
}

test "current density scales with current and inversely with width" {
    // Oracle: law. Current density is linear in the current and inverse in the
    // width, for every pair.
    var p = prng(79);
    const r = p.random();
    for (0..512) |_| {
        const amps: Qty(.current, .milli) = .{ .raw = r.float(f64) * 10.0 + 0.1 };
        const width = nm(r.float(f64) * 900.0 + 100.0);
        const reference = geom.div(amps, width).raw;
        try testing.expectApproxEqRel(reference * 2.0, geom.div(amps.scale(2.0), width).raw, 1e-12);
        try testing.expectApproxEqRel(reference / 2.0, geom.div(amps, width.scale(2.0)).raw, 1e-12);
    }
}
