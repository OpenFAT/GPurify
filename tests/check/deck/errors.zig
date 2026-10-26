//! Every way compiling a deck can refuse it, DRC and ERC side. Ported from
//! crates/check/tests/deck/errors.rs.

const std = @import("std");
const testing = std.testing;
const geom = @import("geom");
const ingest = @import("ingest");
const check = @import("check");
const deck = check.deck;
const ParamValue = ingest.deck.ParamValue;
const gpa = testing.allocator;

/// One hand-built rule row: id, kind, how many layer arguments (each layer
/// 0), and its parameters.
const Row = struct { id: []const u8, kind: []const u8, layers: u32, params: []const struct { []const u8, ParamValue } };

/// A refusal and what it names.
const Refusal = struct { err: anyerror, diag: check.drc.params.Diagnostic };

const header =
    \\grid 1nm
    \\layer a = gds(1, 0)
    \\layer b = gds(2, 0)
    \\layer e = a.edges()
    \\layer f = b.edges()
    \\connect conductors [a, b]
    \\device mos a model "nfet" terminals [a, b, b, b]
    \\
;

/// An `antenna_electrical` row's values, each legal.
const antenna_electrical = "max_ratio: 400, sidewall: 10nm, cut_factor: 1, " ++
    "diode: none, diode_credit: 0, diode_bonus: 0, area_minus_diode: 0, gate_plus_diode: 0, " ++
    "diode_reduce: none, diode_max_ratio: [(0nm2, 400), (100nm2, 800)], exempt: none";

// ---- private ----

fn len(nm: i64) ParamValue {
    return .{ .length = nm };
}

/// What compiling deck text refuses, or null when it compiles.
fn refusedText(text: []const u8) !?Refusal {
    var arena: std.heap.ArenaAllocator = .init(gpa);
    defer arena.deinit();
    var strings: geom.StrTable = .empty;
    defer strings.deinit(gpa);
    var diag: deck.compile.Diag = .{};
    var cd = deck.compile.compile(gpa, arena.allocator(), text, try geom.Grid.init(1000), &strings, &diag) catch |e| return .{ .err = e, .diag = diag.rule };
    cd.deinit(gpa);
    return null;
}

/// `text` with the first `from` replaced by `to`, in `arena`; asserts the
/// template holds `from`.
fn replaceOnce(arena: std.mem.Allocator, text: []const u8, from: []const u8, to: []const u8) ![]const u8 {
    const at = std.mem.indexOf(u8, text, from) orelse return error.TestTemplate;
    return std.mem.concat(arena, u8, &.{ text[0..at], to, text[at + from.len ..] });
}

/// `header`, then `rule r <text>`.
fn ruleDeck(text: []const u8) ![]u8 {
    return std.fmt.allocPrint(gpa, "{s}rule r {s}\n", .{ header, text });
}

/// What compiling a deck of `rows` (an empty layer table) refuses. The
/// parser refuses most of these rows; a deck built in code reaches the rule
/// typer as written.
fn refusal(rows: []const Row) !Refusal {
    var arena: std.heap.ArenaAllocator = .init(gpa);
    defer arena.deinit();
    const a = arena.allocator();
    var strings: geom.StrTable = .empty;
    defer strings.deinit(gpa);
    var specs: std.ArrayList(ingest.deck.RuleSpec) = .empty;
    var layer_ref: std.ArrayList(geom.LayerId) = .empty;
    var param: std.ArrayList(ingest.deck.NamedValue) = .empty;
    for (rows) |r| {
        const layer_start: u32 = @intCast(layer_ref.items.len);
        for (0..r.layers) |_| try layer_ref.append(a, @fromBackingInt(0));
        const param_start: u32 = @intCast(param.items.len);
        for (r.params) |p| try param.append(a, .{ .name = try strings.intern(gpa, p[0]), .value = p[1] });
        try specs.append(a, .{ .id = try strings.intern(gpa, r.id), .kind = try strings.intern(gpa, r.kind), .layer_start = layer_start, .layer_len = r.layers, .param_start = param_start, .param_len = @intCast(r.params.len) });
    }
    const d: ingest.deck.Deck = .{ .rules = .{ .spec = specs.items, .layer_ref = layer_ref.items, .param = param.items } };
    var diag: deck.compile.Diag = .{};
    if (deck.compile.fromDeck(gpa, d, try geom.Grid.init(1000), &strings, &diag)) |cd_| {
        var cd = cd_;
        cd.deinit(gpa);
        return error.TestExpectedRefusal;
    } else |e| return .{ .err = e, .diag = diag.rule };
}

test "every drc error is still produced" {
    // Oracle: construct-from-answer: each deck differs from a legal one in
    // the one value the variant's documented constraint forbids.
    var r = try refusal(&.{.{ .id = "w", .kind = "min_widht", .layers = 1, .params = &.{.{ "limit", len(10) }} }});
    try testing.expectEqual(error.UnknownKind, r.err);
    r = try refusal(&.{.{ .id = "w", .kind = "min_width", .layers = 1, .params = &.{} }});
    try testing.expectEqual(error.MissingParam, r.err);
    try testing.expectEqualStrings("limit", r.diag.param);
    r = try refusal(&.{.{ .id = "w", .kind = "min_width", .layers = 1, .params = &.{.{ "limit", .{ .ratio = 1.0 } }} }});
    try testing.expectEqual(error.WrongParamType, r.err);
    try testing.expectEqualStrings("limit", r.diag.param);
    r = try refusal(&.{.{ .id = "w", .kind = "min_width", .layers = 2, .params = &.{.{ "limit", len(10) }} }});
    try testing.expectEqual(error.WrongLayerCount, r.err);
    try testing.expectEqual(@as(u32, 1), r.diag.expected);
    try testing.expectEqual(@as(u32, 2), r.diag.found);
    r = try refusal(&.{.{ .id = "w", .kind = "min_width", .layers = 1, .params = &.{.{ "limit", len(0) }} }});
    try testing.expectEqual(error.NonPositiveLimit, r.err);
    try testing.expectEqual(@as(i64, 0), r.diag.limit);
    r = try refusal(&.{.{ .id = "a", .kind = "angle", .layers = 0, .params = &.{.{ "angle", .{ .count = 30 } }} }});
    try testing.expectEqual(error.UnrepresentableAngle, r.err);
    try testing.expectEqual(@as(i32, 30), r.diag.degrees);
    r = try refusal(&.{ .{ .id = "w", .kind = "min_width", .layers = 1, .params = &.{.{ "limit", len(10) }} }, .{ .id = "w", .kind = "min_width", .layers = 1, .params = &.{.{ "limit", len(20) }} } });
    try testing.expectEqual(error.DuplicateRule, r.err);
    // A cell of zero: not a positive space, so not a valid table.
    r = try refusal(&.{.{ .id = "t", .kind = "spacing_table", .layers = 1, .params = &.{ .{ "prl", len(0) }, .{ "width", len(0) }, .{ "space", len(0) } } }});
    try testing.expectEqual(error.BadTable, r.err);
}

test "every positive drc value written as zero is refused" {
    // Oracle: the kinds' documented domains: each value is a length, area
    // or count the checker documents as positive.
    const length = [2][]const u8{ "0nm", "10nm" };
    const area = [2][]const u8{ "0nm2", "100nm2" };
    const fraction = [2][]const u8{ "0", "0.5" };
    const count = [2][]const u8{ "0", "2" };
    const cases = [_]struct { []const u8, [2][]const u8 }{
        .{ "width(a) >= {}", length },                                   .{ "width(a) <= {}", length },
        .{ "size(a) == {} x 10nm", length },                             .{ "size(a) == 10nm x {}", length },
        .{ "edge_length(a) >= {}", length },                             .{ "notch(a) >= {}", length },
        .{ "space(a) >= {}", length },                                   .{ "space(a, b) >= {}", length },
        .{ "eol_space(a; eol_width: {}) >= 10nm", length },              .{ "eol_space(a; eol_width: 10nm) >= {}", length },
        .{ "prl_space(a; prl: {}) >= 10nm", length },                    .{ "prl_space(a; prl: 10nm) >= {}", length },
        .{ "corner_space(a) >= {}", length },                            .{ "wide_space(a; width: {}) >= 10nm", length },
        .{ "wide_space(a; width: 10nm) >= {}", length },                 .{ "area(a) >= {}", area },
        .{ "hole_area(a) >= {}", area },                                 .{ "cheesing(a) <= {}", area },
        .{ "density(a; window: {}, step: 10nm) >= 0.5", length },        .{ "density(a; window: 10nm, step: {}) >= 0.5", length },
        .{ "density(a; window: 10nm, step: 10nm) >= {}", fraction },     .{ "global_density(a) >= {}", fraction },
        .{ "enclosure(a, b) >= {}", length },                            .{ "enclosure(a, b, opposite) >= {}", length },
        .{ "extension(a, b) >= {}", length },                            .{ "overlap(a, b) >= {}", length },
        .{ "tap_distance(a, b) <= {}", length },                         .{ "off_grid(; pitch: {})", length },
        .{ "redundant_via(a; within: 10nm) >= {}", count },              .{ "redundant_via(a; within: {}) >= 2", length },
        .{ "via_array_space(a; array: 2) >= {}", length },               .{ "patterning(a; colors: {}) >= 10nm", count },
        .{ "patterning(a; colors: 2) >= {}", length },                   .{ "contains(a, b) >= {}", count },
        .{ "space(a; nets: same) >= {}", length },                       .{ "wide_space(a; width: {}, attached: 10nm) >= 10nm", length },
        .{ "wide_space(a; width: 10nm, attached: {}) >= 10nm", length }, .{ "wide_space(a; width: 10nm, attached: 10nm) >= {}", length },
        .{ "length(e) >= {}", length },                                  .{ "space(e) >= {}", length },
        .{ "space(e, f) >= {}", length },                                .{ "enclosure(e, b) >= {}", length },
    };
    for (cases) |c| {
        for (c[1], [2]bool{ true, false }) |value, zero| {
            const rule = try std.mem.replaceOwned(u8, gpa, c[0], "{}", value);
            defer gpa.free(rule);
            const text = try std.fmt.allocPrint(gpa, "{s}rule r {s}\n", .{ header, rule });
            defer gpa.free(text);
            var arena: std.heap.ArenaAllocator = .init(gpa);
            defer arena.deinit();
            var strings: geom.StrTable = .empty;
            defer strings.deinit(gpa);
            var diag: deck.compile.Diag = .{};
            if (deck.compile.compile(gpa, arena.allocator(), text, try geom.Grid.init(1000), &strings, &diag)) |cd_| {
                var cd = cd_;
                cd.deinit(gpa);
                if (zero) {
                    std.debug.print("{s} with {s} compiled\n", .{ c[0], value });
                    return error.TestExpectedRefusal;
                }
            } else |e| {
                if (!zero or e != error.NonPositiveLimit) {
                    std.debug.print("{s} with {s}: {t}\n", .{ c[0], value, e });
                    return e;
                }
                try testing.expectEqualStrings("r", strings.resolve(diag.rule.rule));
            }
        }
    }
}

test "every erc error is still produced" {
    // Oracle: construct-from-answer: each deck differs from a legal one in
    // the one value the variant's documented constraint forbids. A
    // duplicate id across domains is refused by DRC first, so the ERC
    // duplicate comes from the ERC rule set alone.
    var r = try refusal(&.{.{ .id = "g", .kind = "gate_oxide", .layers = 0, .params = &.{.{ "max_voltage", .{ .ratio = 1800.0 } }} }});
    try testing.expectEqual(error.MissingParam, r.err);
    try testing.expectEqualStrings("model", r.diag.param);
    r = try refusal(&.{.{ .id = "d", .kind = "multiple_drivers", .layers = 0, .params = &.{.{ "max_drivers", .{ .ratio = 1.0 } }} }});
    try testing.expectEqual(error.WrongParamType, r.err);
    try testing.expectEqualStrings("max_drivers", r.diag.param);
    // A non-finite limit would pass everything: the wrong kind of value.
    r = try refusal(&.{.{ .id = "p", .kind = "p2p_resistance", .layers = 0, .params = &.{.{ "max_resistance", .{ .ratio = std.math.inf(f64) } }} }});
    try testing.expectEqual(error.WrongParamType, r.err);
    try testing.expectEqualStrings("max_resistance", r.diag.param);
    r = try refusal(&.{.{ .id = "f", .kind = "floating_well", .layers = 1, .params = &.{} }});
    try testing.expectEqual(error.WrongLayerCount, r.err);
    try testing.expectEqual(@as(u32, 2), r.diag.expected);
    try testing.expectEqual(@as(u32, 1), r.diag.found);
    r = try refusal(&.{.{ .id = "p", .kind = "p2p_resistance", .layers = 0, .params = &.{.{ "max_resistance", .{ .ratio = 0.0 } }} }});
    try testing.expectEqual(error.NonPositiveLimit, r.err);
    try testing.expectEqualStrings("max_resistance", r.diag.param);
    r = try refusal(&.{.{ .id = "c", .kind = "density_cmp", .layers = 1, .params = &.{ .{ "window_x", len(10) }, .{ "window_y", len(10) }, .{ "step_x", len(10) }, .{ "step_y", len(10) }, .{ "max_density", .{ .ratio = 1.5 } } } }});
    try testing.expectEqual(error.NotAFraction, r.err);
    try testing.expectEqualStrings("max_density", r.diag.param);
    // A density_cmp row bounding nothing.
    r = try refusal(&.{.{ .id = "c", .kind = "density_cmp", .layers = 1, .params = &.{ .{ "window_x", len(10) }, .{ "window_y", len(10) }, .{ "step_x", len(10) }, .{ "step_y", len(10) } } }});
    try testing.expectEqual(error.MissingParam, r.err);
    try testing.expectEqualStrings("max_density", r.diag.param);

    var strings: geom.StrTable = .empty;
    defer strings.deinit(gpa);
    const x = try strings.intern(gpa, "x");
    const specs = [_]ingest.deck.RuleSpec{
        .{ .id = x, .kind = try strings.intern(gpa, "ir_drop"), .layer_start = 0, .layer_len = 0, .param_start = 0, .param_len = 0 },
        .{ .id = x, .kind = try strings.intern(gpa, "tie_high_low"), .layer_start = 0, .layer_len = 0, .param_start = 0, .param_len = 0 },
    };
    const twice: ingest.deck.Deck = .{ .rules = .{ .spec = &specs } };
    var diag: check.drc.params.Diagnostic = .{};
    try testing.expectError(error.DuplicateRule, check.erc.fromDeck(gpa, &twice, &strings, &diag));
    try testing.expectEqual(x, diag.rule);
}

test "erc validation holds a table built in code" {
    // Oracle: construct-from-answer: a zero resistance limit breaks the
    // documented positive domain; ten ohms keeps it.
    var set: check.erc.RuleSet = .{};
    defer set.deinit(gpa);
    var diag: check.drc.params.Diagnostic = .{};
    try check.erc.validate.validate(&set, &diag);
    try set.tables.p2p_resistance.head.push(gpa, @fromBackingInt(7), .@"error");
    try set.tables.p2p_resistance.max_resistance.append(gpa, .{ .raw = 0.0 });
    try testing.expectError(error.NonPositiveLimit, check.erc.validate.validate(&set, &diag));
    try testing.expectEqualStrings("max_resistance", diag.param);
    try testing.expectEqual(@as(geom.StrId, @fromBackingInt(7)), diag.rule);
    set.tables.p2p_resistance.max_resistance.items[0] = .{ .raw = 10.0 };
    try check.erc.validate.validate(&set, &diag);
}

test "every positive erc value written as zero is refused" {
    // Oracle: the kinds' documented domains: each template compiles with
    // the legal value and is refused as not positive with zero in it,
    // naming the engine parameter.
    var arena: std.heap.ArenaAllocator = .init(gpa);
    defer arena.deinit();
    const em = "max_density: 1000A/m, max_current_per_cut: 80uA, blech_limit: 15000uA, " ++
        "reference_temperature: 378K, activation_energy: 0.9eV, current_exponent: 2";
    const reliability = "required_lifetime: 1000h, reference_lifetime: 1000h, " ++
        "reference_stress: 1.8V, stress_exponent: 2, reference_temperature: 378K, " ++
        "activation_energy: 0.9eV, max_abs_voltage: 1.8V, duty_cycle: 0.5";
    const density = "window: 77nm x 10nm, step: 10nm x 10nm, min: none, max: 0.5, max_delta: none, partial_windows: true";
    const density_cmp = "window: 10nm x 10nm, step: 10nm x 10nm, min: none, max: 0.5, max_delta: none, partial_windows: true";
    const current = "em_current_density(a; max_density: 1000A/m, max_current_per_cut: 80uA, narrow: (width: 30nm, current: 50uA))";
    // (the rule, the value to zero in it, that value's zero, the engine name)
    const cases = [_][4][]const u8{
        .{ "antenna(a, b; max_ratio: 400, sidewall: none, diode: none, diode_area: none, diode_min: none)", "400", "0", "max_ratio" },
        .{ "antenna(a, b; max_ratio: 400, sidewall: 10nm, diode: none, diode_area: none, diode_min: none)", "10nm", "0nm", "sidewall_thickness" },
        .{ "antenna_electrical(a, b; " ++ antenna_electrical ++ ")", "max_ratio: 400", "max_ratio: 0", "max_ratio" },
        .{ "antenna_electrical(a, b; " ++ antenna_electrical ++ ")", "10nm", "0nm", "sidewall_thickness" },
        .{ "antenna_electrical(a, b; " ++ antenna_electrical ++ ")", "cut_factor: 1", "cut_factor: 0", "cut_factor" },
        .{ "antenna_electrical(a, b; " ++ antenna_electrical ++ ")", "(0nm2, 400)", "(0nm2, 0)", "diode_max_ratio" },
        .{ "density_cmp(a; " ++ density ++ ", cmp: none)", "77nm", "0nm", "window_x" },
        .{ "density_cmp(a; " ++ density_cmp ++ ", cmp: (target: 0.5, sensitivity: 10nm, max_delta: 77nm))", "77nm", "0nm", "cmp_max_abs_thickness_delta" },
        .{ "electromigration(a; " ++ em ++ ")", "1000A/m", "0A/m", "max_density" },
        .{ "electromigration(a; " ++ em ++ ")", "80uA", "0uA", "max_current_per_cut" },
        .{ "electromigration(a; " ++ em ++ ")", "15000uA", "0uA", "blech_limit" },
        .{ "electromigration(a; " ++ em ++ ")", "378K", "0K", "reference_temperature" },
        .{ "electromigration(a; " ++ em ++ ")", "0.9eV", "0eV", "activation_energy_ev" },
        .{ "electromigration(a; " ++ em ++ ")", "current_exponent: 2", "current_exponent: 0", "current_exponent" },
        .{ current, "80uA", "0uA", "max_current_per_cut" },
        .{ current, "30nm", "0nm", "narrow_width" },
        .{ current, "50uA", "0uA", "narrow_current" },
        .{ "esd_latchup(a, b; min_guard_ring_width: 10nm, max_tap_distance: 20nm, clamps: [\"nfet\"])", "20nm", "0nm", "max_tap_distance" },
        .{ "hv_domain(; max_delta: 1.8V, isolation: none)", "1.8V", "0V", "max_domain_delta" },
        .{ "missing_tie(a, b; max_distance: 10nm)", "10nm", "0nm", "max_distance" },
        .{ "multiple_drivers(; max: 2)", "2", "0", "max_drivers" },
        .{ "p2p_resistance(; max: 10ohm)", "10ohm", "0ohm", "max_resistance" },
        .{ "reliability(; " ++ reliability ++ ")", "required_lifetime: 1000h", "required_lifetime: 0h", "required_lifetime_hours" },
        .{ "reliability(; " ++ reliability ++ ")", "stress_exponent: 2", "stress_exponent: 0", "stress_exponent" },
        .{ "reliability(; " ++ reliability ++ ")", "duty_cycle: 0.5", "duty_cycle: 0", "duty_cycle" },
        .{ "gate_oxide(; models: [\"nfet\"], max: 1.8V)", "1.8V", "0V", "max_voltage" },
        .{ "drain_source(; models: [\"nfet\"], max: 1.8V)", "1.8V", "0V", "max_voltage" },
    };
    for (cases) |c| {
        const legal = try ruleDeck(c[0]);
        defer gpa.free(legal);
        if (try refusedText(legal)) |r| {
            std.debug.print("{s}: {t} {s}\n", .{ c[0], r.err, r.diag.param });
            return error.TestLegalRefused;
        }
        const broken = try ruleDeck(try replaceOnce(arena.allocator(), c[0], c[1], c[2]));
        defer gpa.free(broken);
        const r = (try refusedText(broken)) orelse return error.TestExpectedRefusal;
        try testing.expectEqual(error.NonPositiveLimit, r.err);
        try testing.expectEqualStrings(c[3], r.diag.param);
    }
}

test "every erc value check refuses its one broken value" {
    // Oracle: construct-from-answer: each deck differs from a legal row
    // (compiled first) in the one value the kind's documentation forbids,
    // so the error is known before anything runs.
    var arena: std.heap.ArenaAllocator = .init(gpa);
    defer arena.deinit();
    const path = "esd_path(a; clamps: [\"nfet\"], current: 1330mA, clamp_resistance: 1ohm, " ++
        "max_resistance: 2ohm, clamp_it2: 9.25mA/um, max_density: 1mA/um, max_current_per_cut: 10mA, " ++
        "max_voltage: 5V, min_width: 7nm, clamp_voltage: 700mV)";
    const cross = "esd_cross_domain(; diodes: [\"nfet\"], local: [\"nfet\"], resistors: [\"nfet\"], " ++
        "min_series: 100ohm, max_ground_resistance: 2ohm, coupling_resistance: 1ohm)";
    const pin_pair = "esd_pin_pair(a; clamps: [\"nfet\"], current: 1330mA, clamp_resistance: 1ohm, max_resistance: 5ohm)";
    const rms = "em_rms(a; frequency: [100MHz, 300MHz], width: [500nm, 1500nm], " ++
        "density: [[1mA/um, 2mA/um], [3mA/um, 4mA/um]], max_current_per_cut: 1mA)";
    const thermal = "em_thermal(a; max_density: 10mA/um, max_current_per_cut: 1mA, " ++
        "blech_limit: 1nA, reference_temperature: 125C, activation_energy: 0.9eV, current_exponent: 2, " ++
        "thermal_conductivity: 0.05W/mK, spreading: 0.88, sigma: 0.5, limit_failure: 10%, max_failure: 20%)";
    const guard = "guard_ring(a, b; max_space: 15um, min_width: 2um, pad: a, near: b, within: 50um, clear: none)";
    const tie = "conditional_tie(a, b, a, b; within: 50um, spacing: [1um, 2um], max_distance: [15um, 30um, 50um])";
    const space = "voltage_space(a; voltage: [0V, 3.3V, 5V], space: [140nm, 300nm, 600nm])";
    const reliability = "reliability(; required_lifetime: 1000h, reference_lifetime: 1000h, " ++
        "reference_stress: 1.8V, stress_exponent: 2, reference_temperature: 378K, " ++
        "activation_energy: 0.9eV, max_abs_voltage: 1.8V, duty_cycle: 0.5)";
    const latchup = "esd_latchup(a, b; min_guard_ring_width: 10nm, max_tap_distance: 20nm, clamps: [\"nfet\"])";
    const victim = "latchup_victim(a, b, a; within: 15um, max_distance: 2um, pad: a, bias: none, forward: none)";
    const clamp_r = "esd_clamp_resistance(a; clamps: [\"nfet\"], max_resistance: 1ohm)";
    const peak = "em_peak(a; frequency: [1GHz], width: [0nm], density: [[6.1mA/um]], max_current_per_cut: 100uA)";
    const no_limit = "esd_path(a; clamps: [\"nfet\"], current: 1mA, clamp_resistance: 1ohm, " ++
        "max_resistance: none, clamp_it2: none, max_density: none, max_current_per_cut: none, " ++
        "max_voltage: none, min_width: 7nm, clamp_voltage: none)";
    const antenna = "antenna_electrical(a, b; " ++ antenna_electrical ++ ")";
    const ac_order = "an AC current table's frequencies and widths rise strictly";
    const ac_shape = "an AC current table has one density per frequency and width";
    const rising = "a voltage table's voltages start at 0 V or more and rise strictly";
    const falling = "a voltage table's spaces never fall as the voltage rises";
    const Case = struct { legal: []const u8, from: []const u8, to: []const u8, err: anyerror, what: []const u8 };
    const z = error.NonPositiveLimit;
    const m = error.MissingParam;
    const t = error.BadTable;
    const w = error.WrongParamType;
    const cases = [_]Case{
        .{ .legal = "well_bias(; pmos: none, nmos: [\"nfet\"])", .from = "[\"nfet\"]", .to = "none", .err = m, .what = "pmos" },
        .{ .legal = path, .from = "current: 1330mA", .to = "current: 0mA", .err = z, .what = "current" },
        .{ .legal = path, .from = "clamp_resistance: 1ohm", .to = "clamp_resistance: 0ohm", .err = z, .what = "clamp_resistance" },
        .{ .legal = path, .from = "max_resistance: 2ohm", .to = "max_resistance: 0ohm", .err = z, .what = "max_resistance" },
        .{ .legal = path, .from = "9.25mA/um", .to = "0mA/um", .err = z, .what = "clamp_it2" },
        .{ .legal = path, .from = "max_density: 1mA/um", .to = "max_density: 0mA/um", .err = z, .what = "max_density" },
        .{ .legal = path, .from = "max_current_per_cut: 10mA", .to = "max_current_per_cut: 0mA", .err = z, .what = "max_current_per_cut" },
        .{ .legal = path, .from = "max_voltage: 5V", .to = "max_voltage: 0V", .err = z, .what = "max_voltage" },
        .{ .legal = path, .from = "min_width: 7nm", .to = "min_width: 0nm", .err = z, .what = "min_width" },
        .{ .legal = path, .from = "clamp_voltage: 700mV", .to = "clamp_voltage: 0mV", .err = z, .what = "clamp_voltage" },
        .{ .legal = no_limit, .from = "min_width: 7nm", .to = "min_width: none", .err = m, .what = "max_resistance" },
        .{ .legal = cross, .from = "min_series: 100ohm", .to = "min_series: 0ohm", .err = z, .what = "min_series" },
        .{ .legal = cross, .from = "max_ground_resistance: 2ohm", .to = "max_ground_resistance: 0ohm", .err = z, .what = "max_ground_resistance" },
        .{ .legal = cross, .from = "coupling_resistance: 1ohm", .to = "coupling_resistance: 0ohm", .err = z, .what = "coupling_resistance" },
        .{ .legal = cross, .from = "resistors: [\"nfet\"]", .to = "resistors: none", .err = m, .what = "resistor" },
        .{ .legal = cross, .from = "coupling_resistance: 1ohm", .to = "coupling_resistance: none", .err = m, .what = "coupling_resistance" },
        .{ .legal = cross, .from = "max_ground_resistance: 2ohm", .to = "max_ground_resistance: none", .err = m, .what = "max_ground_resistance" },
        .{ .legal = pin_pair, .from = "current: 1330mA", .to = "current: 0mA", .err = z, .what = "current" },
        .{ .legal = pin_pair, .from = "clamp_resistance: 1ohm", .to = "clamp_resistance: 0ohm", .err = z, .what = "clamp_resistance" },
        .{ .legal = pin_pair, .from = "max_resistance: 5ohm", .to = "max_resistance: 0ohm", .err = z, .what = "max_resistance" },
        .{ .legal = clamp_r, .from = "1ohm", .to = "0ohm", .err = z, .what = "max_resistance" },
        .{ .legal = "esd_parasitic(a, b; min_spacing: 5um)", .from = "5um", .to = "0um", .err = z, .what = "min_spacing" },
        .{ .legal = latchup, .from = "10nm", .to = "0nm", .err = z, .what = "min_guard_ring_width" },
        .{ .legal = guard, .from = "15um", .to = "0um", .err = z, .what = "max_space" },
        .{ .legal = guard, .from = "2um", .to = "0um", .err = z, .what = "min_width" },
        .{ .legal = guard, .from = "50um", .to = "0um", .err = z, .what = "within" },
        .{ .legal = tie, .from = "within: 50um", .to = "within: 0um", .err = z, .what = "within" },
        .{ .legal = tie, .from = "[1um, 2um]", .to = "[0um, 2um]", .err = z, .what = "spacing" },
        .{ .legal = tie, .from = "50um]", .to = "0um]", .err = z, .what = "max_distance" },
        .{ .legal = tie, .from = "[15um, 30um, 50um]", .to = "[15um, 30um]", .err = w, .what = "max_distance" },
        .{ .legal = tie, .from = "[1um, 2um]", .to = "[2um, 2um]", .err = w, .what = "max_distance" },
        .{ .legal = victim, .from = "15um", .to = "0um", .err = z, .what = "within" },
        .{ .legal = victim, .from = "2um", .to = "0um", .err = z, .what = "max_distance" },
        .{ .legal = "fanout(; max: 2)", .from = "2", .to = "0", .err = z, .what = "max_gates" },
        .{ .legal = "hv_tag(a, b; voltage: 3V)", .from = "3V", .to = "0V", .err = z, .what = "voltage" },
        .{ .legal = "dielectric_field(a; max_field: 10V/um)", .from = "10V/um", .to = "0V/um", .err = z, .what = "max_field" },
        .{ .legal = reliability, .from = "reference_lifetime: 1000h", .to = "reference_lifetime: 0h", .err = z, .what = "reference_lifetime_hours" },
        .{ .legal = reliability, .from = "1.8V, stress", .to = "0V, stress", .err = z, .what = "reference_stress" },
        .{ .legal = reliability, .from = "378K", .to = "0K", .err = z, .what = "reference_temperature" },
        .{ .legal = reliability, .from = "0.9eV", .to = "0eV", .err = z, .what = "activation_energy_ev" },
        .{ .legal = reliability, .from = "max_abs_voltage: 1.8V", .to = "max_abs_voltage: 0V", .err = z, .what = "max_abs_voltage" },
        .{ .legal = rms, .from = "100MHz", .to = "0MHz", .err = z, .what = "frequency" },
        .{ .legal = rms, .from = "[[1mA/um", .to = "[[0mA/um", .err = z, .what = "density" },
        .{ .legal = rms, .from = "max_current_per_cut: 1mA", .to = "max_current_per_cut: 0mA", .err = z, .what = "max_current_per_cut" },
        .{ .legal = rms, .from = "300MHz", .to = "100MHz", .err = t, .what = ac_order },
        .{ .legal = rms, .from = "1500nm", .to = "500nm", .err = t, .what = ac_order },
        .{ .legal = rms, .from = ", [3mA/um, 4mA/um]", .to = "", .err = t, .what = ac_shape },
        .{ .legal = peak, .from = "[1GHz]", .to = "[2GHz, 1GHz]", .err = t, .what = ac_order },
        .{ .legal = thermal, .from = "0.05W/mK", .to = "0W/mK", .err = z, .what = "thermal_conductivity" },
        .{ .legal = thermal, .from = "sigma: 0.5", .to = "sigma: 0", .err = z, .what = "sigma" },
        .{ .legal = thermal, .from = "spreading: 0.88", .to = "spreading: -1", .err = z, .what = "heat_spreading" },
        .{ .legal = thermal, .from = "limit_failure: 10%", .to = "limit_failure: 0%", .err = z, .what = "limit_failure" },
        .{ .legal = thermal, .from = "max_failure: 20%", .to = "max_failure: 0%", .err = z, .what = "max_failure" },
        .{ .legal = thermal, .from = "limit_failure: 10%", .to = "limit_failure: 100%", .err = error.NotAFraction, .what = "limit_failure" },
        .{ .legal = thermal, .from = "max_density: 10mA/um", .to = "max_density: 0mA/um", .err = z, .what = "max_density" },
        .{ .legal = thermal, .from = "max_current_per_cut: 1mA", .to = "max_current_per_cut: 0mA", .err = z, .what = "max_current_per_cut" },
        .{ .legal = thermal, .from = "blech_limit: 1nA", .to = "blech_limit: 0nA", .err = z, .what = "blech_limit" },
        .{ .legal = thermal, .from = "125C", .to = "-273.15C", .err = z, .what = "reference_temperature" },
        .{ .legal = thermal, .from = "0.9eV", .to = "0eV", .err = z, .what = "activation_energy_ev" },
        .{ .legal = thermal, .from = "current_exponent: 2", .to = "current_exponent: 0", .err = z, .what = "current_exponent" },
        .{ .legal = space, .from = "[0V, 3.3V", .to = "[-1V, 3.3V", .err = t, .what = rising },
        .{ .legal = space, .from = "3.3V, 5V", .to = "5V, 5V", .err = t, .what = rising },
        .{ .legal = space, .from = "140nm", .to = "0nm", .err = z, .what = "space" },
        .{ .legal = space, .from = "300nm, 600nm", .to = "600nm, 300nm", .err = t, .what = falling },
        .{ .legal = antenna, .from = "area_minus_diode: 0", .to = "area_minus_diode: -1", .err = z, .what = "area_minus_diode" },
        .{ .legal = antenna, .from = "gate_plus_diode: 0", .to = "gate_plus_diode: -1", .err = z, .what = "gate_plus_diode" },
    };
    var failures: u32 = 0;
    for (cases) |c| {
        const legal = try ruleDeck(c.legal);
        defer gpa.free(legal);
        if (try refusedText(legal)) |r| {
            std.debug.print("legal {s}: {t} {s}\n", .{ c.legal, r.err, r.diag.param });
            failures += 1;
            continue;
        }
        const broken = try ruleDeck(try replaceOnce(arena.allocator(), c.legal, c.from, c.to));
        defer gpa.free(broken);
        const r = (try refusedText(broken)) orelse {
            std.debug.print("{s}: compiled\n", .{broken});
            failures += 1;
            continue;
        };
        const said = if (r.err == error.BadTable) r.diag.why else r.diag.param;
        if (r.err != c.err or !std.mem.eql(u8, said, c.what)) {
            std.debug.print("{s}: want {t} {s}, got {t} {s}\n", .{ broken, c.err, c.what, r.err, said });
            failures += 1;
        }
    }
    try testing.expectEqual(@as(u32, 0), failures);
}

test "erc validation refuses a table broken in code" {
    // Oracle: construct-from-answer: every row of the deck compiles, then
    // one row's model, clamp or diode list is emptied or one fraction set
    // outside its range, which the kind's documentation forbids.
    const text = header ++
        \\rule gc esd_ground_coupling(; diodes: ["nfet"])
        \\rule xd esd_cross_domain(; diodes: ["nfet"], local: none, resistors: none, min_series: none, max_ground_resistance: none, coupling_resistance: none)
        \\rule ps power_switch(; models: ["nfet"])
        \\rule pp esd_pin_pair(a; clamps: ["nfet"], current: 1330mA, clamp_resistance: 1ohm, max_resistance: 5ohm)
        \\rule cr esd_clamp_resistance(a; clamps: ["nfet"], max_resistance: 1ohm)
        \\rule et esd_topological(a; clamps: ["nfet"])
        \\rule ex esd_exposed(a; clamps: ["nfet"], resistors: none, rated: ["nfet"], min_series: none)
        \\rule fd forward_diode(a; models: ["nfet"])
        \\rule el esd_latchup(a, b; min_guard_ring_width: 10nm, max_tap_distance: 20nm, clamps: ["nfet"])
        \\rule go gate_oxide(; models: ["nfet"], max: 1.8V)
        \\rule ds drain_source(; models: ["nfet"], max: 1.8V)
        \\rule ta tie_area(a, b, a; min_ratio: 3%)
        \\rule rl reliability(; required_lifetime: 1000h, reference_lifetime: 1000h, reference_stress: 1.8V, stress_exponent: 2, reference_temperature: 378K, activation_energy: 0.9eV, max_abs_voltage: 1.8V, duty_cycle: 0.5)
        \\rule th em_thermal(a; max_density: 10mA/um, max_current_per_cut: 1mA, blech_limit: 1nA, reference_temperature: 125C, activation_energy: 0.9eV, current_exponent: 2, thermal_conductivity: 0.05W/mK, spreading: 0.88, sigma: 0.5, limit_failure: 10%, max_failure: 20%)
        \\
    ;
    var arena: std.heap.ArenaAllocator = .init(gpa);
    defer arena.deinit();
    var strings: geom.StrTable = .empty;
    defer strings.deinit(gpa);
    var cdiag: deck.compile.Diag = .{};
    var cd = try deck.compile.compile(gpa, arena.allocator(), text, try geom.Grid.init(1000), &strings, &cdiag);
    defer cd.deinit(gpa);
    const set = &cd.erc;
    var diag: check.drc.params.Diagnostic = .{};
    try check.erc.validate.validate(set, &diag);
    const tt = &set.tables;
    // Each table holds one row, so `start[1] = 0` empties its CSR span.
    const Span = struct { start: *std.ArrayList(u32), rule: []const u8, param: []const u8 };
    const spans = [_]Span{
        .{ .start = &tt.esd_ground_coupling.diode_start, .rule = "gc", .param = "diode" },
        .{ .start = &tt.esd_cross_domain.diode_start, .rule = "xd", .param = "diode" },
        .{ .start = &tt.power_switch.model_start, .rule = "ps", .param = "model" },
        .{ .start = &tt.esd_pin_pair.clamp_start, .rule = "pp", .param = "clamp" },
        .{ .start = &tt.esd_clamp_resistance.clamp_start, .rule = "cr", .param = "clamp" },
        .{ .start = &tt.esd_topological.clamp_start, .rule = "et", .param = "clamp" },
        .{ .start = &tt.esd_exposed.clamp_start, .rule = "ex", .param = "clamp" },
        .{ .start = &tt.forward_diode.model_start, .rule = "fd", .param = "model" },
        .{ .start = &tt.esd_latchup.clamp_start, .rule = "el", .param = "clamp" },
        .{ .start = &tt.gate_oxide.model_start, .rule = "go", .param = "model" },
        .{ .start = &tt.drain_source.model_start, .rule = "ds", .param = "model" },
    };
    for (spans) |s| {
        const keep = s.start.items[1];
        s.start.items[1] = 0;
        defer s.start.items[1] = keep;
        try testing.expectError(error.MissingParam, check.erc.validate.validate(set, &diag));
        try testing.expectEqualStrings(s.rule, strings.resolve(diag.rule));
        try testing.expectEqualStrings(s.param, diag.param);
    }
    const Fraction = struct { value: *f64, to: f64, rule: []const u8, param: []const u8, err: anyerror };
    const fractions = [_]Fraction{
        .{ .value = &tt.tie_area.min_ratio.items[0], .to = 1.5, .rule = "ta", .param = "min_ratio", .err = error.NotAFraction },
        .{ .value = &tt.tie_area.min_ratio.items[0], .to = -0.5, .rule = "ta", .param = "min_ratio", .err = error.NotAFraction },
        .{ .value = &tt.reliability.duty_cycle.items[0], .to = 1.5, .rule = "rl", .param = "duty_cycle", .err = error.NotAFraction },
        .{ .value = &tt.em_thermal.max_failure.items[0], .to = 1.5, .rule = "th", .param = "max_failure", .err = error.NotAFraction },
        .{ .value = &tt.em_thermal.limit_failure.items[0], .to = std.math.nan(f64), .rule = "th", .param = "limit_failure", .err = error.WrongParamType },
    };
    for (fractions) |f| {
        const keep = f.value.*;
        f.value.* = f.to;
        defer f.value.* = keep;
        try testing.expectError(f.err, check.erc.validate.validate(set, &diag));
        try testing.expectEqualStrings(f.rule, strings.resolve(diag.rule));
        try testing.expectEqualStrings(f.param, diag.param);
    }
}
