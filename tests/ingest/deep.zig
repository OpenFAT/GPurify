//! Structural equality for the suites: two values of one type → whether
//! they hold the same data, an `ArrayList` compared by its items (never its
//! capacity), a slice by its elements, a float exactly. What Rust's derived
//! `PartialEq` gave the deck and netlist tests.

const std = @import("std");

/// Whether `a` and `b` hold the same data.
pub fn same(a: anytype, b: @TypeOf(a)) bool {
    const T = @TypeOf(a);
    switch (@typeInfo(T)) {
        .@"struct" => |s| {
            if (@hasField(T, "items") and @hasField(T, "capacity")) return same(a.items, b.items);
            inline for (s.field_names) |name| if (!same(@field(a, name), @field(b, name))) return false;
            return true;
        },
        .pointer => |ptr| switch (ptr.size) {
            .slice => {
                if (a.len != b.len) return false;
                for (a, b) |x, y| if (!same(x, y)) return false;
                return true;
            },
            .one => return same(a.*, b.*),
            else => @compileError("no deep equality for " ++ @typeName(T)),
        },
        .optional => {
            if (a == null or b == null) return a == null and b == null;
            return same(a.?, b.?);
        },
        .@"union" => {
            if (std.meta.activeTag(a) != std.meta.activeTag(b)) return false;
            return switch (a) {
                inline else => |x, tag| same(x, @field(b, @tagName(tag))),
            };
        },
        .array => {
            for (a, b) |x, y| if (!same(x, y)) return false;
            return true;
        },
        else => return a == b,
    }
}
