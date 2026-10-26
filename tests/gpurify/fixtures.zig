//! The per-case GDSII fixtures, split out of one source library, and the
//! corpus's case list. Ported from tests/common/gen_fixtures.rs (`ensure`,
//! `case_gds`, `Source`) and the case reading of tests/golden.rs.
//!
//! In: tests/fixtures/_source/conformance.gds and manifest.json (only
//! `gds_file` and each case's `cell` are read: the deleted tree's answers
//! are no oracle). Out: tests/fixtures/<domain>/<case id>.gds, one library
//! per case holding that cell and everything it places. Rule: `HEADER` and
//! `BGNLIB` copied, a `LIBNAME` of `GPUVERIFY_<id>` NUL-padded only when
//! odd, `UNITS` copied; each cell's `BGNSTR..ENDSTR` copied children first,
//! dropping a `STRANS` whose flag word is zero; `ENDLIB`. A file that holds
//! other bytes is rewritten.
//!
//! Contents:
//! - `pub fn ensure(gpa: Allocator, root: std.Io.Dir) !usize`
//! - `pub const Case = struct { domain, id }`, `pub fn cases(arena: Allocator, root: std.Io.Dir, file: []const u8) ![]const Case`

const std = @import("std");
const Allocator = std.mem.Allocator;
const io = std.testing.io;

pub const Case = struct { domain: []const u8, id: []const u8 };

const case_count = 167;

const Span = [2]usize;

/// The source library: header records and each cell's block and children.
const Source = struct {
    bytes: []const u8,
    header: Span,
    bgnlib: Span,
    units: Span,
    block: std.StringHashMapUnmanaged(Span) = .empty,
    children: std.StringHashMapUnmanaged(std.ArrayList([]const u8)) = .empty,

    fn index(arena: Allocator, bytes: []const u8) !Source {
        var s: Source = .{ .bytes = bytes, .header = undefined, .bgnlib = undefined, .units = undefined };
        var at: usize = 0;
        var open: ?usize = null;
        var cell: ?[]const u8 = null;
        while (at + 4 <= bytes.len) {
            const len = std.mem.readInt(u16, bytes[at..][0..2], .big);
            std.debug.assert(len >= 4 and at + len <= bytes.len);
            const span: Span = .{ at, at + len };
            switch (bytes[at + 2]) {
                0x00 => s.header = span,
                0x01 => s.bgnlib = span,
                0x03 => s.units = span,
                0x05 => {
                    open = at;
                    cell = null;
                },
                0x06 => if (open != null and cell == null) {
                    cell = nameOf(bytes, span);
                },
                0x12 => {
                    const got = try s.children.getOrPut(arena, cell.?);
                    if (!got.found_existing) got.value_ptr.* = .empty;
                    try got.value_ptr.append(arena, nameOf(bytes, span));
                },
                0x07 => {
                    try s.block.put(arena, cell.?, .{ open.?, span[1] });
                    open = null;
                    cell = null;
                },
                else => {},
            }
            at += len;
        }
        std.debug.assert(at == bytes.len);
        return s;
    }

    /// `cell` and everything it places, children first.
    fn closureInto(s: *const Source, arena: Allocator, cell: []const u8, order: *std.ArrayList([]const u8)) !void {
        for (order.items) |c| if (std.mem.eql(u8, c, cell)) return;
        // Marked seen by its place in `order` once visited; a cycle cannot
        // occur in the corpus.
        if (s.children.get(cell)) |kids| for (kids.items) |kid| try s.closureInto(arena, kid, order);
        for (order.items) |c| if (std.mem.eql(u8, c, cell)) return;
        try order.append(arena, cell);
    }
};

/// The tracked fixtures, each equal to its reconstruction or rewritten;
/// how many were rewritten.
pub fn ensure(gpa: Allocator, root: std.Io.Dir) !usize {
    var arena_state: std.heap.ArenaAllocator = .init(gpa);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const manifest = try std.json.parseFromSliceLeaky(std.json.Value, arena, try root.readFileAlloc(io, "tests/fixtures/manifest.json", arena, .unlimited), .{});
    const gds_file = manifest.object.get("gds_file").?.string;
    const bytes = try root.readFileAlloc(io, try std.fmt.allocPrint(arena, "tests/fixtures/{s}", .{gds_file}), arena, .unlimited);
    const source = try Source.index(arena, bytes);
    var written: usize = 0;
    var rewritten: usize = 0;
    for ([_][]const u8{ "drc", "erc", "lvs", "pex" }) |domain| {
        for (manifest.object.get(domain).?.object.get("cases").?.array.items) |case| {
            const id = case.object.get("id").?.string;
            const out = try caseGds(arena, &source, id, case.object.get("cell").?.string);
            const path = try std.fmt.allocPrint(arena, "tests/fixtures/{s}/{s}.gds", .{ domain, id });
            const held = root.readFileAlloc(io, path, arena, .unlimited) catch "";
            if (!std.mem.eql(u8, held, out)) {
                try root.writeFile(io, .{ .sub_path = path, .data = out });
                rewritten += 1;
            }
            written += 1;
        }
    }
    try std.testing.expectEqual(case_count, written);
    return rewritten;
}

/// Every case id of the corpus file `file` (under tests/fixtures), by
/// domain: drc, erc, lvs, pex.
pub fn cases(arena: Allocator, root: std.Io.Dir, file: []const u8) ![]const Case {
    const text = try root.readFileAlloc(io, try std.fmt.allocPrint(arena, "tests/fixtures/{s}", .{file}), arena, .unlimited);
    const json = try std.json.parseFromSliceLeaky(std.json.Value, arena, text, .{});
    var out: std.ArrayList(Case) = .empty;
    for ([_][]const u8{ "drc", "erc", "lvs", "pex" }) |domain| {
        for (json.object.get(domain).?.object.get("cases").?.array.items) |case| try out.append(arena, .{ .domain = domain, .id = case.object.get("id").?.string });
    }
    return out.items;
}

// ---- private ----

fn nameOf(bytes: []const u8, span: Span) []const u8 {
    const payload = bytes[span[0] + 4 .. span[1]];
    return if (payload.len > 0 and payload[payload.len - 1] == 0) payload[0 .. payload.len - 1] else payload;
}

fn caseGds(arena: Allocator, s: *const Source, id: []const u8, cell: []const u8) ![]const u8 {
    var out: std.ArrayList(u8) = .empty;
    try out.appendSlice(arena, s.bytes[s.header[0]..s.header[1]]);
    try out.appendSlice(arena, s.bytes[s.bgnlib[0]..s.bgnlib[1]]);
    const name = try std.fmt.allocPrint(arena, "GPUVERIFY_{s}", .{id});
    const padded = name.len + name.len % 2;
    var head: [4]u8 = undefined;
    std.mem.writeInt(u16, head[0..2], @intCast(4 + padded), .big);
    head[2] = 0x02;
    head[3] = 0x06;
    try out.appendSlice(arena, &head);
    try out.appendSlice(arena, name);
    if (padded != name.len) try out.append(arena, 0);
    try out.appendSlice(arena, s.bytes[s.units[0]..s.units[1]]);
    var order: std.ArrayList([]const u8) = .empty;
    try s.closureInto(arena, cell, &order);
    for (order.items) |c| {
        const span = s.block.get(c).?;
        const block = s.bytes[span[0]..span[1]];
        var at: usize = 0;
        while (at < block.len) {
            const len = std.mem.readInt(u16, block[at..][0..2], .big);
            const zero_strans = block[at + 2] == 0x1a and block[at + 4] == 0 and block[at + 5] == 0;
            if (!zero_strans) try out.appendSlice(arena, block[at .. at + len]);
            at += len;
        }
    }
    try out.appendSlice(arena, &.{ 0x00, 0x04, 0x04, 0x00 });
    return out.items;
}

test "every tracked fixture is its reconstruction from the source library" {
    // Oracle: the reconstruction rule of the module doc, verified by the Rust
    // generator byte-identical against the files tracked before it existed.
    var root = try std.Io.Dir.cwd().openDir(io, @import("paths").root, .{});
    defer root.close(io);
    try std.testing.expectEqual(0, try ensure(std.testing.allocator, root));
}
