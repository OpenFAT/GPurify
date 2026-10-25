//! The deck-language suites' fixture: a header of eight drawn layers on a
//! 5 nm deck grid and a 1 nm layout grid, and a body → a parse outcome, its
//! diagnostics, and its rules as text. Ported from the helpers of
//! crates/ingest/tests/deck_text.rs (`HEAD`, `parse`, `ok`, `errors`,
//! `one_error`, `rules`, `layer_name`).
//!
//! Contents: `head`, `Row`, `Outcome` (`deinit`, `d`, `id`, `layer`, `at`,
//! `rules`, `rule`), `layerName`, `runText`, `run`, `ok`, `errors`,
//! `oneError`, `malformed`, `expectStrings`, `expectRow`

const std = @import("std");
const testing = std.testing;
const ingest = @import("ingest");
const geom = @import("geom");
const deck = ingest.deck;
const StrTable = geom.StrTable;
const gpa = testing.allocator;

pub const head =
    \\grid 5nm
    \\layer diff = gds(65, 20)
    \\layer poly = gds(66, 20)
    \\layer licon = gds(66, 44)
    \\layer li = gds(67, 20)
    \\layer mcon = gds(67, 44)
    \\layer met1 = gds(68, 20)
    \\layer met2 = gds(69, 20)
    \\layer met3 = gds(70, 20)
    \\
;

/// One rule as text: id, engine kind, layer names, `name=value` params.
pub const Row = struct { id: []const u8, kind: []const u8, layers: []const []const u8, params: []const []const u8 };

/// A parse and lowering of some deck text, with what it allocated.
pub const Outcome = struct {
    arena: *std.heap.ArenaAllocator,
    strings: StrTable = .empty,
    deck: ?deck.Deck = null,
    err: ?deck.Error = null,
    diag: deck.Diag = .{},

    pub fn deinit(o: *Outcome) void {
        o.strings.deinit(gpa);
        o.arena.deinit();
        gpa.destroy(o.arena);
    }

    pub fn d(o: *const Outcome) *const deck.Deck {
        return &o.deck.?;
    }

    /// The interned id of `name`, which must be interned.
    pub fn id(o: *const Outcome, name: []const u8) geom.StrId {
        return o.strings.get(name).?;
    }

    /// The layer `name` resolves to, which must be declared.
    pub fn layer(o: *const Outcome, name: []const u8) geom.LayerId {
        return o.deck.?.layers.id(&o.strings, name).?;
    }

    /// The row index of layer `name`.
    pub fn at(o: *const Outcome, name: []const u8) usize {
        return @backingInt(o.layer(name));
    }

    /// Every rule as text, in deck order.
    pub fn rules(o: *Outcome) ![]const Row {
        const a = o.arena.allocator();
        const dk = o.d();
        const out = try a.alloc(Row, dk.rules.spec.len);
        for (dk.rules.spec, out) |spec, *row| {
            const layers = try a.alloc([]const u8, spec.layer_len);
            for (dk.rules.layersOf(spec), layers) |l, *n| n.* = layerName(o, l);
            const params = try a.alloc([]const u8, spec.param_len);
            for (dk.rules.paramsOf(spec), params) |prm, *text| {
                const name = o.strings.resolve(prm.name);
                text.* = switch (prm.value) {
                    .length => |v| try std.fmt.allocPrint(a, "{s}={d}dbu", .{ name, v }),
                    .area => |v| try std.fmt.allocPrint(a, "{s}={d}dbu2", .{ name, v }),
                    .ratio => |v| try std.fmt.allocPrint(a, "{s}={d}", .{ name, v }),
                    .count => |v| try std.fmt.allocPrint(a, "{s}=#{d}", .{ name, v }),
                    .flag => |v| try std.fmt.allocPrint(a, "{s}={}", .{ name, v }),
                    .layer => |v| try std.fmt.allocPrint(a, "{s}={s}", .{ name, layerName(o, v) }),
                    .model => |v| try std.fmt.allocPrint(a, "{s}=\"{s}\"", .{ name, o.strings.resolve(v) }),
                };
            }
            row.* = .{ .id = o.strings.resolve(spec.id), .kind = o.strings.resolve(spec.kind), .layers = layers, .params = params };
        }
        return out;
    }

    /// The row with id `id`, which must exist.
    pub fn rule(o: *Outcome, rule_id: []const u8) !Row {
        for (try o.rules()) |r| if (std.mem.eql(u8, r.id, rule_id)) return r;
        std.debug.print("{s} missing\n", .{rule_id});
        return error.TestUnexpectedResult;
    }
};

/// The name of `l` among those the deck_text suite declares.
pub fn layerName(o: *const Outcome, l: geom.LayerId) []const u8 {
    const names = [_][]const u8{ "diff", "poly", "licon", "li", "mcon", "met1", "met2", "met3", "gate", "x", "x#1", "active" };
    for (names) |n| if (o.deck.?.layers.id(&o.strings, n) == l) return n;
    return "?";
}

/// Parses and lowers `text` as it is, on the 1 nm layout grid.
pub fn runText(text: []const u8) !Outcome {
    const arena = try gpa.create(std.heap.ArenaAllocator);
    arena.* = .init(gpa);
    var o: Outcome = .{ .arena = arena };
    if (deck.parseDeck(arena.allocator(), gpa, text, try .init(1000), &o.strings, &o.diag)) |dk| {
        o.deck = dk;
    } else |err| {
        if (err == error.OutOfMemory) return err;
        o.err = err;
    }
    return o;
}

/// Parses and lowers the header followed by `body`.
pub fn run(body: []const u8) !Outcome {
    const text = try std.mem.concat(gpa, u8, &.{ head, body });
    defer gpa.free(text);
    return runText(text);
}

/// The header and `body`, which must parse and lower.
pub fn ok(body: []const u8) !Outcome {
    var o = try run(body);
    if (o.err) |err| {
        for (o.diag.diagnostics) |dg| std.debug.print("{d}:{d}: {s}\n", .{ dg.line, dg.col, dg.message });
        if (err == error.Malformed) std.debug.print("malformed: {s}\n", .{o.diag.malformed});
        o.deinit();
        return error.TestUnexpectedResult;
    }
    return o;
}

/// Every diagnostic message of `body`, which must be refused with some.
pub fn errors(o: *const Outcome) ![]const deck.Diagnostic {
    if (o.err == null or o.err.? != error.Invalid) {
        std.debug.print("refused with {?}, not diagnostics ({s})\n", .{ o.err, o.diag.malformed });
        return error.TestUnexpectedResult;
    }
    return o.diag.diagnostics;
}

/// `body` is refused with a diagnostic whose message holds `needle`.
pub fn oneError(body: []const u8, needle: []const u8) !void {
    var o = try run(body);
    defer o.deinit();
    for (try errors(&o)) |dg| if (std.mem.indexOf(u8, dg.message, needle) != null) return;
    std.debug.print("wanted an error containing {s}, got:\n", .{needle});
    for (o.diag.diagnostics) |dg| std.debug.print("  {s}\n", .{dg.message});
    return error.TestUnexpectedResult;
}

/// `body` is refused as malformed, the reason holding `needle`.
pub fn malformed(body: []const u8, needle: []const u8) !void {
    var o = try run(body);
    defer o.deinit();
    if (o.err != null and o.err.? == error.Malformed and std.mem.indexOf(u8, o.diag.malformed, needle) != null) return;
    std.debug.print("{s}: wanted malformed with {s}, got {?} ({s})\n", .{ body, needle, o.err, o.diag.malformed });
    for (o.diag.diagnostics) |dg| std.debug.print("  {s}\n", .{dg.message});
    return error.TestUnexpectedResult;
}

/// Asserts two lists of strings are equal.
pub fn expectStrings(want: []const []const u8, got: []const []const u8) !void {
    if (want.len == got.len) {
        for (want, got) |w, g| {
            if (!std.mem.eql(u8, w, g)) break;
        } else return;
    }
    std.debug.print("want:", .{});
    for (want) |w| std.debug.print(" {s}", .{w});
    std.debug.print("\n got:", .{});
    for (got) |g| std.debug.print(" {s}", .{g});
    std.debug.print("\n", .{});
    return error.TestExpectedEqual;
}

/// Asserts a rule row's kind, layers and params.
pub fn expectRow(row: Row, kind: []const u8, layers: []const []const u8, params: []const []const u8) !void {
    try testing.expectEqualStrings(kind, row.kind);
    try expectStrings(layers, row.layers);
    try expectStrings(params, row.params);
}
