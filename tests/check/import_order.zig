//! The one-direction rule inside `check`. Rust's check crate has cycles
//! (deck↔drc↔erc, topology↔drc, lvs→erc); Zig allows them inside one module,
//! and this forbids them: a file imports only files at or above its own level
//! in report → rects → proximity → topology/ → drc/ → erc/ → lvs/ → deck/, and
//! no leaf imports root.zig. Greps every file under src/check.

const std = @import("std");
const testing = std.testing;
const paths = @import("paths");

const gpa = testing.allocator;

/// Levels in the documented order; a file matching none is unplaced.
const levels = [_][]const u8{ "report", "rects", "proximity", "topology/", "drc/", "erc/", "lvs/", "deck/" };

// ---- private ----

/// The level of a path relative to src/check, or null for root.zig or an
/// unplaced file. A level without `/` is a file prefix (`proximity` takes
/// proximity_distance.zig); with one, a folder.
fn levelOf(rel: []const u8) ?usize {
    for (levels, 0..) |l, i| {
        if (std.mem.endsWith(u8, l, "/")) {
            if (std.mem.startsWith(u8, rel, l)) return i;
        } else if (std.mem.indexOfScalar(u8, rel, '/') == null and std.mem.startsWith(u8, rel, l) and std.mem.endsWith(u8, rel, ".zig")) return i;
    }
    return null;
}

/// The first relative `.zig` import of `text` (a file at `rel`) that goes
/// against the order, or imports root.zig, resolved to its path; null when
/// every import points up or across. Writes into `buf`.
fn backEdge(rel: []const u8, text: []const u8, buf: []u8) ?[]const u8 {
    const from = levelOf(rel) orelse return rel;
    const dir = std.fs.path.dirname(rel) orelse "";
    var rest = text;
    while (std.mem.indexOf(u8, rest, "@import(\"")) |at| {
        rest = rest[at + 9 ..];
        const end = std.mem.indexOfScalar(u8, rest, '"') orelse break;
        const target = rest[0..end];
        if (!std.mem.endsWith(u8, target, ".zig")) continue;
        var fba = std.heap.FixedBufferAllocator.init(buf);
        const joined = std.fs.path.resolvePosix(fba.allocator(), &.{ "/", dir, target }) catch return target;
        const resolved = joined[1..];
        if (std.mem.eql(u8, resolved, "root.zig")) return resolved;
        const to = levelOf(resolved) orelse return resolved;
        if (to > from) return resolved;
    }
    return null;
}

test "no file under src/check imports against the documented order" {
    // Oracle: law, the order the header states; every relative import under
    // src/check resolved and placed on it.
    const root = try std.fmt.allocPrint(gpa, "{s}/src/check", .{paths.root});
    defer gpa.free(root);
    var dir = try std.Io.Dir.cwd().openDir(testing.io, root, .{ .iterate = true });
    defer dir.close(testing.io);
    var walker = try dir.walk(gpa);
    defer walker.deinit();
    var files: usize = 0;
    var buf: [512]u8 = undefined;
    while (try walker.next(testing.io)) |entry| {
        if (entry.kind != .file or !std.mem.endsWith(u8, entry.path, ".zig")) continue;
        if (std.mem.eql(u8, entry.path, "root.zig")) continue;
        files += 1;
        const text = try entry.dir.readFileAlloc(testing.io, entry.basename, gpa, .unlimited);
        defer gpa.free(text);
        if (backEdge(entry.path, text, &buf)) |bad| {
            std.debug.print("{s} imports {s}, against the order\n", .{ entry.path, bad });
            return error.BackEdge;
        }
    }
    try testing.expect(files >= 10);
}

test "the grep sees a back edge, a root import and an unplaced file" {
    // Oracle: construct-from-answer. A report importing rects, a topology
    // file importing drc, and any leaf importing root.zig are back edges; a
    // proximity file importing rects or topology importing ../rects.zig is
    // not; a file at no level is reported as itself.
    var buf: [512]u8 = undefined;
    try testing.expectEqualStrings("rects.zig", backEdge("report.zig", "const r = @import(\"rects.zig\");", &buf).?);
    try testing.expectEqualStrings("drc/spacing.zig", backEdge("topology/net.zig", "@import(\"../drc/spacing.zig\")", &buf).?);
    try testing.expectEqualStrings("root.zig", backEdge("rects.zig", "@import(\"root.zig\")", &buf).?);
    try testing.expectEqual(null, backEdge("proximity_inside.zig", "@import(\"rects.zig\") @import(\"std\")", &buf));
    try testing.expectEqual(null, backEdge("topology/device.zig", "@import(\"../rects.zig\") @import(\"net.zig\")", &buf));
    try testing.expectEqualStrings("utils.zig", backEdge("utils.zig", "", &buf).?);
}
