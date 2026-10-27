//! Design intent: the per-chip inputs a PDK cannot supply. In: the intent
//! JSON. Out: a `DesignIntent` whose nets are `StrId`s in the run's table.
//! Optional: rules needing an absent intent are reported as skipped, never as
//! clean. Every wire object refuses unknown keys: a typo'd key would silently
//! ungate a rule. Net types and type sets cite US20100306720A1
//! [0198]-[0246]; power states IEEE 1801 (scope) and Calibre PERC's vectored
//! inputs. Ported from crates/ingest/src/intent.rs.
//!
//! Contents:
//! - `pub const Error`, `pub const Diagnostic`, `Diagnostic.text(d: *const Diagnostic) []const u8`
//! - `pub const DomainId`, `pub const SupplyRole`, `pub const Millivolts`, `pub const Kelvin`
//! - `pub const DesignIntent`,
//!   `DesignIntent.supplyRole(i: *const DesignIntent, net: StrId) ?Supply`,
//!   `DesignIntent.limits(i: *const DesignIntent, net: StrId) NetLimits`,
//!   `DesignIntent.domainVoltage(i: *const DesignIntent, domain: DomainId) Millivolts`,
//!   `DesignIntent.isEmpty(i: *const DesignIntent) bool`
//! - `pub const Supply`, `pub const NetType`, `pub const NetTypeBy`, `pub const TypeSet`,
//!   `pub const PowerState`, `pub const NetLimits`, `pub const Switching`
//! - `pub const max_net_types`, `pub const max_domains`
//! - `pub fn parseIntent(arena: Allocator, gpa: Allocator, source: []const u8, strings: *StrTable, diag: *Diagnostic) Error!DesignIntent`
//! - `pub fn readIntent(arena: Allocator, gpa: Allocator, io: std.Io, dir: std.Io.Dir, sub_path: []const u8, strings: *StrTable, diag: *Diagnostic) Error!DesignIntent`

const std = @import("std");
const Allocator = std.mem.Allocator;
const geom = @import("geom");
const StrTable = geom.StrTable;
const StrId = geom.StrId;

/// Why an intent file was rejected; `Diagnostic.text` says it in words.
pub const Error = error{
    /// Not JSON of the schema (an unknown key, a wrong type, a repeated key),
    /// more than 64 domains, a domain voltage that is not finite, a supply
    /// naming an undeclared domain, two `limits` entries for one net, a
    /// temperature that is not finite or not above absolute zero, a
    /// `dynamic` entry that cannot be simulated (no `budget_current_ua`
    /// beside it, a toggle rate above 1, a rise longer than the period, a
    /// negative decap), a power state repeating a name, turning off a net no
    /// supply declares or pinning an input twice or to a voltage that is not
    /// finite, a net type stating both or neither of `nets` and `models`, an
    /// unknown pin or no model, a type set naming no declared type or earlier
    /// set or reusing a name, or more than `max_net_types` types and sets.
    Malformed,
    /// A net listed more than once in `supplies`, in one domain or two.
    DomainConflict,
    /// A declared domain that no supply net belongs to.
    DomainWithoutSupply,
    /// A stated limit of a net is zero, negative, NaN or infinite.
    BadLimit,
    /// The intent file could not be read.
    Io,
    OutOfMemory,
};

/// The refusal in words, as the Rust tool's `IntentError` displayed it.
pub const Diagnostic = struct {
    buf: [512]u8 = undefined,
    len: usize = 0,

    pub fn text(d: *const Diagnostic) []const u8 {
        return d.buf[0..d.len];
    }

    fn set(d: *Diagnostic, comptime fmt: []const u8, args: anytype) void {
        d.len = if (std.fmt.bufPrint(&d.buf, fmt, args)) |t| t.len else |_| d.buf.len;
    }
};

/// A named voltage domain: its position among the file's domain names in
/// ascending byte order, from 0, below `max_domains`.
pub const DomainId = enum(u32) { _ };

/// Which side of a supply pair a net is.
pub const SupplyRole = enum(u8) {
    /// Sits at its domain's voltage.
    power,
    /// Sits at 0 V; its drop is how far it rises.
    ground,
};

pub const Millivolts = geom.Qty(.voltage, .milli);
pub const Kelvin = geom.Qty(.temperature, .base);

/// A declared supply's domain and role.
pub const Supply = struct { domain: DomainId, role: SupplyRole };

/// The most domains: a domain is one bit of a `u64` in ERC's voltage
/// propagation. ponytail: widen the mask past 64 when a design needs it.
pub const max_domains = 64;

/// The most net types and type sets one design may declare together: the
/// patent's "at most 64 unique net types" ([0200]), one bit each.
pub const max_net_types = 64;

/// Everything the design's owner must state that the process does not. Its
/// slices live in the `arena` `parseIntent` was given.
pub const DesignIntent = struct {
    /// Nominal supply voltage, indexed by `DomainId`.
    domain_voltage: []const Millivolts = &.{},
    /// Declared supply nets, strictly ascending by id, and each one's supply.
    supply_net: []const StrId = &.{},
    supply: []const Supply = &.{},
    /// Nets with limits, strictly ascending, and their limits. Sparse.
    limit_net: []const StrId = &.{},
    limit: []const NetLimits = &.{},
    /// The junction temperature the chip runs at (`temperature_c`).
    temperature: ?Kelvin = null,
    /// Declared power states, net types and type sets, in file order.
    states: []const PowerState = &.{},
    net_types: []const NetType = &.{},
    type_sets: []const TypeSet = &.{},

    /// Whether a net is a declared supply, and in which domain and role.
    pub fn supplyRole(i: *const DesignIntent, net: StrId) ?Supply {
        const row = find(i.supply_net, net) orelse return null;
        return i.supply[row];
    }

    /// The limits declared for a net; all null (unchecked) when undeclared.
    pub fn limits(i: *const DesignIntent, net: StrId) NetLimits {
        const row = find(i.limit_net, net) orelse return .{};
        return i.limit[row];
    }

    /// A domain's nominal voltage, as the file states it (any finite value).
    pub fn domainVoltage(i: *const DesignIntent, domain: DomainId) Millivolts {
        return i.domain_voltage[@backingInt(domain)];
    }

    /// True when nothing was declared, so every intent-dependent rule reports
    /// skipped, not clean.
    pub fn isEmpty(i: *const DesignIntent) bool {
        return i.domain_voltage.len == 0 and i.supply_net.len == 0 and i.limit_net.len == 0 and
            i.states.len == 0 and i.net_types.len == 0;
    }
};

/// A net type a design assigns, by net name (the patent's `perc::commanda`,
/// [0198]-[0214]) or by the devices on a net (`perc::commanda+`,
/// [0215]-[0239]). A net can have several; a declared supply carries one
/// only through `lvsPower` or `lvsGround` ([0207]).
pub const NetType = struct { name: StrId, by: NetTypeBy };

/// How a `NetType` picks its nets.
pub const NetTypeBy = union(enum) {
    /// Net names, each matched whole against a net's layout label, `?`
    /// matching zero or more characters ([0201]). `lvsPower` and `lvsGround`
    /// are the declared power and ground supplies, `lvsOutline` every
    /// labelled net ([0209]-[0211]).
    names: []const []const u8,
    /// The nets on the `pins` of every device of the `models` (with
    /// `negate`, of every model but those), every pin when `pins` is empty
    /// ([0216], [0230]). Pins: `g s d b` (MOS), `c b e` (bipolar), `pos neg`.
    devices: struct { models: []const StrId, negate: bool, pins: []const []const u8 },
};

/// A type set: the logical OR of its types, which may name earlier sets
/// (US20100306720A1 [0240]-[0246]).
pub const TypeSet = struct { name: StrId, types: []const StrId };

/// One power state: the supplies switched off and the inputs held at a
/// voltage while it lasts. Every supply not in `off` stays on.
pub const PowerState = struct {
    name: StrId,
    /// Declared supply nets switched off.
    off: []const StrId,
    /// Nets held at a voltage, each named once, and the voltages.
    input_net: []const StrId,
    input_mv: []const Millivolts,
};

/// The limits a design states for one net. Null means *not checked*, never
/// *unlimited*. Keys: `max_drop_mv`, `max_drop_fraction`,
/// `max_overvoltage_mv`, `budget_current_ua`, `dynamic` (only beside a
/// budget), `rms_current_ua`, `peak_current_ua`, `frequency_mhz`.
pub const NetLimits = struct {
    max_drop: ?Millivolts = null,
    max_drop_fraction: ?f64 = null,
    max_overvoltage: ?Millivolts = null,
    budget_current_ua: ?f64 = null,
    dynamic: ?Switching = null,
    rms_current_ua: ?f64 = null,
    peak_current_ua: ?f64 = null,
    frequency_mhz: ?f64 = null,
};

/// One net's worst switching cycle, for vectorless dynamic IR drop.
pub const Switching = struct {
    /// The dynamic drop permitted at any node of the net (`max_drop_mv`).
    max_drop: Millivolts,
    /// The fraction of cycles in which a load switches, `0 < α <= 1`.
    toggle_rate: f64,
    clock_period_ps: f64,
    /// The current pulse's base, at most the period.
    rise_time_ps: f64,
    /// Decoupling capacitance, zero when left out.
    decap_pf: f64,
};

/// The wire shape. std.json refuses unknown and repeated keys by default.
const IntentFile = struct {
    domains: std.json.ArrayHashMap(DomainSpec) = .{},
    supplies: []const struct { net: []const u8, domain: []const u8, role: SupplyRole } = &.{},
    limits: []const LimitSpec = &.{},
    temperature_c: ?f64 = null,
    states: []const StateSpec = &.{},
    net_types: []const struct {
        type: []const u8,
        nets: ?[]const []const u8 = null,
        models: ?[]const []const u8 = null,
        pins: []const []const u8 = &.{},
    } = &.{},
    type_sets: []const struct { set: []const u8, types: []const []const u8 } = &.{},
};

const DomainSpec = struct { voltage_mv: f64 };

const StateSpec = struct {
    name: []const u8,
    off: []const []const u8 = &.{},
    inputs: []const struct { net: []const u8, voltage_mv: f64 } = &.{},
};

const LimitSpec = struct {
    net: []const u8,
    max_drop_mv: ?f64 = null,
    max_drop_fraction: ?f64 = null,
    max_overvoltage_mv: ?f64 = null,
    budget_current_ua: ?f64 = null,
    dynamic: ?DynamicSpec = null,
    rms_current_ua: ?f64 = null,
    peak_current_ua: ?f64 = null,
    frequency_mhz: ?f64 = null,
};

const DynamicSpec = struct {
    max_drop_mv: f64,
    toggle_rate: f64,
    clock_period_ps: f64,
    rise_time_ps: f64,
    decap_pf: f64 = 0,
};

/// Pin names a device-assigned net type may list.
const pin_names = [_][]const u8{ "g", "s", "d", "b", "c", "e", "pos", "neg" };

/// Parses and validates design intent, the schema of the Rust tool's
/// `parse_intent` (docs/src/reference/design-intent.md). Output and scratch go
/// to `arena`; names are interned into `strings` with `gpa`. Every section is
/// optional. On error nothing is returned, `diag` says why, and `strings` may
/// have gained names.
pub fn parseIntent(arena: Allocator, gpa: Allocator, source: []const u8, strings: *StrTable, diag: *Diagnostic) Error!DesignIntent {
    const file = blk: {
        var scanner: std.json.Scanner = .initCompleteInput(arena, source);
        var where: std.json.Diagnostics = .{};
        scanner.enableDiagnostics(&where);
        break :blk std.json.parseFromTokenSourceLeaky(IntentFile, arena, &scanner, .{}) catch |err| {
            if (err == error.OutOfMemory) return error.OutOfMemory;
            return malformed(diag, "{s} at line {d} column {d}", .{ @errorName(err), where.getLine(), where.getColumn() });
        };
    };
    var out: DesignIntent = .{};
    if (file.temperature_c) |degrees| {
        const kelvin = geom.celsius(degrees);
        if (!(kelvin.isFinite() and kelvin.raw > 0)) return malformed(diag, "temperature_c is {d}, not a temperature above absolute zero", .{degrees});
        out.temperature = kelvin;
    }
    // Domains: a domain's position in byte order is its `DomainId`.
    const domain_names = try arena.dupe([]const u8, file.domains.map.keys());
    const domain_specs = try arena.dupe(DomainSpec, file.domains.map.values());
    if (domain_names.len > max_domains) return malformed(diag, "{d} domains declared; at most 64 are supported", .{domain_names.len});
    sortDomains(domain_names, domain_specs);
    const voltage = try arena.alloc(Millivolts, domain_names.len);
    for (domain_names, domain_specs, voltage) |name, spec, *v| {
        if (!std.math.isFinite(spec.voltage_mv)) return malformed(diag, "domain {s}: voltage_mv is {d} rather than a number", .{ name, spec.voltage_mv });
        _ = try strings.intern(gpa, name); // Not stored; interning order is report order.
        v.* = .{ .raw = spec.voltage_mv };
    }
    out.domain_voltage = voltage;
    try readSupplies(arena, gpa, file, domain_names, strings, diag, &out);
    try readLimits(arena, gpa, file.limits, strings, diag, &out);
    out.states = try readStates(arena, gpa, file.states, strings, diag, &out);
    try readNetTypes(arena, gpa, file, strings, diag, &out);
    return out;
}

/// Reads `sub_path` under `dir` and parses it as `parseIntent` does.
/// `error.Io` names the path when it cannot be read.
pub fn readIntent(arena: Allocator, gpa: Allocator, io: std.Io, dir: std.Io.Dir, sub_path: []const u8, strings: *StrTable, diag: *Diagnostic) Error!DesignIntent {
    const source = dir.readFileAlloc(io, sub_path, arena, .unlimited) catch |err| {
        if (err == error.OutOfMemory) return error.OutOfMemory;
        diag.set("io: {s}: {s}", .{ sub_path, @errorName(err) });
        return error.Io;
    };
    return parseIntent(arena, gpa, source, strings, diag);
}

// ---- private ----

/// The row of `id` in the strictly ascending `ids`.
fn find(ids: []const StrId, id: StrId) ?usize {
    return std.sort.binarySearch(StrId, ids, id, orderId);
}

fn orderId(a: StrId, b: StrId) std.math.Order {
    return std.math.order(@backingInt(a), @backingInt(b));
}

fn malformed(diag: *Diagnostic, comptime fmt: []const u8, args: anytype) Error {
    diag.set("malformed intent file: " ++ fmt, args);
    return error.Malformed;
}

/// Sorts the domain names in byte order, carrying their specs along.
fn sortDomains(names: [][]const u8, specs: []DomainSpec) void {
    if (names.len < 2) return;
    for (1..names.len) |k| {
        var at = k;
        while (at > 0 and std.mem.order(u8, names[at - 1], names[at]) == .gt) : (at -= 1) {
            std.mem.swap([]const u8, &names[at - 1], &names[at]);
            std.mem.swap(DomainSpec, &specs[at - 1], &specs[at]);
        }
    }
}

/// `supplies`, sorted by net; every domain must have one, no net two.
fn readSupplies(arena: Allocator, gpa: Allocator, file: IntentFile, domain_names: []const []const u8, strings: *StrTable, diag: *Diagnostic, out: *DesignIntent) Error!void {
    const Row = struct { net: StrId, supply: Supply };
    const rows = try arena.alloc(Row, file.supplies.len);
    const has_supply = try arena.alloc(bool, domain_names.len);
    @memset(has_supply, false);
    for (file.supplies, rows) |spec, *row| {
        const index = for (domain_names, 0..) |name, k| {
            if (std.mem.eql(u8, name, spec.domain)) break k;
        } else return malformed(diag, "supply {s} names domain {s}, which the file does not declare", .{ spec.net, spec.domain });
        row.* = .{ .net = try strings.intern(gpa, spec.net), .supply = .{ .domain = @fromBackingInt(@as(u32, @intCast(index))), .role = spec.role } };
        has_supply[index] = true;
    }
    if (std.mem.indexOfScalar(bool, has_supply, false)) |index| {
        diag.set("domain {s} has no supply net", .{domain_names[index]});
        return error.DomainWithoutSupply;
    }
    std.mem.sort(Row, rows, {}, struct {
        fn less(_: void, a: Row, b: Row) bool {
            return @backingInt(a.net) < @backingInt(b.net);
        }
    }.less);
    const nets = try arena.alloc(StrId, rows.len);
    const supplies = try arena.alloc(Supply, rows.len);
    for (rows, nets, supplies, 0..) |row, *net, *supply, k| {
        // Any repeat is refused, not only a repeat under two domains.
        if (k > 0 and rows[k - 1].net == row.net) {
            diag.set("net {s} is listed more than once in supplies", .{strings.resolve(row.net)});
            return error.DomainConflict;
        }
        net.* = row.net;
        supply.* = row.supply;
    }
    out.supply_net = nets;
    out.supply = supplies;
}

/// `limits`, each value checked in field order, sorted by net.
fn readLimits(arena: Allocator, gpa: Allocator, specs: []const LimitSpec, strings: *StrTable, diag: *Diagnostic, out: *DesignIntent) Error!void {
    const nets = try arena.alloc(StrId, specs.len);
    const rows = try arena.alloc(NetLimits, specs.len);
    for (specs, nets, rows) |spec, *net, *row| {
        const n = spec.net;
        row.* = .{
            .max_drop = mv(try checked(diag, spec.max_drop_mv, n, "max_drop_mv")),
            .max_drop_fraction = try checked(diag, spec.max_drop_fraction, n, "max_drop_fraction"),
            .max_overvoltage = mv(try checked(diag, spec.max_overvoltage_mv, n, "max_overvoltage_mv")),
            .budget_current_ua = try checked(diag, spec.budget_current_ua, n, "budget_current_ua"),
            .dynamic = if (spec.dynamic) |d| try checkedSwitching(diag, d, n, spec.budget_current_ua) else null,
            .rms_current_ua = try checked(diag, spec.rms_current_ua, n, "rms_current_ua"),
            .peak_current_ua = try checked(diag, spec.peak_current_ua, n, "peak_current_ua"),
            .frequency_mhz = try checked(diag, spec.frequency_mhz, n, "frequency_mhz"),
        };
        net.* = try strings.intern(gpa, n);
    }
    // Sorted so the file may state its nets in any order.
    const order = try arena.alloc(u32, specs.len);
    for (order, 0..) |*o, k| o.* = @intCast(k);
    std.mem.sort(u32, order, nets, struct {
        fn less(ids: []const StrId, a: u32, b: u32) bool {
            return @backingInt(ids[a]) < @backingInt(ids[b]);
        }
    }.less);
    const sorted_nets = try arena.alloc(StrId, specs.len);
    const sorted = try arena.alloc(NetLimits, specs.len);
    for (order, sorted_nets, sorted, 0..) |o, *net, *row, k| {
        net.* = nets[o];
        row.* = rows[o];
        if (k > 0 and sorted_nets[k - 1] == net.*) return malformed(diag, "net {s} has two limits entries", .{strings.resolve(net.*)});
    }
    out.limit_net = sorted_nets;
    out.limit = sorted;
}

fn mv(value: ?f64) ?Millivolts {
    return if (value) |v| .{ .raw = v } else null;
}

/// A stated limit must be strictly positive and finite: a NaN compares false
/// against every measurement, so it would check nothing.
fn checked(diag: *Diagnostic, value: ?f64, net: []const u8, comptime key: []const u8) Error!?f64 {
    const v = value orelse return null;
    if (std.math.isFinite(v) and v > 0) return v;
    diag.set("net {s}: " ++ key ++ " is not a positive finite number", .{net});
    return error.BadLimit;
}

/// A `dynamic` entry: every number positive and finite (`decap_pf` zero or
/// more), a toggle rate of at most 1, a rise within the period, and a budget
/// beside it for the charge to come from.
fn checkedSwitching(diag: *Diagnostic, spec: DynamicSpec, net: []const u8, budget: ?f64) Error!Switching {
    const s: Switching = .{
        .max_drop = .{ .raw = (try checked(diag, spec.max_drop_mv, net, "dynamic.max_drop_mv")).? },
        .toggle_rate = (try checked(diag, spec.toggle_rate, net, "dynamic.toggle_rate")).?,
        .clock_period_ps = (try checked(diag, spec.clock_period_ps, net, "dynamic.clock_period_ps")).?,
        .rise_time_ps = (try checked(diag, spec.rise_time_ps, net, "dynamic.rise_time_ps")).?,
        .decap_pf = spec.decap_pf,
    };
    const why = if (budget == null)
        "needs budget_current_ua, the current it switches"
    else if (s.toggle_rate > 1)
        "toggle_rate is a fraction of cycles, at most 1"
    else if (s.rise_time_ps > s.clock_period_ps)
        "rise_time_ps is longer than clock_period_ps"
    else if (!(std.math.isFinite(s.decap_pf) and s.decap_pf >= 0))
        "decap_pf is negative or not finite"
    else
        return s;
    return malformed(diag, "net {s}: dynamic {s}", .{ net, why });
}

/// `states`, in file order: names unique, `off` only declared supplies,
/// inputs finite and each held once.
fn readStates(arena: Allocator, gpa: Allocator, specs: []const StateSpec, strings: *StrTable, diag: *Diagnostic, intent: *const DesignIntent) Error![]const PowerState {
    const states = try arena.alloc(PowerState, specs.len);
    for (specs, states, 0..) |spec, *state, k| {
        const name = try strings.intern(gpa, spec.name);
        for (states[0..k]) |seen| if (seen.name == name) return malformed(diag, "power state {s} is declared twice", .{spec.name});
        const off = try arena.alloc(StrId, spec.off.len);
        for (spec.off, off) |net, *id| {
            id.* = try strings.intern(gpa, net);
            if (intent.supplyRole(id.*) == null) return malformed(diag, "power state {s} turns off {s}, which no supply declares", .{ spec.name, net });
        }
        const input_net = try arena.alloc(StrId, spec.inputs.len);
        const input_mv = try arena.alloc(Millivolts, spec.inputs.len);
        for (spec.inputs, input_net, input_mv, 0..) |input, *id, *v, j| {
            if (!std.math.isFinite(input.voltage_mv)) return malformed(diag, "power state {s}: input {s} has voltage_mv {d}, not a number", .{ spec.name, input.net, input.voltage_mv });
            id.* = try strings.intern(gpa, input.net);
            if (std.mem.indexOfScalar(StrId, input_net[0..j], id.*) != null) return malformed(diag, "power state {s}: input {s} is held twice", .{ spec.name, input.net });
            v.* = .{ .raw = input.voltage_mv };
        }
        state.* = .{ .name = name, .off = off, .input_net = input_net, .input_mv = input_mv };
    }
    return states;
}

/// `net_types` then `type_sets`, in file order; together at most
/// `max_net_types` names.
fn readNetTypes(arena: Allocator, gpa: Allocator, file: IntentFile, strings: *StrTable, diag: *Diagnostic, out: *DesignIntent) Error!void {
    var names: std.ArrayList(StrId) = .empty;
    const types = try arena.alloc(NetType, file.net_types.len);
    for (file.net_types, types) |spec, *t| {
        const name = try strings.intern(gpa, spec.type);
        const by = try netTypeBy(arena, gpa, spec.type, spec.nets, spec.models, spec.pins, strings, diag) orelse
            return malformed(diag, "net type {s}: states either nets, or models with optional pins", .{spec.type});
        if (std.mem.indexOfScalar(StrId, names.items, name) == null) try names.append(arena, name);
        t.* = .{ .name = name, .by = by };
    }
    const sets = try arena.alloc(TypeSet, file.type_sets.len);
    for (file.type_sets, sets) |spec, *set| {
        const name = try strings.intern(gpa, spec.set);
        if (std.mem.indexOfScalar(StrId, names.items, name) != null) return malformed(diag, "type set {s} repeats a type or set name", .{spec.set});
        const members = try arena.alloc(StrId, spec.types.len);
        for (spec.types, members) |member, *id| {
            id.* = try strings.intern(gpa, member);
            if (std.mem.indexOfScalar(StrId, names.items, id.*) == null) return malformed(diag, "type set {s} names {s}, no type or earlier set", .{ spec.set, member });
        }
        try names.append(arena, name);
        set.* = .{ .name = name, .types = members };
    }
    if (names.items.len > max_net_types) return malformed(diag, "{d} net types and type sets declared; at most 64", .{names.items.len});
    out.net_types = types;
    out.type_sets = sets;
}

/// What one `net_types` entry assigns by: `nets` alone, or `models` (a
/// leading `!` negating) with known `pins`; null when it states neither or
/// both.
fn netTypeBy(arena: Allocator, gpa: Allocator, name: []const u8, nets: ?[]const []const u8, models: ?[]const []const u8, pins: []const []const u8, strings: *StrTable, diag: *Diagnostic) Error!?NetTypeBy {
    if (nets) |n| return if (models == null and pins.len == 0) .{ .names = n } else null;
    const all = models orelse return null;
    for (pins) |pin| {
        const known = for (pin_names) |p| {
            if (std.mem.eql(u8, p, pin)) break true;
        } else false;
        if (!known) return malformed(diag, "net type {s}: pin {s} is none of g, s, d, b, c, e, pos, neg", .{ name, pin });
    }
    const negate = all.len > 0 and std.mem.eql(u8, all[0], "!");
    const listed = all[@intFromBool(negate)..];
    if (listed.len == 0) return malformed(diag, "net type {s}: models names no model", .{name});
    const ids = try arena.alloc(StrId, listed.len);
    for (listed, ids) |m, *id| id.* = try strings.intern(gpa, m);
    return .{ .devices = .{ .models = ids, .negate = negate, .pins = pins } };
}
