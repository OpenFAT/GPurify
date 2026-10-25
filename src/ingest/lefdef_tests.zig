//! The LEF/DEF readers against the reference's own examples (LEF/DEF 5.8
//! Language Reference), the flattened geometry, and the GDSII written from
//! it read back by the GDS reader. Test-only; ported from
//! crates/ingest/src/lefdef/tests.rs, the in-file test module.

const std = @import("std");
const testing = std.testing;
const geom = @import("geom");
const StrTable = geom.StrTable;
const lefdef = @import("lefdef.zig");
const Lef = lefdef.Lef;
const Def = lefdef.Def;
const Shape = lefdef.Shape;
const FlatShape = lefdef.FlatShape;
const Diagnostic = lefdef.Diagnostic;
const exactUnits = lefdef.exactUnits;
const deck = @import("deck/deck.zig");
const gds = @import("gds.zig");
const gpa = testing.allocator;

/// A technology with two metals and a cut, in the reference's own layer
/// names, and a 4 × 2 macro whose one pin is its lower-left unit square.
const lef_text =
    \\VERSION 5.8 ;
    \\BUSBITCHARS "[]" ;
    \\UNITS
    \\  DATABASE MICRONS 1000 ;
    \\END UNITS
    \\MANUFACTURINGGRID 0.005 ;
    \\LAYER M1
    \\  TYPE ROUTING ;
    \\  DIRECTION HORIZONTAL ;
    \\  PITCH 0.2 ;
    \\  WIDTH 0.01 ;
    \\  PROPERTY LEF58_SPACING "SPACING 0.1 ; " ;
    \\END M1
    \\LAYER cut12
    \\  TYPE CUT ;
    \\END cut12
    \\LAYER M2
    \\  TYPE ROUTING ;
    \\  DIRECTION VERTICAL ;
    \\  WIDTH 0.02 ;
    \\END M2
    \\VIA VIA12 DEFAULT
    \\  LAYER M1 ;
    \\    RECT -0.01 -0.01 0.01 0.01 ;
    \\  LAYER cut12 ;
    \\    RECT -0.005 -0.005 0.005 0.005 ;
    \\  LAYER M2 ;
    \\    RECT -0.01 -0.01 0.01 0.01 ;
    \\END VIA12
    \\VIARULE GEN GENERATE
    \\  LAYER M1 ;
    \\    ENCLOSURE 0 0 ;
    \\END GEN
    \\MACRO cell
    \\  CLASS CORE ;
    \\  ORIGIN 0 0 ;
    \\  SIZE 0.004 BY 0.002 ;
    \\  PIN a
    \\    DIRECTION INPUT ;
    \\    PORT
    \\      LAYER M1 ;
    \\        RECT 0 0 0.001 0.001 ;
    \\    END
    \\  END a
    \\  OBS
    \\    LAYER M2 ;
    \\      RECT 0.003 0.001 0.004 0.002 ;
    \\  END
    \\END cell
    \\END LIBRARY
    \\
;

/// One test's arena, diagnostic and the test LEF.
const Fixture = struct {
    arena_state: std.heap.ArenaAllocator,
    diag: Diagnostic = .{},
    lef: Lef = .{},

    fn init() !*Fixture {
        const f = try std.heap.page_allocator.create(Fixture);
        f.* = .{ .arena_state = .init(gpa) };
        try lefdef.readLefInto(f.arena(), lef_text, 1000, &f.lef, &f.diag);
        return f;
    }

    fn deinit(f: *Fixture) void {
        f.arena_state.deinit();
        std.heap.page_allocator.destroy(f);
    }

    fn arena(f: *Fixture) std.mem.Allocator {
        return f.arena_state.allocator();
    }

    /// `body` in a DEF of design `top` at 1000 units per µm.
    fn def(f: *Fixture, body: []const u8) !Def {
        const text = try std.fmt.allocPrint(f.arena(), "VERSION 5.8 ;\nDESIGN top ;\nUNITS DISTANCE MICRONS 1000 ;\nDIEAREA ( 0 0 ) ( 1000 1000 ) ;\n{s}\nEND DESIGN\n", .{body});
        return lefdef.readDef(f.arena(), text, &f.lef, &f.diag) catch |err| {
            std.debug.print("{s} line {d}: {s}\n", .{ f.diag.file, f.diag.line, f.diag.message() });
            return err;
        };
    }

    fn flatten(f: *Fixture, d: *const Def) ![]const FlatShape {
        return lefdef.flatten(f.arena(), d, &f.lef, &f.diag);
    }
};

const Box = struct { []const u8, [4]i64 };

const two_metals =
    \\layer M1 = gds(1, 0)
    \\layer cut12 = gds(2, 0)
    \\layer M2 = gds(3, 0)
    \\connect conductors [M1, M2]
    \\connect via cut12 [M1, M2]
    \\connect label M1 names M1
    \\connect label M2 names M2
    \\
;

// ---- private ----

fn expectBoxes(want: []const Box, got: []const FlatShape) !void {
    try testing.expectEqual(want.len, got.len);
    for (want, got) |w, g| {
        try testing.expectEqualStrings(w[0], g.shape.layer);
        try testing.expectEqual(w[1], g.shape.bbox());
    }
}

fn cuts(a: std.mem.Allocator, rowcol: [2]i64, pattern: []const u8) !?[]const bool {
    const rule: lefdef.ViaRule = .{ .rowcol = rowcol, .pattern = pattern };
    return rule.cuts(a);
}

fn rowBits(a: std.mem.Allocator, rows: []const []const u8) ![]const bool {
    var out: std.ArrayList(bool) = .empty;
    for (rows) |r| for (r) |c| try out.append(a, c == '1');
    return out.items;
}

/// The refusal of `body` in a DEF with no `DESIGN` header.
fn refused(f: *Fixture, body: []const u8) !*const Diagnostic {
    const text = try std.fmt.allocPrint(f.arena(), "UNITS DISTANCE MICRONS 1000 ;\n{s}\nEND DESIGN\n", .{body});
    try testing.expectError(error.Invalid, lefdef.readDef(f.arena(), text, &f.lef, &f.diag));
    return &f.diag;
}

fn says(d: *const Diagnostic, part: []const u8) bool {
    return std.mem.indexOf(u8, d.message(), part) != null;
}

fn lessText(_: void, x: []const u8, y: []const u8) bool {
    return std.mem.order(u8, x, y) == .lt;
}

test "a length converts exactly or not at all" {
    // Oracle: LEF/DEF 5.8 numbers are decimals of micrometres, read exactly
    // at the DEF's units: 0.145 µm at 1000/µm is 145, half a unit is no
    // unit, and 1.5 µm at 2000/µm is 3000.
    try testing.expectEqual(145, exactUnits("0.145", 1000));
    try testing.expectEqual(-3000, exactUnits("-1.5", 2000));
    try testing.expectEqual(500, exactUnits("+.5", 1000));
    try testing.expectEqual(null, exactUnits("0.0005", 1000));
    try testing.expectEqual(null, exactUnits("1e-3", 1000));
    try testing.expectEqual(null, exactUnits("3000000", 1000));
    try testing.expectEqual(null, exactUnits(".", 1000));
}

test "a generated via is the reference's example" {
    // Oracle: the reference's Example 4-36 and Figures 4-25 to 4-27 (5.8
    // pp. 344-345): a 2 × 3 array of 20-unit cuts 30 apart, enclosures 20,
    // 50 (bottom) and 50, 20 (top), has its top metal at (−110, −55)–(110,
    // 55); ORIGIN 10 −10 moves it to (−100, −65)–(120, 45); OFFSET 0 0 20
    // −20 then to (−80, −85)–(140, 25). The bottom metal is (−80, −85)–(80,
    // 85) and the first cut (−60, −35)–(−40, −15).
    const f = try Fixture.init();
    defer f.deinit();
    const head = "VIAS 1 ;\n- v + VIARULE myViaRule + CUTSIZE 20 20 + LAYERS M1 cut12 M2 + CUTSPACING 30 30 + ENCLOSURE 20 50 50 20 + ROWCOL 2 3 ";
    const plain = (try f.def(head ++ ";\nEND VIAS")).vias[0].shapes;
    try testing.expectEqual(2 + 6, plain.len);
    try testing.expectEqual([4]i64{ -80, -85, 80, 85 }, plain[0].bbox());
    try testing.expectEqual([4]i64{ -110, -55, 110, 55 }, plain[1].bbox());
    try testing.expectEqual([4]i64{ -60, -35, -40, -15 }, plain[2].bbox());
    try testing.expectEqual([4]i64{ -100, -65, 120, 45 }, (try f.def(head ++ "+ ORIGIN 10 -10 ;\nEND VIAS")).vias[0].shapes[1].bbox());
    try testing.expectEqual([4]i64{ -80, -85, 140, 25 }, (try f.def(head ++ "+ ORIGIN 10 -10 + OFFSET 0 0 20 -20 ;\nEND VIAS")).vias[0].shapes[1].bbox());
}

test "a cut pattern leaves out the cuts the reference marks" {
    // Oracle: the reference's cut patterns (5.8 pp. 349-351, Figures 4-31
    // and 4-32): `ROWCOL 5 5 PATTERN 2_F0_2_F8_1_78` is, bottom row first,
    // 11110 twice, 11111 twice, then 01111, and `2_F7_2_FF_1_7F` is the
    // same; `ROWCOL 5 14 PATTERN 2_FFE0_3_R4F` is two rows of eleven cuts
    // and three of fourteen. A pattern of the wrong row count is refused.
    const f = try Fixture.init();
    defer f.deinit();
    const a = f.arena();
    const figure_31 = try rowBits(a, &.{ "11110", "11110", "11111", "11111", "01111" });
    try testing.expectEqualSlices(bool, figure_31, (try cuts(a, .{ 5, 5 }, "2_F0_2_F8_1_78")).?);
    try testing.expectEqualSlices(bool, figure_31, (try cuts(a, .{ 5, 5 }, "2_F7_2_FF_1_7F")).?);
    const got = (try cuts(a, .{ 5, 14 }, "2_FFE0_3_R4F")).?;
    for ([_]usize{ 11, 11, 14, 14, 14 }, 0..) |want, row| try testing.expectEqual(want, std.mem.count(bool, got[row * 14 .. (row + 1) * 14], &.{true}));
    try testing.expectEqual(null, try cuts(a, .{ 4, 5 }, "2_F0_2_F8_1_78"));
    try testing.expectEqual(null, try cuts(a, .{ 5, 8 }, "5_F"));
    const d = try f.def("VIAS 1 ;\n- v + VIARULE r + CUTSIZE 10 10 + LAYERS M1 cut12 M2 + CUTSPACING 10 10 + ENCLOSURE 0 0 0 0 + ROWCOL 1 4 + PATTERN 1_A ;\nEND VIAS");
    // 1010: the first and third of four cuts.
    const cut_shapes = d.vias[0].shapes[2..];
    try testing.expectEqual(2, cut_shapes.len);
    try testing.expectEqual([4]i64{ -35, -5, -25, 5 }, cut_shapes[0].bbox());
    try testing.expectEqual([4]i64{ 5, -5, 15, 5 }, cut_shapes[1].bbox());
}

test "a wire extends as the reference draws it" {
    // Oracle: the reference's "Specifying Coordinates" example (5.8 p. 269),
    // `ROUTED M1 ( 0 50 ) ( 50 * 20 ) VIA12 ( * * 15 ) ( * 0 )`: an M1 wire
    // 10 wide from x = 0, extended by half its width (5) at the start and by
    // 20 past the via, and an M2 wire 20 wide from the via down to y = 0,
    // extended 15 past the via and by half its width (10) at the end.
    const f = try Fixture.init();
    defer f.deinit();
    const d = try f.def("NETS 1 ;\n- n + ROUTED M1 ( 0 50 ) ( 50 * 20 ) VIA12 ( * * 15 ) ( * 0 ) ;\nEND NETS");
    const shapes = try f.flatten(&d);
    // The two wires, then the via's three shapes at (50, 50).
    try expectBoxes(&.{
        .{ "M1", .{ -5, 45, 70, 55 } },
        .{ "M2", .{ 40, -10, 60, 65 } },
        .{ "M1", .{ 40, 40, 60, 60 } },
        .{ "cut12", .{ 45, 45, 55, 55 } },
        .{ "M2", .{ 40, 40, 60, 60 } },
    }, shapes);
    for (shapes) |s| try testing.expectEqualStrings("n", s.net.?);
}

test "virtual and rect routing points are the reference's example" {
    // Oracle: the reference's Example 4-12 (5.8 pp. 267-268): `( 0 0 ) ( 5
    // 0 ) VIRTUAL ( 7 1 ) RECT ( -3 0 -1 2 ) ( 7 7 )` draws a wire to (5,
    // 0), no wire to (7, 1), the rectangle (4, 1)–(6, 3), and a wire (7,
    // 1)–(7, 7). A special net of width 2, so its ends are not extended.
    const f = try Fixture.init();
    defer f.deinit();
    const d = try f.def("SPECIALNETS 1 ;\n- s + ROUTED M1 2 ( 0 0 ) ( 5 0 ) VIRTUAL ( 7 1 ) RECT ( -3 0 -1 2 ) ( 7 7 ) ;\nEND SPECIALNETS");
    try expectBoxes(&.{ .{ "M1", .{ 0, -1, 5, 1 } }, .{ "M1", .{ 6, 1, 8, 7 } }, .{ "M1", .{ 4, 1, 6, 3 } } }, try f.flatten(&d));
}

test "every orientation places the pin where the reference says" {
    // Oracle: the reference's placement rule (5.8 p. 244: the lower-left
    // corner of the turned cell lands on the placement point) and its table
    // of orientations as OpenAccess turns, hand-derived for a 4 × 2 macro
    // whose pin is its lower-left unit square, placed at (100, 200).
    const f = try Fixture.init();
    defer f.deinit();
    const cases = [_]struct { []const u8, [4]i64 }{
        .{ "N", .{ 100, 200, 101, 201 } },  .{ "S", .{ 103, 201, 104, 202 } },
        .{ "W", .{ 101, 200, 102, 201 } },  .{ "E", .{ 100, 203, 101, 204 } },
        .{ "FN", .{ 103, 200, 104, 201 } }, .{ "FS", .{ 100, 201, 101, 202 } },
        .{ "FW", .{ 100, 200, 101, 201 } }, .{ "FE", .{ 101, 203, 102, 204 } },
    };
    for (cases) |c| {
        const d = try f.def(try std.fmt.allocPrint(f.arena(), "COMPONENTS 1 ;\n- u1 cell + SOURCE NETLIST + PLACED ( 100 200 ) {s} ;\nEND COMPONENTS\nNETS 1 ;\n- n ( u1 a ) ;\nEND NETS", .{c[0]}));
        const got = try f.flatten(&d);
        try testing.expectEqual(c[1], got[0].shape.bbox());
        try testing.expectEqualStrings("n", got[0].net.?);
        try testing.expectEqual(lefdef.Origin{ .macro_pin = .{ 0, 0 } }, got[0].origin);
        // The obstruction, the upper-right unit square, stays in the cell box.
        const b = got[1].shape.bbox();
        const turned = c[0][c[0].len - 1] == 'W' or c[0][c[0].len - 1] == 'E';
        const w: i64 = if (turned) 2 else 4;
        const h: i64 = if (turned) 4 else 2;
        try testing.expect(b[0] >= 100 and b[1] >= 200 and b[2] <= 100 + w and b[3] <= 200 + h);
        try testing.expectEqual(null, got[1].net);
    }
}

test "a macro origin shifts its geometry first" {
    // Oracle: the reference's macro ORIGIN (5.8 p. 122): "if the ORIGIN is
    // 0, -1, then macro geometry at 0, 1 are shifted to 0, 0, and then
    // aligned to the DEF placement point".
    const f = try Fixture.init();
    defer f.deinit();
    const m = &f.lef.macros.items[0];
    m.origin = .{ 0, -1 };
    const pins = try f.arena().dupe(lefdef.MacroPin, m.pins);
    pins[0].shapes = &.{try Shape.rect(f.arena(), "M1", .{ 0, 1 }, .{ 1, 2 })};
    m.pins = pins;
    const d = try f.def("COMPONENTS 1 ;\n- u1 cell + FIXED ( 10 20 ) N ;\nEND COMPONENTS");
    const got = try f.flatten(&d);
    try testing.expectEqual([4]i64{ 10, 20, 11, 21 }, got[0].shape.bbox());
    try testing.expectEqual(null, got[0].net);
}

test "a pin turns about its placement point" {
    // Oracle: the reference's PINS (5.8 p. 288): a pin's LAYER shape is
    // given about its placement point and turned with it; S turns (−5,
    // 0)–(5, 10) to (−5, −10)–(5, 0), moved to (100, 0). An unplaced port
    // has no shape.
    const f = try Fixture.init();
    defer f.deinit();
    const d = try f.def("PINS 2 ;\n- p + NET n + DIRECTION INPUT + USE SIGNAL\n  + PORT + LAYER M1 ( -5 0 ) ( 5 10 ) + PLACED ( 100 0 ) S ;\n- q + NET m + LAYER M2 ( 0 0 ) ( 1 1 ) ;\nEND PINS");
    try testing.expectEqual([4]i64{ 95, -10, 105, 0 }, d.pins[0].shapes[0].bbox());
    try testing.expectEqual(0, d.pins[1].shapes.len);
}

test "a non-default rule sets the width and taper resets it" {
    // Oracle: the reference's NONDEFAULTRULES and TAPER (5.8 pp. 251, 265):
    // a net under a rule draws its width; `TAPER` goes back to the LEF's.
    const f = try Fixture.init();
    defer f.deinit();
    const d = try f.def("NONDEFAULTRULES 1 ;\n- wide + HARDSPACING + LAYER M1 WIDTH 40 SPACING 10 ;\nEND NONDEFAULTRULES\nNETS 1 ;\n- n + NONDEFAULTRULE wide + ROUTED M1 ( 0 0 ) ( 100 0 ) NEW M1 TAPER ( 0 100 ) ( 100 100 ) ;\nEND NETS");
    try testing.expectEqual(40, d.nets[0].wires[0].width);
    try testing.expectEqual([2]lefdef.Pt{ .{ -20, -20 }, .{ 120, 20 } }, d.nets[0].wires[0].rect());
    try testing.expectEqual(10, d.nets[0].wires[1].width);
}

test "what is not read is refused with its line" {
    // Oracle: the module's refusal list, each from the reference: what the
    // reader does not model is refused at its line, never drawn wrong.
    const f = try Fixture.init();
    defer f.deinit();
    const e = try refused(f, "NETS 1 ;\n- n + ROUTED M1 ( 0 0 ) ( 10 10 ) ;\nEND NETS");
    try testing.expectEqual(3, e.line);
    try testing.expect(says(e, "neither horizontal nor vertical"));
    try testing.expect(says(try refused(f, "NETS 1 ;\n- n + ROUTED M1 ( 0 0 ) ( 10 0 ) nosuchvia ;\nEND NETS"), "nosuchvia"));
    try testing.expect(says(try refused(f, "NETS 1 ;\n- n + ROUTED M1 STYLE 1 ( 0 0 ) ( 10 0 ) ;\nEND NETS"), "STYLE"));
    try testing.expect(says(try refused(f, "NETS 1 ;\n- n + ROUTED cut12 ( 0 0 ) ( 10 0 ) ;\nEND NETS"), "no LEF WIDTH"));
    try testing.expect(says(try refused(f, "COMPONENTS 1 ;\n- u cell + PLACED ( 0 0 ) NE ;\nEND COMPONENTS"), "orientation"));
    var other: Lef = .{};
    try testing.expectError(error.Invalid, lefdef.readLefInto(f.arena(), "MACRO m\n SIZE 1 BY 1 ;\n OBS\n  LAYER M1 ;\n  PATH 0 0 1 0 ;\n END\nEND m\n", 1000, &other, &f.diag));
    try testing.expectEqualStrings("LEF", f.diag.file);
    try testing.expectEqual(5, f.diag.line);
    try testing.expectError(error.Invalid, lefdef.readLefInto(f.arena(), "LAYER M1\n WIDTH 0.0001 ;\nEND M1\n", 1000, &other, &f.diag));
    try testing.expectError(error.Invalid, lefdef.defUnits(f.arena(), "DESIGN x ;", &f.diag));
    try testing.expectEqual(2000, try lefdef.defUnits(f.arena(), "VERSION 5.8 ; UNITS DISTANCE MICRONS 2000 ;", &f.diag));
}

test "the written stream reads back shape for shape" {
    // Oracle: round trip through the GDS reader: the GDSII `toGds` writes is
    // read back by `gds.Library` at the DEF's units, every shape on its
    // layer at its coordinates, and a `TEXT` of the net on each of the five
    // net shapes (the macro pin, two wires, the via's metals; not the
    // obstruction or the cut). The Rust test's second half, binding the
    // labels through `Library::flatten` and `resolve_labels`, waits for
    // wave 2's GeometryStore.
    const f = try Fixture.init();
    defer f.deinit();
    const a = f.arena();
    const d = try f.def("COMPONENTS 1 ;\n- u1 cell + PLACED ( 100 200 ) N ;\nEND COMPONENTS\nNETS 1 ;\n- n ( u1 a ) + ROUTED M1 ( 0 50 ) ( 50 * ) VIA12 ( * 0 ) ;\nEND NETS");
    const shapes = try f.flatten(&d);
    var strings: StrTable = .empty;
    defer strings.deinit(gpa);
    var deck_diag: deck.Diag = .{};
    const parsed = try deck.parseDeck(a, gpa, two_metals, try .init(1000), &strings, &deck_diag);
    const bytes = try lefdef.toGds(gpa, shapes, 1000, "top", &parsed.layers, &parsed.connectivity, &strings, &f.diag);
    defer gpa.free(bytes);
    var gds_diag: gds.Diagnostic = .{};
    var library = try gds.Library.parse(gpa, bytes, &strings, &gds_diag);
    defer library.deinit(gpa);
    try testing.expectEqual(1000, (try library.grid(&gds_diag)).dbu_per_um);
    // Every element back, as `layer xlo ylo xhi yhi`, sorted.
    var read: std.ArrayList([]const u8) = .empty;
    for (0..library.elems.len) |k| {
        const e = library.elems.get(k);
        const xs = library.xs.items[e.vert_start..][0..e.vert_len];
        const ys = library.ys.items[e.vert_start..][0..e.vert_len];
        const layer = parsed.layers.ofStream(e.layer, e.datatype).?;
        const name = strings.resolve(parsed.layers.name(layer));
        try read.append(a, try std.fmt.allocPrint(a, "{s} {d} {d} {d} {d}", .{ name, std.mem.min(i64, xs), std.mem.min(i64, ys), std.mem.max(i64, xs), std.mem.max(i64, ys) }));
    }
    var want: std.ArrayList([]const u8) = .empty;
    for (shapes) |s| {
        const b = s.shape.bbox();
        try want.append(a, try std.fmt.allocPrint(a, "{s} {d} {d} {d} {d}", .{ s.shape.layer, b[0], b[1], b[2], b[3] }));
    }
    std.mem.sort([]const u8, read.items, {}, lessText);
    std.mem.sort([]const u8, want.items, {}, lessText);
    try testing.expectEqual(want.items.len, read.items.len);
    for (want.items, read.items) |w, r| try testing.expectEqualStrings(w, r);
    try testing.expectEqual(5, library.texts.len);
    for (library.texts.items(.string)) |s| try testing.expectEqualStrings("n", strings.resolve(s));
    var no_layer = try a.dupe(FlatShape, shapes);
    no_layer[0].shape.layer = "M9";
    try testing.expectError(error.Invalid, lefdef.toGds(gpa, no_layer, 1000, "top", &parsed.layers, &parsed.connectivity, &strings, &f.diag));
}

test "a pin's antenna statements read as the reference states them" {
    // Oracle: LEF/DEF 5.8 pp. 140-142 ("the ANTENNAMODEL statement does not
    // affect ANTENNAPARTIAL*AREA and ANTENNADIFFAREA"; "if an ANTENNA
    // statement occurs twice for the same oxide model, the last value
    // specified is used"; ANTENNAMAX*CAR takes `LAYER layerName`), the
    // values copied from Example 1-32's statements: the `OXIDE2` gate area
    // and ratio skipped, its partial cut area kept.
    const f = try Fixture.init();
    defer f.deinit();
    const pin_text =
        \\MACRO g
        \\  SIZE 1 BY 1 ;
        \\  PIN IN1
        \\ANTENNADIFFAREA 1.0 ;
        \\ANTENNAMODEL OXIDE1 ;
        \\ANTENNAGATEAREA 1.0 ;
        \\ANTENNAMAXAREACAR 50.0 LAYER m1 ;
        \\ANTENNAMAXAREACAR 60.0 LAYER m1 ;
        \\ANTENNAPARTIALMETALAREA 10.0 LAYER METAL3 ;
        \\ANTENNAMODEL OXIDE2 ;
        \\ANTENNAGATEAREA 3.0 ;
        \\ANTENNAMAXCUTCAR 5.0 LAYER VIA34 ;
        \\ANTENNAPARTIALCUTAREA 0.1 LAYER VIA34 ;
        \\PORT
        \\ LAYER M1 ;
        \\ RECT 0 0 1 1 ;
        \\ END
        \\  END IN1
        \\END g
        \\
    ;
    var lef: Lef = .{};
    try lefdef.readLefInto(f.arena(), pin_text, 1000, &lef, &f.diag);
    const got = lef.macros.items[0].pins[0].antenna;
    const want = [_]struct { lefdef.AntennaKind, f64, ?[]const u8 }{
        .{ .diff, 1.0, null },
        .{ .gate, 1.0, null },
        .{ .max_area_car, 60.0, "m1" },
        .{ .partial_metal, 10.0, "METAL3" },
        .{ .partial_cut, 0.1, "VIA34" },
    };
    try testing.expectEqual(want.len, got.len);
    for (want, got) |w, g| {
        try testing.expectEqual(w[0], g.kind);
        try testing.expectEqual(w[1], g.value);
        if (w[2]) |l| try testing.expectEqualStrings(l, g.layer.?) else try testing.expectEqual(null, g.layer);
    }
    const no_layer = try std.mem.replaceOwned(u8, f.arena(), pin_text, "50.0 LAYER m1", "50.0");
    try testing.expectError(error.Invalid, lefdef.readLefInto(f.arena(), no_layer, 1000, &lef, &f.diag));
    try testing.expect(says(&f.diag, "LAYER"));
}

test "a polygon filling one XY record is written and one vertex more is refused" {
    // Oracle: GDSII stream format, the record header: a record's length is
    // a 16-bit byte count, its 4-byte header included, and a `BOUNDARY`'s
    // `XY` repeats its first point, so an `XY` of n vertices is 8 * (n + 1)
    // + 4 <= 65535 bytes: 8190 vertices are written and read back, 8191 are
    // refused. Breaks if the limit counts the vertices without the closing
    // point.
    const f = try Fixture.init();
    defer f.deinit();
    var strings: StrTable = .empty;
    defer strings.deinit(gpa);
    var deck_diag: deck.Diag = .{};
    const parsed = try deck.parseDeck(f.arena(), gpa, "layer M1 = gds(1, 0)\n", try .init(1000), &strings, &deck_diag);
    for ([_]i64{ 8190, 8191 }) |vertices| {
        const ring = try f.arena().alloc(lefdef.Pt, @intCast(vertices));
        for (ring, 0..) |*p, k| p.* = .{ @intCast(k), @intCast(k % 2) };
        const shape: FlatShape = .{ .shape = .{ .layer = "M1", .ring = ring }, .net = null, .origin = .route };
        const written = lefdef.toGds(gpa, &.{shape}, 1000, "top", &parsed.layers, &parsed.connectivity, &strings, &f.diag);
        if (vertices == 8191) {
            try testing.expectError(error.Invalid, written);
            continue;
        }
        const bytes = try written;
        defer gpa.free(bytes);
        var fresh: StrTable = .empty;
        defer fresh.deinit(gpa);
        var gds_diag: gds.Diagnostic = .{};
        var library = try gds.Library.parse(gpa, bytes, &fresh, &gds_diag);
        library.deinit(gpa);
    }
}
