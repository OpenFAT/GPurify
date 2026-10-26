//! A parsed deck's DRC rows → a `RuleSet`: each row typed by its kind's
//! builder, held to `validate`, and pushed in deck order. In: the `Deck`
//! (its rule table and layer table) and the string table it was interned
//! into. Out: a `RuleSet` the caller owns, or the first problem as a named
//! error with its row in the `Diagnostic`. Ported from
//! crates/check/src/drc/ruleset.rs (`RuleSet::from_deck`); the per-kind arms
//! live in `build_shapes.zig`, `build_spacing.zig` and `build_layers.zig`.
//!
//! Contents:
//! - `pub fn fromDeck(gpa: Allocator, d: *const Deck, strings: *const StrTable, diag: *Diagnostic) Error!RuleSet`
//! - `pub fn buildRule(c: Ctx, kind: Kind) Error!Rule`
//! - `pub const Ctx = struct`

const std = @import("std");
const Allocator = std.mem.Allocator;
const geom = @import("geom");
const LayerId = geom.LayerId;
const StrId = geom.StrId;
const StrTable = geom.StrTable;
const deck = @import("ingest").deck;
const Deck = deck.Deck;
const LayerTable = deck.LayerTable;
const kinds = @import("kinds.zig");
const Kind = kinds.Kind;
const Rule = @import("rows.zig").Rule;
const RuleSet = @import("rule_set.zig").RuleSet;
const params = @import("params.zig");
const Error = params.Error;
const Diagnostic = params.Diagnostic;
const Reader = params.Reader;
const validate = @import("validate.zig").validate;
const shapes = @import("build_shapes.zig");
const spacing = @import("build_spacing.zig");
const layers_ = @import("build_layers.zig");

/// What a kind builder reads and where it files side tables.
pub const Ctx = struct {
    gpa: Allocator,
    r: Reader,
    rs: *RuleSet,
    layers: *const LayerTable,
};

/// Types every DRC row of `d`, in deck order; a row of any other kind is
/// stepped over (the deck compiler refuses unknown and ERC kinds). The
/// first problem, in deck order, and within a row: `DuplicateRule` over
/// rows of every domain, then `WrongLayerCount`, `MissingParam` or
/// `WrongParamType` in field order, `UnrepresentableAngle`, then what
/// `validate` refuses, and `BadTable` for a table that fails its check.
pub fn fromDeck(gpa: Allocator, d: *const Deck, strings: *const StrTable, diag: *Diagnostic) Error!RuleSet {
    const specs = d.rules.spec;
    {
        const ids = try gpa.alloc(StrId, specs.len);
        defer gpa.free(ids);
        for (ids, specs) |*id, s| id.* = s.id;
        std.mem.sortUnstable(StrId, ids, {}, lessId);
        for (1..ids.len) |i| if (ids[i - 1] == ids[i]) {
            diag.* = .{ .rule = ids[i] };
            return error.DuplicateRule;
        };
    }
    var rs: RuleSet = .{};
    errdefer rs.deinit(gpa);
    for (0..d.layers.len()) |i| {
        const id: LayerId = @fromBackingInt(@as(u16, @intCast(i)));
        if (d.layers.isDerived(id)) {
            rs.first_derived = id;
            break;
        }
    }
    var scratch: std.heap.ArenaAllocator = .init(gpa);
    defer scratch.deinit();
    for (specs) |spec| {
        const kind = kinds.byName(strings.resolve(spec.kind)) orelse continue;
        _ = scratch.reset(.retain_capacity);
        const c: Ctx = .{
            .gpa = gpa,
            .r = .{ .scratch = scratch.allocator(), .table = d.rules, .spec = spec, .strings = strings, .diag = diag },
            .rs = &rs,
            .layers = &d.layers,
        };
        const rule = try buildRule(c, kind);
        try validate(spec.id, rule, &rs, diag);
        const warning = if (c.r.optional("warning")) |v| switch (v) {
            .flag => |set| set,
            .length, .ratio, .count, .area, .layer, .model => return c.r.fail(error.WrongParamType, "warning"),
        } else false;
        try rs.push(gpa, spec.id, rule, if (warning) .warning else .@"error");
    }
    return rs;
}

/// One row of `kind`, typed: layer count first, then each parameter in
/// field order. Side tables are filed into `c.rs` as they are read.
pub fn buildRule(c: Ctx, kind: Kind) Error!Rule {
    const r = c.r;
    return switch (kind) {
        .min_width => .{ .min_width = try layerLimit(r) },
        .max_width => .{ .max_width = try layerLimit(r) },
        .cut_size => .{ .cut_size = .{ .layer = try r.one(), .width = try r.length("width"), .height = try r.length("height") } },
        .min_edge_length => .{ .min_edge_length = try layerLimit(r) },
        .notch => .{ .notch = try layerLimit(r) },
        .min_spacing => .{ .min_spacing = try layerLimit(r) },
        .min_spacing_diff => .{ .min_spacing_diff = try twoLayers(r) },
        .projection_spacing => .{ .projection_spacing = try twoLayers(r) },
        .eol_spacing => .{ .eol_spacing = .{ .layer = try r.one(), .eol_width = try r.length("eol_width"), .limit = try r.length("limit") } },
        .prl_spacing => .{ .prl_spacing = .{ .layer = try r.one(), .prl_threshold = try r.length("prl_threshold"), .limit = try r.length("limit") } },
        .corner_to_corner => .{ .corner_to_corner = try layerLimit(r) },
        .wide_dependent_spacing => .{ .wide_dependent_spacing = .{ .layer = try r.one(), .width_threshold = try r.length("width_threshold"), .limit = try r.length("limit") } },
        .min_area => .{ .min_area = .{ .layer = try r.one(), .limit = try r.area("limit") } },
        .min_enclosed_area => .{ .min_enclosed_area = .{ .layer = try r.one(), .limit = try r.area("limit") } },
        .cheesing => .{ .cheesing = .{ .layer = try r.one(), .max_unslotted = try r.area("max_unslotted") } },
        .density => layers_.density(c),
        .global_density => layers_.globalDensity(c),
        .critical_area => .{ .critical_area = .{ .layer = try r.one(), .radius = try r.length("radius"), .limit = try r.area("limit") } },
        .mean_critical_area => shapes.meanCriticalArea(c),
        .density_balance => layers_.densityBalance(c),
        .via_redundancy => layers_.viaRedundancy(c),
        .dfm_score => shapes.dfmScore(c),
        .pattern_match => shapes.patternMatch(c),
        .cut_area_change => layers_.cutAreaChange(c),
        .cover_density => layers_.coverDensity(c),
        .min_enclosure => .{ .min_enclosure = try layers_.enclosure(r, "limit") },
        .noncoincident_enclosure => .{ .noncoincident_enclosure = try plainEnclosure(r, "limit") },
        .full_width => blk: {
            const l = try r.two();
            break :blk .{ .full_width = .{ .outer = l[0], .inner = l[1] } };
        },
        .asymmetric_enclosure => .{ .asymmetric_enclosure = try layers_.enclosure(r, "min_one_side") },
        .max_enclosure => .{ .max_enclosure = try plainEnclosure(r, "limit") },
        .adjacent_enclosure => .{ .adjacent_enclosure = try plainEnclosure(r, "min_one_side") },
        .min_extension => blk: {
            const l = try r.two();
            break :blk .{ .min_extension = .{ .layer = l[0], .reference = l[1], .limit = try r.length("limit") } };
        },
        .gate_corner => blk: {
            const l = try r.two();
            break :blk .{ .gate_corner = .{ .layer = l[0], .reference = l[1], .of_reference = try r.flag("of_reference") } };
        },
        .overlap => .{ .overlap = try twoLayers(r) },
        .max_distance_to_tap => blk: {
            const l = try r.two();
            break :blk .{ .max_distance_to_tap = .{ .well = l[0], .tap = l[1], .limit = try r.length("limit") } };
        },
        .off_grid => blk: {
            try r.layerCount(0);
            break :blk .{ .off_grid = .{ .pitch = try r.length("pitch") } };
        },
        .angle => shapes.angle(c),
        .redundant_via => .{ .redundant_via = .{ .layer = try r.one(), .min_count = @intCast(try r.count("min_count", std.math.maxInt(u16))), .within = try r.length("within") } },
        .minimum_cut => layers_.minimumCut(c),
        .via_stack => layers_.viaStack(c),
        .metal_width_via => layers_.metalWidthVia(c),
        .stack_spacing => blk: {
            try r.layerCount(3);
            break :blk .{ .stack_spacing = .{ .a = r.layer(0), .b = r.layer(1), .metal = r.layer(2), .same_only = try r.optFlag("same_net"), .limit = try r.length("limit") } };
        },
        .max_cut_spacing => blk: {
            const l = try r.bounded();
            break :blk .{ .max_cut_spacing = .{ .cut = l.layer, .others = l.other, .limit = try r.length("limit") } };
        },
        .via_array_spacing => .{ .via_array_spacing = .{ .layer = try r.one(), .array_threshold = @intCast(try r.count("array_threshold", std.math.maxInt(u16))), .limit = try r.length("limit") } },
        .cut_spacing => layers_.cutSpacing(c),
        .cut_class_spacing => layers_.cutClassSpacing(c),
        .multi_patterning => .{ .multi_patterning = .{ .layer = try r.one(), .colors = @intCast(try r.count("colors", std.math.maxInt(u8))), .color_spacing = try r.length("color_spacing") } },
        .anchored_patterning => spacing.anchoredPatterning(c),
        .sadp => spacing.sadp(c),
        .sadp_line_end => .{ .sadp_line_end = .{ .layer = try r.one(), .ends = .{
            .adjacent = try r.length("adjacent"),
            .tip = try r.length("tip"),
            .overlap = try r.length("overlap"),
            .corner = try r.length("corner"),
            .offset = try r.length("offset"),
        } } },
        .forbidden => .{ .forbidden = .{ .layer = try r.one() } },
        .must_contain => shapes.mustContain(c),
        .must_be_inside => blk: {
            const l = try r.two();
            break :blk .{ .must_be_inside = .{ .inner = l[0], .outer = l[1] } };
        },
        .net_spacing => spacing.netSpacing(c),
        .spacing_table => spacing.spacingTable(c),
        .attached_wide_spacing => .{ .attached_wide_spacing = .{
            .layer = try r.one(),
            .width_threshold = try r.length("width_threshold"),
            .attached = try r.length("attached"),
            .limit = try r.length("limit"),
        } },
        .edge_min_length => .{ .edge_min_length = try layerLimit(r) },
        .edge_spacing => blk: {
            const l = try r.bounded();
            break :blk .{ .edge_spacing = .{ .a = l.layer, .b = l.other, .limit = try r.length("limit") } };
        },
        .edge_enclosure => blk: {
            const l = try r.two();
            break :blk .{ .edge_enclosure = .{ .edges = l[0], .outer = l[1], .limit = try r.length("limit") } };
        },
        .count => .{ .count = .{ .layer = try r.one(), .limit = try r.count("limit", std.math.maxInt(u32)), .sense = try r.sense() } },
        .aspect_ratio => .{ .aspect_ratio = .{ .layer = try r.one(), .limit = try r.ratio("limit") } },
        .total_area => .{ .total_area = .{ .layer = try r.one(), .limit = try r.area("limit") } },
        .cut_class => shapes.cutClass(c),
        .edge_width => .{ .edge_width = try layerLimit(r) },
        .edge_facing_space => .{ .edge_facing_space = .{
            .layer = try r.one(),
            .limit = try r.length("limit"),
            .prl = if (r.stated("prl")) try r.atLeastZero("prl") else 0,
        } },
        .region_density => blk: {
            const l = try r.two();
            break :blk .{ .region_density = .{ .layer = l[0], .region = l[1], .limit = try r.ratio("limit"), .sense = try r.sense() } };
        },
        .allowed_width => shapes.allowedWidth(c),
        .min_interior_angle => .{ .min_interior_angle = .{ .layer = try optLayer(r), .limit = try r.ratio("limit") } },
        .polygon_validity => .{ .polygon_validity = .{ .layer = try optLayer(r) } },
        .min_step => shapes.minStep(c),
        .min_step_adjacent => shapes.minStepAdjacent(c),
        .tip_spacing_table => spacing.tipSpacingTable(c),
        .forbidden_spacing => spacing.forbiddenSpacing(c),
        .eol_within_spacing => spacing.eolWithinSpacing(c),
        .eol_keep_out => spacing.eolKeepOut(c),
        .eol_extension_spacing => spacing.eolExtensionSpacing(c),
        .origin => .{ .origin = .{ .layer = try r.one() } },
        .protrusion_width => .{ .protrusion_width = .{ .layer = try r.one(), .wide = try r.length("wide"), .limit = try r.length("limit") } },
        .keep_out_zone => layers_.keepOutZone(c),
        .two_width_spacing_table => spacing.twoWidthSpacingTable(c),
        .span_length => spacing.spanLength(c),
        .convex_corner_spacing => .{ .convex_corner_spacing = .{
            .layer = try r.one(),
            .corner_to_corner = try r.flag("corner_to_corner"),
            .except_eol = try r.optLength("except_eol"),
            .limit = try r.length("limit"),
        } },
        .exact_pitch => .{ .exact_pitch = .{ .layer = try r.one(), .vertical = try r.flag("vertical"), .pitch = try r.length("limit") } },
    };
}

// ---- private ----

fn lessId(_: void, a: StrId, b: StrId) bool {
    return @backingInt(a) < @backingInt(b);
}

fn layerLimit(r: Reader) Error!@import("rows.zig").LayerLimit {
    return .{ .layer = try r.one(), .limit = try r.length("limit") };
}

fn twoLayers(r: Reader) Error!@import("rows.zig").TwoLayers {
    const l = try r.two();
    return .{ .a = l[0], .b = l[1], .limit = try r.length("limit") };
}

fn plainEnclosure(r: Reader, param: []const u8) Error!@import("rows.zig").PlainEnclosure {
    const l = try r.two();
    return .{ .outer = l[0], .inner = l[1], .limit = try r.length(param) };
}

/// No layer (every drawn one), or one.
fn optLayer(r: Reader) Error!?LayerId {
    return if (r.spec.layer_len == 0) null else try r.one();
}
