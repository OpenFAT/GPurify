//! The check catalog against the code and the user docs.
//! `tests/check-catalog.tsv` lists every check kind a signoff verifier must
//! handle, one row per kind, with the sources that define it and what the
//! code has for it. This keeps it, the code and the docs from drifting
//! apart: every kind the catalog names exists in the code and every kind the
//! code has is in the catalog; every row has exactly one entry in the user
//! docs (docs/src/reference), whose **Status and limits.** opens with the
//! row's status; and the rule reference in src/check/root.zig (Rust's
//! crates/check/src/lib.rs) cites the catalog rows and names Zig items that
//! exist. Ported from tests/catalog.rs; its generated blocks in
//! limitations.md and check-sources.md went with those pages, into the
//! entries this checks.

const std = @import("std");
const testing = std.testing;
const check = @import("check");
const paths = @import("paths");
const Allocator = std.mem.Allocator;

const statuses = [_][]const u8{ "implemented", "expressible", "partial", "missing", "verify", "out_of_scope" };

/// Feature tags in the `gpurify` column: a capability, not a rule kind.
const tags = [_][]const u8{ "deck:", "drc:", "erc:", "lvs:", "pex:", "ingest:", "lib:" };

/// The domains a row may name.
const domains = [_][]const u8{ "drc", "lvs", "erc", "pex", "flow" };

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

/// One check entry of the user docs, `### <ID>: <name>` (docs/STYLE.md,
/// section 3): its page under docs/src/reference, and the first word after
/// its **Status and limits.** lead-in, null when it has none.
const Entry = struct { id: []const u8, page: []const u8, status: ?[]const u8 };

// ---- private ----

fn read(arena: Allocator, rel: []const u8) ![]const u8 {
    const path = try std.fmt.allocPrint(arena, "{s}/{s}", .{ paths.root, rel });
    return std.Io.Dir.cwd().readFileAlloc(testing.io, path, arena, .unlimited);
}

/// Whether `id` reads as a catalog id: capitals, a hyphen, then letters
/// and digits (`DRC-028`, `ERC-D1a`).
fn isCatalogId(id: []const u8) bool {
    const dash = std.mem.indexOfScalar(u8, id, '-') orelse return false;
    if (dash == 0 or dash + 1 == id.len) return false;
    for (id[0..dash]) |c| if (!std.ascii.isUpper(c)) return false;
    for (id[dash + 1 ..]) |c| if (!std.ascii.isAlphanumeric(c)) return false;
    return true;
}

/// Every check entry under docs/src/reference. An entry runs to the next
/// heading outside a code block (a deck snippet's `#` comment is no heading).
fn docEntries(arena: Allocator) ![]const Entry {
    const root = try std.fmt.allocPrint(arena, "{s}/docs/src/reference", .{paths.root});
    var dir = try std.Io.Dir.cwd().openDir(testing.io, root, .{ .iterate = true });
    defer dir.close(testing.io);
    var walker = try dir.walk(arena);
    defer walker.deinit();
    var out: std.ArrayList(Entry) = .empty;
    while (try walker.next(testing.io)) |file| {
        if (file.kind != .file or !std.mem.endsWith(u8, file.path, ".md")) continue;
        const page = try arena.dupe(u8, file.path);
        const text = try file.dir.readFileAlloc(testing.io, file.basename, arena, .unlimited);
        var open: ?usize = null;
        var fenced = false;
        var lines = std.mem.splitScalar(u8, text, '\n');
        while (lines.next()) |line| {
            if (std.mem.startsWith(u8, line, "```")) {
                fenced = !fenced;
                continue;
            }
            if (fenced) continue;
            if (std.mem.startsWith(u8, line, "#")) {
                open = null;
                if (!std.mem.startsWith(u8, line, "### ")) continue;
                const colon = std.mem.indexOf(u8, line, ": ") orelse continue;
                const id = line[4..colon];
                if (!isCatalogId(id)) continue;
                try out.append(arena, .{ .id = id, .page = page, .status = null });
                open = out.items.len - 1;
                continue;
            }
            const at = open orelse continue;
            const lead = "**Status and limits.**";
            if (out.items[at].status != null or !std.mem.startsWith(u8, line, lead)) continue;
            const rest = std.mem.trimStart(u8, line[lead.len..], " ");
            var n: usize = 0;
            while (n < rest.len and std.ascii.isAlphabetic(rest[n])) n += 1;
            out.items[at].status = rest[0..n];
        }
    }
    return out.items;
}

/// The word an entry's status opens with: `partial` reads `Partial`.
fn statusWord(arena: Allocator, status: []const u8) ![]const u8 {
    const word = try std.mem.replaceOwned(u8, arena, status, "_", " ");
    if (word.len > 0) word[0] = std.ascii.toUpper(word[0]);
    return word;
}

fn eql(a: []const u8, b: []const u8) bool {
    return std.mem.eql(u8, a, b);
}

fn oneOf(name: []const u8, set: []const []const u8) bool {
    for (set) |s| if (eql(name, s)) return true;
    return false;
}

fn catalog(arena: Allocator) ![]const Row {
    const text = try read(arena, "tests/check-catalog.tsv");
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
    // Oracle: the catalog's schema as tests/catalog.rs states it: unique ids, a listed domain and
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
        for (domains) |d| known_domain = known_domain or eql(d, r.domain);
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
    // defines has two independent codes (Rust's EVIDENCE_GAPS is empty).
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
}

test "the user docs give every catalog row one entry that opens with its status" {
    // Oracle: the catalog: each row's id heads exactly one `### <ID>: <name>`
    // entry under docs/src/reference (docs/STYLE.md, section 3), no entry
    // names an id the catalog lacks, and each entry's **Status and limits.**
    // opens with its row's status word.
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const rows = try catalog(a);
    const entries = try docEntries(a);
    var bad: std.ArrayList([]const u8) = .empty;
    for (rows) |r| {
        const want = try statusWord(a, r.status);
        var n: usize = 0;
        for (entries) |e| if (eql(e.id, r.id)) {
            n += 1;
            const got = e.status orelse "no status";
            if (!eql(got, want)) try bad.append(a, try std.fmt.allocPrint(a, "{s} ({s}): its status reads {s}, the catalog says {s}", .{ r.id, e.page, got, want }));
        };
        if (n != 1) try bad.append(a, try std.fmt.allocPrint(a, "{s}: {d} entries in the docs, want 1", .{ r.id, n }));
    }
    for (entries) |e| {
        for (rows) |r| {
            if (eql(r.id, e.id)) break;
        } else try bad.append(a, try std.fmt.allocPrint(a, "{s} ({s}): no catalog row has this id", .{ e.id, e.page }));
    }
    if (bad.items.len > 0) {
        std.debug.print("{d} entries disagree with the catalog:\n{s}\n", .{ bad.items.len, try std.mem.join(a, "\n", bad.items) });
        return error.TestExpectedEqual;
    }
}
