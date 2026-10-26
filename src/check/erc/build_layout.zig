//! The layout-reading kinds' row builders: the latchup, supply, topology
//! and matching kinds (`conditional_tie`, `forward_diode`, `guard_ring`,
//! `guard_ring_bias`, `latchup_victim`, `tie_area`, `matching`,
//! `missing_tie`, `multiple_drivers`, `soft_connection`, `supply_short`,
//! `unconnected_pin`, `mixed_tag`, `floating_gate`, `floating_well`,
//! `fanout`, `supply_path`, `gate_path`, `net_type`). In: one deck row
//! (`Ctx`). Out: its columns pushed onto its kind's table, parameters read
//! in Rust's order. Ported from crates/check/src/erc/ruleset.rs
//! (`RuleSet::from_deck`, those arms).
//!
//! Contents:
//! - `pub fn conditionalTie(c: Ctx) Error!void`, `forwardDiode`, `guardRing`, `guardRingBias`, `latchupVictim`, `tieArea`,
//!   `matching`, `missingTie`, `multipleDrivers`, `softConnection`, `supplyShort`, `unconnectedPin`, `mixedTag`,
//!   `floatingGate`, `floatingWell`, `fanout`, `supplyPath`, `gatePath`, `netType`

const std = @import("std");
const Error = @import("../drc/params.zig").Error;
const compile = @import("compile.zig");
const Ctx = compile.Ctx;
const pushCsr = compile.pushCsr;
const latchup = @import("latchup_tables.zig");

pub fn conditionalTie(c: Ctx) Error!void {
    const row = c.row;
    const layers = try row.layers(4);
    const within = try row.length("within");
    const spacing = try row.lengths("spacing");
    const max_distance = try row.lengths("max_distance");
    const t = &c.rs.tables.conditional_tie;
    const gpa = c.gpa;
    try row.head(gpa, &t.head);
    try t.region.append(gpa, layers[0]);
    try t.tap.append(gpa, layers[1]);
    try t.well.append(gpa, layers[2]);
    try t.other.append(gpa, layers[3]);
    try t.within.append(gpa, within);
    try pushCsr(gpa, &t.spacing_start, &t.spacing, spacing);
    try pushCsr(gpa, &t.max_distance_start, &t.max_distance, max_distance);
}

pub fn forwardDiode(c: Ctx) Error!void {
    const layers = try c.row.layers(1);
    const models = try c.row.models("model");
    const t = &c.rs.tables.forward_diode;
    try c.row.head(c.gpa, &t.head);
    try t.marker.append(c.gpa, layers[0]);
    try pushCsr(c.gpa, &t.model_start, &t.model, models);
}

pub fn guardRing(c: Ctx) Error!void {
    const row = c.row;
    const layers = try row.layers(2);
    const max_space = try row.optLength("max_space");
    const min_width = try row.optLength("min_width");
    const pad = try row.optLayer("pad");
    // `near` and `within` are one condition: both or neither.
    const near_layer = try row.optLayer("near");
    const within = try row.optLength("within");
    if (near_layer != null and within == null) return row.missing("within");
    if (near_layer == null and within != null) return row.missing("near");
    const near: ?latchup.Near = if (near_layer) |l| .{ .layer = l, .within = within.? } else null;
    const t = &c.rs.tables.guard_ring;
    const gpa = c.gpa;
    try row.head(gpa, &t.head);
    try t.target.append(gpa, layers[0]);
    try t.ring.append(gpa, layers[1]);
    try t.max_space.append(gpa, max_space);
    try t.min_width.append(gpa, min_width);
    try t.pad.append(gpa, pad);
    try t.near.append(gpa, near);
    try t.clear.append(gpa, try row.optLayer("clear"));
}

pub fn guardRingBias(c: Ctx) Error!void {
    const layers = try c.row.layers(1);
    const power = try c.row.flagOr("power", true);
    const t = &c.rs.tables.guard_ring_bias;
    try c.row.head(c.gpa, &t.head);
    try t.ring.append(c.gpa, layers[0]);
    try t.power.append(c.gpa, power);
}

pub fn latchupVictim(c: Ctx) Error!void {
    const row = c.row;
    const layers = try row.layers(3);
    const within = try row.length("within");
    const max_distance = try row.length("max_distance");
    const pad = try row.optLayer("pad");
    // `bias` and `forward` are one condition: both or neither.
    const forward: ?bool = if (row.r.optional("forward")) |v| switch (v) {
        .count => |at| at == 0,
        .length, .ratio, .flag, .area, .layer, .model => return row.wrong("forward"),
    } else null;
    const bias_layer = try row.optLayer("bias");
    if (bias_layer != null and forward == null) return row.missing("forward");
    if (bias_layer == null and forward != null) return row.missing("bias");
    const bias: ?latchup.Bias = if (bias_layer) |l| .{ .layer = l, .above = forward.? } else null;
    const t = &c.rs.tables.latchup_victim;
    const gpa = c.gpa;
    try row.head(gpa, &t.head);
    try t.aggressor.append(gpa, layers[0]);
    try t.region.append(gpa, layers[1]);
    try t.tap.append(gpa, layers[2]);
    try t.within.append(gpa, within);
    try t.max_distance.append(gpa, max_distance);
    try t.pad.append(gpa, pad);
    try t.bias.append(gpa, bias);
}

pub fn tieArea(c: Ctx) Error!void {
    const layers = try c.row.layers(3);
    const min_ratio = try c.row.number("min_ratio");
    const t = &c.rs.tables.tie_area;
    try c.row.head(c.gpa, &t.head);
    try t.region.append(c.gpa, layers[0]);
    try t.contact.append(c.gpa, layers[1]);
    try t.channel.append(c.gpa, layers[2]);
    try t.min_ratio.append(c.gpa, min_ratio);
}

pub fn matching(c: Ctx) Error!void {
    const layers = try c.row.layers(1);
    const tolerance = try c.row.length("tolerance");
    const t = &c.rs.tables.matching;
    try c.row.head(c.gpa, &t.head);
    try t.group.append(c.gpa, layers[0]);
    try t.tolerance.append(c.gpa, tolerance);
}

pub fn missingTie(c: Ctx) Error!void {
    const layers = try c.row.layers(2);
    const max_distance = try c.row.length("max_distance");
    const t = &c.rs.tables.missing_tie;
    try c.row.head(c.gpa, &t.head);
    try t.region.append(c.gpa, layers[0]);
    try t.tap.append(c.gpa, layers[1]);
    try t.max_distance.append(c.gpa, max_distance);
}

pub fn multipleDrivers(c: Ctx) Error!void {
    _ = try c.row.layers(0);
    const max_drivers = try c.row.count("max_drivers");
    const t = &c.rs.tables.multiple_drivers;
    try c.row.head(c.gpa, &t.head);
    try t.max_drivers.append(c.gpa, max_drivers);
}

pub fn softConnection(c: Ctx) Error!void {
    const layers = try c.row.layersFrom(1);
    const t = &c.rs.tables.soft_connection;
    try c.row.head(c.gpa, &t.head);
    try pushCsr(c.gpa, &t.soft_start, &t.soft, layers);
}

pub fn supplyShort(c: Ctx) Error!void {
    const layers = try c.row.layersFrom(2);
    const t = &c.rs.tables.supply_short;
    try c.row.head(c.gpa, &t.head);
    try t.tap_a.append(c.gpa, layers[0]);
    try t.tap_b.append(c.gpa, layers[1]);
    try t.within.append(c.gpa, if (layers.len > 2) layers[2] else null);
}

pub fn unconnectedPin(c: Ctx) Error!void {
    const layers = try c.row.layersFrom(1);
    const t = &c.rs.tables.unconnected_pin;
    try c.row.head(c.gpa, &t.head);
    try pushCsr(c.gpa, &t.layer_start, &t.layer, layers);
}

pub fn mixedTag(c: Ctx) Error!void {
    const layers = try c.row.layers(2);
    const t = &c.rs.tables.mixed_tag;
    try c.row.head(c.gpa, &t.head);
    try t.layer.append(c.gpa, layers[0]);
    try t.tag.append(c.gpa, layers[1]);
}

pub fn floatingGate(c: Ctx) Error!void {
    _ = try c.row.layers(0);
    const labels = try c.row.flagOr("labels_are_ports", false);
    const t = &c.rs.tables.floating_gate;
    try c.row.head(c.gpa, &t.head);
    try t.labels_are_ports.append(c.gpa, labels);
}

pub fn floatingWell(c: Ctx) Error!void {
    const layers = try c.row.layers(2);
    const t = &c.rs.tables.floating_well;
    try c.row.head(c.gpa, &t.head);
    try t.well.append(c.gpa, layers[0]);
    try t.tap.append(c.gpa, layers[1]);
}

pub fn fanout(c: Ctx) Error!void {
    _ = try c.row.layers(0);
    const max_gates = try c.row.count("max_gates");
    const t = &c.rs.tables.fanout;
    try c.row.head(c.gpa, &t.head);
    try t.max_gates.append(c.gpa, max_gates);
}

pub fn supplyPath(c: Ctx) Error!void {
    _ = try c.row.layers(0);
    const both = try c.row.flagOr("both", false);
    const labels = try c.row.flagOr("labels_are_ports", false);
    const t = &c.rs.tables.supply_path;
    try c.row.head(c.gpa, &t.head);
    try t.both.append(c.gpa, both);
    try t.labels_are_ports.append(c.gpa, labels);
}

pub fn gatePath(c: Ctx) Error!void {
    _ = try c.row.layers(0);
    const ground = try c.row.flagOr("ground", true);
    const max_devices = try c.row.count("max_devices");
    const t = &c.rs.tables.gate_path;
    try c.row.head(c.gpa, &t.head);
    try t.ground.append(c.gpa, ground);
    try t.max_devices.append(c.gpa, max_devices);
}

pub fn netType(c: Ctx) Error!void {
    const row = c.row;
    _ = try row.layers(0);
    const net = try row.condition("net");
    const path = try row.condition("path");
    const breaks = try row.condition("break");
    const exclude = try row.models("exclude");
    const t = &c.rs.tables.net_type;
    const gpa = c.gpa;
    try row.head(gpa, &t.head);
    try pushCsr(gpa, &t.net_start, &t.net, net);
    try pushCsr(gpa, &t.path_start, &t.path, path);
    try pushCsr(gpa, &t.break_start, &t.breaks, breaks);
    try pushCsr(gpa, &t.exclude_start, &t.exclude, exclude);
}
