//! Every way compiling a deck can refuse it, DRC side. Ported from
//! crates/check/tests/deck/errors.rs; the ERC tests
//! (`every_erc_error_is_still_produced`, `erc_validation_*`,
//! `every_positive_erc_value_written_as_zero_is_refused`,
//! `every_erc_value_check_refuses_its_one_broken_value`) wait for the ERC
//! port (wave 4): until then every ERC row is `ErcRulesNotPorted`.

const std = @import("std");
const testing = std.testing;
const geom = @import("geom");
const ingest = @import("ingest");
const check = @import("check");
const deck = check.deck;
const ParamValue = ingest.deck.ParamValue;
const gpa = testing.allocator;

/// One hand-built rule row: id, kind, how many layer arguments (each layer
/// 0), and its parameters.
const Row = struct { id: []const u8, kind: []const u8, layers: u32, params: []const struct { []const u8, ParamValue } };

/// A refusal and what it names.
const Refusal = struct { err: anyerror, diag: check.drc.params.Diagnostic };

const header =
    \\grid 1nm
    \\layer a = gds(1, 0)
    \\layer b = gds(2, 0)
    \\layer e = a.edges()
    \\layer f = b.edges()
    \\connect conductors [a, b]
    \\device mos a model "nfet" terminals [a, b, b, b]
    \\
;

// ---- private ----

fn len(nm: i64) ParamValue {
    return .{ .length = nm };
}

/// What compiling a deck of `rows` (an empty layer table) refuses. The
/// parser refuses most of these rows; a deck built in code reaches the rule
/// typer as written.
fn refusal(rows: []const Row) !Refusal {
    var arena: std.heap.ArenaAllocator = .init(gpa);
    defer arena.deinit();
    const a = arena.allocator();
    var strings: geom.StrTable = .empty;
    defer strings.deinit(gpa);
    var specs: std.ArrayList(ingest.deck.RuleSpec) = .empty;
    var layer_ref: std.ArrayList(geom.LayerId) = .empty;
    var param: std.ArrayList(ingest.deck.NamedValue) = .empty;
    for (rows) |r| {
        const layer_start: u32 = @intCast(layer_ref.items.len);
        for (0..r.layers) |_| try layer_ref.append(a, @fromBackingInt(0));
        const param_start: u32 = @intCast(param.items.len);
        for (r.params) |p| try param.append(a, .{ .name = try strings.intern(gpa, p[0]), .value = p[1] });
        try specs.append(a, .{ .id = try strings.intern(gpa, r.id), .kind = try strings.intern(gpa, r.kind), .layer_start = layer_start, .layer_len = r.layers, .param_start = param_start, .param_len = @intCast(r.params.len) });
    }
    const d: ingest.deck.Deck = .{ .rules = .{ .spec = specs.items, .layer_ref = layer_ref.items, .param = param.items } };
    var diag: deck.compile.Diag = .{};
    if (deck.compile.fromDeck(gpa, d, try geom.Grid.init(1000), &strings, &diag)) |cd_| {
        var cd = cd_;
        cd.deinit(gpa);
        return error.TestExpectedRefusal;
    } else |e| return .{ .err = e, .diag = diag.rule };
}

test "every drc error is still produced" {
    // Oracle: construct-from-answer: each deck differs from a legal one in
    // the one value the variant's documented constraint forbids.
    var r = try refusal(&.{.{ .id = "w", .kind = "min_widht", .layers = 1, .params = &.{.{ "limit", len(10) }} }});
    try testing.expectEqual(error.UnknownKind, r.err);
    r = try refusal(&.{.{ .id = "w", .kind = "min_width", .layers = 1, .params = &.{} }});
    try testing.expectEqual(error.MissingParam, r.err);
    try testing.expectEqualStrings("limit", r.diag.param);
    r = try refusal(&.{.{ .id = "w", .kind = "min_width", .layers = 1, .params = &.{.{ "limit", .{ .ratio = 1.0 } }} }});
    try testing.expectEqual(error.WrongParamType, r.err);
    try testing.expectEqualStrings("limit", r.diag.param);
    r = try refusal(&.{.{ .id = "w", .kind = "min_width", .layers = 2, .params = &.{.{ "limit", len(10) }} }});
    try testing.expectEqual(error.WrongLayerCount, r.err);
    try testing.expectEqual(@as(u32, 1), r.diag.expected);
    try testing.expectEqual(@as(u32, 2), r.diag.found);
    r = try refusal(&.{.{ .id = "w", .kind = "min_width", .layers = 1, .params = &.{.{ "limit", len(0) }} }});
    try testing.expectEqual(error.NonPositiveLimit, r.err);
    try testing.expectEqual(@as(i64, 0), r.diag.limit);
    r = try refusal(&.{.{ .id = "a", .kind = "angle", .layers = 0, .params = &.{.{ "angle", .{ .count = 30 } }} }});
    try testing.expectEqual(error.UnrepresentableAngle, r.err);
    try testing.expectEqual(@as(i32, 30), r.diag.degrees);
    r = try refusal(&.{ .{ .id = "w", .kind = "min_width", .layers = 1, .params = &.{.{ "limit", len(10) }} }, .{ .id = "w", .kind = "min_width", .layers = 1, .params = &.{.{ "limit", len(20) }} } });
    try testing.expectEqual(error.DuplicateRule, r.err);
    // A cell of zero: not a positive space, so not a valid table.
    r = try refusal(&.{.{ .id = "t", .kind = "spacing_table", .layers = 1, .params = &.{ .{ "prl", len(0) }, .{ "width", len(0) }, .{ "space", len(0) } } }});
    try testing.expectEqual(error.BadTable, r.err);
}

test "every positive drc value written as zero is refused" {
    // Oracle: the kinds' documented domains: each value is a length, area
    // or count the checker documents as positive.
    const length = [2][]const u8{ "0nm", "10nm" };
    const area = [2][]const u8{ "0nm2", "100nm2" };
    const fraction = [2][]const u8{ "0", "0.5" };
    const count = [2][]const u8{ "0", "2" };
    const cases = [_]struct { []const u8, [2][]const u8 }{
        .{ "width(a) >= {}", length },                                   .{ "width(a) <= {}", length },
        .{ "size(a) == {} x 10nm", length },                             .{ "size(a) == 10nm x {}", length },
        .{ "edge_length(a) >= {}", length },                             .{ "notch(a) >= {}", length },
        .{ "space(a) >= {}", length },                                   .{ "space(a, b) >= {}", length },
        .{ "eol_space(a; eol_width: {}) >= 10nm", length },              .{ "eol_space(a; eol_width: 10nm) >= {}", length },
        .{ "prl_space(a; prl: {}) >= 10nm", length },                    .{ "prl_space(a; prl: 10nm) >= {}", length },
        .{ "corner_space(a) >= {}", length },                            .{ "wide_space(a; width: {}) >= 10nm", length },
        .{ "wide_space(a; width: 10nm) >= {}", length },                 .{ "area(a) >= {}", area },
        .{ "hole_area(a) >= {}", area },                                 .{ "cheesing(a) <= {}", area },
        .{ "density(a; window: {}, step: 10nm) >= 0.5", length },        .{ "density(a; window: 10nm, step: {}) >= 0.5", length },
        .{ "density(a; window: 10nm, step: 10nm) >= {}", fraction },     .{ "global_density(a) >= {}", fraction },
        .{ "enclosure(a, b) >= {}", length },                            .{ "enclosure(a, b, opposite) >= {}", length },
        .{ "extension(a, b) >= {}", length },                            .{ "overlap(a, b) >= {}", length },
        .{ "tap_distance(a, b) <= {}", length },                         .{ "off_grid(; pitch: {})", length },
        .{ "redundant_via(a; within: 10nm) >= {}", count },              .{ "redundant_via(a; within: {}) >= 2", length },
        .{ "via_array_space(a; array: 2) >= {}", length },               .{ "patterning(a; colors: {}) >= 10nm", count },
        .{ "patterning(a; colors: 2) >= {}", length },                   .{ "contains(a, b) >= {}", count },
        .{ "space(a; nets: same) >= {}", length },                       .{ "wide_space(a; width: {}, attached: 10nm) >= 10nm", length },
        .{ "wide_space(a; width: 10nm, attached: {}) >= 10nm", length }, .{ "wide_space(a; width: 10nm, attached: 10nm) >= {}", length },
        .{ "length(e) >= {}", length },                                  .{ "space(e) >= {}", length },
        .{ "space(e, f) >= {}", length },                                .{ "enclosure(e, b) >= {}", length },
    };
    for (cases) |c| {
        for (c[1], [2]bool{ true, false }) |value, zero| {
            const rule = try std.mem.replaceOwned(u8, gpa, c[0], "{}", value);
            defer gpa.free(rule);
            const text = try std.fmt.allocPrint(gpa, "{s}rule r {s}\n", .{ header, rule });
            defer gpa.free(text);
            var arena: std.heap.ArenaAllocator = .init(gpa);
            defer arena.deinit();
            var strings: geom.StrTable = .empty;
            defer strings.deinit(gpa);
            var diag: deck.compile.Diag = .{};
            if (deck.compile.compile(gpa, arena.allocator(), text, try geom.Grid.init(1000), &strings, &diag)) |cd_| {
                var cd = cd_;
                cd.deinit(gpa);
                if (zero) {
                    std.debug.print("{s} with {s} compiled\n", .{ c[0], value });
                    return error.TestExpectedRefusal;
                }
            } else |e| {
                if (!zero or e != error.NonPositiveLimit) {
                    std.debug.print("{s} with {s}: {t}\n", .{ c[0], value, e });
                    return e;
                }
                try testing.expectEqualStrings("r", strings.resolve(diag.rule.rule));
            }
        }
    }
}
