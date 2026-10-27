//! Design intent, and what its absence has to look like: six ERC rules need
//! facts no PDK can supply, a run without an intent file reports them
//! skipped, and that verdict hangs on `DesignIntent.isEmpty` and accessors
//! that say "not declared". Ported from crates/ingest/tests/intent.rs.

const std = @import("std");
const testing = std.testing;
const ingest = @import("ingest");
const geom = @import("geom");
const intent = ingest.intent;
const DesignIntent = intent.DesignIntent;
const StrTable = geom.StrTable;
const gpa = testing.allocator;

/// One parse with its own arena, strings and diagnostic.
const Run = struct {
    arena: std.heap.ArenaAllocator = .init(gpa),
    strings: StrTable = .empty,
    diag: intent.Diagnostic = .{},

    fn deinit(r: *Run) void {
        r.arena.deinit();
        r.strings.deinit(gpa);
    }

    fn parse(r: *Run, source: []const u8) intent.Error!DesignIntent {
        return intent.parseIntent(r.arena.allocator(), gpa, source, &r.strings, &r.diag);
    }

    /// `source` is refused with `err`, the refusal reading `message`.
    fn expectRefused(r: *Run, source: []const u8, err: intent.Error, message: []const u8) !void {
        try testing.expectError(err, r.parse(source));
        try testing.expectEqualStrings(message, r.diag.text());
    }

    fn fmt(r: *Run, comptime f: []const u8, args: anytype) ![]u8 {
        return std.fmt.allocPrint(r.arena.allocator(), f, args);
    }
};

const states_head =
    \\{"domains":{"core":{"voltage_mv":1800},"sw":{"voltage_mv":1800}},
    \\ "supplies":[{"net":"VDD","domain":"core","role":"power"},
    \\             {"net":"VDD_SW","domain":"sw","role":"power"},
    \\             {"net":"VSS","domain":"core","role":"ground"}],
;

// ---- private ----

/// The `dynamic` entry of the example in docs/src/reference/design-intent.md,
/// on VDD, with `budget` beside it and `extra` spliced into it.
fn dynamicIntent(r: *Run, budget: []const u8, extra: []const u8) ![]u8 {
    return r.fmt(
        \\{{"temperature_c":105,"domains":{{"core":{{"voltage_mv":1800}}}},
        \\"supplies":[{{"net":"VDD","domain":"core","role":"power"}}],
        \\"limits":[{{"net":"VDD"{s},"dynamic":{{"max_drop_mv":180,
        \\"toggle_rate":0.2,"clock_period_ps":2000,"rise_time_ps":100{s}}}}}]}}
    , .{ budget, extra });
}

fn replace(r: *Run, text: []const u8, from: []const u8, to: []const u8) ![]u8 {
    return std.mem.replaceOwned(u8, r.arena.allocator(), text, from, to);
}

test "an absent intent declares nothing and every accessor says so" {
    // Oracle: construct-from-answer. "Nothing was declared" has exactly one
    // answer for every accessor, and it is the accessors an ERC rule reads.
    var strings: StrTable = .empty;
    defer strings.deinit(gpa);
    const vdd = try strings.intern(gpa, "VDD");
    const vss = try strings.intern(gpa, "VSS");
    const none: DesignIntent = .{};
    try testing.expect(none.isEmpty());
    try testing.expectEqual(null, none.supplyRole(vdd));
    try testing.expectEqual(null, none.supplyRole(vss));
    const limits = none.limits(vdd);
    try testing.expectEqual(null, limits.max_drop);
    try testing.expectEqual(null, limits.max_drop_fraction);
    try testing.expectEqual(null, limits.max_overvoltage);
    try testing.expectEqual(null, limits.budget_current_ua);
}

test "an intent file that cannot be opened is an error rather than an empty intent" {
    // Oracle: construct-from-answer. An unreadable file is a run that should
    // stop, never an empty intent.
    var r: Run = .{};
    defer r.deinit();
    try testing.expectError(error.Io, intent.readIntent(r.arena.allocator(), gpa, testing.io, std.Io.Dir.cwd(), "/nonexistent/gpurify/no-such-intent.json", &r.strings, &r.diag));
    try testing.expect(std.mem.startsWith(u8, r.diag.text(), "io: /nonexistent/gpurify/no-such-intent.json: "));
}

test "a bad limit names the limit it is" {
    // Oracle: construct-from-answer. Each limit stated as zero is refused
    // naming that limit's key.
    for ([_][]const u8{ "max_drop_mv", "max_drop_fraction", "max_overvoltage_mv", "budget_current_ua", "rms_current_ua", "peak_current_ua", "frequency_mhz" }) |key| {
        var r: Run = .{};
        defer r.deinit();
        const source = try r.fmt(
            \\{{"domains":{{"core":{{"voltage_mv":1800}}}},
            \\"supplies":[{{"net":"VDD","domain":"core","role":"power"}}],
            \\"limits":[{{"net":"VDD","{s}":0}}]}}
        , .{key});
        try r.expectRefused(source, error.BadLimit, try r.fmt("net VDD: {s} is not a positive finite number", .{key}));
    }
}

test "a supply listed twice in one domain is named as a repeat" {
    // Oracle: construct-from-answer. The message names the repeat, not two
    // domains.
    var r: Run = .{};
    defer r.deinit();
    try r.expectRefused(
        \\{"domains":{"core":{"voltage_mv":1800}},
        \\ "supplies":[{"net":"VDD","domain":"core","role":"power"},
        \\             {"net":"VDD","domain":"core","role":"power"}],
        \\ "limits":[]}
    , error.DomainConflict, "net VDD is listed more than once in supplies");
}

test "power states read back and a malformed one is refused" {
    // Oracle: construct-from-answer, on the schema in
    // docs/src/reference/design-intent.md (states): two states in file order
    // with their switched-off supplies and held inputs in mV; a file of states
    // alone is not empty; a repeated state, one turning off an undeclared net,
    // and an input held twice are each refused by name.
    var r: Run = .{};
    defer r.deinit();
    const got = try r.parse(states_head ++
        \\"states":[{"name":"sleep","off":["VDD_SW"]},
        \\{"name":"disable","inputs":[{"net":"EN","voltage_mv":0},{"net":"SEL","voltage_mv":1800}]}]}
    );
    try testing.expectEqual(2, got.states.len);
    try testing.expectEqualStrings("sleep", r.strings.resolve(got.states[0].name));
    try testing.expectEqualSlices(geom.StrId, &.{r.strings.get("VDD_SW").?}, got.states[0].off);
    try testing.expectEqual(0, got.states[0].input_net.len);
    try testing.expectEqualStrings("disable", r.strings.resolve(got.states[1].name));
    try testing.expectEqualStrings("EN", r.strings.resolve(got.states[1].input_net[0]));
    try testing.expectEqualStrings("SEL", r.strings.resolve(got.states[1].input_net[1]));
    try testing.expectEqual(0.0, got.states[1].input_mv[0].raw);
    try testing.expectEqual(1800.0, got.states[1].input_mv[1].raw);
    const only_states = try r.parse(
        \\{"states":[{"name":"idle"}]}
    );
    try testing.expect(!only_states.isEmpty());
    for ([_][2][]const u8{
        .{
            \\[{"name":"sleep"},{"name":"sleep"}]
            ,
            "power state sleep is declared twice",
        },
        .{
            \\[{"name":"sleep","off":["EN"]}]
            ,
            "power state sleep turns off EN, which no supply declares",
        },
        .{
            \\[{"name":"d","inputs":[{"net":"EN","voltage_mv":0},{"net":"EN","voltage_mv":1}]}]
            ,
            "power state d: input EN is held twice",
        },
    }) |case| {
        try r.expectRefused(try r.fmt("{s}\"states\":{s}}}", .{ states_head, case[0] }), error.Malformed, try r.fmt("malformed intent file: {s}", .{case[1]}));
    }
}

test "a dynamic entry and a temperature read back as written" {
    // Oracle: round trip against the schema docs/src/reference/design-intent.md
    // documents: 105 °C reads back as 378.15 K and every `dynamic` number lands
    // in its field, an absent `decap_pf` as zero.
    var r: Run = .{};
    defer r.deinit();
    const got = try r.parse(try dynamicIntent(&r, ",\"budget_current_ua\":2000", ""));
    try testing.expectEqual(105.0 + 273.15, got.temperature.?.raw);
    const dynamic = got.limits(try r.strings.intern(gpa, "VDD")).dynamic.?;
    try testing.expectEqual(180.0, dynamic.max_drop.raw);
    try testing.expectEqual(0.2, dynamic.toggle_rate);
    try testing.expectEqual(2000.0, dynamic.clock_period_ps);
    try testing.expectEqual(100.0, dynamic.rise_time_ps);
    try testing.expectEqual(0.0, dynamic.decap_pf);
    try testing.expectEqual(null, (DesignIntent{}).temperature);
}

test "a dynamic entry that cannot be simulated is refused" {
    // Oracle: construct-from-answer, against `Error`'s documented cases: no
    // budget beside it, a toggle rate above 1, a rise longer than the
    // period, a negative decap, a zero toggle rate, and a temperature below
    // absolute zero.
    var r: Run = .{};
    defer r.deinit();
    const budget = ",\"budget_current_ua\":2000";
    const plain = try dynamicIntent(&r, budget, "");
    const cases = [_]struct { []const u8, intent.Error, []const u8 }{
        .{ try dynamicIntent(&r, "", ""), error.Malformed, "malformed intent file: net VDD: dynamic needs budget_current_ua, the current it switches" },
        .{ try replace(&r, plain, "0.2", "1.5"), error.Malformed, "malformed intent file: net VDD: dynamic toggle_rate is a fraction of cycles, at most 1" },
        .{ try replace(&r, plain, ":100", ":3000"), error.Malformed, "malformed intent file: net VDD: dynamic rise_time_ps is longer than clock_period_ps" },
        .{ try dynamicIntent(&r, budget, ",\"decap_pf\":-1"), error.Malformed, "malformed intent file: net VDD: dynamic decap_pf is negative or not finite" },
        .{ try replace(&r, plain, "0.2", "0"), error.BadLimit, "net VDD: dynamic.toggle_rate is not a positive finite number" },
        .{ try replace(&r, plain, "105", "-300"), error.Malformed, "malformed intent file: temperature_c is -300, not a temperature above absolute zero" },
    };
    for (cases) |c| try r.expectRefused(c[0], c[1], c[2]);
}

test "net types read back and a malformed one is refused" {
    // Oracle: spec example (US20100306720A1 [0198]-[0246]): a type by name,
    // one by device with a `!` model list and a pin, and a type set read
    // back as written; both names and models, an unknown pin, a set naming
    // an undeclared type, and a set reusing a type's name are each refused
    // by name. Breaks if the `!` is kept as a model or a malformed type reads.
    var r: Run = .{};
    defer r.deinit();
    const got = try r.parse(
        \\{"net_types":[{"type":"power","nets":["VDD?","lvsPower"]},
        \\              {"type":"gated","models":["!","nfet"],"pins":["g"]}],
        \\ "type_sets":[{"set":"any","types":["power","gated"]}]}
    );
    try testing.expect(!got.isEmpty());
    const types = got.net_types;
    try testing.expectEqualStrings("power", r.strings.resolve(types[0].name));
    try testing.expectEqual(2, types[0].by.names.len);
    try testing.expectEqualStrings("VDD?", types[0].by.names[0]);
    try testing.expectEqualStrings("lvsPower", types[0].by.names[1]);
    const devices = types[1].by.devices;
    try testing.expect(devices.negate);
    try testing.expectEqualSlices(geom.StrId, &.{r.strings.get("nfet").?}, devices.models);
    try testing.expectEqual(1, devices.pins.len);
    try testing.expectEqualStrings("g", devices.pins[0]);
    const set = got.type_sets[0];
    try testing.expectEqualStrings("any", r.strings.resolve(set.name));
    try testing.expectEqualSlices(geom.StrId, &.{ types[0].name, types[1].name }, set.types);
    for ([_][2][]const u8{
        .{
            \\{"net_types":[{"type":"t","nets":["A"],"models":["m"]}]}
            ,
            "net type t: states either nets, or models with optional pins",
        },
        .{
            \\{"net_types":[{"type":"t","models":["m"],"pins":["x"]}]}
            ,
            "net type t: pin x is none of g, s, d, b, c, e, pos, neg",
        },
        .{
            \\{"net_types":[{"type":"t","nets":["A"]}],"type_sets":[{"set":"s","types":["u"]}]}
            ,
            "type set s names u, no type or earlier set",
        },
        .{
            \\{"net_types":[{"type":"t","nets":["A"]}],"type_sets":[{"set":"t","types":["t"]}]}
            ,
            "type set t repeats a type or set name",
        },
    }) |case| {
        try r.expectRefused(case[0], error.Malformed, try r.fmt("malformed intent file: {s}", .{case[1]}));
    }
}

test "an unknown key and a repeated key are refused" {
    // Oracle: construct-from-answer, on the Rust tool's
    // `deny_unknown_fields`: a typo'd key (`max_dorp_mv`) would silently
    // ungate a rule. A repeated domain key is refused too, where serde's map
    // kept the last (a deliberate tightening).
    var r: Run = .{};
    defer r.deinit();
    try testing.expectError(error.Malformed, r.parse(
        \\{"limits":[{"net":"VDD","max_dorp_mv":5}]}
    ));
    try testing.expect(std.mem.startsWith(u8, r.diag.text(), "malformed intent file: UnknownField"));
    try testing.expectError(error.Malformed, r.parse(
        \\{"domains":{"core":{"voltage_mv":1},"core":{"voltage_mv":2}}}
    ));
}
