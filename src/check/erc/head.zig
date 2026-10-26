//! The two columns every ERC rule table has (`RuleHead`: the deck id and
//! severity per row), the design every rule reads, and the run records
//! every kind shares: a whole table recorded skipped or refused, and one
//! violation per flagged net. In: a table's head, the violations so far.
//! Out: `RuleRun`s and violations. Ported from crates/check/src/erc/mod.rs
//! (`Design`, `fill_rows`, `skip_rows`, `push_net_violations`) and
//! ruleset.rs (`RuleHead`, `no_temperature`).
//!
//! Contents:
//! - `pub const Design = struct { store, nets, devices }`
//! - `pub const RuleHead = struct`, `deinit`, `len(h) u32`, `push(h, gpa: Allocator, rule: StrId, severity: Severity) Allocator.Error!void`
//! - `pub const Record = struct { gpa, out, runs }`, `fillRows(r, head: *const RuleHead, outcome: Outcome) Allocator.Error!void`,
//!   `skipRows(r, head) Allocator.Error!void`, `noTemperature(r, usable: bool, head) Allocator.Error!void`,
//!   `run(r, rule: StrId, before: u32, outcome: Outcome, examined: u64) Allocator.Error!void`,
//!   `netViolations(r, design: Design, flagged: []const u32, rule: StrId, severity: Severity, measured: Measurement, limit: Measurement) Allocator.Error!void`

const std = @import("std");
const Allocator = std.mem.Allocator;
const geom = @import("geom");
const StrId = geom.StrId;
const GeometryStore = geom.GeometryStore;
const report = @import("../report.zig");
const Violations = report.Violations;
const RuleRun = report.RuleRun;
const Outcome = report.Outcome;
const Severity = report.Severity;
const Measurement = report.Measurement;
const net_ = @import("../topology/net.zig");
const NetId = net_.NetId;
const NetTable = net_.NetTable;
const DeviceTable = @import("../topology/device.zig").DeviceTable;

/// The extracted layout every rule reads.
/// ponytail: the same three fields as lvs/project.zig's `Design`; one type
/// once the engine spine (wave 5) owns it below both.
pub const Design = struct {
    store: *const GeometryStore,
    nets: *const NetTable,
    devices: *const DeviceTable,
};

/// The deck id and severity of each row of one kind's table. Invariant:
/// the columns are parallel; every other per-row column of the table has
/// `len()` rows.
pub const RuleHead = struct {
    rule: std.ArrayList(StrId) = .empty,
    /// `.warning` when the deck row is marked `warning`.
    severity: std.ArrayList(Severity) = .empty,

    pub fn deinit(h: *RuleHead, gpa: Allocator) void {
        h.rule.deinit(gpa);
        h.severity.deinit(gpa);
    }

    pub fn len(h: *const RuleHead) u32 {
        return @intCast(h.rule.items.len);
    }

    pub fn push(h: *RuleHead, gpa: Allocator, rule: StrId, severity: Severity) Allocator.Error!void {
        std.debug.assert(h.rule.items.len < std.math.maxInt(u32));
        try h.rule.append(gpa, rule);
        try h.severity.append(gpa, severity);
    }
};

/// Where a rule records: its violations and its runs.
pub const Record = struct {
    gpa: Allocator,
    out: *Violations,
    runs: *std.ArrayList(RuleRun),

    /// One row's run: the violations since `before`.
    pub fn run(r: Record, rule: StrId, before: u32, outcome: Outcome, examined: u64) Allocator.Error!void {
        try report.recordRun(r.gpa, r.runs, r.out, before, rule, outcome, examined);
    }

    /// Every row of a table recorded with one outcome, nothing examined.
    pub fn fillRows(r: Record, head: *const RuleHead, outcome: Outcome) Allocator.Error!void {
        for (head.rule.items) |rule| try r.run(rule, r.out.len(), outcome, 0);
    }

    /// Every row skipped for want of design intent.
    pub fn skipRows(r: Record, head: *const RuleHead) Allocator.Error!void {
        try r.fillRows(head, .{ .skipped = .no_design_intent });
    }

    /// The rows of a table that derates to the sign-off temperature, in a
    /// run that has none: skipped without usable intent, as they would be
    /// anyway, else refused (the temperature they would read is no one's).
    pub fn noTemperature(r: Record, usable: bool, head: *const RuleHead) Allocator.Error!void {
        try r.fillRows(head, if (usable) .refused else .{ .skipped = .no_design_intent });
    }

    /// One violation per flagged net, at its lowest polygon's first
    /// vertex; a net with no polygon is skipped.
    pub fn netViolations(r: Record, design: Design, flagged: []const u32, rule: StrId, severity: Severity, measured: Measurement, limit: Measurement) Allocator.Error!void {
        for (flagged) |n| {
            const polys = design.nets.polysOf(@fromBackingInt(n));
            if (polys.len == 0) continue;
            const poly = polys[0];
            try r.out.push(r.gpa, .{
                .rule = rule,
                .layer = design.store.polyLayer(poly),
                .severity = severity,
                .at = design.store.firstVertex(poly),
                .measured = measured,
                .limit = limit,
                .shape_a = poly,
                .shape_b = report.no_shape,
            });
        }
    }
};
