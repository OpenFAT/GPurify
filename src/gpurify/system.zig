//! `gpurify system`: several dies placed into one assembly and checked as
//! one: system LVS (catalog LVS-073) and package- and system-level ESD
//! (ERC-C12, ERC-C13), whose checks are system_checks.zig. Ported from
//! src/engine/system.rs.
//!
//! In: a system description (`ingest.system`) naming each die's layout,
//! deck, intent and placement, its bonded faces and its package face; and
//! the system netlist, whose unique top places one instance per die, named
//! as the die, and whose ports are the package pins. Out: `Outputs` and a
//! `Summary`, the comparison as the LVS stage, the ESD rows as ERC. A run:
//! reads every die into one string table, then the system netlist (its
//! model-less cards bind to every die deck's recognisers together);
//! extracts each die and projects it to a graph whose labelled nets are
//! `<die>.<label>`; places and bonds every bonded face's bumps; merges the
//! dies' graphs through the bonds and compares the pins by name; compares
//! the merged graph with the flattened netlist, every net of the top a
//! port; with an `esd` section, holds die-to-die bumps to their own die's
//! clamps and package pins to the assembly's.
//!
//! Contents:
//! - `pub const SystemRun = struct { strings, grid, outputs, summary }`, `pub const Error`, `pub const Diagnostic`
//! - `pub fn run(gpa: Allocator, run_arena: Allocator, io: std.Io, dir: std.Io.Dir, system_path: []const u8, reference_path: []const u8, diag: *Diagnostic) Error!SystemRun`
//! - `pub fn checkSystem(gpa: Allocator, run_arena: Allocator, spec: *const System, dies: []const Die, intents: []const ?DesignIntent, reference: *const Netlist, strings: *StrTable, out: *Outputs, diag: *Diagnostic) Error!Summary`
//! - `pub fn allModels(arena: Allocator, dies: []const Die) Allocator.Error!DeviceRecognition`

const std = @import("std");
const Allocator = std.mem.Allocator;
const geom = @import("geom");
const Grid = geom.Grid;
const Point = geom.Point;
const StrId = geom.StrId;
const StrTable = geom.StrTable;
const ingest = @import("ingest");
const System = ingest.system.System;
const Face = ingest.system.Face;
const DesignIntent = ingest.intent.DesignIntent;
const Netlist = ingest.netlist.Netlist;
const DeviceRecognition = ingest.deck.DeviceRecognition;
const check = @import("check");
const lvs = check.lvs;
const Graph = lvs.Graph;
const NetId = check.topology.NetId;
const report = check.report;
const load_ = @import("load.zig");
const Die = load_.Die;
const extracted_ = @import("extracted.zig");
const Extracted = extracted_.Extracted;
const run_ = @import("run.zig");
const Outputs = run_.Outputs;
const Summary = run_.Summary;
const StageStatus = run_.StageStatus;
const sys = @import("system_checks.zig");
const reference_ = @import("reference.zig");
const paramNames = @import("checks_lvs.zig").paramNames;

/// What a system run produced, with the table its names are in and the
/// grid every die shares; everything in the run arena.
pub const SystemRun = struct { strings: StrTable, grid: Grid, outputs: Outputs, summary: Summary };

/// The description (`ingest.system.Error`), a die's or the netlist's read
/// (`load.Error`, `Diagnostic.what` naming it), a die's extraction, or dies
/// and a netlist that make no one assembly (`Assembly`, `Diagnostic.why`).
pub const Error = ingest.system.Error || load_.Error || extracted_.Error || run_.Error || error{Assembly};

pub const Diagnostic = struct {
    system: ingest.system.Diagnostic = .{},
    /// The die, or "the system netlist", a load or extract error is about.
    what: []const u8 = "",
    load: load_.Diagnostic = .{},
    extract: extracted_.Diagnostic = .none,
    /// Why the dies make no one assembly.
    why: []const u8 = "",
};

/// One die, extracted and projected, with where it sits.
const Placed = struct { extracted: Extracted, graph: Graph, placement: sys.Placement };

/// Where each die's nets landed in the assembled graph.
const Assembly = struct {
    class: []const u32,
    offset: []const u32,

    fn net(s: Assembly, die: u32, n: u32) u32 {
        return s.class[s.offset[die] + n];
    }
};

/// Reads a system description and the system netlist (paths under `dir`),
/// then checks them.
pub fn run(gpa: Allocator, run_arena: Allocator, io: std.Io, dir: std.Io.Dir, system_path: []const u8, reference_path: []const u8, diag: *Diagnostic) Error!SystemRun {
    const spec = try ingest.system.readSystem(run_arena, io, dir, system_path, &diag.system);
    var out: SystemRun = .{ .strings = .empty, .grid = undefined, .outputs = .{}, .summary = undefined };
    const dies = try run_arena.alloc(Die, spec.dies.len);
    const intents = try run_arena.alloc(?DesignIntent, spec.dies.len);
    for (spec.dies, dies, intents) |d, *read, *intent| {
        diag.what = d.name;
        read.* = try load_.loadDie(gpa, run_arena, io, dir, d.layout, d.deck, &out.strings, &diag.load);
        intent.* = null;
        if (d.intent) |path| {
            diag.load = .{ .stage = .intent, .path = path };
            intent.* = try ingest.intent.readIntent(run_arena, run_arena, io, dir, path, &out.strings, &diag.load.intent);
        }
    }
    diag.what = "the system netlist";
    diag.load = .{ .stage = .reference, .path = reference_path };
    const text = dir.readFileAlloc(io, reference_path, run_arena, .unlimited) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        else => return error.Unreadable,
    };
    const ext = std.fs.path.extension(reference_path);
    const models = try allModels(run_arena, dies);
    const reference = try reference_.readReferenceText(run_arena, text, std.mem.eql(u8, ext, ".scs") or std.mem.eql(u8, ext, ".spectre"), &models, &out.strings, &diag.load.netlist);
    out.grid = dies[0].grid;
    out.summary = try checkSystem(gpa, run_arena, &spec, dies, intents, &reference, &out.strings, &out.outputs, diag);
    return out;
}

/// Every die deck's device models together, which a model-less card or an
/// `X` card calling a device of the system netlist binds to.
pub fn allModels(arena: Allocator, dies: []const Die) Allocator.Error!DeviceRecognition {
    var kind: std.ArrayList(ingest.deck.DeviceKind) = .empty;
    var model: std.ArrayList(StrId) = .empty;
    for (dies) |d| {
        try kind.appendSlice(arena, d.deck.deck.devices.kind);
        try model.appendSlice(arena, d.deck.deck.devices.model);
    }
    return .{ .kind = kind.items, .model = model.items };
}

/// Checks a system whose dies are read (`dies[i]`, `intents[i]` belong to
/// `spec.dies[i]`), `reference` the system netlist as read, every name in
/// `strings`, into `out` (empty on entry).
pub fn checkSystem(gpa: Allocator, run_arena: Allocator, spec: *const System, dies: []const Die, intents: []const ?DesignIntent, reference: *const Netlist, strings: *StrTable, out: *Outputs, diag: *Diagnostic) Error!Summary {
    std.debug.assert(dies.len == spec.dies.len and intents.len == spec.dies.len);
    const a = run_arena;
    const grid = dies[0].grid;
    for (spec.dies, dies) |d, read| if (read.grid.dbu_per_um != grid.dbu_per_um)
        return assembly(a, diag, "die {s} is on a grid of {d} units per µm and die {s} on {d}: every die of a system shares one grid", .{ d.name, read.grid.dbu_per_um, spec.dies[0].name, grid.dbu_per_um });
    const top = try reference.top(a) orelse return assembly(a, diag, "the system netlist has no unique top subcircuit", .{});
    const instance_of = try instances(a, spec, reference, top, strings, diag);
    diag.what = "the system netlist";
    const flat = try ingest.netlist.flattenTop(a, reference, top, strings, &diag.load.netlist);
    try lvs.internRuleIds(a, strings);
    try sys.internRuleIds(a, strings);

    const placed = try place(gpa, a, spec, dies, grid, strings, diag);
    const faces = try a.alloc([2][]const sys.Bump, spec.bonds.len);
    for (spec.bonds, faces) |bond, *f| f.* = .{ try bumps(a, spec, dies, placed, bond[0], strings, diag), try bumps(a, spec, dies, placed, bond[1], strings, diag) };
    const package: []const sys.Bump = if (spec.package) |face| try bumps(a, spec, dies, placed, face, strings, diag) else &.{};

    const pairs = try a.alloc([]const [2]u32, faces.len);
    try sys.checkBonds(a, faces, strings, &out.violations, &out.runs, pairs);
    const limits = try a.alloc([2]?geom.Dbu, spec.bond_limits.len);
    for (spec.bond_limits, limits) |l, *o| o.* = .{ try onGrid(a, grid, l.max_offset_nm, "max_offset_nm", diag), try onGrid(a, grid, l.min_space_nm, "min_space_nm", diag) };
    try sys.checkAlignment(a, faces, pairs, limits, strings, &out.violations, &out.runs);

    const offset = try a.alloc(u32, placed.len);
    var nets: u32 = 0;
    for (placed, offset) |p, *o| {
        o.* = nets;
        nets += p.graph.netCount();
    }
    var joins: std.ArrayList([2]u32) = .empty;
    for (spec.bonds, faces, pairs) |bond, f, ps| for (ps) |pr| try joins.append(a, .{ offset[bond[0].die] + @backingInt(f[0][pr[0]].net), offset[bond[1].die] + @backingInt(f[1][pr[1]].net) });
    const graphs = try a.alloc(*const Graph, placed.len);
    for (placed, graphs) |*p, *g| g.* = &p.graph;
    var layout: Graph = .{};
    var class: std.ArrayList(u32) = .empty;
    try sys.assemble(a, graphs, joins.items, &layout, &class);
    const at: Assembly = .{ .class = class.items, .offset = offset };

    // A pin's place: the first bump on its die's net, bonded faces first.
    var first_bump: std.AutoHashMapUnmanaged([2]u32, Point) = .empty;
    for (spec.bonds, faces) |bond, f| for (bond, f) |face, side| for (side) |b| {
        const got = try first_bump.getOrPut(a, .{ face.die, @backingInt(b.net) });
        if (!got.found_existing) got.value_ptr.* = geom.ops.centre(b.at);
    };
    if (spec.package) |face| for (package) |b| {
        const got = try first_bump.getOrPut(a, .{ face.die, @backingInt(b.net) });
        if (!got.found_existing) got.value_ptr.* = geom.ops.centre(b.at);
    };
    var pins: std.ArrayList(sys.Pin) = .empty;
    for (instance_of, 0..) |maybe, die| {
        const instance = maybe orelse continue;
        const callee = @backingInt(reference.instance_of.items[instance]);
        const ports = reference.port_net.items[reference.subckt_port_start.items[callee]..reference.subckt_port_start.items[callee + 1]];
        const passed = reference.instance_net.items[reference.instance_net_start.items[instance]..reference.instance_net_start.items[instance + 1]];
        for (ports, passed) |port, net| try pins.append(a, pinOf(placed, &first_bump, at, @intCast(die), reference.net_name.items[@backingInt(port)], @backingInt(net)));
    }
    // The top's ports are the package pins, labelled on the package face's die.
    if (spec.package) |face| {
        const row = @backingInt(top);
        for (reference.port_net.items[reference.subckt_port_start.items[row]..reference.subckt_port_start.items[row + 1]]) |port| try pins.append(a, pinOf(placed, &first_bump, at, face.die, reference.net_name.items[@backingInt(port)], @backingInt(port)));
    }
    try sys.checkPins(a, pins.items, strings, &out.violations, &out.runs);

    const lvs_status = try compare(a, &layout, &flat, reference, top, spec, dies, strings, out);
    // Bonds, alignment and pins count as LVS, the stage the
    // system's summary reports them under (DRC is not selected).
    try run_.tagRuns(a, out, .lvs);
    const erc: StageStatus = if (spec.esd) |esd| try esdRows(a, spec, esd, placed, intents, faces, package, &layout, at, strings, out, diag) else .not_selected;
    try run_.tagRuns(a, out, .erc);
    return run_.summarize(run_arena, out, .{ .not_selected, erc, lvs_status, .not_selected });
}

// ---- private ----

fn assembly(arena: Allocator, diag: *Diagnostic, comptime fmt: []const u8, args: anytype) Error {
    diag.why = try std.fmt.allocPrint(arena, fmt, args);
    return error.Assembly;
}

fn onGrid(arena: Allocator, grid: Grid, nm: ?f64, what: []const u8, diag: *Diagnostic) Error!?geom.Dbu {
    const v = nm orelse return null;
    return grid.toDbu(geom.Qty(.length, .nano){ .raw = v }) catch assembly(arena, diag, "a bond's {s} {d} is not a whole number of grid units", .{ what, v });
}

/// Per die, the top instance of the system netlist named as it, if any.
/// Every instance the top places must be a die.
fn instances(arena: Allocator, spec: *const System, reference: *const Netlist, top: ingest.netlist.SubcktId, strings: *const StrTable, diag: *Diagnostic) Error![]const ?u32 {
    const out = try arena.alloc(?u32, spec.dies.len);
    @memset(out, null);
    for (0..reference.instance_of.items.len) |instance| {
        if (reference.instance_subckt.items[instance] != top) continue;
        const name = strings.resolve(reference.instance_name.items[instance]);
        const die = for (spec.dies, 0..) |d, i| (if (std.mem.eql(u8, d.name, name)) break i) else return assembly(arena, diag, "the system netlist places instance {s}, which is no die of the system", .{name});
        out[die] = @intCast(instance);
    }
    return out;
}

/// Extracts every die, projects it to a graph whose labelled nets are
/// `<die>.<label>`, and converts its placement onto the grid.
fn place(gpa: Allocator, arena: Allocator, spec: *const System, dies: []const Die, grid: Grid, strings: *StrTable, diag: *Diagnostic) Error![]Placed {
    _ = gpa;
    const out = try arena.alloc(Placed, dies.len);
    for (spec.dies, dies, out) |d, read, *p| {
        diag.what = d.name;
        p.extracted = try extracted_.extractLayout(arena, &read.store, &read.deck.deck, &read.provenance, &diag.extract);
        p.graph = .{};
        try lvs.fromLayoutInto(arena, &p.extracted.nets, &p.extracted.devices, &p.extracted.ports, strings, grid, &p.graph);
        for (p.graph.net_name.items) |*name| if (name.*) |label| {
            name.* = try strings.intern(arena, try std.fmt.allocPrint(arena, "{s}.{s}", .{ d.name, strings.resolve(label) }));
        };
        const dx = grid.toDbu(geom.Qty(.length, .nano){ .raw = d.origin_nm[0] }) catch return assembly(arena, diag, "die {s}: origin_nm {any} is not a whole number of grid units", .{ d.name, d.origin_nm });
        const dy = grid.toDbu(geom.Qty(.length, .nano){ .raw = d.origin_nm[1] }) catch return assembly(arena, diag, "die {s}: origin_nm {any} is not a whole number of grid units", .{ d.name, d.origin_nm });
        p.placement = .{ .mirror = d.mirror, .quarter_turns = d.quarter_turns, .dx = dx, .dy = dy };
    }
    return out;
}

/// The bumps of one face, placed.
fn bumps(arena: Allocator, spec: *const System, dies: []const Die, placed: []const Placed, face: Face, strings: *const StrTable, diag: *Diagnostic) Error![]const sys.Bump {
    const name = spec.dies[face.die].name;
    const read = &dies[face.die];
    const layer = read.deck.deck.layers.id(strings, face.layer) orelse return assembly(arena, diag, "die {s}: its deck has no layer {s}", .{ name, face.layer });
    const die = &placed[face.die];
    var out: std.ArrayList(sys.Bump) = .empty;
    var bad: geom.PolyId = undefined;
    sys.bumpsInto(arena, .{ .store = &read.store, .nets = &die.extracted.nets, .devices = &die.extracted.devices }, layer, die.placement, &out, &bad) catch |err| return switch (err) {
        error.NotRectangle => assembly(arena, diag, "die {s}, layer {s}: shape PolyId({d}) is not a rectangle", .{ name, face.layer, @backingInt(bad) }),
        error.NoNet => assembly(arena, diag, "die {s}, layer {s}: shape PolyId({d}) is on no net: the layer is not a conductor", .{ name, face.layer, @backingInt(bad) }),
        error.OutOfMemory => error.OutOfMemory,
    };
    return out.items;
}

fn pinOf(placed: []const Placed, first_bump: *const std.AutoHashMapUnmanaged([2]u32, Point), at: Assembly, die: u32, name: StrId, reference: u32) sys.Pin {
    const nets = placed[die].extracted.ports.netsOf(name);
    if (nets.len == 0) return .{ .reference = reference, .layout = std.math.maxInt(u32), .at = report.nowhere };
    const net = @backingInt(nets[0]);
    return .{ .reference = reference, .layout = at.net(die, net), .at = first_bump.get(.{ die, net }) orelse report.nowhere };
}

/// The flat comparison: `layout` against the flattened system netlist,
/// every net of its top a port, within the strictest of the dies' `lvs
/// tolerance default`s; refused when a die's deck states none.
fn compare(a: Allocator, layout: *const Graph, flat: *const Netlist, reference: *const Netlist, top: ingest.netlist.SubcktId, spec: *const System, dies: []const Die, strings: *const StrTable, out: *Outputs) Error!StageStatus {
    var tolerance = std.math.inf(f64);
    for (spec.dies, dies) |d, read| {
        const stated = read.deck.deck.lvs.default_tolerance orelse return .{ .refused = try std.fmt.allocPrint(a, "die {s}: its deck states no `lvs tolerance default`", .{d.name}) };
        tolerance = @min(tolerance, stated);
    }
    var schematic: Graph = .{};
    try lvs.fromReferenceInto(a, flat, @fromBackingInt(0), &schematic);
    // The top's own nets are the flattened netlist's first rows: each joins
    // pins of dies, as a bonded net joins labelled ones in the layout.
    var top_nets: usize = 0;
    for (reference.net_subckt.items) |s| top_nets += @intFromBool(s == top);
    const is_port = try a.alloc(bool, top_nets);
    @memset(is_port, false);
    for (schematic.port_net.items) |net| if (net < top_nets) {
        is_port[net] = true;
    };
    for (is_port, 0..) |port, net| if (!port) try schematic.port_net.append(a, @intCast(net));
    var traced: lvs.Traced = .{};
    try lvs.compareTraced(a, layout, &schematic, .{ .params = paramNames(strings), .param_tolerance = tolerance }, &.{}, &traced);
    out.lvs = traced;
    return switch (traced.verdict) {
        .match => .ran,
        .mismatch => {
            try lvs.records.recordDiscrepancies(a, traced.found.items, strings, &out.violations);
            return .ran;
        },
        .inconclusive => |why| .{ .refused = switch (why) {
            .round_limit => "the comparison did not conclude: RoundLimit",
            .ambiguous_top => "the comparison did not conclude: AmbiguousTop",
        } },
    };
}

/// The ESD rows: `system.esd_d2d` per die through its own clamps,
/// `system.esd_package` through the assembly's, `system.esd_iec` for the
/// named pins through the system-rated clamps; skipped for no intent.
fn esdRows(a: Allocator, spec: *const System, esd: ingest.system.EsdSpec, placed: []const Placed, intents: []const ?DesignIntent, faces: []const [2][]const sys.Bump, package: []const sys.Bump, layout: *const Graph, at: Assembly, strings: *StrTable, out: *Outputs, diag: *Diagnostic) Error!StageStatus {
    const clamps = try internAll(a, strings, esd.clamps);
    const rated = try internAll(a, strings, esd.system_clamps);
    const named = try internAll(a, strings, esd.system_pins);
    const rules = [3]StrId{ strings.get("system.esd_d2d").?, strings.get("system.esd_package").?, strings.get("system.esd_iec").? };
    const any_intent = for (intents) |i| (if (i != null) break true) else false;
    if (!any_intent) {
        const configured: usize = if (named.len == 0) 2 else 3;
        for (rules[0..configured]) |rule| try out.runs.append(a, .{ .rule = rule, .outcome = .{ .skipped = .no_design_intent }, .examined = 0, .violations = 0 });
        return .ran;
    }
    const supply = try a.alloc([]u8, placed.len);
    for (placed, intents, supply) |*p, intent, *s| s.* = try rails(a, p, if (intent) |*i| i else null);
    const assembled = try a.alloc(u8, layout.netCount());
    @memset(assembled, 0);
    for (supply, 0..) |bits, die| for (bits, 0..) |b, net| {
        assembled[at.net(@intCast(die), @intCast(net))] |= b;
    };
    // Die-to-die bumps, each through its own die alone.
    var before = out.violations.len();
    var examined: u64 = 0;
    for (placed, 0..) |*p, die| {
        var pads: std.ArrayList(sys.Pad) = .empty;
        for (spec.bonds, faces) |bond, f| for (bond, f) |face, side| if (face.die == die) for (side) |b| try pads.append(a, .{ .net = @backingInt(b.net), .at = geom.ops.centre(b.at) });
        examined += try sys.esdPadsInto(a, rules[0], &p.graph, supply[die], clamps, pads.items, &out.violations);
    }
    try appendRun(a, out, rules[0], before, examined);
    const face = spec.package.?; // the system reader refuses esd without a package face
    var pads: std.ArrayList(sys.Pad) = .empty;
    for (package) |b| try pads.append(a, .{ .net = at.net(face.die, @backingInt(b.net)), .at = geom.ops.centre(b.at) });
    before = out.violations.len();
    examined = try sys.esdPadsInto(a, rules[1], layout, assembled, clamps, pads.items, &out.violations);
    try appendRun(a, out, rules[1], before, examined);
    if (named.len == 0) return .ran;
    const ports = &placed[face.die].extracted.ports;
    var exposed: std.ArrayList(sys.Pad) = .empty;
    for (package) |b| {
        const is_named = for (ports.namesOf(b.net)) |n| (if (std.mem.findScalar(StrId, named, n) != null) break true) else false;
        if (is_named) try exposed.append(a, .{ .net = at.net(face.die, @backingInt(b.net)), .at = geom.ops.centre(b.at) });
    }
    for (named, esd.system_pins) |name, text| {
        const on_a_bump = for (package) |b| (if (std.mem.findScalar(StrId, ports.namesOf(b.net), name) != null) break true) else false;
        if (!on_a_bump) return assembly(a, diag, "system pin {s} labels no bump of the package face", .{text});
    }
    before = out.violations.len();
    examined = try sys.esdPadsInto(a, rules[2], layout, assembled, rated, exposed.items, &out.violations);
    try appendRun(a, out, rules[2], before, examined);
    return .ran;
}

fn internAll(a: Allocator, strings: *StrTable, names: []const []const u8) Allocator.Error![]const StrId {
    const out = try a.alloc(StrId, names.len);
    for (names, out) |n, *o| o.* = try strings.intern(a, n);
    return out;
}

fn appendRun(a: Allocator, out: *Outputs, rule: StrId, before: u32, examined: u64) Allocator.Error!void {
    try out.runs.append(a, .{ .rule = rule, .outcome = .ran, .examined = examined, .violations = std.math.lossyCast(u32, out.violations.len() - before) });
}

/// A die's supply bits per net, from the labels its intent declares.
fn rails(a: Allocator, die: *const Placed, intent: ?*const DesignIntent) Allocator.Error![]u8 {
    const bits = try a.alloc(u8, die.graph.netCount());
    @memset(bits, 0);
    const i = intent orelse return bits;
    for (bits, 0..) |*slot, net| for (die.extracted.ports.namesOf(@fromBackingInt(@as(u32, @intCast(net))))) |name| {
        if (i.supplyRole(name)) |s| slot.* |= switch (s.role) {
            .power => sys.power,
            .ground => sys.ground,
        };
    };
    return bits;
}
