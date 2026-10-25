//! A flattened LEF/DEF design as a GDSII stream on a deck's layers, so the
//! GDS reader, the deck's derived layers and its label binding take it as
//! any layout (GDSII Stream Format 6.0 records). In: flat shapes, the DEF's
//! units, the deck's layer table and connectivity. Out: stream bytes.
//! Ported from crates/ingest/src/lefdef/gds_out.rs.
//!
//! Contents:
//! - `pub fn toGds(gpa: Allocator, shapes: []const FlatShape, dbu: i64, design: []const u8, layers: *const LayerTable, connectivity: *const Connectivity, strings: *const StrTable, diag: *Diagnostic) Error![]u8`

const std = @import("std");
const Allocator = std.mem.Allocator;
const geom = @import("geom");
const StrTable = geom.StrTable;
const LayerId = geom.LayerId;
const lex = @import("lefdef_lex.zig");
const Error = lex.Error;
const Diagnostic = lex.Diagnostic;
const FlatShape = @import("lefdef.zig").FlatShape;
const deck = @import("deck/deck.zig");
const LayerTable = deck.LayerTable;
const Connectivity = deck.Connectivity;

/// A LEF layer's stream pair and the stream pair of its label layer.
const Lookup = struct { name: []const u8, pair: [2]u16, label: ?[2]u16 };

const Writer = struct {
    gpa: Allocator,
    out: std.ArrayList(u8) = .empty,

    fn record(w: *Writer, tag: u16, payload: []const u8) Allocator.Error!void {
        const len: u16 = @intCast(payload.len + 4);
        try w.out.appendSlice(w.gpa, &std.mem.toBytes(std.mem.nativeToBig(u16, len)));
        try w.out.appendSlice(w.gpa, &std.mem.toBytes(std.mem.nativeToBig(u16, tag)));
        try w.out.appendSlice(w.gpa, payload);
    }

    /// An ASCII record, NUL-padded to an even length.
    fn string(w: *Writer, tag: u16, text: []const u8) Allocator.Error!void {
        const bytes = text[0..@min(text.len, 65_000)];
        if (bytes.len % 2 == 0) return w.record(tag, bytes);
        const padded = try w.gpa.alloc(u8, bytes.len + 1);
        defer w.gpa.free(padded);
        @memcpy(padded[0..bytes.len], bytes);
        padded[bytes.len] = 0;
        try w.record(tag, padded);
    }
};

/// The `shapes` as one GDSII structure named `design` (`TOP` when empty), at
/// `dbu` database units per micrometre; the caller owns the bytes. Each LEF
/// layer is the deck's drawn layer of the same name. A shape on a net gets a
/// `TEXT` of the net's name at its bounding box's centre on the deck's label
/// layer for that layer: the layer itself when a `connect label` row has it
/// as its text layer, else the text layer of a row that names it. Every
/// shape of a net is labelled, so a net drawn as two unjoined pieces reads
/// as an open and two touching nets as a short. Refuses a LEF layer the deck
/// does not draw, a net shape on a conductor with no label layer, a polygon
/// of more than 8190 vertices, and a coordinate past 32 bits.
pub fn toGds(gpa: Allocator, shapes: []const FlatShape, dbu: i64, design: []const u8, layers: *const LayerTable, connectivity: *const Connectivity, strings: *const StrTable, diag: *Diagnostic) Error![]u8 {
    var w: Writer = .{ .gpa = gpa };
    errdefer w.out.deinit(gpa);
    try w.record(0x0002, &std.mem.toBytes(std.mem.nativeToBig(i16, 600)));
    try w.record(0x0102, &@as([24]u8, @splat(0)));
    try w.string(0x0206, "LEFDEF");
    const per_um: f64 = @floatFromInt(dbu);
    try w.record(0x0305, &(real(1.0 / per_um) ++ real(1e-6 / per_um)));
    try w.record(0x0502, &@as([24]u8, @splat(0)));
    try w.string(0x0606, if (design.len == 0) "TOP" else design);
    // ponytail: a linear lookup per shape; a design's LEF has tens of layers.
    var lookup: std.ArrayList(Lookup) = .empty;
    defer lookup.deinit(gpa);
    for (shapes) |flat| {
        const name = flat.shape.layer;
        const found = for (lookup.items) |l| {
            if (std.mem.eql(u8, l.name, name)) break l;
        } else blk: {
            const id = layers.id(strings, name) orelse return fail(diag, "LEF layer {s} is not a drawn layer of the deck; the deck's layer names must be the LEF's", .{name});
            if (layers.isDerived(id)) return fail(diag, "LEF layer {s} is not a drawn layer of the deck; the deck's layer names must be the LEF's", .{name});
            const row = std.mem.indexOfScalar(LayerId, connectivity.label_layer, id) orelse std.mem.indexOfScalar(LayerId, connectivity.label_names, id);
            const entry: Lookup = .{ .name = name, .pair = layers.streamOf(id), .label = if (row) |r| layers.streamOf(connectivity.label_layer[r]) else null };
            try lookup.append(gpa, entry);
            break :blk entry;
        };
        const ring = flat.shape.ring;
        // An `XY` record is at most 65535 bytes, its 4-byte header included,
        // and repeats the first point: 8190 vertices fill it.
        if (ring.len > 8190) return fail(diag, "a polygon of {d} vertices on {s} is more than one GDSII XY record holds", .{ ring.len, name });
        var xy: std.ArrayList(u8) = .empty;
        defer xy.deinit(gpa);
        for (0..ring.len + 1) |k| {
            const p = ring[k % ring.len];
            try xy.appendSlice(gpa, &big(try coord(diag, p[0], name)));
            try xy.appendSlice(gpa, &big(try coord(diag, p[1], name)));
        }
        try w.record(0x0800, &.{});
        try w.record(0x0D02, &std.mem.toBytes(std.mem.nativeToBig(u16, found.pair[0])));
        try w.record(0x0E02, &std.mem.toBytes(std.mem.nativeToBig(u16, found.pair[1])));
        try w.record(0x1003, xy.items);
        try w.record(0x1100, &.{});
        const net = flat.net orelse continue;
        const label = found.label orelse {
            const conductor = if (layers.id(strings, name)) |id| std.mem.indexOfScalar(LayerId, connectivity.conductors, id) != null else false;
            if (conductor) return fail(diag, "net {s} has shapes on {s}, which no `connect label` row names, so the net's name would be lost", .{ net, name });
            continue;
        };
        const b = flat.shape.bbox();
        const cx = b[0] + @divTrunc(b[2] - b[0], 2);
        const cy = b[1] + @divTrunc(b[3] - b[1], 2);
        try w.record(0x0C00, &.{});
        try w.record(0x0D02, &std.mem.toBytes(std.mem.nativeToBig(u16, label[0])));
        try w.record(0x1602, &std.mem.toBytes(std.mem.nativeToBig(u16, label[1])));
        try w.record(0x1003, &(big(try coord(diag, cx, name)) ++ big(try coord(diag, cy, name))));
        try w.string(0x1906, net);
        try w.record(0x1100, &.{});
    }
    try w.record(0x0700, &.{});
    try w.record(0x0400, &.{});
    return w.out.toOwnedSlice(gpa);
}

// ---- private ----

fn fail(diag: *Diagnostic, comptime fmt: []const u8, args: anytype) Error {
    diag.set("design", 0, fmt, args);
    return error.Invalid;
}

fn big(v: i32) [4]u8 {
    return std.mem.toBytes(std.mem.nativeToBig(i32, v));
}

fn coord(diag: *Diagnostic, v: i64, layer: []const u8) Error!i32 {
    if (@abs(v) <= lex.max_coord) return @intCast(v);
    return fail(diag, "a shape on {s} reaches {d}, past GDSII's 32-bit coordinates", .{ layer, v });
}

/// An eight-byte GDSII real: sign, a base-16 exponent in excess 64, and a
/// 56-bit fraction.
fn real(value: f64) [8]u8 {
    if (value == 0) return @splat(0);
    const sign: u8 = if (value < 0) 0x80 else 0;
    var v = @abs(value);
    var exponent: i32 = 64;
    while (v >= 1.0) : (exponent += 1) v /= 16.0;
    while (v < 1.0 / 16.0) : (exponent -= 1) v *= 16.0;
    const fraction = @min(@as(u64, @intFromFloat(@round(v * 72_057_594_037_927_936.0))), (1 << 56) - 1);
    var out: [8]u8 = std.mem.toBytes(std.mem.nativeToBig(u64, fraction));
    out[0] = sign | @as(u8, @intCast(exponent));
    return out;
}
