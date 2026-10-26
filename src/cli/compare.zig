//! `gpurify compare <reference> <candidate> [--spec <compare.json>]`: two
//! parasitic netlists, SPEF or DSPF, from any two tools, compared net by net
//! with nets linked by name (PEX-009). In: the arguments after `compare`.
//! Out: the report and whether it passes. Ported from src/cli/compare.rs.
//!
//! The spec, JSON, states the tolerance a qualification passes at,
//! `{"tolerance": 5}` in percent; without one it is 5 %. An unknown key is
//! an error, so a misspelled one never leaves the default in force.
//!
//! Contents:
//! - `pub fn run(arena: Allocator, io: std.Io, dir: std.Io.Dir, argv: []const []const u8, out: *std.Io.Writer, why: *[]const u8) Error!bool`
//! - `pub const Error = error{ Refused, OutOfMemory, WriteFailed }`

const std = @import("std");
const Allocator = std.mem.Allocator;
const Writer = std.Io.Writer;
const foreign = @import("gpurify").foreign;

/// `Refused`: the arguments, the spec or a netlist; `why` says which.
pub const Error = error{Refused} || Allocator.Error || Writer.Error;

/// Rows whose reference and candidate are both under these are noise to a
/// qualification and not compared: 0.01 fF, 0.01 Ω, 0.01 fs.
const floor = 0.01;

/// Writes the report to `out` and returns whether every metric's every
/// compared row is within the tolerance and both files hold the same nets.
pub fn run(arena: Allocator, io: std.Io, dir: std.Io.Dir, argv: []const []const u8, out: *Writer, why: *[]const u8) Error!bool {
    var files: std.ArrayList([]const u8) = .empty;
    var spec: ?[]const u8 = null;
    var i: usize = 0;
    while (i < argv.len) : (i += 1) {
        const arg = argv[i];
        if (std.mem.eql(u8, arg, "--spec")) {
            i += 1;
            if (i == argv.len) return refuse(arena, why, "--spec wants a value", .{});
            spec = argv[i];
        } else if (std.mem.eql(u8, arg, "--tolerance")) {
            return refuse(arena, why, "--tolerance is no longer an option: the compare spec's `tolerance` field (--spec <file>) says it now", .{});
        } else if (std.mem.startsWith(u8, arg, "-")) {
            return refuse(arena, why, "unknown option {s}", .{arg});
        } else try files.append(arena, arg);
    }
    if (files.items.len != 2) return refuse(arena, why, "compare takes two parasitic netlists: compare <reference> <candidate>", .{});
    const reference = files.items[0];
    const candidate = files.items[1];
    const tolerance = if (spec) |path| try readTolerance(arena, io, dir, path, why) else 5.0;
    const a = try read(arena, io, dir, reference, why);
    const b = try read(arena, io, dir, candidate, why);

    // Both files' names, ascending, each once: the shared net ids.
    var names: std.ArrayList([]const u8) = .empty;
    for ([_]*const foreign.Read{ &a, &b }) |r| for (0..r.nameCount()) |k| try names.append(arena, r.name(@intCast(k)));
    std.mem.sortUnstable([]const u8, names.items, {}, lessThan);
    var kept: usize = 0;
    for (names.items) |name| {
        if (kept > 0 and std.mem.eql(u8, names.items[kept - 1], name)) continue;
        names.items[kept] = name;
        kept += 1;
    }
    names.shrinkRetainingCapacity(kept);
    var na: foreign.ParasiticNetwork = .empty;
    var nb: foreign.ParasiticNetwork = .empty;
    try a.onNamesInto(arena, names.items, &na);
    try b.onNamesInto(arena, names.items, &nb);
    var result: foreign.Comparison = .empty;
    try foreign.compareInto(arena, &na, &nb, &result);

    const only_r = result.only_reference.items;
    const only_c = result.only_candidate.items;
    try out.print("reference {s}\ncandidate {s}\n", .{ reference, candidate });
    try out.print("nets: {d} in both, {d} in the reference only, {d} in the candidate only\n", .{ names.items.len - only_r.len - only_c.len, only_r.len, only_c.len });
    for (only_r) |net| try out.print("  only in the reference: {s}\n", .{names.items[net]});
    for (only_c) |net| try out.print("  only in the candidate: {s}\n", .{names.items[net]});
    try out.print("tolerance {d}%, rows under {d} in both not compared\n", .{ tolerance, floor });
    try out.writeAll("metric            unit  rows  within  worst%      mean%     rms%      worst row\n");
    const fraction = tolerance / 100.0;
    var passed = only_r.len == 0 and only_c.len == 0;
    const per_net = [_]struct { []const u8, []const u8, *const @TypeOf(result.total_cap) }{
        .{ "total_cap", "fF", &result.total_cap },
        .{ "ground_cap", "fF", &result.ground_cap },
        .{ "pin_to_pin_res", "ohm", &result.resistance },
        .{ "elmore_delay", "fs", &result.delay },
    };
    for (per_net) |m| {
        const e = foreign.errors(m[2].reference.items, m[2].candidate.items, fraction, floor);
        const at: ?[]const u8 = if (e.worst_row) |r| names.items[m[2].key.items[r]] else null;
        passed = try row(out, m[0], m[1], e, at) and passed;
    }
    const coupling = &result.coupling;
    const e = foreign.errors(coupling.reference.items, coupling.candidate.items, fraction, floor);
    const at: ?[]const u8 = if (e.worst_row) |r| try std.fmt.allocPrint(arena, "{s}/{s}", .{ names.items[coupling.key.items[r][0]], names.items[coupling.key.items[r][1]] }) else null;
    passed = try row(out, "coupling_cap", "fF", e, at) and passed;
    try out.print("{s}\n", .{if (passed) "pass" else "fail"});
    return passed;
}

// ---- private ----

fn refuse(arena: Allocator, why: *[]const u8, comptime fmt: []const u8, args: anytype) Error {
    why.* = try std.fmt.allocPrint(arena, fmt, args);
    return error.Refused;
}

/// The tolerance, percent, a spec file states.
fn readTolerance(arena: Allocator, io: std.Io, dir: std.Io.Dir, path: []const u8, why: *[]const u8) Error!f64 {
    const text = dir.readFileAlloc(io, path, arena, .unlimited) catch |err| return refuse(arena, why, "{s}: {t}", .{ path, err });
    const spec = std.json.parseFromSliceLeaky(struct { tolerance: f64 }, arena, text, .{}) catch |err|
        return refuse(arena, why, "{s}: {t}", .{ path, err });
    if (!std.math.isFinite(spec.tolerance) or spec.tolerance < 0) return refuse(arena, why, "{s}: tolerance {d} is not a percentage", .{ path, spec.tolerance });
    return spec.tolerance;
}

/// One netlist, its dialect told by its first non-blank line (`*SPEF` or
/// `*|DSPF`), else by its extension.
fn read(arena: Allocator, io: std.Io, dir: std.Io.Dir, path: []const u8, why: *[]const u8) Error!foreign.Read {
    const text = dir.readFileAlloc(io, path, arena, .unlimited) catch |err| return refuse(arena, why, "{s}: {t}", .{ path, err });
    var lines = std.mem.splitScalar(u8, text, '\n');
    const first = while (lines.next()) |l| (if (std.mem.trim(u8, l, " \t\r").len > 0) break l) else "";
    const ext = std.fs.path.extension(path);
    const spef = std.mem.startsWith(u8, first, "*SPEF") or (!std.mem.startsWith(u8, first, "*|") and std.ascii.eqlIgnoreCase(ext, ".spef"));
    const dspf = !spef and (std.mem.startsWith(u8, first, "*|DSPF") or std.ascii.eqlIgnoreCase(ext, ".dspf"));
    if (!spef and !dspf) return refuse(arena, why, "{s}: neither SPEF (*SPEF) nor DSPF (*|DSPF)", .{path});
    var out: foreign.Read = .empty;
    var diag: foreign.Diagnostic = .{};
    const read_ = if (spef) foreign.readSpefInto(arena, text, &out, &diag) else foreign.readDspfInto(arena, text, &out, &diag);
    read_ catch |err| {
        if (err == error.OutOfMemory) return error.OutOfMemory;
        return refuse(arena, why, "{s}: line {d}: {t} at `{s}`", .{ path, diag.line, err, diag.token });
    };
    return out;
}

/// One metric's line; whether every compared row is within.
fn row(out: *Writer, label: []const u8, unit: []const u8, e: foreign.Errors, at: ?[]const u8) Writer.Error!bool {
    // Rust's `{:>+9.3}`: the sign always shown.
    var buf: [64]u8 = undefined;
    const worst = 100.0 * e.worst;
    const signed = std.fmt.bufPrint(&buf, "{s}{d:.3}", .{ if (worst < 0) "-" else "+", @abs(worst) }) catch unreachable;
    try out.print("{s:<17} {s:<5} {d:>4}  {d:>6}  {s:>9}  {d:>8.3}  {d:>8.3}  {s}\n", .{ label, unit, e.count, e.within, signed, 100.0 * e.mean, 100.0 * e.rms, at orelse "-" });
    return e.within == e.count;
}

fn lessThan(_: void, x: []const u8, y: []const u8) bool {
    return std.mem.lessThan(u8, x, y);
}

test "a ground cap ten percent off fails at five and passes at twenty" {
    // Oracle: hand-derived: the candidate's ground cap on `b` is 10 % over the
    // reference's (0.33 against 0.3 fF), so at the default 5 % one row of two
    // fails and the run fails; at a spec's 20 % every row is within and it
    // passes; a net in one file only fails it whatever the tolerance. The flag
    // that used to say it is refused.
    const testing = std.testing;
    var arena_state: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const io = testing.io;
    const spef = "*SPEF \"IEEE 1481-2009\"\n*C_UNIT 1 FF\n*R_UNIT 1 OHM\n\n" ++
        "*D_NET a 1.0\n*CONN\n*P a I\n*CAP\n1 a:1 1.0\n*RES\n1 a a:1 10\n*END\n\n" ++
        "*D_NET b {s}\n*CONN\n*P b I\n*CAP\n1 b:1 {s}\n*RES\n1 b b:1 20\n*END\n{s}";
    const files = [_][2][]const u8{
        .{ "r.spef", try std.fmt.allocPrint(arena, spef, .{ "0.3", "0.3", "" }) },
        .{ "c.spef", try std.fmt.allocPrint(arena, spef, .{ "0.33", "0.33", "" }) },
        .{ "x.spef", try std.fmt.allocPrint(arena, spef, .{ "0.3", "0.3", "\n*D_NET c 0.5\n*CONN\n*P c I\n*CAP\n1 c:1 0.5\n*END\n" }) },
        .{ "20.json", "{\"tolerance\": 20}" },
        .{ "50.json", "{\"tolerance\": 50}" },
        .{ "typo.json", "{\"tolerence\": 20}" },
    };
    for (files) |f| try tmp.dir.writeFile(io, .{ .sub_path = f[0], .data = f[1] });
    var why: []const u8 = "";
    var text: Writer.Allocating = .init(arena);

    try testing.expect(!try run(arena, io, tmp.dir, &.{ "r.spef", "c.spef" }, &text.writer, &why));
    var lines = std.mem.splitScalar(u8, text.written(), '\n');
    const ground = while (lines.next()) |l| (if (std.mem.startsWith(u8, l, "ground_cap")) break l) else return error.TestUnexpectedResult;
    var words = std.mem.tokenizeScalar(u8, ground, ' ');
    for ([_][]const u8{ "ground_cap", "fF", "2", "1", "+10.000" }) |want| try testing.expectEqualStrings(want, words.next().?);

    text.clearRetainingCapacity();
    try testing.expect(try run(arena, io, tmp.dir, &.{ "r.spef", "c.spef", "--spec", "20.json" }, &text.writer, &why));
    text.clearRetainingCapacity();
    try testing.expect(!try run(arena, io, tmp.dir, &.{ "r.spef", "x.spef", "--spec", "50.json" }, &text.writer, &why));
    try testing.expect(std.mem.indexOf(u8, text.written(), "only in the candidate: c") != null);

    try testing.expectError(error.Refused, run(arena, io, tmp.dir, &.{"r.spef"}, &text.writer, &why));
    try testing.expectError(error.Refused, run(arena, io, tmp.dir, &.{ "r.spef", "c.spef", "--spec", "typo.json" }, &text.writer, &why));
    try testing.expectError(error.Refused, run(arena, io, tmp.dir, &.{ "r.spef", "c.spef", "--tolerance", "20%" }, &text.writer, &why));
    try testing.expectEqualStrings("--tolerance is no longer an option: the compare spec's `tolerance` field (--spec <file>) says it now", why);
}
