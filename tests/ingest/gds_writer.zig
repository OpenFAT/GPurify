//! The test GDS writer, read back by the reader: structures, placements,
//! arrays and texts. Ported from crates/testgen/src/gds.rs (its round trips
//! live in the readers' suites there).

const std = @import("std");
const testing = std.testing;
const ingest = @import("ingest");
const geom = @import("geom");
const testgen = @import("testgen");
const gpa = testing.allocator;

test "a written library reads back structure for structure" {
    // Oracle: round trip through the reader. A rectangle, a mirrored and
    // magnified `SREF`, a 2 × 3 `AREF` and a `TEXT` read back as written,
    // the array's pitch the stated steps; a zero-count array and a non-ASCII
    // name are refused.
    var out: std.ArrayList(u8) = .empty;
    defer out.deinit(gpa);
    try testgen.gds.writeLibrary(gpa, &.{
        .{ .name = "LEAF", .rects = &.{.{ 68, 20, .{ 0, 0, 100, 50 } }} },
        .{ .name = "TOP", .refs = &.{
            .{ .cell = "LEAF", .reflect = true, .quarter_turns = 1, .mag = 2, .at = .{ 10, 20 } },
            .{ .cell = "LEAF", .at = .{ 0, 1000 }, .array = .{ .cols = 2, .rows = 3, .col_step = .{ 200, 0 }, .row_step = .{ 0, 300 } } },
        }, .texts = &.{.{ 68, 5, 7, 8, "VDD" }} },
    }, &out);
    var strings: geom.StrTable = .empty;
    defer strings.deinit(gpa);
    var diag: ingest.gds.Diagnostic = .{};
    var lib = try ingest.gds.Library.parse(gpa, out.items, &strings, &diag);
    defer lib.deinit(gpa);
    try testing.expectEqual(1000, (try lib.grid(&diag)).dbu_per_um);
    try testing.expectEqualSlices(i64, &.{ 0, 100, 100, 0 }, lib.xs.items);
    try testing.expectEqualSlices(i64, &.{ 0, 0, 50, 50 }, lib.ys.items);
    const r0 = lib.refs.get(0);
    try testing.expectEqual(ingest.gds.Xform{ .mag = 2, .flip = true, .quadrant = 1, .dx = 10, .dy = 20 }, r0.place);
    const r1 = lib.refs.get(1);
    try testing.expectEqual([4]i64{ 200, 0, 0, 300 }, [4]i64{ r1.col_step[0], r1.col_step[1], r1.row_step[0], r1.row_step[1] });
    try testing.expectEqual([2]u32{ 2, 3 }, [2]u32{ r1.cols, r1.rows });
    try testing.expectEqualStrings("VDD", strings.resolve(lib.texts.get(0).string));
    out.clearRetainingCapacity();
    try testing.expectError(error.ZeroCount, testgen.gds.writeLibrary(gpa, &.{.{ .name = "T", .refs = &.{.{ .cell = "T", .array = .{ .cols = 0, .rows = 1, .col_step = .{ 1, 0 }, .row_step = .{ 0, 1 } } }} }}, &out));
    try testing.expectError(error.NotAscii, testgen.gds.writeLibrary(gpa, &.{.{ .name = "\xc3\xa9" }}, &out));
}
