//! The check catalog against the code. `docs/check-catalog.tsv` lists every
//! check kind a signoff verifier must handle, one row per kind, with the
//! sources that define it and what the code has for it. This keeps it, the
//! code and the docs from drifting apart: every kind the catalog names
//! exists in the code and every kind the code has is in the catalog; every
//! `missing` or `partial` check is in `docs/limitations.md`; the status
//! counts and the beyond-open-source block of `docs/check-sources.md` are
//! the catalog's; and the rule reference in src/check/root.zig (Rust's
//! crates/check/src/lib.rs) cites the catalog rows and names Zig items that
//! exist. A stale generated block is rewritten and the test fails, so the
//! change is reviewed like a golden file. Ported from tests/catalog.rs.

const std = @import("std");
const testing = std.testing;
const check = @import("check");
const paths = @import("paths");
const Allocator = std.mem.Allocator;

const statuses = [_][]const u8{ "implemented", "expressible", "partial", "missing", "verify", "out_of_scope" };

/// Feature tags in the `gpurify` column: a capability, not a rule kind.
const tags = [_][]const u8{ "deck:", "drc:", "erc:", "lvs:", "pex:", "ingest:", "lib:" };

/// The domains in the order the docs list them, with their headings.
const domains = [_][2][]const u8{
    .{ "drc", "Design rules (DRC)" },
    .{ "lvs", "Layout against schematic (LVS)" },
    .{ "erc", "Electrical rules (ERC)" },
    .{ "pex", "Parasitic extraction (PEX)" },
    .{ "flow", "Flow" },
};

const begin = "<!-- generated from docs/check-catalog.tsv by tests/catalog.rs; edit the catalog, not this block -->";
const end = "<!-- end of generated block -->";

/// Open tools the catalog cites, in `sources` and in a `TX:<tool>` oracle.
const open_tools = [_][]const u8{ "KL", "NG", "MAG", "OR", "drt", "YOSYS", "ngspice", "FasterCap", "FastHenry" };

/// Oracles that do not borrow another tool's answer.
const independent = [_][]const u8{ "CF", "SE", "FR", "SY", "NV", "BM", "MR" };

const Row = struct {
    id: []const u8,
    domain: []const u8,
    check: []const u8,
    gpurify: []const []const u8,
    status: []const u8,
    sources: []const u8,
    oracle: []const u8,
    notes: []const u8,
};

// ---- private ----

fn read(arena: Allocator, rel: []const u8) ![]const u8 {
    const path = try std.fmt.allocPrint(arena, "{s}/{s}", .{ paths.root, rel });
    return std.Io.Dir.cwd().readFileAlloc(testing.io, path, arena, .unlimited);
}

fn rewrite(arena: Allocator, rel: []const u8, data: []const u8) !void {
    const path = try std.fmt.allocPrint(arena, "{s}/{s}", .{ paths.root, rel });
    try std.Io.Dir.cwd().writeFile(testing.io, .{ .sub_path = path, .data = data });
}

fn eql(a: []const u8, b: []const u8) bool {
    return std.mem.eql(u8, a, b);
}

fn oneOf(name: []const u8, set: []const []const u8) bool {
    for (set) |s| if (eql(name, s)) return true;
    return false;
}

fn catalog(arena: Allocator) ![]const Row {
    const text = try read(arena, "docs/check-catalog.tsv");
    var lines = std.mem.splitScalar(u8, std.mem.trimEnd(u8, text, "\n"), '\n');
    try testing.expectEqualStrings("id\tdomain\tcategory\tcheck\tsources\tgpurify\tstatus\toracle\tnotes", lines.next().?);
    var rows: std.ArrayList(Row) = .empty;
    while (lines.next()) |line| {
        var cells: [9][]const u8 = undefined;
        var it = std.mem.splitScalar(u8, line, '\t');
        for (&cells) |*c| c.* = it.next() orelse return error.TestUnexpectedResult;
        try testing.expect(it.next() == null);
        var names: std.ArrayList([]const u8) = .empty;
        var parts = std.mem.splitScalar(u8, cells[5], ',');
        while (parts.next()) |part| {
            const name = std.mem.trim(u8, part, " ");
            if (name.len > 0 and !eql(name, "-")) try names.append(arena, name);
        }
        try rows.append(arena, .{ .id = cells[0], .domain = cells[1], .check = cells[3], .gpurify = names.items, .status = cells[6], .sources = cells[4], .oracle = cells[7], .notes = cells[8] });
    }
    return rows.items;
}

/// Every rule kind and LVS report id the code has.
fn codeKinds(arena: Allocator) ![]const []const u8 {
    var out: std.ArrayList([]const u8) = .empty;
    for (std.enums.values(check.drc.Kind)) |k| try out.append(arena, @tagName(k));
    for (check.erc.kinds.names) |n| try out.append(arena, n);
    for (check.lvs.rule_ids) |n| try out.append(arena, n);
    return out.items;
}

fn isTag(name: []const u8) bool {
    for (tags) |t| if (std.mem.startsWith(u8, name, t)) return true;
    return false;
}

fn cell(arena: Allocator, text: []const u8) ![]const u8 {
    if (text.len == 0) return "—";
    return std.mem.replaceOwned(u8, arena, text, "|", "\\|");
}

/// The limitations block as the catalog says it should read.
fn limitationsBlock(arena: Allocator, rows: []const Row) ![]const u8 {
    var out: std.ArrayList(u8) = .empty;
    try out.print(arena, "{s}\n", .{begin});
    for (domains) |d| {
        var any = false;
        for (rows) |r| {
            if (!eql(r.domain, d[0]) or !(eql(r.status, "missing") or eql(r.status, "partial"))) continue;
            if (!any) try out.print(arena, "\n### {s}\n\n| Id | Check | Status | What is missing |\n|---|---|---|---|\n", .{d[1]});
            any = true;
            try out.print(arena, "| {s} | {s} | {s} | {s} |\n", .{ r.id, try cell(arena, r.check), r.status, try cell(arena, r.notes) });
        }
    }
    try out.print(arena, "\n{s}", .{end});
    return out.items;
}

/// The oracle codes of an `oracle` cell: `TX:KL; MR` is `TX`, `MR`.
fn hasCode(oracle: []const u8, code: []const u8) bool {
    var it = std.mem.splitScalar(u8, oracle, ';');
    while (it.next()) |part| {
        const c = std.mem.trim(u8, part, " ");
        const name = c[0 .. std.mem.indexOfScalar(u8, c, ':') orelse c.len];
        if (eql(name, code)) return true;
    }
    return false;
}

/// A supported row no open tool defines and none was compared against.
fn beyondOpenSource(r: Row) bool {
    if (!(eql(r.status, "implemented") or eql(r.status, "partial") or eql(r.status, "expressible"))) return false;
    // Words: runs of ASCII letters and digits.
    var at: usize = 0;
    while (at < r.sources.len) {
        while (at < r.sources.len and !std.ascii.isAlphanumeric(r.sources[at])) at += 1;
        const start = at;
        while (at < r.sources.len and std.ascii.isAlphanumeric(r.sources[at])) at += 1;
        if (oneOf(r.sources[start..at], &open_tools)) return false;
    }
    return !hasCode(r.oracle, "TX");
}

fn beyondBlock(arena: Allocator, rows: []const Row) ![]const u8 {
    var out: std.ArrayList(u8) = .empty;
    try out.print(arena, "{s}\n\n| Id | Check | Status | Defined by (public) | Evidence |\n|---|---|---|---|---|\n", .{begin});
    for (rows) |r| if (beyondOpenSource(r)) {
        try out.print(arena, "| {s} | {s} | {s} | {s} | {s} |\n", .{ r.id, try cell(arena, r.check), r.status, try cell(arena, r.sources), try cell(arena, r.oracle) });
    };
    try out.print(arena, "\n{s}", .{end});
    return out.items;
}

/// `doc`'s generated block replaced by `want`; fails (after rewriting the
/// file) when they differ.
fn expectBlock(arena: Allocator, rel: []const u8, want: []const u8) !void {
    const doc = try read(arena, rel);
    const start = std.mem.indexOf(u8, doc, begin) orelse return error.TestUnexpectedResult;
    const stop = (std.mem.indexOf(u8, doc, end) orelse return error.TestUnexpectedResult) + end.len;
    if (eql(doc[start..stop], want)) return;
    try rewrite(arena, rel, try std.mem.concat(arena, u8, &.{ doc[0..start], want, doc[stop..] }));
    std.debug.print("{s} was stale against the catalog; it is rewritten: review and commit it\n", .{rel});
    return error.TestExpectedEqual;
}

/// Whether a rule-reference item (`drc.Rule.min_width`,
/// `erc.RuleSet.tables.antenna`, `lvs.Discrepancy.unpaired_net`,
/// `lvs.checkLayout`) names something in the check module.
fn zigItemExists(item: []const u8) bool {
    if (std.mem.startsWith(u8, item, "drc.Rule.")) return std.meta.stringToEnum(check.drc.Kind, item["drc.Rule.".len..]) != null;
    if (std.mem.startsWith(u8, item, "erc.RuleSet.tables.")) return check.erc.kinds.isKind(item["erc.RuleSet.tables.".len..]);
    if (std.mem.startsWith(u8, item, "lvs.Discrepancy.")) return std.meta.stringToEnum(std.meta.Tag(check.lvs.Discrepancy), item["lvs.Discrepancy.".len..]) != null;
    inline for (.{ "checkLayout", "checkParamRanges", "checkNetSeedConflicts", "checkDeviceCounts", "recordUnpairedInstances" }) |f| {
        if (eql(item, "lvs." ++ f)) return @hasDecl(check.lvs, f);
    }
    return false;
}

test "every row is well formed and resolved" {
    // Oracle: the catalog's schema as tests/catalog.rs and
    // docs/check-sources.md state it: unique ids, a listed domain and
    // status, no `verify` once committed, a covered row naming what covers
    // it, and a partial or out-of-scope row saying why.
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const rows = try catalog(arena.allocator());
    for (rows, 0..) |r, i| {
        for (rows[0..i]) |o| if (eql(o.id, r.id)) {
            std.debug.print("{s}: the id appears twice\n", .{r.id});
            return error.TestUnexpectedResult;
        };
        var known_domain = false;
        for (domains) |d| known_domain = known_domain or eql(d[0], r.domain);
        try testing.expect(known_domain);
        try testing.expect(oneOf(r.status, &statuses));
        try testing.expect(!eql(r.status, "verify"));
        if (eql(r.status, "implemented") or eql(r.status, "partial") or eql(r.status, "expressible")) try testing.expect(r.gpurify.len > 0);
        if (eql(r.status, "partial") or eql(r.status, "out_of_scope")) try testing.expect(r.notes.len > 0);
    }
}

test "every kind the catalog names exists in the code" {
    // Oracle: the code's own kind lists (drc.Kind, erc.kinds.names,
    // lvs.rule_ids): every name a row gives, feature tags aside, is in them.
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const known = try codeKinds(arena.allocator());
    for (try catalog(arena.allocator())) |r| for (r.gpurify) |name| {
        if (isTag(name) or oneOf(name, known)) continue;
        std.debug.print("{s}: names {s}, which is no rule kind or LVS report id in the code\n", .{ r.id, name });
        return error.TestUnexpectedResult;
    };
}

test "every kind the code has is in the catalog" {
    // Oracle: the code's own kind lists: every kind in them is named by a
    // catalog row.
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const rows = try catalog(arena.allocator());
    for (try codeKinds(arena.allocator())) |kind| {
        const named = for (rows) |r| {
            if (oneOf(kind, r.gpurify)) break true;
        } else false;
        if (!named) {
            std.debug.print("{s} exists in the code but no catalog row names it: add one\n", .{kind});
            return error.TestUnexpectedResult;
        }
    }
}

test "check sources states the catalog's status counts" {
    // Oracle: the catalog's rows, counted per domain and status, against the
    // table and row total docs/check-sources.md states.
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const rel = "docs/check-sources.md";
    const doc = try read(a, rel);
    const rows = try catalog(a);
    var lines: std.ArrayList([]const u8) = .empty;
    var it = std.mem.splitScalar(u8, std.mem.trimEnd(u8, doc, "\n"), '\n');
    while (it.next()) |line| try lines.append(a, line);
    var stale = false;
    for (lines.items) |*line| {
        if (!(std.mem.startsWith(u8, line.*, "**Snapshot") and std.mem.endsWith(u8, line.*, " rows):"))) continue;
        const open = std.mem.lastIndexOfScalar(u8, line.*, '(') orelse continue;
        const want = try std.fmt.allocPrint(a, "{s}({d} rows):", .{ line.*[0..open], rows.len });
        if (!eql(line.*, want)) stale = true;
        line.* = want;
    }
    for (domains) |d| {
        const label = if (eql(d[0], "flow")) "Flow" else try std.ascii.allocUpperString(a, d[0]);
        var want: std.ArrayList(u8) = .empty;
        try want.print(a, "| {s} |", .{label});
        for (statuses) |status| {
            var n: usize = 0;
            for (rows) |r| n += @intFromBool(eql(r.domain, d[0]) and eql(r.status, status));
            try want.print(a, " {d} |", .{n});
        }
        const prefix = try std.fmt.allocPrint(a, "| {s} | ", .{label});
        const line = for (lines.items) |*line| {
            if (std.mem.startsWith(u8, line.*, prefix)) break line;
        } else return error.TestUnexpectedResult;
        if (!eql(line.*, want.items)) stale = true;
        line.* = want.items;
    }
    if (!stale) return;
    const joined = try std.mem.join(a, "\n", lines.items);
    try rewrite(a, rel, try std.mem.concat(a, u8, &.{ joined, if (std.mem.endsWith(u8, doc, "\n")) "\n" else "" }));
    std.debug.print("{s}'s status counts were stale against the catalog; they are rewritten: review and commit them\n", .{rel});
    return error.TestExpectedEqual;
}

test "limitations lists every missing and partial check" {
    // Oracle: golden: the block built from the catalog's missing and partial
    // rows against the reviewed block in docs/limitations.md.
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    try expectBlock(a, "docs/limitations.md", try limitationsBlock(a, try catalog(a)));
}

test "the rule reference cites the catalog and names Zig items that exist" {
    // Oracle: the catalog: for each kind the code has, the rows naming it are
    // exactly the ids its rule-reference row in src/check/root.zig cites (Rust
    // read crates/check/src/lib.rs); and the code: each row's checking item
    // is a `drc.Rule` field, an `erc.RuleSet.tables` field, an
    // `lvs.Discrepancy` tag or an `lvs` function, as the Rust paths map.
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const doc = try read(a, "src/check/root.zig");
    const rows = try catalog(a);
    for (try codeKinds(a)) |kind| {
        const needle = try std.fmt.allocPrint(a, "| `{s}` |", .{kind});
        var lines = std.mem.splitScalar(u8, doc, '\n');
        const line = while (lines.next()) |line| {
            if (std.mem.indexOf(u8, line, needle) != null) break line;
        } else {
            std.debug.print("src/check/root.zig: the rule reference has no row for {s}\n", .{kind});
            return error.TestUnexpectedResult;
        };
        var cells: std.ArrayList([]const u8) = .empty;
        var it = std.mem.splitScalar(u8, std.mem.trimEnd(u8, std.mem.trimEnd(u8, line, " "), "|"), '|');
        while (it.next()) |c| try cells.append(a, std.mem.trim(u8, c, " "));
        var named: std.ArrayList([]const u8) = .empty;
        for (rows) |r| if (oneOf(kind, r.gpurify)) try named.append(a, r.id);
        const want = if (named.items.len == 0) "—" else try std.mem.join(a, ", ", named.items);
        try testing.expectEqualStrings(want, cells.items[cells.items.len - 1]);
        // The checking item: the cell after the kind's (an escaped `\|` in
        // the deck cell splits it, so the kind's cell is found, not counted).
        const at = for (cells.items, 0..) |c, i| {
            if (eql(c, needle[2 .. needle.len - 2])) break i;
        } else return error.TestUnexpectedResult;
        const by = cells.items[at + 1];
        try testing.expect(by.len > 2 and by[0] == '`' and by[by.len - 1] == '`');
        try testing.expect(zigItemExists(by[1 .. by.len - 1]));
    }
}

test "checks beyond open source are listed with two independent oracles" {
    // Oracle: the catalog's oracle codes: a supported row no open tool
    // defines has two independent codes (Rust's EVIDENCE_GAPS is empty);
    // and golden, the generated block against docs/check-sources.md.
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const rows = try catalog(a);
    for (rows) |r| if (beyondOpenSource(r)) {
        var n: usize = 0;
        for (independent) |code| n += @intFromBool(hasCode(r.oracle, code));
        if (n < 2) {
            std.debug.print("{s}: beyond open source on fewer than two independent oracles\n", .{r.id});
            return error.TestUnexpectedResult;
        }
    };
    try expectBlock(a, "docs/check-sources.md", try beyondBlock(a, rows));
}
