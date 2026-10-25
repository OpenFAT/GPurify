//! GDSII records: bytes at an offset → one `(tag, payload, next)` record, and
//! the payload decoders every element reader shares (big-endian words and
//! longs, NUL-padded ASCII, the eight-byte excess-64 real, `XY` points).
//! Cites: the GDSII Stream Format manual, release 6.0. Ported from
//! crates/ingest/src/layout.rs (`record`, `word`, `long`, `ascii`, `real`,
//! `xy`, `points`, `skip_element`).
//!
//! Contents:
//! - `pub const Tag = enum(u16)`, `pub const strans_reflect`, `pub const strans_absolute`
//! - `pub const Record`, `pub fn record(bytes: []const u8, at: usize, diag: *Diagnostic) Error!Record`
//! - `pub fn truncated(diag: *Diagnostic, at: usize) Error`, `pub fn unsupported(diag: *Diagnostic, tag: Tag, at: usize) Error`
//! - `pub fn word(payload: []const u8, at: usize, diag: *Diagnostic) Error!u16`
//! - `pub fn long(payload: []const u8, at: usize, diag: *Diagnostic) Error!i64`
//! - `pub fn ascii(payload: []const u8) []const u8`
//! - `pub fn real(payload: []const u8, at: usize, diag: *Diagnostic) Error!f64`
//! - `pub fn xy(p: *const [8]u8) [2]i64`
//! - `pub fn skipElement(bytes: []const u8, start: usize, diag: *Diagnostic) Error!usize`

const std = @import("std");
const gds = @import("gds.zig");
const Error = gds.Error;
const Diagnostic = gds.Diagnostic;

/// Record tags as on the wire: `(record type << 8) | data type`. Open: any
/// other value is a record the reader refuses.
pub const Tag = enum(u16) {
    header = 0x0002,
    bgnlib = 0x0102,
    libname = 0x0206,
    units = 0x0305,
    endlib = 0x0400,
    bgnstr = 0x0502,
    strname = 0x0606,
    endstr = 0x0700,
    boundary = 0x0800,
    path = 0x0900,
    sref = 0x0A00,
    aref = 0x0B00,
    text = 0x0C00,
    layer = 0x0D02,
    datatype = 0x0E02,
    width = 0x0F03,
    xy = 0x1003,
    endel = 0x1100,
    sname = 0x1206,
    colrow = 0x1302,
    node = 0x1500,
    texttype = 0x1602,
    presentation = 0x1701,
    string = 0x1906,
    strans = 0x1A01,
    mag = 0x1B05,
    angle = 0x1C05,
    reflibs = 0x1F06,
    fonts = 0x2006,
    pathtype = 0x2102,
    generations = 0x2202,
    attrtable = 0x2306,
    elflags = 0x2601,
    propattr = 0x2B02,
    propvalue = 0x2C06,
    box = 0x2D00,
    boxtype = 0x2E02,
    plex = 0x2F03,
    bgnextn = 0x3003,
    endextn = 0x3103,
    format = 0x3602,
    mask = 0x3706,
    endmasks = 0x3800,
    libdirsize = 0x3902,
    srfname = 0x3A06,
    libsecur = 0x3B02,
    _,
};

/// `STRANS` bit 0 (MSB first): reflect about the X axis before rotating.
pub const strans_reflect: u16 = 0x8000;
/// `STRANS` bits 13-14: absolute magnification/angle, which do not compose.
pub const strans_absolute: u16 = 0x0006;

/// One record: its tag, its payload, and the offset just past it.
pub const Record = struct { tag: Tag, payload: []const u8, next: usize };

/// The record at `at`. Refuses a length under 4 (which would loop forever),
/// an odd one (not GDSII), and one running past the end.
pub fn record(bytes: []const u8, at: usize, diag: *Diagnostic) Error!Record {
    if (bytes.len < 4 or at > bytes.len - 4) return truncated(diag, at);
    const len: usize = std.mem.readInt(u16, bytes[at..][0..2], .big);
    const tag: Tag = @fromBackingInt(std.mem.readInt(u16, bytes[at + 2 ..][0..2], .big));
    if (len < 4 or len % 2 != 0 or len > bytes.len - at) return truncated(diag, at);
    return .{ .tag = tag, .payload = bytes[at + 4 .. at + len], .next = at + len };
}

/// `Truncated` at `at`.
pub fn truncated(diag: *Diagnostic, at: usize) Error {
    diag.offset = at;
    return error.Truncated;
}

/// `UnsupportedRecord` naming `tag` at `at`.
pub fn unsupported(diag: *Diagnostic, tag: Tag, at: usize) Error {
    diag.record = @backingInt(tag);
    diag.offset = at;
    return error.UnsupportedRecord;
}

/// A two-byte integer payload.
pub fn word(payload: []const u8, at: usize, diag: *Diagnostic) Error!u16 {
    if (payload.len < 2) return truncated(diag, at);
    return std.mem.readInt(u16, payload[0..2], .big);
}

/// A four-byte signed integer payload.
pub fn long(payload: []const u8, at: usize, diag: *Diagnostic) Error!i64 {
    if (payload.len < 4) return truncated(diag, at);
    return std.mem.readInt(i32, payload[0..4], .big);
}

/// An ASCII payload, the NULs the format pads odd names with removed.
pub fn ascii(payload: []const u8) []const u8 {
    return std.mem.trimEnd(u8, payload, "\x00");
}

/// An eight-byte GDSII real: `± fraction / 2^56 · 16^(exponent − 64)`. The
/// 56-bit fraction loses bits in f64; callers accept only values exact in it.
pub fn real(payload: []const u8, at: usize, diag: *Diagnostic) Error!f64 {
    if (payload.len < 8) return truncated(diag, at);
    const sign: f64 = if (payload[0] & 0x80 == 0) 1.0 else -1.0;
    const exponent = @as(i32, payload[0] & 0x7f) - 64;
    var fraction: u64 = 0;
    for (payload[1..8]) |b| fraction = fraction << 8 | b;
    const scale: f64 = 72_057_594_037_927_936.0; // 2^56
    return sign * @as(f64, @floatFromInt(fraction)) / scale * std.math.pow(f64, 16.0, @floatFromInt(exponent));
}

/// One 8-byte `XY` point.
pub fn xy(p: *const [8]u8) [2]i64 {
    return .{ std.mem.readInt(i32, p[0..4], .big), std.mem.readInt(i32, p[4..8], .big) };
}

/// Consumes an element whose records carry nothing kept, through its
/// `ENDEL`; returns the offset past it.
pub fn skipElement(bytes: []const u8, start: usize, diag: *Diagnostic) Error!usize {
    var at = start;
    while (true) {
        const r = try record(bytes, at, diag);
        at = r.next;
        if (r.tag == .endel) return at;
    }
}

test "an eight-byte real reads the GDSII examples" {
    // Oracle: the Stream Format manual's worked reals: 0x41100000_00000000 is
    // 1.0, 0xC1100000_00000000 is -1.0, 0x3E4189374BC6A7EF is 0.001 (1e-3
    // exactly as the 56-bit fraction rounds it).
    var diag: Diagnostic = .{};
    try std.testing.expectEqual(1.0, try real(&.{ 0x41, 0x10, 0, 0, 0, 0, 0, 0 }, 0, &diag));
    try std.testing.expectEqual(-1.0, try real(&.{ 0xC1, 0x10, 0, 0, 0, 0, 0, 0 }, 0, &diag));
    const milli = try real(&.{ 0x3E, 0x41, 0x89, 0x37, 0x4B, 0xC6, 0xA7, 0xEF }, 0, &diag);
    try std.testing.expectApproxEqRel(1e-3, milli, 1e-15);
    try std.testing.expectError(error.Truncated, real(&.{ 0x41, 0x10 }, 7, &diag));
    try std.testing.expectEqual(7, diag.offset);
}
