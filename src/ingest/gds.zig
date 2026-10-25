//! GDSII reader: a record stream → one `Library`, the hierarchy intact.
//! In: GDSII bytes (plain, or gzip through `readGdsBytes`). Out: SoA tables
//! of cells, elements, references, texts and one pair of coordinate columns,
//! every string interned into the run's `StrTable` in file order. Nothing is
//! scaled: coordinates stay in the file's database units, and `grid` states
//! their size. An inexact construct is refused with its byte offset, never
//! rounded. Cites: the GDSII Stream Format manual, release 6.0 (record types
//! and data types, `STRANS` bits, the eight-byte real).
//! Ported from crates/ingest/src/layout.rs (`read_gds_bytes`, `gds::Library::parse`,
//! `grid`, `Xform`).
//!
//! Contents:
//! - `pub const Error`, `pub const Diagnostic`
//! - `pub const Xform`, `Xform.identity`, `Xform.linear(x: Xform) [4]i64`,
//!   `Xform.apply(x: Xform, px: i64, py: i64) ?[2]i64`,
//!   `Xform.compose(parent: Xform, child: Xform) ?Xform`
//! - `pub const Cell`, `pub const Elem`, `pub const Ref`, `Ref.element(r: Ref, row: u32, col: u32) Xform`,
//!   `pub const Text`
//! - `pub const Library`, `Library.deinit(lib: *Library, gpa: Allocator) void`,
//!   `Library.parse(gpa: Allocator, bytes: []const u8, strings: *StrTable, diag: *Diagnostic) Error!Library`,
//!   `Library.grid(lib: *const Library, diag: *Diagnostic) Error!Grid`
//! - `pub fn readGdsBytes(gpa: Allocator, io: std.Io, dir: std.Io.Dir, sub_path: []const u8) Error![]u8`

const std = @import("std");
const Allocator = std.mem.Allocator;
const assert = std.debug.assert;
const geom = @import("geom");
const StrId = geom.StrId;
const StrTable = geom.StrTable;
const Grid = geom.Grid;
const rec = @import("gds_records.zig");
const elements = @import("gds_elements.zig");
const fixture = @import("gds_fixture.zig");
const testing = std.testing;

/// Why a layout could not be read; the `Diagnostic` says where. Every member
/// is a refusal: approximating a transform moves geometry and moves verdicts.
pub const Error = error{
    /// The bytes, after any gunzip, do not open with a GDSII `HEADER` record
    /// (OASIS is not read).
    UnknownFormat,
    /// The stream ends inside a record or before `ENDLIB`, a record's length
    /// is under 4 or odd, a payload is shorter than its type needs, or a
    /// structure is still open at `ENDLIB`. `diag.offset` is the record's.
    Truncated,
    /// A record outside the reader's subset or out of place, or an element
    /// missing what it needs (no `LAYER`/`DATATYPE`/`XY`, a boundary under
    /// three vertices, a `TEXT` without exactly one point, a reference
    /// without its name or points, a `PATH` of odd or non-positive `WIDTH`
    /// or a `PATHTYPE` other than 0, 2 or 4). `diag.record` and `diag.offset`.
    UnsupportedRecord,
    /// A placement that would move geometry off the integer grid: absolute
    /// `STRANS`, a magnification not a whole number from 1 to 10^6, an angle
    /// not a multiple of 90°, an `AREF` whose pitch does not divide exactly
    /// or with a zero count; a `PATH` with a diagonal or zero-length segment
    /// or a vertex that turns back on itself.
    UnsupportedTransform,
    /// An `SREF` or `AREF` names a structure the library does not define.
    /// `diag.cell`.
    MissingCell,
    /// Two structures share a name: which one a reference places is not
    /// stated. `diag.cell`.
    DuplicateCell,
    /// Without `UNITS`, no deck length converts to the layout's grid.
    NoUnits,
    /// The database unit is not a whole fraction of a micrometre.
    /// `diag.metres_per_dbu`.
    UnsupportedUnits,
    /// The file could not be read or un-gzipped.
    Io,
    OutOfMemory,
};

/// Where and on what a read failed; each field is set by the errors its doc
/// names, the rest keep their defaults.
pub const Diagnostic = struct {
    /// Byte offset of the record (`Truncated`, `UnsupportedRecord`).
    offset: usize = 0,
    /// The record type, or the element's (`UnsupportedRecord`).
    record: u16 = 0,
    /// The cell (`MissingCell`, `DuplicateCell`).
    cell: ?StrId = null,
    /// The `UNITS` record's metres per database unit (`UnsupportedUnits`).
    metres_per_dbu: f64 = 0,
};

/// An exact instance transform: integral magnification, optional reflection
/// about X, a quarter turn, a translation. Closed under composition since
/// `F·R_q = R_{-q}·F`. Invariant: `mag >= 1`, `quadrant < 4`.
pub const Xform = struct {
    mag: i64,
    flip: bool,
    quadrant: u2,
    dx: i64,
    dy: i64,

    pub const identity: Xform = .{ .mag = 1, .flip = false, .quadrant = 0, .dx = 0, .dy = 0 };

    /// The linear part `(a, b, c, e)` of `x' = a·x + b·y`, `y' = c·x + e·y`.
    pub fn linear(x: Xform) [4]i64 {
        const r: [4]i64 = switch (x.quadrant) {
            0 => .{ 1, 0, 0, 1 },
            1 => .{ 0, -1, 1, 0 },
            2 => .{ -1, 0, 0, -1 },
            3 => .{ 0, 1, -1, 0 },
        };
        // Reflection runs before rotation: the second column negated.
        const s: i64 = if (x.flip) -1 else 1;
        return .{ x.mag * r[0], x.mag * r[1] * s, x.mag * r[2], x.mag * r[3] * s };
    }

    /// `x` applied to a point; null on i64 overflow.
    pub fn apply(x: Xform, px: i64, py: i64) ?[2]i64 {
        const l = x.linear();
        const x2 = addAll(&.{ mulOrNull(l[0], px) orelse return null, mulOrNull(l[1], py) orelse return null, x.dx }) orelse return null;
        const y2 = addAll(&.{ mulOrNull(l[2], px) orelse return null, mulOrNull(l[3], py) orelse return null, x.dy }) orelse return null;
        return .{ x2, y2 };
    }

    /// `parent` applied after `child`; null on i64 overflow: nested
    /// magnifications multiply, and a wrapped value could pass the bound.
    pub fn compose(parent: Xform, child: Xform) ?Xform {
        const d = parent.apply(child.dx, child.dy) orelse return null;
        return .{
            .mag = mulOrNull(parent.mag, child.mag) orelse return null,
            .flip = parent.flip != child.flip,
            // A reflecting parent reverses the child's turn as it commutes past it.
            .quadrant = if (parent.flip) parent.quadrant -% child.quadrant else parent.quadrant +% child.quadrant,
            .dx = d[0],
            .dy = d[1],
        };
    }
};

/// One structure, as ranges into the library's element, reference and text
/// tables. Invariant (asserted at the end of `parse`): `*_start <= *_end`
/// within each table.
pub const Cell = struct {
    name: StrId,
    elem_start: u32,
    elem_end: u32,
    ref_start: u32,
    ref_end: u32,
    text_start: u32,
    text_end: u32,
};

/// One shape: a ring of at least three vertices in the coordinate columns,
/// counter-clockwise (but see `gds_elements.zig` on keyholes), without the
/// closing point the format repeats.
pub const Elem = struct {
    layer: u16,
    datatype: u16,
    vert_start: u32,
    vert_len: u32,
};

/// One `SREF` or `AREF`; an `SREF` is the 1×1 array with zero steps.
pub const Ref = struct {
    cell: StrId,
    /// Row of `Library.cells`, resolved once parsing is done.
    child: u32,
    /// The child's own transform; its translation is the array origin.
    place: Xform,
    col_step: [2]i64,
    row_step: [2]i64,
    cols: u32,
    rows: u32,

    /// Array element `(row, col)`'s transform relative to the parent: the
    /// placement moved by the steps.
    pub fn element(r: Ref, row: u32, col: u32) Xform {
        var x = r.place;
        x.dx = r.place.dx + @as(i64, col) * r.col_step[0] + @as(i64, row) * r.row_step[0];
        x.dy = r.place.dy + @as(i64, col) * r.col_step[1] + @as(i64, row) * r.row_step[1];
        return x;
    }
};

/// One `TEXT` as the file states it, before any transform.
pub const Text = struct {
    layer: u16,
    texttype: u16,
    x: i64,
    y: i64,
    string: StrId,
};

/// A parsed library: hierarchy intact, nothing mapped to a deck yet. Every
/// `BOUNDARY` and `BOX` is one counter-clockwise ring and every `PATH` is
/// stroked into its outline, exactly. Rings are not otherwise validated: a
/// diagonal or self-crossing boundary is refused where a check reads it.
pub const Library = struct {
    /// The `UNITS` record's second value; null until one is read.
    metres_per_dbu: ?f64 = null,
    cells: std.MultiArrayList(Cell) = .empty,
    elems: std.MultiArrayList(Elem) = .empty,
    refs: std.MultiArrayList(Ref) = .empty,
    texts: std.MultiArrayList(Text) = .empty,
    xs: std.ArrayList(i64) = .empty,
    ys: std.ArrayList(i64) = .empty,

    pub fn deinit(lib: *Library, gpa: Allocator) void {
        lib.cells.deinit(gpa);
        lib.elems.deinit(gpa);
        lib.refs.deinit(gpa);
        lib.texts.deinit(gpa);
        lib.xs.deinit(gpa);
        lib.ys.deinit(gpa);
    }

    /// Reads the record stream in one pass: every record is consumed,
    /// skipped, or refused; bytes after `ENDLIB` (block padding) are ignored.
    /// Glyph records on a `TEXT` and properties are accepted and discarded.
    /// Cell names, `TEXT`s, `SNAME`s and `PROPVALUE`s are interned in file
    /// order. On error, `strings` may have gained names.
    pub fn parse(gpa: Allocator, bytes: []const u8, strings: *StrTable, diag: *Diagnostic) Error!Library {
        var lib: Library = .{};
        errdefer lib.deinit(gpa);
        var scratch: elements.Scratch = .{};
        defer scratch.deinit(gpa);
        const r: elements.Reader = .{ .gpa = gpa, .bytes = bytes, .strings = strings, .diag = diag, .lib = &lib, .scratch = &scratch };
        var open: ?u32 = null;
        var at: usize = 0;
        while (true) {
            const record = try rec.record(bytes, at, diag);
            switch (record.tag) {
                .endlib => break,
                // Coordinates stay database units; `UNITS` only names their size.
                .units => {
                    if (record.payload.len < 8) return rec.truncated(diag, at);
                    lib.metres_per_dbu = try rec.real(record.payload[8..], at, diag);
                },
                .header, .bgnlib, .libname, .reflibs, .fonts, .generations, .attrtable, .format, .mask, .endmasks, .libdirsize, .srfname, .libsecur => {},
                .bgnstr => {
                    if (open != null) return rec.unsupported(diag, record.tag, at);
                    open = rows(lib.cells.len);
                    // Named by STRNAME; a structure without one is refused at ENDSTR.
                    try lib.cells.append(gpa, .{
                        .name = no_name,
                        .elem_start = rows(lib.elems.len),
                        .elem_end = rows(lib.elems.len),
                        .ref_start = rows(lib.refs.len),
                        .ref_end = rows(lib.refs.len),
                        .text_start = rows(lib.texts.len),
                        .text_end = rows(lib.texts.len),
                    });
                },
                .strname => {
                    const index = open orelse return rec.unsupported(diag, record.tag, at);
                    lib.cells.items(.name)[index] = try strings.intern(gpa, rec.ascii(record.payload));
                },
                .endstr => {
                    const index = open orelse return rec.unsupported(diag, record.tag, at);
                    open = null;
                    if (lib.cells.items(.name)[index] == no_name) return rec.unsupported(diag, .bgnstr, at);
                    lib.cells.items(.elem_end)[index] = rows(lib.elems.len);
                    lib.cells.items(.ref_end)[index] = rows(lib.refs.len);
                    lib.cells.items(.text_end)[index] = rows(lib.texts.len);
                },
                .boundary, .box, .path, .sref, .aref, .text => {
                    if (open == null) return rec.unsupported(diag, record.tag, at);
                    at = switch (record.tag) {
                        .boundary, .box => try r.boundary(record.next, at, record.tag),
                        .path => try r.path(record.next, at),
                        .sref, .aref => try r.reference(record.next, at, record.tag == .aref),
                        .text => try r.text(record.next, at),
                        // else: the enclosing prong lists exactly these six
                        else => unreachable,
                    };
                    continue;
                },
                // A NODE has no shape and no name: nothing to record.
                .node => {
                    at = try rec.skipElement(bytes, record.next, diag);
                    continue;
                },
                // else: the tag set is open; every record not listed is refused
                else => return rec.unsupported(diag, record.tag, at),
            }
            at = record.next;
        }
        if (open != null) return rec.truncated(diag, at);
        try resolveRefs(gpa, &lib, diag);
        assertTables(&lib);
        return lib;
    }

    /// The layout's grid from its `UNITS` record: database units per
    /// micrometre, within the 1e-9 relative error an eight-byte real carries
    /// (a written 1 nm reads as exactly 1000).
    pub fn grid(lib: *const Library, diag: *Diagnostic) Error!Grid {
        const metres = lib.metres_per_dbu orelse return error.NoUnits;
        const per_um = 1e-6 / metres;
        const whole = @round(per_um);
        // Negated so NaN and the infinities are refused with the misfits.
        if (!(whole >= 1.0 and @abs(per_um - whole) <= whole * 1e-9 and whole < 1e15)) {
            diag.metres_per_dbu = metres;
            return error.UnsupportedUnits;
        }
        return Grid.init(@intFromFloat(whole)) catch {
            diag.metres_per_dbu = metres;
            return error.UnsupportedUnits;
        };
    }
};

/// The name of a cell whose `STRNAME` has not been read yet.
const no_name: StrId = @fromBackingInt(std.math.maxInt(u32));

const square: fixture.Boundary = .{ .layer = 68, .datatype = 20, .xs = &.{ 0, 400, 400, 0 }, .ys = &.{ 0, 0, 400, 400 } };

/// A GDSII file's bytes, gunzipped when the file is gzip: every member of a
/// multi-member gzip, so a concatenated file is never read partially. The
/// caller owns the result. `Io` when the file cannot be read or
/// decompressed, `UnknownFormat` when the bytes do not open with a `HEADER`.
pub fn readGdsBytes(gpa: Allocator, io: std.Io, dir: std.Io.Dir, sub_path: []const u8) Error![]u8 {
    const raw = dir.readFileAlloc(io, sub_path, gpa, .unlimited) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        else => return error.Io,
    };
    const bytes = if (std.mem.startsWith(u8, raw, &.{ 0x1f, 0x8b })) blk: {
        defer gpa.free(raw);
        break :blk try gunzip(gpa, raw);
    } else raw;
    // A GDSII `HEADER` record: length 6, type 0, data type 2.
    if (!std.mem.startsWith(u8, bytes, &.{ 0x00, 0x06, 0x00, 0x02 })) {
        gpa.free(bytes);
        return error.UnknownFormat;
    }
    return bytes;
}
// ---- private ----

/// A table length as the `u32` rows are indexed by.
fn rows(len: usize) u32 {
    return @intCast(len);
}

fn mulOrNull(a: i64, b: i64) ?i64 {
    const m = @mulWithOverflow(a, b);
    return if (m[1] == 0) m[0] else null;
}

fn addAll(terms: []const i64) ?i64 {
    var sum: i64 = 0;
    for (terms) |t| {
        const s = @addWithOverflow(sum, t);
        if (s[1] != 0) return null;
        sum = s[0];
    }
    return sum;
}

/// Refuses two structures of one name, then points every reference at the
/// cell it names. Cells sorted by (name, row) make both a neighbour test and
/// a binary search.
fn resolveRefs(gpa: Allocator, lib: *Library, diag: *Diagnostic) Error!void {
    const names = lib.cells.items(.name);
    const by_name = try gpa.alloc(u32, names.len);
    defer gpa.free(by_name);
    for (by_name, 0..) |*b, i| b.* = @intCast(i);
    std.mem.sortUnstable(u32, by_name, names, struct {
        fn less(n: []const StrId, a: u32, b: u32) bool {
            const na = @backingInt(n[a]);
            const nb = @backingInt(n[b]);
            return na < nb or (na == nb and a < b);
        }
    }.less);
    for (by_name[0..by_name.len -| 1], by_name[@min(1, by_name.len)..]) |a, b| {
        if (names[a] == names[b]) {
            diag.cell = names[a];
            return error.DuplicateCell;
        }
    }
    for (lib.refs.items(.cell), lib.refs.items(.child)) |cell, *child| {
        child.* = lowerBound(by_name, names, cell) orelse {
            diag.cell = cell;
            return error.MissingCell;
        };
    }
}

/// The row named `name` in `by_name` (rows sorted by name), or null.
fn lowerBound(by_name: []const u32, names: []const StrId, name: StrId) ?u32 {
    var lo: usize = 0;
    var hi: usize = by_name.len;
    while (lo < hi) {
        const mid = lo + (hi - lo) / 2;
        if (@backingInt(names[by_name[mid]]) < @backingInt(name)) lo = mid + 1 else hi = mid;
    }
    return if (lo < by_name.len and names[by_name[lo]] == name) by_name[lo] else null;
}

fn assertTables(lib: *const Library) void {
    assert(lib.xs.items.len == lib.ys.items.len);
    for (lib.elems.items(.vert_start), lib.elems.items(.vert_len)) |start, len| {
        assert(len >= 3 and @as(usize, start) + len <= lib.xs.items.len);
    }
    const c = lib.cells.slice();
    for (0..lib.cells.len) |i| {
        assert(c.items(.elem_start)[i] <= c.items(.elem_end)[i] and c.items(.elem_end)[i] <= lib.elems.len);
        assert(c.items(.ref_start)[i] <= c.items(.ref_end)[i] and c.items(.ref_end)[i] <= lib.refs.len);
        assert(c.items(.text_start)[i] <= c.items(.text_end)[i] and c.items(.text_end)[i] <= lib.texts.len);
    }
    for (lib.refs.items(.child)) |child| assert(child < lib.cells.len);
}

/// All of a gzip stream, member after member.
fn gunzip(gpa: Allocator, compressed: []const u8) Error![]u8 {
    var out: std.Io.Writer.Allocating = .init(gpa);
    defer out.deinit();
    var rest = compressed;
    while (rest.len > 0) {
        if (!std.mem.startsWith(u8, rest, &.{ 0x1f, 0x8b })) return error.Io;
        var input: std.Io.Reader = .fixed(rest);
        var inflate: std.compress.flate.Decompress = .init(&input, .gzip, &.{});
        _ = inflate.reader.streamRemaining(&out.writer) catch |err| switch (err) {
            error.WriteFailed => return error.OutOfMemory,
            error.ReadFailed => return error.Io,
        };
        if (input.seek == 0) return error.Io;
        rest = rest[input.seek..];
    }
    return out.toOwnedSlice() catch error.OutOfMemory;
}

fn unitsLibrary(metres: ?f64) ![]u8 {
    return fixture.library(testing.allocator, &.{.{ .name = "TOP" }}, metres);
}

/// The error `bytes` parses to, or null when it parses.
fn refusal(bytes: []const u8, strings: *StrTable, diag: *Diagnostic) ?Error {
    var lib = Library.parse(testing.allocator, bytes, strings, diag) catch |err| return err;
    lib.deinit(testing.allocator);
    return null;
}

fn expectRefusal(want: ?Error, got: ?Error) !void {
    try testing.expectEqual(want, got);
}

/// `refusal` of the library of `cells`.
fn cellsRefusal(cells: []const fixture.Cell, strings: *StrTable, diag: *Diagnostic) !?Error {
    const bytes = try fixture.library(testing.allocator, cells, 1e-9);
    defer testing.allocator.free(bytes);
    return refusal(bytes, strings, diag);
}

/// A one-cell library holding one `PATH` of `width` on 68/20 along `xs, ys`.
fn pathLibrary(width: i32, xs: []const i32, ys: []const i32) ![]u8 {
    const gpa = testing.allocator;
    const head = try fixture.library(gpa, &.{}, 1e-9);
    defer gpa.free(head);
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(gpa);
    try out.appendSlice(gpa, head[0 .. head.len - 4]);
    try fixture.record(&out, gpa, 0x0502, &@as([24]u8, @splat(0)));
    try fixture.record(&out, gpa, 0x0606, "TOP\x00");
    try fixture.record(&out, gpa, 0x0900, &.{});
    try fixture.record(&out, gpa, 0x0D02, &.{ 0, 68 });
    try fixture.record(&out, gpa, 0x0E02, &.{ 0, 20 });
    var w: [4]u8 = undefined;
    std.mem.writeInt(i32, &w, width, .big);
    try fixture.record(&out, gpa, 0x0F03, &w);
    var xy: std.ArrayList(u8) = .empty;
    defer xy.deinit(gpa);
    for (xs, ys) |x, y| {
        var p: [8]u8 = undefined;
        std.mem.writeInt(i32, p[0..4], x, .big);
        std.mem.writeInt(i32, p[4..8], y, .big);
        try xy.appendSlice(gpa, &p);
    }
    try fixture.record(&out, gpa, 0x1003, xy.items);
    try fixture.record(&out, gpa, 0x1100, &.{});
    try fixture.record(&out, gpa, 0x0700, &.{});
    try fixture.record(&out, gpa, 0x0400, &.{});
    return out.toOwnedSlice(gpa);
}

test "the units record is the grid" {
    // Oracle: the GDSII definition, database units per micrometre being
    // 1e-6 m over the stated metres per unit.
    const gpa = testing.allocator;
    const cases = [_]struct { f64, i64 }{ .{ 1e-9, 1000 }, .{ 5e-9, 200 }, .{ 2.5e-10, 4000 }, .{ 1e-6, 1 } };
    for (cases) |c| {
        const bytes = try unitsLibrary(c[0]);
        defer gpa.free(bytes);
        var strings: StrTable = .empty;
        defer strings.deinit(gpa);
        var diag: Diagnostic = .{};
        var lib = try Library.parse(gpa, bytes, &strings, &diag);
        defer lib.deinit(gpa);
        try testing.expectEqual(c[1], (try lib.grid(&diag)).dbu_per_um);
    }
}

test "a missing or fractional unit is refused" {
    // Oracle: hand-derived. A unit of 3e-9 m is 333.3 units per um and 2e-6 m
    // half a unit per um, neither a whole number, and a library with no UNITS
    // record states no grid at all.
    const gpa = testing.allocator;
    const cases = [_]struct { ?f64, Error }{ .{ null, error.NoUnits }, .{ 3e-9, error.UnsupportedUnits }, .{ 2e-6, error.UnsupportedUnits } };
    for (cases) |c| {
        const bytes = try unitsLibrary(c[0]);
        defer gpa.free(bytes);
        var strings: StrTable = .empty;
        defer strings.deinit(gpa);
        var diag: Diagnostic = .{};
        var lib = try Library.parse(gpa, bytes, &strings, &diag);
        defer lib.deinit(gpa);
        try testing.expectError(c[1], lib.grid(&diag));
    }
}

test "a record running past the end of the file is a truncation, not a short read" {
    // Oracle: construct-from-answer. One byte is cut from a well-formed
    // library, so its last record's header states a length the file does not
    // hold: a truncation, at an offset inside the file.
    const gpa = testing.allocator;
    const bytes = try fixture.library(gpa, &.{.{ .name = "TOP", .boundaries = &.{square} }}, 1e-9);
    defer gpa.free(bytes);
    var strings: StrTable = .empty;
    defer strings.deinit(gpa);
    var diag: Diagnostic = .{};
    try testing.expectError(error.Truncated, Library.parse(gpa, bytes[0 .. bytes.len - 1], &strings, &diag));
    try testing.expect(diag.offset <= bytes.len - 1);
}

test "each layout input exception the parser sees is refused by name" {
    // Oracle: the GDSII format (`STRNAME` once per structure; a `PATH`
    // outline at half its width from the centreline) and the documented
    // refusals. Metamorphic: the duplicates in either order are refused
    // alike. The parse-level half of Rust's
    // `each_layout_input_exception_is_refused_by_name_or_read_as_stated`;
    // the magnified-square, spike and staircase halves need `flatten`
    // (wave 2).
    const gpa = testing.allocator;
    var strings: StrTable = .empty;
    defer strings.deinit(gpa);
    var diag: Diagnostic = .{};
    const sq = [_]fixture.Boundary{square};

    const missing = [_]fixture.Ref{.{ .cell = "NOWHERE" }};
    try expectRefusal(error.MissingCell, try cellsRefusal(&.{.{ .name = "TOP", .refs = &missing }}, &strings, &diag));
    try testing.expectEqualStrings("NOWHERE", strings.resolve(diag.cell.?));

    const leaf = [_]fixture.Ref{.{ .cell = "LEAF" }};
    try expectRefusal(error.DuplicateCell, try cellsRefusal(&.{ .{ .name = "TOP", .refs = &leaf }, .{ .name = "LEAF", .boundaries = &sq }, .{ .name = "LEAF" } }, &strings, &diag));
    try testing.expectEqualStrings("LEAF", strings.resolve(diag.cell.?));
    diag = .{};
    try expectRefusal(error.DuplicateCell, try cellsRefusal(&.{ .{ .name = "LEAF" }, .{ .name = "TOP", .refs = &leaf }, .{ .name = "LEAF", .boundaries = &sq } }, &strings, &diag));
    try testing.expectEqualStrings("LEAF", strings.resolve(diag.cell.?));

    const turned = [_]fixture.Ref{.{ .cell = "LEAF", .angle = 45 }};
    try expectRefusal(error.UnsupportedTransform, try cellsRefusal(&.{ .{ .name = "TOP", .refs = &turned }, .{ .name = "LEAF", .boundaries = &sq } }, &strings, &diag));

    // The tripled library with the MAG record's real 3.0 replaced by 2.5.
    const tripled = [_]fixture.Ref{.{ .cell = "LEAF", .mag = 3 }};
    const bytes = try fixture.library(gpa, &.{ .{ .name = "TOP", .refs = &tripled }, .{ .name = "LEAF", .boundaries = &sq } }, 1e-9);
    defer gpa.free(bytes);
    try expectRefusal(null, refusal(bytes, &strings, &diag));
    const at = std.mem.indexOf(u8, bytes, &fixture.gdsReal(3.0)).?;
    @memcpy(bytes[at..][0..8], &fixture.gdsReal(2.5));
    try expectRefusal(error.UnsupportedTransform, refusal(bytes, &strings, &diag));

    for ([_]i32{ 0, 101 }) |width| {
        const path_bytes = try pathLibrary(width, &.{ 0, 4000 }, &.{ 0, 0 });
        defer gpa.free(path_bytes);
        diag = .{};
        try expectRefusal(error.UnsupportedRecord, refusal(path_bytes, &strings, &diag));
        try testing.expectEqual(@as(u16, 0x0F03), diag.record);
    }
}

test "a path is stroked to its outline and a clockwise boundary is stored counter-clockwise" {
    // Oracle: the GDSII format: a PATHTYPE 0 outline lies half its width
    // either side of the centreline, flush with its ends, so a 100-wide path
    // from (0,0) to (4000,0) is the box (0,-50)-(4000,50), right side first,
    // counter-clockwise. A boundary written clockwise reads back as the same
    // ring reversed.
    const gpa = testing.allocator;
    var strings: StrTable = .empty;
    defer strings.deinit(gpa);
    var diag: Diagnostic = .{};
    const path_bytes = try pathLibrary(100, &.{ 0, 4000 }, &.{ 0, 0 });
    defer gpa.free(path_bytes);
    var lib = try Library.parse(gpa, path_bytes, &strings, &diag);
    defer lib.deinit(gpa);
    try testing.expectEqualSlices(i64, &.{ 0, 4000, 4000, 0 }, lib.xs.items);
    try testing.expectEqualSlices(i64, &.{ -50, -50, 50, 50 }, lib.ys.items);

    const cw: fixture.Boundary = .{ .layer = 68, .datatype = 20, .xs = &.{ 0, 0, 400, 400 }, .ys = &.{ 0, 400, 400, 0 } };
    const bytes = try fixture.library(gpa, &.{.{ .name = "TOP", .boundaries = &.{cw} }}, 1e-9);
    defer gpa.free(bytes);
    var lib2 = try Library.parse(gpa, bytes, &strings, &diag);
    defer lib2.deinit(gpa);
    try testing.expectEqualSlices(i64, &.{ 400, 400, 0, 0 }, lib2.xs.items);
    try testing.expectEqualSlices(i64, &.{ 0, 400, 400, 0 }, lib2.ys.items);
}

test "composing transforms is applying them in turn" {
    // Oracle: law. For every flip, quarter turn and magnification pair,
    // `compose(p, c).apply(v) == p.apply(c.apply(v))` on a chiral point; a
    // product past i64 is refused, not wrapped.
    for (0..2) |pf| for (0..4) |pq| for (0..2) |cf| for (0..4) |cq| {
        const p: Xform = .{ .mag = 2, .flip = pf == 1, .quadrant = @intCast(pq), .dx = 7, .dy = -3 };
        const c: Xform = .{ .mag = 3, .flip = cf == 1, .quadrant = @intCast(cq), .dx = -5, .dy = 11 };
        const inner = c.apply(13, 2).?;
        try testing.expectEqual(p.apply(inner[0], inner[1]).?, p.compose(c).?.apply(13, 2).?);
    };
    const huge: Xform = .{ .mag = 1 << 40, .flip = false, .quadrant = 0, .dx = 0, .dy = 0 };
    try testing.expectEqual(null, huge.compose(huge));
}
