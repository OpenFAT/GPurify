//! The asap7 deck against OpenROAD-flow-scripts' KLayout asap7 deck
//! (tests/fixtures/asap7/asap7.lydrc), rule by rule, on the fixture cells,
//! held to the ledger tests/xcheck/asap7.tsv. Built only with
//! `-Dcomparison-tests=true`, inside `nix develop .#comparison`; it fails,
//! never skips, when `klayout` is not on `PATH`.
//!
//! Contents: tests only.

const std = @import("std");
const testing = std.testing;
const Allocator = std.mem.Allocator;
const paths = @import("paths");
const gpurify = @import("gpurify");
const gpa = testing.allocator;
const io = testing.io;

const cells = [_][]const u8{
    "INVx1_ASAP7_75t_R", "INVx1_ASAP7_75t_L",   "INVx1_ASAP7_75t_SL",  "INVx1_ASAP7_75t_SRAM",
    "INVx2_ASAP7_75t_R", "NAND2x1_ASAP7_75t_R", "AOI21x1_ASAP7_75t_R", "TIEHIx1_ASAP7_75t_R",
    "BUFx2_ASAP7_75t_R",
};

/// One ledger row: rule ids on each side, space separated, and its status.
const Row = struct { ours: []const u8, theirs: []const u8, status: []const u8 };

/// One side's findings on one cell: every id it has, and the count each found.
const Found = std.StringHashMapUnmanaged(u32);

// ---- private ----

fn ledger(a: Allocator) ![]const Row {
    const path = try std.fmt.allocPrint(a, "{s}/tests/xcheck/asap7.tsv", .{paths.root});
    const text = try std.Io.Dir.cwd().readFileAlloc(io, path, a, .unlimited);
    var rows: std.ArrayList(Row) = .empty;
    var lines = std.mem.splitScalar(u8, text, '\n');
    var header = true;
    while (lines.next()) |line| {
        if (line.len == 0 or line[0] == '#') continue;
        if (header) {
            header = false;
            continue;
        }
        var f = std.mem.splitScalar(u8, line, '\t');
        try rows.append(a, .{ .ours = f.next().?, .theirs = f.next().?, .status = f.next().? });
    }
    return rows.items;
}

/// A KLayout category as an id: its description cut off at " : ", and a
/// name the deck wrote twice (`"X" "X : ..."`) once.
fn categoryId(raw: []const u8) []const u8 {
    var n = std.mem.trim(u8, raw, " '");
    if (std.mem.indexOf(u8, n, " : ")) |at| n = std.mem.trim(u8, n[0..at], " ");
    const half = n.len / 2;
    if (n.len % 2 == 0 and std.mem.eql(u8, n[0..half], n[half..])) n = n[0..half];
    return n;
}

/// KLayout's report on `cell`: every category it lists, and the items each holds.
fn theirs(a: Allocator, cell: []const u8) !Found {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const fixtures = try std.fmt.allocPrint(a, "{s}/tests/fixtures/asap7", .{paths.root});
    const deck = try std.fmt.allocPrint(a, "{s}/asap7.lydrc", .{fixtures});
    const layout = try std.fmt.allocPrint(a, "in_gds={s}/{s}.gds", .{ fixtures, cell });
    // KLayout resolves a relative report path against the layout's directory.
    const report = try std.fmt.allocPrint(a, "report_file={s}/.zig-cache/tmp/{s}/report.lyrdb", .{ paths.root, tmp.sub_path });
    const ran = try std.process.run(a, io, .{ .argv = &.{ "klayout", "-b", "-r", deck, "-rd", layout, "-rd", report }, .cwd = .{ .dir = tmp.dir } });
    if (ran.term != .exited or ran.term.exited != 0) {
        std.debug.print("klayout on {s}:\n{s}\n", .{ cell, ran.stderr });
        return error.TestKLayoutFailed;
    }
    const text = try tmp.dir.readFileAlloc(io, "report.lyrdb", a, .unlimited);
    var out: Found = .empty;
    const listed = text[0 .. std.mem.indexOf(u8, text, "<cells>") orelse text.len];
    var names = std.mem.splitSequence(u8, listed, "<name>");
    _ = names.next();
    while (names.next()) |chunk| {
        // The cell list and an unnamed category name nothing to compare.
        const id = categoryId(chunk[0..std.mem.indexOf(u8, chunk, "</name>").?]);
        if (id.len != 0) try out.put(a, id, 0);
    }
    const items = text[std.mem.indexOf(u8, text, "<items>") orelse text.len ..];
    var tags = std.mem.splitSequence(u8, items, "<category>");
    _ = tags.next();
    while (tags.next()) |chunk| {
        const id = categoryId(chunk[0..std.mem.indexOf(u8, chunk, "</category>").?]);
        const slot = out.getPtr(id) orelse return error.TestUnlistedCategory;
        slot.* += 1;
    }
    return out;
}

/// GPurify's DRC and ERC on `cell`: every rule it ran, and what each found.
fn ours(a: Allocator, dir: std.Io.Dir, cell: []const u8) !Found {
    var diag: gpurify.RunDiagnostic = .{};
    const layout = try std.fmt.allocPrint(a, "{s}.gds", .{cell});
    const r = try gpurify.run(gpa, a, io, dir, .{ .layout = layout, .deck = "asap7" }, .{ .checks = .{ .drc = true, .erc = true } }, &gpurify.pdks.decks, &diag);
    var out: Found = .empty;
    for (r.outputs.runs.items) |rr| {
        const slot = try out.getOrPutValue(a, r.loaded.strings.resolve(rr.rule), 0);
        slot.value_ptr.* += rr.violations;
    }
    return out;
}

/// Whether any of `ids` found something; every id must be in `found`.
fn flagged(found: *const Found, ids: []const u8, side: []const u8) !bool {
    if (std.mem.eql(u8, ids, "-")) return false;
    var any = false;
    var it = std.mem.tokenizeScalar(u8, ids, ' ');
    while (it.next()) |id| {
        const n = found.get(id) orelse {
            std.debug.print("ledger names {s} id {s}, which that side does not have\n", .{ side, id });
            return error.TestUnknownId;
        };
        any = any or n > 0;
    }
    return any;
}

fn ledgered(rows: []const Row, side: enum { ours, theirs }, id: []const u8) bool {
    for (rows) |row| {
        var it = std.mem.tokenizeScalar(u8, if (side == .ours) row.ours else row.theirs, ' ');
        while (it.next()) |x| if (std.mem.eql(u8, x, id)) return true;
    }
    return false;
}

test "asap7 against KLayout's asap7 deck: every ledger row holds on every fixture cell" {
    // Oracle: differential against KLayout running OpenROAD-flow-scripts'
    // asap7.lydrc on the same cells. A row marked `agrees` gives the same
    // verdict (flagged or clean) on every cell; `differs` another verdict
    // on at least one, which its note explains; every id either side has,
    // and every one that fires, is in the ledger.
    var arena: std.heap.ArenaAllocator = .init(gpa);
    defer arena.deinit();
    const a = arena.allocator();
    const rows = try ledger(a);
    const path = try std.fmt.allocPrint(a, "{s}/tests/fixtures/asap7", .{paths.root});
    var dir = try std.Io.Dir.cwd().openDir(io, path, .{});
    defer dir.close(io);
    const differed = try a.alloc(bool, rows.len);
    @memset(differed, false);
    var broken: usize = 0;
    for (cells) |cell| {
        const o = try ours(a, dir, cell);
        const t = try theirs(a, cell);
        var oi = o.iterator();
        while (oi.next()) |e| if (!ledgered(rows, .ours, e.key_ptr.*)) {
            std.debug.print("{s}: our rule {s} has no ledger row\n", .{ cell, e.key_ptr.* });
            broken += 1;
        };
        var ti = t.iterator();
        while (ti.next()) |e| if (!ledgered(rows, .theirs, e.key_ptr.*)) {
            std.debug.print("{s}: KLayout's {s} has no ledger row\n", .{ cell, e.key_ptr.* });
            broken += 1;
        };
        for (rows, differed) |row, *d| {
            const ours_flag = try flagged(&o, row.ours, "our");
            const theirs_flag = try flagged(&t, row.theirs, "KLayout's");
            if (ours_flag != theirs_flag) d.* = true;
            if (std.mem.eql(u8, row.status, "agrees") and ours_flag != theirs_flag) {
                std.debug.print("{s}: {s} / {s} marked agrees: ours {}, KLayout {}\n", .{ cell, row.ours, row.theirs, ours_flag, theirs_flag });
                broken += 1;
            }
        }
    }
    for (rows, differed) |row, d| if (std.mem.eql(u8, row.status, "differs") and !d) {
        std.debug.print("{s} / {s} marked differs, but agreed on every cell\n", .{ row.ours, row.theirs });
        broken += 1;
    };
    try testing.expectEqual(@as(usize, 0), broken);
}
