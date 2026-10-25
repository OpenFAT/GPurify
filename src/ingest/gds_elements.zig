//! GDSII elements: the records from an element's opening record through its
//! `ENDEL` → one row appended to a `Library` table. A `BOUNDARY` or `BOX`
//! becomes one counter-clockwise ring with repeated vertices and the closing
//! point dropped; a `PATH` is stroked exactly into its `2n`-point outline; an
//! `SREF`/`AREF` becomes a `Ref` whose array pitch divides exactly; a `TEXT`
//! keeps its layer, type, point and string. Cites: the GDSII Stream Format
//! manual, release 6.0 (`PATHTYPE` 0/2/4 end caps). Ported from
//! crates/ingest/src/layout.rs (`boundary`, `path`, `reference`, `text`,
//! `element_record`, `push_keyhole` and its ring tests).
//!
//! Keyholes: Rust splits a ring that revisits a vertex or folds back along
//! one line (how GDSII writes a hole) into its outer and holes through
//! `geom::boolean::canonical_rings_into` (`push_keyhole`). That sweep is wave
//! 2's (ARCHITECTURE.md), and `push_keyhole` with its ring tests moves with
//! it; until then such a ring is kept whole, which geometry validation
//! refuses as self-intersecting: fail closed.
//!
//! Contents:
//! - `pub const Scratch`, `Scratch.deinit(s: *Scratch, gpa: Allocator) void`
//! - `pub const Reader`, `Reader.boundary(r: Reader, next: usize, start: usize, kind: Tag) Error!usize`,
//!   `Reader.path(r: Reader, next: usize, start: usize) Error!usize`,
//!   `Reader.reference(r: Reader, next: usize, start: usize, array: bool) Error!usize`,
//!   `Reader.text(r: Reader, next: usize, start: usize) Error!usize`

const std = @import("std");
const Allocator = std.mem.Allocator;
const geom = @import("geom");
const StrId = geom.StrId;
const StrTable = geom.StrTable;
const gds = @import("gds.zig");
const Error = gds.Error;
const Diagnostic = gds.Diagnostic;
const Library = gds.Library;
const Xform = gds.Xform;
const rec = @import("gds_records.zig");
const Tag = rec.Tag;

/// Per-element scratch, reused across the stream and freed by `parse`.
pub const Scratch = struct {
    /// The centreline, end caps applied, and one unit direction per segment.
    pts: std.ArrayList([2]i64) = .empty,
    dirs: std.ArrayList([2]i64) = .empty,
    left: std.ArrayList([2]i64) = .empty,
    right: std.ArrayList([2]i64) = .empty,

    pub fn deinit(s: *Scratch, gpa: Allocator) void {
        s.pts.deinit(gpa);
        s.dirs.deinit(gpa);
        s.left.deinit(gpa);
        s.right.deinit(gpa);
    }
};

/// What every element reader writes to and reports through.
pub const Reader = struct {
    gpa: Allocator,
    bytes: []const u8,
    strings: *StrTable,
    diag: *Diagnostic,
    lib: *Library,
    scratch: *Scratch,

    /// Consumes a `BOUNDARY` or `BOX` from `next` through its `ENDEL`;
    /// returns the offset past it. `start` is the opening record's offset.
    pub fn boundary(r: Reader, next: usize, start: usize, kind: Tag) Error!usize {
        const lib = r.lib;
        const first = lib.xs.items.len;
        var layer: ?u16 = null;
        var datatype: ?u16 = null;
        var seen_xy = false;
        var at = next;
        const end = while (true) {
            const record = try rec.record(r.bytes, at, r.diag);
            switch (record.tag) {
                .layer => layer = try rec.word(record.payload, at, r.diag),
                // A BOX's type is the second half of the stream pair.
                .datatype, .boxtype => datatype = try rec.word(record.payload, at, r.diag),
                .xy => {
                    try r.points(record.payload, at);
                    seen_xy = true;
                },
                else => if (try r.elementRecord(record, at)) |done| break done,
            }
            at = record.next;
        };
        dropRepeats(lib, first);
        // Drop the closing point the format repeats.
        const xs = lib.xs.items;
        const ys = lib.ys.items;
        if (xs.len - first >= 2 and xs[first] == xs[xs.len - 1] and ys[first] == ys[ys.len - 1]) {
            _ = lib.xs.pop();
            _ = lib.ys.pop();
        }
        const vert_len = lib.xs.items.len - first;
        if (layer == null or datatype == null or !seen_xy or vert_len < 3) return rec.unsupported(r.diag, kind, start);
        // DEFERRED(wave 2): Rust `push_keyhole` splits a keyhole here.
        // Every BOUNDARY/BOX is an outer ring, stored counter-clockwise
        // whatever the file's winding: KLayout writes hulls clockwise.
        if (ringIsClockwise(lib.xs.items[first..], lib.ys.items[first..])) {
            std.mem.reverse(i64, lib.xs.items[first..]);
            std.mem.reverse(i64, lib.ys.items[first..]);
        }
        try r.pushElem(layer.?, datatype.?, first);
        return end;
    }

    /// Consumes a `PATH`, stroking its `n`-point centreline into a `2n`-point
    /// counter-clockwise ring. Exact or refused: every segment axis-parallel
    /// and non-degenerate, an even positive width, no reversing vertex,
    /// `PATHTYPE` 0, 2 or 4.
    pub fn path(r: Reader, next: usize, start: usize) Error!usize {
        const lib = r.lib;
        const s = r.scratch;
        const first = lib.xs.items.len;
        var layer: ?u16 = null;
        var datatype: ?u16 = null;
        var seen_xy = false;
        var width: i64 = 0;
        var pathtype: u16 = 0;
        var ext: [2]i64 = .{ 0, 0 };
        var at = next;
        const end = while (true) {
            const record = try rec.record(r.bytes, at, r.diag);
            switch (record.tag) {
                .layer => layer = try rec.word(record.payload, at, r.diag),
                .datatype => datatype = try rec.word(record.payload, at, r.diag),
                .width => width = try rec.long(record.payload, at, r.diag),
                .pathtype => pathtype = try rec.word(record.payload, at, r.diag),
                .bgnextn => ext[0] = try rec.long(record.payload, at, r.diag),
                .endextn => ext[1] = try rec.long(record.payload, at, r.diag),
                .xy => {
                    try r.points(record.payload, at);
                    seen_xy = true;
                },
                else => if (try r.elementRecord(record, at)) |done| break done,
            }
            at = record.next;
        };
        // The centreline leaves the coordinate columns; the outline replaces it.
        s.pts.clearRetainingCapacity();
        for (lib.xs.items[first..], lib.ys.items[first..]) |x, y| try s.pts.append(r.gpa, .{ x, y });
        lib.xs.shrinkRetainingCapacity(first);
        lib.ys.shrinkRetainingCapacity(first);
        if (layer == null or datatype == null) return rec.unsupported(r.diag, .path, start);
        const n = s.pts.items.len;
        if (!seen_xy or n < 2) return rec.unsupported(r.diag, .path, start);
        // Zero width has no area, negative is "absolute" (does not compose
        // with magnification), odd puts the outline half a unit off grid.
        if (width <= 0 or @rem(width, 2) != 0) return rec.unsupported(r.diag, .width, start);
        const half = @divExact(width, 2);
        const caps: [2]i64 = switch (pathtype) {
            0 => .{ 0, 0 },
            2 => .{ half, half },
            4 => ext,
            else => return rec.unsupported(r.diag, .pathtype, start),
        };
        // Exactly one delta is zero on an axis-parallel, non-degenerate segment.
        const pts = s.pts.items;
        for (pts[0 .. n - 1], pts[1..]) |a, b| {
            if ((a[0] == b[0]) == (a[1] == b[1])) return error.UnsupportedTransform;
        }
        s.dirs.clearRetainingCapacity();
        for (pts[0 .. n - 1], pts[1..]) |a, b| try s.dirs.append(r.gpa, .{ std.math.sign(b[0] - a[0]), std.math.sign(b[1] - a[1]) });
        const dirs = s.dirs.items;
        // A reversal has no intersection to miter at.
        for (dirs[0 .. dirs.len - 1], dirs[1..]) |a, b| {
            if (a[0] * b[0] + a[1] * b[1] < 0) return error.UnsupportedTransform;
        }
        // End caps extend the first and last vertex along their own segment.
        const front = dirs[0];
        const back = dirs[dirs.len - 1];
        pts[0] = .{ pts[0][0] - caps[0] * front[0], pts[0][1] - caps[0] * front[1] };
        pts[n - 1] = .{ pts[n - 1][0] + caps[1] * back[0], pts[n - 1][1] + caps[1] * back[1] };
        s.left.clearRetainingCapacity();
        s.right.clearRetainingCapacity();
        for (0..n) |i| {
            // `arrive` reaches vertex i, `leave` leaves it; the ends double up.
            const arrive = if (i == 0) front else dirs[i - 1];
            const leave = if (i == n - 1) back else dirs[i];
            try s.left.append(r.gpa, corner(half, 1, pts[i], arrive, leave));
            try s.right.append(r.gpa, corner(half, -1, pts[i], arrive, leave));
        }
        // Right side forward, then left back: counter-clockwise.
        for (s.right.items) |p| try r.pushVertex(p);
        var i = s.left.items.len;
        while (i > 0) {
            i -= 1;
            try r.pushVertex(s.left.items[i]);
        }
        // DEFERRED(wave 2): a path running back over itself strokes a
        // keyhole, which Rust `push_keyhole` splits here.
        try r.pushElem(layer.?, datatype.?, first);
        return end;
    }

    /// Consumes an `SREF` (one point) or `AREF` (three: origin, column end,
    /// row end, so the pitch divides exactly or is refused).
    pub fn reference(r: Reader, next: usize, start: usize, array: bool) Error!usize {
        var name: ?StrId = null;
        var place = Xform.identity;
        var cols: u32 = 1;
        var rows: u32 = 1;
        var pt: [3][2]i64 = @splat(.{ 0, 0 });
        var points_seen: usize = 0;
        var at = next;
        const end = while (true) {
            const record = try rec.record(r.bytes, at, r.diag);
            const payload = record.payload;
            switch (record.tag) {
                .sname => name = try r.strings.intern(r.gpa, rec.ascii(payload)),
                .strans => {
                    const flags = try rec.word(payload, at, r.diag);
                    if (flags & rec.strans_absolute != 0) return error.UnsupportedTransform;
                    place.flip = flags & rec.strans_reflect != 0;
                },
                .mag => {
                    // Non-integral magnification puts vertices off grid.
                    const m = try rec.real(payload, at, r.diag);
                    if (!(m >= 1.0 and m <= 1e6 and m == @trunc(m))) return error.UnsupportedTransform;
                    place.mag = @intFromFloat(m);
                },
                .angle => {
                    const quarters = try rec.real(payload, at, r.diag) / 90.0;
                    if (quarters - @trunc(quarters) != 0.0 or @abs(quarters) > 1e6) return error.UnsupportedTransform;
                    place.quadrant = @intCast(@mod(@as(i64, @intFromFloat(quarters)), 4));
                },
                .colrow => {
                    cols = try rec.word(payload, at, r.diag);
                    rows = try rec.word(if (payload.len >= 2) payload[2..] else &.{}, at, r.diag);
                },
                .xy => {
                    if (payload.len % 8 != 0) return rec.truncated(r.diag, at);
                    points_seen = payload.len / 8;
                    for (0..@min(3, points_seen)) |k| pt[k] = rec.xy(payload[k * 8 ..][0..8]);
                },
                .elflags, .plex => {},
                .endel => break record.next,
                // else: a reference carries only the records above; a property refuses it
                else => return rec.unsupported(r.diag, record.tag, at),
            }
            at = record.next;
        };
        const cell = name orelse return rec.unsupported(r.diag, .sref, start);
        if (points_seen != @as(usize, if (array) 3 else 1)) return rec.unsupported(r.diag, .sref, start);
        place.dx = pt[0][0];
        place.dy = pt[0][1];
        var col_step: [2]i64 = .{ 0, 0 };
        var row_step: [2]i64 = .{ 0, 0 };
        if (array) {
            if (cols == 0 or rows == 0) return error.UnsupportedTransform;
            col_step = step(pt[0], pt[1], cols) orelse return error.UnsupportedTransform;
            row_step = step(pt[0], pt[2], rows) orelse return error.UnsupportedTransform;
        }
        try r.lib.refs.append(r.gpa, .{
            .cell = cell,
            .child = std.math.maxInt(u32),
            .place = place,
            .col_step = col_step,
            .row_step = row_step,
            .cols = cols,
            .rows = rows,
        });
        return end;
    }

    /// Consumes a `TEXT`. `LAYER`, `TEXTTYPE`, one `XY` point and `STRING`
    /// are required and kept; the glyph records leave the point where it is.
    pub fn text(r: Reader, next: usize, start: usize) Error!usize {
        var layer: ?u16 = null;
        var texttype: ?u16 = null;
        var point: ?[2]i64 = null;
        var string: ?StrId = null;
        var at = next;
        const end = while (true) {
            const record = try rec.record(r.bytes, at, r.diag);
            const payload = record.payload;
            switch (record.tag) {
                .layer => layer = try rec.word(payload, at, r.diag),
                .texttype => texttype = try rec.word(payload, at, r.diag),
                .xy => {
                    if (payload.len % 8 != 0) return rec.truncated(r.diag, at);
                    if (payload.len != 8) return rec.unsupported(r.diag, .text, start);
                    point = rec.xy(payload[0..8]);
                },
                .string => string = try r.strings.intern(r.gpa, rec.ascii(payload)),
                .presentation, .pathtype, .width, .strans, .mag, .angle => {},
                else => if (try r.elementRecord(record, at)) |done| break done,
            }
            at = record.next;
        };
        if (layer == null or texttype == null or point == null or string == null) return rec.unsupported(r.diag, .text, start);
        try r.lib.texts.append(r.gpa, .{ .layer = layer.?, .texttype = texttype.?, .x = point.?[0], .y = point.?[1], .string = string.? });
        return end;
    }

    // ---- private ----

    /// The records any element may carry; the offset past an `ENDEL`, or
    /// null to read on. A reference does not route through this, so a
    /// property on an `SREF` stays a refusal.
    fn elementRecord(r: Reader, record: rec.Record, at: usize) Error!?usize {
        switch (record.tag) {
            .propattr => _ = try rec.word(record.payload, at, r.diag),
            // Not stored; interned only because interning order is report order.
            .propvalue => _ = try r.strings.intern(r.gpa, rec.ascii(record.payload)),
            .elflags, .plex => {},
            .endel => return record.next,
            // else: these are the records every element shares; the rest refuse
            else => return rec.unsupported(r.diag, record.tag, at),
        }
        return null;
    }

    /// Appends an `XY` payload to the coordinate columns.
    fn points(r: Reader, payload: []const u8, at: usize) Error!void {
        if (payload.len % 8 != 0) return rec.truncated(r.diag, at);
        var k: usize = 0;
        while (k < payload.len) : (k += 8) try r.pushVertex(rec.xy(payload[k..][0..8]));
    }

    fn pushVertex(r: Reader, p: [2]i64) Allocator.Error!void {
        try r.lib.xs.append(r.gpa, p[0]);
        try r.lib.ys.append(r.gpa, p[1]);
    }

    fn pushElem(r: Reader, layer: u16, datatype: u16, first: usize) Allocator.Error!void {
        try r.lib.elems.append(r.gpa, .{
            .layer = layer,
            .datatype = datatype,
            .vert_start = @intCast(first),
            .vert_len = @intCast(r.lib.xs.items.len - first),
        });
    }
};

// ---- private ----

/// A vertex repeated at once is an edge of length zero: it carries no
/// geometry, writers emit it (gf180mcu's unit structures do), and validation
/// would refuse the ring as degenerate. A ring that would keep fewer than
/// three vertices, its closing point not counted, is left whole for the
/// validator to name. Counting without the closing point keeps this a fixed
/// point: written back with its closing point, the ring reads back unchanged.
fn dropRepeats(lib: *Library, first: usize) void {
    const xs = lib.xs.items;
    const ys = lib.ys.items;
    const past = xs.len;
    var distinct: usize = 0;
    for (first..past) |i| distinct += @intFromBool(!(i > first and xs[i] == xs[i - 1] and ys[i] == ys[i - 1]));
    const closed = distinct >= 2 and xs[first] == xs[past - 1] and ys[first] == ys[past - 1];
    if (distinct - @intFromBool(closed) < 3) return;
    var kept = first;
    for (first..past) |i| {
        if (i > first and xs[i] == xs[i - 1] and ys[i] == ys[i - 1]) continue;
        xs[kept] = xs[i];
        ys[kept] = ys[i];
        kept += 1;
    }
    lib.xs.shrinkRetainingCapacity(kept);
    lib.ys.shrinkRetainingCapacity(kept);
}

/// Whether a ring runs clockwise. `i128`: raw file coordinates, not yet bounded.
fn ringIsClockwise(xs: []const i64, ys: []const i64) bool {
    var area2: i128 = 0;
    for (0..xs.len) |i| {
        const j = if (i + 1 == xs.len) 0 else i + 1;
        area2 += @as(i128, xs[i]) * ys[j] - @as(i128, xs[j]) * ys[i];
    }
    return area2 < 0;
}

/// Exact miter: with `d` the dot of the two unit directions, the offset
/// corner is `p + half·(n_in·(1 − d) + n_out)`; `side` is +1 left, −1 right.
fn corner(half: i64, side: i64, p: [2]i64, pv: [2]i64, cv: [2]i64) [2]i64 {
    const dot = pv[0] * cv[0] + pv[1] * cv[1];
    const in = [2]i64{ -pv[1] * side, pv[0] * side };
    const out = [2]i64{ -cv[1] * side, cv[0] * side };
    return .{ p[0] + half * (in[0] * (1 - dot) + out[0]), p[1] + half * (in[1] * (1 - dot) + out[1]) };
}

/// The pitch from `origin` to `far` over `n` steps, when it divides exactly.
fn step(origin: [2]i64, far: [2]i64, n: u32) ?[2]i64 {
    const d = [2]i64{ far[0] - origin[0], far[1] - origin[1] };
    if (@rem(d[0], n) != 0 or @rem(d[1], n) != 0) return null;
    return .{ @divTrunc(d[0], n), @divTrunc(d[1], n) };
}
