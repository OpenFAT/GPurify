//! The shipped decks as the engine carries them, and the tables the run
//! reads from them. Ported from the root tests/pdk_decks.rs, the halves
//! tests/check/drc/pdk_decks.zig deferred to the engine (the `pdks`
//! constants, and the pex, connectivity and device tables).

const std = @import("std");
const testing = std.testing;
const Allocator = std.mem.Allocator;
const paths = @import("paths");
const geom = @import("geom");
const LayerId = geom.LayerId;
const ingest = @import("ingest");
const Deck = ingest.deck.Deck;
const check = @import("check");
const gpurify = @import("gpurify");
const gpa = testing.allocator;
const io = testing.io;

const DeckFile = struct { name: []const u8, text: []const u8 };

/// The layers asap7.deck's header names as conducting with no public
/// resistance (its known blocker), sorted: the one exception to a sheet
/// resistance on every current-carrying layer.
const asap7_unsourced = [_][]const u8{ "GATE_C", "GATE_FET", "LIG", "LIG_LISD", "LISD", "NTAP", "PTAP", "SD", "SDT", "V0" };

const Parsed = struct {
    deck: Deck,
    strings: geom.StrTable,

    fn name(p: *const Parsed, layer: LayerId) []const u8 {
        return p.strings.resolve(p.deck.layers.name(layer));
    }
};

// ---- private ----

/// Every `*.deck` under pdks/, sorted by stem, discovered by reading the
/// directory (an empty pdks/ would pass every loop vacuously).
fn deckFiles(a: Allocator) ![]const DeckFile {
    const root = try std.fmt.allocPrint(a, "{s}/pdks", .{paths.root});
    var dir = try std.Io.Dir.cwd().openDir(io, root, .{ .iterate = true });
    defer dir.close(io);
    var out: std.ArrayList(DeckFile) = .empty;
    var it = dir.iterate();
    while (try it.next(io)) |e| {
        if (!std.mem.endsWith(u8, e.name, ".deck")) continue;
        try out.append(a, .{ .name = try a.dupe(u8, e.name[0 .. e.name.len - ".deck".len]), .text = try dir.readFileAlloc(io, e.name, a, .unlimited) });
    }
    std.mem.sort(DeckFile, out.items, {}, lessFile);
    try testing.expect(out.items.len != 0);
    return out.items;
}

fn lessFile(_: void, x: DeckFile, y: DeckFile) bool {
    return std.mem.order(u8, x.name, y.name) == .lt;
}

fn lessName(_: void, x: []const u8, y: []const u8) bool {
    return std.mem.order(u8, x, y) == .lt;
}

fn parse(a: Allocator, text: []const u8) !Parsed {
    var p: Parsed = .{ .deck = undefined, .strings = .empty };
    var diag: ingest.deck.Diag = .{};
    p.deck = try ingest.deck.parseDeck(a, a, text, try .init(1000), &p.strings, &diag);
    return p;
}

fn isIn(layers: []const LayerId, layer: LayerId) bool {
    return std.mem.findScalar(LayerId, layers, layer) != null;
}

test "every deck file is a shipped constant byte for byte" {
    // Oracle: construct-from-answer. `pdks.all` names every deck in pdks/,
    // sorted, and nothing else, each constant the file's bytes.
    var arena: std.heap.ArenaAllocator = .init(gpa);
    defer arena.deinit();
    const files = try deckFiles(arena.allocator());
    try testing.expectEqual(files.len, gpurify.pdks.all.len);
    for (files, gpurify.pdks.all) |f, shipped| {
        try testing.expectEqualStrings(f.name, shipped.name);
        try testing.expectEqualStrings(f.text, shipped.text);
    }
}

test "every shipped constant compiles" {
    // Oracle: construct-from-answer. Each shipped constant compiles as a
    // consumer compiling it would and configures rules; each named deck
    // builds its own constant (another deck has another rule count), and
    // the one alias past them, `generic_finfet`, builds asap7's.
    var arena: std.heap.ArenaAllocator = .init(gpa);
    defer arena.deinit();
    const a = arena.allocator();
    const alias = gpurify.pdks.decks[gpurify.pdks.all.len];
    try testing.expectEqualStrings("generic_finfet", alias.name);
    try testing.expectEqual(gpurify.pdks.all.len + 1, gpurify.pdks.decks.len);
    try testing.expectEqual(@intFromPtr(gpurify.pdks.decks[0].build), @intFromPtr(alias.build));
    for (gpurify.pdks.all, gpurify.pdks.decks[0..gpurify.pdks.all.len]) |shipped, named| {
        try testing.expectEqualStrings(shipped.name, named.name);
        var strings: geom.StrTable = .empty;
        var diag: check.deck.compile.Diag = .{};
        const deck = try check.deck.compile.compile(a, a, shipped.text, try .init(1000), &strings, &diag);
        try testing.expect(deck.ruleCount() > 0);
        var again_strings: geom.StrTable = .empty;
        const again = try named.build(a, a, try .init(1000), &again_strings, &diag);
        try testing.expectEqual(deck.ruleCount(), again.ruleCount());
    }
}

test "every current-carrying layer has a sheet resistance" {
    // Oracle: construct-from-answer, against the power grid's stated refusal:
    // a conductor, or a cut between two non-global layers, with no positive
    // finite sheet resistance refuses the whole IR-drop family; and a deck
    // with no conductor extracts every polygon as its own net. The one
    // exception is asap7's middle of line, which no public source gives a
    // resistance: those layers, and no others, carry current unsourced.
    var arena: std.heap.ArenaAllocator = .init(gpa);
    defer arena.deinit();
    const a = arena.allocator();
    for (gpurify.pdks.all) |shipped| {
        const d = try parse(a, shipped.text);
        const conn = d.deck.connectivity;
        var carrying: std.ArrayList(LayerId) = .empty;
        try carrying.appendSlice(a, conn.conductors);
        for (conn.via_cut, conn.via_connects) |cut, pair| if (!isIn(conn.global, pair[0]) and !isIn(conn.global, pair[1])) try carrying.append(a, cut);
        var unsourced: std.ArrayList([]const u8) = .empty;
        for (carrying.items) |layer| {
            const ohms = if (@backingInt(layer) < d.deck.stack.sheet_res_ohm_sq.len) d.deck.stack.sheet_res_ohm_sq[@backingInt(layer)] else std.math.nan(f64);
            if (ohms > 0 and std.math.isFinite(ohms)) continue;
            for (unsourced.items) |n| (if (std.mem.eql(u8, n, d.name(layer))) break) else try unsourced.append(a, d.name(layer));
        }
        std.mem.sort([]const u8, unsourced.items, {}, lessName);
        const allowed: []const []const u8 = if (std.mem.eql(u8, shipped.name, "asap7")) &asap7_unsourced else &.{};
        try testing.expectEqualDeep(allowed, @as([]const []const u8, unsourced.items));
        try testing.expect(conn.conductors.len != 0);
    }
}

test "a pex stack that exists has one row per declared layer" {
    // Oracle: law. The stack is indexed by LayerId, so each column is as
    // long as the layer table, or the stack is empty and so are conductors.
    var arena: std.heap.ArenaAllocator = .init(gpa);
    defer arena.deinit();
    for (gpurify.pdks.all) |shipped| {
        const d = try parse(arena.allocator(), shipped.text);
        const s = d.deck.stack;
        if (s.sheet_res_ohm_sq.len == 0) {
            try testing.expectEqual(0, d.deck.connectivity.conductors.len);
            continue;
        }
        for ([_][]const f64{ s.thickness_nm, s.height_nm, s.sheet_res_ohm_sq, s.area_cap_af_um2, s.fringe_cap_af_um, s.dielectric_k }) |column| try testing.expectEqual(d.deck.layers.len(), column.len);
    }
}

test "every via joins two declared conductors" {
    // Oracle: construct-from-answer. A via joining a layer that is no
    // conductor (nor global, which conducts as one net) stops the net there.
    var arena: std.heap.ArenaAllocator = .init(gpa);
    defer arena.deinit();
    for (gpurify.pdks.all) |shipped| {
        const d = try parse(arena.allocator(), shipped.text);
        const conn = d.deck.connectivity;
        for (conn.via_connects) |pair| for (pair) |joined| try testing.expect(isIn(conn.conductors, joined) or isIn(conn.global, joined));
    }
}

test "every deck pairs a text layer with a conductor" {
    // Oracle: construct-from-answer. A deck pairs at least one text layer
    // with a conductor, so a port label has something to bind to; the
    // pairing columns are parallel and each names a conductor.
    var arena: std.heap.ArenaAllocator = .init(gpa);
    defer arena.deinit();
    for (gpurify.pdks.all) |shipped| {
        const d = try parse(arena.allocator(), shipped.text);
        const conn = d.deck.connectivity;
        try testing.expect(conn.label_layer.len != 0);
        try testing.expectEqual(conn.label_layer.len, conn.label_names.len);
        for (conn.label_names) |named| try testing.expect(isIn(conn.conductors, named));
    }
}

test "every mos terminal names a conductor" {
    // Oracle: construct-from-answer, against device recognition's rule that
    // a marker whose positions are not all filled is no device: a MOS
    // terminal on a layer that is no conductor (nor global) can never fill.
    var arena: std.heap.ArenaAllocator = .init(gpa);
    defer arena.deinit();
    for (gpurify.pdks.all) |shipped| {
        const d = try parse(arena.allocator(), shipped.text);
        const devices = d.deck.devices;
        const conn = d.deck.connectivity;
        for (devices.kind, 0..) |kind, row| {
            if (kind != .mos) continue;
            for (devices.terminal[devices.terminal_start[row]..devices.terminal_start[row + 1]]) |t| try testing.expect(isIn(conn.conductors, t) or isIn(conn.global, t));
        }
    }
}
