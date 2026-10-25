//! The system description: which dies make up a multi-die assembly (2.5D,
//! 3D, chiplets on an interposer), where each sits, which faces are bonded,
//! and which face meets the package. In: the system JSON and the directory
//! it is in. Out: a `System`, every path joined to that directory. It is the
//! configuration Calibre 3DSTACK reads (Siemens fact sheet 82850-D2, 2022);
//! each die's layout, deck and intent stay their own files, and pin-level
//! connectivity is the system netlist. Every key is checked; nothing partial
//! is returned. Ported from crates/ingest/src/system.rs.
//!
//! Contents:
//! - `pub const Error`, `pub const Diagnostic`, `Diagnostic.text(d: *const Diagnostic) []const u8`
//! - `pub const System`, `pub const DieSpec`, `pub const Face`, `pub const BondLimits`, `pub const EsdSpec`
//! - `pub fn parseSystem(arena: Allocator, source: []const u8, base: []const u8, diag: *Diagnostic) Error!System`
//! - `pub fn readSystem(arena: Allocator, io: std.Io, dir: std.Io.Dir, sub_path: []const u8, diag: *Diagnostic) Error!System`

const std = @import("std");
const Allocator = std.mem.Allocator;

/// Why a system description was rejected; `Diagnostic.text` says why.
pub const Error = error{
    /// Not JSON of the schema (an unknown or repeated key, a wrong type), or
    /// a value the schema refuses: no die, a die named twice or not at all,
    /// a rotation that is not a quarter turn, an origin that is not a
    /// number, a face naming an unlisted die, a bond between a die and
    /// itself, a bond limit below 0, or an `esd` section naming no clamp,
    /// with no package face, or naming system pins without system clamps
    /// (or the reverse).
    Malformed,
    /// The file could not be read.
    Io,
    OutOfMemory,
};

/// The refusal in words, as the Rust tool's `SystemFileError` displayed it.
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

/// A parsed system description; its slices live in the parse's arena.
pub const System = struct {
    /// Every die, in file order; a die's index is how the rest refers to it.
    dies: []const DieSpec,
    /// Bonded face pairs, on two different dies, and each bond's alignment
    /// limits.
    bonds: []const [2]Face,
    bond_limits: []const BondLimits,
    /// The face that meets the package substrate: its bumps are the
    /// component's external pins.
    package: ?Face,
    /// The ESD checks to run, if any.
    esd: ?EsdSpec,
};

/// One die of the assembly.
pub const DieSpec = struct {
    /// The system netlist's instance of the die has this name; a die no
    /// instance names is interconnect only (an interposer).
    name: []const u8,
    /// The die's GDSII layout, process deck and design intent.
    layout: []const u8,
    deck: []const u8,
    intent: ?[]const u8,
    /// Where the die's origin lands, in nanometres.
    origin_nm: [2]f64,
    /// Counter-clockwise quarter turns, 0 to 3, applied after `mirror`
    /// (reflection in x, a die flipped face down): a GDSII reference's order.
    quarter_turns: u2,
    mirror: bool,
};

/// One face of a die: the deck layer whose shapes are its bumps, TSV
/// landings or bond pads.
pub const Face = struct { die: u32, layer: []const u8 };

/// What a bond's bumps are held to, each null when unstated: the largest
/// centre-to-centre offset of two bonded bumps and the least gap to an
/// unbonded facing bump, nanometres, 0 or more.
pub const BondLimits = struct { max_offset_nm: ?f64 = null, min_space_nm: ?f64 = null };

/// The ESD checks: which device models protect a pin.
pub const EsdSpec = struct {
    /// ESD protection devices and rail clamps; at least one.
    clamps: []const []const u8,
    /// Models rated for system-level stress (IEC 61000-4-2); empty exactly
    /// when `system_pins` is.
    system_clamps: []const []const u8,
    /// Package pins exposed to system-level ESD, by their bump's label.
    system_pins: []const []const u8,
};

/// The wire shape; std.json refuses unknown and repeated keys.
const SystemWire = struct {
    dies: []const struct {
        name: []const u8,
        layout: []const u8,
        deck: []const u8,
        intent: ?[]const u8 = null,
        origin_nm: [2]f64 = .{ 0, 0 },
        rotate: u32 = 0,
        mirror: bool = false,
    },
    bonds: []const struct {
        a: FaceWire,
        b: FaceWire,
        max_offset_nm: ?f64 = null,
        min_space_nm: ?f64 = null,
    } = &.{},
    package: ?FaceWire = null,
    esd: ?struct {
        clamps: []const []const u8,
        system_clamps: []const []const u8 = &.{},
        system_pins: []const []const u8 = &.{},
    } = null,
};

const FaceWire = struct { die: []const u8, layer: []const u8 };

/// Parses and validates a system description; relative paths are taken
/// from `base`, the file's directory. Schema (Rust `parse_system`): `dies`
/// required and not empty, each `name`, `layout`, `deck`, optional `intent`,
/// `origin_nm` ([0, 0]), `rotate` (0, 90, 180 or 270), `mirror` (false);
/// optional `bonds` (`a`, `b` faces, `max_offset_nm`, `min_space_nm`),
/// `package` face, `esd` (`clamps`, `system_clamps`, `system_pins`).
pub fn parseSystem(arena: Allocator, source: []const u8, base: []const u8, diag: *Diagnostic) Error!System {
    const wire = blk: {
        var scanner: std.json.Scanner = .initCompleteInput(arena, source);
        var where: std.json.Diagnostics = .{};
        scanner.enableDiagnostics(&where);
        break :blk std.json.parseFromTokenSourceLeaky(SystemWire, arena, &scanner, .{}) catch |err| {
            if (err == error.OutOfMemory) return error.OutOfMemory;
            return malformed(diag, "{s} at line {d} column {d}", .{ @errorName(err), where.getLine(), where.getColumn() });
        };
    };
    if (wire.dies.len == 0) return malformed(diag, "a system needs at least one die", .{});
    const dies = try arena.alloc(DieSpec, wire.dies.len);
    for (wire.dies, dies, 0..) |die, *spec, k| {
        if (die.name.len == 0) return malformed(diag, "a die has an empty name", .{});
        for (dies[0..k]) |seen| if (std.mem.eql(u8, seen.name, die.name)) return malformed(diag, "die {s} is listed twice", .{die.name});
        if (die.rotate % 90 != 0 or die.rotate >= 360) return malformed(diag, "die {s}: rotate is {d}, not 0, 90, 180 or 270", .{ die.name, die.rotate });
        if (!(std.math.isFinite(die.origin_nm[0]) and std.math.isFinite(die.origin_nm[1]))) return malformed(diag, "die {s}: origin_nm is not a number", .{die.name});
        spec.* = .{
            .name = die.name,
            .layout = try join(arena, base, die.layout),
            .deck = try join(arena, base, die.deck),
            .intent = if (die.intent) |path| try join(arena, base, path) else null,
            .origin_nm = die.origin_nm,
            .quarter_turns = @intCast(die.rotate / 90),
            .mirror = die.mirror,
        };
    }
    const bonds = try arena.alloc([2]Face, wire.bonds.len);
    const bond_limits = try arena.alloc(BondLimits, wire.bonds.len);
    for (wire.bonds, bonds, bond_limits) |bond, *pair, *limits| {
        for ([_]?f64{ bond.max_offset_nm, bond.min_space_nm }, [_][]const u8{ "max_offset_nm", "min_space_nm" }) |value, name| {
            const v = value orelse continue;
            if (!(std.math.isFinite(v) and v >= 0)) return malformed(diag, "a bond's {s} is not a number of 0 or more", .{name});
        }
        limits.* = .{ .max_offset_nm = bond.max_offset_nm, .min_space_nm = bond.min_space_nm };
        pair.* = .{ try face(dies, bond.a, diag), try face(dies, bond.b, diag) };
        if (pair[0].die == pair[1].die) return malformed(diag, "a bond joins die {s} to itself", .{dies[pair[0].die].name});
    }
    const package = if (wire.package) |p| try face(dies, p, diag) else null;
    const esd: ?EsdSpec = if (wire.esd) |e| esd: {
        if (e.clamps.len == 0) return malformed(diag, "esd names no clamp model", .{});
        if (package == null) return malformed(diag, "esd checks the package pins, so the system needs a package face", .{});
        if ((e.system_pins.len == 0) != (e.system_clamps.len == 0)) return malformed(diag, "esd: system pins need system clamps, and system clamps need system pins", .{});
        break :esd .{ .clamps = e.clamps, .system_clamps = e.system_clamps, .system_pins = e.system_pins };
    } else null;
    return .{ .dies = dies, .bonds = bonds, .bond_limits = bond_limits, .package = package, .esd = esd };
}

/// Reads `sub_path` under `dir`; paths in it are relative to its directory.
/// `error.Io` names the path when it cannot be read.
pub fn readSystem(arena: Allocator, io: std.Io, dir: std.Io.Dir, sub_path: []const u8, diag: *Diagnostic) Error!System {
    const source = dir.readFileAlloc(io, sub_path, arena, .unlimited) catch |err| {
        if (err == error.OutOfMemory) return error.OutOfMemory;
        diag.set("io: {s}: {s}", .{ sub_path, @errorName(err) });
        return error.Io;
    };
    return parseSystem(arena, source, std.fs.path.dirname(sub_path) orelse "", diag);
}

// ---- private ----

fn malformed(diag: *Diagnostic, comptime fmt: []const u8, args: anytype) Error {
    diag.set("malformed system description: " ++ fmt, args);
    return error.Malformed;
}

/// `path` taken from `base`, as Rust's `Path::join`: an absolute path stands.
fn join(arena: Allocator, base: []const u8, path: []const u8) Allocator.Error![]const u8 {
    if (std.fs.path.isAbsolute(path) or base.len == 0) return path;
    return std.fs.path.join(arena, &.{ base, path });
}

fn face(dies: []const DieSpec, wire: FaceWire, diag: *Diagnostic) Error!Face {
    for (dies, 0..) |die, k| if (std.mem.eql(u8, die.name, wire.die)) return .{ .die = @intCast(k), .layer = wire.layer };
    return malformed(diag, "a face names die {s}, which the system does not list", .{wire.die});
}

test "a full description reads back as written" {
    // Oracle: construct-from-answer against the schema in `parseSystem`'s
    // doc: every value reads back as written, paths joined to the base,
    // `rotate: 270` is three quarter turns, left-out keys take the defaults.
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    var diag: Diagnostic = .{};
    const system = try parseSystem(arena.allocator(),
        \\{
        \\  "dies": [
        \\    { "name": "Xint", "layout": "int.gds", "deck": "int.deck" },
        \\    { "name": "Xcpu", "layout": "/abs/cpu.gds", "deck": "cpu.deck",
        \\      "intent": "cpu.json", "origin_nm": [1500, -20],
        \\      "rotate": 270, "mirror": true }
        \\  ],
        \\  "bonds": [{ "a": { "die": "Xint", "layer": "ubump" },
        \\              "b": { "die": "Xcpu", "layer": "bump" } }],
        \\  "package": { "die": "Xint", "layer": "c4" },
        \\  "esd": { "clamps": ["dio"], "system_clamps": ["scr"],
        \\           "system_pins": ["usb_dp"] }
        \\}
    , "/work", &diag);
    const int = system.dies[0];
    const cpu = system.dies[1];
    const expectStr = std.testing.expectEqualStrings;
    try expectStr("/work/int.gds", int.layout);
    try expectStr("/abs/cpu.gds", cpu.layout);
    try expectStr("/work/cpu.json", cpu.intent.?);
    try std.testing.expectEqual(null, int.intent);
    try std.testing.expectEqual([2]f64{ 0, 0 }, int.origin_nm);
    try std.testing.expectEqual(0, int.quarter_turns);
    try std.testing.expect(!int.mirror);
    try std.testing.expectEqual([2]f64{ 1500, -20 }, cpu.origin_nm);
    try std.testing.expectEqual(3, cpu.quarter_turns);
    try std.testing.expect(cpu.mirror);
    try std.testing.expectEqual(1, system.bonds.len);
    try std.testing.expectEqual(0, system.bonds[0][0].die);
    try expectStr("ubump", system.bonds[0][0].layer);
    try std.testing.expectEqual(1, system.bonds[0][1].die);
    try expectStr("bump", system.bonds[0][1].layer);
    try std.testing.expectEqual(0, system.package.?.die);
    try expectStr("c4", system.package.?.layer);
    const esd = system.esd.?;
    try expectStr("dio", esd.clamps[0]);
    try expectStr("scr", esd.system_clamps[0]);
    try expectStr("usb_dp", esd.system_pins[0]);
}

test "every malformed description is refused with its reason" {
    // Oracle: the refusals `Error.Malformed` documents, one description
    // breaking each, each message naming the rule broken. An unknown key
    // reads `UnknownField`, std.json's name for serde's "unknown field".
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const die = "{{ \"name\": \"{s}\", \"layout\": \"l.gds\", \"deck\": \"d.deck\"{s} }}";
    const two = try std.fmt.allocPrint(a, die ++ ", " ++ die, .{ "A", "", "B", "" });
    const bond = "{{ \"dies\": [{s}], \"bonds\": [{{ \"a\": {{ \"die\": \"A\", \"layer\": \"b\" }}, \"b\": {{ \"die\": \"{s}\", \"layer\": \"c\" }} }}] }}";
    const cases = [_][2][]const u8{
        .{ "{ \"dies\": [] }", "at least one die" },
        .{ try std.fmt.allocPrint(a, "{{ \"dies\": [" ++ die ++ "] }}", .{ "", "" }), "empty name" },
        .{ try std.fmt.allocPrint(a, "{{ \"dies\": [" ++ die ++ ", " ++ die ++ "] }}", .{ "A", "", "A", "" }), "listed twice" },
        .{ try std.fmt.allocPrint(a, "{{ \"dies\": [" ++ die ++ "] }}", .{ "A", ", \"rotate\": 45" }), "not 0, 90, 180 or 270" },
        .{ try std.fmt.allocPrint(a, "{{ \"dies\": [" ++ die ++ "] }}", .{ "A", ", \"rotate\": 360" }), "not 0, 90, 180 or 270" },
        .{ try std.fmt.allocPrint(a, "{{ \"dies\": [" ++ die ++ "] }}", .{ "A", ", \"flip\": true" }), "UnknownField" },
        .{ try std.fmt.allocPrint(a, bond, .{ two, "C" }), "does not list" },
        .{ try std.fmt.allocPrint(a, bond, .{ two, "A" }), "to itself" },
        .{ try std.fmt.allocPrint(a, "{{ \"dies\": [{s}], \"esd\": {{ \"clamps\": [\"d\"] }} }}", .{two}), "needs a package face" },
        .{ try std.fmt.allocPrint(a, "{{ \"dies\": [{s}], \"package\": {{ \"die\": \"A\", \"layer\": \"c4\" }}, \"esd\": {{ \"clamps\": [] }} }}", .{two}), "no clamp model" },
        .{ try std.fmt.allocPrint(a, "{{ \"dies\": [{s}], \"package\": {{ \"die\": \"A\", \"layer\": \"c4\" }}, \"esd\": {{ \"clamps\": [\"d\"], \"system_pins\": [\"p\"] }} }}", .{two}), "system pins need system clamps" },
    };
    for (cases) |c| {
        var diag: Diagnostic = .{};
        try std.testing.expectError(error.Malformed, parseSystem(a, c[0], "", &diag));
        if (std.mem.indexOf(u8, diag.text(), c[1]) == null) {
            std.debug.print("{s}: {s}\n", .{ c[0], diag.text() });
            return error.TestUnexpectedResult;
        }
    }
}
