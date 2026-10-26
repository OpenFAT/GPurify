//! The latch-up kinds that measure geometry on esd_geometry.zig's hand-drawn
//! cell: `tie_area`, `guard_ring` and `latchup_victim`. Ported from
//! crates/check/tests/erc/esd_geometry.rs (its last three tests). Unwired
//! until the latch-up family lands (its rows refuse today); add it to
//! tests/check.zig then.

const std = @import("std");
const testing = std.testing;
const geom = @import("geom");
const check = @import("check");
const testgen = @import("testgen");
const common = @import("common.zig");
const cell_ = @import("esd_geometry.zig");
const Cell = cell_.Cell;
const LayerId = geom.LayerId;
const PolyId = geom.PolyId;
const Measurement = check.report.Measurement;
const erc = check.erc;
const tables = erc.latchup_tables;
const deinitTable = erc.rule_set.deinitTable;
const LayoutBuilder = testgen.shapes.LayoutBuilder;
const gpa = common.gpa;

// ---- private ----

fn l(i: u16) LayerId {
    return @fromBackingInt(i);
}

/// Four bars around the box `(x0, y0, x1, y1)`, `band` wide, on the ring.
fn ringRound(lb: *LayoutBuilder, box: [4]i64, band: i64) !void {
    const x0, const y0, const x1, const y1 = box;
    _ = try lb.rect(gpa, cell_.ring, x0 - band, y0 - band, x1 + band, y0);
    _ = try lb.rect(gpa, cell_.ring, x0 - band, y1, x1 + band, y1 + band);
    _ = try lb.rect(gpa, cell_.ring, x0 - band, y0, x0, y1);
    _ = try lb.rect(gpa, cell_.ring, x1, y0, x1 + band, y1);
}

test "a well with enough tie is clean" {
    // Oracle: closed form: a 10 µm well holding a 2 µm² gate and three
    // 200 nm contacts: 0.12 µm² over 2 µm² is 6 %, above a 3 % floor, so
    // the one well examined is clean.
    var lb = LayoutBuilder.init(cell_.layers);
    defer lb.deinit(gpa);
    _ = try lb.rect(gpa, cell_.well, 0, 0, 10_000, 10_000);
    _ = try lb.rect(gpa, cell_.gate, 1000, 1000, 2000, 3000);
    for ([_]i64{ 5000, 6000, 7000 }) |x| _ = try lb.rect(gpa, cell_.cont, x, 5000, x + 200, 5200);
    var cell: Cell = .{};
    defer cell.deinit();
    try cell.init(&lb);
    var t: tables.TieAreaTable = .{};
    defer deinitTable(gpa, &t);
    try t.head.push(gpa, common.rule(3), .@"error");
    try t.region.append(gpa, l(cell_.well));
    try t.contact.append(gpa, l(cell_.cont));
    try t.channel.append(gpa, l(cell_.gate));
    try t.min_ratio.append(gpa, 0.03);
    var scratch: erc.scratch.Scratch = .{};
    defer scratch.deinit(gpa);
    var sink: common.Sink = .{};
    defer sink.deinit();
    try erc.latchup.checkTieArea(sink.record(), cell.design(), &t, &scratch);
    try testing.expectEqual(@as(u32, 0), sink.out.len());
    try testing.expectEqual(@as(u64, 1), (try common.runOf(sink.runs.items, common.rule(3))).examined);
}

test "a target in a hole's box but not its hole is not surrounded" {
    // Oracle: by construction: a ring whose hole is an L (a block of ring
    // fills one corner of a square hole), with a target inside the block:
    // in the hole's box but not in the hole, so surrounded by no hole; a
    // second target sits in a square ring and is; both are examined.
    var lb = LayoutBuilder.init(cell_.layers);
    defer lb.deinit(gpa);
    try ringRound(&lb, .{ 1000, 1000, 9000, 9000 }, 1000);
    _ = try lb.rect(gpa, cell_.ring, 5000, 5000, 9000, 9000);
    const blocked = try lb.rect(gpa, cell_.diff, 6000, 6000, 8000, 8000);
    try ringRound(&lb, .{ 20_000, 20_000, 24_000, 24_000 }, 1000);
    _ = try lb.rect(gpa, cell_.diff, 21_000, 21_000, 23_000, 23_000);
    var cell: Cell = .{};
    defer cell.deinit();
    try cell.init(&lb);
    var t: tables.GuardRingTable = .{};
    defer deinitTable(gpa, &t);
    try t.head.push(gpa, common.rule(4), .@"error");
    try t.target.append(gpa, l(cell_.diff));
    try t.ring.append(gpa, l(cell_.ring));
    try t.max_space.append(gpa, null);
    try t.min_width.append(gpa, null);
    try t.pad.append(gpa, null);
    try t.near.append(gpa, null);
    try t.clear.append(gpa, null);
    var scratch: erc.scratch.Scratch = .{};
    defer scratch.deinit(gpa);
    var sink: common.Sink = .{};
    defer sink.deinit();
    try erc.latchup.checkGuardRing(sink.record(), cell.design(), &t, &scratch);
    try testing.expectEqual(@as(u32, 1), sink.out.len());
    try testing.expect(sink.out.get(0).measured.eql(Measurement.count(0)));
    try testing.expectEqualSlices(PolyId, &.{cell.ids.of(blocked)}, sink.out.shape_a.items);
    try testing.expectEqual(@as(u64, 2), (try common.runOf(sink.runs.items, common.rule(4))).examined);
}

test "a victim of a pad junction is held to its tap distance" {
    // Oracle: by construction: a diffusion joined to a pad is an aggressor;
    // a 10 µm region 2 µm from it, tapped only at its far end, is its
    // victim; the region's left edge is 10 µm from its tap, above the 2 µm
    // a victim may be.
    var lb = LayoutBuilder.init(cell_.layers);
    defer lb.deinit(gpa);
    _ = try lb.rect(gpa, cell_.diff, 0, 0, 1000, 1000);
    _ = try lb.rect(gpa, cell_.pad_layer, 0, 0, 1000, 1000);
    _ = try lb.rect(gpa, cell_.dcut, 400, 400, 600, 600);
    _ = try lb.rect(gpa, cell_.gate, 3000, 0, 13_000, 1000);
    _ = try lb.rect(gpa, cell_.cont, 13_000, 0, 13_500, 1000);
    var cell: Cell = .{};
    defer cell.deinit();
    try cell.init(&lb);
    var t: tables.LatchupVictimTable = .{};
    defer deinitTable(gpa, &t);
    try t.head.push(gpa, common.rule(5), .@"error");
    try t.aggressor.append(gpa, l(cell_.diff));
    try t.region.append(gpa, l(cell_.gate));
    try t.tap.append(gpa, l(cell_.cont));
    try t.within.append(gpa, 15_000);
    try t.max_distance.append(gpa, 2000);
    try t.pad.append(gpa, l(cell_.pad_layer));
    try t.bias.append(gpa, null);
    const intent: erc.facts.IntentMap = .{};
    const voltage: erc.voltage.NetVoltage = .{};
    var scratch: erc.scratch.Scratch = .{};
    defer scratch.deinit(gpa);
    var sink: common.Sink = .{};
    defer sink.deinit();
    try erc.latchup.checkLatchupVictim(sink.record(), cell.design(), &intent, &voltage, &t, &scratch);
    try testing.expectEqual(@as(u32, 1), sink.out.len());
    try testing.expect(sink.out.get(0).measured.eql(Measurement.length(10_000)));
}
