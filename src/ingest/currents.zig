//! Simulated terminal currents: a simulator's per-terminal current file
//! (`espice-emir/1`, ESPice `--emir`, OpenFAT/EGSpice#237) → `Currents`, one
//! row per instance terminal: its average, electromigration-average, RMS
//! and peak current at one corner. In: the JSON. Out: the rows, names
//! interned, currents in µA (the file states amperes, positive into the
//! terminal). The header (`deck`, `analysis`, `temp`, `window`,
//! `em_recovery`, a sweep's `variant`) and the independent `sources` are
//! read for the schema and not kept: the corner is the simulation's, and a
//! source is no layout device. A key the format does not have refuses, as
//! a newer format would.
//!
//! Contents:
//! - `pub const Error`, `pub const Diagnostic`, `Diagnostic.text(d: *const Diagnostic) []const u8`
//! - `pub const format: []const u8`
//! - `pub const Currents = struct`, `Currents.len(c: *const Currents) u32`
//! - `pub fn parseCurrents(arena: Allocator, gpa: Allocator, source: []const u8, strings: *StrTable, diag: *Diagnostic) Error!Currents`
//! - `pub fn readCurrents(arena: Allocator, gpa: Allocator, io: std.Io, dir: std.Io.Dir, sub_path: []const u8, strings: *StrTable, diag: *Diagnostic) Error!Currents`

const std = @import("std");
const Allocator = std.mem.Allocator;
const geom = @import("geom");
const StrTable = geom.StrTable;
const StrId = geom.StrId;
const testing = std.testing;

/// Why a current file was rejected; `Diagnostic.text` says it in words.
pub const Error = error{
    /// Not JSON of the format (an unknown key, a wrong type, a repeated
    /// key), another `format`, an empty name, a current that is `null` (the
    /// simulator's NaN) or not finite, a negative `em_avg`, `rms` or
    /// `peak`, or one terminal listed twice.
    Malformed,
    /// The file could not be read.
    Io,
    OutOfMemory,
};

/// The refusal in words.
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

/// The `format` string this reader reads.
pub const format = "espice-emir/1";

/// One row per instance terminal, in file order, columns parallel. Every
/// `(instance, terminal)` is distinct. Its slices live in the `arena`
/// `parseCurrents` was given.
pub const Currents = struct {
    /// The flattened hierarchical name the simulator gives (`x1.mn1`).
    instance: []const StrId = &.{},
    /// The terminal's name on its instance (`d`).
    terminal: []const StrId = &.{},
    /// µA, the signed mean over the window, positive into the terminal.
    avg: []const f64 = &.{},
    /// µA, the electromigration average (recovery applied), at least 0.
    em_avg: []const f64 = &.{},
    /// µA, at least 0.
    rms: []const f64 = &.{},
    /// µA, the largest `|i|`.
    peak: []const f64 = &.{},

    pub fn len(c: *const Currents) u32 {
        return @intCast(c.instance.len);
    }
};

const ua_per_a: f64 = 1e6;

const value_names = [4][]const u8{ "avg", "em_avg", "rms", "peak" };

/// The wire shape (ESPice#237, its writer src/output/emir.zig on the
/// espice-237 branch): `variant` is an object (`{"kind": "nominal"}`),
/// `window` null at an operating point, a NaN statistic `null`. std.json
/// refuses unknown and repeated keys.
const File = struct {
    format: []const u8,
    deck: []const u8 = "",
    analysis: []const u8 = "",
    temp: ?f64 = null,
    window: ?[2]f64 = null,
    em_recovery: ?f64 = null,
    /// A sweep variant's label, as `--measures` writes it.
    variant: ?std.json.Value = null,
    terminals: []const Terminal,
    sources: []const Source = &.{},
};

const Terminal = struct {
    instance: []const u8,
    model: []const u8 = "",
    terminal: []const u8,
    net: []const u8 = "",
    avg: ?f64,
    em_avg: ?f64,
    rms: ?f64,
    peak: ?f64,
};

const Source = struct { instance: []const u8, net: []const u8 = "", avg: ?f64, em_avg: ?f64, rms: ?f64, peak: ?f64 };

/// ESPice#237's example, verbatim.
const example =
    \\{
    \\  "format": "espice-emir/1",
    \\  "deck": "hot.sp",
    \\  "analysis": "tran",
    \\  "temp": 125,
    \\  "window": [1e-06, 3e-06],
    \\  "em_recovery": 1,
    \\  "terminals": [
    \\    {"instance": "x1.mn1", "model": "sky130_fd_pr__nfet_01v8", "terminal": "d", "net": "x1.out",
    \\     "avg": 1.21e-04, "em_avg": 1.21e-04, "rms": 1.53e-04, "peak": 4.10e-04},
    \\    {"instance": "x1.mn1", "model": "sky130_fd_pr__nfet_01v8", "terminal": "s", "net": "x1.tail",
    \\     "avg": -1.21e-04, "em_avg": 1.21e-04, "rms": 1.53e-04, "peak": 4.10e-04}
    \\  ],
    \\  "sources": [
    \\    {"instance": "vdd", "net": "vdd", "avg": -5.49e-04, "em_avg": 5.49e-04, "rms": 6.27e-04, "peak": 1.14e-03}
    \\  ]
    \\}
;

/// Parses and validates a current file. Output and scratch go to `arena`;
/// names are interned into `strings` with `gpa`. On error nothing is
/// returned, `diag` says why, and `strings` may have gained names.
pub fn parseCurrents(arena: Allocator, gpa: Allocator, source: []const u8, strings: *StrTable, diag: *Diagnostic) Error!Currents {
    const file = blk: {
        var scanner: std.json.Scanner = .initCompleteInput(arena, source);
        var where: std.json.Diagnostics = .{};
        scanner.enableDiagnostics(&where);
        break :blk std.json.parseFromTokenSourceLeaky(File, arena, &scanner, .{}) catch |err| {
            if (err == error.OutOfMemory) return error.OutOfMemory;
            return malformed(diag, "{s} at line {d} column {d}", .{ @errorName(err), where.getLine(), where.getColumn() });
        };
    };
    if (!std.mem.eql(u8, file.format, format)) return malformed(diag, "format is {s}, not " ++ format, .{file.format});
    const n = file.terminals.len;
    const instance = try arena.alloc(StrId, n);
    const terminal = try arena.alloc(StrId, n);
    const columns = [4][]f64{ try arena.alloc(f64, n), try arena.alloc(f64, n), try arena.alloc(f64, n), try arena.alloc(f64, n) };
    for (file.terminals, 0..) |t, row| {
        if (t.instance.len == 0 or t.terminal.len == 0) return malformed(diag, "terminal {d} names no instance or terminal", .{row});
        const values = [4]?f64{ t.avg, t.em_avg, t.rms, t.peak };
        for (values, columns, 0..) |value, column, k| {
            // ESPice writes a NaN as `null`. A negative magnitude, or a
            // NaN, would read as a smaller current.
            const v = value orelse return malformed(diag, "{s} {s}: {s} is null, not a current", .{ t.instance, t.terminal, value_names[k] });
            if (!std.math.isFinite(v) or (k > 0 and v < 0)) return malformed(diag, "{s} {s}: {s} is {d}, not a current", .{ t.instance, t.terminal, value_names[k], v });
            column[row] = v * ua_per_a;
        }
        instance[row] = try strings.intern(gpa, t.instance);
        terminal[row] = try strings.intern(gpa, t.terminal);
    }
    // Sorted by (instance, terminal), a repeat sits next to its first.
    const order = try arena.alloc(u32, n);
    for (order, 0..) |*o, k| o.* = @intCast(k);
    const Keys = struct { instance: []const StrId, terminal: []const StrId };
    std.mem.sortUnstable(u32, order, Keys{ .instance = instance, .terminal = terminal }, struct {
        fn less(k: Keys, a: u32, b: u32) bool {
            if (k.instance[a] != k.instance[b]) return @backingInt(k.instance[a]) < @backingInt(k.instance[b]);
            return @backingInt(k.terminal[a]) < @backingInt(k.terminal[b]);
        }
    }.less);
    for (order[0..n -| 1], order[@min(1, n)..]) |a, b| if (instance[a] == instance[b] and terminal[a] == terminal[b]) {
        return malformed(diag, "{s} {s} is listed twice", .{ strings.resolve(instance[a]), strings.resolve(terminal[a]) });
    };
    return .{ .instance = instance, .terminal = terminal, .avg = columns[0], .em_avg = columns[1], .rms = columns[2], .peak = columns[3] };
}

/// Reads `sub_path` under `dir` and parses it as `parseCurrents` does.
/// `error.Io` names the path when it cannot be read.
pub fn readCurrents(arena: Allocator, gpa: Allocator, io: std.Io, dir: std.Io.Dir, sub_path: []const u8, strings: *StrTable, diag: *Diagnostic) Error!Currents {
    const source = dir.readFileAlloc(io, sub_path, arena, .unlimited) catch |err| {
        if (err == error.OutOfMemory) return error.OutOfMemory;
        diag.set("io: {s}: {s}", .{ sub_path, @errorName(err) });
        return error.Io;
    };
    return parseCurrents(arena, gpa, source, strings, diag);
}

// ---- private ----

fn malformed(diag: *Diagnostic, comptime fmt: []const u8, args: anytype) Error {
    diag.set("malformed current file: " ++ fmt, args);
    return error.Malformed;
}

test "the format's own example reads as two terminals in microamps" {
    // Oracle: OpenFAT/EGSpice#237's example file and its units: amperes,
    // positive into the terminal, so 1.21e-04 A is 121 uA drawn by the
    // drain and -121 uA by the source; the source row is no terminal.
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    var strings: StrTable = .empty;
    defer strings.deinit(testing.allocator);
    var diag: Diagnostic = .{};
    const c = try parseCurrents(arena.allocator(), testing.allocator, example, &strings, &diag);
    try testing.expectEqual(2, c.len());
    try testing.expectEqualStrings("x1.mn1", strings.resolve(c.instance[1]));
    try testing.expectEqualStrings("s", strings.resolve(c.terminal[1]));
    for ([_]f64{ 121, -121 }, c.avg) |want, got| try testing.expectApproxEqRel(want, got, 1e-12);
    try testing.expectApproxEqRel(@as(f64, 410), c.peak[0], 1e-12);
}

test "the writer's own output reads, a NaN source statistic aside" {
    // Oracle: ESPice's src/output/emir.zig test `encodeFile: the documented
    // layout` (espice-237 branch), its expected bytes verbatim: a variant
    // object, and a source whose peak is NaN (`null`), which is no
    // terminal and so is never read as a current.
    const written =
        \\{
        \\  "format": "espice-emir/1",
        \\  "deck": "hot.sp",
        \\  "variant": {"kind": "nominal"},
        \\  "analysis": "tran",
        \\  "temp": 125,
        \\  "window": [1e-6, 3e-6],
        \\  "em_recovery": 1,
        \\  "terminals": [
        \\    {"instance": "x1.mn1", "model": "nch", "terminal": "d", "net": "x1.out", "avg": 1.21e-4, "em_avg": 1.21e-4, "rms": 1.53e-4, "peak": 4.1e-4}
        \\  ],
        \\  "sources": [
        \\    {"instance": "vdd", "net": "vdd", "avg": -5.49e-4, "em_avg": 5.49e-4, "rms": 6.27e-4, "peak": null}
        \\  ]
        \\}
        \\
    ;
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    var strings: StrTable = .empty;
    defer strings.deinit(testing.allocator);
    var diag: Diagnostic = .{};
    const c = try parseCurrents(arena.allocator(), testing.allocator, written, &strings, &diag);
    try testing.expectEqual(1, c.len());
    try testing.expectApproxEqRel(@as(f64, 153), c.rms[0], 1e-12);
}

test "a file outside the format is refused, naming why" {
    // Oracle: the format's contract (ESPice#237): another `format`, an
    // unknown key, a negative RMS, one terminal twice and a nameless
    // instance are each refused, never read as zero.
    const cases = [_]struct { []const u8, []const u8 }{
        .{ "{\"format\":\"espice-emir/2\",\"terminals\":[]}", "format is espice-emir/2" },
        .{ "{\"format\":\"espice-emir/1\",\"terminals\":[],\"corner\":\"ss\"}", "UnknownField" },
        .{ "{\"format\":\"espice-emir/1\",\"terminals\":[{\"instance\":\"m1\",\"terminal\":\"d\",\"avg\":0,\"em_avg\":0,\"rms\":-1e-6,\"peak\":0}]}", "m1 d: rms is" },
        .{ "{\"format\":\"espice-emir/1\",\"terminals\":[{\"instance\":\"m1\",\"terminal\":\"d\",\"avg\":1,\"em_avg\":1,\"rms\":1,\"peak\":1},{\"instance\":\"m1\",\"terminal\":\"d\",\"avg\":1,\"em_avg\":1,\"rms\":1,\"peak\":1}]}", "m1 d is listed twice" },
        .{ "{\"format\":\"espice-emir/1\",\"terminals\":[{\"instance\":\"m1\",\"terminal\":\"d\",\"avg\":1,\"em_avg\":1,\"rms\":1,\"peak\":null}]}", "m1 d: peak is null" },
        .{ "{\"format\":\"espice-emir/1\",\"terminals\":[{\"instance\":\"\",\"terminal\":\"d\",\"avg\":1,\"em_avg\":1,\"rms\":1,\"peak\":1}]}", "names no instance" },
    };
    for (cases) |c| {
        var arena: std.heap.ArenaAllocator = .init(testing.allocator);
        defer arena.deinit();
        var strings: StrTable = .empty;
        defer strings.deinit(testing.allocator);
        var diag: Diagnostic = .{};
        try testing.expectError(error.Malformed, parseCurrents(arena.allocator(), testing.allocator, c[0], &strings, &diag));
        if (std.mem.indexOf(u8, diag.text(), c[1]) == null) {
            std.debug.print("{s}: {s}\n", .{ c[1], diag.text() });
            return error.TestUnexpectedResult;
        }
    }
}
