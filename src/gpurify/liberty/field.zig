//! The wiring of chosen nets, field-solved: layout nets → a network with one
//! node per net, its ground and coupling capacitance. Ported from
//! src/liberty/mod.rs (`FieldMesh`, `FIELD`, `SPICE_FIELD`, `field_solve`,
//! `merge_overlaps`).
//!
//! Wells, diffusions and substrate stay out of the mesh (their capacitance
//! is the device models', and a well touching its own diffusion is two
//! conductors at zero gap, which no boundary-element system converges on),
//! and so do via cuts (a cut's end faces coincide with the plates it joins);
//! a net's layers become separate conductors, folded back by owner. A net is
//! driven as one: all its conductors at one volt in one solve, the column of
//! the net with them shorted. Its total charge is its capacitance to ground;
//! the charge on each other net is their coupling, a pair's the mean of what
//! each side's solve saw (collocation is not exactly reciprocal, and windows
//! differ).
//!
//! ponytail: poly over a channel stays in the mesh, so a gate net counts its
//! oxide-area field capacitance (about 1 % of an input's) on top of the
//! model's; subtract the channels with a boolean if that ever matters.
//!
//! Contents:
//! - `pub const FieldMesh = struct { edge_nm, window_nm }`, `pub const field_mesh`, `pub const spice_mesh`
//! - `pub const Error = error{Solve} || Allocator.Error`
//! - `pub fn fieldSolve(arena: Allocator, loaded: *const Loaded, extracted: *const Extracted, targets: []const u32, how: FieldMesh, out: *ParasiticNetwork, diag: *Diagnostic) Error!void`

const std = @import("std");
const Allocator = std.mem.Allocator;
const geom = @import("geom");
const Bbox = geom.Bbox;
const LayerId = geom.LayerId;
const GeometryStore = geom.GeometryStore;
const check = @import("check");
const topology = check.topology;
const ingest = @import("ingest");
const extract = @import("extract");
const ParasiticNetwork = extract.network.ParasiticNetwork;
const Loaded = @import("../load.zig").Loaded;
const Extracted = @import("../extracted.zig").Extracted;
const Diagnostic = @import("spec.zig").Diagnostic;

/// How the wiring is field-solved.
pub const FieldMesh = struct {
    /// Largest panel edge, nm; halved near another conductor.
    edge_nm: i64,
    /// Each net's solve meshes only the conductors within this many nm of
    /// it; null: every selected net's wiring.
    window_nm: ?i64,
};

/// `field`: the pin nets' wiring, solved together, converged to 0.05 %.
pub const field_mesh: FieldMesh = .{ .edge_nm = 50, .window_nm = null };

/// `spice`, `statistical`: every net, each in a 3 µm window, converged to
/// 0.8 % of its wire capacitance (a 200 nm edge, halved near another
/// conductor). The dense solve's cost grows as the edge's inverse fourth power.
pub const spice_mesh: FieldMesh = .{ .edge_nm = 200, .window_nm = 3000 };

/// `Solve`: a layer the mesh cannot take, or a solve that did not converge;
/// `diag.message` is the one `pex` reports for the same refusal.
pub const Error = error{Solve} || Allocator.Error;

/// Field-solves the wiring of `targets` (layout net ids) into `out`
/// (cleared): one node per net, canonical order.
pub fn fieldSolve(arena: Allocator, loaded: *const Loaded, extracted: *const Extracted, targets: []const u32, how: FieldMesh, out: *ParasiticNetwork, diag: *Diagnostic) Error!void {
    out.clear();
    if (targets.len == 0) return;
    const deck = &loaded.deck.deck;
    const store = &loaded.store;
    // Windowed, every net's wiring is a potential neighbour.
    const meshed = try arena.alloc(bool, extracted.nets.netCount());
    @memset(meshed, how.window_nm != null);
    for (targets) |net| meshed[net] = true;
    var builder: geom.GeometryStoreBuilder = .empty;
    var origin: std.ArrayList(u32) = .empty;
    for (0..store.polyCount()) |row| {
        const poly: geom.PolyId = @fromBackingInt(@intCast(row));
        const net = extracted.nets.netOf(poly);
        if (net == .none or !meshed[@backingInt(net)] or !isWire(deck, store.polyLayer(poly))) continue;
        const v = store.polyVerts(poly);
        _ = try builder.push(arena, store.polyLayer(poly), v.xs, v.ys);
        try origin.append(arena, @backingInt(net));
    }
    var drawn: GeometryStore = .empty;
    var permutation: std.ArrayList(u32) = .empty;
    try builder.finish(arena, @intCast(store.layerCount()), &drawn, &permutation);
    const drawn_origin = try arena.alloc(u32, permutation.items.len);
    for (drawn_origin, permutation.items) |*o, old| o.* = origin.items[old];
    var wires: GeometryStore = .empty;
    const wire_origin = try mergeOverlaps(arena, &drawn, drawn_origin, &deck.connectivity, &wires);
    var nets: topology.NetTable = .{};
    try topology.extractNetsInto(arena, &wires, &deck.connectivity, &nets);
    // Conductors, ascending, with their layout net and footprint.
    var conductors: std.ArrayList(u32) = .empty;
    var owner: std.ArrayList(u32) = .empty;
    var extent: std.ArrayList(Bbox) = .empty;
    for (0..nets.netCount()) |n| {
        const polys = nets.polysOf(@fromBackingInt(@intCast(n)));
        if (polys.len == 0) continue;
        var box: Bbox = .empty;
        for (polys) |p| box = box.merge(wires.polyBbox(p));
        try conductors.append(arena, @intCast(n));
        try owner.append(arena, wire_origin[@backingInt(polys[0])]);
        try extent.append(arena, box);
    }
    var net_polys: extract.NetPolys = .empty;
    try net_polys.buildInto(arena, nets.netColumn(), nets.netCount());
    const problem: extract.capacitance.Problem = .{ .store = &wires, .nets = &net_polys, .global = deck.connectivity.global, .stack = stackOf(&deck.stack), .grid = loaded.grid };
    const per_um = loaded.grid.dbu_per_um;
    const edge: i64 = @max(@divTrunc(how.edge_nm * per_um, 1000), 1);
    const meshing: extract.mesh.MeshOptions = .{ .max_edge = edge, .proximity_refine = edge, .max_panels = 1 << 22 };
    // A relative residual of 1e-7 leaves every capacitance good to that:
    // four orders below the mesh's own error.
    var solver = extract.solve.Options.default;
    solver.tolerance = 1e-7;
    const halo: ?i64 = if (how.window_nm) |nm| @divTrunc(nm * per_um, 1000) else null;

    var ground: std.AutoArrayHashMapUnmanaged(u32, f64) = .empty;
    // `(from, to)`: what `from`'s solve saw on `to`.
    var seen: std.AutoArrayHashMapUnmanaged([2]u32, f64) = .empty;
    var matrix: extract.capacitance.CapMatrix = .empty;
    const groups = try arena.dupe(u32, targets);
    std.mem.sortUnstable(u32, groups, {}, std.sort.asc(u32));
    var window: std.ArrayList(u32) = .empty;
    var driven: std.ArrayList(u32) = .empty;
    for (groups, 0..) |target, g| {
        if (g > 0 and groups[g - 1] == target) continue;
        // One solve per net: its conductors at one volt, the window's at ground.
        driven.clearRetainingCapacity();
        var reach: Bbox = .empty;
        for (conductors.items, owner.items, extent.items) |c, o, box| if (o == target) {
            try driven.append(arena, c);
            reach = reach.merge(box);
        };
        if (driven.items.len == 0) continue;
        window.clearRetainingCapacity();
        for (conductors.items, extent.items) |c, box| if (halo == null or box.within(reach, halo.?)) try window.append(arena, c);
        var why: extract.capacitance.Diagnostic = .{};
        _ = extract.capacitance.extractColumnsInto(arena, .cpu, problem, window.items, &.{driven.items}, meshing, solver, &matrix, &why) catch |err| {
            if (err == error.OutOfMemory) return error.OutOfMemory;
            diag.message = try solveRefusal(arena, loaded, err, why);
            return error.Solve;
        };
        // The net's column: by reciprocity its row, so its total is its
        // capacitance to ground and each other net's share its coupling.
        const source = ownerOf(conductors.items, owner.items, driven.items[0]);
        for (matrix.net.items, matrix.value.items) |row_net, charge| {
            const slot = try ground.getOrPut(arena, source);
            if (!slot.found_existing) slot.value_ptr.* = 0.0;
            slot.value_ptr.* += charge;
            const other = ownerOf(conductors.items, owner.items, row_net);
            if (other == source) continue;
            const pair = try seen.getOrPut(arena, .{ source, other });
            if (!pair.found_existing) pair.value_ptr.* = 0.0;
            pair.value_ptr.* += -charge;
        }
    }
    sortByKey(u32, &ground);
    sortByKey([2]u32, &seen);
    // A pair seen from both sides is the mean; from one side, that side.
    var coupling: std.AutoArrayHashMapUnmanaged([2]u32, f64) = .empty;
    for (seen.keys(), seen.values()) |key, f| {
        const value = if (seen.get(.{ key[1], key[0] })) |m| 0.5 * (f + m) else f;
        try coupling.put(arena, .{ @min(key[0], key[1]), @max(key[0], key[1]) }, value);
    }
    sortByKey([2]u32, &coupling);
    try out.node_net.appendSlice(arena, ground.keys());
    try out.node_layer.appendNTimes(arena, @fromBackingInt(std.math.maxInt(u16)), ground.count());
    for (ground.values(), 0..) |farads, i| try out.push(arena, .at(i), .ground, .ground_cap, farads * 1e15);
    for (coupling.keys(), coupling.values()) |key, farads| {
        const a = ground.getIndex(key[0]) orelse continue;
        const b = ground.getIndex(key[1]) orelse continue;
        try out.push(arena, .at(a), .at(b), .coupling_cap, farads * 1e15);
    }
    try out.sortCanonical(arena);
}

// ---- private ----

/// A conductor layer with wire capacitance in the stack.
fn isWire(deck: *const ingest.deck.Deck, layer: LayerId) bool {
    const row = @backingInt(layer);
    if (std.mem.indexOfScalar(LayerId, deck.connectivity.conductors, layer) == null) return false;
    if (row >= deck.stack.area_cap_af_um2.len) return false;
    return deck.stack.area_cap_af_um2[row] > 0.0 or deck.stack.fringe_cap_af_um[row] > 0.0;
}

fn stackOf(s: *const ingest.deck.ProcessStack) extract.Stack {
    return .{ .thickness_nm = s.thickness_nm, .height_nm = s.height_nm, .sheet_res_ohm_sq = s.sheet_res_ohm_sq, .area_cap_af_um2 = s.area_cap_af_um2, .fringe_cap_af_um = s.fringe_cap_af_um, .dielectric_k = s.dielectric_k };
}

fn ownerOf(conductors: []const u32, owner: []const u32, conductor: u32) u32 {
    return owner[std.sort.binarySearch(u32, conductors, conductor, orderU32).?];
}

fn orderU32(key: u32, item: u32) std.math.Order {
    return std.math.order(key, item);
}

fn sortByKey(comptime K: type, map: *std.AutoArrayHashMapUnmanaged(K, f64)) void {
    const Ctx = struct {
        keys: []const K,
        pub fn lessThan(c: @This(), x: usize, y: usize) bool {
            if (K == u32) return c.keys[x] < c.keys[y];
            const p = c.keys[x];
            const q = c.keys[y];
            return p[0] < q[0] or (p[0] == q[0] and p[1] < q[1]);
        }
    };
    map.sort(Ctx{ .keys = map.keys() });
}

/// Why a field solve produced no capacitance, naming the deck layer a mesh
/// refusal is about.
/// ponytail: duplicate of the engine's solve_refusal; dedupe when run.zig lands.
fn solveRefusal(arena: Allocator, loaded: *const Loaded, err: extract.capacitance.Error, why: extract.capacitance.Diagnostic) Allocator.Error![]const u8 {
    const name = loaded.strings.resolve(loaded.deck.deck.layers.name(why.layer));
    return switch (err) {
        error.MissingThickness => arena.print("layer {s}: no pex row gives this layer a positive thickness and permittivity, so it cannot be meshed", .{name}),
        error.InvalidGeometry => arena.print("layer {s}: not valid rectilinear geometry, so it cannot be meshed exactly", .{name}),
        error.DielectricConflict => arena.print("layer {s}: its dielectric differs from another layer's at the same height, so the stack's permittivity there is not defined", .{name}),
        error.TooManyPanels => arena.dupe(u8, "field solve: mesh would exceed the panel limit"),
        error.EmptyConductor => arena.dupe(u8, "field solve: selected net has no geometry"),
        error.NotConverged => arena.print("field solve: did not converge: residual {f} after {d} iterations", .{ Display{ .v = why.failure.residual }, why.failure.iterations }),
        error.Breakdown => arena.print("field solve: system broke down at iteration {d}", .{why.failure.iterations}),
        error.NonFinite => arena.print("field solve: the operator produced a non-finite value at iteration {d}", .{why.failure.iterations}),
        error.OutOfMemory => error.OutOfMemory,
    };
}

/// Rust's `{}` of an `f64`.
const Display = struct {
    v: f64,
    pub fn format(d: Display, w: *std.Io.Writer) std.Io.Writer.Error!void {
        return geom.float.display(w, d.v);
    }
};

/// The same wiring with every conductor's overlapping shapes on a layer
/// merged into one outline, into `out`, and each outline's layout net. Two
/// shapes drawn over each other put panels inside metal, coincident with
/// the other's: a system that never converges. A group the union cannot
/// take is meshed as drawn.
fn mergeOverlaps(arena: Allocator, drawn: *const GeometryStore, origin: []const u32, connectivity: *const ingest.deck.Connectivity, out: *GeometryStore) Allocator.Error![]u32 {
    var nets: topology.NetTable = .{};
    try topology.extractNetsInto(arena, drawn, connectivity, &nets);
    // Shapes by (layer, conductor), in row order.
    const Key = struct { layer: u16, net: u32, row: u32 };
    const keys = try arena.alloc(Key, drawn.polyCount());
    for (keys, 0..) |*k, row| {
        const poly: geom.PolyId = @fromBackingInt(@intCast(row));
        k.* = .{ .layer = @backingInt(drawn.polyLayer(poly)), .net = @backingInt(nets.netOf(poly)), .row = @intCast(row) };
    }
    std.mem.sortUnstable(Key, keys, {}, struct {
        fn less(_: void, p: Key, q: Key) bool {
            if (p.layer != q.layer) return p.layer < q.layer;
            if (p.net != q.net) return p.net < q.net;
            return p.row < q.row;
        }
    }.less);
    var builder: geom.GeometryStoreBuilder = .empty;
    var owners: std.ArrayList(u32) = .empty;
    var alone: geom.ValidatedLayer = .empty;
    var merged: geom.ValidatedLayer = .empty;
    const nothing: geom.ValidatedLayer = .empty;
    var scratch_store: GeometryStore = .empty;
    var scratch_perm: std.ArrayList(u32) = .empty;
    var start: usize = 0;
    while (start < keys.len) {
        var end = start;
        while (end < keys.len and keys[end].layer == keys[start].layer and keys[end].net == keys[start].net) end += 1;
        const group = keys[start..end];
        const layer: LayerId = @fromBackingInt(group[0].layer);
        const owner = origin[group[0].row];
        var overlapping = false;
        for (group, 0..) |p, i| for (group[i + 1 ..]) |q| {
            const x = drawn.polyBbox(@fromBackingInt(p.row));
            const y = drawn.polyBbox(@fromBackingInt(q.row));
            overlapping = overlapping or (@max(x.xlo, y.xlo) < @min(x.xhi, y.xhi) and @max(x.ylo, y.ylo) < @min(x.yhi, y.yhi));
        };
        const outlined = overlapping and blk: {
            var scratch: geom.GeometryStoreBuilder = .empty;
            for (group) |p| {
                const v = drawn.polyVerts(@fromBackingInt(p.row));
                _ = try scratch.push(arena, @fromBackingInt(0), v.xs, v.ys);
            }
            try scratch.finish(arena, 1, &scratch_store, &scratch_perm);
            if (try geom.view.validateLayer(arena, &scratch_store, @fromBackingInt(0), .rectilinear, &alone) != null) break :blk false;
            try geom.boolean.unionInto(arena, &alone, &nothing, &merged);
            for (0..merged.len()) |i| {
                const polygon = merged.get(@intCast(i));
                for (0..polygon.ringCount()) |k| {
                    const ring = polygon.ring(@intCast(k));
                    _ = try builder.push(arena, layer, ring.xs, ring.ys);
                    try owners.append(arena, owner);
                }
            }
            break :blk true;
        };
        if (!outlined) for (group) |p| {
            const v = drawn.polyVerts(@fromBackingInt(p.row));
            _ = try builder.push(arena, layer, v.xs, v.ys);
            try owners.append(arena, origin[p.row]);
        };
        start = end;
    }
    var permutation: std.ArrayList(u32) = .empty;
    try builder.finish(arena, @intCast(drawn.layerCount()), out, &permutation);
    const out_owner = try arena.alloc(u32, permutation.items.len);
    for (out_owner, permutation.items) |*o, old| o.* = owners.items[old];
    return out_owner;
}
