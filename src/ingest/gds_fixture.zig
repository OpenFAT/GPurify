//! GDSII bytes for the reader's tests, written from the Stream Format manual
//! and never from the reader: boundaries, references and texts → a library
//! byte string. Test-only; nothing outside a `test` block imports it.
//! Ported from the helpers of crates/ingest/src/layout.rs's tests.
//!
//! Contents:
//! - `pub const Boundary`, `pub const Ref`, `pub const Cell`
//! - `pub fn record(out: *std.ArrayList(u8), gpa: Allocator, tag: u16, payload: []const u8) !void`
//! - `pub fn gdsReal(value: f64) [8]u8`
//! - `pub fn library(gpa: Allocator, cells: []const Cell, metres_per_dbu: ?f64) ![]u8`

const std = @import("std");
const Allocator = std.mem.Allocator;

/// One BOUNDARY element: a stream pair, an open point list (the closing point
/// is added), and `PROPATTR`/`PROPVALUE` pairs.
pub const Boundary = struct {
    layer: u16,
    datatype: u16,
    xs: []const i32,
    ys: []const i32,
    props: []const struct { i16, []const u8 } = &.{},
};

/// One `SREF`: the cell placed, the `STRANS` flags, the angle in degrees, the
/// origin, and an integral magnification (1 writes no `MAG`).
pub const Ref = struct {
    cell: []const u8,
    strans: u16 = 0,
    angle: f64 = 0,
    x: i32 = 0,
    y: i32 = 0,
    mag: i32 = 1,
};

/// One structure: its name, boundaries and references.
pub const Cell = struct {
    name: []const u8,
    boundaries: []const Boundary = &.{},
    refs: []const Ref = &.{},
};

/// Appends one record: length, tag, payload.
pub fn record(out: *std.ArrayList(u8), gpa: Allocator, tag: u16, payload: []const u8) !void {
    const len: u16 = @intCast(payload.len + 4);
    std.debug.assert(len % 2 == 0);
    try out.appendSlice(gpa, &std.mem.toBytes(std.mem.nativeToBig(u16, len)));
    try out.appendSlice(gpa, &std.mem.toBytes(std.mem.nativeToBig(u16, tag)));
    try out.appendSlice(gpa, payload);
}

/// A GDSII eight-byte real; positive values only.
pub fn gdsReal(value: f64) [8]u8 {
    std.debug.assert(value > 0);
    var exponent: i32 = 64;
    var mantissa = value;
    while (mantissa >= 1.0) : (exponent += 1) mantissa /= 16.0;
    while (mantissa < 1.0 / 16.0) : (exponent -= 1) mantissa *= 16.0;
    const fraction: u64 = @intFromFloat(@round(mantissa * 72_057_594_037_927_936.0));
    std.debug.assert(fraction < 1 << 56);
    var out: [8]u8 = undefined;
    std.mem.writeInt(u64, &out, fraction, .big);
    out[0] = @intCast(exponent);
    return out;
}

/// A library of `cells` on `metres_per_dbu` (no `UNITS` record when null),
/// user units 1e-3. Every unreferenced cell is a root.
pub fn library(gpa: Allocator, cells: []const Cell, metres_per_dbu: ?f64) ![]u8 {
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(gpa);
    try record(&out, gpa, 0x0002, &be(u16, 600));
    try record(&out, gpa, 0x0102, &@as([24]u8, @splat(0)));
    try record(&out, gpa, 0x0206, "GPURIFY.DB");
    if (metres_per_dbu) |m| try record(&out, gpa, 0x0305, &(gdsReal(1e-3) ++ gdsReal(m)));
    for (cells) |cell| {
        try record(&out, gpa, 0x0502, &@as([24]u8, @splat(0)));
        try asciiRecord(&out, gpa, 0x0606, cell.name);
        for (cell.boundaries) |b| {
            try record(&out, gpa, 0x0800, &.{});
            try record(&out, gpa, 0x0D02, &be(u16, b.layer));
            try record(&out, gpa, 0x0E02, &be(u16, b.datatype));
            var xy: std.ArrayList(u8) = .empty;
            defer xy.deinit(gpa);
            for (b.xs, b.ys) |x, y| try xy.appendSlice(gpa, &(be(i32, x) ++ be(i32, y)));
            // A BOUNDARY's point list closes by repeating its first point.
            try xy.appendSlice(gpa, &(be(i32, b.xs[0]) ++ be(i32, b.ys[0])));
            try record(&out, gpa, 0x1003, xy.items);
            for (b.props) |prop| {
                try record(&out, gpa, 0x2B02, &be(i16, prop[0]));
                try asciiRecord(&out, gpa, 0x2C06, prop[1]);
            }
            try record(&out, gpa, 0x1100, &.{});
        }
        for (cell.refs) |r| {
            try record(&out, gpa, 0x0A00, &.{});
            try asciiRecord(&out, gpa, 0x1206, r.cell);
            if (r.strans != 0) try record(&out, gpa, 0x1A01, &be(u16, r.strans));
            if (r.mag != 1) try record(&out, gpa, 0x1B05, &gdsReal(@floatFromInt(r.mag)));
            if (r.angle != 0) try record(&out, gpa, 0x1C05, &gdsReal(r.angle));
            try record(&out, gpa, 0x1003, &(be(i32, r.x) ++ be(i32, r.y)));
            try record(&out, gpa, 0x1100, &.{});
        }
        try record(&out, gpa, 0x0700, &.{});
    }
    try record(&out, gpa, 0x0400, &.{});
    return out.toOwnedSlice(gpa);
}

// ---- private ----

fn be(comptime T: type, v: T) [@sizeOf(T)]u8 {
    var out: [@sizeOf(T)]u8 = undefined;
    std.mem.writeInt(T, &out, v, .big);
    return out;
}

/// An ASCII record, NUL-padded to an even length as the format requires.
fn asciiRecord(out: *std.ArrayList(u8), gpa: Allocator, tag: u16, text: []const u8) !void {
    var padded: [256]u8 = undefined;
    @memcpy(padded[0..text.len], text);
    const len = text.len + text.len % 2;
    if (text.len % 2 == 1) padded[text.len] = 0;
    try record(out, gpa, tag, padded[0..len]);
}
