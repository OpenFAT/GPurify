//! GDSII writer: the other half of `parse -> write -> parse`, for test
//! layouts. In: a flattened `GeometryStore` and the deck's `LayerTable`, or a
//! hierarchy of `Structure`s. Out: a GDSII library (one cell for a store) on
//! a 1 nm grid: `UNITS` says 0.001 user units (µm) and 1e-9 m per database
//! unit, every coordinate written as the integer it is. Timestamps are zero,
//! so the bytes are reproducible. An error names what the format cannot
//! represent. Ported from crates/testgen/src/gds.rs.
//!
//! Contents:
//! - `pub const Error`
//! - `pub const Label`, `pub const Structure`, `pub const Placement`, `pub const Array`
//! - `pub fn writeStore(gpa: Allocator, store: *const GeometryStore, layers: *const LayerTable, cell_name: []const u8, out: *std.ArrayList(u8)) Error!void`
//! - `pub fn writeStoreLabelled(gpa: Allocator, store: *const GeometryStore, layers: *const LayerTable, labels: []const Label, cell_name: []const u8, out: *std.ArrayList(u8)) Error!void`
//! - `pub fn writeLibrary(gpa: Allocator, cells: []const Structure, out: *std.ArrayList(u8)) Error!void`

const std = @import("std");
const Allocator = std.mem.Allocator;
const geom = @import("geom");
const Dbu = geom.Dbu;
const LayerId = geom.LayerId;
const PolyId = geom.PolyId;
const GeometryStore = geom.GeometryStore;
const LayerTable = @import("ingest").deck.LayerTable;

/// What GDSII cannot carry. On any error the output holds a partial library
/// and must be discarded.
pub const Error = error{
    /// A name or text outside ASCII.
    NotAscii,
    /// A polygon with fewer than three vertices.
    TooFewVertices,
    /// A coordinate beyond `i32` in magnitude (`minInt(i32)` excluded with it).
    CoordinateOutOfRange,
    /// A record over 65535 bytes (a polygon of over 8190 vertices, keyhole slits included).
    RecordTooLong,
    /// A clockwise row first on its layer: a hole with no outer before it.
    OrphanHole,
    /// A shape or label on a layer the table does not declare as drawn.
    UndeclaredLayer,
    /// An array with a zero count.
    ZeroCount,
} || Allocator.Error;

/// One text label for `writeStoreLabelled`: a `TEXT` on a drawn layer's
/// stream pair, at a point in database units, stating `text` (ASCII).
pub const Label = struct { layer: LayerId, x: i64, y: i64, text: []const u8 };

/// One structure for `writeLibrary`: its rectangles, its placements, then
/// its texts. Every string ASCII.
pub const Structure = struct {
    name: []const u8,
    /// `(layer, datatype, [xlo, ylo, xhi, yhi])`, each a counter-clockwise `BOUNDARY`.
    rects: []const struct { u16, u16, [4]i32 } = &.{},
    /// Each an `SREF`, or an `AREF` when it is an array.
    refs: []const Placement = &.{},
    /// `(layer, texttype, x, y, text)`, each a `TEXT` after the placements.
    texts: []const struct { u16, u16, i32, i32, []const u8 } = &.{},
};

/// One `SREF` or `AREF` in a `Structure`.
pub const Placement = struct {
    cell: []const u8,
    /// Reflect about the x axis before rotating (`STRANS` bit 0).
    reflect: bool = false,
    /// Counter-clockwise quarter turns, written as an `ANGLE` in degrees.
    quarter_turns: u2 = 0,
    /// Whole magnification; 1 writes no `MAG`.
    mag: u32 = 1,
    /// Where the child's origin lands; for an array, its first element's.
    at: [2]i32 = .{ 0, 0 },
    /// The lattice of an `AREF`; null for an `SREF`.
    array: ?Array = null,
};

/// An `AREF`'s lattice, in the parent's frame as the format states it.
pub const Array = struct { cols: u16, rows: u16, col_step: [2]i32, row_step: [2]i32 };

// Record tags as on the wire: `(record type << 8) | data type`.
const header: u16 = 0x0002;
const bgnlib: u16 = 0x0102;
const libname: u16 = 0x0206;
const units: u16 = 0x0305;
const endlib: u16 = 0x0400;
const bgnstr: u16 = 0x0502;
const strname: u16 = 0x0606;
const endstr: u16 = 0x0700;
const boundary: u16 = 0x0800;
const sref: u16 = 0x0A00;
const aref: u16 = 0x0B00;
const text_tag: u16 = 0x0C00;
const layer_tag: u16 = 0x0D02;
const datatype_tag: u16 = 0x0E02;
const xy: u16 = 0x1003;
const endel: u16 = 0x1100;
const sname: u16 = 0x1206;
const colrow: u16 = 0x1302;
const texttype_tag: u16 = 0x1602;
const string_tag: u16 = 0x1906;
const strans: u16 = 0x1A01;
const mag_tag: u16 = 0x1B05;
const angle_tag: u16 = 0x1C05;

/// `STRANS` bit 0 (MSB first): reflect about the x axis before rotating.
const strans_reflect: u16 = 0x8000;

/// Library and structure times: zero, never the clock.
const timestamps: [24]u8 = @splat(0);

/// `store` as a flat GDSII library of one cell, `cell_name`, appended to
/// `out`: polygons in store order, each a `BOUNDARY` on its layer's stream
/// pair; a clockwise row is a hole of the outer row before it, written
/// inside that outer's keyhole. Shapes on derived layers are skipped: they
/// are the deck's arithmetic over geometry already in the file.
pub fn writeStore(gpa: Allocator, store: *const GeometryStore, layers: *const LayerTable, cell_name: []const u8, out: *std.ArrayList(u8)) Error!void {
    return writeStoreLabelled(gpa, store, layers, &.{}, cell_name, out);
}

/// `writeStore`, plus one `TEXT` per label after the polygons, so a test
/// layout names its nets the way a drawn one does.
pub fn writeStoreLabelled(gpa: Allocator, store: *const GeometryStore, layers: *const LayerTable, labels: []const Label, cell_name: []const u8, out: *std.ArrayList(u8)) Error!void {
    try putLibraryHead(gpa, out, cell_name);
    try putRecord(gpa, out, bgnstr, &timestamps);
    try putAscii(gpa, out, strname, cell_name);
    var kx: std.ArrayList(Dbu) = .empty;
    defer kx.deinit(gpa);
    var ky: std.ArrayList(Dbu) = .empty;
    defer ky.deinit(gpa);
    for (0..store.layerCount()) |l| {
        const layer: LayerId = @fromBackingInt(@as(u16, @intCast(l)));
        const range = store.polysOnLayer(layer);
        if (range.len() == 0 or layers.isDerived(layer)) continue;
        // A row on a layer the deck never declared has no stream pair.
        if (l >= layers.len()) return error.UndeclaredLayer;
        const pair = layers.streamOf(layer);
        var row = range.start;
        while (row < range.end) {
            const v = store.polyVerts(@fromBackingInt(row));
            if (geom.ops.area2(v.xs, v.ys) < 0) return error.OrphanHole;
            // A clockwise row is a hole of the outer before it, as the reader
            // stores a keyhole: written back as one keyhole with that outer.
            const holes = row + 1;
            row = holes;
            while (row < range.end) : (row += 1) {
                const h = store.polyVerts(@fromBackingInt(row));
                if (geom.ops.area2(h.xs, h.ys) >= 0) break;
            }
            if (holes == row) {
                try putBoundary(gpa, out, pair, v.xs, v.ys);
            } else {
                try keyholeInto(gpa, store, holes - 1, row, &kx, &ky);
                try putBoundary(gpa, out, pair, kx.items, ky.items);
            }
        }
    }
    for (labels) |label| {
        if (@backingInt(label.layer) >= layers.len() or layers.isDerived(label.layer)) return error.UndeclaredLayer;
        const pair = layers.streamOf(label.layer);
        try putText(gpa, out, pair, .{ try coord(label.x), try coord(label.y) }, label.text);
    }
    try putRecord(gpa, out, endstr, &.{});
    try putRecord(gpa, out, endlib, &.{});
}

/// `cells` as one GDSII library, in order, on the 1 nm grid: the
/// hierarchical half of a `write -> parse` test. Nothing is checked against
/// the hierarchy: a placement may name any structure, itself included.
pub fn writeLibrary(gpa: Allocator, cells: []const Structure, out: *std.ArrayList(u8)) Error!void {
    try putLibraryHead(gpa, out, "LIB");
    for (cells) |cell| {
        try putRecord(gpa, out, bgnstr, &timestamps);
        try putAscii(gpa, out, strname, cell.name);
        for (cell.rects) |r| {
            const b = r[2];
            try putRecord(gpa, out, boundary, &.{});
            try putRecord(gpa, out, layer_tag, &be(u16, r[0]));
            try putRecord(gpa, out, datatype_tag, &be(u16, r[1]));
            try putRecord(gpa, out, xy, &(be(i32, b[0]) ++ be(i32, b[1]) ++ be(i32, b[2]) ++ be(i32, b[1]) ++ be(i32, b[2]) ++ be(i32, b[3]) ++ be(i32, b[0]) ++ be(i32, b[3]) ++ be(i32, b[0]) ++ be(i32, b[1])));
            try putRecord(gpa, out, endel, &.{});
        }
        for (cell.refs) |p| try putPlacement(gpa, out, p);
        for (cell.texts) |t| try putText(gpa, out, .{ t[0], t[1] }, .{ t[2], t[3] }, t[4]);
        try putRecord(gpa, out, endstr, &.{});
    }
    try putRecord(gpa, out, endlib, &.{});
}

// ---- private ----

/// One `SREF` or `AREF`, in the format's record order.
fn putPlacement(gpa: Allocator, out: *std.ArrayList(u8), p: Placement) Error!void {
    var points: [3][2]i32 = .{ p.at, undefined, undefined };
    var n: usize = 1;
    if (p.array) |a| {
        if (a.cols == 0 or a.rows == 0) return error.ZeroCount;
        for ([_]u16{ a.cols, a.rows }, [_][2]i32{ a.col_step, a.row_step }) |count, step| {
            for (0..2) |axis| points[n][axis] = std.math.cast(i32, @as(i64, p.at[axis]) + @as(i64, count) * step[axis]) orelse return error.CoordinateOutOfRange;
            n += 1;
        }
    }
    try putRecord(gpa, out, if (p.array == null) sref else aref, &.{});
    try putAscii(gpa, out, sname, p.cell);
    if (p.reflect or p.mag != 1 or p.quarter_turns != 0) {
        try putRecord(gpa, out, strans, &be(u16, if (p.reflect) strans_reflect else 0));
        if (p.mag != 1) try putRecord(gpa, out, mag_tag, &real8(@floatFromInt(p.mag)));
        if (p.quarter_turns != 0) try putRecord(gpa, out, angle_tag, &real8(@as(f64, @floatFromInt(p.quarter_turns)) * 90.0));
    }
    if (p.array) |a| try putRecord(gpa, out, colrow, &(be(u16, a.cols) ++ be(u16, a.rows)));
    var payload: [24]u8 = undefined;
    for (points[0..n], 0..) |pt, k| payload[k * 8 ..][0..8].* = be(i32, pt[0]) ++ be(i32, pt[1]);
    try putRecord(gpa, out, xy, payload[0 .. n * 8]);
    try putRecord(gpa, out, endel, &.{});
}

/// One `TEXT` element: the stream pair, the point, and the string.
fn putText(gpa: Allocator, out: *std.ArrayList(u8), pair: [2]u16, at: [2]i32, text: []const u8) Error!void {
    try putRecord(gpa, out, text_tag, &.{});
    try putRecord(gpa, out, layer_tag, &be(u16, pair[0]));
    try putRecord(gpa, out, texttype_tag, &be(u16, pair[1]));
    try putRecord(gpa, out, xy, &(be(i32, at[0]) ++ be(i32, at[1])));
    try putAscii(gpa, out, string_tag, text);
    try putRecord(gpa, out, endel, &.{});
}

/// `HEADER`, `BGNLIB`, `LIBNAME` and `UNITS`: everything before the first cell.
fn putLibraryHead(gpa: Allocator, out: *std.ArrayList(u8), name: []const u8) Error!void {
    try putRecord(gpa, out, header, &be(u16, 600));
    try putRecord(gpa, out, bgnlib, &timestamps);
    try putAscii(gpa, out, libname, name);
    try putRecord(gpa, out, units, &(real8(1e-3) ++ real8(1e-9)));
}

/// Rows `first..past`, an outer then its clockwise holes, as one GDSII
/// keyhole ring into `kx, ky`: the outer, then from its first vertex an
/// axis-aligned slit out to each hole's first vertex, around the hole and
/// back along the same slit. Each slit is drawn both ways, so it encloses
/// nothing, and the reader's keyhole split gives back the outer and holes.
fn keyholeInto(gpa: Allocator, store: *const GeometryStore, first: u32, past: u32, kx: *std.ArrayList(Dbu), ky: *std.ArrayList(Dbu)) Allocator.Error!void {
    kx.clearRetainingCapacity();
    ky.clearRetainingCapacity();
    const o = store.polyVerts(@fromBackingInt(first));
    for (o.xs, o.ys) |x, y| try go(gpa, kx, ky, x, y);
    const x0 = o.xs[0];
    const y0 = o.ys[0];
    for (first + 1..past) |hole| {
        const h = store.polyVerts(@fromBackingInt(@intCast(hole)));
        try go(gpa, kx, ky, x0, y0);
        try go(gpa, kx, ky, h.xs[0], y0);
        for (h.xs, h.ys) |x, y| try go(gpa, kx, ky, x, y);
        try go(gpa, kx, ky, h.xs[0], h.ys[0]);
        try go(gpa, kx, ky, h.xs[0], y0);
    }
}

/// Appends `(x, y)` unless it repeats the last vertex.
fn go(gpa: Allocator, kx: *std.ArrayList(Dbu), ky: *std.ArrayList(Dbu), x: Dbu, y: Dbu) Allocator.Error!void {
    const n = kx.items.len;
    if (n > 0 and kx.items[n - 1] == x and ky.items[n - 1] == y) return;
    try kx.append(gpa, x);
    try ky.append(gpa, y);
}

/// One `BOUNDARY`: the stream pair and the closed outline. GDSII repeats a
/// boundary's first point as its last; the reader drops it again, which
/// keeps `parse -> write -> parse` from growing a vertex per trip.
fn putBoundary(gpa: Allocator, out: *std.ArrayList(u8), pair: [2]u16, xs: []const Dbu, ys: []const Dbu) Error!void {
    if (xs.len < 3) return error.TooFewVertices;
    const len = (xs.len + 1) * 8;
    if (len + 4 > std.math.maxInt(u16)) return error.RecordTooLong;
    try putRecord(gpa, out, boundary, &.{});
    try putRecord(gpa, out, layer_tag, &be(u16, pair[0]));
    try putRecord(gpa, out, datatype_tag, &be(u16, pair[1]));
    try out.appendSlice(gpa, &(be(u16, @intCast(len + 4)) ++ be(u16, xy)));
    for (0..xs.len + 1) |k| {
        const i = if (k == xs.len) 0 else k;
        try out.appendSlice(gpa, &(be(i32, try coord(xs[i])) ++ be(i32, try coord(ys[i]))));
    }
    try putRecord(gpa, out, endel, &.{});
}

/// A coordinate as a GDSII 32-bit database unit; `minInt(i32)` refused too.
fn coord(v: i64) Error!i32 {
    if (@abs(v) > std.math.maxInt(i32)) return error.CoordinateOutOfRange;
    return @intCast(v);
}

fn putRecord(gpa: Allocator, out: *std.ArrayList(u8), tag: u16, payload: []const u8) Error!void {
    if (payload.len + 4 > std.math.maxInt(u16)) return error.RecordTooLong;
    try out.appendSlice(gpa, &(be(u16, @intCast(payload.len + 4)) ++ be(u16, tag)));
    try out.appendSlice(gpa, payload);
}

/// A name record, NUL-padded to an even length.
fn putAscii(gpa: Allocator, out: *std.ArrayList(u8), tag: u16, text: []const u8) Error!void {
    for (text) |c| if (c >= 0x80) return error.NotAscii;
    const padding = text.len % 2;
    if (text.len + padding + 4 > std.math.maxInt(u16)) return error.RecordTooLong;
    try out.appendSlice(gpa, &(be(u16, @intCast(text.len + padding + 4)) ++ be(u16, tag)));
    try out.appendSlice(gpa, text);
    try out.appendNTimes(gpa, 0, padding);
}

fn be(comptime T: type, v: T) [@sizeOf(T)]u8 {
    var out: [@sizeOf(T)]u8 = undefined;
    std.mem.writeInt(T, &out, v, .big);
    return out;
}

/// An eight-byte GDSII real: sign, a seven-bit excess-64 base-16 exponent
/// and a 56-bit fraction, `± fraction / 2^56 · 16^(exponent − 64)`.
fn real8(value: f64) [8]u8 {
    if (value == 0) return @splat(0);
    const sign: u8 = if (value < 0) 0x80 else 0;
    var mantissa = @abs(value);
    var exponent: i32 = 64;
    while (mantissa >= 1.0) : (exponent += 1) mantissa /= 16.0;
    while (mantissa < 1.0 / 16.0) : (exponent -= 1) mantissa *= 16.0;
    var out = be(u64, @intFromFloat(@round(mantissa * 72_057_594_037_927_936.0)));
    out[0] = sign | @as(u8, @intCast(exponent));
    return out;
}
