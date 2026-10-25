//! String interning: names → dense `StrId`s in arrival order, so a caller
//! that interns in a fixed order gets the same ids on every machine. Nothing
//! iterates the hash map; it only answers "seen before?".
//!
//! Contents:
//! - `pub const StrId = enum(u32)`
//! - `pub const StrTable = struct`, `StrTable.empty`,
//!   `StrTable.deinit(t: *StrTable, gpa: Allocator) void`,
//!   `StrTable.intern(t: *StrTable, gpa: Allocator, name: []const u8) Allocator.Error!StrId`,
//!   `StrTable.get(t: *const StrTable, name: []const u8) ?StrId`,
//!   `StrTable.resolve(t: *const StrTable, id: StrId) []const u8`,
//!   `StrTable.count(t: *const StrTable) u32`
//! - private `IdContext`, `NameAdapter`: their `hash` and `eql` are `pub`
//!   only because `std.HashMapUnmanaged` looks them up

const std = @import("std");
const Allocator = std.mem.Allocator;
const assert = std.debug.assert;

/// An interned string. Ids from different tables are not comparable.
pub const StrId = enum(u32) { _ };

/// The one string table of a run: cell, net, layer, model and rule names.
/// Every name's bytes sit back to back in `bytes`; name `i` ends at `ends[i]`
/// and starts where name `i - 1` ended. `ids` holds every id once, hashed by
/// its name.
pub const StrTable = struct {
    bytes: std.ArrayList(u8) = .empty,
    ends: std.ArrayList(u32) = .empty,
    ids: std.HashMapUnmanaged(StrId, void, IdContext, std.hash_map.default_max_load_percentage) = .empty,

    pub const empty: StrTable = .{};

    pub fn deinit(t: *StrTable, gpa: Allocator) void {
        t.bytes.deinit(gpa);
        t.ends.deinit(gpa);
        t.ids.deinit(gpa);
    }

    /// Returns `name`'s id, interning it as the next integer if it is new.
    /// On error the table is unchanged.
    pub fn intern(t: *StrTable, gpa: Allocator, name: []const u8) Allocator.Error!StrId {
        assert(t.bytes.items.len + name.len <= std.math.maxInt(u32));
        const slot = try t.ids.getOrPutContextAdapted(gpa, name, NameAdapter{ .table = t }, .{ .table = t });
        if (slot.found_existing) return slot.key_ptr.*;
        errdefer t.ids.removeByPtr(slot.key_ptr);
        try t.bytes.ensureUnusedCapacity(gpa, name.len);
        try t.ends.ensureUnusedCapacity(gpa, 1);
        const id: StrId = @fromBackingInt(@intCast(t.ends.items.len));
        t.bytes.appendSliceAssumeCapacity(name);
        t.ends.appendAssumeCapacity(@intCast(t.bytes.items.len));
        slot.key_ptr.* = id;
        return id;
    }

    /// Looks `name` up without interning it.
    pub fn get(t: *const StrTable, name: []const u8) ?StrId {
        return t.ids.getKeyAdapted(name, NameAdapter{ .table = t });
    }

    /// The name `id` was interned from. Asserts `id` came from this table.
    pub fn resolve(t: *const StrTable, id: StrId) []const u8 {
        const i = @backingInt(id);
        assert(i < t.ends.items.len);
        const start = if (i == 0) 0 else t.ends.items[i - 1];
        return t.bytes.items[start..t.ends.items[i]];
    }

    /// How many distinct names are interned; ids run `0..count`.
    pub fn count(t: *const StrTable) u32 {
        return @intCast(t.ends.items.len);
    }
};

const IdContext = struct {
    table: *const StrTable,

    pub fn hash(ctx: IdContext, id: StrId) u64 {
        return std.hash_map.hashString(ctx.table.resolve(id));
    }

    pub fn eql(_: IdContext, a: StrId, b: StrId) bool {
        return a == b;
    }
};

const NameAdapter = struct {
    table: *const StrTable,

    pub fn hash(_: NameAdapter, name: []const u8) u64 {
        return std.hash_map.hashString(name);
    }

    pub fn eql(ctx: NameAdapter, name: []const u8, id: StrId) bool {
        return std.mem.eql(u8, name, ctx.table.resolve(id));
    }
};

// ---- private ----

fn internTwice(gpa: Allocator) !void {
    var t: StrTable = .empty;
    defer t.deinit(gpa);
    const a = try t.intern(gpa, "VDD");
    const b = try t.intern(gpa, "VSS");
    try std.testing.expectEqual(a, try t.intern(gpa, "VDD"));
    try std.testing.expectEqualStrings("VSS", t.resolve(b));
    try std.testing.expectEqual(@as(u32, 2), t.count());
}

test "intern leaves the table unchanged on allocation failure" {
    // Oracle: law. A failed `intern` is a no-op: every allocation point,
    // driven by checkAllAllocationFailures, leaves no leak and no half row.
    try std.testing.checkAllAllocationFailures(std.testing.allocator, internTwice, .{});
}
