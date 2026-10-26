//! A DEF layout through the whole run: read with its LEF, drawn on the
//! deck's layers, checked and extracted like a GDS. Ported from
//! tests/engine/def.rs.

const std = @import("std");
const testing = std.testing;
const Allocator = std.mem.Allocator;
const gpurify = @import("gpurify");
const extract = @import("extract");
const ParasiticNetwork = extract.network.ParasiticNetwork;
const gpa = testing.allocator;
const io = testing.io;

/// Two metals and a cut, named as the deck names them.
const lef_head =
    \\VERSION 5.8 ;
    \\UNITS DATABASE MICRONS 1000 ; END UNITS
    \\LAYER met1 TYPE ROUTING ; DIRECTION HORIZONTAL ; WIDTH 0.2 ; END met1
    \\LAYER via1 TYPE CUT ; END via1
    \\LAYER met2 TYPE ROUTING ; DIRECTION VERTICAL ; WIDTH 0.4 ; END met2
    \\VIA V12 DEFAULT
    \\  LAYER met1 ; RECT -0.2 -0.2 0.2 0.2 ;
    \\  LAYER via1 ; RECT -0.1 -0.1 0.1 0.1 ;
    \\  LAYER met2 ; RECT -0.2 -0.2 0.2 0.2 ;
    \\END V12
    \\
;

const lef = lef_head ++ "END LIBRARY\n";

const lef_head_mfg = "VERSION 5.8 ;\nMANUFACTURINGGRID 0.005 ;\n" ++ lef_head["VERSION 5.8 ;\n".len..];

/// The LEF's layers, a width rule on met1, and the stack.
const deck =
    \\grid 1nm
    \\extraction rcc coupling_halo 10
    \\layer met1 = gds(1, 0)
    \\layer via1 = gds(2, 0)
    \\layer met2 = gds(3, 0)
    \\rule m1.w width(met1) >= 300nm
    \\connect conductors [met1, met2]
    \\connect touch_within_layer
    \\connect via via1 [met1, met2]
    \\connect label met1 names met1
    \\connect label met2 names met2
    \\pex met1 thickness 100nm height 1000nm sheet 0.1ohm dielectric 3.9 area_cap 30aF/um2 fringe_cap 40aF/um
    \\pex via1 thickness 100nm height 1100nm sheet 2ohm dielectric 3.9 area_cap 0aF/um2 fringe_cap 0aF/um
    \\pex met2 thickness 100nm height 1200nm sheet 0.05ohm dielectric 3.9 area_cap 20aF/um2 fringe_cap 30aF/um
    \\
;

const tap_lef =
    \\VERSION 5.8 ;
    \\UNITS DATABASE MICRONS 1000 ; END UNITS
    \\LAYER tap TYPE ROUTING ; WIDTH 1 ; END tap
    \\END LIBRARY
    \\
;

/// The LEF, the deck and a DEF written to a temporary directory.
const Case = struct {
    tmp: testing.TmpDir,
    arena_state: std.heap.ArenaAllocator,
    inputs: gpurify.Inputs = .{ .layout = "top.def", .deck = "top.deck", .lef = &.{"tech.lef"} },

    /// Takes `def` (owned; freed here) and writes the three files.
    fn init(def: []u8, lef_text: []const u8, deck_text: []const u8) !Case {
        defer gpa.free(def);
        var c: Case = .{ .tmp = testing.tmpDir(.{}), .arena_state = .init(gpa) };
        errdefer c.deinit();
        try c.tmp.dir.writeFile(io, .{ .sub_path = "top.def", .data = def });
        try c.tmp.dir.writeFile(io, .{ .sub_path = "top.deck", .data = deck_text });
        try c.tmp.dir.writeFile(io, .{ .sub_path = "tech.lef", .data = lef_text });
        return c;
    }

    fn deinit(c: *Case) void {
        c.arena_state.deinit();
        c.tmp.cleanup();
    }

    fn arena(c: *Case) Allocator {
        return c.arena_state.allocator();
    }

    fn run(c: *Case, checks: gpurify.Checks) !gpurify.Run {
        var diag: gpurify.RunDiagnostic = .{};
        return gpurify.run(gpa, c.arena(), io, c.tmp.dir, c.inputs, .{ .checks = checks }, &.{}, &diag);
    }

    const Substrate = struct { spef: []const u8, dspf: []const u8, resistors: []const struct { u1, f64 } };

    /// PEX, both writers, and every substrate resistor: (to ground, ohms).
    fn substrate(c: *Case) !Substrate {
        const r = try c.run(.{ .pex = true });
        const network = &r.outputs.parasitics.?;
        const header: gpurify.@"export".Header = .{ .tool_version = "test", .deck_path = "top.deck", .layout_path = "top.def" };
        var wdiag: gpurify.@"export".Diagnostic = .{};
        var spef: std.Io.Writer.Allocating = .init(c.arena());
        try gpurify.@"export".spef.writeSpef(&spef.writer, c.arena(), network, &r.extracted.ports, &r.loaded.strings, &header, &wdiag);
        var dspf: std.Io.Writer.Allocating = .init(c.arena());
        try gpurify.@"export".dspf.writeDspf(&dspf.writer, c.arena(), network, &r.extracted.ports, &r.loaded.strings, &header, &wdiag);
        var out: std.ArrayList(struct { u1, f64 }) = .empty;
        for (network.to.items, network.kind.items, network.value.items) |to, k, v| if (k == .substrate_resistance) try out.append(c.arena(), .{ @intFromBool(to == .ground), v });
        return .{ .spef = spef.written(), .dspf = dspf.written(), .resistors = out.items };
    }
};

/// Pin A (G1) and pin B (G2) report at their pins' centres.
const pin_a: [2]i64 = .{ 5600, 1500 };

const pin_b: [2]i64 = .{ 10100, 1600 };

/// Appendix C's Figure C-20 at the top level, its gates behind macro pins
/// (cell A's pin A, G1; cell B's pin B, G2 with diode D1), `extra` added
/// to pin A; ERC on it with Example 1's and Example 2's rows.
const C20 = struct {
    case: Case,
    found: []const Finding,
    erc: gpurify.StageStatus,

    const Finding = struct { rule: []const u8, ratio: f64, at: [2]i64 };

    fn init(extra: []const u8) !C20 {
        const all = "met1, via1, met2, via2, met3";
        const lib = try std.fmt.allocPrint(gpa,
            \\VERSION 5.8 ;
            \\UNITS DATABASE MICRONS 1000 ; END UNITS
            \\LAYER met1 TYPE ROUTING ; WIDTH 0.2 ; END met1
            \\LAYER via1 TYPE CUT ; END via1
            \\LAYER met2 TYPE ROUTING ; WIDTH 0.2 ; END met2
            \\LAYER via2 TYPE CUT ; END via2
            \\LAYER met3 TYPE ROUTING ; WIDTH 0.2 ; END met3
            \\MACRO CELLA
            \\  CLASS CORE ;
            \\  ORIGIN 0 0 ;
            \\  SIZE 1 BY 1 ;
            \\  PIN A
            \\    DIRECTION INPUT ;
            \\    ANTENNAGATEAREA 1.0 LAYER met1 ;
            \\    ANTENNAMAXAREACAR 1.0 LAYER met1 ;
            \\{s}    PORT
            \\      LAYER met1 ;
            \\        RECT 0 0 0.2 0.2 ;
            \\    END
            \\  END A
            \\END CELLA
            \\MACRO CELLB
            \\  CLASS CORE ;
            \\  ORIGIN 0 0 ;
            \\  SIZE 1 BY 1 ;
            \\  PIN B
            \\    DIRECTION INPUT ;
            \\    ANTENNAGATEAREA 2.0 LAYER met1 ;
            \\    ANTENNADIFFAREA 0.5 LAYER met1 ;
            \\    ANTENNAMAXAREACAR 1.0 LAYER met1 ;
            \\    PORT
            \\      LAYER met1 ;
            \\        RECT 0 0 0.2 0.2 ;
            \\    END
            \\  END B
            \\END CELLB
            \\END LIBRARY
            \\
        , .{extra});
        defer gpa.free(lib);
        const d = try std.fmt.allocPrint(gpa,
            \\grid 1nm
            \\extraction rcc coupling_halo 10
            \\layer met1 = gds(1, 0)
            \\layer via1 = gds(2, 0)
            \\layer met2 = gds(3, 0)
            \\layer via2 = gds(4, 0)
            \\layer met3 = gds(5, 0)
            \\layer gate = gds(6, 0)
            \\layer dio = gds(7, 0)
            \\connect conductors [met1, met2, met3]
            \\connect touch_within_layer
            \\connect via via1 [met1, met2]
            \\connect via via2 [met2, met3]
            \\connect label met1 names met1
            \\connect label met2 names met2
            \\connect label met3 names met3
            \\{s}{s}{s}rule par1 antenna(gate, met1; max_ratio: 1e-6, sidewall: none, diode: none, diode_area: none, diode_min: none)
            \\rule par2 antenna(gate, met2; max_ratio: 1e-6, sidewall: none, diode: none, diode_area: none, diode_min: none)
            \\
        , .{ electrical("ex1", all, "none", "0"), electrical("ex2", all, "dio", "100"), electrical("ex2v1", "met1, via1", "dio", "100") });
        defer gpa.free(d);
        var c: C20 = .{ .case = try .init(try gpa.dupe(u8, c20_def), lib, d), .found = &.{}, .erc = .ran };
        errdefer c.case.deinit();
        const r = try c.case.run(.{ .erc = true });
        var found: std.ArrayList(Finding) = .empty;
        for (0..r.outputs.violations.len()) |k| {
            const v = r.outputs.violations.get(@intCast(k));
            try found.append(c.case.arena(), .{ .rule = r.loaded.strings.resolve(v.rule), .ratio = v.measured.float(), .at = .{ v.at.x, v.at.y } });
        }
        c.found = found.items;
        c.erc = r.summary.erc;
        return c;
    }

    fn deinit(c: *C20) void {
        c.case.deinit();
    }

    fn expectRatio(c: *const C20, rule: []const u8, at: [2]i64, want: f64) !void {
        for (c.found) |f| if (std.mem.eql(u8, f.rule, rule) and f.at[0] == at[0] and f.at[1] == at[1]) {
            return testing.expect(@abs(f.ratio - want) < 1e-9 * want);
        };
        std.debug.print("{s} at ({d}, {d}) not found\n", .{ rule, at[0], at[1] });
        return error.TestRatioMissing;
    }

    fn count(c: *const C20, rule: []const u8) usize {
        var n: usize = 0;
        for (c.found) |f| n += @intFromBool(std.mem.eql(u8, f.rule, rule));
        return n;
    }
};

/// Figure C-20's metal and cuts: M1,1 = 1, M1,2 = 2, M1,3 = 3, M2,1 = 4,
/// M2,2 = 5, M3,1 = 6, M3,2 = 9 µm², every cut 0.1 µm²; pins A and B
/// inside M1,2 and M1,3, adding no area.
const c20_def =
    \\VERSION 5.8 ;
    \\DESIGN top ;
    \\UNITS DISTANCE MICRONS 1000 ;
    \\DIEAREA ( 0 0 ) ( 20000 20000 ) ;
    \\COMPONENTS 2 ;
    \\- a CELLA + PLACED ( 5500 1400 ) N ;
    \\- b CELLB + PLACED ( 10000 1500 ) N ;
    \\END COMPONENTS
    \\SPECIALNETS 1 ;
    \\- n ( a A ) ( b B )
    \\+ RECT met1 ( 4000 1250 ) ( 8000 1750 ) + RECT met1 ( 1000 1250 ) ( 2000 2250 )
    \\+ RECT met1 ( 9000 1250 ) ( 12000 2250 )
    \\+ RECT via1 ( 4750 1400 ) ( 5150 1650 ) + RECT via1 ( 7000 1400 ) ( 7400 1650 )
    \\+ RECT via1 ( 1300 1600 ) ( 1700 1850 ) + RECT via1 ( 9200 1900 ) ( 9600 2150 )
    \\+ RECT met2 ( 1200 1400 ) ( 5200 2400 ) + RECT met2 ( 6900 1300 ) ( 11900 2300 )
    \\+ RECT via2 ( 2000 1900 ) ( 2400 2150 ) + RECT via2 ( 8000 1900 ) ( 8400 2150 )
    \\+ RECT met3 ( 1000 1400 ) ( 4000 3400 ) + RECT met3 ( 7000 1300 ) ( 10000 4300 ) ;
    \\END SPECIALNETS
    \\END DESIGN
    \\
;

// ---- private ----

fn tapDeck(comptime backside: []const u8) []const u8 {
    return
    \\grid 1nm
    \\extraction rcc coupling_halo 10
    \\layer tap = gds(1, 0)
    \\connect conductors [tap]
    \\connect touch_within_layer
    \\connect label tap names tap
    \\pex tap thickness 100nm height 0nm sheet 1ohm dielectric 3.9 area_cap 0aF/um2 fringe_cap 0aF/um
    \\
    ++ "pex_substrate ports [tap] backside " ++ backside ++ " profile [(2um, 1), (5um, 10)]\n";
}

/// A 200 µm die holding `nets`, owned by the caller.
fn design(gpa_: Allocator, nets: []const u8) ![]u8 {
    return std.fmt.allocPrint(gpa_, "VERSION 5.8 ;\nDESIGN top ;\nUNITS DISTANCE MICRONS 1000 ;\nDIEAREA ( 0 0 ) ( 200000 200000 ) ;\n{s}\nEND DESIGN\n", .{nets});
}

fn runRow(r: *const gpurify.Run, name: []const u8) @import("check").report.RuleRun {
    const id = r.loaded.strings.get(name).?;
    for (r.outputs.runs.items) |run| if (run.rule == id) return run;
    unreachable;
}

/// The lengths `rule` measured, in report order.
fn lengths(arena: Allocator, r: *const gpurify.Run, rule: []const u8) ![]const i128 {
    const id = r.loaded.strings.get(rule).?;
    var out: std.ArrayList(i128) = .empty;
    for (0..r.outputs.violations.len()) |k| {
        const v = r.outputs.violations.get(@intCast(k));
        if (v.rule == id) try out.append(arena, v.measured.exact());
    }
    return out.items;
}

/// One `antenna_electrical` row over `collectors`, flagging every ratio
/// above a millionth.
fn electrical(comptime id: []const u8, comptime collectors: []const u8, comptime diode: []const u8, comptime minus: []const u8) []const u8 {
    return "rule " ++ id ++ " antenna_electrical(gate, " ++ collectors ++ "; max_ratio: 1e-6, sidewall: none, cut_factor: 10, diode: " ++ diode ++ ", diode_credit: 0, diode_bonus: 0, area_minus_diode: " ++ minus ++ ", gate_plus_diode: 0, diode_reduce: none, diode_max_ratio: none, exempt: none)\n";
}

test "a def wire extracts to its closed form and is checked" {
    // Oracle: closed form. Net `a` is one met1 wire 0.2 µm wide extended
    // 0.1 µm past each end (LEF/DEF 5.8 p. 268): a 100.2 × 0.2 µm bar.
    // R = 0.1 Ω/□ · 100.2 / 0.2 = 50.1 Ω and C = 30 aF/µm² · 20.04 µm² +
    // 40 aF/µm · 200.8 µm = 8.6332 fF (Weste & Harris ch. 6). At 0.2 µm it
    // is under the 0.3 µm width rule: one finding.
    var c: Case = try .init(try design(gpa, "NETS 1 ;\n- a + ROUTED met1 ( 0 0 ) ( 100000 0 ) ;\nEND NETS"), lef, deck);
    defer c.deinit();
    const r = try c.run(.{ .drc = true, .pex = true });
    const net = r.extracted.ports.netOf(r.loaded.strings.get("a").?).?;
    const network = r.outputs.parasitics.?;
    var ohms: f64 = 0;
    for (network.from.items, network.kind.items, network.value.items) |from, k, v| {
        if (k == .resistance and network.node_net.items[@backingInt(from)] == @backingInt(net)) ohms += v;
    }
    try testing.expectApproxEqAbs(50.1, ohms, 1e-9);
    var per_net: std.ArrayList(f64) = .empty;
    try network.capacitancePerNetInto(c.arena(), &per_net);
    try testing.expectApproxEqAbs(8.6332, per_net.items[@backingInt(net)], 1e-9);
    try testing.expectEqual(1, r.outputs.violations.len());
    try testing.expectEqualStrings("m1.w", r.loaded.strings.resolve(r.outputs.violations.rule.items[0]));
}

test "every integration fault planted in a def is found" {
    // Oracle: construct-from-answer, each fault planted by its definition
    // (integration.zig): of three fills one is inside the die, one crosses
    // its edge, one is outside (2); block b2 overlaps b1 by 2 × 2 µm and b3
    // runs past the die; core cell c2 sits 10 nm off its row's site pitch;
    // pin q is 50 nm off met1's tracks; one special wire starts 3 nm off
    // the 5 nm manufacturing grid.
    const lib = try std.mem.concat(gpa, u8, &.{
        lef_head_mfg,
        \\SITE core CLASS CORE ; SIZE 0.2 BY 2 ; END core
        \\MACRO blk CLASS BLOCK ; SIZE 5 BY 5 ; OBS LAYER met2 ; RECT 0 0 5 5 ; END END blk
        \\MACRO inv CLASS CORE ; SIZE 0.4 BY 2 ; SITE core ; END inv
        \\MACRO bump CLASS COVER BUMP ; SIZE 5 BY 5 ; END bump
        \\END LIBRARY
        \\
    });
    var c: Case = try .init(try design(gpa,
        \\ROW r0 core 0 10000 N DO 50 BY 1 STEP 200 0 ;
        \\TRACKS Y 100 DO 100 STEP 200 LAYER met1 ;
        \\COMPONENTS 6 ;
        \\- b1 blk + FIXED ( 1000 1000 ) N ;
        \\- b2 blk + PLACED ( 4000 4000 ) N ;
        \\- b3 blk + PLACED ( 196000 1000 ) N ;
        \\- bp bump + COVER ( 1000 1000 ) N ;
        \\- c1 inv + PLACED ( 400 10000 ) N ;
        \\- c2 inv + PLACED ( 1010 10000 ) FN ;
        \\END COMPONENTS
        \\PINS 2 ;
        \\- p + NET p + LAYER met1 ( -100 -100 ) ( 100 100 ) + PLACED ( 50000 10100 ) N ;
        \\- q + NET q + LAYER met1 ( -100 -100 ) ( 100 100 ) + PLACED ( 50000 10150 ) N ;
        \\END PINS
        \\SPECIALNETS 1 ;
        \\- v + ROUTED met2 400 ( 1003 150000 ) ( 2005 150000 ) ;
        \\END SPECIALNETS
        \\FILLS 3 ;
        \\- LAYER met2 RECT ( 100000 100000 ) ( 101000 101000 ) ;
        \\- LAYER met2 RECT ( 199000 100000 ) ( 201000 101000 ) ;
        \\- LAYER met2 RECT ( 300000 0 ) ( 301000 1000 ) ;
        \\END FILLS
    ), lib, deck);
    gpa.free(lib);
    defer c.deinit();
    const r = try c.run(.{ .drc = true });
    const rows = [_]struct { []const u8, u64, u32 }{
        .{ "def.fill_outside_die", 3, 2 },
        .{ "def.component_outside_die", 6, 1 },
        // The COVER bump over b1 is no overlap; b1 and b2 are.
        .{ "def.component_overlap", 5, 1 },
        .{ "def.off_site", 2, 1 },
        .{ "def.pin_off_track", 2, 1 },
    };
    for (rows) |row| {
        const rr = runRow(&r, row[0]);
        try testing.expectEqual(row[1], rr.examined);
        try testing.expectEqual(row[2], rr.violations);
    }
    try testing.expectEqual(1, runRow(&r, "def.off_manufacturing_grid").violations);
    const overlap = r.loaded.strings.get("def.component_overlap").?;
    const at = std.mem.findScalar(@TypeOf(overlap), r.outputs.violations.rule.items, overlap).?;
    try testing.expect(r.outputs.violations.get(@intCast(at)).measured.eql(.area(2000 * 2000)));
}

test "a top-level wire is checked against a block abstract" {
    // Oracle: construct-from-answer (FLOW-004): block b's met2 obstruction
    // over (0, 0)-(5, 5) µm placed at (10, 10) µm; a met2 wire 0.1 µm from
    // its right edge breaks a 0.2 µm spacing (one finding at 100 nm); two
    // met1 wires 0.15 µm wide, one ending on the pin, break only the 0.3 µm
    // width rule (two findings at 150 nm, neither on the 0.4 µm pin).
    const lib = try std.mem.concat(gpa, u8, &.{
        lef_head,
        \\MACRO blk CLASS BLOCK ; SIZE 5 BY 5 ;
        \\PIN A DIRECTION INPUT ; PORT LAYER met1 ; RECT 4.8 2 5 2.4 ; END END A
        \\OBS LAYER met2 ; RECT 0 0 5 5 ; END END blk
        \\END LIBRARY
        \\
    });
    const d = try std.mem.replaceOwned(u8, gpa, deck, "rule m1.w", "rule m2.s space(met2) >= 200nm\nrule m1.w");
    var c: Case = try .init(try design(gpa,
        \\COMPONENTS 1 ;
        \\- b blk + FIXED ( 10000 10000 ) N ;
        \\END COMPONENTS
        \\SPECIALNETS 2 ;
        \\- v + ROUTED met2 400 ( 15300 10000 ) ( 15300 15000 ) ;
        \\- w + ROUTED met1 150 ( 14800 12100 ) ( 18000 12100 ) NEW met1 150 ( 16000 9000 ) ( 18000 9000 ) ;
        \\END SPECIALNETS
    ), lib, d);
    gpa.free(lib);
    gpa.free(d);
    defer c.deinit();
    const r = try c.run(.{ .drc = true });
    try testing.expectEqualDeep(@as([]const i128, &.{100}), try lengths(c.arena(), &r, "m2.s"));
    try testing.expectEqualDeep(@as([]const i128, &.{ 150, 150 }), try lengths(c.arena(), &r, "m1.w"));
}

test "fill between two plates is in series, grounded or gone" {
    // Oracle: closed form. Net a on met1, a fill piece on fillm and net b on
    // met2, 10 × 10 µm stacked 0.1 µm apart in k = 3.9: each gap a parallel
    // plate C₁ = ε₀k·100 µm²/0.1 µm, a–b directly C₁/3. Floating fill puts
    // a–fill and fill–b in series: a–b is C₁/3 + C₁/2; grounded, C₁/3 and
    // each plate gains C₁ to ground; ignored, C₁/3. Only nets a and b remain.
    const lib = try std.mem.concat(gpa, u8, &.{ lef_head, "LAYER fillm TYPE ROUTING ; DIRECTION HORIZONTAL ; WIDTH 0.2 ; END fillm\nEND LIBRARY\n" });
    defer gpa.free(lib);
    const c1 = 8.8541878128 * 3.9 * 100.0 / 0.1 / 1000.0;
    for ([_]struct { []const u8, f64, f64 }{ .{ "floating", c1 / 3.0 + c1 / 2.0, 0 }, .{ "grounded", c1 / 3.0, c1 }, .{ "ignored", c1 / 3.0, 0 } }) |row| {
        const d = try std.fmt.allocPrint(gpa,
            \\grid 1nm
            \\extraction rcc coupling_halo 10
            \\layer met1 = gds(1, 0)
            \\layer via1 = gds(2, 0)
            \\layer met2 = gds(3, 0)
            \\layer fillm = gds(4, 0)
            \\connect conductors [met1, fillm, met2]
            \\connect touch_within_layer
            \\connect via via1 [met1, met2]
            \\connect label met1 names met1
            \\connect label met2 names met2
            \\pex met1 thickness 100nm height 1000nm sheet 0.1ohm dielectric 3.9 area_cap 0aF/um2 fringe_cap 0aF/um
            \\pex fillm thickness 100nm height 1200nm sheet 0.1ohm dielectric 3.9 area_cap 0aF/um2 fringe_cap 0aF/um
            \\pex met2 thickness 100nm height 1400nm sheet 0.1ohm dielectric 3.9 area_cap 0aF/um2 fringe_cap 0aF/um
            \\pex via1 thickness 100nm height 1100nm sheet 2ohm dielectric 3.9 area_cap 0aF/um2 fringe_cap 0aF/um
            \\pex_fill fillm {s}
            \\
        , .{row[0]});
        defer gpa.free(d);
        var c: Case = try .init(try design(gpa,
            \\SPECIALNETS 2 ;
            \\- a + RECT met1 ( 0 0 ) ( 10000 10000 ) ;
            \\- b + RECT met2 ( 0 0 ) ( 10000 10000 ) ;
            \\END SPECIALNETS
            \\FILLS 1 ;
            \\- LAYER fillm RECT ( 0 0 ) ( 10000 10000 ) ;
            \\END FILLS
        ), lib, d);
        defer c.deinit();
        const r = try c.run(.{ .pex = true });
        const network = r.outputs.parasitics.?;
        const a = @backingInt(r.extracted.ports.netOf(r.loaded.strings.get("a").?).?);
        const b = @backingInt(r.extracted.ports.netOf(r.loaded.strings.get("b").?).?);
        // Rust's `dedup` of the node column: runs of one net count once.
        var nets: std.ArrayList(u32) = .empty;
        for (network.node_net.items) |n| if (nets.items.len == 0 or nets.items[nets.items.len - 1] != n) try nets.append(c.arena(), n);
        try testing.expectEqualSlices(u32, &.{ @min(a, b), @max(a, b) }, nets.items);
        var cc: f64 = 0;
        var ga: f64 = 0;
        for (network.from.items, network.kind.items, network.value.items) |from, k, v| switch (k) {
            .coupling_cap => cc += v,
            .ground_cap => if (network.node_net.items[@backingInt(from)] == a) {
                ga += v;
            },
            else => {},
        };
        try testing.expect(@abs(cc - row[1]) < 1e-9 * row[1]);
        try testing.expect(@abs(ga - row[2]) < 1e-9 * c1);
    }
}

test "point to point resistance and net coupling are reported" {
    // Oracle: closed forms (PEX-016). Between x = 10 and 60 µm along a
    // 0.2 µm wire of 0.1 Ω/□ the resistance is 0.1 · 50 / 0.2 = 25 Ω (0
    // from a point to itself); the wires, 100.2 µm long and 0.8 µm apart in
    // k = 3.9 with met1 0.1 µm thick, couple by ε₀ k t L / S (Weste &
    // Harris ch. 6). A point off the net, and a net the layout lacks, refuse.
    const d = try std.mem.concat(gpa, u8, &.{
        deck,
        \\report p2p "a" at [(10um, 0um), (60um, 50nm), (10um, 0um)]
        \\report p2p "a" at [(10um, 0.5um), (20um, 0um)]
        \\report coupling "a" "b"
        \\report coupling "a" "zz"
        \\
    });
    var c: Case = try .init(try design(gpa,
        \\NETS 2 ;
        \\- a + ROUTED met1 ( 0 0 ) ( 100000 0 ) ;
        \\- b + ROUTED met1 ( 0 1000 ) ( 100000 1000 ) ;
        \\END NETS
    ), lef, d);
    gpa.free(d);
    defer c.deinit();
    const a = c.arena();
    const r = try c.run(.{ .pex = true });
    const reports = &r.loaded.deck.deck.reports;
    var pairs: std.ArrayList(gpurify.p2p.Pair) = .empty;
    var why: []const u8 = "";
    try gpurify.p2p.resistanceInto(a, a, &r.loaded, &r.extracted, reports.p2p.items[0].net, reports.p2p.items[0].points, &pairs, &why);
    try testing.expectEqual(3, pairs.items.len);
    try testing.expectApproxEqAbs(25.0, pairs.items[0].ohms, 1e-9);
    try testing.expectEqual(gpurify.p2p.Pair{ .i = 0, .j = 2, .ohms = 0 }, pairs.items[1]);
    const network = &r.outputs.parasitics.?;
    const got = try gpurify.p2p.coupling(a, &r.loaded, &r.extracted, network, reports.coupling.items[0].a, reports.coupling.items[0].b, &why);
    try testing.expectApproxEqAbs(8.8541878128 * 3.9 * 0.1 * 100.2 / 0.8 / 1000.0, got, 1e-9);
    pairs.clearRetainingCapacity();
    try testing.expectError(error.Refused, gpurify.p2p.resistanceInto(a, a, &r.loaded, &r.extracted, reports.p2p.items[1].net, reports.p2p.items[1].points, &pairs, &why));
    try testing.expect(std.mem.indexOf(u8, why, "no conducting shape") != null);
    try testing.expectError(error.Refused, gpurify.p2p.coupling(a, &r.loaded, &r.extracted, network, reports.coupling.items[1].a, reports.coupling.items[1].b, &why));
}

test "a through-silicon via adds its liner capacitance" {
    // Oracle: closed form (Katti et al., IEEE TED 57(1), 2010, eq. 2): a 5 ×
    // 5 µm cut is a cylinder of radius 5/√π µm; 50 µm long in a 0.2 µm liner
    // of k = 3.9 it is 2π ε₀ k L / ln((r + t) / r) to ground, two of them
    // twice that; the plates carry no capacitance of their own.
    const tsv_lef =
        \\VERSION 5.8 ;
        \\UNITS DATABASE MICRONS 1000 ; END UNITS
        \\LAYER met1 TYPE ROUTING ; WIDTH 0.2 ; END met1
        \\LAYER tsv TYPE CUT ; END tsv
        \\LAYER bm TYPE ROUTING ; WIDTH 1 ; END bm
        \\VIA T1 LAYER met1 ; RECT -3 -3 3 3 ; LAYER tsv ; RECT -2.5 -2.5 2.5 2.5 ;
        \\LAYER bm ; RECT -3 -3 3 3 ; END T1
        \\END LIBRARY
        \\
    ;
    const tsv_deck =
        \\grid 1nm
        \\extraction rcc coupling_halo 10
        \\layer met1 = gds(1, 0)
        \\layer tsv = gds(2, 0)
        \\layer bm = gds(3, 0)
        \\connect conductors [met1, bm]
        \\connect touch_within_layer
        \\connect via tsv [met1, bm]
        \\connect label met1 names met1
        \\connect label bm names bm
        \\pex met1 thickness 100nm height 1000nm sheet 0.1ohm dielectric 3.9 area_cap 0aF/um2 fringe_cap 0aF/um
        \\pex tsv thickness 100nm height 1100nm sheet 0.05ohm dielectric 3.9 area_cap 0aF/um2 fringe_cap 0aF/um
        \\pex bm thickness 100nm height 1200nm sheet 0.1ohm dielectric 3.9 area_cap 0aF/um2 fringe_cap 0aF/um
        \\pex_tsv tsv length 50um liner 200nm liner_k 3.9
        \\
    ;
    var c: Case = try .init(try design(gpa,
        \\SPECIALNETS 1 ;
        \\- t + RECT met1 ( 7000 7000 ) ( 33000 13000 ) + VIA T1 ( 10000 10000 ) ( 30000 10000 ) ;
        \\END SPECIALNETS
    ), tsv_lef, tsv_deck);
    defer c.deinit();
    const r = try c.run(.{ .pex = true });
    const net = r.extracted.ports.netOf(r.loaded.strings.get("t").?).?;
    var per_net: std.ArrayList(f64) = .empty;
    try r.outputs.parasitics.?.capacitancePerNetInto(c.arena(), &per_net);
    const radius = 5.0 / @sqrt(std.math.pi);
    const one = 2.0 * std.math.pi * 8.8541878128e-3 * 3.9 * 50.0 / @log((radius + 0.2) / radius);
    try testing.expect(@abs(per_net.items[@backingInt(net)] - 2.0 * one) < 1e-9 * one);
}

test "a def on a layer the deck lacks is refused" {
    // Oracle: `load`'s documented errors (the lefdef stage) and
    // `lefdef.toGds`'s refusal of a layer the deck lacks; an unreadable LEF
    // names its path.
    var c: Case = try .init(try design(gpa, "SPECIALNETS 1 ;\n- p + ROUTED met3 1000 ( 0 0 ) ( 1000 0 ) ;\nEND SPECIALNETS"), lef, deck);
    defer c.deinit();
    var diag: gpurify.LoadDiagnostic = .{};
    try testing.expectError(error.Invalid, gpurify.load(gpa, c.arena(), io, c.tmp.dir, c.inputs, &.{}, &diag));
    try testing.expectEqual(.lefdef, diag.stage);
    try testing.expect(std.mem.indexOf(u8, diag.lefdef.message(), "met3") != null);
    var missing = c.inputs;
    missing.lef = &.{"/nonexistent/tech.lef"};
    try testing.expectError(error.Unreadable, gpurify.load(gpa, c.arena(), io, c.tmp.dir, missing, &.{}, &diag));
    try testing.expectEqualStrings("/nonexistent/tech.lef", diag.path);
}

test "a tap over a layered substrate is its series resistance in spef and dspf" {
    // Oracle: closed form (Ohm's law, PEX-013): the die is the tap's 10 × 10
    // µm, so the current runs straight down through 2 µm of 1 Ω·cm and 5 µm
    // of 10 Ω·cm, (2·10⁴ + 5·10⁵) Ω·µm / 100 µm² = 5200 Ω; SPEF carries it
    // as a comment, DSPF as an R card to node 0.
    var c: Case = try .init(try design(gpa, "SPECIALNETS 1 ;\n- vss + RECT tap ( 0 0 ) ( 10000 10000 ) ;\nEND SPECIALNETS"), tap_lef, tapDeck("grounded"));
    defer c.deinit();
    const s = try c.substrate();
    try testing.expectEqual(1, s.resistors.len);
    try testing.expect(s.resistors[0][0] == 1);
    try testing.expect(@abs(s.resistors[0][1] - 5200.0) < 1e-9 * 5200.0);
    try testing.expect(std.mem.indexOf(u8, s.spef, "// substrate vss:0 0 5200") != null);
    try testing.expect(std.mem.indexOf(u8, s.dspf, "R1 vss:0 0 5200") != null);
}

test "two taps on a floating backside are one resistor between their nets" {
    // Oracle: the model's definition (extract.substrate): with no backside
    // contact every current leaves through another port, so the network is
    // the one conductance between the two ports.
    var c: Case = try .init(try design(gpa, "SPECIALNETS 2 ;\n- a + RECT tap ( 0 0 ) ( 2000 2000 ) ;\n- b + RECT tap ( 8000 0 ) ( 10000 2000 ) ;\nEND SPECIALNETS"), tap_lef, tapDeck("floating"));
    defer c.deinit();
    const s = try c.substrate();
    try testing.expectEqual(1, s.resistors.len);
    try testing.expect(s.resistors[0][0] == 0 and s.resistors[0][1] > 0);
    try testing.expect(std.mem.indexOf(u8, s.spef, "// substrate a:0 b:0 ") != null);
    var lines = std.mem.splitScalar(u8, s.dspf, '\n');
    const card = while (lines.next()) |l| (if (l.len > 0 and l[0] == 'R' and std.mem.indexOf(u8, l, " a:0 b:0 ") != null) break true) else false;
    try testing.expect(card);
}

test "macro pin antenna data follows lef appendix c examples 1 and 2" {
    // Oracle: LEF/DEF 5.8 Appendix C, Examples 1 and 2 hand-derived (cut
    // factor 10): G1's CAR is pin A's 1.0 plus 2/1, 10·0.2/1, 9/3, 10·0.2/3
    // and 15/3: 13⅔; G2's is pin B's 1.0 plus 3/2, 10·0.1/2, 3, ⅔ and 5:
    // 11⅔. Single-layer rows are PARs: 2.0 and 1.5 at met1, 3.0 at met2.
    // Example 2 subtracts 100 × diff: G1 is still 5.0 through via1, every
    // later sum truncates to 0, and G2 is 0 from met1 on.
    var c: C20 = try .init("");
    defer c.deinit();
    try testing.expect(c.erc == .ran);
    try c.expectRatio("ex1", pin_a, 13.0 + 2.0 / 3.0);
    try c.expectRatio("ex1", pin_b, 11.0 + 2.0 / 3.0);
    try c.expectRatio("par1", pin_a, 2.0);
    try c.expectRatio("par1", pin_b, 1.5);
    try c.expectRatio("par2", pin_a, 3.0);
    try c.expectRatio("ex2v1", pin_a, 5.0);
    try testing.expectEqual(0, c.count("ex2"));
    try testing.expectEqual(1, c.count("ex2v1"));
    try testing.expectEqual(6, c.found.len);
}

test "a pin's partial area and per-layer gate area count" {
    // Oracle: LEF/DEF 5.8 p. 142 (a pin's ANTENNAPARTIALMETALAREA adds to its
    // metal area) and p. 140 (ANTENNAGATEAREA ... LAYER is the gate area
    // joined through that layer), hand-derived: 1.0 µm² of partial met1 makes
    // pin A's met1 PAR (2 + 1)/1 = 3.0; a gate area of 3.0 on met2 makes the
    // met2 PAR 9/(3 + 2) = 1.8, met1's still 2.0.
    {
        var c: C20 = try .init("    ANTENNAPARTIALMETALAREA 1.0 LAYER met1 ;\n");
        defer c.deinit();
        try c.expectRatio("par1", pin_a, 3.0);
    }
    var c: C20 = try .init("    ANTENNAGATEAREA 3.0 LAYER met2 ;\n");
    defer c.deinit();
    try c.expectRatio("par1", pin_a, 2.0);
    try c.expectRatio("par2", pin_a, 1.8);
}

test "a pin antenna value on a layer the deck lacks refuses erc" {
    // Oracle: `runErc`'s refusal: a value no row can place is unknown, not
    // zero, so the stage refuses naming the macro, the pin and the layer.
    var c: C20 = try .init("    ANTENNAMAXCUTCAR 1.0 LAYER cont ;\n");
    defer c.deinit();
    try testing.expectEqual(0, c.found.len);
    const why = c.erc.refused;
    try testing.expect(std.mem.indexOf(u8, why, "CELLA") != null and std.mem.indexOf(u8, why, "pin A") != null and std.mem.indexOf(u8, why, "cont") != null);
}
