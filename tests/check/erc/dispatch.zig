//! `erc.run_.run`, and the claim that makes an ERC report readable: every
//! configured rule row produces exactly one `RuleRun`, including the rows
//! that could not run. Oracle throughout: construct-from-answer. The rule
//! set holds one row of each kind, its id the kind's name, so the expected
//! number of run rows and the split between the kinds that always run and
//! the intent-gated ones are decided before anything executes. Ported from
//! crates/check/tests/erc/dispatch.rs (its `RuleSet::run` half; the
//! `RuleSet::from_deck` half is dispatch_deck.zig). Rust writes `every_kind`
//! out table by table; here it is a deck of one row per kind, compiled.

const std = @import("std");
const Allocator = std.mem.Allocator;
const testing = std.testing;
const geom = @import("geom");
const ingest = @import("ingest");
const check = @import("check");
const testgen = @import("testgen");
const StrId = geom.StrId;
const StrTable = geom.StrTable;
const report = check.report;
const Violations = report.Violations;
const RuleRun = report.RuleRun;
const Outcome = report.Outcome;
const topology = check.topology;
const erc = check.erc;
const RunInputs = erc.run_.RunInputs;
const Power = erc.power_grid.Power;
const common = @import("common.zig");
const gpa = common.gpa;

/// The kinds that cannot answer their question without design intent.
const intent_gated = [_][]const u8{
    "combinational_loop", "dielectric_field", "domain_crossing",    "drain_source",
    "dynamic_ir_drop",    "electromigration", "em_current_density", "em_peak",
    "em_rms",             "esd_cross_domain", "esd_exposed",        "esd_ground_coupling",
    "em_thermal",         "esd_latchup",      "esd_path",           "esd_pin_pair",
    "esd_topological",    "floating_supply",  "forward_diode",      "gate_oxide",
    "gate_path",          "guard_ring_bias",  "hot_carrier",        "hv_domain",
    "hv_tag",             "ir_drop",          "missing_isolation",  "missing_level_shifter",
    "multiple_drivers",   "net_type",         "power_switch",       "reliability",
    "supply_path",        "tie_high_low",     "undriven_gate",      "voltage_spacing",
    "well_bias",
};

/// The kinds that read the solved supply grid.
const grid_kinds = [_][]const u8{ "ir_drop", "dynamic_ir_drop", "em_current_density", "electromigration", "em_thermal", "reliability" };

/// Two conductors `a` and `b` joined by the cut `c`, a channel marker `m`,
/// and one row of every kind, each named for its kind.
const every_kind_deck =
    \\grid 1nm
    \\layer a = gds(1, 0)
    \\layer b = gds(2, 0)
    \\layer c = gds(3, 0)
    \\layer m = gds(4, 0)
    \\connect conductors [a, b]
    \\connect via c [a, b]
    \\device mos m model "nfet" terminals [a, b, b]
    \\pex a thickness 100nm height 100nm sheet 0.1ohm dielectric 3.9 area_cap 1aF/um2 fringe_cap 1aF/um
    \\pex b thickness 100nm height 300nm sheet 0.1ohm dielectric 3.9 area_cap 1aF/um2 fringe_cap 1aF/um
    \\pex c thickness 100nm height 200nm sheet 1ohm dielectric 3.9 area_cap 1aF/um2 fringe_cap 1aF/um
    \\rule antenna antenna(a, b; max_ratio: 20, sidewall: none, diode: none, diode_area: none, diode_min: none)
    \\rule antenna_electrical antenna_electrical(a, b; max_ratio: 400, sidewall: none, cut_factor: 1, diode: none, diode_credit: 0, diode_bonus: 0, area_minus_diode: 0, gate_plus_diode: 0, diode_reduce: none, diode_max_ratio: none, exempt: none)
    \\rule conditional_tie conditional_tie(a, b, a, b; within: 50um, spacing: [1um, 2um], max_distance: [15um, 30um, 50um])
    \\rule density_cmp density_cmp(a; window: 700um x 700um, step: 70um x 70um, min: none, max: 0.7, max_delta: none, partial_windows: false, cmp: none)
    \\rule dielectric_field dielectric_field(a; max_field: 10V/um)
    \\rule domain_crossing domain_crossing()
    \\rule drain_source drain_source(; models: ["nfet"], max: 1.8V)
    \\rule dynamic_ir_drop dynamic_ir_drop()
    \\rule electromigration electromigration(a, c; max_density: 1000A/m, max_current_per_cut: 80uA, blech_limit: 54000uA, reference_temperature: 378K, activation_energy: 0.9eV, current_exponent: 2)
    \\rule em_current_density em_current_density(a; max_density: 1mA/um, max_current_per_cut: 1000uA, narrow: none)
    \\rule em_rms em_rms(a; frequency: [100MHz], width: [0um], density: [[1mA/um]], max_current_per_cut: 1000uA)
    \\rule em_peak em_peak(a; frequency: [100MHz], width: [0um], density: [[1mA/um]], max_current_per_cut: 1000uA)
    \\rule em_thermal em_thermal(a, c; max_density: 1mA/um, max_current_per_cut: 0.2mA, blech_limit: 2000uA, reference_temperature: 110C, activation_energy: 0.9eV, current_exponent: 2, thermal_conductivity: 1.4W/mK, spreading: 0.88, sigma: 0.4, limit_failure: 10%, max_failure: 20%)
    \\rule esd_cross_domain esd_cross_domain(; diodes: ["nfet"], local: none, resistors: none, min_series: none, max_ground_resistance: none, coupling_resistance: none)
    \\rule esd_exposed esd_exposed(a; clamps: ["nfet"], resistors: none, rated: ["nfet"], min_series: none)
    \\rule esd_ground_coupling esd_ground_coupling(; diodes: ["nfet"])
    \\rule esd_latchup esd_latchup(a, b; min_guard_ring_width: 10nm, max_tap_distance: 20nm, clamps: ["nfet"])
    \\rule esd_parasitic esd_parasitic(a, b; min_spacing: 5um)
    \\rule esd_path esd_path(a; clamps: ["nfet"], current: 1330mA, clamp_resistance: 1ohm, max_resistance: 5ohm, clamp_it2: none, max_density: none, max_current_per_cut: none, max_voltage: none, min_width: none, clamp_voltage: none)
    \\rule esd_pin_pair esd_pin_pair(a; clamps: ["nfet"], current: 1330mA, clamp_resistance: 1ohm, max_resistance: 5ohm)
    \\rule esd_clamp_resistance esd_clamp_resistance(a; clamps: ["nfet"], max_resistance: 1ohm)
    \\rule esd_topological esd_topological(a; clamps: ["nfet"])
    \\rule fanout fanout(; max: 1)
    \\rule floating_gate floating_gate(; labels_are_ports: false)
    \\rule floating_well floating_well(a, b)
    \\rule power_switch power_switch(; models: ["nfet"])
    \\rule matching matching(m; tolerance: 50nm)
    \\rule floating_supply floating_supply()
    \\rule forward_diode forward_diode(a; models: ["nfet"])
    \\rule combinational_loop combinational_loop()
    \\rule gate_oxide gate_oxide(; models: ["nfet"], max: 1.8V)
    \\rule gate_path gate_path(; ground: false, max_devices: 3)
    \\rule guard_ring guard_ring(a, b; max_space: 15um, min_width: 2um, pad: a, near: none, within: none, clear: none)
    \\rule guard_ring_bias guard_ring_bias(b; power: false)
    \\rule hot_carrier hot_carrier(; models: ["nfet"], max_length: 200nm)
    \\rule hv_domain hv_domain(; max_delta: 1000mV, isolation: b)
    \\rule hv_tag hv_tag(a, b; voltage: 3V)
    \\rule ir_drop ir_drop()
    \\rule latchup_victim latchup_victim(a, b, a; within: 15um, max_distance: 2um, pad: none, bias: none, forward: none)
    \\rule missing_isolation missing_isolation(; isolation: ["nfet"])
    \\rule missing_level_shifter missing_level_shifter(; shifters: ["nfet"])
    \\rule missing_tie missing_tie(a, b; max_distance: 20um)
    \\rule mixed_tag mixed_tag(a, b)
    \\rule multiple_drivers multiple_drivers(; max: 1)
    \\rule net_type net_type(; net: ["power"], path: none, break: none, exclude: none)
    \\rule p2p_resistance p2p_resistance(; max: 10ohm)
    \\rule reliability reliability(; required_lifetime: 1000h, reference_lifetime: 1000h, reference_stress: 1.8V, stress_exponent: 2, reference_temperature: 378K, activation_energy: 0.9eV, max_abs_voltage: 1.8V, duty_cycle: 0.5)
    \\rule soft_connection soft_connection(a)
    \\rule supply_short supply_short(a, b)
    \\rule supply_path supply_path(; both: true, labels_are_ports: true)
    \\rule tie_area tie_area(a, b, a; min_ratio: 3%)
    \\rule tie_high_low tie_high_low()
    \\rule unconnected_pin unconnected_pin(a)
    \\rule undriven_gate undriven_gate()
    \\rule voltage_spacing voltage_space(a; voltage: [0V, 3.3V, 5V], space: [140nm, 300nm, 600nm])
    \\rule well_bias well_bias(; pmos: ["nfet"], nmos: ["nfet"])
    \\rule well_sharing well_sharing(; models: ["nfet"], resistors: true)
    \\
;

/// Everything a run borrows: the compiled every-kind deck over two
/// rectangles (one on `a`, one on `b`) and empty extraction tables.
const Cell = struct {
    arena: std.heap.ArenaAllocator,
    strings: StrTable = .empty,
    cd: check.deck.compile.CompiledDeck,
    store: geom.GeometryStore = .empty,
    nets: topology.NetTable = .{},
    devices: topology.DeviceTable = .{},
    facts: erc.facts.NetFacts = .{},
    ports: topology.PortTable = .{},
    intent: erc.facts.IntentMap = .{},
    net_types: erc.facts.NetTypes = .{},
    voltage: erc.voltage.NetVoltage = .{},
    networks: erc.power_grid.NetNetworks = .{},

    fn deinit(c: *Cell) void {
        c.store.deinit(gpa);
        c.cd.deinit(gpa);
        c.strings.deinit(gpa);
        c.arena.deinit();
    }

    fn inputs(c: *const Cell, power: Power) RunInputs {
        return .{
            .design = .{ .store = &c.store, .nets = &c.nets, .devices = &c.devices },
            .facts = &c.facts,
            .ports = &c.ports,
            .intent = &c.intent,
            .net_types = &c.net_types,
            .voltage = &c.voltage,
            .networks = &c.networks,
            .power = power,
            .rms_intent = &c.intent,
            .peak_intent = &c.intent,
            .die = .{ .xlo = 0, .ylo = 0, .xhi = 2_000, .yhi = 2_000 },
            .process = .{ .grid = common.manufacturingGrid(), .stack = &c.cd.deck.stack, .connectivity = &c.cd.deck.connectivity },
            .temperature = common.operating_temperature,
        };
    }

    fn id(c: *Cell, kind: []const u8) !StrId {
        return c.strings.intern(gpa, kind);
    }
};

/// A run's rows and violations.
const Ran = struct {
    out: Violations = .{},
    runs: std.ArrayList(RuleRun) = .empty,

    fn deinit(r: *Ran) void {
        r.out.deinit(gpa);
        r.runs.deinit(gpa);
    }
};

// ---- private ----

fn cell() !Cell {
    var c: Cell = .{ .arena = .init(gpa), .cd = undefined };
    errdefer {
        c.strings.deinit(gpa);
        c.arena.deinit();
    }
    const grid = common.manufacturingGrid();
    var diag: check.deck.compile.Diag = .{};
    const parsed = ingest.deck.parseDeck(c.arena.allocator(), gpa, every_kind_deck, grid, &c.strings, &diag.deck) catch |e| {
        for (diag.deck.diagnostics) |d| std.debug.print("deck: {s}\n", .{d.message});
        std.debug.print("deck: {s}\n", .{diag.deck.malformed});
        return e;
    };
    c.cd = check.deck.compile.fromDeck(gpa, parsed, grid, &c.strings, &diag) catch |e| {
        std.debug.print("compile: {t} param {s} {s}\n", .{ e, diag.rule.param, diag.rule.why });
        return e;
    };
    errdefer c.cd.deinit(gpa);
    var lb = testgen.shapes.LayoutBuilder.init(4);
    defer lb.deinit(gpa);
    _ = try lb.rect(gpa, 0, 0, 0, 1_000, 2_000);
    _ = try lb.rect(gpa, 1, 1_200, 200, 1_800, 800);
    var ids: testgen.shapes.Ids = .{};
    defer ids.deinit(gpa);
    try lb.finish(gpa, &c.store, &ids);
    return c;
}

fn runOnce(c: *const Cell, power: Power, r: *Ran) !void {
    var scratch: erc.scratch.Scratch = .{};
    defer scratch.deinit(gpa);
    try erc.run_.run(gpa, &c.cd.erc, c.inputs(power), &scratch, &r.out, &r.runs);
}

fn contains(list: []const []const u8, name: []const u8) bool {
    for (list) |x| if (std.mem.eql(u8, x, name)) return true;
    return false;
}

test "every configured rule row produces exactly one run row" {
    // Oracle: construct-from-answer. One row per kind produces one run row
    // per kind, each attributable to its own rule id: the comparison
    // `RuleSet.len` names as catching a transform that returns early
    // without recording itself, the shape of a false-clean result.
    var c = try cell();
    defer c.deinit();
    var r: Ran = .{};
    defer r.deinit();
    try runOnce(&c, .no_supply, &r);
    try testing.expectEqual(erc.kinds.count, c.cd.erc.len());
    try testing.expectEqual(@as(usize, c.cd.erc.len()), r.runs.items.len);
    for (erc.kinds.names) |kind| _ = try common.runOf(r.runs.items, try c.id(kind));
}

test "without intent exactly the gated kinds record themselves skipped" {
    // Oracle: construct-from-answer. With no design intent the gated kinds
    // say so and the others run anyway: a gated rule reporting clean is the
    // failure this module is built against, and an ungated rule skipping
    // would stop checking a design that needs no intent file.
    var c = try cell();
    defer c.deinit();
    var r: Ran = .{};
    defer r.deinit();
    try runOnce(&c, .no_supply, &r);
    var failures: u32 = 0;
    for (erc.kinds.names) |kind| {
        const row = try common.runOf(r.runs.items, try c.id(kind));
        const want: Outcome = if (contains(&intent_gated, kind)) .{ .skipped = .no_design_intent } else .ran;
        if (!std.meta.eql(row.outcome, want)) {
            std.debug.print("{s}: {any}, want {any}\n", .{ kind, row.outcome, want });
            failures += 1;
        }
        if (contains(&intent_gated, kind)) {
            try testing.expectEqual(@as(u64, 0), row.examined);
            try testing.expectEqual(@as(u32, 0), row.violations);
        }
    }
    try testing.expectEqual(@as(u32, 0), failures);
}

test "a failed solve refuses only the grid rules" {
    // Oracle: `Power`'s contract ("those rows are refused; every other rule
    // still runs"), as a differential against the same rule set with no
    // supply: the six grid kinds turn refused, every other outcome is the
    // first run's.
    var c = try cell();
    defer c.deinit();
    var solved: Ran = .{};
    defer solved.deinit();
    try runOnce(&c, .no_supply, &solved);
    var failed: Ran = .{};
    defer failed.deinit();
    try runOnce(&c, .{ .failed = error.UnanchoredIsland }, &failed);
    for (erc.kinds.names) |kind| {
        const id = try c.id(kind);
        const before = (try common.runOf(solved.runs.items, id)).outcome;
        const after = (try common.runOf(failed.runs.items, id)).outcome;
        if (contains(&grid_kinds, kind)) {
            try testing.expectEqual(Outcome.refused, after);
        } else {
            try testing.expect(std.meta.eql(before, after));
        }
    }
}

test "a kind the deck did not configure produces no run row" {
    // Oracle: construct-from-answer. An empty rule set claims nothing was
    // checked: a different silence from a skip, which claims the rule was
    // wanted and could not run.
    var c = try cell();
    defer c.deinit();
    const empty: erc.RuleSet = .{};
    try testing.expect(empty.isEmpty());
    try testing.expectEqual(@as(u32, 0), empty.len());
    var r: Ran = .{};
    defer r.deinit();
    var scratch: erc.scratch.Scratch = .{};
    defer scratch.deinit(gpa);
    try erc.run_.run(gpa, &empty, c.inputs(.no_supply), &scratch, &r.out, &r.runs);
    try testing.expectEqual(@as(usize, 0), r.runs.items.len);
    try testing.expectEqual(@as(u32, 0), r.out.len());
}

test "run appends to the buffers it is given" {
    // Oracle: construct-from-answer. `run` appends rather than clears,
    // which lets a caller accumulate several cells into one report.
    var c = try cell();
    defer c.deinit();
    var r: Ran = .{};
    defer r.deinit();
    try r.runs.append(gpa, .{ .rule = common.rule(999), .outcome = .ran, .examined = 7, .violations = 0 });
    try r.out.push(gpa, .{
        .rule = common.rule(999),
        .layer = @fromBackingInt(0),
        .severity = .warning,
        .at = .{ .x = 1, .y = 1 },
        .measured = report.Measurement.count(1),
        .limit = report.Measurement.count(0),
        .shape_a = @fromBackingInt(0),
        .shape_b = report.no_shape,
    });
    try runOnce(&c, .no_supply, &r);
    try testing.expectEqual(common.rule(999), r.runs.items[0].rule);
    try testing.expectEqual(@as(usize, c.cd.erc.len()) + 1, r.runs.items.len);
    try testing.expectEqual(common.rule(999), r.out.rule.items[0]);
}

test "running one rule set twice produces identical rows" {
    // Oracle: determinism. One rule set over one cell, run twice, produces
    // the same rows in the same order (the family order `run` states).
    var c = try cell();
    defer c.deinit();
    var first: Ran = .{};
    defer first.deinit();
    try runOnce(&c, .no_supply, &first);
    var second: Ran = .{};
    defer second.deinit();
    try runOnce(&c, .no_supply, &second);
    try testing.expectEqual(first.runs.items.len, second.runs.items.len);
    for (first.runs.items, second.runs.items) |a, b| try testing.expect(std.meta.eql(a, b));
    try testing.expectEqual(first.out.len(), second.out.len());
    for (0..first.out.len()) |i| try testing.expect(std.meta.eql(first.out.get(@intCast(i)), second.out.get(@intCast(i))));
}
