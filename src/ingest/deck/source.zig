//! A deck as names: what the parser reads, what a deck built in code holds,
//! and what the printer writes, before `lower` resolves it to a `Deck`.
//! Every value is already in its engine unit (lengths in grid units of the
//! layout grid the deck was read for), but layers, models and rule ids are
//! still names. Every list grows in the arena its owner was built in.
//! Ported from crates/ingest/src/deck/source.rs (types) and mod.rs (`LvsSrc`).
//!
//! Contents:
//! - `pub const DeckSource`, `DrawnLayer`, `PexRow`, `Temperature`, `StageSource`, `WaiverSource`
//! - `pub const CornerSource`, `DerivedSource`, `RuleSource`, `NamedSource`, `ParamSource`
//! - `pub const ConnectivitySource`, `ViaSource`, `LabelSource`, `DeviceSource`, `MatchingSource`, `StackSource`
//! - `pub const LvsSrc`, `ToleranceSrc`, `RangeSrc`, `CountSrc`, `LdeSrc`, `LdeWellSrc`, `ModelPin`, `NamePair`,
//!   `LvsSrc.defaultTolerance(s: *LvsSrc, fraction: f64) ?[]const u8`,
//!   `LvsSrc.addBlackbox(s: *LvsSrc, arena: Allocator, pattern: []const u8) Allocator.Error!?[]const u8`,
//!   `LvsSrc.addSupply(s: *LvsSrc, arena: Allocator, names: []const []const u8) Allocator.Error!?[]const u8`,
//!   `LvsSrc.filterUnused(s: *LvsSrc, arena: Allocator, options: []const UnusedFilter) Allocator.Error!?[]const u8`

const std = @import("std");
const Allocator = std.mem.Allocator;
const geom = @import("geom");
const Dbu = geom.Dbu;
const tables = @import("tables.zig");
const DerivedOp = @import("layers.zig").DerivedOp;
const ParamValue = tables.ParamValue;
const UnusedFilter = tables.UnusedFilter;

/// A whole deck by name, in statement order.
pub const DeckSource = struct {
    /// `grid <length>`, nm: what every deck length is a multiple of.
    grid_nm: ?f64 = null,
    /// Drawn layers; their ids are assigned ascending by name.
    layers: std.ArrayList(DrawnLayer) = .empty,
    /// `ignore gds(L, D)` pairs: distinct, none a drawn layer's.
    ignored: std.ArrayList([2]u16) = .empty,
    /// Derived layers in declaration order, which is their id order; inner
    /// operations of a nested expression named `<layer>#k` (post-order) and
    /// a layer expression inside a rule `<rule id>@k`.
    derived: std.ArrayList(DerivedSource) = .empty,
    /// Text and cell-name patterns, indexed by `with_text`'s `text` and
    /// `in_cells`' `first..first + count`.
    texts: std.ArrayList([]const u8) = .empty,
    /// Every rule, in deck order (a `for` loop's in iteration order).
    rules: std.ArrayList(RuleSource) = .empty,
    connectivity: ConnectivitySource = .{},
    devices: std.ArrayList(DeviceSource) = .empty,
    /// The `matching` statements, one per model.
    matching: std.ArrayList(MatchingSource) = .empty,
    /// The `pex` rows, each a layer name and its values.
    pex: std.ArrayList(PexRow) = .empty,
    /// `temperature T nominal T0`, kelvin, both positive.
    temperature: ?Temperature = null,
    lvs: LvsSrc = .{},
    extraction: ?tables.Extraction = null,
    corners: std.ArrayList(CornerSource) = .empty,
    /// The `stage` lines, each with the ids of the rules written after it.
    stages: std.ArrayList(StageSource) = .empty,
    waivers: std.ArrayList(WaiverSource) = .empty,
    /// `boundary <layer>`.
    boundary: ?[]const u8 = null,
    /// `netlist_scale <length>`, nm.
    netlist_scale_nm: ?f64 = null,
    pex_models: tables.PexModels = .{},
    edits: tables.Edits = .{},
    reports: tables.Reports = .{},
};

pub const DrawnLayer = struct { name: []const u8, stream: [2]u16 };
pub const PexRow = struct { layer: []const u8, row: StackSource };
pub const Temperature = struct { operating_k: f64, nominal_k: f64 };
pub const StageSource = struct { name: []const u8, rules: std.ArrayList([]const u8) = .empty };
pub const WaiverSource = struct { rule: []const u8, layer: []const u8 };

/// One `corner` line: `corner <corner> <layer> <key> <value> ..`.
pub const CornerSource = struct { corner: []const u8, layer: []const u8, values: tables.CornerValues };

/// One derived layer: `name = layers[0] op layers[1] ..`.
pub const DerivedSource = struct {
    name: []const u8,
    op: DerivedOp,
    /// The operands, each a layer declared before this one.
    layers: []const []const u8,
};

/// One rule: an engine kind with its layers and named parameters.
pub const RuleSource = struct {
    /// Unique in the deck.
    id: []const u8,
    /// The engine kind name (`min_width`).
    kind: []const u8,
    /// The layer arguments in the order the engine kind takes them.
    layers: []const []const u8,
    /// The parameters by engine name; a list is one row per element, `none` no row.
    params: []const NamedSource,
};

pub const NamedSource = struct { name: []const u8, value: ParamSource };

/// A parameter value: converted, or a name still to resolve.
pub const ParamSource = union(enum) {
    /// A value in its engine unit; never `.layer` or `.model`.
    value: ParamValue,
    /// A layer, by name.
    layer: []const u8,
    /// A quoted name: a device model, or for a `names` param a name that is not one.
    model: []const u8,
};

/// The `connect` statements.
pub const ConnectivitySource = struct {
    conductors: std.ArrayList([]const u8) = .empty,
    intra_layer_touch: bool = false,
    global: std.ArrayList([]const u8) = .empty,
    vias: std.ArrayList(ViaSource) = .empty,
    labels: std.ArrayList(LabelSource) = .empty,
};

/// `connect via <layer> [<a>, <b>]`.
pub const ViaSource = struct { layer: []const u8, connects: [2][]const u8 };
/// `connect label <layer> names <conductor>`.
pub const LabelSource = struct { layer: []const u8, names: []const u8 };

/// One `device` statement.
pub const DeviceSource = struct {
    kind: tables.DeviceKind,
    marker: []const u8,
    model: []const u8,
    /// In role order (`DeviceRecognition`).
    terminals: []const []const u8,
    value: tables.DeviceValue = .{},
    /// `fins <layer>`: a `mos` sized by the fins under its channel.
    fins: ?[]const u8 = null,
};

/// One `matching` statement: `matching "<model>" pair|single <key> <value> ..`.
pub const MatchingSource = struct { model: []const u8, basis: tables.MatchingBasis, stated: tables.Matching };

/// One `pex` row in `ProcessStack`'s units; 0.0 is "not stated", the sheet
/// resistance at the deck's nominal temperature.
pub const StackSource = struct {
    thickness_nm: f64 = 0,
    height_nm: f64 = 0,
    sheet_res_ohm_sq: f64 = 0,
    area_cap_af_um2: f64 = 0,
    fringe_cap_af_um: f64 = 0,
    dielectric_k: f64 = 0,
    /// `(tc1 per K, tc2 per K²)`, together or not at all.
    tc: ?[2]f64 = null,
};

/// The `lvs` statements as written, models unresolved.
pub const LvsSrc = struct {
    default_tolerance: ?f64 = null,
    tolerance: std.ArrayList(ToleranceSrc) = .empty,
    /// `(model, parameter)`, the parameter lowercase.
    ignore_parameter: std.ArrayList(NamePair) = .empty,
    asymmetric: std.ArrayList([]const u8) = .empty,
    /// `(model, pin, pin)`, the pins as written.
    permute: std.ArrayList(ModelPin) = .empty,
    ignore: std.ArrayList([]const u8) = .empty,
    ignore_shorted: std.ArrayList([]const u8) = .empty,
    ports_by_name: bool = false,
    range: std.ArrayList(RangeSrc) = .empty,
    /// `lvs topology`, once: true relaxed, false strict.
    topology: ?bool = null,
    connect_implicit: std.ArrayList([]const u8) = .empty,
    connect_explicit: std.ArrayList([]const []const u8) = .empty,
    /// Ohms.
    max_res: ?f64 = null,
    /// aF as the deck states it.
    min_caps: ?f64 = null,
    /// `(layout label, reference net)`.
    same_nets: std.ArrayList(NamePair) = .empty,
    count: std.ArrayList(CountSrc) = .empty,
    recognize_gates: bool = false,
    split_gates: bool = false,
    blackbox: std.ArrayList([]const u8) = .empty,
    filter_unused: std.ArrayList(UnusedFilter) = .empty,
    supply: std.ArrayList([]const u8) = .empty,
    lde: std.ArrayList(LdeSrc) = .empty,

    /// Sets `lvs tolerance default relative r`; the reason when refused: a
    /// fraction outside 0 to 1, or a default already stated.
    pub fn defaultTolerance(s: *LvsSrc, fraction: f64) ?[]const u8 {
        if (!(fraction >= 0.0 and fraction <= 1.0)) return "a relative tolerance is a fraction: 0 to 1, or 0% to 100%";
        if (s.default_tolerance != null) {
            s.default_tolerance = fraction;
            return "the default tolerance is already stated";
        }
        s.default_tolerance = fraction;
        return null;
    }

    /// Adds `lvs blackbox "pattern"`; the reason when refused: empty, holding
    /// `[`, `]`, `{`, `}` or `\` (which KLayout reads as classes,
    /// alternatives and escapes), or already stated.
    pub fn addBlackbox(s: *LvsSrc, arena: Allocator, pattern: []const u8) Allocator.Error!?[]const u8 {
        if (pattern.len == 0) return "an empty pattern matches no cell";
        if (std.mem.indexOfAny(u8, pattern, "[]{}\\") != null) return "a cell-name pattern takes `*` and `?` only; `[`, `]`, `{`, `}` and `\\` are refused";
        for (s.blackbox.items) |stated| if (std.mem.eql(u8, stated, pattern)) return try std.fmt.allocPrint(arena, "\"{s}\" is already a black box", .{pattern});
        try s.blackbox.append(arena, pattern);
        return null;
    }

    /// Adds `lvs supply` names; the reason when refused: none, or a name
    /// already stated.
    pub fn addSupply(s: *LvsSrc, arena: Allocator, names: []const []const u8) Allocator.Error!?[]const u8 {
        if (names.len == 0) return "supply names one net or more, each in quotes";
        for (names, 0..) |n, at| {
            const twice = for (names[0..at]) |m| {
                if (std.mem.eql(u8, m, n)) break true;
            } else for (s.supply.items) |m| {
                if (std.mem.eql(u8, m, n)) break true;
            } else false;
            if (twice) return try std.fmt.allocPrint(arena, "\"{s}\" is already a supply", .{n});
        }
        try s.supply.appendSlice(arena, names);
        return null;
    }

    /// Sets `lvs filter_unused` to `options`; the reason when refused: none,
    /// one given twice, or a second statement.
    pub fn filterUnused(s: *LvsSrc, arena: Allocator, options: []const UnusedFilter) Allocator.Error!?[]const u8 {
        if (s.filter_unused.items.len > 0) return "the unused filters are already stated";
        if (options.len == 0) return "filter_unused takes ae, af, ag, c or u, one or more";
        for (options, 0..) |o, at| {
            if (std.mem.indexOfScalar(UnusedFilter, options[0..at], o) != null) return try std.fmt.allocPrint(arena, "`{s}` is given twice", .{o.name()});
        }
        try s.filter_unused.appendSlice(arena, options);
        return null;
    }
};

/// `lvs tolerance "model" param relative r absolute a`, the absolute part in
/// the deck's unit (`absoluteUnit`).
pub const ToleranceSrc = struct { model: []const u8, param: []const u8, relative: f64, absolute: f64 };
/// `(model, parameter, min, max)`, the parameter lowercase.
pub const RangeSrc = struct { model: []const u8, param: []const u8, min: ?tables.LvsLimit, max: ?tables.LvsLimit };
/// `lvs count`: `(model, min, max)`.
pub const CountSrc = struct { model: []const u8, min: ?u32, max: ?u32 };
/// `lvs lde`: `(model, od layer, max, (well layer, scref))` on the layout's grid.
pub const LdeSrc = struct { model: []const u8, od: []const u8, max: Dbu, well: ?LdeWellSrc };
pub const LdeWellSrc = struct { layer: []const u8, scref: Dbu };
pub const ModelPin = struct { model: []const u8, a: []const u8, b: []const u8 };
pub const NamePair = struct { a: []const u8, b: []const u8 };
