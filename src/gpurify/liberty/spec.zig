//! The macro spec: JSON text → a validated `MacroSpec`, what a layout cannot
//! say about its own interface (which pin is a clock or analog, the arcs,
//! each corner's supply voltages and model lines). Ported from
//! src/liberty/spec.rs, with `Accuracy` from src/liberty/mod.rs.
//!
//! Unknown keys are refused throughout (serde's `deny_unknown_fields`): a
//! misspelled key would otherwise silently drop an arc or a corner. Units:
//! V, °C, ns, pF, Hz, and percent of a pin's swing for thresholds. Build a
//! spec with `parse`, never by hand: the characterizer trusts every relation
//! it checks. Every slice lives in the caller's arena.
//!
//! Contents:
//! - `pub const Accuracy = enum`, `Accuracy.all`, `Accuracy.name(a) []const u8`, `Accuracy.describe(a) []const u8`, `Accuracy.parse(text: []const u8) ?Accuracy`
//! - `pub const Diagnostic = struct { message: []const u8 }`
//! - `pub fn Sorted(comptime T: type) type`, `get(s, name: []const u8) ?T`, `jsonParse`
//! - `pub const Vector = Sorted(Level)`, `pub const Level = union(enum)`, `Level.jsonParse`
//! - `pub const Role = enum`, `Role.isSupply(r) bool`, `Role.isDigitalInput(r) bool`
//! - `pub const Direction = enum`, `pub const ArcKind = enum`, `ArcKind.isConstraint(k) bool`, `ArcKind.isHold(k) bool`, `ArcKind.clockEdge(k) ?Edge`
//! - `pub const Edge = enum`, `Edge.flip(e) Edge`
//! - `pub const PinSpec`, `ArcSpec`, `CaseSpec`, `Check`, `CornerSpec`, `Characterization`, `Simulator`, `Levels`, `MacroSpec`
//! - `MacroSpec.pinIndex(s: *const MacroSpec, name: []const u8) ?usize`
//! - `pub const Error = error{ Malformed, Invalid } || Allocator.Error`
//! - `pub fn parse(arena: Allocator, text: []const u8, diag: *Diagnostic) Error!MacroSpec`

const std = @import("std");
const Allocator = std.mem.Allocator;
const json = std.json;

/// How much is measured, and how. Ordered cheapest first: a higher level
/// measures everything a lower one does, more exactly.
pub const Accuracy = enum(u8) {
    /// Pins, `pg_pin`s, directions and area; no simulator runs.
    interface,
    /// Closed-form wire C plus each touching device's static model C; leakage simulated.
    analytical,
    /// As `analytical`, the signal pins' wiring field-solved (50 nm panels).
    field,
    /// The extracted RC netlist simulated: NLDM tables, setup/hold, energy, leakage.
    spice,
    /// As `spice`, plus LVF `ocv_sigma_*` over `mc_samples` Monte Carlo redraws.
    statistical,

    /// Every level, cheapest first: what `"accuracy": "all"` runs.
    pub const all = [_]Accuracy{ .interface, .analytical, .field, .spice, .statistical };

    /// The level's spelling in the spec and in each `.lib` header comment.
    pub fn name(a: Accuracy) []const u8 {
        return @tagName(a);
    }

    /// One line on what the level measured, for each `.lib`'s header comment.
    pub fn describe(a: Accuracy) []const u8 {
        return switch (a) {
            .interface => "pins, supplies and area only",
            .analytical => "closed-form wire capacitance plus static device capacitance; no arcs",
            .field => "field-solved wire capacitance plus static device capacitance; no arcs",
            .spice => "SPICE characterization of the extracted RC netlist",
            .statistical => "SPICE characterization of the extracted RC netlist, plus Monte Carlo sigma",
        };
    }

    /// A level from its name or its number `0`..`4`; null for anything
    /// else, `all` included.
    pub fn parse(text: []const u8) ?Accuracy {
        for (all, 0..) |a, level| {
            if (std.mem.eql(u8, text, a.name())) return a;
            if (text.len == 1 and text[0] == '0' + level) return a;
        }
        return null;
    }
};

/// The message of the last refusal, in the caller's arena.
pub const Diagnostic = struct { message: []const u8 = "" };

/// A JSON object read as parallel slices sorted by key (a `BTreeMap`): a
/// repeated key keeps its last value.
pub fn Sorted(comptime T: type) type {
    return struct {
        const Self = @This();
        names: []const []const u8 = &.{},
        values: []const T = &.{},

        pub fn get(s: Self, key: []const u8) ?T {
            const i = std.sort.binarySearch([]const u8, s.names, key, order) orelse return null;
            return s.values[i];
        }

        pub fn jsonParse(arena: Allocator, source: anytype, options: json.ParseOptions) !Self {
            var names: std.ArrayList([]const u8) = .empty;
            var values: std.ArrayList(T) = .empty;
            if (.object_begin != try source.next()) return error.UnexpectedToken;
            while (true) {
                switch (try source.nextAlloc(arena, .alloc_always)) {
                    .allocated_string => |key| {
                        const value = try json.innerParse(T, arena, source, options);
                        const at = std.sort.lowerBound([]const u8, names.items, key, order);
                        if (at < names.items.len and std.mem.eql(u8, names.items[at], key)) {
                            values.items[at] = value;
                        } else {
                            try names.insert(arena, at, key);
                            try values.insert(arena, at, value);
                        }
                    },
                    .object_end => break,
                    else => return error.UnexpectedToken,
                }
            }
            return .{ .names = names.items, .values = values.items };
        }

        fn order(key: []const u8, item: []const u8) std.math.Order {
            return std.mem.order(u8, key, item);
        }
    };
}

/// Pin values applied together, by pin name; unnamed pins keep their value.
pub const Vector = Sorted(Level);

/// A pin value: a logic level of the pin's related supplies, or volts. In
/// JSON `"0"`, `"1"` or a finite number; anything else is refused.
pub const Level = union(enum) {
    low,
    high,
    volts: f64,

    pub fn jsonParse(arena: Allocator, source: anytype, options: json.ParseOptions) !Level {
        switch (try source.peekNextTokenType()) {
            .string => {
                const text = try json.innerParse([]const u8, arena, source, options);
                if (std.mem.eql(u8, text, "0")) return .low;
                if (std.mem.eql(u8, text, "1")) return .high;
                return error.UnexpectedToken;
            },
            .number => {
                const volts = try json.innerParse(f64, arena, source, options);
                if (!std.math.isFinite(volts)) return error.UnexpectedToken;
                return .{ .volts = volts };
            },
            else => return error.UnexpectedToken,
        }
    }
};

/// What a pin is, which decides how it is driven and written.
pub const Role = enum(u8) {
    power,
    ground,
    nwell,
    pwell,
    input,
    clock,
    output,
    analog,

    /// A `pg_pin`: power, ground or a well.
    pub fn isSupply(r: Role) bool {
        return switch (r) {
            .power, .ground, .nwell, .pwell => true,
            .input, .clock, .output, .analog => false,
        };
    }

    /// Driven as a logic level: an input or a clock.
    pub fn isDigitalInput(r: Role) bool {
        return r == .input or r == .clock;
    }
};

/// An analog pin's direction; Liberty and Verilog spell it alike.
pub const Direction = enum(u8) { input, output, inout };

/// Liberty `timing_type`.
pub const ArcKind = enum(u8) {
    combinational,
    rising_edge,
    falling_edge,
    setup_rising,
    hold_rising,
    setup_falling,
    hold_falling,

    /// Setup or hold: a constraint table on the data pin.
    pub fn isConstraint(k: ArcKind) bool {
        return switch (k) {
            .setup_rising, .hold_rising, .setup_falling, .hold_falling => true,
            .combinational, .rising_edge, .falling_edge => false,
        };
    }

    /// Whether the data edge is placed after the clock.
    pub fn isHold(k: ArcKind) bool {
        return k == .hold_rising or k == .hold_falling;
    }

    /// The related pin's edge a clocked arc is defined on.
    pub fn clockEdge(k: ArcKind) ?Edge {
        return switch (k) {
            .rising_edge, .setup_rising, .hold_rising => .rise,
            .falling_edge, .setup_falling, .hold_falling => .fall,
            .combinational => null,
        };
    }
};

/// A signal transition; `@tagName` is Liberty's spelling (`cell_rise`).
pub const Edge = enum(u8) {
    rise,
    fall,

    pub fn flip(e: Edge) Edge {
        return switch (e) {
            .rise => .fall,
            .fall => .rise,
        };
    }
};

/// One port. Every signal pin names a related `power` and `ground`.
pub const PinSpec = struct {
    name: []const u8,
    role: Role,
    power: ?[]const u8 = null,
    ground: ?[]const u8 = null,
    /// An analog pin's direction; default `inout`.
    direction: ?Direction = null,
    /// An analog pin's DC voltage, V; required on one, forbidden elsewhere.
    bias: ?f64 = null,
    /// An output's Liberty `function`, copied through unread.
    function: ?[]const u8 = null,
};

/// One timing arc, measured once per case.
pub const ArcSpec = struct {
    from: []const u8,
    to: []const u8,
    kind: ArcKind,
    cases: []const CaseSpec,
};

/// One measurement of an arc.
pub const CaseSpec = struct {
    vectors: []const Vector,
    edge: ?Edge = null,
    output: ?Edge = null,
    data: ?Edge = null,
    check: ?Check = null,
};

/// The pin and value a constraint's pass criterion reads.
pub const Check = struct { pin: []const u8, value: Level };

/// One PVT corner, one `.lib` file.
pub const CornerSpec = struct {
    name: []const u8,
    process: f64 = 1.0,
    temperature: f64,
    /// Volts on every supply pin, by pin name.
    supplies: Sorted(f64),
    models: []const []const u8,
    mc_models: []const []const u8 = &.{},
};

/// How each quantity is measured; defaults are `sky130_fd_sc_hd`'s.
pub const Characterization = struct {
    slews_ns: []const f64 = &.{ 0.01, 0.0230506, 0.0531329, 0.122474, 0.282311, 0.650743, 1.5 },
    loads_pf: []const f64 = &.{ 0.0005, 0.00133517, 0.00356533, 0.00952062, 0.0254232, 0.0678883, 0.181284 },
    constraint_slews_ns: []const f64 = &.{ 0.01, 0.5, 1.5 },
    input_threshold_pct: f64 = 50.0,
    output_threshold_pct: f64 = 50.0,
    slew_lower_pct: f64 = 20.0,
    slew_upper_pct: f64 = 80.0,
    pushout_pct: f64 = 10.0,
    vector_ns: f64 = 2.0,
    settle_ns: f64 = 10.0,
    constraint_window_ns: f64 = 4.0,
    mc_samples: u32 = 64,
    analog_frequency_hz: f64 = 1e6,
};

/// How to drive the simulator and spell its device cards.
pub const Simulator = struct {
    /// Run as ngspice in batch mode (`-b`), looked up on `PATH`.
    binary: []const u8 = "ngspice",
    /// `.option scale`: lengths are written divided by it.
    scale: f64 = 1e-6,
    prefix: []const u8 = "X",
    options: []const []const u8 = &.{},
    /// Concurrent simulator processes; null: available parallelism.
    workers: ?u32 = null,
};

/// The `accuracy` key: its text as written, resolved by `parse` into
/// `levels` (`"all"` is every level).
pub const Levels = struct {
    text: []const u8 = "spice",
    levels: []const Accuracy = &.{.spice},

    pub fn jsonParse(arena: Allocator, source: anytype, options: json.ParseOptions) !Levels {
        return .{ .text = try json.innerParse([]const u8, arena, source, options), .levels = &.{} };
    }
};

/// One macro's interface, arcs and corners, as `parse` validated it.
pub const MacroSpec = struct {
    cell: []const u8,
    /// Port order is this order.
    pins: []const PinSpec,
    /// The pin the deck's global (substrate) nets are tied to.
    substrate: ?[]const u8 = null,
    arcs: []const ArcSpec = &.{},
    corners: []const CornerSpec,
    leakage_states: []const []const Vector = &.{},
    characterization: Characterization = .{},
    simulator: Simulator = .{},
    accuracy: Levels = .{},

    pub fn pinIndex(s: *const MacroSpec, name: []const u8) ?usize {
        for (s.pins, 0..) |p, i| if (std.mem.eql(u8, p.name, name)) return i;
        return null;
    }
};

/// `Malformed`: not JSON of the spec's shape (syntax, a missing or unknown
/// key, a bad role, kind, edge or pin value, an unknown accuracy).
/// `Invalid`: well-formed but its parts disagree. `diag.message` says which.
pub const Error = error{ Malformed, Invalid } || Allocator.Error;

/// Parses and validates a spec; every relation spec.rs `parse` documents is
/// checked, and the first offence is the message.
pub fn parse(arena: Allocator, text: []const u8, diag: *Diagnostic) Error!MacroSpec {
    var scanner: json.Scanner = .initCompleteInput(arena, text);
    var where: json.Diagnostics = .{};
    scanner.enableDiagnostics(&where);
    var spec = json.parseFromTokenSourceLeaky(MacroSpec, arena, &scanner, .{}) catch |err| {
        if (err == error.OutOfMemory) return error.OutOfMemory;
        diag.message = try arena.print("{s} at line {d}, column {d}", .{ @errorName(err), where.getLine(), where.getColumn() });
        return error.Malformed;
    };
    if (std.mem.eql(u8, spec.accuracy.text, "all")) {
        spec.accuracy.levels = &Accuracy.all;
    } else if (Accuracy.parse(spec.accuracy.text)) |level| {
        spec.accuracy.levels = try arena.dupe(Accuracy, &.{level});
    } else {
        diag.message = try arena.print("unknown accuracy \"{s}\"; expected interface, analytical, field, spice, statistical (or 0 to 4), or all", .{spec.accuracy.text});
        return error.Malformed;
    }
    try validate(arena, &spec, diag);
    return spec;
}

// ---- private ----

fn validate(arena: Allocator, s: *const MacroSpec, diag: *Diagnostic) Error!void {
    if (s.pins.len == 0) return bad(arena, diag, "a macro has at least one pin", .{});
    for (s.pins, 0..) |pin, i| {
        for (s.pins[0..i]) |other| if (std.mem.eql(u8, other.name, pin.name)) return bad(arena, diag, "pin {s} is listed twice", .{pin.name});
        if (pin.role.isSupply()) {
            if (pin.power != null or pin.ground != null or pin.bias != null) return bad(arena, diag, "supply pin {s} takes no power, ground or bias", .{pin.name});
            continue;
        }
        const related = [_]struct { []const u8, ?[]const u8, [2]Role }{
            .{ "power", pin.power, .{ .power, .nwell } },
            .{ "ground", pin.ground, .{ .ground, .pwell } },
        };
        for (related) |r| {
            const name = r[1] orelse return bad(arena, diag, "signal pin {s} needs a related {s} pin", .{ pin.name, r[0] });
            const ok = if (s.pinIndex(name)) |j| s.pins[j].role == r[2][0] or s.pins[j].role == r[2][1] else false;
            if (!ok) return bad(arena, diag, "pin {s}'s {s} {s} is not a {s} pin of this macro", .{ pin.name, r[0], name, r[0] });
        }
        if (pin.role == .analog) {
            if (pin.bias == null) return bad(arena, diag, "analog pin {s} needs a bias: the voltage it sits at while everything else is measured", .{pin.name});
        } else if (pin.direction != null or pin.bias != null) {
            return bad(arena, diag, "pin {s}: only an analog pin takes a direction or a bias", .{pin.name});
        }
    }
    if (s.substrate) |name| if (!isSupplyPin(s, name)) return bad(arena, diag, "substrate {s} is not a supply pin", .{name});
    if (s.corners.len == 0) return bad(arena, diag, "at least one corner is needed, one .lib per corner", .{});
    for (s.corners) |corner| {
        for (s.pins) |pin| if (pin.role.isSupply() and corner.supplies.get(pin.name) == null)
            return bad(arena, diag, "corner {s} gives supply {s} no voltage", .{ corner.name, pin.name });
        for (corner.supplies.names) |name| if (!isSupplyPin(s, name))
            return bad(arena, diag, "corner {s} sets a voltage on {s}, which is not a supply pin", .{ corner.name, name });
    }
    for (s.arcs) |arc| try validateArc(arena, s, arc, diag);
    for (s.leakage_states) |sequence| {
        if (sequence.len == 0) return bad(arena, diag, "a leakage state is at least one vector", .{});
        for (sequence) |vector| try validateVector(arena, s, vector, "a leakage state", diag);
    }
    const c = &s.characterization;
    for ([_]struct { []const u8, []const f64 }{ .{ "slews_ns", c.slews_ns }, .{ "loads_pf", c.loads_pf }, .{ "constraint_slews_ns", c.constraint_slews_ns } }) |row| {
        var ok = row[1].len > 0;
        for (row[1], 0..) |v, i| ok = ok and v > 0.0 and (i == 0 or row[1][i - 1] < v);
        if (!ok) return bad(arena, diag, "{s} must be positive and strictly ascending", .{row[0]});
    }
    if (!(pct(c.input_threshold_pct) and pct(c.output_threshold_pct) and pct(c.slew_lower_pct) and pct(c.slew_upper_pct) and c.slew_lower_pct < c.slew_upper_pct))
        return bad(arena, diag, "thresholds are percentages in (0, 100), lower below upper", .{});
    if (!(c.pushout_pct > 0.0 and c.vector_ns > 0.0 and c.settle_ns > 0.0 and c.constraint_window_ns > 0.0 and c.analog_frequency_hz > 0.0 and c.mc_samples >= 2))
        return bad(arena, diag, "pushout, vector, settle, window and frequency are positive; mc_samples >= 2", .{});
    if (!(s.simulator.scale > 0.0) or s.simulator.workers == 0)
        return bad(arena, diag, "simulator scale is positive and workers, if given, nonzero", .{});
}

fn validateArc(arena: Allocator, s: *const MacroSpec, arc: ArcSpec, diag: *Diagnostic) Error!void {
    const name = try arena.print("arc {s} -> {s} ({s})", .{ arc.from, arc.to, @tagName(arc.kind) });
    const from = s.pinIndex(arc.from);
    const to = s.pinIndex(arc.to);
    if (from == null or to == null) return bad(arena, diag, "{s}: both ends must be pins of this macro", .{name});
    if (!s.pins[from.?].role.isDigitalInput()) return bad(arena, diag, "{s}: {s} is not an input or clock pin", .{ name, arc.from });
    if (arc.kind.isConstraint()) {
        if (!s.pins[to.?].role.isDigitalInput()) return bad(arena, diag, "{s}: {s} is not an input, so nothing constrains it", .{ name, arc.to });
    } else if (s.pins[to.?].role != .output) {
        return bad(arena, diag, "{s}: {s} is not an output pin", .{ name, arc.to });
    }
    if (arc.cases.len == 0) return bad(arena, diag, "{s}: an arc needs at least one case", .{name});
    for (arc.cases) |case| {
        if (case.vectors.len == 0) return bad(arena, diag, "{s}: a case starts from at least one vector", .{name});
        for (case.vectors) |vector| try validateVector(arena, s, vector, name, diag);
        var missing: std.ArrayList(u8) = .empty;
        for (s.pins) |pin| if (pin.role.isDigitalInput() and case.vectors[0].get(pin.name) == null) {
            if (missing.items.len > 0) try missing.appendSlice(arena, ", ");
            try missing.appendSlice(arena, pin.name);
        };
        if (missing.items.len > 0) return bad(arena, diag, "{s}: the first vector leaves {s} undriven", .{ name, missing.items });
        if (arc.kind == .combinational and case.edge == null) return bad(arena, diag, "{s}: a combinational case names its input edge", .{name});
        if (arc.kind != .combinational and case.edge != null) return bad(arena, diag, "{s}: a clocked case takes its edge from the arc kind", .{name});
        if (arc.kind.isConstraint()) {
            const check = case.check orelse return bad(arena, diag, "{s}: a constraint case needs a check", .{name});
            if (case.data == null or case.output != null) return bad(arena, diag, "{s}: a constraint case gives data, never output", .{name});
            const signal = if (s.pinIndex(check.pin)) |j| !s.pins[j].role.isSupply() else false;
            if (!signal) return bad(arena, diag, "{s}: check pin {s} is not a signal pin", .{ name, check.pin });
        } else if (case.output == null or case.data != null or case.check != null) {
            return bad(arena, diag, "{s}: a delay case gives output, never data or check", .{name});
        }
    }
}

fn validateVector(arena: Allocator, s: *const MacroSpec, vector: Vector, what: []const u8, diag: *Diagnostic) Error!void {
    for (vector.names, vector.values) |name, level| {
        const ok = if (s.pinIndex(name)) |j| s.pins[j].role.isDigitalInput() or (s.pins[j].role == .analog and level == .volts) else false;
        if (!ok) return bad(arena, diag, "{s}: {s} is not an input (or an analog pin given volts)", .{ what, name });
    }
}

fn isSupplyPin(s: *const MacroSpec, name: []const u8) bool {
    return if (s.pinIndex(name)) |j| s.pins[j].role.isSupply() else false;
}

fn pct(v: f64) bool {
    return v > 0.0 and v < 100.0;
}

fn bad(arena: Allocator, diag: *Diagnostic, comptime fmt: []const u8, args: anytype) Error {
    diag.message = try arena.print(fmt, args);
    return error.Invalid;
}

const inverter =
    \\{
    \\    "cell": "inv",
    \\    "pins": [
    \\        {"name": "A", "role": "input", "power": "VPWR", "ground": "VGND"},
    \\        {"name": "Y", "role": "output", "power": "VPWR", "ground": "VGND", "function": "!A"},
    \\        {"name": "VPWR", "role": "power"},
    \\        {"name": "VGND", "role": "ground"}
    \\    ],
    \\    "arcs": [{"from": "A", "to": "Y", "kind": "combinational", "cases": [
    \\        {"vectors": [{"A": "0"}], "edge": "rise", "output": "fall"},
    \\        {"vectors": [{"A": "1"}], "edge": "fall", "output": "rise"}
    \\    ]}],
    \\    "corners": [{"name": "tt_025C_1v80", "temperature": 25,
    \\                 "supplies": {"VPWR": 1.8, "VGND": 0}, "models": []}]
    \\}
;

test "an inverter spec parses" {
    // Oracle: construct-from-answer. `inverter` drives `A` low in its first
    // case, and with no `characterization` block the slews are the
    // documented default, `sky130_fd_sc_hd`'s seven-point table.
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    var diag: Diagnostic = .{};
    const spec = try parse(arena.allocator(), inverter, &diag);
    try std.testing.expectEqual(Level.low, spec.arcs[0].cases[0].vectors[0].get("A").?);
    try std.testing.expectEqual(7, spec.characterization.slews_ns.len);
}

test "the accuracy field reads a level or all" {
    // Oracle: `docs/liberty.md`: `accuracy` defaults to `spice`, `"all"` is
    // the five levels, `"2"` is `field` (levels 0 to 4 from `interface`),
    // and anything else is refused with the levels named.
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var diag: Diagnostic = .{};
    const with = struct {
        fn f(al: Allocator, value: []const u8, d: *Diagnostic) Error!MacroSpec {
            const text = try std.mem.replaceOwned(u8, al, inverter, "\"cell\"", try al.print("\"accuracy\": {s}, \"cell\"", .{value}));
            return parse(al, text, d);
        }
    }.f;
    try std.testing.expectEqualSlices(Accuracy, &.{.spice}, (try parse(a, inverter, &diag)).accuracy.levels);
    try std.testing.expectEqualSlices(Accuracy, &Accuracy.all, (try with(a, "\"all\"", &diag)).accuracy.levels);
    try std.testing.expectEqualSlices(Accuracy, &.{.field}, (try with(a, "\"2\"", &diag)).accuracy.levels);
    try std.testing.expectEqualSlices(Accuracy, &.{.interface}, (try with(a, "\"interface\"", &diag)).accuracy.levels);
    try std.testing.expectError(error.Malformed, with(a, "\"9\"", &diag));
    try std.testing.expect(std.mem.indexOf(u8, diag.message, "unknown accuracy \"9\"; expected interface, analytical, field, spice, statistical (or 0 to 4), or all") != null);
}

test "every broken relation is refused" {
    // Oracle: the relations `parse` documents. Each edit breaks one (a
    // supply pin with no corner voltage, a combinational case with no
    // `edge`, a first vector leaving an input undriven, a ground pin turned
    // input, a level that is not one, an unknown arc kind, an unknown key),
    // so each is refused.
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const edits = [_][2][]const u8{
        .{ "\"VPWR\": 1.8, \"VGND\": 0", "\"VPWR\": 1.8" },
        .{ "\"edge\": \"rise\", \"output\"", "\"output\"" },
        .{ "{\"A\": \"0\"}], \"edge\"", "{}], \"edge\"" },
        .{ "\"role\": \"ground\"}", "\"role\": \"input\"}" },
        .{ "\"A\": \"1\"", "\"A\": \"2\"" },
        .{ "\"kind\": \"combinational\"", "\"kind\": \"combinatorial\"" },
        .{ "\"temperature\"", "\"temperatur\"" },
    };
    for (edits) |e| {
        const at = std.mem.indexOf(u8, inverter, e[0]) orelse return error.TestEditNotFound;
        const broken = try std.mem.concat(a, u8, &.{ inverter[0..at], e[1], inverter[at + e[0].len ..] });
        var diag: Diagnostic = .{};
        if (parse(a, broken, &diag)) |_| return error.TestAccepted else |_| {}
    }
}
