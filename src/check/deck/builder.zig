//! A deck built in code, or a compiled deck overridden: statements by name
//! into a `DeckSource`, then lowered and compiled as deck text is. In:
//! layers, derived layers, rules (`RuleRow`: a kind, layer expressions and
//! named parameters), custom rules, the overrides `add`, `replace`, `remove`,
//! and `matching` statements, each added or replacing the model's own.
//! Out: a `CompiledDeck` whose provenance says where each rule came from.
//! What the builder refuses (an id used twice, an override of something
//! absent, a length off the grid) is gathered, at most 50, and reported by
//! `finish` as `error.Invalid` with one diagnostic each, worded as the
//! parser words deck text. Ported from crates/check/src/deck/builder.rs;
//! a layer is named by its string (no handle type), and the statements
//! with no refusal of their own (connectivity, devices, pex rows) are
//! written straight into `doc`.
//!
//! Contents:
//! - `pub const DeckBuilder = struct`
//! - `DeckBuilder.init(arena: Allocator, grid: Grid, strings: *StrTable) DeckBuilder`
//! - `DeckBuilder.fromDeck(arena: Allocator, base: *const CompiledDeck, strings: *StrTable) Allocator.Error!DeckBuilder`
//! - `length(b: *DeckBuilder, nm: f64) Allocator.Error!Dbu`, `area(b, nm2: f64) Allocator.Error!DbuArea`
//! - `layer(b, name: []const u8, stream: [2]u16) Allocator.Error!void`, `ignore(b, stream: [2]u16) Allocator.Error!void`
//! - `derived(b, name: []const u8, comptime e: Expr) Allocator.Error!void`
//! - `removeLayer(b, name: []const u8) Allocator.Error!void`
//! - `rule(b, id: []const u8, row: RuleRow) Allocator.Error!void`, `add(b, id, row) Allocator.Error!void`,
//!   `replace(b, id, row) Allocator.Error!void`, `remove(b, id: []const u8) Allocator.Error!void`
//! - `custom(b, id: []const u8, inputs: []const []const u8, severity: Severity, check: CustomCheck) Allocator.Error!void`
//! - `matching(b, row: MatchingSource) Allocator.Error!void`
//! - `finish(b: *DeckBuilder, gpa: Allocator, diag: *Diag) Error!CompiledDeck`

const std = @import("std");
const Allocator = std.mem.Allocator;
const geom = @import("geom");
const Dbu = geom.Dbu;
const DbuArea = geom.DbuArea;
const Grid = geom.Grid;
const StrTable = geom.StrTable;
const ingest_deck = @import("ingest").deck;
const DeckSource = ingest_deck.DeckSource;
const RuleSource = ingest_deck.RuleSource;
const NamedSource = ingest_deck.NamedSource;
const MatchingSource = ingest_deck.MatchingSource;
const Severity = @import("../report.zig").Severity;
const compile = @import("compile.zig");
const CompiledDeck = compile.CompiledDeck;
const Origin = compile.Origin;
const Error = compile.Error;
const Diag = compile.Diag;
const source_ = @import("source.zig");
const custom_ = @import("custom.zig");
const CustomCheck = custom_.CustomCheck;
const expr = @import("expr.zig");
const Expr = expr.Expr;
const RuleRow = @import("rules.zig").RuleRow;

/// A deck under construction. Every string and list lives in `arena`, the
/// caller's, which must outlive the compiled deck's `deck` tables.
pub const DeckBuilder = struct {
    arena: Allocator,
    grid: Grid,
    strings: *StrTable,
    /// Everything but the rules and the text patterns, which `finish` fills.
    doc: DeckSource = .{},
    /// Per derived layer, its `with_text` or `in_cells` patterns.
    patterns: std.ArrayList([]const []const u8) = .empty,
    slots: std.ArrayList(Slot) = .empty,
    /// Rules added over the base deck: `finish` writes them sorted by id.
    added: std.ArrayList(Added) = .empty,
    base_origin: std.ArrayList(Named) = .empty,
    customs: std.ArrayList(Pending) = .empty,
    /// Whether this builder overrides a base deck, so what it states is added.
    based: bool = false,
    errors: std.ArrayList(ingest_deck.Diagnostic) = .empty,

    const Slot = union(enum) {
        kept: RuleSource,
        row: struct { id: []const u8, row: RuleRow, origin: Origin },
        /// A base rule removed: adding its id again replaces it here.
        removed: []const u8,

        fn id(s: Slot) []const u8 {
            return switch (s) {
                .kept => |r| r.id,
                .row => |r| r.id,
                .removed => |i| i,
            };
        }
    };
    const Added = struct { id: []const u8, row: RuleRow };
    const Named = struct { id: []const u8, origin: Origin };
    const Pending = struct { id: []const u8, inputs: []const []const u8, severity: Severity, check: CustomCheck, origin: Origin };

    /// An empty deck on the layout grid `grid`, its names interned into
    /// `strings` when it is finished.
    pub fn init(arena: Allocator, grid: Grid, strings: *StrTable) DeckBuilder {
        return .{ .arena = arena, .grid = grid, .strings = strings };
    }

    /// A builder that starts as `base` and overrides it. `strings` is the
    /// table `base` was compiled into.
    pub fn fromDeck(arena: Allocator, base: *const CompiledDeck, strings: *StrTable) Allocator.Error!DeckBuilder {
        var b: DeckBuilder = .{ .arena = arena, .grid = base.grid, .strings = strings, .based = true };
        b.doc = try source_.sourceOf(arena, base, strings);
        for (b.doc.derived.items) |row| try b.patterns.append(arena, switch (row.op) {
            .with_text => |t| b.doc.texts.items[t.text..][0..1],
            .in_cells => |c| b.doc.texts.items[c.first..][0..c.count],
            else => &.{},
        });
        for (b.doc.rules.items) |r| try b.slots.append(arena, .{ .kept = r });
        b.doc.rules = .empty;
        for (base.provenance.items) |p| try b.base_origin.append(arena, .{ .id = strings.resolve(p.id), .origin = p.origin });
        for (base.custom.items) |kept_rule| {
            const inputs = try arena.alloc([]const u8, kept_rule.inputs.len);
            for (inputs, kept_rule.inputs) |*n, l| n.* = strings.resolve(base.deck.layers.name(l));
            const id = strings.resolve(kept_rule.id);
            try b.customs.append(arena, .{ .id = id, .inputs = inputs, .severity = kept_rule.severity, .check = kept_rule.check, .origin = b.originOf(id) orelse .base });
        }
        return b;
    }

    /// `nm` nanometres on the deck's grid; refused (0) when not a whole
    /// number of grid units.
    pub fn length(b: *DeckBuilder, nm: f64) Allocator.Error!Dbu {
        return b.grid.toDbu(geom.Qty(.length, .nano){ .raw = nm }) catch {
            try b.refuse("{d}nm is not a whole number of grid units", .{nm});
            return 0;
        };
    }

    /// `nm2` square nanometres on the deck's grid; refused (0) when not a
    /// whole number of square grid units.
    pub fn area(b: *DeckBuilder, nm2: f64) Allocator.Error!DbuArea {
        const per_um: f64 = @floatFromInt(b.grid.dbu_per_um);
        const units = nm2 * per_um * per_um / 1e6;
        if (std.math.isFinite(units) and @trunc(units) == units and @abs(units) < std.math.pow(f64, 2, 100)) return @intFromFloat(units);
        try b.refuse("{d}nm2 is not a whole number of square grid units", .{nm2});
        return 0;
    }

    /// `layer name = gds(layer, datatype)`: a drawn layer.
    pub fn layer(b: *DeckBuilder, name: []const u8, stream: [2]u16) Allocator.Error!void {
        try b.declare(name);
        try b.doc.layers.append(b.arena, .{ .name = name, .stream = stream });
    }

    /// `ignore gds(layer, datatype)`.
    pub fn ignore(b: *DeckBuilder, stream: [2]u16) Allocator.Error!void {
        for (b.doc.ignored.items) |s| if (std.mem.eql(u16, &s, &stream)) try b.refuse("gds({d}, {d}) is already ignored", .{ stream[0], stream[1] });
        try b.doc.ignored.append(b.arena, stream);
    }

    /// `layer name = e`: a derived layer, its inner operations `name#k`.
    /// Refused when `e` is a plain layer or its construction refused.
    pub fn derived(b: *DeckBuilder, name: []const u8, comptime e: Expr) Allocator.Error!void {
        try b.declare(name);
        try b.lowerNamed(name, e);
    }

    /// Removes a layer, drawn or derived (with its hidden inner layers).
    /// Anything still naming it is refused when the deck is finished.
    pub fn removeLayer(b: *DeckBuilder, name: []const u8) Allocator.Error!void {
        const before = b.doc.layers.items.len + b.doc.derived.items.len;
        var kept: usize = 0;
        for (b.doc.layers.items) |l| if (!std.mem.eql(u8, l.name, name)) {
            b.doc.layers.items[kept] = l;
            kept += 1;
        };
        b.doc.layers.shrinkRetainingCapacity(kept);
        kept = 0;
        for (b.doc.derived.items, b.patterns.items) |row, p| if (!std.mem.eql(u8, row.name, name) and !isHidden(row.name, name)) {
            b.doc.derived.items[kept] = row;
            b.patterns.items[kept] = p;
            kept += 1;
        };
        b.doc.derived.shrinkRetainingCapacity(kept);
        b.patterns.shrinkRetainingCapacity(kept);
        if (b.doc.layers.items.len + b.doc.derived.items.len == before) try b.refuse("remove of layer `{s}`, which the deck does not have", .{name});
    }

    /// `rule id ..`: a rule this deck states, after the ones before it.
    pub fn rule(b: *DeckBuilder, id: []const u8, row: RuleRow) Allocator.Error!void {
        if (try b.checkId(id)) try b.slots.append(b.arena, .{ .kept = try b.lowerRule(id, row) });
    }

    /// Adds a rule over the base deck. Refused when the id is taken; an id
    /// removed before is replaced in its place.
    pub fn add(b: *DeckBuilder, id: []const u8, row: RuleRow) Allocator.Error!void {
        for (b.slots.items) |*s| if (s.* == .removed and std.mem.eql(u8, s.removed, id)) {
            s.* = .{ .row = .{ .id = id, .row = row, .origin = .replaced } };
            return;
        };
        if (try b.checkId(id)) try b.added.append(b.arena, .{ .id = id, .row = row });
    }

    /// Replaces the rule `id`, keeping its place; its kind may change.
    /// Refused, never an add, when the deck has no rule `id`, and for a
    /// custom rule, which is removed and stated again.
    pub fn replace(b: *DeckBuilder, id: []const u8, row: RuleRow) Allocator.Error!void {
        for (b.customs.items) |c| if (std.mem.eql(u8, c.id, id)) return b.refuse("replace of custom rule `{s}`: remove it and state the new one", .{id});
        for (b.added.items) |*a| if (std.mem.eql(u8, a.id, id)) {
            a.row = row;
            return;
        };
        for (b.slots.items) |*s| if (s.* != .removed and std.mem.eql(u8, s.id(), id)) {
            s.* = .{ .row = .{ .id = id, .row = row, .origin = .replaced } };
            return;
        };
        try b.refuse("replace of rule `{s}`, which the deck does not have", .{id});
    }

    /// Removes the rule `id`, custom or not. Refused when the deck has none.
    pub fn remove(b: *DeckBuilder, id: []const u8) Allocator.Error!void {
        for (b.added.items, 0..) |a, i| if (std.mem.eql(u8, a.id, id)) {
            _ = b.added.orderedRemove(i);
            return;
        };
        for (b.customs.items, 0..) |c, i| if (std.mem.eql(u8, c.id, id)) {
            _ = b.customs.orderedRemove(i);
            return;
        };
        for (b.slots.items) |*s| if (s.* != .removed and std.mem.eql(u8, s.id(), id)) {
            s.* = .{ .removed = id };
            return;
        };
        try b.refuse("remove of rule `{s}`, which the deck does not have", .{id});
    }

    /// A custom rule: `check` reads `inputs` and reports at `severity`,
    /// after the DRC rules. Added in a builder started from a deck. Refused
    /// when the id is taken or no input is given.
    pub fn custom(b: *DeckBuilder, id: []const u8, inputs: []const []const u8, severity: Severity, check: CustomCheck) Allocator.Error!void {
        if (!try b.checkId(id)) return;
        if (inputs.len == 0) return b.refuse("{s}: a custom rule reads at least one layer", .{id});
        try b.customs.append(b.arena, .{ .id = id, .inputs = try b.arena.dupe([]const u8, inputs), .severity = severity, .check = check, .origin = if (b.based) .added else .base });
    }

    /// `matching "model" ..`: the statement for `row.model`, replacing the
    /// deck's own when it has one. A model no `device` of a stated key's
    /// kind declares, or a value that is not positive, is refused when the
    /// deck is finished, as text is.
    pub fn matching(b: *DeckBuilder, row: MatchingSource) Allocator.Error!void {
        for (b.doc.matching.items) |*own| if (std.mem.eql(u8, own.model, row.model)) {
            own.* = row;
            return;
        };
        try b.doc.matching.append(b.arena, row);
    }

    /// Lowers and compiles the deck, as `compile` does deck text, recording
    /// where each rule came from. `error.Invalid` with everything the
    /// builder refused in `diag.deck`; else what lowering or typing refused.
    pub fn finish(b: *DeckBuilder, gpa: Allocator, diag: *Diag) Error!CompiledDeck {
        const arena = b.arena;
        // A base rule's inline layers go with it when it is replaced or removed.
        var kept: usize = 0;
        for (b.doc.derived.items, b.patterns.items) |row, p| {
            const owner = if (std.mem.indexOfScalar(u8, row.name, '@')) |at| row.name[0..at] else null;
            if (owner) |o| if (!b.keeps(o)) continue;
            b.doc.derived.items[kept] = row;
            b.patterns.items[kept] = p;
            kept += 1;
        }
        b.doc.derived.shrinkRetainingCapacity(kept);
        b.patterns.shrinkRetainingCapacity(kept);
        var origins: std.ArrayList(Named) = .empty;
        b.doc.rules = .empty;
        for (b.slots.items) |s| switch (s) {
            .kept => |r| {
                try origins.append(arena, .{ .id = r.id, .origin = b.originOf(r.id) orelse .base });
                try b.doc.rules.append(arena, r);
            },
            .row => |r| {
                try origins.append(arena, .{ .id = r.id, .origin = r.origin });
                try b.doc.rules.append(arena, try b.lowerRule(r.id, r.row));
            },
            .removed => {},
        };
        std.mem.sortUnstable(Added, b.added.items, {}, struct {
            fn less(_: void, p: Added, q: Added) bool {
                return std.mem.lessThan(u8, p.id, q.id);
            }
        }.less);
        for (b.added.items) |a| {
            try origins.append(arena, .{ .id = a.id, .origin = .added });
            try b.doc.rules.append(arena, try b.lowerRule(a.id, a.row));
        }
        if (b.errors.items.len > 0) {
            diag.deck = .{ .diagnostics = b.errors.items };
            return error.Invalid;
        }
        // Text patterns are numbered in the order the derived rows name them,
        // as the parser numbers them.
        b.doc.texts = .empty;
        for (b.doc.derived.items, b.patterns.items) |*row, p| switch (row.op) {
            .with_text => |*t| {
                t.text = @intCast(b.doc.texts.items.len);
                try b.doc.texts.append(arena, if (p.len > 0) p[0] else "");
            },
            .in_cells => |*c| {
                c.first = @intCast(b.doc.texts.items.len);
                c.count = @intCast(p.len);
                try b.doc.texts.appendSlice(arena, p);
            },
            else => {},
        };
        // A removed rule leaves its stage and its waivers.
        for (b.doc.stages.items) |*stage| {
            var n: usize = 0;
            for (stage.rules.items) |id| if (b.stated(id)) {
                stage.rules.items[n] = id;
                n += 1;
            };
            stage.rules.shrinkRetainingCapacity(n);
        }
        var w: usize = 0;
        for (b.doc.waivers.items) |waiver| if (b.stated(waiver.rule)) {
            b.doc.waivers.items[w] = waiver;
            w += 1;
        };
        b.doc.waivers.shrinkRetainingCapacity(w);
        const d = try ingest_deck.lower(arena, gpa, &b.doc, b.strings, &diag.deck);
        var cd = try compile.fromDeck(gpa, d, b.grid, b.strings, diag);
        errdefer cd.deinit(gpa);
        for (cd.provenance.items) |*p| {
            for (origins.items) |o| if (std.mem.eql(u8, o.id, b.strings.resolve(p.id))) {
                p.origin = o.origin;
            };
        }
        // Custom rules follow every typed rule, their ids interned last.
        for (b.customs.items) |c| {
            const inputs = try gpa.alloc(geom.LayerId, c.inputs.len);
            errdefer gpa.free(inputs);
            for (inputs, c.inputs) |*l, name| l.* = cd.deck.layers.id(b.strings, name) orelse {
                diag.deck = .{ .malformed = try std.fmt.allocPrint(arena, "{s}: unknown layer {s}", .{ c.id, name }) };
                return error.Malformed;
            };
            const id = try b.strings.intern(gpa, c.id);
            try cd.custom.append(gpa, .{ .id = id, .inputs = inputs, .severity = c.severity, .check = c.check });
            try cd.provenance.append(gpa, .{ .id = id, .origin = c.origin });
        }
        return cd;
    }

    // ---- private ----

    fn refuse(b: *DeckBuilder, comptime fmt: []const u8, args: anytype) Allocator.Error!void {
        if (b.errors.items.len >= max_errors) return;
        try b.errors.append(b.arena, .{ .message = try std.fmt.allocPrint(b.arena, fmt, args), .start = 0, .end = 0 });
    }

    fn declare(b: *DeckBuilder, name: []const u8) Allocator.Error!void {
        if (!isLayerName(name)) return b.refuse("`{s}` is not a layer name a deck can write", .{name});
        for (b.doc.layers.items) |l| if (std.mem.eql(u8, l.name, name)) return b.refuse("`{s}` is already bound", .{name});
        for (b.doc.derived.items) |l| if (std.mem.eql(u8, l.name, name)) return b.refuse("`{s}` is already bound", .{name});
    }

    fn checkId(b: *DeckBuilder, id: []const u8) Allocator.Error!bool {
        if (!isRuleId(id)) {
            try b.refuse("`{s}` is not a rule id a deck can write", .{id});
            return false;
        }
        if (b.has(id)) {
            try b.refuse("duplicate rule id `{s}`", .{id});
            return false;
        }
        return true;
    }

    /// Whether some rule of the deck has `id`.
    fn has(b: *const DeckBuilder, id: []const u8) bool {
        for (b.added.items) |a| if (std.mem.eql(u8, a.id, id)) return true;
        for (b.customs.items) |c| if (std.mem.eql(u8, c.id, id)) return true;
        for (b.slots.items) |s| if (s != .removed and std.mem.eql(u8, s.id(), id)) return true;
        return false;
    }

    /// Whether the base rule `id` is kept as it was.
    fn keeps(b: *const DeckBuilder, id: []const u8) bool {
        for (b.slots.items) |s| if (s == .kept and std.mem.eql(u8, s.kept.id, id)) return true;
        return false;
    }

    /// Whether the finished rules include `id`.
    fn stated(b: *const DeckBuilder, id: []const u8) bool {
        for (b.doc.rules.items) |r| if (std.mem.eql(u8, r.id, id)) return true;
        return false;
    }

    fn originOf(b: *const DeckBuilder, id: []const u8) ?Origin {
        for (b.base_origin.items) |o| if (std.mem.eql(u8, o.id, id)) return o.origin;
        return null;
    }

    fn lowerNamed(b: *DeckBuilder, name: []const u8, e: Expr) Allocator.Error!void {
        if (e.fault) |why| return b.refuse("{s}", .{why});
        if (e.node == .layer) return b.refuse("a derived layer needs an operator (and, or, not) or an operation (`.sized(..)`)", .{});
        try expr.lowerNamed(b.arena, .{ .derived = &b.doc.derived, .patterns = &b.patterns }, name, e.node);
    }

    /// A row in the parser's form: each layer argument that is not a plain
    /// layer lowered as `id@k` in deck order, the layers put in the engine's
    /// order, and `warning` a parameter.
    fn lowerRule(b: *DeckBuilder, id: []const u8, row: RuleRow) Allocator.Error!RuleSource {
        const named = try b.arena.alloc([]const u8, row.layers.len);
        var inline_count: u32 = 0;
        for (row.layers, named) |arg, *n| {
            if (arg.node == .layer and arg.fault == null) {
                n.* = arg.node.layer;
                continue;
            }
            inline_count += 1;
            n.* = try std.fmt.allocPrint(b.arena, "{s}@{d}", .{ id, inline_count });
            try b.lowerNamed(n.*, arg);
        }
        const layers = if (row.slots.len == 0 or named.len < row.slots.len) named else blk: {
            const ordered = try b.arena.alloc([]const u8, named.len);
            for (row.slots, 0..) |slot, i| ordered[i] = named[slot];
            @memcpy(ordered[row.slots.len..], named[row.slots.len..]);
            break :blk ordered;
        };
        var params: std.ArrayList(NamedSource) = .empty;
        try params.appendSlice(b.arena, row.params);
        if (row.warning) try params.append(b.arena, .{ .name = "warning", .value = .{ .value = .{ .flag = true } } });
        return .{ .id = id, .kind = row.kind, .layers = layers, .params = params.items };
    }
};

/// The most diagnostics a builder keeps, as the parser keeps.
const max_errors = 50;

// ---- private ----

/// Whether `name` is `owner`'s hidden inner layer (`owner#k`).
fn isHidden(name: []const u8, owner: []const u8) bool {
    return name.len > owner.len and std.mem.startsWith(u8, name, owner) and name[owner.len] == '#';
}

/// A letter or `_`, then letters, digits and `_`.
fn isLayerName(name: []const u8) bool {
    if (name.len == 0 or !(std.ascii.isAlphabetic(name[0]) or name[0] == '_')) return false;
    for (name[1..]) |ch| if (!(std.ascii.isAlphanumeric(ch) or ch == '_')) return false;
    return true;
}

/// Letters, digits, `_` and `.`.
fn isRuleId(id: []const u8) bool {
    if (id.len == 0) return false;
    for (id) |ch| if (!(std.ascii.isAlphanumeric(ch) or ch == '_' or ch == '.')) return false;
    return true;
}
