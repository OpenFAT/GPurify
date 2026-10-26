//! Keyholes: one raw GDSII ring that revisits a vertex or folds back along
//! one line (how GDSII writes a hole) → its outer and its clockwise holes,
//! each appended to the `Library` as its own element. Any other ring is left
//! for the caller. The decomposition is geom's
//! `boolean.canonicalRingsInto`. Ported from crates/ingest/src/layout.rs
//! (`push_keyhole`, `ring_revisits_a_vertex`, `ring_overlaps_itself`,
//! `ring_is_in_domain`).
//!
//! Contents:
//! - `pub const Scratch`, `Scratch.deinit(s: *Scratch, gpa: Allocator) void`
//! - `pub fn pushKeyhole(gpa: Allocator, lib: *Library, s: *Scratch, first: usize, layer: u16, datatype: u16) Allocator.Error!bool`

const std = @import("std");
const Allocator = std.mem.Allocator;
const geom = @import("geom");
const Library = @import("gds.zig").Library;

/// The keyhole tests' reused buffers.
pub const Scratch = struct {
    /// A ring's vertices, for `revisitsVertex`.
    seen: std.ArrayList([2]i64) = .empty,
    /// A ring's vertical and horizontal edges as `(line, lo, hi)`, for `overlapsItself`.
    lines: [2]std.ArrayList([3]i64) = .{ .empty, .empty },
    rings: geom.boolean.Rings = .{},

    pub fn deinit(s: *Scratch, gpa: Allocator) void {
        s.seen.deinit(gpa);
        s.lines[0].deinit(gpa);
        s.lines[1].deinit(gpa);
        s.rings.deinit(gpa);
    }
};

/// The fewest vertices a keyhole ring can have: outer 4, hole 4, slit ends revisited.
const keyhole_min_verts = 10;

/// Decomposes the ring `lib.xs/ys[first..]`, when it revisits a vertex or
/// folds back along one line, into its outer ring and holes, each pushed as
/// an element; returns whether it did. Only then: the sweep reorders
/// vertices, and vertex 0 is a shape's report point. A ring outside the
/// domain, or one that traces no ring, is left untouched for the plain path,
/// where `geom.view` names what is wrong.
pub fn pushKeyhole(gpa: Allocator, lib: *Library, s: *Scratch, first: usize, layer: u16, datatype: u16) Allocator.Error!bool {
    const xs = lib.xs.items[first..];
    const ys = lib.ys.items[first..];
    const folds = try revisitsVertex(gpa, xs, ys, &s.seen) or try overlapsItself(gpa, xs, ys, &s.lines);
    if (!folds or !inDomain(xs, ys)) return false;
    try geom.boolean.canonicalRingsInto(gpa, xs, ys, &s.rings);
    const rings = &s.rings;
    if (rings.count() == 0) return false;
    lib.xs.shrinkRetainingCapacity(first);
    lib.ys.shrinkRetainingCapacity(first);
    for (0..rings.count()) |k| {
        const span = rings.range(k);
        const ring_start: u32 = @intCast(lib.xs.items.len);
        try lib.xs.appendSlice(gpa, rings.xs.items[span[0]..span[1]]);
        try lib.ys.appendSlice(gpa, rings.ys.items[span[0]..span[1]]);
        try lib.elems.append(gpa, .{
            .layer = layer,
            .datatype = datatype,
            .vert_start = ring_start,
            .vert_len = @as(u32, @intCast(lib.xs.items.len)) - ring_start,
        });
    }
    return true;
}

// ---- private ----

/// Whether a ring revisits a vertex. Sorts, so O(n log n).
fn revisitsVertex(gpa: Allocator, xs: []const i64, ys: []const i64, seen: *std.ArrayList([2]i64)) Allocator.Error!bool {
    if (xs.len < keyhole_min_verts) return false;
    seen.clearRetainingCapacity();
    for (xs, ys) |x, y| try seen.append(gpa, .{ x, y });
    std.mem.sortUnstable([2]i64, seen.items, {}, lessLex(2));
    const v = seen.items;
    for (v[0 .. v.len - 1], v[1..]) |a, b| if (a[0] == b[0] and a[1] == b[1]) return true;
    return false;
}

/// Whether two axis-parallel edges share a stretch of one line: the ring
/// folds back over itself. A keyhole whose way out runs on along the hole's
/// side, past where the way in started, does so without revisiting a vertex
/// (`sky130_fd_sc_hd`'s level shifters draw poly this way). O(n log n).
fn overlapsItself(gpa: Allocator, xs: []const i64, ys: []const i64, lines: *[2]std.ArrayList([3]i64)) Allocator.Error!bool {
    const vertical = &lines[0];
    const horizontal = &lines[1];
    vertical.clearRetainingCapacity();
    horizontal.clearRetainingCapacity();
    for (0..xs.len) |i| {
        const j = if (i + 1 == xs.len) 0 else i + 1;
        if (xs[i] == xs[j] and ys[i] != ys[j]) try vertical.append(gpa, .{ xs[i], @min(ys[i], ys[j]), @max(ys[i], ys[j]) });
        if (ys[i] == ys[j] and xs[i] != xs[j]) try horizontal.append(gpa, .{ ys[i], @min(xs[i], xs[j]), @max(xs[i], xs[j]) });
    }
    // Sorted by line, then start: an overlap shows between neighbours.
    for (lines) |*edges| {
        std.mem.sortUnstable([3]i64, edges.items, {}, lessLex(3));
        const e = edges.items;
        if (e.len < 2) continue;
        for (e[0 .. e.len - 1], e[1..]) |a, b| if (a[0] == b[0] and b[1] < a[2]) return true;
    }
    return false;
}

/// Whether every vertex is inside the domain `canonicalRingsInto` asserts.
fn inDomain(xs: []const i64, ys: []const i64) bool {
    for (xs, ys) |x, y| if (!geom.inDomain(x) or !geom.inDomain(y)) return false;
    return true;
}

fn lessLex(comptime n: usize) fn (void, [n]i64, [n]i64) bool {
    return struct {
        fn less(_: void, a: [n]i64, b: [n]i64) bool {
            return std.mem.lessThan(i64, &a, &b);
        }
    }.less;
}
