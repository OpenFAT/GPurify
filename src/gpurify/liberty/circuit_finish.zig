//! The circuit's numbering: the builder's proto nodes → dense simulator
//! nodes, ground first, each pin's nets joined at the pin. In: the filled
//! `Builder` and the spec's pins. Out: the `Circuit`'s node count, wire
//! elements, device nodes and pin nodes. Ported from src/liberty/circuit.rs
//! (`Builder::{pin_node, finish}`).
//!
//! Contents:
//! - `pub fn finish(b: *Builder, macro: *const MacroSpec, out: *Circuit) Allocator.Error!void`

const std = @import("std");
const Allocator = std.mem.Allocator;
const geom = @import("geom");
const Bbox = geom.Bbox;
const LayerId = geom.LayerId;
const NetId = @import("check").topology.net.NetId;
const MacroSpec = @import("spec.zig").MacroSpec;
const Circuit = @import("circuit.zig").Circuit;
const graph = @import("circuit_graph.zig");
const Builder = graph.Builder;

/// Joins each unreached hub to its net's anchor and each pin's nets at the
/// pin, renumbers the roots densely in proto order (ground first), and
/// writes every element on the final nodes; elements whose ends merged are
/// dropped and parallel capacitors summed.
pub fn finish(b: *Builder, macro: *const MacroSpec, out: *Circuit) Allocator.Error!void {
    const a = b.arena;
    // A hub beside rectangles is reached through via resistors only; one
    // nothing reached is joined to the anchor.
    for (b.net_rects, b.hub, 0..) |list, hub, net| {
        if (list.items.len == 0 or hub == graph.none) continue;
        const reached = std.mem.findScalar(u32, b.resistor_a.items, hub) != null or std.mem.findScalar(u32, b.resistor_b.items, hub) != null;
        if (!reached) b.join(hub, try b.anchor(@fromBackingInt(@intCast(net))));
    }
    const pin_proto = try a.alloc(u32, macro.pins.len);
    for (macro.pins, pin_proto, 0..) |pin, *node, p| {
        const nets = out.pinNets(p);
        node.* = try pinNode(b, pin.name, nets);
        for (nets[1..]) |net| b.join(node.*, try b.anchor(net));
    }
    // Renumber roots densely, in proto order, ground first.
    const total = b.parent.items.len;
    const dense = try a.alloc(u32, total);
    @memset(dense, graph.none);
    var next: u32 = 0;
    for (0..total) |proto| {
        const root = b.find(@intCast(proto));
        if (dense[root] == graph.none) {
            dense[root] = next;
            next += 1;
        }
    }
    out.node_count = next;
    for (b.resistor_a.items, b.resistor_b.items, b.resistor_ohms.items) |x, y, ohms| {
        const p = dense[b.find(x)];
        const q = dense[b.find(y)];
        if (p == q) continue;
        try out.resistor_a.append(a, p);
        try out.resistor_b.append(a, q);
        try out.resistor_ohms.append(a, ohms);
    }
    var merged: std.AutoArrayHashMapUnmanaged([2]u32, f64) = .empty;
    for (b.sortedCaps(), b.caps.values()) |key, f| {
        const p = dense[b.find(key[0])];
        const q = dense[b.find(key[1])];
        if (p == q) continue;
        const slot = try merged.getOrPut(a, .{ @max(p, q), @min(p, q) });
        if (!slot.found_existing) slot.value_ptr.* = 0.0;
        slot.value_ptr.* += f;
    }
    const Ctx = struct {
        keys: []const [2]u32,
        pub fn lessThan(c: @This(), x: usize, y: usize) bool {
            const p = c.keys[x];
            const q = c.keys[y];
            return p[0] < q[0] or (p[0] == q[0] and p[1] < q[1]);
        }
    };
    merged.sort(Ctx{ .keys = merged.keys() });
    for (merged.keys(), merged.values()) |key, f| {
        try out.capacitor_a.append(a, key[0]);
        try out.capacitor_b.append(a, key[1]);
        try out.capacitor_farads.append(a, f);
    }
    for (out.terminal_node.items) |*node| node.* = dense[b.find(node.*)];
    for (pin_proto) |node| try out.pin_node.append(a, dense[b.find(node)]);
}

// ---- private ----

/// The pin's node: the rectangle under its label (one on the layer the
/// label names first, then the first in order), else its first net's anchor.
fn pinNode(b: *Builder, pin: []const u8, nets: []const NetId) Allocator.Error!u32 {
    const loaded = b.loaded;
    const connectivity = &loaded.deck.deck.connectivity;
    const name = loaded.strings.get(pin) orelse return b.anchor(nets[0]);
    const placed = loaded.provenance.placed.slice();
    var best: ?u32 = null;
    var best_named = false;
    for (placed.items(.name), placed.items(.x), placed.items(.y), placed.items(.layer)) |label, x, y, layer| {
        if (label != name) continue;
        const at: Bbox = .point(x, y);
        const named: ?LayerId = for (connectivity.label_layer, connectivity.label_names) |l, n| (if (l == layer) break n) else null;
        for (nets) |net| for (b.net_rects[@backingInt(net)].items) |r| {
            const s = graph.shared(b.rect.items[r], at);
            if (s[0] < 0 or s[1] < 0) continue;
            const on_named = named != null and named.? == b.rect_layer.items[r];
            if (best == null or (on_named and !best_named) or (on_named == best_named and r < best.?)) {
                best = r;
                best_named = on_named;
            }
        };
    }
    return if (best) |r| Builder.rectNode(r) else b.anchor(nets[0]);
}
