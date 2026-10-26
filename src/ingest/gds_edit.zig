//! GDS edit: a GDSII stream and boxes on stream pairs → the same stream with
//! one `BOUNDARY` per box added to its first root structure, every other
//! record left byte for byte: a layout edit (density fill, a redundant cut)
//! in the coordinates `flatten` reads. Flattening places every root at the
//! origin, so any root would do. Ported from crates/ingest/src/layout.rs
//! (`gds::with_boxes`).
//!
//! Contents:
//! - `pub const StreamBox = struct { stream: [2]u16, box: Bbox }`
//! - `pub fn withBoxes(gpa: Allocator, bytes: []const u8, boxes: []const StreamBox, diag: *Diagnostic) Error![]u8`

const std = @import("std");
const Allocator = std.mem.Allocator;
const geom = @import("geom");
const Bbox = geom.Bbox;
const gds = @import("gds.zig");
const Error = gds.Error;
const Diagnostic = gds.Diagnostic;
const rec = @import("gds_records.zig");

/// One box to add, on its GDS layer/datatype pair.
pub const StreamBox = struct { stream: [2]u16, box: Bbox };

/// `bytes` with `boxes` added to the first structure (in file order) that no
/// reference places; the caller owns the result. `Truncated` for a stream
/// that does not read to `ENDLIB` or has no root structure;
/// `CoordinateOutOfRange` for a box past GDSII's 32-bit coordinates.
pub fn withBoxes(gpa: Allocator, bytes: []const u8, boxes: []const StreamBox, diag: *Diagnostic) Error![]u8 {
    var ends: std.ArrayList(struct { name: []const u8, at: usize }) = .empty;
    defer ends.deinit(gpa);
    var placed: std.ArrayList([]const u8) = .empty;
    defer placed.deinit(gpa);
    var name: []const u8 = "";
    var at: usize = 0;
    while (true) {
        const r = try rec.record(bytes, at, diag);
        switch (r.tag) {
            .strname => name = rec.ascii(r.payload),
            .sname => try placed.append(gpa, rec.ascii(r.payload)),
            .endstr => {
                try ends.append(gpa, .{ .name = name, .at = at });
                name = "";
            },
            .endlib => break,
            // else: the tag set is open; only the names and ends matter here
            else => {},
        }
        at = r.next;
    }
    const root = for (ends.items) |e| {
        const is_placed = for (placed.items) |p| {
            if (std.mem.eql(u8, p, e.name)) break true;
        } else false;
        if (!is_placed) break e.at;
    } else return rec.truncated(diag, at);

    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(gpa);
    try out.ensureTotalCapacity(gpa, bytes.len + boxes.len * 64);
    out.appendSliceAssumeCapacity(bytes[0..root]);
    for (boxes) |sb| {
        const b = sb.box;
        var xy: [40]u8 = undefined;
        const ring = [5][2]i64{ .{ b.xlo, b.ylo }, .{ b.xhi, b.ylo }, .{ b.xhi, b.yhi }, .{ b.xlo, b.yhi }, .{ b.xlo, b.ylo } };
        for (ring, 0..) |p, k| for (p, 0..) |v, axis| {
            const word = std.math.cast(i32, v) orelse {
                diag.coordinate = v;
                return error.CoordinateOutOfRange;
            };
            std.mem.writeInt(i32, xy[k * 8 + axis * 4 ..][0..4], word, .big);
        };
        try put(gpa, &out, .boundary, &.{});
        try put(gpa, &out, .layer, &std.mem.toBytes(std.mem.nativeToBig(u16, sb.stream[0])));
        try put(gpa, &out, .datatype, &std.mem.toBytes(std.mem.nativeToBig(u16, sb.stream[1])));
        try put(gpa, &out, .xy, &xy);
        try put(gpa, &out, .endel, &.{});
    }
    try out.appendSlice(gpa, bytes[root..]);
    return out.toOwnedSlice(gpa);
}

// ---- private ----

fn put(gpa: Allocator, out: *std.ArrayList(u8), tag: rec.Tag, payload: []const u8) Allocator.Error!void {
    const head = [2]u16{ @intCast(payload.len + 4), @backingInt(tag) };
    for (head) |h| try out.appendSlice(gpa, &std.mem.toBytes(std.mem.nativeToBig(u16, h)));
    try out.appendSlice(gpa, payload);
}

test "boxes land in the first root and read back where they were placed" {
    // Oracle: construct-from-answer. `TOP` places `LEAF`, so `TOP` is the
    // first root; the edited stream parses with one more element there, a
    // box at the coordinates given, and `LEAF` untouched. A box past i32 is
    // refused by value.
    const fixture = @import("gds_fixture.zig");
    const testing = std.testing;
    const tgpa = testing.allocator;
    const sq: fixture.Boundary = .{ .layer = 68, .datatype = 20, .xs = &.{ 0, 400, 400, 0 }, .ys = &.{ 0, 0, 400, 400 } };
    const bytes = try fixture.library(tgpa, &.{ .{ .name = "LEAF", .boundaries = &.{sq} }, .{ .name = "TOP", .refs = &.{.{ .cell = "LEAF" }} } }, 1e-9);
    defer tgpa.free(bytes);
    var diag: Diagnostic = .{};
    const edited = try withBoxes(tgpa, bytes, &.{.{ .stream = .{ 1, 2 }, .box = .{ .xlo = -5, .ylo = 10, .xhi = 20, .yhi = 30 } }}, &diag);
    defer tgpa.free(edited);
    var strings: geom.StrTable = .empty;
    defer strings.deinit(tgpa);
    var lib = try gds.Library.parse(tgpa, edited, &strings, &diag);
    defer lib.deinit(tgpa);
    const top = lib.cells.get(1);
    try testing.expectEqual(1, top.elem_end - top.elem_start);
    const e = lib.elems.get(top.elem_start);
    try testing.expectEqual([2]u16{ 1, 2 }, [2]u16{ e.layer, e.datatype });
    try testing.expectEqualSlices(i64, &.{ -5, 20, 20, -5 }, lib.xs.items[e.vert_start..][0..4]);
    try testing.expectEqualSlices(i64, &.{ 10, 10, 30, 30 }, lib.ys.items[e.vert_start..][0..4]);
    const leaf = lib.cells.get(0);
    try testing.expectEqual(1, leaf.elem_end - leaf.elem_start);
    try testing.expectError(error.CoordinateOutOfRange, withBoxes(tgpa, bytes, &.{.{ .stream = .{ 1, 2 }, .box = .{ .xlo = 0, .ylo = 0, .xhi = 1 << 31, .yhi = 1 } }}, &diag));
    try testing.expectEqual(1 << 31, diag.coordinate);
}
