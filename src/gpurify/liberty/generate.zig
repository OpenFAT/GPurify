//! Liberty generation for a hard macro, the spine: `Loaded` + `Extracted` +
//! a `Request` → a `Generated`, the Verilog blackbox and one `.lib` per PVT
//! corner, in memory for the caller to write. Ported from src/liberty/mod.rs
//! (`LibError`, `Generated`, `Request`, `generate`, `cross_check`,
//! `lef_pins`, `area_um2`) with the engine's `design_extent`
//! (src/engine/run.rs).
//!
//! The accuracy ladder, cheapest first: `interface` (pins, `pg_pin`s,
//! directions, area; no simulator), `analytical` (closed-form wire C plus
//! static device C; leakage simulated), `field` (field-solved wire C),
//! `spice` (the extracted RC netlist simulated: NLDM delay and transition,
//! setup and hold, internal energy, charge-integrated pin C), `statistical`
//! (plus Monte Carlo LVF sigma). Every level above `interface` runs ngspice
//! (`ngspice -b`, the spec's `simulator.binary`), each corner's measurements
//! on a pool of `simulator.workers` sessions, one corner after another.
//!
//! Before anything is measured the spec's pins are checked against the
//! layout's labels, the reference `.subckt`'s ports and the LEF's pins:
//! name drift between these is the integration failure this exists to stop.
//! A run never returns part of its output: the first failure ends it.
//!
//! Contents:
//! - `pub const Request = struct { spec, accuracy, lef, work, tool_version, env }`
//! - `pub const File = struct { path, text }`, `pub const Generated = struct { files, notes }`
//! - `pub const Error`
//! - `pub fn generate(arena: Allocator, loaded: *const Loaded, extracted: *const Extracted, request: Request, diag: *Diagnostic) Error!Generated`
//! - `pub fn lefPins(arena: Allocator, lef: []const u8, cell: []const u8) Allocator.Error!?[]const []const u8`

const std = @import("std");
const Allocator = std.mem.Allocator;
const geom = @import("geom");
const Bbox = geom.Bbox;
const Loaded = @import("../load.zig").Loaded;
const Extracted = @import("../extracted.zig").Extracted;
const spec = @import("spec.zig");
const Accuracy = spec.Accuracy;
const MacroSpec = spec.MacroSpec;
const Diagnostic = spec.Diagnostic;
const circuit = @import("circuit.zig");
const session = @import("session.zig");
const write = @import("write.zig");
const prepare_ = @import("prepare.zig");
const corner_ = @import("corner.zig");

/// Everything a run needs besides the layout; the reference netlist comes
/// with `Loaded` and is cross-checked whenever present.
pub const Request = struct {
    /// From `spec.parse`, which validated it.
    spec: *const MacroSpec,
    accuracy: Accuracy,
    /// The LEF's text: the `PIN`s of its `MACRO <cell>` must be the spec's.
    lef: ?[]const u8 = null,
    /// Where testbench decks and simulator logs go, `env.dir`-relative:
    /// created if missing, never removed (the logs say what failed).
    work: []const u8,
    /// Written into every header comment.
    tool_version: []const u8,
    /// The simulator sessions' allocator, I/O, directory and environment.
    env: session.Env,
};

/// One output file, its path relative to the output directory.
pub const File = struct { path: []const u8, text: []const u8 };

/// `files`: `<cell>.v`, then per corner in spec order `<cell>__<corner>.lib`,
/// followed by `min/<cell>__<corner>.lib` (library `<cell>__<corner>__min`,
/// since OpenSTA skips a second library of a name it has read) when that
/// corner's arc cases disagree. `notes`: what did not stop the run (labels
/// the spec does not list, constraints clamped to the window).
pub const Generated = struct { files: []const File, notes: []const []const u8 };

/// `Mismatch`: the spec's pins disagree with the reference's top `.subckt`
/// or the LEF macro (the message names what each side lacks); a spec pin
/// missing from the layout is `MissingPin`. Every other member as
/// circuit.zig, prepare.zig, corner.zig and session.zig document them;
/// `diag.message` is mod.rs's text.
pub const Error = error{Mismatch} || prepare_.Error || corner_.Error;

/// Generates the blackbox and one Liberty model per corner at
/// `request.accuracy`, everything in `arena`.
pub fn generate(arena: Allocator, loaded: *const Loaded, extracted: *const Extracted, request: Request, diag: *Diagnostic) Error!Generated {
    const macro = request.spec;
    var notes: std.ArrayList([]const u8) = .empty;
    var files: std.ArrayList(File) = .empty;
    try crossCheck(arena, loaded, extracted, request, &notes, diag);
    const area = areaUm2(loaded);
    var verilog: std.Io.Writer.Allocating = .init(arena);
    write.writeBlackbox(macro.cell, macro.pins, request.tool_version, &verilog.writer) catch return error.OutOfMemory;
    try files.append(arena, .{ .path = try arena.print("{s}.v", .{macro.cell}), .text = verilog.written() });
    request.env.dir.createDirPath(request.env.io, request.work) catch |err| {
        diag.message = try arena.print("io: {s}: {s}", .{ request.work, @errorName(err) });
        return error.Io;
    };
    // ponytail: every extraction, solve and simulation temporary shares
    // `arena`; split a scratch allocator off when peak RSS matters.
    const prepared = try prepare_.prepare(arena, loaded, extracted, macro, request.accuracy, diag);
    const run: corner_.Run = .{ .arena = arena, .env = request.env, .macro = macro, .accuracy = request.accuracy, .work = request.work, .prepared = &prepared };
    for (macro.corners) |*corner| {
        const cells = try corner_.characterize(run, corner, &notes, diag);
        for (cells, [_][]const u8{ "", "__min" }, [_][]const u8{ "", "min/" }) |maybe, suffix, dir| {
            var cell = maybe orelse continue;
            cell.area_um2 = area;
            const lib: write.Library = .{ .name = try arena.print("{s}__{s}{s}", .{ macro.cell, corner.name, suffix }), .corner = corner, .thresholds = &macro.characterization, .accuracy = request.accuracy, .tool_version = request.tool_version, .cell = cell };
            var text: std.Io.Writer.Allocating = .init(arena);
            write.writeLiberty(arena, &lib, &text.writer) catch return error.OutOfMemory;
            try files.append(arena, .{ .path = try arena.print("{s}{s}__{s}.lib", .{ dir, macro.cell, corner.name }), .text = text.written() });
        }
    }
    return .{ .files = files.items, .notes = notes.items };
}

/// The `PIN` names of `MACRO cell` in a LEF, ascending and each once; null
/// when the LEF has no such macro.
pub fn lefPins(arena: Allocator, lef: []const u8, cell: []const u8) Allocator.Error!?[]const []const u8 {
    var inside = false;
    var found = false;
    var pins: std.ArrayList([]const u8) = .empty;
    var lines = std.mem.splitScalar(u8, lef, '\n');
    while (lines.next()) |line| {
        var words = std.mem.tokenizeAny(u8, line, " \t\r");
        const first = words.next() orelse continue;
        const name = words.next() orelse continue;
        if (std.mem.eql(u8, first, "MACRO") and std.mem.eql(u8, name, cell)) {
            inside = true;
            found = true;
        } else if (std.mem.eql(u8, first, "END") and inside and std.mem.eql(u8, name, cell)) {
            inside = false;
        } else if (std.mem.eql(u8, first, "PIN") and inside) {
            try pins.append(arena, name);
        }
    }
    if (!found) return null;
    return sortedSet(pins.items);
}

// ---- private ----

/// Spec pins against the layout's labels (a label the spec lacks is noted,
/// it may name an internal net), the reference `.subckt`'s ports and the
/// LEF's pins; the last two must match exactly.
fn crossCheck(arena: Allocator, loaded: *const Loaded, extracted: *const Extracted, request: Request, notes: *std.ArrayList([]const u8), diag: *Diagnostic) Error!void {
    const macro = request.spec;
    var wanted: std.ArrayList([]const u8) = .empty;
    for (macro.pins) |p| try wanted.append(arena, p.name);
    const spec_names = sortedSet(wanted.items);
    var labelled: std.ArrayList([]const u8) = .empty;
    for (0..extracted.nets.netCount()) |n| for (extracted.ports.namesOf(@fromBackingInt(@intCast(n)))) |name| {
        try labelled.append(arena, loaded.strings.resolve(name));
    };
    var unlisted: std.ArrayList(u8) = .empty;
    for (sortedSet(labelled.items)) |name| if (!has(spec_names, name)) {
        if (unlisted.items.len > 0) try unlisted.appendSlice(arena, ", ");
        try unlisted.appendSlice(arena, name);
    };
    if (unlisted.items.len > 0) try notes.append(arena, try arena.print("the layout labels nets the spec does not list, taken as internal: {s}", .{unlisted.items}));
    var start: std.ArrayList(u32) = .empty;
    var nets: std.ArrayList(@import("check").topology.net.NetId) = .empty;
    try circuit.pinNetsInto(arena, loaded, extracted, macro, &start, &nets, diag);
    if (loaded.reference) |*reference| {
        const top = try reference.top(arena) orelse {
            diag.message = try arena.dupe(u8, "the reference netlist has no unique top subcircuit");
            return error.Mismatch;
        };
        var ports: std.ArrayList([]const u8) = .empty;
        for (reference.portsOf(top)) |net| try ports.append(arena, loaded.strings.resolve(reference.net_name.items[@backingInt(net)]));
        const name = loaded.strings.resolve(reference.subckt_name.items[@backingInt(top)]);
        if (!std.mem.eql(u8, name, macro.cell)) {
            diag.message = try arena.print("the reference's top subcircuit is {s}, the spec's cell {s}", .{ name, macro.cell });
            return error.Mismatch;
        }
        try compare(arena, "the reference .subckt", spec_names, sortedSet(ports.items), diag);
    }
    if (request.lef) |lef| {
        const pins = try lefPins(arena, lef, macro.cell) orelse {
            diag.message = try arena.print("the LEF has no MACRO {s}", .{macro.cell});
            return error.Mismatch;
        };
        try compare(arena, "the LEF macro", spec_names, pins, diag);
    }
}

/// `Mismatch` naming what `found` lacks and has beyond `wanted`; both sorted sets.
fn compare(arena: Allocator, source: []const u8, wanted: []const []const u8, found: []const []const u8, diag: *Diagnostic) Error!void {
    var missing: std.ArrayList(u8) = .empty;
    var extra: std.ArrayList(u8) = .empty;
    for (wanted) |w| if (!has(found, w)) {
        if (missing.items.len > 0) try missing.appendSlice(arena, ", ");
        try missing.appendSlice(arena, w);
    };
    for (found) |f| if (!has(wanted, f)) {
        if (extra.items.len > 0) try extra.appendSlice(arena, ", ");
        try extra.appendSlice(arena, f);
    };
    if (missing.items.len == 0 and extra.items.len == 0) return;
    diag.message = try arena.print("{s} lacks [{s}] and has [{s}] that the spec does not", .{ source, missing.items, extra.items });
    return error.Mismatch;
}

/// Sorts `names` ascending and drops repeats, in place.
fn sortedSet(names: [][]const u8) []const []const u8 {
    std.mem.sortUnstable([]const u8, names, {}, struct {
        fn less(_: void, x: []const u8, y: []const u8) bool {
            return std.mem.order(u8, x, y) == .lt;
        }
    }.less);
    var kept: usize = 0;
    for (names) |n| {
        if (kept > 0 and std.mem.eql(u8, names[kept - 1], n)) continue;
        names[kept] = n;
        kept += 1;
    }
    return names[0..kept];
}

fn has(set: []const []const u8, name: []const u8) bool {
    for (set) |s| if (std.mem.eql(u8, s, name)) return true;
    return false;
}

/// The die area, µm²: the deck's outline layer if drawn, else every drawn
/// shape's box.
fn areaUm2(loaded: *const Loaded) f64 {
    const die = designExtent(loaded);
    if (die.isEmpty()) return 0.0;
    const per_um: f64 = @floatFromInt(loaded.grid.dbu_per_um);
    return @as(f64, @floatFromInt(die.width())) * @as(f64, @floatFromInt(die.height())) / (per_um * per_um);
}

/// The deck's outline layer's extent when drawn, else every drawn
/// (non-derived) layer's.
/// ponytail: duplicate of the engine's design_extent; dedupe when run.zig lands.
fn designExtent(loaded: *const Loaded) Bbox {
    const deck = &loaded.deck.deck;
    const store = &loaded.store;
    if (deck.boundary) |layer| if (@backingInt(layer) < store.layerCount()) {
        var outline: Bbox = .empty;
        for (store.layerBboxes(layer)) |b| outline = outline.merge(b);
        if (!outline.isEmpty()) return outline;
    };
    var die: Bbox = .empty;
    for (0..store.layerCount()) |l| {
        const layer: geom.LayerId = @fromBackingInt(@intCast(l));
        if (deck.layers.isDerived(layer)) continue;
        for (store.layerBboxes(layer)) |b| die = die.merge(b);
    }
    return die;
}

test "lef pins are read inside the named macro only" {
    // Oracle: construct-from-answer, by LEF's `MACRO` ... `END` scoping: `m`
    // holds `a` and `vdd`, `other`'s `x` is not among them, and a macro the
    // file lacks is none.
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    const lef = "MACRO other\n PIN x\n END x\nEND other\nMACRO m\n PIN a\n  DIRECTION INPUT ;\n END a\n PIN vdd\n END vdd\nEND m\n";
    const pins = (try lefPins(arena.allocator(), lef, "m")).?;
    try std.testing.expectEqual(2, pins.len);
    try std.testing.expectEqualStrings("a", pins[0]);
    try std.testing.expectEqualStrings("vdd", pins[1]);
    try std.testing.expect(try lefPins(arena.allocator(), lef, "nope") == null);
}

test "accuracy parses by name and level" {
    // Oracle: `Accuracy.parse`'s doc: a name or a level `0` to `4`, so
    // `field` is `field`, `4` is `statistical` and `5` is nothing.
    try std.testing.expectEqual(Accuracy.field, Accuracy.parse("field").?);
    try std.testing.expectEqual(Accuracy.statistical, Accuracy.parse("4").?);
    try std.testing.expect(Accuracy.parse("5") == null);
}
