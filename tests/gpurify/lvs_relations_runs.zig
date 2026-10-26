//! The LVS metamorphic relations (P1) that compare two runs of the tool:
//! each takes no expected value from the brute-force oracle, and is a
//! second, independent oracle for the rows the fixtures prove with it.
//! Ported from tests/exhaustive/lvs.rs (`mod tests`:
//! `a_reference_reads_the_same_in_spice_and_spectre`,
//! `an_unmeasured_parameter_is_one_undeclared_row_whatever_its_value`,
//! `an_implant_marker_on_a_gate_flips_its_flavour`).
//!
//! Contents: tests only.

const std = @import("std");
const Allocator = std.mem.Allocator;
const testing = std.testing;
const circuit = @import("lvs_circuit.zig");
const Dev = circuit.Dev;
const Circuit = circuit.Circuit;
const fixture = @import("lvs_fixture.zig");
const oracle = @import("lvs_oracle.zig");
const lvs_enum = @import("lvs_enum.zig");
const relations = @import("lvs_relations.zig");
const report = relations.report;
const gpa = testing.allocator;

// ---- private ----

fn sameLines(a: []const []const u8, b: []const []const u8) bool {
    if (a.len != b.len) return false;
    for (a, b) |x, y| if (!std.mem.eql(u8, x, y)) return false;
    return true;
}

test "a reference reads the same in SPICE and Spectre" {
    // LVS-071: one circuit gets one report whichever dialect states it.
    // Oracle: metamorphic relation. `spice` and `spectre` write the same
    // circuit in the reader's two documented dialects (the `netlist` module
    // docs), so every rule row, every finding and the verdict must be the
    // same for both: on every circuit of `sample` against itself and each
    // of its single faults, and on `everyModel` as drawn and with two pins
    // swapped. A Spectre card read as another device, terminal order or
    // parameter breaks it.
    var arena: std.heap.ArenaAllocator = .init(gpa);
    defer arena.deinit();
    const a = arena.allocator();
    const Pair = struct { Circuit, Circuit };
    var pairs: std.ArrayList(Pair) = .empty;
    for (try fixture.everyModel(a)) |p| {
        try pairs.append(a, .{ p.drawn, p.drawn });
        try pairs.append(a, .{ p.drawn, p.swapped });
    }
    for (try relations.sample(a)) |c| {
        try pairs.append(a, .{ c, c });
        var faults: std.ArrayList(lvs_enum.Fault) = .empty;
        try lvs_enum.faultsInto(a, &c, &faults);
        for (faults.items) |f| try pairs.append(a, .{ c, f.circuit });
    }
    for (pairs.items) |*pair| {
        var run_arena: std.heap.ArenaAllocator = .init(gpa);
        defer run_arena.deinit();
        const ra = run_arena.allocator();
        const layout = try circuit.draw(ra, &pair[0]);
        const in_spice = try report(ra, layout, try circuit.spice(ra, &pair[1]));
        const in_spectre = try report(ra, layout, try circuit.spectre(ra, &pair[1]));
        if (!sameLines(in_spice, in_spectre)) {
            std.debug.print("{s} drawn, {s} written\n", .{ try pair[0].code(ra), try pair[1].code(ra) });
            return error.TestDialectsDisagree;
        }
    }
}

test "an unmeasured parameter is one undeclared row whatever its value" {
    // LVS-020: a parameter the layout cannot measure, stated on one card, is
    // one `lvs.undeclared_param` row and changes nothing else, whatever its
    // value.
    // Oracle: metamorphic relation. From a reference that matches its
    // layout, adding `nrd` (BSIM's drain squares, which no recogniser
    // measures: `DeviceParam` lists what one does) to any one card keeps
    // every other row and finding, and adds exactly one
    // `lvs.undeclared_param` finding and the mismatch; `nrd=1` and
    // `nrd=1000` give the same report. On every device of every circuit of
    // `sample` and `everyModel` that reduces nothing, so the added parameter
    // cannot stop a merge. A stated value taken as agreement with the
    // layout's silence, or one compared by value, breaks it.
    var arena: std.heap.ArenaAllocator = .init(gpa);
    defer arena.deinit();
    const a = arena.allocator();
    var circuits: std.ArrayList(Circuit) = .empty;
    try circuits.appendSlice(a, try relations.sample(a));
    for (try fixture.everyModel(a)) |p| try circuits.append(a, p.drawn);
    var checked: usize = 0;
    for (circuits.items) |*c| {
        if (try oracle.reducedCount(a, c) < c.devs.len) continue;
        var run_arena: std.heap.ArenaAllocator = .init(gpa);
        defer run_arena.deinit();
        const ra = run_arena.allocator();
        const layout = try circuit.draw(ra, c);
        const base = try report(ra, layout, try circuit.spice(ra, c));
        try testing.expectEqualStrings("matched true", base[base.len - 1]);
        const rows = base[0 .. base.len - 1];
        for (0..c.devs.len) |i| {
            var reports: [2][]const []const u8 = undefined;
            for ([_]f64{ 1.0, 1000.0 }, &reports) |value, *out| {
                const written = try c.clone(ra);
                written.devs[i] = written.devs[i].param("nrd", value);
                out.* = try report(ra, layout, try circuit.spice(ra, &written));
            }
            try testing.expect(sameLines(reports[0], reports[1]));
            var added: std.ArrayList([]const u8) = .empty;
            try added.appendSlice(ra, reports[0]);
            for (rows) |line| {
                const at = for (added.items, 0..) |have, k| (if (std.mem.eql(u8, have, line)) break k) else {
                    std.debug.print("{s}: device {d} lost {s}\n", .{ try c.code(ra), i, line });
                    return error.TestRowLost;
                };
                _ = added.orderedRemove(at);
            }
            const ok = added.items.len == 2 and std.mem.startsWith(u8, added.items[0], "lvs.undeclared_param ") and std.mem.eql(u8, added.items[1], "matched false");
            if (!ok) {
                std.debug.print("{s}: device {d} added {d} lines\n", .{ try c.code(ra), i, added.items.len });
                return error.TestNotOneUndeclaredRow;
            }
            checked += 1;
        }
    }
    try testing.expect(checked >= 30); // cards checked
}

test "an implant marker on a gate flips its flavour" {
    // LVS-066: the `hvt` implant over an `nmos` gate, and only over its
    // gate, makes it the deck's `nmos_hvt` flavour (`gate_nh = gate_n and
    // hvt`, `gate_nl = gate_n not hvt`).
    // Oracle: metamorphic relation. Adding `hvt` over exactly one `nmos`
    // gate gives, against any reference, the report of the same circuit
    // drawn with that device an `nmos_hvt` (the implant over its whole
    // device), and so flips the verdict against both the plain reference
    // and the flavoured one; adding it over that device's source diffusion,
    // beside the gate, changes nothing. On every `nmos` of every circuit of
    // `sample`. A flavour read from anything but the gate's implant breaks
    // it.
    var arena: std.heap.ArenaAllocator = .init(gpa);
    defer arena.deinit();
    const a = arena.allocator();
    var checked: usize = 0;
    for (try relations.sample(a)) |*c| for (c.devs, 0..) |dev, i| {
        if (dev.model != .n) continue;
        // The drawer's channel, and its source diffusion short of it.
        const x0 = circuit.column(i);
        const gate = [4]i64{ x0 + circuit.sd, 0, x0 + circuit.sd + dev.l, dev.w };
        const beside = [4]i64{ x0, 0, x0 + circuit.sd - 100, dev.w };
        var run_arena: std.heap.ArenaAllocator = .init(gpa);
        defer run_arena.deinit();
        const ra = run_arena.allocator();
        const flavoured = try c.clone(ra);
        flavoured.devs[i].model = .h;
        for ([_]*const Circuit{ c, &flavoured }) |reference| {
            const text = try circuit.spice(ra, reference);
            const plain = try report(ra, try circuit.draw(ra, c), text);
            var on_gate_layout = try circuit.draw(ra, c);
            try on_gate_layout.rect(ra, "hvt", gate[0], gate[1], gate[2], gate[3]);
            const on_gate = try report(ra, on_gate_layout, text);
            var beside_layout = try circuit.draw(ra, c);
            try beside_layout.rect(ra, "hvt", beside[0], beside[1], beside[2], beside[3]);
            const what = .{ try c.code(ra), i, try reference.code(ra) };
            if (!sameLines(on_gate, try report(ra, try circuit.draw(ra, &flavoured), text))) {
                std.debug.print("{s} device {d} against {s}: on the gate\n", what);
                return error.TestGateImplantNotFlavour;
            }
            if (std.mem.eql(u8, on_gate[on_gate.len - 1], plain[plain.len - 1])) {
                std.debug.print("{s} device {d} against {s}: the verdict flips\n", what);
                return error.TestVerdictDidNotFlip;
            }
            if (!sameLines(try report(ra, beside_layout, text), plain)) {
                std.debug.print("{s} device {d} against {s}: beside the gate\n", what);
                return error.TestBesideGateChanged;
            }
        }
        checked += 1;
    };
    try testing.expect(checked >= 20); // nmos checked
}
