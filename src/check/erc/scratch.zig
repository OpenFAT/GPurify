//! The buffers ERC's rule transforms borrow and refill, one set per run:
//! layer validations, per-net marks, areas, edges, the solve and probe
//! workspaces, and an antenna row's stage nets. No transform reads what
//! another left behind. In: nothing. Out: capacity. Ported from
//! crates/check/src/erc/mod.rs (`Scratch`).
//!
//! Contents:
//! - `pub const Scratch = struct`, `deinit`

const std = @import("std");
const Allocator = std.mem.Allocator;
const geom = @import("geom");
const Bbox = geom.Bbox;
const DbuArea = geom.DbuArea;
const ValidatedLayer = geom.ValidatedLayer;
const NetTable = @import("../topology/net.zig").NetTable;
const SolveScratch = @import("power_solve.zig").SolveScratch;
const probe_ = @import("power_probe.zig");

/// Run-scoped scratch; every field is cleared by the transform that uses it.
pub const Scratch = struct {
    layer_a: ValidatedLayer = .empty,
    layer_b: ValidatedLayer = .empty,
    net_marks: std.ArrayList(u32) = .empty,
    areas: std.ArrayList(DbuArea) = .empty,
    edges: std.ArrayList([2]u32) = .empty,
    solve: SolveScratch = .{},
    probe: probe_.ProbeScratch = .{},
    probes: std.ArrayList(probe_.Probe) = .empty,
    boxes: std.ArrayList(Bbox) = .empty,
    /// An antenna row's nets at its etch stage.
    staged_nets: NetTable = .{},

    pub fn deinit(s: *Scratch, gpa: Allocator) void {
        inline for (@typeInfo(Scratch).@"struct".field_names) |f| @field(s, f).deinit(gpa);
    }
};
