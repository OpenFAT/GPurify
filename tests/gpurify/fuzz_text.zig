//! The text fuzz targets' oracles: raw bytes → the deck compiler and the
//! DRC/ERC run over it, the SPICE and Spectre readers and the flattening
//! LVS does, the intent and Liberty-spec readers, the SPEF and DSPF
//! readers → each target's law, an error naming the input when broken.
//! Ported from fuzz/oracles.rs (`deck`, `netlist_spice`, `netlist_spectre`,
//! `intent`, `liberty_spec`, `spef`). Unlike Rust's, the readers here take
//! bytes, so only the deck target, whose oracle speaks of characters, skips
//! input that is not UTF-8.
//!
//! Contents:
//! - `pub fn deck(gpa: Allocator, data: []const u8) !void`
//! - `pub fn netlistSpice(gpa: Allocator, data: []const u8) !void`
//! - `pub fn netlistSpectre(gpa: Allocator, data: []const u8) !void`
//! - `pub fn intent(gpa: Allocator, data: []const u8) !void`
//! - `pub fn libertySpec(gpa: Allocator, data: []const u8) !void`
//! - `pub fn spef(gpa: Allocator, data: []const u8) !void`

const std = @import("std");
const Allocator = std.mem.Allocator;
const ascii = std.ascii;
const geom = @import("geom");
const StrTable = geom.StrTable;
const ingest = @import("ingest");
const Netlist = ingest.netlist.Netlist;
const check = @import("check");
const extract = @import("extract");
const testgen = @import("testgen");
const gpurify = @import("gpurify");
const fuzz = @import("fuzz.zig");
const ensure = fuzz.ensure;
const deck_common = @import("../check/deck/common.zig");

/// The most devices, nets and instances a fuzz input's reference is
/// expanded to. `flattenTop` refuses past `max_flat_elements` (2^28)
/// itself, counted before expanding, but a reference just under that is
/// more than a fuzz run has memory for: inputs between the two are not
/// expanded.
const flat_elements: u128 = 1 << 20;

/// `parseDeck` on arbitrary text, then DRC and ERC over one square on
/// every drawn layer.
///
/// Oracles: every error diagnostic's span lies inside the input on
/// character boundaries; an accepted deck printed compiles back to itself;
/// and every `rule` it holds gets a row in the run table.
pub fn deck(gpa: Allocator, data: []const u8) !void {
    if (!std.unicode.utf8ValidateSlice(data)) return;
    var state: std.heap.ArenaAllocator = .init(gpa);
    defer state.deinit();
    const arena = state.allocator();
    var strings: StrTable = .empty;
    defer strings.deinit(gpa);
    const grid = try geom.Grid.init(1000);
    var diag: ingest.deck.Diag = .{};
    const parsed = ingest.deck.parseDeck(arena, gpa, data, grid, &strings, &diag) catch |err| switch (err) {
        error.Invalid => {
            try ensure(diag.diagnostics.len > 0, "a refusal with no diagnostic", .{});
            for (diag.diagnostics) |d| {
                const ok = d.start <= d.end and d.end <= data.len and boundary(data, d.start) and boundary(data, d.end);
                try ensure(ok, "span {d}..{d} of a {d}-byte deck: {s}", .{ d.start, d.end, data.len, d.message });
            }
            return;
        },
        error.Malformed => return,
        error.OutOfMemory => return err,
    };

    var lb: testgen.shapes.LayoutBuilder = .init(@intCast(parsed.layers.len()));
    for (0..parsed.layers.len()) |l| {
        if (!parsed.layers.isDerived(@fromBackingInt(@as(u16, @intCast(l))))) _ = try lb.rect(arena, @intCast(l), 0, 0, 1000, 1000);
    }
    var store: geom.GeometryStore = .empty;
    var ids: testgen.shapes.Ids = .{};
    try lb.finish(arena, &store, &ids);
    var provenance: ingest.Provenance = .{};
    try ingest.layout.deriveLayersInto(arena, &store, &parsed.layers, &provenance, &strings, &.{});
    try gpurify.internReportIds(gpa, &strings);
    var cdiag: check.deck.compile.Diag = .{};
    // A deck whose rules do not compile has no run table to hold them to.
    var cd = check.deck.compile.fromDeck(gpa, parsed, grid, &strings, &cdiag) catch |err| switch (err) {
        error.OutOfMemory => return err,
        else => return,
    };
    defer cd.deinit(gpa);

    // The printer's round trip: the deck as text compiles, in the same
    // string table, back to the same deck. A `for` loop can splice a unit
    // such as `%` into a rule id, which no `rule` statement can write; the
    // printer refuses that deck rather than write it wrong.
    var why: []const u8 = "";
    const printed = check.deck.source.print(arena, &cd, &strings, &why) catch {
        for (parsed.rules.spec) |r| if (!writable(strings.resolve(r.id))) return;
        return ensure(false, "a parsed deck does not print: {s}", .{why});
    };
    var again = check.deck.compile.compile(gpa, arena, printed, grid, &strings, &cdiag) catch |err|
        return ensure(false, "the printed deck does not compile: {t}\n{s}", .{ err, printed });
    defer again.deinit(gpa);
    deck_common.assertSame(&cd, &again) catch return ensure(false, "the printed deck compiles to another deck:\n{s}", .{printed});

    const loaded: gpurify.Loaded = .{ .strings = strings, .grid = grid, .deck = cd, .store = store, .provenance = provenance, .reference = null, .intent = null, .design = null };
    var ediag: gpurify.ExtractDiagnostic = .none;
    const extracted = gpurify.extract(arena, &loaded, &ediag) catch return;
    var outputs: gpurify.Outputs = .{};
    const summary = gpurify.runChecks(gpa, arena, &loaded, &extracted, .{ .checks = .{ .drc = true, .erc = true } }, &outputs) catch |err| switch (err) {
        error.OutOfMemory => return err,
        else => return,
    };
    // A stage that did not run says why in its status, not row by row: ERC
    // is skipped on a layout with no geometry, which a deck drawing no
    // layer gets here.
    for (parsed.rules.spec) |r| {
        const is_drc = std.mem.indexOfScalar(geom.StrId, cd.drc.id.items, r.id) != null;
        if (summary.erc != .ran and !is_drc) continue;
        const row = for (outputs.runs.items) |run| (if (run.rule == r.id) break true) else false;
        try ensure(row, "rule {s} has no row in the run table", .{strings.resolve(r.id)});
    }
}

/// `readSpice` on arbitrary text, with no deck device models, then the
/// flattening below the top LVS does.
///
/// Oracle: a typed error, never a crash or a leak; an accepted netlist has
/// one device per `M`/`Q`/`R`/`C`/`D`/`L` card and one instance per `X`
/// card, counted from the text by `spiceCards`; and `flattenChecked`.
pub fn netlistSpice(gpa: Allocator, data: []const u8) !void {
    var strings: StrTable = .empty;
    defer strings.deinit(gpa);
    var diag: ingest.netlist.Diagnostic = .{};
    var n = ingest.netlist.readSpice(gpa, data, &strings, &.{}, &diag) catch |err| switch (err) {
        error.OutOfMemory => return err,
        else => return,
    };
    defer n.deinit(gpa);
    const cards = spiceCards(data);
    try ensure(n.device_model.items.len == cards[0], "{d} devices, {d} device cards", .{ n.device_model.items.len, cards[0] });
    try ensure(n.instance_of.items.len == cards[1], "{d} instances, {d} X cards", .{ n.instance_of.items.len, cards[1] });
    try flattenChecked(gpa, &n, &strings);
}

/// `readSpectre` on arbitrary text, then the flattening below the top LVS
/// does.
///
/// Oracle: a typed error, never a crash or a leak; an accepted netlist's
/// devices and instances together number its statements, counted from the
/// text by `spectreStatements`; and `flattenChecked`.
pub fn netlistSpectre(gpa: Allocator, data: []const u8) !void {
    var strings: StrTable = .empty;
    defer strings.deinit(gpa);
    var diag: ingest.netlist.Diagnostic = .{};
    var n = ingest.netlist.readSpectre(gpa, data, &strings, &.{}, &diag) catch |err| switch (err) {
        error.OutOfMemory => return err,
        else => return,
    };
    defer n.deinit(gpa);
    const got = n.device_model.items.len + n.instance_of.items.len;
    const want = spectreStatements(data);
    try ensure(got == want, "{d} devices and instances, {d} statements", .{ got, want });
    try flattenChecked(gpa, &n, &strings);
}

/// `parseIntent` on arbitrary text. Oracle: a typed error, never a crash
/// or a leak.
pub fn intent(gpa: Allocator, data: []const u8) !void {
    var state: std.heap.ArenaAllocator = .init(gpa);
    defer state.deinit();
    var strings: StrTable = .empty;
    defer strings.deinit(gpa);
    var diag: ingest.intent.Diagnostic = .{};
    _ = ingest.intent.parseIntent(state.allocator(), gpa, data, &strings, &diag) catch {};
}

/// `liberty.spec.parse` on arbitrary text. Oracle: a typed error, never a
/// crash.
pub fn libertySpec(gpa: Allocator, data: []const u8) !void {
    var state: std.heap.ArenaAllocator = .init(gpa);
    defer state.deinit();
    var diag: gpurify.liberty.spec.Diagnostic = .{};
    _ = gpurify.liberty.spec.parse(state.allocator(), data, &diag) catch {};
}

/// The SPEF and DSPF readers on arbitrary text.
///
/// Oracle: a typed error, never a crash or a leak; an accepted file is a
/// network the writers and `compareInto` can take: names ascending and
/// unique, one net per name, each net's nodes one run in ascending order,
/// every element's nodes in range, only a capacitance to ground, finite
/// values, the elements in canonical order (sorting them changes nothing).
pub fn spef(gpa: Allocator, data: []const u8) !void {
    const readers = [_]*const fn (Allocator, []const u8, *extract.foreign.Read, *extract.foreign.Diagnostic) extract.foreign.Error!void{ extract.spef.readInto, extract.dspf.readInto };
    for (readers) |readInto| {
        var read: extract.foreign.Read = .empty;
        defer read.deinit(gpa);
        var diag: extract.foreign.Diagnostic = .{};
        readInto(gpa, data, &read, &diag) catch |err| switch (err) {
            error.OutOfMemory => return err,
            else => continue,
        };
        try wellFormed(gpa, &read);
    }
}

// ---- private ----

/// Whether byte `at` of UTF-8 `text` starts a character (or is its end).
fn boundary(text: []const u8, at: usize) bool {
    return at == text.len or (at < text.len and text[at] & 0xC0 != 0x80);
}

/// Whether the printer can write `id` as a rule id.
fn writable(id: []const u8) bool {
    if (id.len == 0) return false;
    for (id) |c| if (!ascii.isAlphanumeric(c) and c != '_' and c != '.') return false;
    return true;
}

/// One line of `text` (split at `\n`, a trailing `\r` dropped), as Rust's
/// `str::lines`.
fn nextLine(lines: *std.mem.SplitIterator(u8, .scalar)) ?[]const u8 {
    const raw = lines.next() orelse return null;
    return std.mem.trimEnd(u8, raw, "\r");
}

/// SPICE cards counted without the reader: `(device cards, X cards)`. A
/// card is a line's first token after `*` comment lines and `$`/`;` tails
/// are dropped, unless the line continues the last card with `+`.
/// Whitespace is ASCII's, the reader's.
fn spiceCards(text: []const u8) [2]usize {
    var devices: usize = 0;
    var instances: usize = 0;
    var cards: usize = 0;
    var lines = std.mem.splitScalar(u8, text, '\n');
    while (nextLine(&lines)) |raw| {
        const comment = std.mem.startsWith(u8, std.mem.trimStart(u8, raw, &ascii.whitespace), "*");
        const code = if (comment) "" else raw[0 .. std.mem.indexOfAny(u8, raw, "$;") orelse raw.len];
        const lead = std.mem.trimStart(u8, code, &ascii.whitespace);
        const continues = std.mem.startsWith(u8, lead, "+");
        const line = if (continues) lead[1..] else code;
        var tokens = std.mem.tokenizeAny(u8, line, &ascii.whitespace);
        const head = tokens.next() orelse continue;
        if (continues and cards > 0) continue;
        cards += 1;
        switch (ascii.toUpper(head[0])) {
            'M', 'Q', 'R', 'C', 'D', 'L' => devices += 1,
            'X' => instances += 1,
            else => {},
        }
    }
    return .{ devices, instances };
}

/// Spectre statements counted without the reader: every statement but
/// `subckt`, `ends`, `endsubckt` and `model` is a device or an instance. A
/// statement starts a line once `//` comments and `*` comment lines are
/// dropped, unless the line before ended in `\`.
fn spectreStatements(text: []const u8) usize {
    var statements: usize = 0;
    var cards: usize = 0;
    var folded = false;
    var lines = std.mem.splitScalar(u8, text, '\n');
    while (nextLine(&lines)) |raw| {
        const lead = std.mem.trimStart(u8, raw, &ascii.whitespace);
        const comment = std.mem.startsWith(u8, lead, "*") or std.mem.startsWith(u8, lead, "//");
        const code = if (comment) "" else raw[0 .. std.mem.indexOf(u8, raw, "//") orelse raw.len];
        const trimmed = std.mem.trimEnd(u8, code, &ascii.whitespace);
        const folds = std.mem.endsWith(u8, trimmed, "\\");
        const line = if (folds) trimmed[0 .. trimmed.len - 1] else trimmed;
        const continues = folded;
        folded = folds;
        var tokens = std.mem.tokenizeAny(u8, line, ascii.whitespace ++ "()");
        const head = tokens.next() orelse continue;
        if (continues and cards > 0) continue;
        cards += 1;
        const structural = for ([_][]const u8{ "subckt", "ends", "endsubckt", "model" }) |k| (if (std.mem.eql(u8, head, k)) break true) else false;
        statements += @intFromBool(!structural);
    }
    return statements;
}

/// Flattens `n` below its top, as LVS loads a reference, when it has one
/// top and at most 1000 subcircuits (the oracle's own walk recurses).
///
/// Oracle, counted from the tables: a cycle the top reaches is
/// `CyclicHierarchy`; a top whose devices, nets and instances number more
/// than `max_flat_elements` is `TooLarge` with that number, saturated to a
/// `u64`; otherwise, within `flat_elements`, the flat netlist holds each
/// subcircuit's devices once per instance path, and the top's nets plus,
/// per instance, its callee's nets that are not on a port.
fn flattenChecked(gpa: Allocator, n: *const Netlist, strings: *StrTable) !void {
    const top = try n.top(gpa) orelse return;
    const count = n.subcktCount();
    if (count > 1000) return;
    var state: std.heap.ArenaAllocator = .init(gpa);
    defer state.deinit();
    const arena = state.allocator();
    const calls = try arena.alloc(std.ArrayList(u32), count);
    @memset(calls, .empty);
    for (n.instance_subckt.items, n.instance_of.items) |caller, callee| try calls[@backingInt(caller)].append(arena, @backingInt(callee));
    // Per subcircuit: its devices, and its nets that are not on its ports.
    const own = try arena.alloc([2]u128, count);
    for (own, 0..) |*o, c| {
        const rows = n.devicesOf(@fromBackingInt(@as(u32, @intCast(c))));
        o.* = .{ rows[1] - rows[0], 0 };
    }
    var top_nets: u128 = 0;
    for (n.net_subckt.items, 0..) |cell, net| {
        const on_port = for (n.port_net.items) |p| (if (@backingInt(p) == net) break true) else false;
        own[@backingInt(cell)][1] += @intFromBool(!on_port);
        top_nets += @intFromBool(cell == top);
    }
    const memo = try arena.alloc(?[3]u128, count);
    @memset(memo, null);
    const on_path = try arena.alloc(bool, count);
    @memset(on_path, false);
    var diag: ingest.netlist.Diagnostic = .{};
    const below = flatBelow(@backingInt(top), calls, own, memo, on_path) orelse {
        var flat = ingest.netlist.flattenTop(gpa, n, top, strings, &diag) catch |err| {
            return ensure(err == error.CyclicHierarchy, "a cycle under the top read as {t}", .{err});
        };
        flat.deinit(gpa);
        return ensure(false, "a cycle under the top flattened", .{});
    };
    const nets = top_nets +| below[1];
    const total = below[0] +| nets +| below[2];
    if (total > ingest.netlist.max_flat_elements) {
        const saturated: u64 = std.math.cast(u64, total) orelse std.math.maxInt(u64);
        var flat = ingest.netlist.flattenTop(gpa, n, top, strings, &diag) catch |err| {
            return ensure(err == error.TooLarge and diag.count == saturated, "{d} elements read as {t} (count {d})", .{ total, err, diag.count });
        };
        flat.deinit(gpa);
        return ensure(false, "{d} elements flattened", .{total});
    }
    if (total > flat_elements) return;
    var flat = ingest.netlist.flattenTop(gpa, n, top, strings, &diag) catch |err|
        return ensure(false, "an acyclic reference within the cap does not flatten: {t}", .{err});
    defer flat.deinit(gpa);
    try ensure(flat.device_model.items.len == below[0], "{d} flat devices, want {d}", .{ flat.device_model.items.len, below[0] });
    try ensure(flat.net_name.items.len == nets, "{d} flat nets, want {d}", .{ flat.net_name.items.len, nets });
}

/// `(devices, nets, instances)` below one placement of `cell`, each
/// instance with the nets it adds; null on a cycle.
fn flatBelow(cell: u32, calls: []const std.ArrayList(u32), own: []const [2]u128, memo: []?[3]u128, on_path: []bool) ?[3]u128 {
    if (memo[cell]) |c| return c;
    if (on_path[cell]) return null;
    on_path[cell] = true;
    var c: [3]u128 = .{ own[cell][0], 0, 0 };
    for (calls[cell].items) |callee| {
        const b = flatBelow(callee, calls, own, memo, on_path) orelse return null;
        c = .{ c[0] +| b[0], c[1] +| own[callee][1] +| b[1], c[2] +| 1 +| b[2] };
    }
    on_path[cell] = false;
    memo[cell] = c;
    return c;
}

/// The laws an accepted SPEF or DSPF's `Read` holds; see `spef`.
fn wellFormed(gpa: Allocator, read: *const extract.foreign.Read) !void {
    const n = &read.network;
    const names = read.nameCount();
    for (1..names) |i| try ensure(std.mem.order(u8, read.name(@intCast(i - 1)), read.name(@intCast(i))) == .lt, "names unique, ascending: {s} then {s}", .{ read.name(@intCast(i - 1)), read.name(@intCast(i)) });
    try ensure(std.sort.isSorted(u32, n.node_net.items, {}, std.sort.asc(u32)), "each net's nodes one run", .{});
    for (n.node_net.items) |net| try ensure(net < names, "a node on net {d} of {d}", .{ net, names });
    try ensure(n.node_layer.items.len == n.nodeCount(), "a layer per node", .{});
    for (n.from.items, n.to.items, n.kind.items, n.value.items) |from, to, kind, value| {
        try ensure(@backingInt(from) < n.nodeCount(), "an element from node {d} of {d}", .{ @backingInt(from), n.nodeCount() });
        if (to == .ground) {
            try ensure(kind == .ground_cap, "a {t} to ground", .{kind});
        } else try ensure(@backingInt(to) < n.nodeCount(), "an element to node {d} of {d}", .{ @backingInt(to), n.nodeCount() });
        try ensure(std.math.isFinite(value), "a {t} of {d}", .{ kind, value });
    }
    var sorted: extract.network.ParasiticNetwork = .empty;
    defer sorted.deinit(gpa);
    try sorted.from.appendSlice(gpa, n.from.items);
    try sorted.to.appendSlice(gpa, n.to.items);
    try sorted.kind.appendSlice(gpa, n.kind.items);
    try sorted.value.appendSlice(gpa, n.value.items);
    try sorted.sortCanonical(gpa);
    const canonical = std.mem.eql(extract.network.NodeId, sorted.from.items, n.from.items) and
        std.mem.eql(extract.network.NodeId, sorted.to.items, n.to.items) and
        std.mem.eql(extract.network.Kind, sorted.kind.items, n.kind.items) and
        std.mem.eql(u64, @ptrCast(sorted.value.items), @ptrCast(n.value.items));
    try ensure(canonical, "the elements are not in canonical order", .{});
    var cmp: extract.compare.Comparison = .empty;
    defer cmp.deinit(gpa);
    try extract.compare.compareInto(gpa, n, n, &cmp);
}
