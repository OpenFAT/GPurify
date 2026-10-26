//! A parsed deck's ERC rows → a `RuleSet`: each row typed by its kind's
//! builder (`build_*.zig`), held to `validate.zig` as it is filed, and
//! slotted in deck order; then the deck views the stage kinds read (the
//! connectivity, the layer heights, the MOS gate layers). In: the `Deck`
//! and the string table it was interned into. Out: a `RuleSet` the caller
//! owns, or the first problem as a named error with its row in the
//! `Diagnostic`. Ported from crates/check/src/erc/ruleset.rs
//! (`RuleSet::from_deck`).
//!
//! Contents:
//! - `pub fn fromDeck(gpa: Allocator, d: *const Deck, strings: *const StrTable, diag: *Diagnostic) Error!RuleSet`
//! - `pub const Ctx = struct { gpa, row, rs, deck }`
//! - `pub fn pushCsr(gpa: Allocator, start: *std.ArrayList(u32), list: anytype, items: anytype) Allocator.Error!void`

const std = @import("std");
const Allocator = std.mem.Allocator;
const geom = @import("geom");
const StrId = geom.StrId;
const StrTable = geom.StrTable;
const Deck = @import("ingest").deck.Deck;
const params = @import("../drc/params.zig");
const Error = params.Error;
const Diagnostic = params.Diagnostic;
const kinds = @import("kinds.zig");
const Kind = kinds.Kind;
const RuleSet = @import("rule_set.zig").RuleSet;
const Row = @import("build_row.zig").Row;
const validate = @import("validate.zig");
const stage = @import("build_stage.zig");
const esd = @import("build_esd.zig");
const layout = @import("build_layout.zig");
const domain = @import("build_domain.zig");

/// What a kind builder reads and writes.
pub const Ctx = struct {
    gpa: Allocator,
    row: Row,
    rs: *RuleSet,
    deck: *const Deck,
};

/// Types every ERC row of `d` in deck order; a row of any other kind is
/// stepped over (the deck compiler refuses unknown kinds). The first
/// problem in deck order: `DuplicateRule` over rows of every domain, then,
/// in an ERC row, a missing or mistyped parameter or a wrong layer count
/// in its kind's reading order, then what `validate` refuses of it.
pub fn fromDeck(gpa: Allocator, d: *const Deck, strings: *const StrTable, diag: *Diagnostic) Error!RuleSet {
    var rs: RuleSet = .{};
    errdefer rs.deinit(gpa);
    // Sorted ids already filed; the first duplicate in deck order refuses.
    var seen: std.ArrayList(StrId) = .empty;
    defer seen.deinit(gpa);
    var scratch: std.heap.ArenaAllocator = .init(gpa);
    defer scratch.deinit();
    for (d.rules.spec) |spec| {
        const at = std.sort.lowerBound(StrId, seen.items, spec.id, orderId);
        if (at < seen.items.len and seen.items[at] == spec.id) {
            diag.* = .{ .rule = spec.id };
            return error.DuplicateRule;
        }
        try seen.insert(gpa, at, spec.id);
        const kind = kinds.byName(strings.resolve(spec.kind)) orelse continue;
        _ = scratch.reset(.retain_capacity);
        const c: Ctx = .{
            .gpa = gpa,
            .row = .{ .r = .{ .scratch = scratch.allocator(), .table = d.rules, .spec = spec, .strings = strings, .diag = diag } },
            .rs = &rs,
            .deck = d,
        };
        try build(c, kind);
        try rs.file(gpa, kind);
        try validate.validateRow(&rs, kind, rs.head(kind).len() - 1, diag);
    }
    rs.connectivity = d.connectivity;
    rs.height_nm = d.stack.height_nm;
    const dev = d.devices;
    for (dev.kind, 0..) |k, i| if (k == .mos and dev.terminal_start[i] < dev.terminal.len) {
        try rs.gates.append(gpa, dev.terminal[dev.terminal_start[i]]);
    };
    return rs;
}

/// Appends one CSR row of `items` to `list`, closing `start` (the leading
/// zero on the first row, then the running end).
pub fn pushCsr(gpa: Allocator, start: *std.ArrayList(u32), list: anytype, items: anytype) Allocator.Error!void {
    if (start.items.len == 0) try start.append(gpa, 0);
    try list.appendSlice(gpa, items);
    std.debug.assert(list.items.len <= std.math.maxInt(u32));
    try start.append(gpa, @intCast(list.items.len));
}

// ---- private ----

/// One row of `kind`, typed and pushed onto its table.
fn build(c: Ctx, kind: Kind) Error!void {
    return switch (kind) {
        .antenna => stage.antenna(c),
        .antenna_electrical => stage.antennaElectrical(c),
        .density_cmp => stage.densityCmp(c),
        .electromigration => stage.electromigration(c),
        .em_rms => stage.emAc(c, &c.rs.tables.em_rms),
        .em_peak => stage.emAc(c, &c.rs.tables.em_peak),
        .em_current_density => stage.emCurrentDensity(c),
        .em_thermal => stage.emThermal(c),
        .p2p_resistance => stage.p2pResistance(c),
        .ir_drop => stage.noLayers(c, &c.rs.tables.ir_drop.head),
        .dynamic_ir_drop => stage.noLayers(c, &c.rs.tables.dynamic_ir_drop.head),
        .esd_latchup => esd.esdLatchup(c),
        .esd_cross_domain => esd.esdCrossDomain(c),
        .esd_exposed => esd.esdExposed(c),
        .esd_ground_coupling => esd.esdGroundCoupling(c),
        .esd_parasitic => esd.esdParasitic(c),
        .esd_path => esd.esdPath(c),
        .esd_pin_pair => esd.esdPinPair(c),
        .esd_clamp_resistance => esd.esdClampResistance(c),
        .esd_topological => esd.esdTopological(c),
        .reliability => esd.reliability(c),
        .hv_domain => esd.hvDomain(c),
        .conditional_tie => layout.conditionalTie(c),
        .forward_diode => layout.forwardDiode(c),
        .guard_ring => layout.guardRing(c),
        .guard_ring_bias => layout.guardRingBias(c),
        .latchup_victim => layout.latchupVictim(c),
        .tie_area => layout.tieArea(c),
        .matching => layout.matching(c),
        .missing_tie => layout.missingTie(c),
        .multiple_drivers => layout.multipleDrivers(c),
        .soft_connection => layout.softConnection(c),
        .supply_short => layout.supplyShort(c),
        .unconnected_pin => layout.unconnectedPin(c),
        .mixed_tag => layout.mixedTag(c),
        .floating_gate => layout.floatingGate(c),
        .floating_well => layout.floatingWell(c),
        .fanout => layout.fanout(c),
        .supply_path => layout.supplyPath(c),
        .gate_path => layout.gatePath(c),
        .net_type => layout.netType(c),
        .tie_high_low => stage.noLayers(c, &c.rs.tables.tie_high_low.head),
        .floating_supply => stage.noLayers(c, &c.rs.tables.floating_supply.head),
        .combinational_loop => stage.noLayers(c, &c.rs.tables.combinational_loop.head),
        .gate_oxide => domain.modelLimit(c, &c.rs.tables.gate_oxide),
        .drain_source => domain.modelLimit(c, &c.rs.tables.drain_source),
        .well_bias => domain.wellBias(c),
        .missing_level_shifter => domain.missingLevelShifter(c),
        .domain_crossing => stage.noLayers(c, &c.rs.tables.domain_crossing.head),
        .undriven_gate => stage.noLayers(c, &c.rs.tables.undriven_gate.head),
        .missing_isolation => domain.missingIsolation(c),
        .hv_tag => domain.hvTag(c),
        .dielectric_field => domain.dielectricField(c),
        .voltage_spacing => domain.voltageSpacing(c),
        .power_switch => domain.powerSwitch(c),
        .hot_carrier => domain.hotCarrier(c),
        .well_sharing => domain.wellSharing(c),
    };
}

fn orderId(a: StrId, b: StrId) std.math.Order {
    return std.math.order(@backingInt(a), @backingInt(b));
}
