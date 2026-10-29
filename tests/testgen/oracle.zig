//! The independent tools the comparison tests run against: KLayout, Netgen,
//! Magic, FastCap, FastHenry, OpenROAD, Yosys and ngspice, all provided by
//! `nix develop .#comparison` and run under `-Dcomparison-tests=true`.
//!
//! A comparison that cannot find or finish its tool fails, naming the shell
//! that provides it: a comparison that did not run must never read as one
//! that passed. Its output streams are kept in the run directory for a
//! reader, so a failure leaves them behind.
//!
//! Contents:
//! - `pub const Error`, `pub const Diagnostic = struct`
//! - `pub fn run(gpa: Allocator, io: std.Io, dir: std.Io.Dir, argv: []const []const u8, limit_s: i64, diag: *Diagnostic) Error![]u8`

const std = @import("std");
const Allocator = std.mem.Allocator;

/// `Missing`: `argv[0]` is not on `PATH`. `Failed`: it exited unsuccessfully
/// or by a signal. `TimedOut`: it ran past its limit and was stopped.
pub const Error = error{ Missing, Failed, TimedOut, Io } || Allocator.Error;

/// What went wrong, for the test's failure message: the tool's two streams
/// (owned by the caller's allocator) and how it ended.
pub const Diagnostic = struct {
    tool: []const u8 = "",
    stdout: []const u8 = "",
    stderr: []const u8 = "",
    term: ?std.process.Child.Term = null,
};

/// Runs `argv` in `dir` (stdin empty, so a tool that falls back to reading
/// commands ends instead of waiting) and returns its standard output, owned
/// by `gpa`. Both streams are also written to `stdout.txt` and `stderr.txt`
/// in `dir`. Fails, printing why on stderr, when the tool is missing, runs
/// past `limit_s` seconds, or exits unsuccessfully.
pub fn run(gpa: Allocator, io: std.Io, dir: std.Io.Dir, argv: []const []const u8, limit_s: i64, diag: *Diagnostic) Error![]u8 {
    diag.* = .{ .tool = argv[0] };
    const ran = std.process.run(gpa, io, .{
        .argv = argv,
        .cwd = .{ .dir = dir },
        .timeout = .{ .duration = .{ .raw = .fromSeconds(limit_s), .clock = .awake } },
    }) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        error.FileNotFound => {
            std.debug.print("{s} is not on PATH: run this test inside `nix develop .#comparison`\n", .{argv[0]});
            return error.Missing;
        },
        error.Timeout => {
            std.debug.print("{s} ran past {d} s and was stopped\n", .{ argv[0], limit_s });
            return error.TimedOut;
        },
        else => {
            std.debug.print("cannot run {s}: {t}\n", .{ argv[0], err });
            return error.Io;
        },
    };
    diag.stdout = ran.stdout;
    diag.stderr = ran.stderr;
    diag.term = ran.term;
    dir.writeFile(io, .{ .sub_path = "stdout.txt", .data = ran.stdout }) catch return error.Io;
    dir.writeFile(io, .{ .sub_path = "stderr.txt", .data = ran.stderr }) catch return error.Io;
    if (!ran.term.success()) {
        std.debug.print("{s} failed ({any}):\n{s}\n{s}\n", .{ argv[0], ran.term, ran.stdout, ran.stderr });
        gpa.free(ran.stderr);
        return error.Failed;
    }
    gpa.free(ran.stderr);
    return ran.stdout;
}

test "a tool that is not on PATH fails, never reads as a pass" {
    // Oracle: the module's contract: a missing tool is `Missing`, not an
    // empty output a comparison could mistake for agreement.
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var diag: Diagnostic = .{};
    try std.testing.expectError(error.Missing, run(std.testing.allocator, std.testing.io, tmp.dir, &.{"gpurify-no-such-tool"}, 5, &diag));
}

test "a tool's standard output comes back and both streams are kept" {
    // Oracle: construct-from-answer: `sh -c 'echo hi; echo err >&2'` prints
    // `hi` and `err`; the run returns the first and keeps both files.
    const gpa = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var diag: Diagnostic = .{};
    const out = try run(gpa, std.testing.io, tmp.dir, &.{ "sh", "-c", "echo hi; echo err >&2" }, 5, &diag);
    defer gpa.free(out);
    try std.testing.expectEqualStrings("hi\n", out);
    var buf: [16]u8 = undefined;
    try std.testing.expectEqualStrings("err\n", try tmp.dir.readFile(std.testing.io, "stderr.txt", &buf));
}
