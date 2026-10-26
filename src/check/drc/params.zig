//! One deck rule row's layers and parameters, read by type: what every kind
//! builder calls. In: the parsed `RuleTable`, one `RuleSpec`, the string
//! table. Out: typed values, or the named error with the row and parameter
//! in the `Diagnostic`. Each reader takes a value of its type only; what
//! values a rule may hold is `validate.zig`'s. Ported from the closures at
//! the top of crates/check/src/drc/ruleset.rs `RuleSet::from_deck`.
//!
//! Contents:
//! - `pub const Error`, `pub const Diagnostic = struct`
//! - `pub const Reader = struct`, `fail(r, err: Error, param: []const u8) Error`,
//!   `value(r, param: []const u8) Error!ParamValue`, `optional(r, param: []const u8) ?ParamValue`,
//!   `stated(r, param: []const u8) bool`, `length(r, param) Error!Dbu`, `atLeastZero(r, param) Error!Dbu`,
//!   `optLength(r, param) Error!?Dbu`, `area(r, param) Error!DbuArea`, `ratio(r, param) Error!f64`,
//!   `flag(r, param) Error!bool`, `optFlag(r, param) Error!bool`, `count(r, param, ceiling: u32) Error!u32`,
//!   `list(r, comptime tag: std.meta.Tag(ParamValue), param) Error![]...`, `layerCount(r, expected: u32) Error!void`,
//!   `layer(r, nth: u32) LayerId`, `one(r) Error!LayerId`, `two(r) Error![2]LayerId`,
//!   `bounded(r) Error!Bounded`, `pub const Bounded`, `sense(r) Error!LimitSense`, `wire(r) Error!WireBand`,
//!   `badTable(r) Error`, `nonPositive(r, v: i64) Error`, `typed(r, comptime tag, param)`

const std = @import("std");
const Allocator = std.mem.Allocator;
const geom = @import("geom");
const Dbu = geom.Dbu;
const DbuArea = geom.DbuArea;
const LayerId = geom.LayerId;
const StrId = geom.StrId;
const StrTable = geom.StrTable;
const deck = @import("ingest").deck;
const ParamValue = deck.ParamValue;
const RuleSpec = deck.RuleSpec;
const RuleTable = deck.RuleTable;
const LimitSense = @import("../report.zig").LimitSense;
const rows = @import("rows.zig");
const WireBand = rows.WireBand;

/// Why a deck's rows could not be typed. Load time only: geometry a rule
/// cannot handle is that rule's refused run, not an error.
pub const Error = error{
    /// A row's kind is in neither the DRC nor the ERC kind list.
    UnknownKind,
    /// A required parameter is absent; for `angle`, the allowed list is empty.
    MissingParam,
    /// A parameter holds the wrong kind of value, or a count too large for
    /// its field.
    WrongParamType,
    /// A row names too few or too many layers for its kind.
    WrongLayerCount,
    /// A length, area or fraction is zero or negative, a fraction is not
    /// finite, or a required count is zero.
    NonPositiveLimit,
    /// An allowed angle is not a multiple of 45 degrees.
    UnrepresentableAngle,
    /// Two deck rows, DRC or ERC, share an id.
    DuplicateRule,
    /// A row's table, band list, range or pattern is not well formed.
    BadTable,
    /// An ERC fraction outside `0 ..= 1`.
    NotAFraction,
} || Allocator.Error;

/// What the error names: the row always, the rest as the error says.
pub const Diagnostic = struct {
    /// The row's id as the deck spells it, interned.
    rule: StrId = @fromBackingInt(std.math.maxInt(u32)),
    /// `UnknownKind`: the kind the row names.
    kind: StrId = @fromBackingInt(std.math.maxInt(u32)),
    /// `MissingParam`, `WrongParamType`, and an ERC row's
    /// `NonPositiveLimit` and `NotAFraction`: the engine parameter name.
    param: []const u8 = "",
    /// `WrongLayerCount`: layers the kind takes (the larger where one is
    /// optional), and layers the row names.
    expected: u32 = 0,
    found: u32 = 0,
    /// `NonPositiveLimit`: the offending value, for display (a fraction
    /// truncated toward zero, NaN as 0).
    limit: i64 = 0,
    /// `UnrepresentableAngle`: the angle reduced modulo 360.
    degrees: i32 = 0,
    /// An ERC row's `BadTable`: what is out of order.
    why: []const u8 = "",
};

/// A density layer and its optional die boundary.
pub const Bounded = struct { layer: LayerId, other: ?LayerId };

/// Reads one row. `scratch` holds lists `list` returns until the caller
/// resets it.
pub const Reader = struct {
    scratch: Allocator,
    table: RuleTable,
    spec: RuleSpec,
    strings: *const StrTable,
    diag: *Diagnostic,

    /// Records `param` on the row and returns `err`.
    pub fn fail(r: Reader, err: Error, param: []const u8) Error {
        r.diag.* = .{ .rule = r.spec.id, .kind = r.spec.kind, .param = param };
        return err;
    }

    pub fn badTable(r: Reader) Error {
        return r.fail(error.BadTable, "");
    }

    pub fn value(r: Reader, param: []const u8) Error!ParamValue {
        return r.optional(param) orelse r.fail(error.MissingParam, param);
    }

    /// A parameter a row may leave out (`none` in the deck).
    pub fn optional(r: Reader, param: []const u8) ?ParamValue {
        const name = r.strings.get(param) orelse return null;
        return r.table.findParam(r.spec, name);
    }

    pub fn stated(r: Reader, param: []const u8) bool {
        return r.optional(param) != null;
    }

    pub fn length(r: Reader, param: []const u8) Error!Dbu {
        return r.typed(.length, param);
    }

    /// A length that may be 0: a run a pair must exceed.
    pub fn atLeastZero(r: Reader, param: []const u8) Error!Dbu {
        const v = try r.length(param);
        if (v < 0) return r.nonPositive(v);
        return v;
    }

    /// A length when stated, else null.
    pub fn optLength(r: Reader, param: []const u8) Error!?Dbu {
        return if (r.stated(param)) try r.length(param) else null;
    }

    pub fn area(r: Reader, param: []const u8) Error!DbuArea {
        return r.typed(.area, param);
    }

    pub fn ratio(r: Reader, param: []const u8) Error!f64 {
        return r.typed(.ratio, param);
    }

    pub fn flag(r: Reader, param: []const u8) Error!bool {
        return r.typed(.flag, param);
    }

    /// A flag that is false when absent.
    pub fn optFlag(r: Reader, param: []const u8) Error!bool {
        return r.stated(param) and try r.flag(param);
    }

    /// A count no greater than `ceiling`.
    pub fn count(r: Reader, param: []const u8, ceiling: u32) Error!u32 {
        const v = try r.typed(.count, param);
        return if (v <= ceiling) v else r.fail(error.WrongParamType, param);
    }

    /// Every value the row states under `param`, in order (a list's
    /// elements), each of variant `tag`; in `scratch`.
    pub fn list(r: Reader, comptime tag: std.meta.Tag(ParamValue), param: []const u8) Error![]@FieldType(ParamValue, @tagName(tag)) {
        var out: std.ArrayList(@FieldType(ParamValue, @tagName(tag))) = .empty;
        const name = r.strings.get(param) orelse return out.items;
        for (r.table.paramsOf(r.spec)) |p| {
            if (p.name != name) continue;
            if (p.value != tag) return r.fail(error.WrongParamType, param);
            try out.append(r.scratch, @field(p.value, @tagName(tag)));
        }
        return out.items;
    }

    pub fn layerCount(r: Reader, expected: u32) Error!void {
        if (r.spec.layer_len == expected) return;
        r.diag.* = .{ .rule = r.spec.id, .kind = r.spec.kind, .expected = expected, .found = r.spec.layer_len };
        return error.WrongLayerCount;
    }

    pub fn layer(r: Reader, nth: u32) LayerId {
        return r.table.layersOf(r.spec)[nth];
    }

    pub fn one(r: Reader) Error!LayerId {
        try r.layerCount(1);
        return r.layer(0);
    }

    pub fn two(r: Reader) Error![2]LayerId {
        try r.layerCount(2);
        return .{ r.layer(0), r.layer(1) };
    }

    /// One layer, then an optional second (a die boundary, another layer).
    pub fn bounded(r: Reader) Error!Bounded {
        if (r.spec.layer_len == 1) return .{ .layer = r.layer(0), .other = null };
        const both = try r.two();
        return .{ .layer = both[0], .other = both[1] };
    }

    /// `maximum: true|false` as a limit's sense.
    pub fn sense(r: Reader) Error!LimitSense {
        return if (try r.flag("maximum")) .maximum else .minimum;
    }

    /// An enclosure's optional wire band and LEF selections.
    pub fn wire(r: Reader) Error!WireBand {
        const from = try r.optLength("wire_width") orelse 0;
        const below = try r.optLength("wire_below");
        const overhang: [2]?Dbu = .{ try r.optLength("length_from"), try r.optLength("length_below") };
        if (below) |hi| if (hi <= from) return r.nonPositive(hi - from);
        if (overhang[1]) |hi| if (hi <= (overhang[0] orelse 0)) return r.nonPositive(hi - (overhang[0] orelse 0));
        const extra_cut: ?rows.ExtraCut = if (try r.optLength("extra_cut_within")) |within| blk: {
            const v = r.optional("extra_cut_other") orelse return r.fail(error.WrongParamType, "extra_cut_other");
            if (v != .layer) return r.fail(error.WrongParamType, "extra_cut_other");
            const other = v.layer;
            const only = if (r.optional("extra_cut_only")) |o| o == .flag and o.flag else false;
            break :blk .{ .within = within, .other = other, .only = only };
        } else null;
        return .{ .from = from, .below = below, .extra_cut = extra_cut, .length = overhang };
    }

    /// Records `v` as a limit that is not positive.
    pub fn nonPositive(r: Reader, v: i64) Error {
        r.diag.* = .{ .rule = r.spec.id, .kind = r.spec.kind, .limit = v };
        return error.NonPositiveLimit;
    }

    /// The value under `param`, of variant `tag` only.
    pub fn typed(r: Reader, comptime tag: std.meta.Tag(ParamValue), param: []const u8) Error!@FieldType(ParamValue, @tagName(tag)) {
        const v = try r.value(param);
        return if (v == tag) @field(v, @tagName(tag)) else r.fail(error.WrongParamType, param);
    }
};
