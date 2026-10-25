//! The deck language's error classes and its parasitic statements (`pex`,
//! `temperature`, `corner`, `extraction`). Ported from the error-class and
//! stack tests of crates/ingest/tests/deck_text.rs.

const std = @import("std");
const testing = std.testing;
const ingest = @import("ingest");
const deck = ingest.deck;
const fx = @import("deck_fixture.zig");
const ok = fx.ok;
const oneError = fx.oneError;
const gpa = testing.allocator;

/// sky130's metal rows as `pex` lines: `sheet` at the models' `tnom`, 30 °C,
/// with the models' `tc1rm1`/`tc2rm1` and `tc1rm2`/`tc2rm2`.
const sky130_metals =
    \\pex met1 thickness 360nm height 1376nm sheet 0.125ohm dielectric 3.9 area_cap 25.8aF/um2 fringe_cap 40.5aF/um tc1 3.179e-3/K tc2 3.094e-7/K2
    \\pex met2 thickness 360nm height 2006nm sheet 0.125ohm dielectric 3.9 area_cap 17.5aF/um2 fringe_cap 37.6aF/um tc1 3.161e-3/K tc2 -7.272e-7/K2
    \\
;

var space_buf: [256]u8 = @splat(' ');

var caret_buf: [256]u8 = @splat('^');

const corner_rows =
    \\pex met1 thickness 360nm height 1376nm sheet 0.125ohm dielectric 3.9 area_cap 25.8aF/um2 fringe_cap 40.5aF/um
    \\pex met2 thickness 360nm height 2006nm sheet 0.125ohm dielectric 4.2 area_cap 17.5aF/um2 fringe_cap 37.8aF/um
    \\
;

// ---- private ----

fn bits(v: f64) u64 {
    return @bitCast(v);
}

/// The rendered refusal of `text` under the file name `file`.
fn rendered(text: []const u8, file: []const u8) ![]u8 {
    var o = try fx.runText(text);
    defer o.deinit();
    var out: std.Io.Writer.Allocating = .init(gpa);
    errdefer out.deinit();
    try deck.render(&out.writer, file, try fx.errors(&o));
    return out.toOwnedSlice();
}

fn spaces(n: usize) ![]const u8 {
    return space_buf[0..n];
}

fn carets(n: usize) ![]const u8 {
    return caret_buf[0..n];
}

/// `row` with the value of `key value`'s key replaced, and a newline.
fn replaced(row: []const u8, key_value: []const u8) ![]u8 {
    const sp = std.mem.indexOfScalar(u8, key_value, ' ').?;
    const key = key_value[0..sp];
    const needle = try std.fmt.allocPrint(gpa, "{s} ", .{key});
    defer gpa.free(needle);
    const at = std.mem.indexOf(u8, row, needle).? + key.len + 1;
    const end = if (std.mem.indexOfScalarPos(u8, row, at, ' ')) |e| e else row.len;
    return std.fmt.allocPrint(gpa, "{s}{s}{s}\n", .{ row[0..at], key_value[sp + 1 ..], row[end..] });
}

test "a missing parameter is an error" {
    // Oracle: the documented forms in docs/deck.md: `eol_space(L; eol_width:
    // len)`, and `antenna(..; max_ratio, sidewall, diode)` under "Every
    // parameter below is required".
    try oneError("rule e eol_space(met1) >= 100nm\n", "missing parameter `eol_width`");
    try oneError("rule a antenna(poly, met1; max_ratio: 400)\n", "missing parameter `sidewall`");
}

test "an unknown parameter is an error" {
    // Oracle: the documented parameter lists of docs/deck.md: `eol_space` has
    // no `colour` and the CMP model no `thickness`.
    try oneError("rule e eol_space(met1; eol_width: 100nm, colour: 3) >= 100nm\n", "unknown parameter `colour`");
    try oneError(
        \\rule d density_cmp(met1; window: 1um x 1um, step: 1um x 1um, min: none, max: 0.7,
        \\    max_delta: none, partial_windows: false,
        \\    cmp: (target: 0.5, thickness: 400nm, sensitivity: 200nm, max_delta: 50nm))
        \\
    , "unknown parameter `thickness`");
}

test "a bare number where a unit belongs is an error" {
    // Oracle: docs/deck.md, Basics: numbers carry units, and only a count,
    // ratio or exponent is bare; the message is the spec's Errors example.
    try oneError("rule m1.5 enclosure(mcon, met1, opposite) >= 60\n", "m1.5: enclosure needs a length, got 60 (no unit)");
}

test "a unit of the wrong dimension is an error" {
    // Oracle: the units table of docs/deck.md: `um2` is an area, `uA` a
    // current, neither a length nor a voltage.
    try oneError("rule w width(met1) >= 0.083um2\n", "needs a length, got 0.083um2 (an area)");
    try oneError("rule hv hv_domain(; max_delta: 5uA, isolation: none)\n", "needs a voltage");
}

test "an off-grid length is an error" {
    // Oracle: docs/deck.md, Basics: "`142nm` on a 5 nm grid is an error, not
    // a rounding"; 30 nm2 is likewise not a multiple of 25 nm2.
    try oneError("rule w width(met1) >= 142nm\n", "142nm is not a multiple of the grid");
    try oneError("rule a area(met1) >= 30nm2\n", "not a multiple of the grid squared");
}

test "the wrong comparator is an error, not a flip" {
    // Oracle: docs/deck.md, Rules: "Writing `<=` on a minimum rule is an
    // error, not a flipped rule"; `tap_distance` is documented with `<=`,
    // `width` with a comparison, `off_grid` with none.
    try oneError("rule t tap_distance(diff, li) >= 10um\n", "`>=` is not legal on `tap_distance`; it takes `<=`");
    try oneError("rule w width(met1)\n", "`width` needs a comparison");
    // `size` also has a form without one, `size(L; allowed: [..])`.
    try oneError("rule s size(met1)\n", "`size` needs a comparison: `==`");
    try oneError("rule g off_grid(; pitch: 5nm) >= 5nm\n", "`off_grid` takes no comparison");
}

test "an unknown layer is an error" {
    // Oracle: docs/deck.md: a layer must be declared, and `met9` is not in
    // the header.
    try oneError("rule w width(met9) >= 100nm\n", "unknown layer `met9`");
}

test "a forward reference is an error" {
    // Oracle: docs/deck.md, Layers: "A layer must be declared before
    // anything uses it", and a `let` name likewise.
    try oneError("rule w width(met4) >= 100nm\nlayer met4 = gds(71, 20)\n", "`met4` is used before its declaration on line");
    try oneError("rule w width(met1) >= w\nlet w = 100nm\n", "`w` is used before its declaration");
}

test "rebinding a name is an error" {
    // Oracle: docs/deck.md, Reuse: "A name can be bound once", whether by
    // `let` or `layer`.
    try oneError("let w = 1nm\nlet w = 2nm\n", "`w` is already bound");
    try oneError("layer met1 = gds(1, 1)\n", "`met1` is already bound");
    try oneError("let met1 = 5nm\n", "`met1` is already bound");
}

test "a duplicate rule id is an error" {
    // Oracle: docs/deck.md, Rules: the id is how violations are reported, so
    // it is unique.
    try oneError("rule w width(met1) >= 100nm\nrule w width(met1) >= 200nm\n", "duplicate rule id `w`");
}

test "errors are collected and capped at fifty" {
    // Oracle: docs/deck.md, Errors: problems are "reported together (up to
    // 50)". Eighty off-grid rules give fifty; three different faults give
    // three.
    var body: std.ArrayList(u8) = .empty;
    defer body.deinit(gpa);
    for (0..80) |i| try body.print(gpa, "rule r{d} width(met1) >= 142nm\n", .{i});
    var o = try fx.run(body.items);
    defer o.deinit();
    try testing.expectEqual(50, (try fx.errors(&o)).len);
    var t = try fx.run("rule a width(met1) >= 1nm\nrule b width(met9) >= 5nm\nrule c space(met1) <= 5nm\n");
    defer t.deinit();
    try testing.expectEqual(3, (try fx.errors(&t)).len);
}

test "a pex row with a value no process has is refused at the value" {
    // Oracle: docs/deck.md, Parasitic stack: "the thickness positive, a
    // stated dielectric positive, the rest zero or more", and the error marks
    // the value, so each case's caret is placed by hand under its value.
    const base = "pex met1 thickness 360nm height 1376nm sheet 0.125ohm dielectric 3.9 area_cap 25.8aF/um2 fringe_cap 40.5aF/um";
    const cases = [_][2][]const u8{
        .{ "thickness 0nm", "thickness must be positive" },
        .{ "thickness -360nm", "thickness must be positive" },
        .{ "height -1nm", "height must be zero or more" },
        .{ "sheet -0.125ohm", "sheet must be zero or more" },
        .{ "dielectric -3.9", "dielectric must be positive" },
        .{ "dielectric 0", "dielectric must be positive" },
        .{ "area_cap -25aF/um2", "area_cap must be zero or more" },
        .{ "fringe_cap -40aF/um", "fringe_cap must be zero or more" },
        // Past f64's range a decimal reads as infinite, which no process has.
        .{ "thickness 1e999nm", "thickness must be positive and finite" },
        .{ "sheet 1e999ohm", "sheet must be zero or more, and finite" },
    };
    for (cases) |c| {
        const body = try replaced(base, c[0]);
        defer gpa.free(body);
        const text = try std.mem.concat(gpa, u8, &.{ fx.head, body });
        defer gpa.free(text);
        const err = try rendered(text, "<deck>");
        defer gpa.free(err);
        const stated = c[0][std.mem.indexOfScalar(u8, c[0], ' ').? + 1 ..];
        const caret = try std.fmt.allocPrint(gpa, "{s}{s}", .{ try spaces(std.mem.indexOf(u8, body, stated).?), try carets(stated.len) });
        defer gpa.free(caret);
        const want = try std.fmt.allocPrint(gpa, "pex `met1`: {s}", .{c[1]});
        defer gpa.free(want);
        try testing.expect(std.mem.indexOf(u8, err, want) != null);
        try testing.expect(std.mem.endsWith(u8, err, caret));
    }
    for ([_][]const u8{ "height 0nm", "sheet 0ohm", "area_cap 0aF/um2", "fringe_cap 0aF/um" }) |value| {
        const body = try replaced(base, value);
        defer gpa.free(body);
        var o = try ok(body);
        o.deinit();
    }
}

test "a pex value past the range of a float is refused at the value" {
    // Oracle: IEEE 754: `1e400` overflows binary64 (largest finite about
    // 1.8e308), so each such value is refused as not finite.
    const keys = [_][2][]const u8{
        .{ "thickness", "1e400nm" }, .{ "height", "1e400nm" },       .{ "sheet", "1e400ohm" },
        .{ "dielectric", "1e400" },  .{ "area_cap", "1e400aF/um2" }, .{ "fringe_cap", "1e400aF/um" },
    };
    const base = "pex met1 thickness 360nm height 1376nm sheet 0.125ohm dielectric 3.9 area_cap 25.8aF/um2 fringe_cap 40.5aF/um";
    for (keys) |k| {
        const kv = try std.fmt.allocPrint(gpa, "{s} {s}", .{ k[0], k[1] });
        defer gpa.free(kv);
        const body = try replaced(base, kv);
        defer gpa.free(body);
        const text = try std.mem.concat(gpa, u8, &.{ fx.head, body });
        defer gpa.free(text);
        const err = try rendered(text, "<deck>");
        defer gpa.free(err);
        const want = try std.fmt.allocPrint(gpa, "pex `met1`: {s} must be", .{k[0]});
        defer gpa.free(want);
        try testing.expect(std.mem.indexOf(u8, err, want) != null and std.mem.indexOf(u8, err, "finite") != null);
    }
}

test "a pex row may leave its dielectric out and nothing else" {
    // Oracle: docs/deck.md, Parasitic stack: "Every value is required but
    // the dielectric", and a zero is "not stated"; the sheet is read back as
    // written, 1.2675 ohm.
    var o = try ok("pex met1 thickness 36nm height 0nm sheet 1.2675ohm area_cap 0aF/um2 fringe_cap 0aF/um\n");
    defer o.deinit();
    const met1 = o.at("met1");
    try testing.expectEqual(bits(0.0), bits(o.d().stack.dielectric_k[met1]));
    try testing.expectEqual(bits(1.2675), bits(o.d().stack.sheet_res_ohm_sq[met1]));
    try oneError("pex met1 thickness 36nm height 0nm dielectric 3.9 area_cap 0aF/um2 fringe_cap 0aF/um\n", "pex `met1` is missing sheet");
}

test "an error renders file, line, column and a caret" {
    // Oracle: hand-derived. The format is docs/deck.md's Errors example; the
    // `60` is on line 3 (after `grid` and `layer`) at column 26, two
    // characters wide.
    const err = try rendered("grid 5nm\nlayer met1 = gds(68, 20)\nrule m1.1 width(met1) >= 60\n", "pdks/x.deck");
    defer gpa.free(err);
    try testing.expectEqualStrings("pdks/x.deck:3:26: m1.1: width needs a length, got 60 (no unit)\nrule m1.1 width(met1) >= 60\n                         ^^", err);
}

test "a temperature moves each sheet resistance by its own coefficients" {
    // Oracle: closed form `R(T) = R0 (1 + tc1 ΔT + tc2 ΔT²)` (ngspice's
    // resistor law) by hand with sky130's met1 and met2 coefficients at 85 °C
    // over 30 °C (ΔT = 55 K): met1 0.146972616875 Ω, met2 0.1464569025 Ω;
    // 85 °C is 358.15 K.
    var o = try ok("temperature 85C nominal 30C\n" ++ sky130_metals);
    defer o.deinit();
    for ([_]struct { []const u8, f64 }{ .{ "met1", 0.146_972_616_875 }, .{ "met2", 0.146_456_902_5 } }) |c| {
        const got = o.d().stack.sheet_res_ohm_sq[o.at(c[0])];
        try testing.expect(@abs(got / c[1] - 1.0) < 1e-12);
    }
    try testing.expect(@abs(o.d().temperature.?.raw - 358.15) < 1e-9);
}

test "at its nominal temperature a deck reads its sheets as written" {
    // Oracle: metamorphic relation: the deck run at T = T0 and the same deck
    // with no temperature and no coefficients give bit-identical stacks (ΔT
    // is exactly 0, so the factor is exactly 1), each sheet the 0.125 Ω
    // written.
    var hot = try ok("temperature 30C nominal 30C\n" ++ sky130_metals);
    defer hot.deinit();
    var plain: std.ArrayList(u8) = .empty;
    defer plain.deinit(gpa);
    var lines = std.mem.splitScalar(u8, sky130_metals, '\n');
    while (lines.next()) |line| {
        if (line.len == 0) continue;
        try plain.appendSlice(gpa, line[0..std.mem.indexOf(u8, line, " tc1").?]);
        try plain.append(gpa, '\n');
    }
    var cold = try ok(plain.items);
    defer cold.deinit();
    try testing.expectEqual(bits(0.125), bits(hot.d().stack.sheet_res_ohm_sq[hot.at("met1")]));
    for (hot.d().stack.sheet_res_ohm_sq, cold.d().stack.sheet_res_ohm_sq) |a, b| try testing.expectEqual(bits(a), bits(b));
    try testing.expectEqual(null, cold.d().temperature);
}

test "a temperature and its coefficients come together" {
    // Oracle: docs/deck.md, Parasitic stack: with a `temperature` every row
    // gives `tc1` and `tc2`, without one none does, both or neither on a
    // row, coefficients in `/K` and `/K2`, the resistance positive at
    // temperature (`1 − 0.02 × 55 = −0.1` here), one statement, above
    // absolute zero.
    try fx.malformed(sky130_metals, "pex met1: tc1 and tc2 need a `temperature` statement");
    const row = "pex met1 thickness 360nm height 1376nm sheet 0.125ohm area_cap 0aF/um2 fringe_cap 0aF/um";
    const t = "temperature 85C nominal 30C\n";
    try fx.malformed(t ++ row ++ "\n", "pex met1: the deck states a temperature, so the row needs tc1 and tc2");
    try fx.malformed(t ++ row ++ " tc1 -0.02/K tc2 0/K2\n", "a resistance stays positive");
    try oneError(t ++ row ++ " tc1 3e-3/K\n", "pex `met1` gives one of tc1 and tc2; give both, or neither");
    try oneError(t ++ row ++ " tc1 3e-3 tc2 0/K2\n", "tc1 needs a coefficient per kelvin");
    try oneError(t ++ row ++ " tc1 3e-3/K tc2 3e-7/K\n", "tc2 needs a coefficient per kelvin squared");
    try oneError(t ++ t, "the temperature is already stated");
    try oneError("temperature -300C nominal 30C\n", "temperature must be above absolute zero");
    try oneError("temperature 85C\n", "expected `nominal`");
}

test "a piecewise linear table lowers point by point and must rise" {
    // Oracle: LEF/DEF 5.8's `PWL ( ( d1 r1 ) ( d2 r2 ) ... )` as a list of
    // `(area, number)` points: each lowers to its area in square grid units
    // (0.0125 µm² is 12 500) and its number, in deck order; areas start at 0
    // or more and rise strictly; a point is a pair, and a table has one.
    const head = "rule ae antenna_electrical(poly, met1; max_ratio: 400, sidewall: none, cut_factor: 1, diode: diff,\n    diode_credit: 0, diode_bonus: 0, area_minus_diode: 0, gate_plus_diode: 0,\n    diode_reduce: none, diode_max_ratio: ";
    const tail = ", exempt: none)\n";
    var o = try ok(head ++ "[(0um2, 400), (0.0125um2, 400), (22.5um2, 11600)]" ++ tail);
    defer o.deinit();
    try fx.expectStrings(&.{
        "max_ratio=400",                  "cut_factor=1",               "diode_layer=diff",
        "diode_credit=0",                 "diode_bonus=0",              "area_minus_diode=0",
        "gate_plus_diode=0",              "diode_max_ratio_area=0dbu2", "diode_max_ratio=400",
        "diode_max_ratio_area=12500dbu2", "diode_max_ratio=400",        "diode_max_ratio_area=22500000dbu2",
        "diode_max_ratio=11600",
    }, (try o.rules())[0].params);
    try oneError(head ++ "[(0.1um2, 400), (0.1um2, 500)]" ++ tail, "rise strictly");
    try oneError(head ++ "[(0.1um2, 400), (0.05um2, 500)]" ++ tail, "rise strictly");
    try oneError(head ++ "[(0um2, 400, 1)]" ++ tail, "(area, number) points");
    try oneError(head ++ "[]" ++ tail, "at least one point");
}

test "an extraction line names a type and an optional threshold" {
    // Oracle: hand-derived from the statement's definition (deck.md): each
    // spelling's type, each unit's attofarads (0.1 fF is 100 aF, 0.002 pF
    // 2000), each misuse's message (PEX-008).
    var none = try ok("");
    defer none.deinit();
    try testing.expectEqual(deck.Extraction{}, none.d().extraction);
    try testing.expectEqual(deck.ExtractionKind.rcc, none.d().extraction.kind);
    const cases = [_]struct { []const u8, deck.ExtractionKind, f64 }{
        .{ "extraction r\n", .r, 0 },
        .{ "extraction c\n", .c, 0 },
        .{ "extraction cc\n", .cc, 0 },
        .{ "extraction rc\n", .rc, 0 },
        .{ "extraction rcc\n", .rcc, 0 },
        .{ "extraction rcc coupling_threshold 0.1fF\n", .rcc, 100 },
        .{ "extraction cc coupling_threshold 250aF\n", .cc, 250 },
        .{ "extraction rcc coupling_threshold 0.002pF\n", .rcc, 2000 },
        .{ "extraction rc coupling_threshold 0fF\n", .rc, 0 },
    };
    for (cases) |c| {
        var o = try ok(c[0]);
        defer o.deinit();
        try testing.expectEqual(c[1], o.d().extraction.kind);
        try testing.expect(@abs(o.d().extraction.coupling_threshold_af - c[2]) <= 1e-12 * @max(c[2], 1.0));
    }
    const bad = [_][2][]const u8{
        .{ "extraction rlc\n", "unknown extraction type `rlc`" },
        .{ "extraction rc coupling_threshold 0.1fF\n", "`rc` keeps no coupling" },
        .{ "extraction c coupling_threshold 1fF\n", "`c` keeps no coupling" },
        .{ "extraction rcc coupling_threshold -0.1fF\n", "coupling_threshold must be zero or more" },
        .{ "extraction rcc coupling_threshold 0.1fF/um\n", "coupling_threshold needs a capacitance" },
        .{ "extraction rcc threshold 0.1fF\n", "unknown extraction key" },
        .{ "extraction rc\nextraction rcc\n", "the extraction type is already stated" },
    };
    for (bad) |b| try oneError(b[0], b[1]);
}

test "a corner line varies the nominal pex rows" {
    // Oracle: construct-from-answer (PEX-006): every value a corner states
    // lands on its row, every other is the nominal row's, bit for bit.
    var o = try ok(corner_rows ++ "corner cmax met1 thickness 396nm sheet 0.11ohm\ncorner cmin met1 thickness 324nm\ncorner cmax met2 dielectric 4.4\n");
    defer o.deinit();
    const met1 = o.at("met1");
    const met2 = o.at("met2");
    const corners = o.d().corners;
    try testing.expectEqual(2, corners.len);
    try testing.expectEqualStrings("cmax", o.strings.resolve(corners[0].name));
    try testing.expectEqualStrings("cmin", o.strings.resolve(corners[1].name));
    const cmax = corners[0].stack;
    const cmin = corners[1].stack;
    try testing.expectEqual(bits(396.0), bits(cmax.thickness_nm[met1]));
    try testing.expectEqual(bits(0.11), bits(cmax.sheet_res_ohm_sq[met1]));
    try testing.expectEqual(bits(4.4), bits(cmax.dielectric_k[met2]));
    try testing.expectEqual(bits(324.0), bits(cmin.thickness_nm[met1]));
    for ([_]deck.ProcessStack{ cmax, cmin }) |s| {
        try testing.expectEqual(bits(1376.0), bits(s.height_nm[met1]));
        try testing.expectEqual(bits(17.5), bits(s.area_cap_af_um2[met2]));
    }
    try testing.expectEqual(bits(0.125), bits(cmin.sheet_res_ohm_sq[met1]));
    try testing.expectEqual(bits(4.2), bits(cmin.dielectric_k[met2]));
    try testing.expectEqual(bits(360.0), bits(o.d().stack.thickness_nm[met1]));
    var plain = try ok(corner_rows);
    defer plain.deinit();
    try testing.expectEqual(0, plain.d().corners.len);
    const bad = [_][2][]const u8{
        .{ "corner cmax met1 thickness 396nm\ncorner cmax met1 sheet 0.1ohm\n", "corner `cmax` already states `met1`" },
        .{ "corner cmax met1\n", "corner `cmax` states nothing for `met1`" },
        .{ "corner cmax met1 width 1nm\n", "unknown pex key `width`" },
        .{ "corner cmax met1 thickness 0nm\n", "pex `met1`: thickness must be positive" },
        .{ "corner cmax met1 sheet -1ohm\n", "pex `met1`: sheet must be zero or more" },
        .{ "corner cmax nolayer sheet 1ohm\n", "nolayer" },
    };
    for (bad) |b| {
        const text = try std.mem.concat(gpa, u8, &.{ corner_rows, b[0] });
        defer gpa.free(text);
        try oneError(text, b[1]);
    }
    try fx.malformed("corner cmax met3 sheet 0.1ohm\n", "met3 has no pex row");
}

test "a corner's sheet moves with the deck's temperature" {
    // Oracle: closed form `R(T) = R0 (1 + tc1 ΔT + tc2 ΔT²)` by hand with
    // sky130's met1 coefficients at 85 °C over 30 °C: the factor is
    // 1.175780935, so a `cmax` sheet of 0.15 Ω reads 0.17636714025 Ω, a
    // `cmin` that states no sheet the nominal row's 0.146972616875 Ω, and a
    // corner stating `tc1 0/K tc2 0/K2` its 0.2 Ω as written.
    var o = try ok("temperature 85C nominal 30C\n" ++ sky130_metals ++ "corner cmax met1 sheet 0.15ohm\ncorner cmin met1 thickness 324nm\ncorner flat met2 sheet 0.2ohm tc1 0/K tc2 0/K2\n");
    defer o.deinit();
    const met1 = o.at("met1");
    const met2 = o.at("met2");
    for ([_]struct { usize, usize, f64 }{ .{ 0, met1, 0.176_367_140_25 }, .{ 1, met1, 0.146_972_616_875 }, .{ 2, met2, 0.2 } }) |c| {
        const got = o.d().corners[c[0]].stack.sheet_res_ohm_sq[c[1]];
        try testing.expect(@abs(got / c[2] - 1.0) < 1e-12);
    }
    try fx.malformed("temperature 85C nominal 30C\n" ++ sky130_metals ++ "corner cmax met1 sheet 0.15ohm tc1 0/K\n", "gives one of tc1 and tc2");
}
