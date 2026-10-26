//! A deck compiled for the engine: the parsed tables plus every DRC rule
//! typed. In: deck text and the layout's grid (`compile`), or a parsed
//! `Deck` (`fromDeck`). Out: a `CompiledDeck`, the engine runs as it is. A
//! deck that compiled names no kind the engine does not run and holds no
//! limit it would refuse. Ported from crates/check/src/deck/mod.rs
//! (`CompiledDeck`, `compile`, `CompiledDeck::from_deck`, `rule_count`).
//!
//! Until the ERC port (wave 4) an ERC row is refused by name
//! (`error.ErcRulesNotPorted`, its id and kind in the diagnostic), never
//! dropped. The parsed rule table is kept: it is what printing reads.
//!
//! Contents:
//! - `pub const CompiledDeck = struct`, `deinit`, `ruleCount(cd: *const CompiledDeck) u32`
//! - `pub const Origin = enum { base, added, replaced }`, `pub const Provenance`
//! - `pub const Error`, `pub const Diag`
//! - `pub fn compile(gpa: Allocator, arena: Allocator, text: []const u8, grid: Grid, strings: *StrTable, diag: *Diag) Error!CompiledDeck`
//! - `pub fn fromDeck(gpa: Allocator, d: Deck, grid: Grid, strings: *const StrTable, diag: *Diag) Error!CompiledDeck`

const std = @import("std");
const Allocator = std.mem.Allocator;
const geom = @import("geom");
const Grid = geom.Grid;
const StrId = geom.StrId;
const StrTable = geom.StrTable;
const ingest_deck = @import("ingest").deck;
const Deck = ingest_deck.Deck;
const drc_kinds = @import("../drc/kinds.zig");
const params = @import("../drc/params.zig");
const RuleSet = @import("../drc/rule_set.zig").RuleSet;
const drc_compile = @import("../drc/compile.zig");
const erc_kinds = @import("../erc/kinds.zig");
const CustomRule = @import("custom.zig").CustomRule;

/// Why a deck did not compile: the parser's errors, then the rule typer's.
pub const Error = ingest_deck.Error || params.Error;

/// The detail of a refusal: the parser's located diagnostics, or the row
/// the typer refused.
pub const Diag = struct {
    deck: ingest_deck.Diag = .{},
    rule: params.Diagnostic = .{},
};

/// Where a rule came from.
pub const Origin = enum(u8) {
    /// As the deck it was compiled or built from states it.
    base,
    /// Added over a base deck.
    added,
    /// A base deck's rule, replaced.
    replaced,
};

pub const Provenance = struct { id: StrId, origin: Origin };

/// A deck ready to run. Every `StrId` is from the table it was compiled
/// into and every length on `grid`, so it is meaningful only with a layout
/// on that grid and that table. `deck`'s slices live in the caller's arena;
/// `drc`, `custom` and `provenance` are owned (`deinit`).
pub const CompiledDeck = struct {
    grid: Grid,
    /// The parsed tables: layers, connectivity, devices, stack, corners,
    /// stages, waivers, lvs controls, and the rule rows as written.
    deck: Deck,
    /// Every DRC rule, typed, in deck order.
    drc: RuleSet,
    /// Rule kinds written in code, run after the DRC rules; empty for a
    /// deck compiled from text. Each one's `inputs` is owned.
    custom: std.ArrayList(CustomRule) = .empty,
    /// Every rule's id in deck order (custom rules last), with where it came
    /// from: what a report says a consumer changed in a shipped deck.
    provenance: std.ArrayList(Provenance) = .empty,

    pub fn deinit(cd: *CompiledDeck, gpa: Allocator) void {
        cd.drc.deinit(gpa);
        for (cd.custom.items) |rule| gpa.free(rule.inputs);
        cd.custom.deinit(gpa);
        cd.provenance.deinit(gpa);
    }

    /// The `RuleRun` rows a run of every domain records.
    pub fn ruleCount(cd: *const CompiledDeck) u32 {
        return @intCast(cd.provenance.items.len);
    }
};

/// Parses `text` on the layout grid `grid` into `arena`, interning every
/// name into `strings` (through `gpa`), and types every rule.
pub fn compile(gpa: Allocator, arena: Allocator, text: []const u8, grid: Grid, strings: *StrTable, diag: *Diag) Error!CompiledDeck {
    const d = try ingest_deck.parseDeck(arena, gpa, text, grid, strings, &diag.deck);
    return fromDeck(gpa, d, grid, strings, diag);
}

/// Types every rule of a parsed deck. The first problem, in this order: a
/// row whose kind is in neither kind list (`UnknownKind`); what the DRC
/// typer refuses; then the first ERC row (`ErcRulesNotPorted`).
pub fn fromDeck(gpa: Allocator, d: Deck, grid: Grid, strings: *const StrTable, diag: *Diag) Error!CompiledDeck {
    for (d.rules.spec) |spec| {
        const kind = strings.resolve(spec.kind);
        if (drc_kinds.byName(kind) == null and !erc_kinds.isKind(kind)) {
            diag.rule = .{ .rule = spec.id, .kind = spec.kind };
            return error.UnknownKind;
        }
    }
    var drc = try drc_compile.fromDeck(gpa, &d, strings, &diag.rule);
    errdefer drc.deinit(gpa);
    for (d.rules.spec) |spec| if (erc_kinds.isKind(strings.resolve(spec.kind))) {
        diag.rule = .{ .rule = spec.id, .kind = spec.kind };
        return error.ErcRulesNotPorted;
    };
    var cd: CompiledDeck = .{ .grid = grid, .deck = d, .drc = drc };
    try cd.provenance.ensureTotalCapacityPrecise(gpa, d.rules.spec.len);
    for (d.rules.spec) |spec| cd.provenance.appendAssumeCapacity(.{ .id = spec.id, .origin = .base });
    return cd;
}
