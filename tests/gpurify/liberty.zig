//! Liberty generation on a corpus cell: the interface level end to end and
//! the pin cross-check's refusals, which need no simulator. Ported from
//! tests/liberty.rs (the `spice`-level differential against ngspice is
//! liberty_ngspice.zig).
//!
//! `LVS_CLEAN_MATCH` is one inverter whose four nets are labelled
//! `LVS_INV_n0`, `_n1`, `_n4` and `_n5`; its schematic, `lvs_inv.cdl`, calls
//! the ports A, Y, VDD and VSS. Those names are the answer every spec below
//! is checked against.
//!
//! Contents:
//! - `pub const pins`, `pub fn specWith(arena: Allocator, pin_list: []const u8, extra: []const u8) !MacroSpec`
//! - `pub fn loadInverter(arena: Allocator, reference: bool) !gpurify.Loaded`

const std = @import("std");
const Allocator = std.mem.Allocator;
const testing = std.testing;
const paths = @import("paths");
const gpurify = @import("gpurify");
const liberty = gpurify.liberty;
const MacroSpec = liberty.spec.MacroSpec;

/// The inverter's labelled pins.
pub const pins =
    \\{"name": "LVS_INV_n5", "role": "input", "power": "LVS_INV_n1", "ground": "LVS_INV_n0"},
    \\{"name": "LVS_INV_n4", "role": "output", "power": "LVS_INV_n1", "ground": "LVS_INV_n0"},
    \\{"name": "LVS_INV_n1", "role": "power"},
    \\{"name": "LVS_INV_n0", "role": "ground"}
;

/// The inverter's spec with `pin_list` as its pins and `extra` keys after
/// its one corner (`""` or `, "key": ...`).
pub fn specWith(arena: Allocator, pin_list: []const u8, extra: []const u8) !MacroSpec {
    const text = try arena.print(
        \\{{"cell": "LVS_INV", "pins": [{s}],
        \\  "corners": [{{"name": "tt_025C_1v80", "temperature": 25,
        \\                "supplies": {{"LVS_INV_n1": 1.8, "LVS_INV_n0": 0}}, "models": []}}]{s}}}
    , .{ pin_list, extra });
    var diag: liberty.Diagnostic = .{};
    return liberty.spec.parse(arena, text, &diag);
}

/// The corpus inverter on params.deck, with its schematic when `reference`.
pub fn loadInverter(arena: Allocator, reference: bool) !gpurify.Loaded {
    var root = try std.Io.Dir.cwd().openDir(testing.io, paths.root, .{});
    defer root.close(testing.io);
    var diag: gpurify.LoadDiagnostic = .{};
    const inputs: gpurify.Inputs = .{
        .layout = "tests/fixtures/lvs/LVS_CLEAN_MATCH.gds",
        .deck = "tests/fixtures/params.deck",
        .reference = if (reference) &.{"tests/fixtures/lvs_inv.cdl"} else &.{},
    };
    return gpurify.load(testing.allocator, arena, testing.io, root, inputs, &.{}, &diag);
}

// ---- private ----

/// Runs `generate` at `accuracy` in a scratch directory.
fn run(arena: Allocator, loaded: *const gpurify.Loaded, macro: *const MacroSpec, accuracy: liberty.Accuracy, lef: ?[]const u8, diag: *liberty.Diagnostic) liberty.Error!liberty.Generated {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    var ediag: gpurify.ExtractDiagnostic = .none;
    const extracted = gpurify.extract(arena, loaded, &ediag) catch return error.Geometry;
    return liberty.generate(arena, loaded, &extracted, .{
        .spec = macro,
        .accuracy = accuracy,
        .lef = lef,
        .work = "work",
        .tool_version = "test",
        .env = .{ .gpa = testing.allocator, .io = testing.io, .dir = tmp.dir },
    }, diag);
}

fn contains(haystack: []const u8, needle: []const u8) bool {
    return std.mem.indexOf(u8, haystack, needle) != null;
}

test "the interface level writes pins, supplies and area and no arcs" {
    // Oracle: the `interface` level of `docs/liberty.md` (in git history):
    // pins, `pg_pin`s, directions and area; and of
    // docs/src/how-to/characterise-a-library.md (Steps, 3): no arc, no
    // capacitance; in Liberty's syntax, for the corpus inverter's labelled pins
    // and the spec's 1.8 V supply.
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const loaded = try loadInverter(a, false);
    const macro = try specWith(a, pins, "");
    var diag: liberty.Diagnostic = .{};
    const generated = try run(a, &loaded, &macro, .interface, null, &diag);
    try testing.expectEqual(2, generated.files.len);
    try testing.expectEqualStrings("LVS_INV.v", generated.files[0].path);
    try testing.expectEqualStrings("LVS_INV__tt_025C_1v80.lib", generated.files[1].path);
    const lib = generated.files[1].text;
    for ([_][]const u8{
        "library (\"LVS_INV__tt_025C_1v80\")",
        "pg_pin (\"LVS_INV_n1\")",
        "pg_type : primary_power;",
        "pin (\"LVS_INV_n5\")",
        "direction : input;",
        "related_power_pin : \"LVS_INV_n1\";",
        "is_macro_cell : true;",
        "voltage_map(\"LVS_INV_n1\", 1.8000000000);",
    }) |needle| if (!contains(lib, needle)) {
        std.debug.print("missing {s} in\n{s}\n", .{ needle, lib });
        return error.TestMissing;
    };
    try testing.expect(!contains(lib, "timing ()"));
    try testing.expect(!contains(lib, "capacitance :"));
    const at = std.mem.indexOf(u8, lib, "area : ").? + 7;
    const area = try std.fmt.parseFloat(f64, lib[at .. at + std.mem.indexOfScalar(u8, lib[at..], ';').?]);
    try testing.expect(area > 0.0);
    try testing.expect(contains(generated.files[0].text, "(* blackbox *)\nmodule LVS_INV ("));
}

test "a pin the views disagree on is refused by name" {
    // Oracle: construct-from-answer. Each case adds one disagreement (a spec
    // pin no layout label carries, schematic port names that are not the
    // labels, a LEF pin the spec lacks), and the refusal must name it.
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var diag: liberty.Diagnostic = .{};
    const plain = try loadInverter(a, false);

    // The spec lists Z; nothing in the layout carries it.
    const extra = try specWith(a, pins ++ ", {\"name\": \"Z\", \"role\": \"input\", \"power\": \"LVS_INV_n1\", \"ground\": \"LVS_INV_n0\"}", "");
    try testing.expectError(error.MissingPin, run(a, &plain, &extra, .interface, null, &diag));
    try testing.expect(contains(diag.message, "pin Z"));

    // The schematic's ports are A, Y, VDD and VSS; the spec's are the labels.
    const with_reference = try loadInverter(a, true);
    const macro = try specWith(a, pins, "");
    try testing.expectError(error.Mismatch, run(a, &with_reference, &macro, .interface, null, &diag));
    try testing.expect(contains(diag.message, "lacks [LVS_INV_n0, LVS_INV_n1, LVS_INV_n4, LVS_INV_n5]") and contains(diag.message, "has [A, VDD, VSS, Y]"));

    // The LEF's macro has a pin the spec does not.
    const lef = "MACRO LVS_INV\n PIN LVS_INV_n0\n END LVS_INV_n0\n PIN LVS_INV_n1\n END LVS_INV_n1\n PIN LVS_INV_n4\n END LVS_INV_n4\n PIN LVS_INV_n5\n END LVS_INV_n5\n PIN EN\n END EN\nEND LVS_INV\n";
    try testing.expectError(error.Mismatch, run(a, &plain, &macro, .interface, lef, &diag));
    try testing.expect(contains(diag.message, "has [EN]"));
}

test "two pins labelled on one net are refused as shorted" {
    // Oracle: construct-from-answer (testing-plan F14). The input's name is
    // added to the output's net, a short between two pins by construction;
    // without it the four pins are four nets. Extraction keeps both names,
    // and the circuit refuses the pair rather than characterise one node as
    // two pins.
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var loaded = try loadInverter(a, false);
    const macro = try specWith(a, pins, "");
    var ediag: gpurify.ExtractDiagnostic = .none;
    var diag: liberty.Diagnostic = .{};
    var start: std.ArrayList(u32) = .empty;
    var nets: std.ArrayList(@import("check").topology.net.NetId) = .empty;
    const clean = try gpurify.extract(a, &loaded, &ediag);
    try liberty.circuit.pinNetsInto(a, &loaded, &clean, &macro, &start, &nets, &diag);

    const output = loaded.strings.get("LVS_INV_n4").?;
    const net = clean.ports.netOf(output).?;
    const input = loaded.strings.get("LVS_INV_n5").?;
    try loaded.provenance.label(a, clean.nets.polysOf(net)[0], input);
    const shorted = try gpurify.extract(a, &loaded, &ediag);
    try testing.expectError(error.ShortedPins, liberty.circuit.pinNetsInto(a, &loaded, &shorted, &macro, &start, &nets, &diag));
    try testing.expectEqualStrings("pins LVS_INV_n5 and LVS_INV_n4 are labelled on one net: the layout shorts them", diag.message);
}

test "a pex refusal names the deck layer" {
    // Oracle: construct-from-answer (testing-plan F78). `poly` is stripped
    // of its sheet resistance, then of its dielectric, so the closed forms
    // (`analytical`) and the field solve (`field`, the input pin's gate is
    // drawn on poly) each refuse it before any simulation, named as the deck
    // names it, as `pex` reports it.
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const macro = try specWith(a, pins, "");
    var diag: liberty.Diagnostic = .{};

    var no_sheet = try loadInverter(a, false);
    const poly = @backingInt(no_sheet.deck.deck.layers.id(&no_sheet.strings, "poly").?);
    no_sheet.deck.deck.stack.sheet_res_ohm_sq[poly] = 0.0;
    try testing.expectError(error.Pex, run(a, &no_sheet, &macro, .analytical, null, &diag));
    try testing.expect(std.mem.startsWith(u8, diag.message, "layer poly: ") and contains(diag.message, "sheet resistance"));

    var no_dielectric = try loadInverter(a, false);
    no_dielectric.deck.deck.stack.dielectric_k[poly] = 0.0;
    try testing.expectError(error.Solve, run(a, &no_dielectric, &macro, .field, null, &diag));
    try testing.expect(std.mem.startsWith(u8, diag.message, "layer poly: ") and contains(diag.message, "permittivity"));
}
