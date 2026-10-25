//! `readGdsBytes` on whole files: refusals, and gzip. Ported from
//! crates/ingest/tests/layout.rs. The gzip is written with
//! `std.compress.flate` (Rust: flate2), the empty library by hand from the
//! Stream Format manual (Rust: `gpurify_testgen::gds::write_library`).

const std = @import("std");
const testing = std.testing;
const ingest = @import("ingest");
const geom = @import("geom");
const gds = ingest.gds;

/// An empty GDSII library: no structure, only the library records.
const empty_library = [_]u8{
    0, 6, 0x00, 0x02, 0x02, 0x58, // HEADER 600
    0, 28, 0x01, 0x02, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, // BGNLIB
    0, 6, 0x02, 0x06, 'L', 'B', // LIBNAME
    0, 20, 0x03, 0x05, 0x3E, 0x41, 0x89, 0x37, 0x4B, 0xC6, 0xA7, 0xEF, // UNITS 1e-3 ...
    0x39, 0x44, 0xB8, 0x2F, 0xA0, 0x9B, 0x5A, 0x54, // ... 1e-9
    0, 4, 0x04, 0x00, // ENDLIB
};

// ---- private ----

/// Writes `bytes` to a fresh scratch file and reads it as a layout.
fn read(name: []const u8, bytes: []const u8) gds.Error!void {
    const gpa = testing.allocator;
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    tmp.dir.writeFile(testing.io, .{ .sub_path = name, .data = bytes }) catch return error.Io;
    const read_back = try gds.readGdsBytes(gpa, testing.io, tmp.dir, name);
    defer gpa.free(read_back);
    var strings: geom.StrTable = .empty;
    defer strings.deinit(gpa);
    var diag: gds.Diagnostic = .{};
    var lib = try gds.Library.parse(gpa, read_back, &strings, &diag);
    lib.deinit(gpa);
}

fn gzip(gpa: std.mem.Allocator, bytes: []const u8) ![]u8 {
    var out: std.Io.Writer.Allocating = try .initCapacity(gpa, 64);
    defer out.deinit();
    var window: [std.compress.flate.max_window_len]u8 = undefined;
    var deflate = try std.compress.flate.Compress.init(&out.writer, &window, .gzip, .default);
    try deflate.writer.writeAll(bytes);
    try deflate.finish();
    return out.toOwnedSlice();
}

test "a file in no known format is refused rather than read as an empty layout" {
    // Oracle: construct-from-answer. Bytes in no known format are refused,
    // not read as an empty layout, which would report clean.
    try testing.expectError(error.UnknownFormat, read("not-a-layout.bin", "this is not a layout file, it is a sentence"));
}

test "a layout that cannot be opened is an error rather than an empty store" {
    // Oracle: construct-from-answer. An unopenable layout is an error, not an
    // empty store.
    try testing.expectError(error.Io, gds.readGdsBytes(testing.allocator, testing.io, std.Io.Dir.cwd(), "/nonexistent/gpurify/no-such-layout.gds"));
}

test "a gzip layout reads as its contents across every member" {
    // Oracle: law. A gzip file reads as its contents, including one split
    // into two gzip members: stopping after the first would be a silently
    // partial layout.
    const gpa = testing.allocator;
    try read("plain.gds", &empty_library);
    const one = try gzip(gpa, &empty_library);
    defer gpa.free(one);
    try read("one-member.gds.gz", one);
    const head = try gzip(gpa, empty_library[0..10]);
    defer gpa.free(head);
    const tail = try gzip(gpa, empty_library[10..]);
    defer gpa.free(tail);
    const two = try std.mem.concat(gpa, u8, &.{ head, tail });
    defer gpa.free(two);
    try read("two-members.gds.gz", two);
    // The first member alone stops before ENDLIB: refused, never empty.
    try testing.expectError(error.Truncated, read("first-member.gds.gz", head));
}
