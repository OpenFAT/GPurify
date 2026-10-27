//! Regressions for two fixes Philis found through its use of the sky130
//! deck, run through the real reader and engine. Ported from
//! tests/supply_and_enclosure_regressions.rs (Rust 11b5578).
//!
//! - sky130 lvtn.10 measures only an lvtn that touches `nwell_novar`, as
//!   the deck's own note (after the foundry PVL) says: an LVT nfet's lvtn on
//!   p-substrate is not measured.
//! - `soft_connection` takes every global layer out of the hard
//!   connectivity, as its docs say: a supply tied to the substrate through
//!   a soft tap is one piece, while two straps joined only through the
//!   substrate are still flagged.

const std = @import("std");
const testing = std.testing;
const Allocator = std.mem.Allocator;
const gpurify = @import("gpurify");
const harness = @import("harness.zig");
const Fixture = harness.Fixture;
const Layout = harness.Layout;

/// A supply's front end: met1 to a soft p-tap through licon, the p-tap to
/// the global substrate through a tie, as sky130's `psub_tie`.
const soft_deck =
    \\grid 1nm
    \\layer psub = gds(64, 0)
    \\layer ptap = gds(65, 44)
    \\layer tie = gds(65, 45)
    \\layer licon = gds(66, 44)
    \\layer met1 = gds(68, 20)
    \\connect conductors [ptap, met1]
    \\connect global psub
    \\connect via tie [ptap, psub]
    \\connect via licon [ptap, met1]
    \\rule soft soft_connection(ptap)
    \\
;

// ---- private ----

/// A met1 strap on a p-tap at height `y`, the tap tied to the substrate.
fn strap(a: Allocator, l: *Layout, y: i64) Allocator.Error!void {
    try l.rect(a, "psub", 0, 0, 10_000, 10_000);
    try l.rect(a, "ptap", 1000, y + 1000, 9000, y + 2000);
    try l.rect(a, "tie", 1000, y + 1000, 9000, y + 2000);
    try l.rect(a, "licon", 1200, y + 1200, 1400, y + 1400);
    try l.rect(a, "met1", 1000, y + 1000, 9000, y + 2000);
}

test "sky130 lvtn.10 skips an lvtn off every n-well" {
    // Oracle: the deck's own note (after the foundry PVL, lvtn.drc.pvl
    // lines 40-44): an lvtn off every `nwell_novar` is not measured, so an
    // LVT nfet's lvtn on p-substrate gives no lvtn.10 finding.
    var arena_state: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    var f: Fixture = .init("lvtn10/off_nwell", &.{"DRC-054"}, gpurify.pdks.sky130, harness.drc);
    try f.layout.rect(a, "lvtn", 0, 0, 2000, 2000);
    try f.claim(a, .clean("lvtn.10"));
    try harness.checkAll(&.{f});
}

test "sky130 lvtn.10 still measures an lvtn in an n-well" {
    // Oracle: construct-from-answer. An lvtn 100 nm inside an n-well edge,
    // under lvtn.10's 380 nm, is still one finding.
    var arena_state: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    var f: Fixture = .init("lvtn10/in_nwell", &.{"DRC-054"}, gpurify.pdks.sky130, harness.drc);
    try f.layout.rect(a, "nwell", 0, 0, 5000, 5000);
    try f.layout.rect(a, "lvtn", 100, 100, 2000, 2000);
    try f.claim(a, .rule("lvtn.10", &.{.any()}));
    try harness.checkAll(&.{f});
}

test "a supply tied to the substrate is not a soft connection" {
    // Oracle: construct-from-answer. One strap tied to the substrate through
    // a soft p-tap is one piece once the soft layers and the global
    // substrate are out (`checkSoftConnection`'s doc comment): clean.
    var arena_state: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    var f: Fixture = .init("soft/one_strap", &.{ "LVS-003", "ERC-G5" }, soft_deck, .{ .erc = true });
    try strap(a, &f.layout, 0);
    try f.claim(a, .clean("soft"));
    try harness.checkAll(&.{f});
}

test "straps joined only by the substrate are flagged" {
    // Oracle: construct-from-answer, the control. Two straps of one supply,
    // joined only through their soft p-taps and the substrate, are two
    // pieces: a real soft connection, one finding measuring 2 against 1.
    var arena_state: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    var f: Fixture = .init("soft/two_straps", &.{ "LVS-003", "ERC-G5" }, soft_deck, .{ .erc = true });
    try strap(a, &f.layout, 0);
    try strap(a, &f.layout, 5000);
    try f.claim(a, .rule("soft", &.{.{ .measured = .count(2), .at = null }}));
    try harness.checkAll(&.{f});
}
