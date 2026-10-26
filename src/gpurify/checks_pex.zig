//! The PEX stage: a loaded and extracted design → its parasitic network,
//! nominal and per process corner, in `Outputs`. Ported from
//! src/engine/run.rs (`run_pex`, `pex_network`, `coupling_halo`,
//! `fill_nets`, `layer_name`, `pex_refusal`, `solve_refusal`,
//! `reciprocity_refusal`).
//!
//! Closed forms over every net; the named nets field-solved for
//! capacitance and inductance and laid over them; device-region, TSV,
//! substrate and fill effects; reduced to the deck's extraction type. Every
//! refusal on the way, a non-reciprocal solve included, refuses the stage, a
//! corner's naming the corner; a refused stage leaves no partial network.
//! The adapters here map check's tables to extract's plain columns.
//!
//! Contents:
//! - `pub fn runPex(scratch: Allocator, run_arena: Allocator, device: Device, loaded: *const Loaded, extracted: *const Extracted, names: []const []const u8, out: *Outputs) Allocator.Error!StageStatus`
//! - `pub fn reciprocityRefusal(arena: Allocator, accuracy: Accuracy) Allocator.Error!?[]const u8`
//! - `pub const no_halo`, `pub fn couplingHalo(extraction: ingest.deck.Extraction) ?f64`
//! - `pub fn pexRefusal(arena: Allocator, loaded: *const Loaded, err: extract.analytical.Error, layer: LayerId) Allocator.Error![]const u8`
//! - `pub fn solveRefusal(arena: Allocator, loaded: *const Loaded, err: extract.capacitance.Error, diag: extract.capacitance.Diagnostic) Allocator.Error![]const u8`

const std = @import("std");
const Allocator = std.mem.Allocator;
const geom = @import("geom");
const Device = geom.Device;
const LayerId = geom.LayerId;
const Dbu = geom.Dbu;
const ingest = @import("ingest");
const ProcessStack = ingest.deck.ProcessStack;
const check = @import("check");
const topology = check.topology;
const NetId = topology.NetId;
const extract = @import("extract");
const ParasiticNetwork = extract.network.ParasiticNetwork;
const Accuracy = extract.capacitance.Accuracy;
const Loaded = @import("load.zig").Loaded;
const Extracted = @import("extracted.zig").Extracted;
const run_ = @import("run.zig");
const Outputs = run_.Outputs;
const StageStatus = run_.StageStatus;
const designExtent = @import("checks_erc.zig").designExtent;

/// The refusal when the deck states no lateral coupling reach.
pub const no_halo = "the deck states no `coupling_halo` on its `extraction` line, so no lateral coupling reach is the deck's";

/// What one stack's network reads.
const Pex = struct {
    scratch: Allocator,
    run_arena: Allocator,
    device: Device,
    loaded: *const Loaded,
    extracted: *const Extracted,
    nets: *const extract.NetPolys,
    selected: []const u32,

    /// One stack's network in the run arena, or null with `why` set.
    fn network(p: Pex, stack_in: *const ProcessStack, why: *[]const u8) Allocator.Error!?ParasiticNetwork {
        const scratch = p.scratch;
        const loaded = p.loaded;
        const deck = &loaded.deck.deck;
        const grid = loaded.grid;
        const conn = &deck.connectivity;
        const stack = stackOf(stack_in);
        const vias: extract.Vias = .{ .cut = conn.via_cut, .connects = conn.via_connects };
        const poly_net = p.extracted.nets.netColumn();
        // The deck's lateral coupling reach: 0 for an `r` extraction, which
        // keeps no capacitance; no reach is every process's.
        const halo = couplingHalo(deck.extraction) orelse {
            why.* = no_halo;
            return null;
        };
        var net: ParasiticNetwork = .empty;
        var refusal: extract.analytical.Refusal = .{ .layer = @fromBackingInt(0) };
        extract.analytical.extractInto(scratch, .{ .store = &loaded.store, .nets = p.nets, .conductors = conn.conductors, .global = conn.global, .vias = vias, .stack = stack, .halo = halo, .grid = grid }, &net, &refusal) catch |err| {
            why.* = try pexRefusal(p.run_arena, loaded, err, refusal.layer);
            return null;
        };
        if (p.selected.len != 0) if (try p.fieldSolve(stack, vias, &net, why) == null) return null;

        try extract.device_region.addInto(scratch, &net, try p.mosColumns(), deck.pex_models.device.items, grid);
        var tsvs: std.ArrayList(extract.tsv.Tsv) = .empty;
        for (deck.pex_models.tsv.items) |m| if (deck.layers.id(&loaded.strings, m.layer)) |layer|
            try tsvs.append(scratch, .{ .layer = layer, .length_nm = m.length_nm, .liner_nm = m.liner_nm, .liner_k = m.liner_k });
        try extract.tsv.addInto(scratch, &net, &loaded.store, poly_net, vias, tsvs.items, grid);
        if (deck.pex_models.substrate) |model| {
            var ports: std.ArrayList(LayerId) = .empty;
            for (model.ports) |name| if (deck.layers.id(&loaded.strings, name)) |l| try ports.append(scratch, l);
            // nm and Ω·cm to µm and Ω·µm.
            const layers = try scratch.alloc([2]f64, model.layers.len);
            for (model.layers, layers) |l, *o| o.* = .{ l[0] / 1000.0, l[1] * 1e4 };
            const profile: extract.substrate.Profile = .{ .layers = layers, .backside = if (model.grounded) .grounded else .floating };
            var sub_refusal: extract.substrate.Refusal = .{};
            extract.substrate.addInto(scratch, p.device.threads, &net, &loaded.store, poly_net, profile, ports.items, designExtent(loaded), grid, &sub_refusal) catch |err| {
                why.* = switch (err) {
                    error.TooLarge => try std.fmt.allocPrint(p.run_arena, "pex_substrate: the substrate grid needs {d} lines on an axis, more than {d}", .{ sub_refusal.lines, extract.substrate.max_lines }),
                    error.NoConvergence => "pex_substrate: the substrate solve did not converge",
                    error.OutOfMemory => return error.OutOfMemory,
                };
                return null;
            };
        }
        var fill_refusal: extract.fill.Refusal = .{};
        extract.fill.treat(scratch, &net, try p.fillNets(), &fill_refusal) catch |err| {
            why.* = switch (err) {
                error.Cluster => try std.fmt.allocPrint(p.run_arena, "{d} floating fill pieces couple into one cluster, over the {d} one dense reduction holds", .{ fill_refusal.pieces, extract.fill.max_cluster }),
                error.OutOfMemory => return error.OutOfMemory,
            };
            return null;
        };
        try extract.reduce.reduce(scratch, &net, deck.extraction);
        return try clone(p.run_arena, &net);
    }

    /// The selected nets field-solved, checked reciprocal, solved for
    /// inductance and laid over `net`; null with `why` set on a refusal.
    fn fieldSolve(p: Pex, stack: extract.Stack, vias: extract.Vias, net: *ParasiticNetwork, why: *[]const u8) Allocator.Error!?void {
        const scratch = p.scratch;
        const loaded = p.loaded;
        const conn = &loaded.deck.deck.connectivity;
        var matrix: extract.capacitance.CapMatrix = .{};
        var solved: ParasiticNetwork = .empty;
        var diag: extract.capacitance.Diagnostic = .{};
        const problem: extract.capacitance.Problem = .{ .store = &loaded.store, .nets = p.nets, .global = conn.global, .stack = stack, .grid = loaded.grid };
        const accuracy = extract.quasistatic.extractInto(scratch, p.device, problem, p.selected, &matrix, &solved, &diag) catch |err| {
            why.* = try solveRefusal(p.run_arena, loaded, err, diag);
            return null;
        };
        if (try reciprocityRefusal(p.run_arena, accuracy)) |r| {
            why.* = r;
            return null;
        }
        var inductance: extract.henry.InductMatrix = .{};
        var refusal: extract.henry.Refusal = .{};
        const henry: extract.henry.Problem = .{ .store = &loaded.store, .nets = p.nets, .global = conn.global, .vias = vias, .stack = stack, .grid = loaded.grid };
        extract.quasistatic.extractInductanceInto(scratch, p.device.threads, henry, p.selected, &inductance, &solved, &refusal) catch |err| {
            why.* = switch (err) {
                error.NoSheetResistance => try std.fmt.allocPrint(p.run_arena, "layer {d} has no positive sheet resistance in the process stack, so its conductivity is undefined and net inductance cannot be solved", .{refusal.layer}),
                error.NoThickness => try std.fmt.allocPrint(p.run_arena, "layer {d} has no positive thickness in the process stack", .{refusal.layer}),
                error.EmptyNet => try std.fmt.allocPrint(p.run_arena, "net {d} has no geometry to build a filament from", .{refusal.net}),
                error.Singular => "singular system at frequency 1000000 Hz",
                error.InvalidGeometry => try std.fmt.allocPrint(p.run_arena, "layer {d} is not valid rectilinear geometry, so it cannot be cut into filaments", .{refusal.layer}),
                error.Disconnected => try std.fmt.allocPrint(p.run_arena, "net {d}'s shapes do not join into one circuit through shared edges and vias, so its inductance is undefined", .{refusal.net}),
                error.OutOfMemory => return error.OutOfMemory,
            };
            return null;
        };
        try extract.quasistatic.overlay(scratch, net, &solved);
    }

    /// The MOS devices whose model a `pex_device` line names and whose
    /// width is measured, as extract's plain columns.
    fn mosColumns(p: Pex) Allocator.Error!extract.device_region.Mos {
        const scratch = p.scratch;
        const devices = &p.extracted.devices;
        const models = p.loaded.deck.deck.pex_models.device.items;
        var model: std.ArrayList(u32) = .empty;
        var width: std.ArrayList(Dbu) = .empty;
        var gate: std.ArrayList(u32) = .empty;
        var source: std.ArrayList(u32) = .empty;
        var drain: std.ArrayList(u32) = .empty;
        if (models.len == 0) return .{ .model = &.{}, .width = &.{}, .gate = &.{}, .source = &.{}, .drain = &.{} };
        for (0..devices.len()) |d| {
            if (devices.kind.items[d] != .mos) continue;
            const name = p.loaded.strings.resolve(devices.model.items[d]);
            const row = for (models, 0..) |m, i| (if (std.mem.eql(u8, m.model, name)) break i) else continue;
            const id: topology.DeviceId = @fromBackingInt(@as(u32, @intCast(d)));
            const params = devices.paramsOf(id);
            const w = for (params.names, params.measures) |n, m| {
                if (n == .width) switch (m) {
                    .length => |l| break l,
                    else => {},
                };
            } else continue;
            const terms = devices.terminalsOf(id);
            try model.append(scratch, @intCast(row));
            try width.append(scratch, w);
            try gate.append(scratch, roleNet(terms, .gate));
            try source.append(scratch, roleNet(terms, .source));
            try drain.append(scratch, roleNet(terms, .drain));
        }
        return .{ .model = model.items, .width = width.items, .gate = gate.items, .source = source.items, .drain = drain.items };
    }

    /// Every net drawn only on `pex_fill` layers, ascending, with the
    /// treatment of the first fill layer (deck order) it is on.
    fn fillNets(p: Pex) Allocator.Error![]const extract.fill.Fill {
        const loaded = p.loaded;
        const deck = &loaded.deck.deck;
        var layers: std.ArrayList(LayerId) = .empty;
        var treatments: std.ArrayList(extract.fill.Treatment) = .empty;
        for (deck.pex_models.fill.items) |row| if (deck.layers.id(&loaded.strings, row.layer)) |l| {
            try layers.append(p.scratch, l);
            try treatments.append(p.scratch, row.treatment);
        };
        var out: std.ArrayList(extract.fill.Fill) = .empty;
        if (layers.items.len == 0) return out.items;
        for (0..p.extracted.nets.netCount()) |n| {
            const polys = p.extracted.nets.polysOf(@fromBackingInt(@as(u32, @intCast(n))));
            if (polys.len == 0) continue;
            const all_fill = for (polys) |poly| {
                if (std.mem.findScalar(LayerId, layers.items, loaded.store.polyLayer(poly)) == null) break false;
            } else true;
            if (!all_fill) continue;
            const first = for (layers.items, treatments.items) |l, t| {
                if (for (polys) |poly| (if (loaded.store.polyLayer(poly) == l) break true) else false) break t;
            } else unreachable; // every polygon is on a fill layer
            try out.append(p.scratch, .{ .net = @intCast(n), .treatment = first });
        }
        return out.items;
    }
};

pub fn runPex(scratch: Allocator, run_arena: Allocator, device: Device, loaded: *const Loaded, extracted: *const Extracted, names: []const []const u8, out: *Outputs) Allocator.Error!StageStatus {
    // The names are the user's input, refused before any extraction.
    var selected: std.ArrayList(u32) = .empty;
    for (names) |name| {
        // `get`, never `intern`: a name the run never saw is not a net.
        const pieces = if (loaded.strings.get(name)) |id| extracted.ports.netsOf(id) else &.{};
        switch (pieces.len) {
            1 => try selected.append(scratch, @backingInt(pieces[0])),
            0 => return .{ .refused = try std.fmt.allocPrint(run_arena, "no extracted net is named {s}, so it cannot be field solved", .{name}) },
            else => return .{ .refused = try std.fmt.allocPrint(run_arena, "{s} labels {d} disconnected nets, an open, so no one net of that name can be field solved", .{ name, pieces.len }) },
        }
    }
    // A net named twice is one conductor: solved twice, it is a singular
    // system that never converges.
    std.mem.sort(u32, selected.items, {}, std.sort.asc(u32));
    const unique = dedup(selected.items);

    var nets: extract.NetPolys = .empty;
    try nets.buildInto(scratch, extracted.nets.netColumn(), extracted.nets.netCount());
    const pex: Pex = .{ .scratch = scratch, .run_arena = run_arena, .device = device, .loaded = loaded, .extracted = extracted, .nets = &nets, .selected = unique };
    var why: []const u8 = "";
    const nominal = try pex.network(&loaded.deck.deck.stack, &why) orelse return .{ .refused = why };
    var corners: std.ArrayList(run_.Corner) = .empty;
    for (loaded.deck.deck.corners) |corner| {
        const network = try pex.network(&corner.stack, &why) orelse
            return .{ .refused = try std.fmt.allocPrint(run_arena, "corner {s}: {s}", .{ loaded.strings.resolve(corner.name), why }) };
        try corners.append(run_arena, .{ .name = corner.name, .network = network });
    }
    out.parasitics = nominal;
    out.corners = corners;
    return .ran;
}

/// The refusal when the matrix is not reciprocal within what its solve
/// allows (its own tolerance with a symmetric operator, the
/// discretisation's with dielectric interfaces); a NaN or infinite
/// asymmetry is refused too. Null when reciprocal.
pub fn reciprocityRefusal(arena: Allocator, accuracy: Accuracy) Allocator.Error!?[]const u8 {
    if (std.math.isFinite(accuracy.asymmetry) and accuracy.asymmetry <= accuracy.reciprocity) return null;
    return try std.fmt.allocPrint(arena, "the capacitance matrix is not reciprocal: asymmetry {e} against the {e} its solve allows, after {d} iterations", .{ accuracy.asymmetry, accuracy.reciprocity, accuracy.iterations });
}

/// The deck's lateral coupling reach: 0 for an `r` extraction, which keeps
/// no capacitance; null when the deck states none (`no_halo`).
pub fn couplingHalo(extraction: ingest.deck.Extraction) ?f64 {
    return if (extraction.kind == .r) 0 else extraction.coupling_halo;
}

/// Why the closed forms refused `layer`, named as the deck names it.
pub fn pexRefusal(arena: Allocator, loaded: *const Loaded, err: extract.analytical.Error, layer: LayerId) Allocator.Error![]const u8 {
    const why = switch (err) {
        error.Undescribed => "no pex row gives this conductor a positive sheet resistance",
        error.UndescribedVia => "no pex row gives this via layer a positive resistance per cut",
        error.InvalidGeometry => "not valid rectilinear geometry, so its conductors cannot be merged exactly",
        error.OutOfMemory => return error.OutOfMemory,
    };
    return std.fmt.allocPrint(arena, "layer {s}: {s}", .{ try layerName(arena, loaded, layer), why });
}

/// Why a field solve produced no capacitance, naming the deck layer a mesh
/// refusal is about.
pub fn solveRefusal(arena: Allocator, loaded: *const Loaded, err: extract.capacitance.Error, diag: extract.capacitance.Diagnostic) Allocator.Error![]const u8 {
    const mesh: []const u8 = switch (err) {
        error.TooManyPanels => return "field solve: mesh would exceed the panel limit",
        error.EmptyConductor => return "field solve: selected net has no geometry",
        error.MissingThickness => "no pex row gives this layer a positive thickness and permittivity, so it cannot be meshed",
        error.InvalidGeometry => "not valid rectilinear geometry, so it cannot be meshed exactly",
        error.DielectricConflict => "its dielectric differs from another layer's at the same height, so the stack's permittivity there is not defined",
        error.NotConverged => return std.fmt.allocPrint(arena, "field solve: did not converge: residual {d} after {d} iterations", .{ diag.failure.residual, diag.failure.iterations }),
        error.Breakdown => return std.fmt.allocPrint(arena, "field solve: system broke down at iteration {d}", .{diag.failure.iterations}),
        error.NonFinite => return std.fmt.allocPrint(arena, "field solve: the operator produced a non-finite value at iteration {d}", .{diag.failure.iterations}),
        error.OutOfMemory => return error.OutOfMemory,
    };
    return std.fmt.allocPrint(arena, "layer {s}: {s}", .{ try layerName(arena, loaded, diag.layer), mesh });
}

// ---- private ----

fn stackOf(s: *const ProcessStack) extract.Stack {
    return .{ .thickness_nm = s.thickness_nm, .height_nm = s.height_nm, .sheet_res_ohm_sq = s.sheet_res_ohm_sq, .area_cap_af_um2 = s.area_cap_af_um2, .fringe_cap_af_um = s.fringe_cap_af_um, .dielectric_k = s.dielectric_k };
}

/// The net of the first terminal in `role`, `extract.none` without one.
fn roleNet(terms: topology.device.Terminals, role: std.meta.Tag(topology.TerminalRole)) u32 {
    for (terms.nets, terms.roles) |n, r| if (r == role) return @backingInt(n);
    return extract.none;
}

fn dedup(sorted: []u32) []u32 {
    if (sorted.len == 0) return sorted;
    var n: usize = 1;
    for (sorted[1..]) |v| if (v != sorted[n - 1]) {
        sorted[n] = v;
        n += 1;
    };
    return sorted[0..n];
}

/// A layer as the deck names it; its id past the deck's table.
fn layerName(arena: Allocator, loaded: *const Loaded, layer: LayerId) Allocator.Error![]const u8 {
    const layers = &loaded.deck.deck.layers;
    if (@backingInt(layer) < layers.len()) return loaded.strings.resolve(layers.name(layer));
    return std.fmt.allocPrint(arena, "LayerId({d})", .{@backingInt(layer)});
}

/// `n`'s columns copied into `arena`.
fn clone(arena: Allocator, n: *const ParasiticNetwork) Allocator.Error!ParasiticNetwork {
    var out: ParasiticNetwork = .empty;
    inline for (@typeInfo(ParasiticNetwork).@"struct".field_names) |f| try @field(out, f).appendSlice(arena, @field(n, f).items);
    return out;
}

test "a matrix that is not reciprocal is refused, and a non-finite one too" {
    // Oracle: `reciprocityRefusal`'s doc: refused when the asymmetry exceeds
    // the solve's own tolerance (1e-10 here) or is not finite, so 1e-11 and
    // 0 pass and 1e-9, infinity and NaN are refused.
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const at = struct {
        fn f(asymmetry: f64) Accuracy {
            return .{ .tolerance = 1e-10, .iterations = 7, .asymmetry = asymmetry, .reciprocity = 1e-10 };
        }
    }.f;
    try std.testing.expect(try reciprocityRefusal(a, at(1e-11)) == null);
    try std.testing.expect(try reciprocityRefusal(a, at(0)) == null);
    try std.testing.expect(try reciprocityRefusal(a, at(1e-9)) != null);
    try std.testing.expect(try reciprocityRefusal(a, at(std.math.inf(f64))) != null);
    try std.testing.expect(try reciprocityRefusal(a, at(std.math.nan(f64))) != null);
}
