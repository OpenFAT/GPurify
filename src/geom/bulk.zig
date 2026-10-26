//! Bulk host-to-device movement: every column a kernel reads goes up in one
//! device allocation and one copy, never one transfer per column. In: the
//! columns as bytes, and the sizes of device-only scratch regions (written
//! by kernels, e.g. a solve's `x` and `y`). Out: one Gompute buffer, each
//! region's byte offset in it, and each region's device address for kernel
//! arguments (ARCHITECTURE.md, GPU).
//!
//! Every region starts on a 256-byte boundary, the alignment both drivers
//! give an allocation, so a kernel sees each column as if it were its own.
//!
//! The copy is the cost (measured on an RTX 4060 Laptop, PCIe 4.0 x8: the
//! driver moves 50 MB of pageable memory in 4.3 ms, pinned in 4.2 ms, but
//! packing it into a fresh staging block takes 19 ms of page faults and
//! copying). So a lone column goes up straight from the caller's memory,
//! and a staging block is only written, never cleared first.
//!
//! Contents:
//! - `pub const alignment`
//! - `pub fn upload(comptime Raw: type, raw: *Raw, gpa: Allocator, columns: []const []const u8, scratch: []const usize, offsets: []usize, addresses: []usize) !Raw.Buffer`

const std = @import("std");
const assert = std.debug.assert;
const Allocator = std.mem.Allocator;

/// The start of every region, in bytes.
pub const alignment = 256;

/// Packs `columns` into one staging block, makes one device allocation
/// holding them and the `scratch` regions after them, and copies the block
/// up once. Region `i` is `columns[i]` for `i < columns.len`, then
/// `scratch[i - columns.len]`; `offsets[i]` is its byte offset and
/// `addresses[i]` its device address (pass `&addresses[i]` as the kernel
/// argument). The caller frees the returned buffer.
pub fn upload(
    comptime Raw: type,
    raw: *Raw,
    gpa: Allocator,
    columns: []const []const u8,
    scratch: []const usize,
    offsets: []usize,
    addresses: []usize,
) !Raw.Buffer {
    const regions = columns.len + scratch.len;
    assert(offsets.len == regions and addresses.len == regions);
    var end: usize = 0;
    for (offsets, 0..) |*o, i| {
        o.* = end;
        const bytes = if (i < columns.len) columns[i].len else scratch[i - columns.len];
        end = std.mem.alignForward(usize, end + bytes, alignment);
    }
    const staged = if (scratch.len > 0) offsets[columns.len] else end;

    // A zero-byte allocation is not portable; every buffer is at least one word.
    var buffer = try raw.alloc(@max(end, 8));
    errdefer buffer.free();
    if (columns.len == 1) {
        if (columns[0].len > 0) try buffer.upload(columns[0].ptr, columns[0].len);
    } else if (staged > 0) {
        // Pageable on purpose: pinned moves no faster here and costs 16 ms
        // a 50 MB block to lock.
        const block = try gpa.alloc(u8, staged);
        defer gpa.free(block);
        for (columns, offsets[0..columns.len], 0..) |col, o, i| {
            @memcpy(block[o..][0..col.len], col);
            const next = if (i + 1 < columns.len) offsets[i + 1] else staged;
            @memset(block[o + col.len .. next], 0);
        }
        try buffer.upload(block.ptr, staged);
    }
    const base = address(buffer.handle);
    for (addresses, offsets) |*a, o| a.* = base + o;
    return buffer;
}

// ---- private ----

/// A device handle as an integer: CUDA's is `c_ulonglong`, HIP's `?*anyopaque`.
fn address(handle: anytype) usize {
    return switch (@typeInfo(@TypeOf(handle))) {
        .optional => @intFromPtr(handle),
        else => @intCast(handle),
    };
}

test "regions are aligned, in order, and disjoint" {
    // Oracle: the layout rule, worked by hand: 3 bytes -> [0, 3), next at 256;
    // 300 bytes -> [256, 556), next at 768; scratch 16 -> [768, 784).
    const Fake = struct {
        const Buffer = struct {
            handle: usize,
            bytes: usize,
            fn upload(_: *@This(), _: *const anyopaque, _: usize) !void {}
            fn free(_: *@This()) void {}
        };
        fn alloc(_: *@This(), bytes: usize) !Buffer {
            return .{ .handle = 0x1000, .bytes = bytes };
        }
    };
    var raw: Fake = .{};
    var offsets: [3]usize = undefined;
    var addresses: [3]usize = undefined;
    const a = [_]u8{ 1, 2, 3 };
    const b: [300]u8 = @splat(7);
    const buf = try upload(Fake, &raw, std.testing.allocator, &.{ &a, &b }, &.{16}, &offsets, &addresses);
    try std.testing.expectEqualSlices(usize, &.{ 0, 256, 768 }, &offsets);
    try std.testing.expectEqualSlices(usize, &.{ 0x1000, 0x1100, 0x1300 }, &addresses);
    try std.testing.expectEqual(@as(usize, 1024), buf.bytes);
}
