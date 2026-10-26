//! The report every engine writes. In: one finding at a time from DRC, ERC
//! and LVS, and one rule row's outcome. Out: the `Violations` columns in
//! canonical order (`Violations.sortCanonical`, the byte-determinism gate)
//! and one `RuleRun` per configured rule, so a clean table can be told apart
//! from rules that never ran. Ported from crates/check/src/report/{mod,
//! violation,measure}.rs.
//!
//! Measurement layout (DOD): Rust's `Measurement` is a 32-byte enum (an
//! `i128` payload), and a row held two of them. Here a measurement is a kind
//! byte plus an `i128` payload (exact for lengths, areas and counts; the
//! `f64` bits for the rest), and the table stores the kind once per row,
//! shared by `measured` and `limit`: 33 bytes for the pair instead of 64,
//! and a row whose measured and limit differ in dimension is unrepresentable
//! (Rust only documented it). The rare fix hint lives in a sparse side table.
//!
//! Contents:
//! - `pub const Severity = enum(u8) { warning, @"error" }`
//! - `pub const Kind = enum(u8)`, `pub const LimitSense = enum(u8) { minimum, maximum }`
//! - `pub const Measurement = struct`, `Measurement.length(v: Dbu) Measurement`,
//!   `area(v: DbuArea)`, `ratio(v: f64)`, `count(v: u32)`, `voltage(v: Millivolts)`,
//!   `current(v: Microamps)`, `resistance(v: Ohms)`,
//!   `exact(m: Measurement) i128`, `float(m: Measurement) f64`,
//!   `isFinite(m: Measurement) bool`, `eql(a: Measurement, b: Measurement) bool`,
//!   `violates(m: Measurement, limit: Measurement, sense: LimitSense) bool`,
//!   `format(m: Measurement, w: *std.Io.Writer) std.Io.Writer.Error!void`
//! - `pub const Millivolts`, `pub const Microamps`, `pub const Ohms`
//! - `pub const nowhere: Point`, `pub const no_layer: LayerId`, `pub const no_shape: PolyId`
//! - `pub fn ruleId(strings: *const StrTable, name: []const u8) StrId`
//! - `pub const Violation = struct`
//! - `pub const Violations = struct`, `deinit`, `len(v: *const Violations) u32`,
//!   `push(v: *Violations, gpa: Allocator, row: Violation) Allocator.Error!void`,
//!   `get(v: *const Violations, row: u32) Violation`,
//!   `fixOf(v: *const Violations, row: u32) ?Measurement`,
//!   `setFix(v: *Violations, gpa: Allocator, row: u32, fix: Measurement) Allocator.Error!void`,
//!   `pushRow(v: *Violations, gpa: Allocator, other: *const Violations, row: u32) Allocator.Error!void`,
//!   `extend(v: *Violations, gpa: Allocator, other: *const Violations) Allocator.Error!void`,
//!   `truncate(v: *Violations, new_len: u32) void`,
//!   `sortCanonical(v: *Violations, gpa: Allocator) Allocator.Error!void`
//! - `pub const RuleRun = struct`, `pub const Outcome = union(enum)`, `pub const Verdict = struct`,
//!   `pub const refused: Verdict`, `pub const SkipReason = enum(u8)`
//! - `pub fn recordRun(gpa: Allocator, runs: *std.ArrayList(RuleRun), out: *const Violations, violations_before: u32, rule: StrId, outcome: Outcome, examined: u64) Allocator.Error!void`

const std = @import("std");
const Allocator = std.mem.Allocator;
const assert = std.debug.assert;
const geom = @import("geom");
const Dbu = geom.Dbu;
const DbuArea = geom.DbuArea;
const LayerId = geom.LayerId;
const PolyId = geom.PolyId;
const Point = geom.Point;
const StrId = geom.StrId;
const StrTable = geom.StrTable;

/// How bad a finding is. Ordered, `warning < error`, so the max over a run
/// is its worst.
pub const Severity = enum(u8) {
    /// Does not fail the run: a DRC or ERC row the deck marks `warning`.
    /// LVS never reports one.
    warning,
    /// Fails the run.
    @"error",
};

/// A measurement's dimension, in Rust's variant order (the sort key's order).
/// The electrical kinds fix a prefix, so a report column has one scale.
pub const Kind = enum(u8) {
    /// Grid units, exact: spacing, width, enclosure, extension.
    length,
    /// Square grid units, exact.
    area,
    /// Dimensionless `f64`: antenna ratios, density fractions.
    ratio,
    /// A `u32` count: vias in an array, drivers on a net.
    count,
    /// Millivolts, `f64`.
    voltage,
    /// Microamps, `f64`.
    current,
    /// Ohms, `f64`.
    resistance,

    fn isFloat(k: Kind) bool {
        return switch (k) {
            .length, .area, .count => false,
            .ratio, .voltage, .current, .resistance => true,
        };
    }
};

/// Which side of a limit is the violation; the rule's, not the measurement's.
pub const LimitSense = enum(u8) {
    /// Violated below the limit: widths, spacings.
    minimum,
    /// Violated above: densities, antenna ratios, resistances, IR drop.
    maximum,
};

pub const Millivolts = geom.Qty(.voltage, .milli);
pub const Microamps = geom.Qty(.current, .micro);
pub const Ohms = geom.Qty(.resistance, .base);

/// A measured quantity carrying its dimension. Invariant: `raw` is the exact
/// value for `length`, `area` and `count`, and the `f64`'s bits
/// (zero-extended) for every other kind; the constructors establish it.
pub const Measurement = struct {
    kind: Kind,
    raw: i128,

    pub fn length(v: Dbu) Measurement {
        return .{ .kind = .length, .raw = v };
    }

    pub fn area(v: DbuArea) Measurement {
        return .{ .kind = .area, .raw = v };
    }

    pub fn ratio(v: f64) Measurement {
        return fromFloat(.ratio, v);
    }

    pub fn count(v: u32) Measurement {
        return .{ .kind = .count, .raw = v };
    }

    pub fn voltage(v: Millivolts) Measurement {
        return fromFloat(.voltage, v.raw);
    }

    pub fn current(v: Microamps) Measurement {
        return fromFloat(.current, v.raw);
    }

    pub fn resistance(v: Ohms) Measurement {
        return fromFloat(.resistance, v.raw);
    }

    /// The value of a `length`, `area` or `count`; asserts the kind.
    pub fn exact(m: Measurement) i128 {
        assert(!m.kind.isFloat());
        return m.raw;
    }

    /// The value of a `ratio`, `voltage`, `current` or `resistance` in its
    /// fixed unit; asserts the kind.
    pub fn float(m: Measurement) f64 {
        assert(m.kind.isFloat());
        return @bitCast(@as(u64, @intCast(m.raw)));
    }

    /// False for a NaN or an infinity, which would pass every rule silently.
    /// The exact kinds are always finite.
    pub fn isFinite(m: Measurement) bool {
        return !m.kind.isFloat() or std.math.isFinite(m.float());
    }

    /// Value equality, as Rust's derived `PartialEq`: floats compare as
    /// floats (`-0 == 0`, a NaN equals nothing).
    pub fn eql(a: Measurement, b: Measurement) bool {
        if (a.kind != b.kind) return false;
        return if (a.kind.isFloat()) a.float() == b.float() else a.raw == b.raw;
    }

    /// Whether `m` violates `limit` under `sense`. Strict: a value exactly
    /// at its limit is legal under both senses. Asserts one kind and, both
    /// finite.
    pub fn violates(m: Measurement, limit: Measurement, sense: LimitSense) bool {
        assert(m.kind == limit.kind);
        assert(m.isFinite() and limit.isFinite());
        const lo, const hi = switch (sense) {
            .minimum => .{ m, limit },
            .maximum => .{ limit, m },
        };
        return if (m.kind.isFloat()) lo.float() < hi.float() else lo.raw < hi.raw;
    }

    /// With its unit, at the kind's fixed scale: `200 dbu`, `400 dbu^2`,
    /// `1800 mV`, `120 uA`, `12.4 ohm`; a ratio or count bare. Use with `{f}`.
    pub fn format(m: Measurement, w: *std.Io.Writer) std.Io.Writer.Error!void {
        switch (m.kind) {
            .length => try w.print("{d} dbu", .{m.raw}),
            .area => try w.print("{d} dbu^2", .{m.raw}),
            .ratio => try w.print("{d}", .{m.float()}),
            .count => try w.print("{d}", .{m.raw}),
            .voltage => try w.print("{f}", .{Millivolts{ .raw = m.float() }}),
            .current => try w.print("{f}", .{Microamps{ .raw = m.float() }}),
            .resistance => try w.print("{f}", .{Ohms{ .raw = m.float() }}),
        }
    }

    // ---- private ----

    fn fromFloat(kind: Kind, v: f64) Measurement {
        return .{ .kind = kind, .raw = @as(u64, @bitCast(v)) };
    }
};

/// `Violation.at` of a finding with no place (an LVS row): the origin.
pub const nowhere: Point = .{ .x = 0, .y = 0 };
/// `Violation.layer` of a finding on no layer: an LVS or system row.
pub const no_layer: LayerId = @fromBackingInt(std.math.maxInt(u16));
/// A shape column's "no shape": `shape_a` of an edge-layer or LVS finding,
/// `shape_b` of a finding naming one shape.
pub const no_shape: PolyId = @fromBackingInt(std.math.maxInt(u32));

/// One finding, as pushed and as `Violations.get` gathers it.
pub const Violation = struct {
    /// The deck's id for the rule, or the LVS report id (`lvs.*`), interned.
    rule: StrId,
    /// The layer reported on; `no_layer` for an LVS or system finding.
    layer: LayerId,
    severity: Severity,
    /// Where to look, in grid units; each rule kind picks its own point.
    at: Point,
    /// What the rule measured; the same kind as `limit`.
    measured: Measurement,
    /// The limit `measured` was held to: for a table rule, the cell applied.
    limit: Measurement,
    /// The offending shape, or `no_shape` when none can be named.
    shape_a: PolyId,
    /// The other shape of a pair, or `no_shape`.
    shape_b: PolyId,
};

/// Every violation from a run, SoA. Invariant: every row column holds `len()`
/// rows; `fix_row` ascends only until the next `setFix`, and names rows
/// below `len()`. Read the columns directly; write through the methods.
pub const Violations = struct {
    rule: std.ArrayList(StrId) = .empty,
    layer: std.ArrayList(LayerId) = .empty,
    severity: std.ArrayList(Severity) = .empty,
    at: std.ArrayList(Point) = .empty,
    /// One kind per row, shared by `measured` and `limit`.
    kind: std.ArrayList(Kind) = .empty,
    measured: std.ArrayList(i128) = .empty,
    limit: std.ArrayList(i128) = .empty,
    shape_a: std.ArrayList(PolyId) = .empty,
    shape_b: std.ArrayList(PolyId) = .empty,
    /// Sparse fix hints: row `fix_row[i]` has `fix_value[i]` (for an antenna
    /// finding, the least diode area that clears it; catalog ERC-A15).
    fix_row: std.ArrayList(u32) = .empty,
    fix_value: std.ArrayList(Measurement) = .empty,

    pub fn deinit(v: *Violations, gpa: Allocator) void {
        inline for (@typeInfo(Violations).@"struct".field_names) |name| @field(v, name).deinit(gpa);
    }

    /// Rows; alone, zero does not mean clean (see `RuleRun`).
    pub fn len(v: *const Violations) u32 {
        return @intCast(v.rule.items.len);
    }

    /// Appends one row. Asserts one kind for measured and limit, both finite
    /// (a NaN compares false against every limit and reads as clean), and
    /// the row count stays a `u32`. On error the table is unchanged.
    pub fn push(v: *Violations, gpa: Allocator, row: Violation) Allocator.Error!void {
        assert(row.measured.kind == row.limit.kind);
        assert(row.measured.isFinite() and row.limit.isFinite());
        assert(v.rule.items.len < std.math.maxInt(u32));
        try v.ensureUnusedCapacity(gpa, 1);
        v.rule.appendAssumeCapacity(row.rule);
        v.layer.appendAssumeCapacity(row.layer);
        v.severity.appendAssumeCapacity(row.severity);
        v.at.appendAssumeCapacity(row.at);
        v.kind.appendAssumeCapacity(row.measured.kind);
        v.measured.appendAssumeCapacity(row.measured.raw);
        v.limit.appendAssumeCapacity(row.limit.raw);
        v.shape_a.appendAssumeCapacity(row.shape_a);
        v.shape_b.appendAssumeCapacity(row.shape_b);
    }

    /// Row `row`, gathered from every column; the fix hint is `fixOf`'s.
    pub fn get(v: *const Violations, row: u32) Violation {
        const kind = v.kind.items[row];
        return .{
            .rule = v.rule.items[row],
            .layer = v.layer.items[row],
            .severity = v.severity.items[row],
            .at = v.at.items[row],
            .measured = .{ .kind = kind, .raw = v.measured.items[row] },
            .limit = .{ .kind = kind, .raw = v.limit.items[row] },
            .shape_a = v.shape_a.items[row],
            .shape_b = v.shape_b.items[row],
        };
    }

    /// Row `row`'s fix hint, or null for most rows.
    /// ponytail: a linear scan of the sparse hints, O(hints) per call; index
    /// it if a writer ever reads hints for many rows of a large table.
    pub fn fixOf(v: *const Violations, row: u32) ?Measurement {
        for (v.fix_row.items, v.fix_value.items) |r, f| if (r == row) return f;
        return null;
    }

    /// Attaches (or replaces) row `row`'s fix hint. Asserts the row exists
    /// and the hint is finite.
    pub fn setFix(v: *Violations, gpa: Allocator, row: u32, fix: Measurement) Allocator.Error!void {
        assert(row < v.len() and fix.isFinite());
        for (v.fix_row.items, v.fix_value.items) |r, *f| if (r == row) {
            f.* = fix;
            return;
        };
        try v.fix_row.ensureUnusedCapacity(gpa, 1);
        try v.fix_value.append(gpa, fix);
        v.fix_row.appendAssumeCapacity(row);
    }

    /// Appends row `row` of `other`, its fix hint included.
    pub fn pushRow(v: *Violations, gpa: Allocator, other: *const Violations, row: u32) Allocator.Error!void {
        try v.push(gpa, other.get(row));
        if (other.fixOf(row)) |fix| try v.setFix(gpa, v.len() - 1, fix);
    }

    /// Appends `other`'s rows after this table's, in their order. The result
    /// is not canonical even when both inputs were. On error the table is
    /// unchanged.
    pub fn extend(v: *Violations, gpa: Allocator, other: *const Violations) Allocator.Error!void {
        const base = v.len();
        assert(@as(u64, base) + other.len() <= std.math.maxInt(u32));
        try v.ensureUnusedCapacity(gpa, other.len());
        try v.fix_row.ensureUnusedCapacity(gpa, other.fix_row.items.len);
        try v.fix_value.ensureUnusedCapacity(gpa, other.fix_value.items.len);
        inline for (row_columns) |name| @field(v, name).appendSliceAssumeCapacity(@field(other, name).items);
        for (other.fix_row.items) |r| v.fix_row.appendAssumeCapacity(base + r);
        v.fix_value.appendSliceAssumeCapacity(other.fix_value.items);
    }

    /// Drops every row from `new_len` on, with their fix hints.
    pub fn truncate(v: *Violations, new_len: u32) void {
        assert(new_len <= v.len());
        inline for (row_columns) |name| @field(v, name).shrinkRetainingCapacity(new_len);
        var kept: usize = 0;
        for (v.fix_row.items, v.fix_value.items) |r, f| {
            if (r >= new_len) continue;
            v.fix_row.items[kept] = r;
            v.fix_value.items[kept] = f;
            kept += 1;
        }
        v.fix_row.shrinkRetainingCapacity(kept);
        v.fix_value.shrinkRetainingCapacity(kept);
    }

    /// Establishes the canonical order: rule id, layer, `at.y`, `at.x`,
    /// `shape_a`, `shape_b` (no shape first, as Rust's `None`), then every
    /// remaining field. The key is total, so the order depends only on the
    /// set of rows, not on input order or thread count. Rule ids compare as
    /// interned ids, so the order also depends on the string table.
    /// `O(n log n)`; rebuilds every column through `gpa` scratch.
    pub fn sortCanonical(v: *Violations, gpa: Allocator) Allocator.Error!void {
        const n = v.len();
        const perm = try gpa.alloc(u32, n);
        defer gpa.free(perm);
        for (perm, 0..) |*p, i| p.* = @intCast(i);
        std.mem.sortUnstable(u32, perm, v, rowLess);
        inline for (row_columns) |name| try permute(gpa, perm, &@field(v, name));
        // A hint follows its row: new row of old row r is inverse[r].
        const inverse = try gpa.alloc(u32, n);
        defer gpa.free(inverse);
        for (perm, 0..) |old, new| inverse[old] = @intCast(new);
        for (v.fix_row.items) |*r| r.* = inverse[r.*];
    }

    // ---- private ----

    const row_columns = .{ "rule", "layer", "severity", "at", "kind", "measured", "limit", "shape_a", "shape_b" };

    fn ensureUnusedCapacity(v: *Violations, gpa: Allocator, n: usize) Allocator.Error!void {
        inline for (row_columns) |name| try @field(v, name).ensureUnusedCapacity(gpa, n);
    }

    /// Strict weak order on rows by the canonical key, then by row index, so
    /// equal keys keep arrival order and the unstable sort is stable.
    fn rowLess(v: *const Violations, a: u32, b: u32) bool {
        const ka = rowKey(v, a);
        const kb = rowKey(v, b);
        inline for (ka, kb) |x, y| if (x != y) return x < y;
        return a < b;
    }

    fn rowKey(v: *const Violations, row: u32) [11]i128 {
        const kind = v.kind.items[row];
        return .{
            @backingInt(v.rule.items[row]),
            @backingInt(v.layer.items[row]),
            v.at.items[row].y,
            v.at.items[row].x,
            @backingInt(v.shape_a.items[row]),
            shapeKey(v.shape_b.items[row]),
            @backingInt(v.severity.items[row]),
            @backingInt(kind),
            valueKey(kind, v.measured.items[row]),
            @backingInt(kind),
            valueKey(kind, v.limit.items[row]),
        };
    }
};

/// What a rule did, whether or not it found anything: "clean" means it ran,
/// examined at least one item, and found nothing.
pub const RuleRun = struct {
    /// The deck's id for the rule, or the LVS report id, interned.
    rule: StrId,
    /// Anything but `.ran` fails the run.
    outcome: Outcome,
    /// Items examined: polygons, figures, pairs, edges, windows...; zero with
    /// `.ran` means there was nothing to measure, not "did not run".
    examined: u64,
    /// Rows this rule added, saturating at `maxInt(u32)`.
    violations: u32,
};

/// Whether a rule executed; anything but `.ran` fails the run.
pub const Outcome = union(enum) {
    /// Executed to completion.
    ran,
    /// A required input was absent; never collapsed into a clean result.
    skipped: SkipReason,
    /// The input was outside what the tool represents exactly: fail closed.
    refused,
};

/// How one rule row ended, and how many of its items it examined: a
/// `RuleRun` before its violation count is known.
pub const Verdict = struct { outcome: Outcome, examined: u64 };

/// The verdict of input a rule cannot represent exactly.
pub const refused: Verdict = .{ .outcome = .refused, .examined = 0 };

/// Why a rule did not run; each fails the run.
pub const SkipReason = enum(u8) {
    /// The rule needs design intent and none was supplied.
    no_design_intent,
    /// The deck carries no limits for this check.
    not_in_deck,
    /// A layer the rule needs holds no geometry.
    empty_layer,
    /// The deck is staged and an earlier stage found an error.
    earlier_stage,
};

/// The interned id of rule `name`, or `maxInt(u32)` when its engine missed
/// interning it: `StrTable.resolve` then asserts rather than misattributing.
pub fn ruleId(strings: *const StrTable, name: []const u8) StrId {
    return strings.get(name) orelse @fromBackingInt(std.math.maxInt(u32));
}

/// Closes one rule row: appends its `RuleRun`, the violation count being
/// `out.len() - violations_before` (saturating). Asserts a rule that
/// reported a finding examined at least one item.
pub fn recordRun(gpa: Allocator, runs: *std.ArrayList(RuleRun), out: *const Violations, violations_before: u32, rule: StrId, outcome: Outcome, examined: u64) Allocator.Error!void {
    assert(violations_before <= out.len());
    const pushed = out.len() - violations_before;
    assert(pushed == 0 or examined > 0);
    try runs.append(gpa, .{ .rule = rule, .outcome = outcome, .examined = examined, .violations = pushed });
}

// ---- private ----

/// No shape before every shape, as Rust's `Option::None < Some`.
fn shapeKey(p: PolyId) i128 {
    return if (p == no_shape) -1 else @backingInt(p);
}

/// A total order over a payload: the exact value, or an `f64`'s bits mapped
/// to IEEE-754 total order.
fn valueKey(kind: Kind, raw: i128) i128 {
    if (!kind.isFloat()) return raw;
    const bits: u64 = @intCast(raw);
    const smear = 0 -% (bits >> 63);
    return bits ^ (smear | (1 << 63));
}

/// `column[i] = old[perm[i]]`.
fn permute(gpa: Allocator, perm: []const u32, column: anytype) Allocator.Error!void {
    const T = @TypeOf(column.items[0]);
    const next = try gpa.alloc(T, perm.len);
    for (next, perm) |*slot, old| slot.* = column.items[old];
    @memcpy(column.items, next);
    gpa.free(next);
}

test "a ratio, a voltage and a current round-trip their bits" {
    // Oracle: law. A measurement built from a value reads back that value
    // bit for bit, negative zero and subnormals included.
    for ([_]f64{ -0.0, 0.0, 5e-324, -3.5, 1e300 }) |x| {
        try std.testing.expectEqual(@as(u64, @bitCast(x)), @as(u64, @bitCast(Measurement.ratio(x).float())));
        try std.testing.expectEqual(@as(u64, @bitCast(x)), @as(u64, @bitCast(Measurement.voltage(.{ .raw = x }).float())));
    }
}
