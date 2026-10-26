//! The mesh the field solve is built from, and the asymmetry measure of its
//! matrix. Ported from crates/extract/tests/field/quasistatic.rs and the
//! in-file tests of crates/extract/src/field/mesh.rs.
//!
//! A mesh's panels tile the conductor, so their areas sum to a surface area
//! no refinement changes. The Rust suite drew its conductors from testgen's
//! scale corpus (not yet ported); here each case is a few combs drawn by
//! hand, one net each, which the laws below hold for as they do for any
//! geometry.
//!
//! Contents: helpers `combs`, `buildMesh`, `conductorArea`, `serialise`,
//! `matrixOf`; then the tests.

const std = @import("std");
const testing = std.testing;
const extract = @import("extract");
const testgen = @import("testgen");
const Rng = testgen.Rng;
const fixture = @import("fixture.zig");
const Box = fixture.Box;
const Case = fixture.Case;
const Rows = fixture.Rows;
const mesh = extract.mesh;
const capacitance = extract.capacitance;
const gpa = testing.allocator;

// ---- private ----

/// `nets` combs, net `k` on layer `k % 3`: a 6 x 0.4 um rail and three
/// 0.4 x 2 um fingers abutting it from above, 4 um apart from the next.
fn combs(comptime nets: u32) [4 * nets]Box {
    var out: [4 * nets]Box = undefined;
    for (0..nets) |k| {
        const y: i64 = @intCast(k * 4_000);
        const layer: u16 = @intCast(k % 3);
        out[4 * k] = .{ .layer = layer, .net = @intCast(k), .r = .{ 0, y, 6_000, y + 400 } };
        for (0..3) |f| {
            const x: i64 = @intCast(f * 2_000);
            out[4 * k + 1 + f] = .{ .layer = layer, .net = @intCast(k), .r = .{ x, y + 400, x + 400, y + 2_400 } };
        }
    }
    return out;
}

fn buildMesh(c: *const Case, rows: *const Rows, selected: []const u32, max_edge: i64, max_panels: u32, out: *mesh.Mesh) mesh.Error!void {
    var refused: @import("geom").LayerId = undefined;
    // Proximity refinement off: it refines against a distance these laws do
    // not control; every law here is about what `max_edge` alone does.
    try mesh.buildInto(gpa, &c.store, &c.nets, &.{}, selected, rows.stack(), .{ .max_edge = max_edge, .proximity_refine = 0, .max_panels = max_panels }, fixture.grid, out, &refused);
}

/// Surface area of one conductor, summed from its band of panels.
fn conductorArea(m: *const mesh.Mesh, conductor: usize) f64 {
    var sum: f64 = 0.0;
    for (m.panel.items(.area)[m.conductor_start.items[conductor]..m.conductor_start.items[conductor + 1]]) |a| sum += a;
    return sum;
}

/// A mesh's panels as bytes, floats by their bit pattern: the determinism
/// gate for meshing.
fn serialise(m: *const mesh.Mesh, out: *std.ArrayList(u8)) !void {
    out.clearRetainingCapacity();
    const s = m.panel.slice();
    for (0..s.len) |i| {
        const p = s.get(i);
        for ([_]f64{ p.cx, p.cy, p.cz, p.area }) |v| try out.appendSlice(gpa, std.mem.asBytes(&v));
        try out.appendSlice(gpa, std.mem.asBytes(&p.conductor));
    }
    try out.appendSlice(gpa, std.mem.sliceAsBytes(m.conductor_start.items));
    try out.appendSlice(gpa, std.mem.sliceAsBytes(m.conductor_net.items));
    try out.appendSlice(gpa, std.mem.sliceAsBytes(m.epsilon.items));
}

fn matrixOf(n: usize, values: []const f64) !capacitance.CapMatrix {
    var m: capacitance.CapMatrix = .empty;
    for (0..n) |i| try m.net.append(gpa, @intCast(i));
    try m.value.appendSlice(gpa, values);
    return m;
}

test "refining a mesh subdivides it without changing any conductor's area" {
    // Oracle: law. A conductor's surface area is a property of the
    // conductor, not of how finely it was cut, so halving `max_edge` leaves
    // every conductor's area where it was (to 1e-9) while producing at least
    // as many panels. A mesh that loses area loses charge, wrong in a way no
    // residual reveals.
    var c = try Case.init(&combs(2), &.{}, 3);
    defer c.deinit();
    const rows = fixture.uniformRows(1.0, 0.25);
    var coarse: mesh.Mesh = .empty;
    defer coarse.deinit(gpa);
    var fine: mesh.Mesh = .empty;
    defer fine.deinit(gpa);
    try buildMesh(&c, &rows, &.{ 0, 1 }, 500, 1 << 20, &coarse);
    try buildMesh(&c, &rows, &.{ 0, 1 }, 250, 1 << 20, &fine);
    try testing.expect(coarse.panel.len > 0 and fine.panel.len >= coarse.panel.len);
    for (0..2) |k| {
        const area = conductorArea(&coarse, k);
        try testing.expect(area > 0.0 and std.math.isFinite(area));
        try testing.expectApproxEqRel(area, conductorArea(&fine, k), 1e-9);
    }
}

test "a built mesh partitions its panels across the nets it was given" {
    // Oracle: construct-from-answer. `panel[conductor_start[c]..
    // conductor_start[c + 1]]` is conductor `c`, one per selected net in
    // selection order: the bands partition the panel column, every panel
    // names its band, `epsilon` runs beside the panels, and every band has
    // positive area.
    var c = try Case.init(&combs(3), &.{}, 3);
    defer c.deinit();
    const rows = fixture.uniformRows(1.0, 0.25);
    var m: mesh.Mesh = .empty;
    defer m.deinit(gpa);
    const selected = [_]u32{ 2, 0, 1 };
    try buildMesh(&c, &rows, &selected, 400, 1 << 20, &m);
    try testing.expectEqualSlices(u32, &selected, m.conductor_net.items);
    try testing.expectEqual(selected.len + 1, m.conductor_start.items.len);
    try testing.expectEqual(0, m.conductor_start.items[0]);
    try testing.expectEqual(m.panel.len, m.conductor_start.items[selected.len]);
    try testing.expectEqual(m.panel.len, m.epsilon.items.len);
    for (0..selected.len) |k| {
        const from = m.conductor_start.items[k];
        const to = m.conductor_start.items[k + 1];
        try testing.expect(from < to);
        for (m.panel.items(.conductor)[from..to], m.panel.items(.area)[from..to]) |owner, area| {
            try testing.expectEqual(k, owner);
            try testing.expect(area > 0.0 and std.math.isFinite(area));
        }
    }
}

test "a mesh that would exceed the panel limit is refused rather than truncated" {
    // Oracle: law, and the fail-closed rule. A conductor is a closed surface
    // of at least six faces, so one panel meshes nothing: refused by name,
    // never an empty clean mesh; the same geometry with room meshes into
    // more than one.
    var c = try Case.init(&combs(2), &.{}, 3);
    defer c.deinit();
    const rows = fixture.uniformRows(1.0, 0.25);
    var m: mesh.Mesh = .empty;
    defer m.deinit(gpa);
    try testing.expectError(error.TooManyPanels, buildMesh(&c, &rows, &.{ 0, 1 }, 400, 1, &m));
    try buildMesh(&c, &rows, &.{ 0, 1 }, 400, 1 << 20, &m);
    try testing.expect(m.panel.len > 1);
}

test "a conductor on the substrate gets no panels" {
    // Oracle: definition (F73). The substrate is ground as a plane at height
    // 0, so a shape on a layer at height 0 is a junction in that plane: no
    // panels, no refusal, and with every layer at height 0 every band empty.
    var c = try Case.init(&combs(2), &.{}, 3);
    defer c.deinit();
    var rows = fixture.uniformRows(1.0, 0.25);
    rows.height = @splat(0.0);
    var m: mesh.Mesh = .empty;
    defer m.deinit(gpa);
    try buildMesh(&c, &rows, &.{ 0, 1 }, 400, 1 << 20, &m);
    try testing.expectEqual(0, m.panel.len);
    try testing.expectEqualSlices(u32, &.{ 0, 0, 0 }, m.conductor_start.items);
    try testing.expectEqualSlices(u32, &.{ 0, 1 }, m.conductor_net.items);
}

test "meshing is byte identical across runs and across a reused buffer" {
    // Oracle: determinism. Panels are sorted by a key derived only from
    // position, so two builds give the same bytes, and a build into a buffer
    // already holding a mesh gives the bytes of one into a fresh buffer.
    var c = try Case.init(&combs(2), &.{}, 3);
    defer c.deinit();
    const rows = fixture.uniformRows(1.0, 0.25);
    var first: std.ArrayList(u8) = .empty;
    defer first.deinit(gpa);
    var again: std.ArrayList(u8) = .empty;
    defer again.deinit(gpa);
    var fresh: mesh.Mesh = .empty;
    defer fresh.deinit(gpa);
    try buildMesh(&c, &rows, &.{ 0, 1 }, 400, 1 << 20, &fresh);
    try serialise(&fresh, &first);
    try testing.expect(first.items.len > 0);
    var reused: mesh.Mesh = .empty;
    defer reused.deinit(gpa);
    try buildMesh(&c, &rows, &.{ 0, 1 }, 400, 1 << 20, &reused);
    try serialise(&reused, &again);
    try testing.expectEqualSlices(u8, first.items, again.items);
    try buildMesh(&c, &rows, &.{ 0, 1 }, 400, 1 << 20, &reused);
    try serialise(&reused, &again);
    try testing.expectEqualSlices(u8, first.items, again.items);
}

test "a concave conductor is meshed as drawn not as its box" {
    // Oracle: hand-derived. An L whose box swallows a square in its notch:
    // the L's top face is 1000 x 400 + 400 x 600 nm², and no panel of it may
    // lie over the square (600..900 on both axes). Meshing boxes put the L's
    // top face over the square.
    const l = fixture.Shape{ .layer = 0, .net = 0, .xs = &.{ 0, 1000, 1000, 400, 400, 0 }, .ys = &.{ 0, 0, 400, 400, 1000, 1000 } };
    var c = try Case.init(&.{.{ .layer = 0, .net = 1, .r = .{ 600, 600, 900, 900 } }}, &.{l}, 1);
    defer c.deinit();
    var rows = fixture.uniformRows(1.0, 1.0);
    rows.thickness[0] = 100;
    rows.height[0] = 1000;
    rows.k[0] = 4.0;
    var m: mesh.Mesh = .empty;
    defer m.deinit(gpa);
    try buildMesh(&c, &rows, &.{ 0, 1 }, 50, 1_000_000, &m);
    var top: f64 = 0.0;
    var inside: u32 = 0;
    const s = m.panel.slice();
    for (0..s.len) |i| {
        const p = s.get(i);
        if (p.conductor != 0) continue;
        const x = p.cx * 1e9;
        const y = p.cy * 1e9;
        if (x > 600 and x < 900 and y > 600 and y < 900) inside += 1;
        if (@abs(p.cz - 1.1e-6) < 1e-12) top += p.area;
    }
    try testing.expectEqual(0, inside);
    try testing.expect(@abs(top * 1e18 - (1000.0 * 400.0 + 400.0 * 600.0)) < 1e-3);
}

test "asymmetry is zero on a symmetric matrix and the relative gap otherwise" {
    // Oracle: closed form. Asymmetry is the largest gap between an entry and
    // its transpose over the geometric mean of the two diagonals: a symmetric
    // matrix has none; `(0,1) = 1`, `(1,0) = 1.1` on a diagonal of 4 and 3 is
    // off by `0.1 / √12`.
    var symmetric = try matrixOf(3, &.{ 4, -1, -0.5, -1, 3, -2, -0.5, -2, 5 });
    defer symmetric.deinit(gpa);
    try testing.expectApproxEqAbs(@as(f64, 0), symmetric.asymmetry(), 1e-15);
    var skewed = try matrixOf(2, &.{ 4, 1, 1.1, 3 });
    defer skewed.deinit(gpa);
    try testing.expectApproxEqRel(0.1 / @sqrt(12.0), skewed.asymmetry(), 1e-9);
}

test "any symmetric matrix reports no asymmetry" {
    // Oracle: law. Reciprocity makes the Maxwell matrix symmetric for any
    // geometry, so a symmetric matrix reports no asymmetry however it was
    // built: over generated diagonally dominant matrices with non-positive
    // off-diagonals, 1 to 8 rows.
    var rng: Rng = .init(61);
    for (1..9) |n| {
        const v = try gpa.alloc(f64, n * n);
        defer gpa.free(v);
        @memset(v, 0.0);
        for (0..n) |i| {
            for (i + 1..n) |j| {
                const coupling = -(0.05 + rng.unit());
                v[i * n + j] = coupling;
                v[j * n + i] = coupling;
            }
        }
        for (0..n) |i| {
            var off: f64 = 0.0;
            for (0..n) |j| off += if (j == i) 0.0 else @abs(v[i * n + j]);
            v[i * n + i] = off + 0.25 + rng.unit();
        }
        var m = try matrixOf(n, v);
        defer m.deinit(gpa);
        try testing.expectApproxEqAbs(@as(f64, 0), m.asymmetry(), 1e-15);
    }
}
