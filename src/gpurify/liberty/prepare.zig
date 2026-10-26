//! Corner-independent work, done once per run: the layout → the wire
//! capacitance per net (`analytical`, `field`) and the circuit every corner
//! simulates (lumped below `spice`, the distributed RC graph from it). In:
//! `Loaded`, `Extracted`, the spec and the accuracy. Out: `Prepared`.
//! Ported from src/liberty/mod.rs (`Prepared::new`) with the engine's
//! `coupling_halo` and `pex_refusal` (src/engine/run.rs).
//!
//! Contents:
//! - `pub const Prepared = struct { wire_ff, circuit, workers }`
//! - `pub const Error = circuit.Error || error{ Pex, Solve }`
//! - `pub fn prepare(arena: Allocator, loaded: *const Loaded, extracted: *const Extracted, macro: *const MacroSpec, accuracy: Accuracy, diag: *Diagnostic) Error!Prepared`

const std = @import("std");
const Allocator = std.mem.Allocator;
const extract = @import("extract");
const ParasiticNetwork = extract.network.ParasiticNetwork;
const NetId = @import("check").topology.net.NetId;
const Loaded = @import("../load.zig").Loaded;
const Extracted = @import("../extracted.zig").Extracted;
const spec = @import("spec.zig");
const Accuracy = spec.Accuracy;
const MacroSpec = spec.MacroSpec;
const Diagnostic = spec.Diagnostic;
const circuit = @import("circuit.zig");
const Circuit = circuit.Circuit;
const field = @import("field.zig");

/// What every corner shares.
pub const Prepared = struct {
    /// Wire capacitance per net, fF (`analytical`, `field`); empty above.
    wire_ff: []const f64 = &.{},
    /// The circuit leakage and everything else is measured on; null at
    /// `interface`.
    circuit: ?Circuit = null,
    /// Concurrent ngspice sessions: the spec's, else every core.
    workers: u32,
};

/// `Pex`: the closed forms refused a layer (or the deck states no coupling
/// reach); `Solve`: the field solve refused. Both messages name the layer as
/// `pex` does.
pub const Error = circuit.Error || error{ Pex, Solve };

/// Extracts the wiring and builds the circuit `accuracy` simulates.
pub fn prepare(arena: Allocator, loaded: *const Loaded, extracted: *const Extracted, macro: *const MacroSpec, accuracy: Accuracy, diag: *Diagnostic) Error!Prepared {
    var out: Prepared = .{ .workers = macro.simulator.workers orelse @intCast(std.Thread.getCpuCount() catch 1) };
    if (accuracy == .interface) return out;
    const deck = &loaded.deck.deck;
    const halo = try couplingHalo(arena, loaded, diag);
    const net_polys = try arena.create(extract.NetPolys);
    net_polys.* = .empty;
    try net_polys.buildInto(arena, extracted.nets.netColumn(), extracted.nets.netCount());
    const problem: extract.analytical.Problem = .{
        .store = &loaded.store,
        .nets = net_polys,
        .conductors = deck.connectivity.conductors,
        .global = deck.connectivity.global,
        .vias = .{ .cut = deck.connectivity.via_cut, .connects = deck.connectivity.via_connects },
        .stack = .{ .thickness_nm = deck.stack.thickness_nm, .height_nm = deck.stack.height_nm, .sheet_res_ohm_sq = deck.stack.sheet_res_ohm_sq, .area_cap_af_um2 = deck.stack.area_cap_af_um2, .fringe_cap_af_um = deck.stack.fringe_cap_af_um, .dielectric_k = deck.stack.dielectric_k },
        .halo = halo,
        .grid = loaded.grid,
    };
    const analytical = try arena.create(ParasiticNetwork);
    analytical.* = .empty;
    var refusal: extract.analytical.Refusal = .{};
    extract.analytical.extractInto(arena, problem, analytical, &refusal) catch |err| {
        if (err == error.OutOfMemory) return error.OutOfMemory;
        diag.message = try pexRefusal(arena, loaded, err, refusal);
        return error.Pex;
    };
    var pin_start: std.ArrayList(u32) = .empty;
    var pin_nets: std.ArrayList(NetId) = .empty;
    try circuit.pinNetsInto(arena, loaded, extracted, macro, &pin_start, &pin_nets, diag);
    var selected: std.ArrayList(u32) = .empty;
    const solved = try arena.create(ParasiticNetwork);
    solved.* = .empty;
    switch (accuracy) {
        .interface => unreachable, // returned above
        .analytical, .field => {
            if (accuracy == .field) {
                for (macro.pins, 0..) |pin, p| if (!pin.role.isSupply()) for (pin_nets.items[pin_start.items[p]..pin_start.items[p + 1]]) |net| {
                    if (!extracted.nets.isGlobalOnly(net)) try selected.append(arena, @backingInt(net));
                };
                field.fieldSolve(arena, loaded, extracted, selected.items, field.field_mesh, solved, diag) catch |err| return mapField(err);
                try extract.quasistatic.overlay(arena, analytical, solved);
            }
            var per_net: std.ArrayList(f64) = .empty;
            try analytical.capacitancePerNetInto(arena, &per_net);
            out.wire_ff = per_net.items;
            out.circuit = try circuit.build(arena, loaded, extracted, macro, .lumped, diag);
        },
        .spice, .statistical => {
            for (0..extracted.nets.netCount()) |n| if (!extracted.nets.isGlobalOnly(@fromBackingInt(@intCast(n)))) try selected.append(arena, @intCast(n));
            field.fieldSolve(arena, loaded, extracted, selected.items, field.spice_mesh, solved, diag) catch |err| return mapField(err);
            out.circuit = try circuit.build(arena, loaded, extracted, macro, .{ .distributed = .{ .analytical = analytical, .problem = problem, .field = solved } }, diag);
        },
    }
    return out;
}

// ---- private ----

fn mapField(err: field.Error) Error {
    return switch (err) {
        error.Solve => error.Solve,
        error.OutOfMemory => error.OutOfMemory,
    };
}

/// The deck's lateral coupling reach: none for an `r` extraction, else its
/// stated `coupling_halo`, else a refusal.
/// ponytail: duplicate of the engine's coupling_halo; dedupe when run.zig lands.
fn couplingHalo(arena: Allocator, loaded: *const Loaded, diag: *Diagnostic) Error!f64 {
    const extraction = loaded.deck.deck.extraction;
    if (extraction.kind == .r) return 0.0;
    if (extraction.coupling_halo) |halo| return halo;
    diag.message = try arena.dupe(u8, "the deck states no `coupling_halo` on its `extraction` line, so no lateral coupling reach is the deck's");
    return error.Pex;
}

/// Why the closed forms refused, naming the layer as the deck does.
/// ponytail: duplicate of the engine's pex_refusal; dedupe when run.zig lands.
fn pexRefusal(arena: Allocator, loaded: *const Loaded, err: extract.analytical.Error, refusal: extract.analytical.Refusal) Allocator.Error![]const u8 {
    const name = loaded.strings.resolve(loaded.deck.deck.layers.name(refusal.layer));
    const why = switch (err) {
        error.Undescribed => "no pex row gives this conductor a positive sheet resistance",
        error.UndescribedVia => "no pex row gives this via layer a positive resistance per cut",
        error.InvalidGeometry => "not valid rectilinear geometry, so its conductors cannot be merged exactly",
        error.OutOfMemory => return error.OutOfMemory,
    };
    return arena.print("layer {s}: {s}", .{ name, why });
}
