//! A compiled deck back to names, and to text. In: a `CompiledDeck` and the
//! string table it was compiled into. Out: the `DeckSource` the parser
//! would read its text into (`sourceOf`), which `lower` and `fromDeck` turn
//! back into an equal deck, or that text (`print`). Rules come from the
//! kept rule table, as written, so no typed rule is decompiled. Ported from
//! crates/check/src/deck/decompile.rs (`CompiledDeck::source`) and mod.rs
//! (`print`).
//!
//! Contents:
//! - `pub fn print(arena: Allocator, cd: *const CompiledDeck, strings: *const StrTable, why: *[]const u8) PrintError![]const u8`
//! - `pub fn sourceOf(arena: Allocator, cd: *const CompiledDeck, strings: *const StrTable) Allocator.Error!DeckSource`

const std = @import("std");
const Allocator = std.mem.Allocator;
const geom = @import("geom");
const LayerId = geom.LayerId;
const StrTable = geom.StrTable;
const ingest_deck = @import("ingest").deck;
const DeckSource = ingest_deck.DeckSource;
const PrintError = ingest_deck.PrintError;
const CompiledDeck = @import("compile.zig").CompiledDeck;

/// A `stage` line by name (the ingest module does not export the type).
const StageSource = @typeInfo(@FieldType(@FieldType(DeckSource, "stages"), "items")).pointer.child;

/// Writes `cd` as deck text, which `compile` reads back, in the same
/// `strings`, to an equal deck: the way to share a deck built or overridden
/// in code with a tool that reads text. `Unprintable` (with `why`) for a
/// value the language cannot state exactly, or a deck holding custom rules,
/// which no deck text states: the error names them, so a shared deck never
/// drops one silently.
pub fn print(arena: Allocator, cd: *const CompiledDeck, strings: *const StrTable, why: *[]const u8) PrintError![]const u8 {
    if (cd.custom.items.len > 0) {
        var ids: std.ArrayList(u8) = .empty;
        for (cd.custom.items, 0..) |rule, i| try ids.print(arena, "{s}{s}", .{ if (i > 0) ", " else "", strings.resolve(rule.id) });
        why.* = try std.fmt.allocPrint(arena, "custom rules {s} are functions, which no deck text states", .{ids.items});
        return error.Unprintable;
    }
    const doc = try sourceOf(arena, cd, strings);
    return ingest_deck.print(arena, &doc, cd.grid, why);
}

/// The deck as names, in the form the parser reads text into. Lists grow
/// in `arena`.
pub fn sourceOf(arena: Allocator, cd: *const CompiledDeck, strings: *const StrTable) Allocator.Error!DeckSource {
    const d = &cd.deck;
    const temperature: ?f64 = if (d.temperature) |t| t.raw else null;
    var doc = try ingest_deck.fromTables(arena, &d.layers, d.connectivity, d.devices, d.stack, temperature, strings);
    doc.lvs = try ingest_deck.fromControls(arena, d.lvs, doc.devices.items, strings);
    for (d.matching) |row| try doc.matching.append(arena, .{ .model = strings.resolve(row.model), .basis = row.basis, .stated = row.stated });
    for (d.corners) |corner| for (corner.stated) |line| {
        try doc.corners.append(arena, .{ .corner = strings.resolve(corner.name), .layer = layerName(cd, line.layer, strings), .values = line.values });
    };
    for (d.stages.name, 0..) |name, at| {
        var stage: StageSource = .{ .name = strings.resolve(name) };
        for (d.stages.of_rule) |r| if (r.stage == at) try stage.rules.append(arena, strings.resolve(r.rule));
        try doc.stages.append(arena, stage);
    }
    for (d.waivers) |w| try doc.waivers.append(arena, .{ .rule = strings.resolve(w.rule), .layer = layerName(cd, w.layer, strings) });
    doc.grid_nm = d.grid_nm;
    doc.boundary = if (d.boundary) |l| layerName(cd, l, strings) else null;
    doc.extraction = if (std.meta.eql(d.extraction, ingest_deck.Extraction{})) null else d.extraction;
    doc.pex_models = d.pex_models;
    doc.edits = d.edits;
    doc.reports = d.reports;
    // The sheets as written, at the nominal temperature, with their
    // coefficients, rather than at the operating one with none.
    if (d.temperature_law) |law| {
        doc.temperature = .{ .operating_k = law.operating_k, .nominal_k = law.nominal_k };
        for (law.rows) |row| {
            const name = layerName(cd, row.layer, strings);
            for (doc.pex.items) |*pex| if (std.mem.eql(u8, pex.layer, name)) {
                pex.row.sheet_res_ohm_sq = row.sheet_ohm_sq;
                pex.row.tc = .{ row.tc1, row.tc2 };
            };
        }
    }
    const t = d.rules;
    for (t.spec) |spec| {
        const layers = try arena.alloc([]const u8, spec.layer_len);
        for (layers, t.layersOf(spec)) |*out, l| out.* = layerName(cd, l, strings);
        const named = try arena.alloc(ingest_deck.NamedSource, spec.param_len);
        for (named, t.paramsOf(spec)) |*out, p| out.* = .{ .name = strings.resolve(p.name), .value = switch (p.value) {
            .layer => |l| .{ .layer = layerName(cd, l, strings) },
            .model => |m| .{ .model = strings.resolve(m) },
            else => |v| .{ .value = v },
        } };
        try doc.rules.append(arena, .{ .id = strings.resolve(spec.id), .kind = strings.resolve(spec.kind), .layers = layers, .params = named });
    }
    return doc;
}

// ---- private ----

fn layerName(cd: *const CompiledDeck, layer: LayerId, strings: *const StrTable) []const u8 {
    return strings.resolve(cd.deck.layers.name(layer));
}
