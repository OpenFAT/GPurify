//! The fixture corpus driven through the engine, and the checks of each
//! case against its geometry-derived expectation in expectations.json.
//! Ported from tests/common/mod.rs (`run_case*`, `check_geometry_case`,
//! `check_lvs_case`, `check_pex_case*`, `check_coupling_laws`,
//! `totals_of`, `field_solved_coupling_af`, `rule_run`).
//!
//! Every case asserts `RuleRun.examined` beside its count, since an empty
//! violation table is also what a rule that never ran produces. A failure
//! is a message naming the case; a domain's messages fail its test at once.
//!
//! Contents:
//! - `pub fn runCase(arena: Allocator, domain: []const u8, id: []const u8, checks: Checks, reference: ?[]const u8, intent: ?[]const u8) !Run`
//! - `pub fn runCaseFieldSolved(arena: Allocator, id: []const u8) !Run`
//! - `pub fn fieldSolvedCouplingAf(arena: Allocator, id: []const u8) !f64`
//! - `pub fn ruleRun(r: *const Run, name: []const u8) !RuleRun`
//! - `pub fn violationsOf(arena: Allocator, r: *const Run, rule: []const u8) ![]const Violation`
//! - `pub const Totals = struct`, `pub fn totalsOf(r: *const Run, only: ?LayerId) Totals`
//! - `pub fn checkGeometryCase(arena: Allocator, case: std.json.Value, failed: *std.ArrayList([]const u8)) !void`
//! - `pub fn checkLvsCase(arena: Allocator, case: std.json.Value, open: []const []const u8, failed: *std.ArrayList([]const u8)) !void`
//! - `pub fn checkPexCase(arena: Allocator, case: std.json.Value, failed: *std.ArrayList([]const u8)) !void`
//! - `pub fn checkPexCaseFieldSolved(arena: Allocator, case: std.json.Value, failed: *std.ArrayList([]const u8)) !void`
//! - `pub fn checkCouplingLaws(arena: Allocator, failed: *std.ArrayList([]const u8)) !void`
//! - `pub fn corpus(arena: Allocator) !std.json.Value`, `pub fn report(domain: []const u8, cases: usize, failed: []const []const u8) !void`

const std = @import("std");
const Allocator = std.mem.Allocator;
const testing = std.testing;
const io = testing.io;
const paths = @import("paths");
const geom = @import("geom");
const LayerId = geom.LayerId;
const check = @import("check");
const report_ = check.report;
const RuleRun = report_.RuleRun;
const Violation = report_.Violation;
const Measurement = report_.Measurement;
const gpurify = @import("gpurify");
const Run = gpurify.Run;
const Checks = gpurify.Checks;
const json = std.json.Value;

/// The parasitic totals one cell extracts to, folded by kind.
pub const Totals = struct { resistance_ohm: f64 = 0, ground_cap_af: f64 = 0, coupling_cap_af: f64 = 0 };

/// Femtofarads to attofarads: the network is in fF, the corpus in aF.
const af_per_ff = 1000.0;

/// The field solves here run on the host, eight threads.
const device: geom.Device = .{ .backend = .cpu, .min_gpu_work = std.math.maxInt(u64), .threads = 8 };

/// One case's own GDS against params.deck, optionally with a reference
/// (under tests/fixtures) and an intent file's text. The run lives in `arena`.
pub fn runCase(arena: Allocator, domain: []const u8, id: []const u8, checks: Checks, reference: ?[]const u8, intent: ?[]const u8) !Run {
    return runWith(arena, domain, id, .{ .checks = checks }, reference, intent);
}

/// One PEX case run through the field solve: every labelled net, ascending
/// by net, named for `--quasistatic`.
pub fn runCaseFieldSolved(arena: Allocator, id: []const u8) !Run {
    const first = try runCase(arena, "pex", id, .{}, null, null);
    var named: std.ArrayList([]const u8) = .empty;
    for (0..first.extracted.nets.netCount()) |n| {
        if (first.extracted.ports.nameOf(@fromBackingInt(@as(u32, @intCast(n))))) |name| try named.append(arena, first.loaded.strings.resolve(name));
    }
    if (named.items.len == 0) return error.NoLabelledNet;
    return runWith(arena, "pex", id, .{ .checks = .{ .pex = true }, .quasistatic_nets = named.items, .device = device }, null, null);
}

/// The coupling capacitance a field solve found in one PEX cell, aF.
pub fn fieldSolvedCouplingAf(arena: Allocator, id: []const u8) !f64 {
    const r = try runCaseFieldSolved(arena, id);
    const network = r.outputs.parasitics orelse return error.NoNetwork;
    var ff: f64 = 0;
    for (network.kind.items, network.value.items) |k, v| if (k == .coupling_cap) {
        ff += v;
    };
    return ff * af_per_ff;
}

/// The one run record of rule `name`.
pub fn ruleRun(r: *const Run, name: []const u8) !RuleRun {
    const id = r.loaded.strings.get(name) orelse return error.TestRuleNotInterned;
    var found: ?RuleRun = null;
    for (r.outputs.runs.items) |run| if (run.rule == id) {
        if (found != null) return error.TestRuleRecordedTwice;
        found = run;
    };
    return found orelse error.TestNoRuleRun;
}

/// Every violation of `rule`, ascending by report point (y, then x).
pub fn violationsOf(arena: Allocator, r: *const Run, rule: []const u8) ![]const Violation {
    const id = r.loaded.strings.get(rule) orelse return error.TestRuleNotInterned;
    var out: std.ArrayList(Violation) = .empty;
    for (0..r.outputs.violations.len()) |row| {
        const v = r.outputs.violations.get(@intCast(row));
        if (v.rule == id) try out.append(arena, v);
    }
    std.mem.sort(Violation, out.items, {}, byPoint);
    return out.items;
}

/// `only` folds the elements whose near node is on that layer alone.
pub fn totalsOf(r: *const Run, only: ?LayerId) Totals {
    var t: Totals = .{};
    const network = r.outputs.parasitics orelse return t;
    for (network.from.items, network.kind.items, network.value.items) |from, k, v| {
        if (only) |want| if (network.node_layer.items[@backingInt(from)] != want) continue;
        switch (k) {
            .resistance => t.resistance_ohm += v,
            .ground_cap => t.ground_cap_af += v * af_per_ff,
            .coupling_cap => t.coupling_cap_af += v * af_per_ff,
            else => {},
        }
    }
    return t;
}

/// tests/fixtures/expectations.json.
pub fn corpus(arena: Allocator) !json {
    var root = try std.Io.Dir.cwd().openDir(io, paths.root, .{});
    defer root.close(io);
    _ = try @import("fixtures.zig").ensure(testing.allocator, root);
    const text = try root.readFileAlloc(io, "tests/fixtures/expectations.json", arena, .unlimited);
    return std.json.parseFromSliceLeaky(json, arena, text, .{});
}

/// Fails with every message of a domain.
pub fn report(domain: []const u8, cases: usize, failed: []const []const u8) !void {
    if (failed.len == 0) return;
    std.debug.print("{d} disagreements across {d} {s} cases: the geometry says one thing and the run says another.\n", .{ failed.len, cases, domain });
    for (failed) |f| std.debug.print("\n{s}\n", .{f});
    return error.TestCorpusDisagrees;
}

/// Every way a DRC or ERC case disagreed with what its geometry says.
pub fn checkGeometryCase(arena: Allocator, case: json, failed: *std.ArrayList([]const u8)) !void {
    const id = str(case, "id");
    const deck_rule = deckRuleOf(id, if (case.object.get("rule")) |r| r.string else str(case, "check")) orelse return checkValidityCase(arena, case, failed);
    // DRC and ERC both: three DRC-named cases are antenna cases, owned by ERC.
    const r = runCase(arena, str(case, "domain"), id, .{ .drc = true, .erc = true }, null, null) catch |err|
        return fail(arena, failed, "{s}: cell did not reach the checks at all: {t}", .{ id, err });
    const rule = r.loaded.strings.get(deck_rule) orelse return fail(arena, failed, "{s}: the deck never interned a rule named {s}", .{ id, deck_rule });
    const record = for (r.outputs.runs.items) |run| (if (run.rule == rule) break run) else return fail(arena, failed, "{s}: rule {s} recorded no RuleRun; a rule that never ran and one that found nothing look alike", .{ id, deck_rule });
    if (asserts(case, "outcome")) {
        const want = str(case, "expect_outcome");
        if (!std.mem.eql(u8, outcomeName(record.outcome), want)) try fail(arena, failed, "{s}: rule {s} recorded {s}; the geometry says {s}", .{ id, deck_rule, outcomeName(record.outcome), want });
    }
    if (asserts(case, "examined_min")) {
        const floor: u64 = @intCast(case.object.get("examined_min").?.integer);
        if (record.examined < floor) try fail(arena, failed, "{s}: rule {s} examined {d}, below the geometry's floor of {d}", .{ id, deck_rule, record.examined, floor });
    }
    const found = try violationsOf(arena, &r, deck_rule);
    const expect_count: usize = @intCast(case.object.get("expect_violations").?.integer);
    if (asserts(case, "violation_count") and found.len != expect_count)
        return fail(arena, failed, "{s}: rule {s} found {d} violations; the geometry says {d}", .{ id, deck_rule, found.len, expect_count });
    const wants_measured = asserts(case, "measured");
    const wants_at = asserts(case, "at");
    const wants_layer = asserts(case, "layer");
    if (!(wants_measured or wants_at or wants_layer)) return;
    const expected = try arena.dupe(json, case.object.get("violations").?.array.items);
    std.mem.sort(json, expected, {}, byExpectedPoint);
    for (expected, found[0..@min(found.len, expected.len)], 0..) |want, got, nth| {
        const at = want.object.get("at").?.array.items;
        const wx = at[0].integer;
        const wy = at[1].integer;
        if (wants_at and (got.at.x != wx or got.at.y != wy)) try fail(arena, failed, "{s}: violation {d} of {s} at ({d}, {d}); the geometry puts it at ({d}, {d})", .{ id, nth, deck_rule, got.at.x, got.at.y, wx, wy });
        const m = want.object.get("measured").?;
        if (wants_measured and !measurementMatches(got.measured, m)) try fail(arena, failed, "{s}: violation {d} of {s} measures {f}; the geometry measures {s}", .{ id, nth, deck_rule, got.measured, str(m, "kind") });
        if (wants_layer) if (want.object.get("layer")) |l| if (l == .string) {
            const want_layer = r.loaded.deck.deck.layers.id(&r.loaded.strings, l.string);
            if (want_layer != got.layer) try fail(arena, failed, "{s}: violation {d} of {s} on layer {d}; the geometry puts it on {s}", .{ id, nth, deck_rule, @backingInt(got.layer), l.string });
        };
    }
}

/// Every way an LVS case disagreed with its geometry, from one run against
/// lvs_refs/<id>.spice. A case blocked by an open finding is expected to
/// fail its verdict; one that holds anyway is reported, so the fix is noticed.
pub fn checkLvsCase(arena: Allocator, case: json, open: []const []const u8, failed: *std.ArrayList([]const u8)) !void {
    const id = str(case, "id");
    const reference = try std.fmt.allocPrint(arena, "lvs_refs/{s}.spice", .{id});
    const r = runCase(arena, "lvs", id, .{ .lvs = true }, reference, null);
    const expect_match = case.object.get("expect_match").?.bool;
    if (asserts(case, "match")) {
        const matched: ?bool = if (r) |run| (if (run.outputs.lvs) |t| t.verdict == .match else null) else |_| null;
        const holds = matched != null and matched.? == expect_match;
        var blocker: ?[]const u8 = null;
        for (case.object.get("blocked_by").?.array.items) |b| for (open) |o| if (std.mem.eql(u8, b.string, o)) {
            blocker = o;
        };
        if (blocker == null and !holds) try fail(arena, failed, "{s}: LVS against {s} gave {?}; the case expects match = {}", .{ id, reference, matched, expect_match });
        if (blocker != null and holds) try fail(arena, failed, "{s}: expected to fail until blocking finding {s} is fixed, and it now holds", .{ id, blocker.? });
    }
    const run = r catch |err| return fail(arena, failed, "{s}: cell did not extract: {t}", .{ id, err });
    if (asserts(case, "outcome") and !std.mem.eql(u8, stageName(run.summary.lvs), str(case, "expect_outcome"))) try fail(arena, failed, "{s}: the LVS stage recorded {s}; the geometry says {s}", .{ id, stageName(run.summary.lvs), str(case, "expect_outcome") });
    if (asserts(case, "examined_min")) {
        const floors = case.object.get("examined_min").?;
        for ([_][2][]const u8{ .{ "lvs.terminal_count", "devices" }, .{ "lvs.floating_net", "nets" } }) |row| {
            const floor: u64 = @intCast(floors.object.get(row[1]).?.integer);
            const examined: ?u64 = if (ruleRun(&run, row[0])) |rr| rr.examined else |_| null;
            if (examined == null or examined.? < floor) try fail(arena, failed, "{s}: {s} examined {?} {s}; the geometry draws {d}", .{ id, row[0], examined, row[1], floor });
        }
    }
    if (asserts(case, "device_count")) {
        const want: u32 = @intCast(case.object.get("expect_devices").?.integer);
        if (run.extracted.devices.len() != want) try fail(arena, failed, "{s}: extracts {d} devices; the geometry draws {d}", .{ id, run.extracted.devices.len(), want });
    }
    if (asserts(case, "net_count")) {
        const want: u32 = @intCast(case.object.get("expect_nets").?.integer);
        if (run.extracted.nets.netCount() != want) try fail(arena, failed, "{s}: extracts {d} nets; the geometry draws {d}", .{ id, run.extracted.nets.netCount(), want });
    }
}

/// Every way a PEX case disagreed with its closed form.
pub fn checkPexCase(arena: Allocator, case: json, failed: *std.ArrayList([]const u8)) !void {
    const id = str(case, "id");
    const r = runCase(arena, "pex", id, .{ .pex = true }, null, null) catch |err| return fail(arena, failed, "{s}: did not extract: {t}", .{ id, err });
    try checkPexExamined(arena, case, &r, failed);
    // Underivable values are relations, asserted by `checkCouplingLaws`.
    if (std.mem.eql(u8, str(case, "provenance"), "underivable")) return;
    const kind = str(case, "kind");
    const scope = scopeOf(&r, kind);
    const totals = totalsOf(&r, scope);
    if (case.object.get("expect_per_net")) |per_net| if (per_net == .object) return checkPerNet(arena, case, &r, per_net, failed);
    const want = number(case.object.get("expect_value") orelse return) orelse return;
    const got = valueOf(kind, totals) orelse return fail(arena, failed, "{s}: kind {s} names no element this fold produces", .{ id, kind });
    const tol = number(case.object.get("tol").?).?;
    const agrees = @abs(got - want) <= tol;
    if (case.object.get("expect_mismatch").?.bool and asserts(case, "mismatch")) {
        if (agrees) try fail(arena, failed, "{s}: extracts {d}, the value a correct cell gives; the fixture is drawn wrong on purpose", .{ id, got });
        if (!agrees and got == 0 and want != 0) try fail(arena, failed, "{s}: extracts nothing, so the negative case is met by an absence", .{id});
    } else if (asserts(case, "value") and !agrees) try fail(arena, failed, "{s}: extracts {d}; the closed form gives {d} (tolerance {d})", .{ id, got, want, tol });
}

/// A PEX case's field solve against the closed forms and its own laws
/// (testing-plan F6): the stage outcome and drawn nets; a derived straight
/// bar's resistance agrees in both methods; a coupling is at least the
/// closed form's, which has no fringing field; a ground cap is positive.
pub fn checkPexCaseFieldSolved(arena: Allocator, case: json, failed: *std.ArrayList([]const u8)) !void {
    const id = str(case, "id");
    const r = runCaseFieldSolved(arena, id) catch |err| return fail(arena, failed, "{s}: did not field solve: {t}", .{ id, err });
    if (!std.mem.eql(u8, stageName(r.summary.pex), str(case, "expect_outcome"))) try fail(arena, failed, "{s}: the field-solved PEX stage recorded {s}", .{ id, stageName(r.summary.pex) });
    var nets: u64 = 0;
    if (r.outputs.parasitics) |n| {
        // Rust's `dedup` of the unsorted column: runs of one net count once.
        for (n.node_net.items, 0..) |net, i| nets += @intFromBool(i == 0 or n.node_net.items[i - 1] != net);
    }
    const floor: u64 = @intCast(case.object.get("examined_min").?.object.get("nets").?.integer);
    if (nets < floor) try fail(arena, failed, "{s}: the field-solved network holds {d} nets, the cell draws {d}", .{ id, nets, floor });
    const kind = str(case, "kind");
    const totals = totalsOf(&r, scopeOf(&r, kind));
    const want = number(case.object.get("expect_value") orelse return) orelse return;
    const got = valueOf(kind, totals) orelse return;
    const tol = number(case.object.get("tol").?).?;
    const mismatch = case.object.get("expect_mismatch").?.bool;
    const derived = asserts(case, "value") and !std.mem.eql(u8, str(case, "provenance"), "underivable");
    if (std.mem.indexOf(u8, kind, "resistance") != null and derived) {
        if ((@abs(got - want) <= tol) == mismatch) try fail(arena, failed, "{s}: field-solved R {d} against the closed form's {d} (tolerance {d}, mismatch expected: {})", .{ id, got, want, tol, mismatch });
    } else if (std.mem.indexOf(u8, kind, "coupling") != null or std.mem.eql(u8, kind, "interlayer_cap")) {
        if (!mismatch and !(std.math.isFinite(got) and got >= want - tol)) try fail(arena, failed, "{s}: field-solved coupling {d} aF under the closed form's {d} aF", .{ id, got, want });
    } else if (!(std.math.isFinite(got) and got > 0)) try fail(arena, failed, "{s}: field-solved capacitance {d} aF is not finite and positive", .{ id, got });
}

/// The two claims the corpus can make about lateral coupling: it goes as
/// 1/S, and it does not depend on the axis.
pub fn checkCouplingLaws(arena: Allocator, failed: *std.ArrayList([]const u8)) !void {
    var c: [4]f64 = undefined;
    for ([_][]const u8{ "PEX_SPACING_100", "PEX_COUPLING_C", "PEX_SPACING_400", "PEX_VERT_COUPLING" }, &c) |id, *v| {
        v.* = if (runCase(arena, "pex", id, .{ .pex = true }, null, null)) |r| totalsOf(&r, null).coupling_cap_af else |_| std.math.nan(f64);
    }
    if (!(c[0] > 0 and c[1] > 0 and c[2] > 0)) return fail(arena, failed, "the lateral-coupling cells extract {d}, {d}, {d} aF: no 1/S law to check", .{ c[0], c[1], c[2] });
    for ([_][2]f64{ .{ c[0], c[1] }, .{ c[1], c[2] } }) |pair| {
        const implied = pair[0] / pair[1];
        if (@abs(implied - 2.0) > 0.02 * 2.0) try fail(arena, failed, "lateral coupling scales as {d:.4} when the gap doubles; parallel plates give exactly 2", .{implied});
    }
    if (@abs(c[1] - c[3]) > 1e-6 * @max(c[1], 1.0)) try fail(arena, failed, "PEX_CC couples at {d} aF and PEX_VERT, the same bars turned a quarter, at {d}", .{ c[1], c[3] });
}

// ---- private ----

fn runWith(arena: Allocator, domain: []const u8, id: []const u8, options_in: gpurify.RunOptions, reference: ?[]const u8, intent: ?[]const u8) !Run {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    var root = try std.Io.Dir.cwd().openDir(io, paths.root, .{});
    defer root.close(io);
    const layout = try std.fmt.allocPrint(arena, "{s}/tests/fixtures/{s}/{s}.gds", .{ paths.root, domain, id });
    const deck = try std.fmt.allocPrint(arena, "{s}/tests/fixtures/params.deck", .{paths.root});
    var inputs: gpurify.Inputs = .{ .layout = layout, .deck = deck };
    if (reference) |ref| inputs.reference = try arena.dupe([]const u8, &.{try std.fmt.allocPrint(arena, "{s}/tests/fixtures/{s}", .{ paths.root, ref })});
    if (intent) |text| {
        try tmp.dir.writeFile(io, .{ .sub_path = "intent.json", .data = text });
        inputs.intent = "intent.json";
    }
    var options = options_in;
    options.device = device;
    var diag: gpurify.RunDiagnostic = .{};
    return gpurify.run(testing.allocator, arena, io, tmp.dir, inputs, options, &.{}, &diag);
}

fn byPoint(_: void, a: Violation, b: Violation) bool {
    return if (a.at.y != b.at.y) a.at.y < b.at.y else a.at.x < b.at.x;
}

fn byExpectedPoint(_: void, a: json, b: json) bool {
    const pa = a.object.get("at").?.array.items;
    const pb = b.object.get("at").?.array.items;
    return if (pa[1].integer != pb[1].integer) pa[1].integer < pb[1].integer else pa[0].integer < pb[0].integer;
}

fn fail(arena: Allocator, failed: *std.ArrayList([]const u8), comptime fmt: []const u8, args: anytype) !void {
    try failed.append(arena, try std.fmt.allocPrint(arena, fmt, args));
}

fn str(v: json, key: []const u8) []const u8 {
    return v.object.get(key).?.string;
}

fn number(v: json) ?f64 {
    return switch (v) {
        .float => |f| f,
        .integer => |i| @floatFromInt(i),
        else => null,
    };
}

fn asserts(case: json, claim: []const u8) bool {
    for (case.object.get("assert").?.array.items) |a| if (std.mem.eql(u8, a.string, claim)) return true;
    return false;
}

/// The deck rule id a case's rule name refers to; null for a validity case.
/// `params.deck` declares `min_enclosure` twice; the `DRC_WE_*` cells are
/// about the nwell-over-diff row, as each case's note says.
fn deckRuleOf(id: []const u8, rule: []const u8) ?[]const u8 {
    if (std.mem.startsWith(u8, id, "DRC_WE_")) return "nwell.diff.min_enclosure";
    if (std.mem.eql(u8, rule, "layer_validity")) return null;
    const map = std.StaticStringMap([]const u8).initComptime(.{
        .{ "min_width", "met1.min_width" },                            .{ "max_width", "met1.max_width" },
        .{ "min_edge_length", "met1.min_edge_length" },                .{ "notch", "met1.notch" },
        .{ "min_spacing", "met1.min_spacing" },                        .{ "min_spacing_diff", "met1.met2.min_spacing" },
        .{ "eol_spacing", "met1.eol_spacing" },                        .{ "prl_spacing", "met1.prl_spacing" },
        .{ "corner_to_corner", "met1.corner_to_corner" },              .{ "wide_dependent_spacing", "met1.wide_dependent_spacing" },
        .{ "min_area", "met1.min_area" },                              .{ "min_enclosed_area", "met1.min_enclosed_area" },
        .{ "cheesing", "met1.cheesing" },                              .{ "min_density", "met1.min_density" },
        .{ "max_density", "met1.max_density" },                        .{ "min_enclosure", "met1.met2.min_enclosure" },
        .{ "asymmetric_enclosure", "met1.via1.asymmetric_enclosure" }, .{ "min_extension", "poly.diff.min_extension" },
        .{ "overlap", "met1.met2.overlap" },                           .{ "max_distance_to_tap", "diff.li.max_distance_to_tap" },
        .{ "off_grid", "off_grid" },                                   .{ "angle", "angle" },
        .{ "redundant_via", "via1.redundant_via" },                    .{ "via_array_spacing", "via1.via_array_spacing" },
        .{ "multi_patterning", "met1.multi_patterning" },              .{ "antenna", "poly.met1.antenna" },
        .{ "antenna_car", "poly.antenna_electrical" },                 .{ "antenna_electrical", "poly.antenna_electrical" },
        .{ "density_cmp", "met1.density_cmp" },                        .{ "electromigration", "met1.electromigration" },
        .{ "em_current_density", "em_current_density" },               .{ "esd_latchup", "esd_latchup" },
        .{ "esd_missing", "esd_topological" },                         .{ "floating_gate", "floating_gate" },
        .{ "floating_well", "nwell.floating_well" },                   .{ "hv_domain_crossing", "hv_domain" },
        .{ "ir_drop", "ir_drop" },                                     .{ "missing_tie", "diff.li.missing_tie" },
        .{ "multiple_drivers", "multiple_drivers" },                   .{ "p2p_resistance", "p2p_resistance" },
        .{ "reliability", "bti" },                                     .{ "soft_connection", "nwell.soft_connection" },
        .{ "supply_short", "supply_short" },                           .{ "tie_high_low", "tie_high_low" },
        .{ "unconnected_pin", "met1.unconnected_pin" },
    });
    return map.get(rule) orelse std.debug.panic("case {s} names rule {s}, which maps to no deck row", .{ id, rule });
}

/// A case whose claim is that the tool refuses the geometry, or `Valid`.
fn checkValidityCase(arena: Allocator, case: json, failed: *std.ArrayList([]const u8)) !void {
    const id = str(case, "id");
    const want = case.object.get("expect_validity_error") orelse return fail(arena, failed, "{s}: names no deck rule and no expected ValidityError", .{id});
    const r = runCase(arena, str(case, "domain"), id, .{}, null, null) catch |err| return fail(arena, failed, "{s}: did not load: {t}", .{ id, err });
    const layer = r.loaded.deck.deck.layers.id(&r.loaded.strings, str(want, "layer")) orelse return fail(arena, failed, "{s}: no layer {s}", .{ id, str(want, "layer") });
    var validated: geom.ValidatedLayer = .empty;
    const defect = try geom.view.validateLayer(arena, &r.loaded.store, layer, .rectilinear, &validated);
    const got: []const u8 = if (defect) |d| switch (d) {
        .degenerate => "Degenerate",
        .self_intersecting => "SelfIntersecting",
        .orphan_hole => "OrphanHole",
        .not_rectilinear => "NotRectilinear",
        .not_octilinear => "NotOctilinear",
        .uncomputed => "Uncomputed",
    } else "Valid";
    if (!std.mem.eql(u8, got, str(want, "variant"))) try fail(arena, failed, "{s}: the layer validates as {s}; the geometry says {s}", .{ id, got, str(want, "variant") });
}

fn outcomeName(o: report_.Outcome) []const u8 {
    return switch (o) {
        .ran => "Ran",
        .refused => "Refused",
        .skipped => |why| switch (why) {
            .no_design_intent => "Skipped(NoDesignIntent)",
            .not_in_deck => "Skipped(NotInDeck)",
            .empty_layer => "Skipped(EmptyLayer)",
            .earlier_stage => "Skipped(EarlierStage)",
        },
    };
}

fn stageName(s: gpurify.StageStatus) []const u8 {
    return switch (s) {
        .ran => "Ran",
        .not_selected => "NotSelected",
        .skipped => "Skipped",
        .refused => "Refused",
    };
}

/// A reported measurement against the derived one, dimension included;
/// floats to a relative 1e-9.
fn measurementMatches(got: Measurement, want: json) bool {
    const kind = str(want, "kind");
    const v = want.object.get("value").?;
    const near = struct {
        fn f(value: f64, w: json) bool {
            const e = number(w) orelse return false;
            return @abs(value - e) <= 1e-9 * @max(@abs(e), 1.0);
        }
    }.f;
    return switch (got.kind) {
        .length => std.mem.eql(u8, kind, "Length") and v == .integer and got.exact() == v.integer,
        .area => std.mem.eql(u8, kind, "Area") and v == .integer and got.exact() == v.integer,
        .count => std.mem.eql(u8, kind, "Count") and v == .integer and got.exact() == v.integer,
        .ratio => std.mem.eql(u8, kind, "Ratio") and near(got.float(), v),
        .voltage => std.mem.eql(u8, kind, "Voltage") and near(got.float(), v),
        .current => std.mem.eql(u8, kind, "Current") and near(got.float(), v),
        .resistance => std.mem.eql(u8, kind, "Resistance") and near(got.float(), v),
    };
}

/// A kind ending in a conductor's name scopes the fold to it (`PEX_DIFF` is
/// met1 and met2 in one cell, derived separately).
fn scopeOf(r: *const Run, kind: []const u8) ?LayerId {
    const at = std.mem.lastIndexOfScalar(u8, kind, '_') orelse return null;
    const conductor = kind[at + 1 ..];
    if (!std.mem.eql(u8, conductor, "met1") and !std.mem.eql(u8, conductor, "met2")) return null;
    return r.loaded.deck.deck.layers.id(&r.loaded.strings, conductor);
}

fn valueOf(kind: []const u8, t: Totals) ?f64 {
    const resistance = [_][]const u8{ "resistance", "resistance_met1", "resistance_met2", "via_resistance" };
    for (resistance) |k| if (std.mem.eql(u8, k, kind)) return t.resistance_ohm;
    if (std.mem.eql(u8, kind, "area_cap")) return t.ground_cap_af;
    for ([_][]const u8{ "coupling_cap", "coupling_cap_met2", "interlayer_cap" }) |k| if (std.mem.eql(u8, k, kind)) return t.coupling_cap_af;
    return null;
}

/// The stage outcome, and a network holding the nets and elements drawn.
fn checkPexExamined(arena: Allocator, case: json, r: *const Run, failed: *std.ArrayList([]const u8)) !void {
    const id = str(case, "id");
    if (asserts(case, "outcome") and !std.mem.eql(u8, stageName(r.summary.pex), str(case, "expect_outcome"))) try fail(arena, failed, "{s}: the PEX stage recorded {s}; the geometry says {s}", .{ id, stageName(r.summary.pex), str(case, "expect_outcome") });
    if (!asserts(case, "examined_min")) return;
    var nets: u64 = 0;
    var elements: u64 = 0;
    if (r.outputs.parasitics) |n| {
        const sorted = try arena.dupe(u32, n.node_net.items);
        std.mem.sort(u32, sorted, {}, std.sort.asc(u32));
        for (sorted, 0..) |net, i| nets += @intFromBool(i == 0 or sorted[i - 1] != net);
        elements = n.value.items.len;
    }
    const floor = case.object.get("examined_min").?.object;
    const fn_: u64 = @intCast(floor.get("nets").?.integer);
    const fe: u64 = @intCast(floor.get("elements").?.integer);
    if (nets < fn_ or elements < fe) try fail(arena, failed, "{s}: extracted {d} nets and {d} elements; the geometry draws at least {d} and {d}", .{ id, nets, elements, fn_, fe });
}

fn checkPerNet(arena: Allocator, case: json, r: *const Run, per_net: json, failed: *std.ArrayList([]const u8)) !void {
    const id = str(case, "id");
    const network = r.outputs.parasitics orelse return fail(arena, failed, "{s}: extracted no network at all", .{id});
    const tol = number(case.object.get("tol").?).?;
    const mismatch = case.object.get("expect_mismatch").?.bool;
    var it = per_net.object.iterator();
    while (it.next()) |entry| {
        const net = try std.fmt.parseInt(u32, entry.key_ptr.*, 10);
        var resistance: f64 = 0;
        var ground: f64 = 0;
        for (network.from.items, network.kind.items, network.value.items) |from, k, v| {
            if (network.node_net.items[@backingInt(from)] != net) continue;
            switch (k) {
                .resistance => resistance += v,
                .ground_cap => ground += v * af_per_ff,
                else => {},
            }
        }
        const want_r = number(entry.value_ptr.object.get("r_ohm").?).?;
        const want_c = number(entry.value_ptr.object.get("ground_cap_af").?).?;
        const r_agrees = @abs(resistance - want_r) <= tol;
        const c_agrees = @abs(ground - want_c) <= tol;
        if (mismatch) {
            if (r_agrees and c_agrees) try fail(arena, failed, "{s}: net {d} extracts the values a correct cell gives", .{ id, net });
            if (!(r_agrees and c_agrees) and resistance == 0 and ground == 0) try fail(arena, failed, "{s}: net {d} extracts nothing", .{ id, net });
        } else {
            if (!r_agrees) try fail(arena, failed, "{s}: net {d} extracts {d} ohm; the closed form gives {d}", .{ id, net, resistance, want_r });
            if (!c_agrees) try fail(arena, failed, "{s}: net {d} extracts {d} aF; the closed form gives {d}", .{ id, net, ground, want_c });
        }
    }
}
