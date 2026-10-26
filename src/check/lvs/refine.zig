//! Partition refinement: the matching algorithm, the iterative graph
//! labelling of C. Ebeling, "GeminiII: a second generation layout validation
//! program", ICCAD 1988, doi:10.1109/ICCAD.1988.122520. In: the two reduced
//! graphs. Out: a class per layout node and per-class tallies in a
//! `Partition`. Classes split by a hash of their neighbours' classes until
//! stable (refine_partition.zig); a balanced stall is broken by a trial
//! pairing (refine_trial.zig), and refinement resumes. Ported from
//! crates/check/src/lvs/refine.rs (`refine_into`, `publish`).
//!
//! Contents:
//! - `pub const Partition`, `pub const Sides`
//! - `pub fn refineInto(gpa: Allocator, layout: *const Graph, reference: *const Graph, max_rounds: u32, tolerance: f64, names: ParamNames, controls: *const LvsControls, seeds: []const u32, models_aside: bool, out: *Partition) Allocator.Error!bool`

const std = @import("std");
const Allocator = std.mem.Allocator;
const LvsControls = @import("ingest").deck.LvsControls;
const graph = @import("graph.zig");
const Graph = graph.Graph;
const no_net = graph.no_net;
const ParamNames = @import("reduce_law.zig").ParamNames;
const part = @import("refine_partition.zig");
const trial = @import("refine_trial.zig");

pub const Partition = part.Partition;
pub const Sides = part.Sides;

/// Refines until stable into `out`. False when more than `max_rounds`
/// passes in a row split a class without settling, which says nothing about
/// whether the graphs match; the count restarts at each tie-break and each
/// trial, so the number of symmetries does not spend it. `tolerance` and
/// `controls` are the verdict's, which a trial's devices must meet. Nets
/// sharing a `seeds` entry (by node, layout first) start in a class of
/// their own; with `models_aside` devices start one class per kind.
pub fn refineInto(gpa: Allocator, layout: *const Graph, reference: *const Graph, max_rounds: u32, tolerance: f64, names: ParamNames, controls: *const LvsControls, seeds: []const u32, models_aside: bool, out: *Partition) Allocator.Error!bool {
    const split = layout.deviceCount() + layout.netCount();
    const sides: Sides = .{ .layout = layout, .reference = reference, .split = split, .names = names, .controls = controls, .seeds = seeds, .models_aside = models_aside };
    try out.seed(gpa, sides);
    var pass_no: u32 = 0;
    var cursor: u32 = 0;
    if (!try trial.settle(out, gpa, sides, max_rounds, &pass_no)) return false;
    while (true) {
        while (cursor < split and trial.settled(out, cursor)) cursor += 1;
        const node = for (cursor..split) |n| (if (trial.stalled(out, @intCast(n))) break @as(u32, @intCast(n))) else {
            try publish(gpa, out, split);
            return true;
        };
        if (!try trial.resolve(out, gpa, node, sides, max_rounds, tolerance, &pass_no)) return false;
    }
}

// ---- private ----

/// Per-class tallies and the layout classes, as the verdict reads them.
fn publish(gpa: Allocator, p: *Partition, split: u32) Allocator.Error!void {
    p.assertValid(split);
    p.layout_tally.clearRetainingCapacity();
    try p.layout_tally.appendSlice(gpa, p.layout_size.items);
    p.ref_tally.clearRetainingCapacity();
    for (p.size.items, p.layout_size.items) |all, layout| try p.ref_tally.append(gpa, all - layout);
    p.ref_first.clearRetainingCapacity();
    try p.ref_first.appendNTimes(gpa, no_net, p.start.items.len);
    for (p.class.items[split..], split..) |class, node| {
        p.ref_first.items[class] = @min(p.ref_first.items[class], @as(u32, @intCast(node)) - split);
    }
    p.layout_class.clearRetainingCapacity();
    try p.layout_class.appendSlice(gpa, p.class.items[0..split]);
}
