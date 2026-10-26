//! The simulator, run: a corner's deck in ngspice batch mode, one process
//! per `Session.run`, and a bounded pool of sessions draining a task list.
//! In: a deck path, command blocks. Out: the `RES <key> <value>` lines they
//! echo, as `Results`. Ported from src/liberty/spice.rs (`SimError`,
//! `Session`, `STATE_COMMANDS`, `remember`, `Results`, `run_pool`).
//!
//! ngspice is run as `<binary> -b <deck>` (the manual's "Batch mode": no
//! graphics, so it runs with no display), found on `PATH`. A batch run keeps
//! nothing, so a session replays the state earlier runs left (`alter`ed
//! sources, `option`s, a `setseed` and `reset`) before each run's commands.
//! A value the simulator could not measure comes back empty and reads as
//! null, never zero. A missing binary is `error.Spawn` naming it, never a
//! skip. There is no timeout: a simulation that never ends blocks.
//!
//! Contents:
//! - `pub const Error = error{ Spawn, Died, Measure, Io } || Allocator.Error`
//! - `pub const Results = std.StringArrayHashMapUnmanaged(?f64)`, `pub fn need(results: *const Results, key: []const u8) ?f64`
//! - `pub const Env = struct { gpa, io, dir, environ }`
//! - `pub const Session = struct`, `start`, `deinit`, `run`
//! - `pub fn remember(gpa: Allocator, state: *std.ArrayList(u8), commands: []const u8) Allocator.Error!void`
//! - `pub fn runPool(env: Env, sim: Simulator, deck: []const u8, corner: []const u8, workers: u32, count: u32, ctx: anytype, comptime task: fn (@TypeOf(ctx), *Session, Allocator, u32, *Diagnostic) Error!void, arena: Allocator, diag: *Diagnostic) Error!void`

const std = @import("std");
const Allocator = std.mem.Allocator;
const spec = @import("spec.zig");
const Simulator = spec.Simulator;
const Diagnostic = spec.Diagnostic;

/// `Spawn`: the binary could not be started (usually not on `PATH`).
/// `Died`: it stopped before the last command (crashed, or the deck made it
/// quit); its output is in the session's log. `Measure`: it ran, but a
/// value could not be measured; the message names the arc, case and point.
/// `Io`: a deck or log could not be read or written.
pub const Error = error{ Spawn, Died, Measure, Io } || Allocator.Error;

/// Measured values by key; null is a measurement that failed.
pub const Results = std.StringArrayHashMapUnmanaged(?f64);

/// Where a session runs: its allocator (thread-safe: sessions run on
/// several threads), I/O, the directory deck paths are under (the child's
/// working directory), and the child's environment (null: inherited; the
/// CLI sets `OMP_NUM_THREADS=1` here so workers do not oversubscribe).
pub const Env = struct {
    gpa: Allocator,
    io: std.Io,
    dir: std.Io.Dir,
    environ: ?*const std.process.Environ.Map = null,
};

/// A corner's deck, run once per `run`; the state a run leaves is replayed
/// before the next one, so a session behaves as one simulator.
pub const Session = struct {
    env: Env,
    binary: []const u8,
    /// The deck without its closing `.end`; owned.
    deck: []const u8,
    /// Every state command run so far, in order; owned.
    state: std.ArrayList(u8) = .empty,
    serial: u64 = 0,
    corner: []const u8,
    /// The log path, `dir`-relative; owned.
    log: []const u8,

    /// Reads `deck`, creates `log`, and runs the deck once with no commands.
    pub fn start(env: Env, sim: Simulator, deck: []const u8, corner: []const u8, log: []const u8, scratch: Allocator, diag: *Diagnostic) Error!Session {
        const text = env.dir.readFileAlloc(env.io, deck, env.gpa, .unlimited) catch |err|
            return ioError(scratch, diag, "{s}: {s}", .{ deck, @errorName(err) });
        defer env.gpa.free(text);
        const trimmed = std.mem.trimEnd(u8, text, " \t\r\n");
        const body = if (std.mem.endsWith(u8, trimmed, ".end")) trimmed[0 .. trimmed.len - 4] else text;
        env.dir.writeFile(env.io, .{ .sub_path = log, .data = "" }) catch |err|
            return ioError(scratch, diag, "{s}: {s}", .{ log, @errorName(err) });
        var s: Session = .{ .env = env, .binary = sim.binary, .deck = try env.gpa.dupe(u8, body), .corner = corner, .log = try env.gpa.dupe(u8, log) };
        errdefer s.deinit();
        _ = try s.run(scratch, "", diag);
        return s;
    }

    pub fn deinit(s: *Session) void {
        s.env.gpa.free(s.deck);
        s.env.gpa.free(s.log);
        s.state.deinit(s.env.gpa);
    }

    /// Runs the deck with the replayed state and `commands` as its
    /// `.control` section; every `RES <key> <value>` line echoed, in
    /// `scratch`. A key echoed twice keeps its last value; one that does not
    /// parse or is not finite reads null. The run's deck is kept beside the
    /// log only when the run fails, its output then appended to the log.
    pub fn run(s: *Session, scratch: Allocator, commands: []const u8, diag: *Diagnostic) Error!Results {
        s.serial += 1;
        const env = s.env;
        const marker = try scratch.print("@@END{d}", .{s.serial});
        const stem = if (std.mem.endsWith(u8, s.log, ".log")) s.log[0 .. s.log.len - 4] else s.log;
        const path = try scratch.print("{s}.{d}.cir", .{ stem, s.serial });
        const text = try scratch.print("{s}\n.control\nset noaskquit\n{s}{s}\necho \"{s}\"\n.endc\n.end\n", .{ s.deck, s.state.items, commands, marker });
        env.dir.writeFile(env.io, .{ .sub_path = path, .data = text }) catch |err|
            return ioError(scratch, diag, "{s}: {s}", .{ path, @errorName(err) });
        const ran = std.process.run(scratch, env.io, .{
            .argv = &.{ s.binary, "-b", path },
            .cwd = .{ .dir = env.dir },
            .environ_map = env.environ,
        }) catch |err| switch (err) {
            error.OutOfMemory => return error.OutOfMemory,
            else => {
                diag.message = try scratch.print("could not start {s}: {s}", .{ s.binary, @errorName(err) });
                return error.Spawn;
            },
        };
        try s.append(scratch, ran.stderr, diag);
        var finished = false;
        var lines = std.mem.splitScalar(u8, ran.stdout, '\n');
        while (lines.next()) |line| finished = finished or std.mem.eql(u8, std.mem.trimEnd(u8, line, " \t\r"), marker);
        if (!finished) {
            try s.append(scratch, try scratch.print("---- {s} ({any})\n{s}\n", .{ path, ran.term, ran.stdout }), diag);
            diag.message = try scratch.print("the simulator stopped answering (corner {s}): {s} ended before its last command; its log is {s}", .{ s.corner, path, s.log });
            return error.Died;
        }
        env.dir.deleteFile(env.io, path) catch {};
        var results: Results = .empty;
        lines = std.mem.splitScalar(u8, ran.stdout, '\n');
        while (lines.next()) |raw| {
            const line = std.mem.trimEnd(u8, raw, " \t\r");
            if (!std.mem.startsWith(u8, line, "RES ")) continue;
            var words = std.mem.tokenizeAny(u8, line[4..], " \t");
            const key = words.next() orelse continue;
            const value: ?f64 = if (words.next()) |w| std.fmt.parseFloat(f64, w) catch null else null;
            try results.put(scratch, key, if (value != null and std.math.isFinite(value.?)) value else null);
        }
        try remember(env.gpa, &s.state, commands);
        return results;
    }

    fn append(s: *Session, scratch: Allocator, bytes: []const u8, diag: *Diagnostic) Error!void {
        if (bytes.len == 0) return;
        const env = s.env;
        var file = env.dir.createFile(env.io, s.log, .{ .truncate = false }) catch |err|
            return ioError(scratch, diag, "{s}: {s}", .{ s.log, @errorName(err) });
        defer file.close(env.io);
        const end = file.length(env.io) catch |err| return ioError(scratch, diag, "{s}: {s}", .{ s.log, @errorName(err) });
        file.writePositionalAll(env.io, bytes, end) catch |err| return ioError(scratch, diag, "{s}: {s}", .{ s.log, @errorName(err) });
    }
};

/// Sessions beyond this share the work of the ones that started.
const max_workers = 256;

/// The value of `key`, or null when it was not echoed or not measured.
pub fn need(results: *const Results, key: []const u8) ?f64 {
    return results.get(key) orelse null;
}

/// Appends to `state` the state lines of `commands` (`alter`, `altermod`,
/// `option`, `setseed`, `reset`), in order. A setting rewritten (`alter X =
/// …`) replaces the line that set it before, so the replayed state stays the
/// size of the circuit's settings however many runs a session makes.
pub fn remember(gpa: Allocator, state: *std.ArrayList(u8), commands: []const u8) Allocator.Error!void {
    var lines = std.mem.splitScalar(u8, commands, '\n');
    while (lines.next()) |line| {
        var words = std.mem.tokenizeAny(u8, line, " \t\r");
        const word = words.next() orelse "";
        const is_state = for ([_][]const u8{ "alter", "altermod", "option", "setseed", "reset" }) |c| (if (std.mem.eql(u8, word, c)) break true) else false;
        if (!is_state) continue;
        if (std.mem.indexOfScalar(u8, line, '=')) |eq| {
            const target = std.mem.trimEnd(u8, line[0..eq], " \t\r\n");
            var kept: std.ArrayList(u8) = .empty;
            defer kept.deinit(gpa);
            var old_lines = std.mem.splitScalar(u8, state.items, '\n');
            while (old_lines.next()) |old| {
                if (old.len == 0) continue;
                const same = if (std.mem.indexOfScalar(u8, old, '=')) |e| std.mem.eql(u8, std.mem.trimEnd(u8, old[0..e], " \t\r\n"), target) else false;
                if (same) continue;
                try kept.appendSlice(gpa, old);
                try kept.append(gpa, '\n');
            }
            state.clearRetainingCapacity();
            try state.appendSlice(gpa, kept.items);
        }
        try state.appendSlice(gpa, line);
        try state.append(gpa, '\n');
    }
}

/// Runs tasks `0..count` on `min(workers, count)` sessions of `deck` (at
/// least one, none for no task), each its own ngspice process on its own
/// thread; session `w` logs to the deck's path with extension `<w>.log`.
/// Tasks go in order to whichever session is free; `task` writes its result
/// into the caller's table at its own index, and must leave the session's
/// settings as it found them. The first failure stops every session before
/// its next task (running ones finish), and is what returns, its message
/// in `arena`.
pub fn runPool(env: Env, sim: Simulator, deck: []const u8, corner: []const u8, workers: u32, count: u32, ctx: anytype, comptime task: fn (@TypeOf(ctx), *Session, Allocator, u32, *Diagnostic) Error!void, arena: Allocator, diag: *Diagnostic) Error!void {
    if (count == 0) return;
    const Ctx = @TypeOf(ctx);
    const Shared = struct {
        env: Env,
        sim: Simulator,
        deck: []const u8,
        corner: []const u8,
        count: u32,
        ctx: Ctx,
        next: std.atomic.Value(u32) = .init(0),
        mutex: std.Io.Mutex = .init,
        failure: ?Error = null,
        message: []u8 = &.{},

        fn work(sh: *@This(), w: usize) void {
            var scratch: std.heap.ArenaAllocator = .init(sh.env.gpa);
            defer scratch.deinit();
            var local: Diagnostic = .{};
            sh.workCaught(w, &scratch, &local) catch |err| {
                sh.mutex.lockUncancelable(sh.env.io);
                defer sh.mutex.unlock(sh.env.io);
                if (sh.failure != null) return;
                sh.failure = err;
                sh.message = sh.env.gpa.dupe(u8, local.message) catch &.{};
            };
        }

        fn workCaught(sh: *@This(), w: usize, scratch: *std.heap.ArenaAllocator, local: *Diagnostic) Error!void {
            const stem = if (std.mem.endsWith(u8, sh.deck, ".cir")) sh.deck[0 .. sh.deck.len - 4] else sh.deck;
            const log = try scratch.allocator().dupe(u8, try scratch.allocator().print("{s}.{d}.log", .{ stem, w }));
            var session = try Session.start(sh.env, sh.sim, sh.deck, sh.corner, log, scratch.allocator(), local);
            defer session.deinit();
            while (!sh.failed()) {
                const i = sh.next.fetchAdd(1, .monotonic);
                if (i >= sh.count) return;
                _ = scratch.reset(.retain_capacity);
                try task(sh.ctx, &session, scratch.allocator(), i, local);
            }
        }

        fn failed(sh: *@This()) bool {
            sh.mutex.lockUncancelable(sh.env.io);
            defer sh.mutex.unlock(sh.env.io);
            return sh.failure != null;
        }
    };
    var shared: Shared = .{ .env = env, .sim = sim, .deck = deck, .corner = corner, .count = count, .ctx = ctx };
    const want = @max(@min(workers, count, max_workers), 1);
    var threads: [max_workers]std.Thread = undefined;
    var spawned: usize = 0;
    for (threads[0 .. want - 1]) |*th| {
        th.* = std.Thread.spawn(.{}, Shared.work, .{ &shared, spawned + 1 }) catch break;
        spawned += 1;
    }
    shared.work(0);
    for (threads[0..spawned]) |th| th.join();
    defer env.gpa.free(shared.message);
    if (shared.failure) |err| {
        diag.message = try arena.dupe(u8, shared.message);
        return err;
    }
}

// ---- private ----

fn ioError(scratch: Allocator, diag: *Diagnostic, comptime fmt: []const u8, args: anytype) Error {
    diag.message = try scratch.print("io: " ++ fmt, args);
    return error.Io;
}

test "a session replays what earlier runs set and nothing else" {
    // Oracle: construct-from-answer. A batch run keeps nothing, so a session
    // replays the state its earlier runs left: the sources and loads they
    // `alter`ed, the `option`s they set, the seed and the circuit redrawn
    // from it, in order. Analyses, measurements, echoes and vector commands
    // are not state. A setting written again replaces its earlier line.
    const gpa = std.testing.allocator;
    var state: std.ArrayList(u8) = .empty;
    defer state.deinit(gpa);
    try remember(gpa, &state, "alter @vp0[pwl] = [ 0 0 1e-9 1.8 ]\nalter cp1 = 1e-15\ntran 1e-12 2e-9\nmeas tran d WHEN v(p1)=0.9\necho \"RES d $&d\"\ndestroy all\n");
    try remember(gpa, &state, "setseed 3\nreset\noption reltol=1e-3\nalter cp1 = 2e-15\nop\nlet p = 1\n");
    try remember(gpa, &state, "option reltol=1e-6\n");
    try std.testing.expectEqualStrings("alter @vp0[pwl] = [ 0 0 1e-9 1.8 ]\nsetseed 3\nreset\nalter cp1 = 2e-15\noption reltol=1e-6\n", state.items);
}

test "a missing simulator is an error naming it, never a skip" {
    // Oracle: spice.rs `SimError::Spawn`'s doc: a binary that cannot be
    // started is an error naming it; construct-from-answer with a name no
    // PATH holds.
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.writeFile(std.testing.io, .{ .sub_path = "d.cir", .data = "* d\n.end\n" });
    var diag: Diagnostic = .{};
    const env: Env = .{ .gpa = std.testing.allocator, .io = std.testing.io, .dir = tmp.dir };
    try std.testing.expectError(error.Spawn, Session.start(env, .{ .binary = "gpurify-no-such-ngspice" }, "d.cir", "c", "d.0.log", arena.allocator(), &diag));
    try std.testing.expect(std.mem.indexOf(u8, diag.message, "could not start gpurify-no-such-ngspice") != null);
}
