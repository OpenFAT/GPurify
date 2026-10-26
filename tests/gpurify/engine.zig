//! The engine's load and extract stages, stage statuses and the pass
//! criterion. Ported from tests/engine/main.rs.

const std = @import("std");
const testing = std.testing;
const paths = @import("paths");
const gpurify = @import("gpurify");
const gpa = testing.allocator;

const fixtures = "tests/fixtures";

test "a load reports the input at fault and reaches no stage" {
    // Oracle: `load`'s documented errors, which name the stage for each
    // input, and construct-from-answer: each case pairs one missing file with
    // a fixture pair the engine loads, so only that input can be at fault.
    var arena: std.heap.ArenaAllocator = .init(gpa);
    defer arena.deinit();
    var root = try std.Io.Dir.cwd().openDir(testing.io, paths.root, .{});
    defer root.close(testing.io);
    const layout = fixtures ++ "/pex/PEX_COUPLING_C.gds";
    const deck = fixtures ++ "/params.deck";
    const missing = "/nonexistent/missing";
    var diag: gpurify.LoadDiagnostic = .{};

    try testing.expectError(error.Unreadable, gpurify.load(gpa, arena.allocator(), testing.io, root, .{ .layout = layout, .deck = missing }, &.{}, &diag));
    try testing.expectEqual(.deck, diag.stage);
    try testing.expectError(error.Io, gpurify.load(gpa, arena.allocator(), testing.io, root, .{ .layout = missing, .deck = deck }, &.{}, &diag));
    try testing.expectEqual(.layout, diag.stage);

    const loaded = try gpurify.load(gpa, arena.allocator(), testing.io, root, .{ .layout = layout, .deck = deck }, &.{}, &diag);
    var ediag: gpurify.ExtractDiagnostic = .none;
    const extracted = try gpurify.extract(arena.allocator(), &loaded, &ediag);
    try testing.expect(extracted.nets.netCount() > 0);
    try testing.expect(loaded.strings.get("lvs.net_seed_conflict") != null);
    try testing.expect(loaded.strings.get("def.cell_edge_spacing") != null);
}
