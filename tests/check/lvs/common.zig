//! Graphs built by hand, and the vocabulary the LVS suite asserts in.
//! Fixtures are construct-from-answer: the expected pairing is a fact about
//! how the graph was written. Ported from crates/check/tests/lvs/common/mod.rs
//! (`GraphBuilder`, the fixtures, `random_graph`, `permute`, `perturbed`,
//! `seeded_corpus`, `canonical`, `flip`, `assert_same_discrepancies`), with
//! Rust's `{:?}` of a verdict written out (`writeVerdict`) for the digest.
//!
//! Contents:
//! - ids `nch`, `pch`, `npn`, `res`, `width`, `length`, `vdd`, `vss`; `pub fn id(n: u32) StrId`
//! - `pub const T`, `pub const P`, `pub const GraphBuilder`, `init`, `deinit`, `device`, `deviceWithParams`, `nameNet`, `port`, `finish`
//! - fixtures `stackedPair`, `stackedPairWithParams`, `mosAndBjt`, `mosAndBjtWithoutTheBjt`, `differentialPair`, `chain`,
//!   `randomGraph`, `permute`, `perm`, `perturbed`
//! - `pub const Result`, `pub fn compare`, `pub fn compareWith`, `pub fn decisive`, `pub fn expectMatch`, `pub fn expectNotMatch`,
//!   `pub fn discrepancies`, `pub fn flip`, `pub fn flipSide`, `pub fn eql`, `pub fn contains`, `pub fn assertSame`,
//!   `pub fn blamesDevice`, `pub fn blamesNet`
//! - `pub const Reduced`, `pub fn reduce`, `pub fn graphEql`, `pub fn expectGraphEql`, `pub fn expectParams`
//! - `pub fn writeVerdict`, `pub fn writeCanonical`, `pub fn writeDiscrepancy`

const std = @import("std");
const testing = std.testing;
const geom = @import("geom");
const StrId = geom.StrId;
const ingest = @import("ingest");
const DeviceKind = ingest.deck.DeviceKind;
const LvsControls = ingest.deck.LvsControls;
const check = @import("check");
const lvs = check.lvs;
const Graph = lvs.Graph;
const Discrepancy = lvs.Discrepancy;
const Side = lvs.Side;
const TerminalRole = check.topology.TerminalRole;
const Rng = @import("testgen").Rng;
const gpa = testing.allocator;

pub const nch = id(1);

pub const pch = id(2);

pub const npn = id(3);

pub const res = id(4);

pub const width = id(5);

pub const length = id(6);

pub const vdd = id(7);

pub const vss = id(8);

/// A terminal: role and net.
pub const T = struct { TerminalRole, u32 };

/// A parameter: name and value.
pub const P = struct { StrId, f64 };

/// Accumulates devices and nets, then lays them out as `Graph`'s columns;
/// the net side is derived (the transpose), never stated.
pub const GraphBuilder = struct {
    g: Graph = .{},
    nets: u32,

    pub fn init(nets: u32) GraphBuilder {
        return .{ .nets = nets };
    }

    pub fn deinit(b: *GraphBuilder) void {
        b.g.deinit(gpa);
    }

    pub fn device(b: *GraphBuilder, kind: DeviceKind, model: StrId, terminals: []const T) !u32 {
        return b.deviceWithParams(kind, model, terminals, &.{});
    }

    pub fn deviceWithParams(b: *GraphBuilder, kind: DeviceKind, model: StrId, terminals: []const T, params: []const P) !u32 {
        std.debug.assert(terminals.len > 0);
        try b.ensureStarted();
        for (terminals) |t| {
            std.debug.assert(t[1] < b.nets);
            try b.g.terminal_role.append(gpa, t[0]);
            try b.g.terminal_net.append(gpa, t[1]);
        }
        for (params) |p| try b.g.param.append(gpa, .{ .name = p[0], .value = p[1] });
        try b.g.device_kind.append(gpa, kind);
        try b.g.device_model.append(gpa, model);
        try b.g.device_terminal_start.append(gpa, @intCast(b.g.terminal_net.items.len));
        try b.g.device_param_start.append(gpa, @intCast(b.g.param.items.len));
        return b.g.deviceCount() - 1;
    }

    pub fn nameNet(b: *GraphBuilder, net: u32, name: StrId) !void {
        try b.ensureStarted();
        b.g.net_name.items[net] = name;
    }

    pub fn port(b: *GraphBuilder, net: u32) !void {
        std.debug.assert(net < b.nets);
        try b.ensureStarted();
        try b.g.port_net.append(gpa, net);
    }

    /// The graph; the builder is spent (deinit is then a no-op).
    pub fn finish(b: *GraphBuilder) !Graph {
        try b.ensureStarted();
        try lvs.graph.transposeInto(gpa, &b.g, b.nets);
        const out = b.g;
        b.g = .{};
        return out;
    }

    // ---- private ----

    fn ensureStarted(b: *GraphBuilder) !void {
        if (b.g.device_terminal_start.items.len != 0) return;
        try b.g.device_terminal_start.append(gpa, 0);
        try b.g.device_param_start.append(gpa, 0);
        try b.g.net_name.appendNTimes(gpa, null, b.nets);
    }
};

/// A comparison's whole answer; `deinit` frees it.
pub const Result = lvs.Traced;

/// A reduction's graph and merges; `deinit` frees both.
pub const Reduced = struct {
    g: Graph = .{},
    merges: lvs.Merges = .{},

    pub fn deinit(r: *Reduced) void {
        r.g.deinit(gpa);
        r.merges.deinit(gpa);
    }
};

pub fn id(n: u32) StrId {
    return @fromBackingInt(@intCast(n));
}

/// Two transistors stacked gate-to-drain, sharing a bulk. Nets: 0 the lower
/// gate, 1 the lower source, 2 the shared drain-gate node, 3 the bulk, 4 the
/// upper source, 5 the upper drain. Not rigid: nets 4 and 5 trade places.
pub fn stackedPair() !Graph {
    return stackedPairWithParams(&.{}, &.{});
}

pub fn stackedPairWithParams(lower: []const P, upper: []const P) !Graph {
    var b = GraphBuilder.init(6);
    defer b.deinit();
    _ = try b.deviceWithParams(.mos, nch, &.{ .{ .gate, 0 }, .{ .source, 1 }, .{ .drain, 2 }, .{ .bulk, 3 } }, lower);
    _ = try b.deviceWithParams(.mos, nch, &.{ .{ .gate, 2 }, .{ .source, 4 }, .{ .drain, 5 }, .{ .bulk, 3 } }, upper);
    return b.finish();
}

/// A MOS on nets 0..=3 and a bipolar on 4..=6, sharing nothing.
pub fn mosAndBjt() !Graph {
    var b = GraphBuilder.init(7);
    defer b.deinit();
    try addMos(&b, 0);
    try addBjt(&b, 4);
    return b.finish();
}

/// `mosAndBjt` with the bipolar deleted; its three nets stay.
pub fn mosAndBjtWithoutTheBjt() !Graph {
    var b = GraphBuilder.init(7);
    defer b.deinit();
    try addMos(&b, 0);
    return b.finish();
}

/// Two transistors sharing a tail (0) and a bulk (5), gates 1 and 2,
/// drains 3 and 4: genuinely symmetric, no ports.
pub fn differentialPair() !Graph {
    var b = GraphBuilder.init(6);
    defer b.deinit();
    _ = try b.device(.mos, nch, &.{ .{ .gate, 1 }, .{ .source, 0 }, .{ .drain, 3 }, .{ .bulk, 5 } });
    _ = try b.device(.mos, nch, &.{ .{ .gate, 2 }, .{ .source, 0 }, .{ .drain, 4 }, .{ .bulk, 5 } });
    return b.finish();
}

/// A source-to-drain chain of `devices` transistors over `devices + 1` nets,
/// device 0 diode-connected at the low end: rigid.
pub fn chain(devices: u32) !Graph {
    std.debug.assert(devices > 0);
    var b = GraphBuilder.init(devices + 1);
    defer b.deinit();
    _ = try b.device(.mos, nch, &.{ .{ .source, 0 }, .{ .drain, 1 }, .{ .gate, 0 } });
    for (1..devices) |i| {
        const k: u32 = @intCast(i);
        _ = try b.device(.mos, nch, &.{ .{ .source, k }, .{ .drain, k + 1 } });
    }
    return b.finish();
}

/// An arbitrary well-formed graph fixed by a seed: each device two to four
/// distinct roles on uniform nets, model `nch` or `pch`.
pub fn randomGraph(rng: *Rng, devices: u32, nets: u32) !Graph {
    std.debug.assert(devices > 0 and nets > 0);
    const roles = [_]TerminalRole{ .gate, .source, .drain, .bulk };
    var b = GraphBuilder.init(nets);
    defer b.deinit();
    var terminals: [4]T = undefined;
    for (0..devices) |_| {
        const count: usize = 2 + @as(usize, @intCast(rng.below(3)));
        for (terminals[0..count], roles[0..count]) |*t, r| t.* = .{ r, @intCast(rng.below(nets)) };
        const model = if (rng.unit() < 0.5) nch else pch;
        _ = try b.device(.mos, model, terminals[0..count]);
    }
    return b.finish();
}

/// `source` relabelled: `new_device[old]` and `new_net[old]` give each row's
/// new index (each a permutation). Isomorphic by construction.
pub fn permute(source: *const Graph, new_device: []const u32, new_net: []const u32) !Graph {
    const devices = source.deviceCount();
    std.debug.assert(new_device.len == devices and new_net.len == source.netCount());
    const order = try gpa.alloc(u32, devices);
    defer gpa.free(order);
    for (new_device, 0..) |n, old| order[n] = @intCast(old);
    var b = GraphBuilder.init(source.netCount());
    defer b.deinit();
    var terminals: std.ArrayList(T) = .empty;
    defer terminals.deinit(gpa);
    var params: std.ArrayList(P) = .empty;
    defer params.deinit(gpa);
    for (order) |old| {
        terminals.clearRetainingCapacity();
        params.clearRetainingCapacity();
        const t = source.terminalsOf(old);
        for (t.nets, t.roles) |n, r| try terminals.append(gpa, .{ r, new_net[n] });
        for (source.paramsOf(old)) |p| try params.append(gpa, .{ p.name, p.value });
        _ = try b.deviceWithParams(source.device_kind.items[old], source.device_model.items[old], terminals.items, params.items);
    }
    for (source.net_name.items, 0..) |name, old| if (name) |n| try b.nameNet(new_net[old], n);
    for (source.port_net.items) |n| try b.port(new_net[n]);
    return b.finish();
}

/// A random permutation of `0..n`, caller-freed.
pub fn perm(rng: *Rng, n: usize) ![]u32 {
    const map = try gpa.alloc(u32, n);
    for (map, 0..) |*m, i| m.* = @intCast(i);
    rng.shuffle(u32, map);
    return map;
}

/// A copy with one terminal moved to another net: a real mismatch.
pub fn perturbed(rng: *Rng, g: *const Graph) !Graph {
    var out = try g.clone(gpa);
    defer out.deinit(gpa);
    const slot: usize = @intCast(rng.below(out.terminal_net.items.len));
    out.terminal_net.items[slot] = @intCast(rng.below(out.netCount()));
    const ids = try gpa.alloc(u32, out.deviceCount());
    defer gpa.free(ids);
    for (ids, 0..) |*x, i| x.* = @intCast(i);
    const nets = try gpa.alloc(u32, out.netCount());
    defer gpa.free(nets);
    for (nets, 0..) |*x, i| x.* = @intCast(i);
    return permute(&out, ids, nets);
}

pub fn compare(layout: *const Graph, reference: *const Graph, options: lvs.CompareOptions) !Result {
    return compareWith(layout, reference, options, &.{});
}

pub fn compareWith(layout: *const Graph, reference: *const Graph, options: lvs.CompareOptions, controls: *const LvsControls) !Result {
    var out: Result = .{};
    errdefer out.deinit(gpa);
    try lvs.compareTraced(gpa, layout, reference, options, controls, &out);
    return out;
}

/// Options that never run out of rounds.
pub fn decisive() lvs.CompareOptions {
    return .{ .max_rounds = 512, .param_tolerance = 1e-6 };
}

pub fn expectMatch(r: *const Result) !void {
    if (r.verdict != .match) {
        std.debug.print("expected a match, got ", .{});
        printVerdict(r);
        return error.TestExpectedMatch;
    }
}

pub fn expectNotMatch(r: *const Result) !void {
    if (r.verdict == .match) return error.TestUnexpectedMatch;
}

/// The discrepancies of a mismatch; fails on any other verdict.
pub fn discrepancies(r: *const Result) ![]const Discrepancy {
    if (r.verdict != .mismatch) {
        std.debug.print("expected a mismatch, got ", .{});
        printVerdict(r);
        return error.TestExpectedMismatch;
    }
    return r.found.items;
}

pub fn flipSide(side: Side) Side {
    return switch (side) {
        .layout => .reference,
        .reference => .layout,
    };
}

/// A discrepancy restated from the other side's point of view.
pub fn flip(d: Discrepancy) Discrepancy {
    return switch (d) {
        .unpaired_device => |x| .{ .unpaired_device = .{ .side = flipSide(x.side), .device = x.device, .model = x.model } },
        .unpaired_net => |x| .{ .unpaired_net = .{ .side = flipSide(x.side), .net = x.net, .name = x.name } },
        .terminal_mismatch => |x| .{ .terminal_mismatch = .{ .layout_device = x.ref_device, .ref_device = x.layout_device, .role = x.role } },
        .parameter_mismatch => |x| .{ .parameter_mismatch = .{ .layout_device = x.ref_device, .ref_device = x.layout_device, .param = x.param, .layout_value = x.ref_value, .ref_value = x.layout_value } },
        .undeclared_param => |x| .{ .undeclared_param = .{ .side = flipSide(x.side), .layout_device = x.ref_device, .ref_device = x.layout_device, .param = x.param } },
        .model_mismatch => |x| .{ .model_mismatch = .{ .layout_device = x.ref_device, .ref_device = x.layout_device, .layout_model = x.ref_model, .ref_model = x.layout_model } },
        .class_imbalance => |x| .{ .class_imbalance = .{ .layout_nodes = x.ref_nodes, .ref_nodes = x.layout_nodes } },
    };
}

/// Value equality, as Rust's derived `PartialEq` (floats as floats).
pub fn eql(a: Discrepancy, b: Discrepancy) bool {
    return std.meta.eql(a, b);
}

pub fn contains(found: []const Discrepancy, want: Discrepancy) bool {
    for (found) |d| if (eql(d, want)) return true;
    return false;
}

/// The two lists hold the same findings, as multisets.
pub fn assertSame(actual: []const Discrepancy, expected: []const Discrepancy) !void {
    const taken = try gpa.alloc(bool, actual.len);
    defer gpa.free(taken);
    @memset(taken, false);
    for (expected) |want| {
        const at = for (actual, 0..) |have, i| (if (!taken[i] and eql(have, want)) break i) else {
            std.debug.print("no discrepancy matches {any}\nfound: {any}\n", .{ want, actual });
            return error.TestMissingDiscrepancy;
        };
        taken[at] = true;
    }
    for (taken, actual) |t, d| if (!t) {
        std.debug.print("unexpected discrepancy {any}\n", .{d});
        return error.TestExtraDiscrepancy;
    };
}

/// Whether a discrepancy blames device `index` on `side`.
pub fn blamesDevice(d: Discrepancy, side: Side, index: u32) bool {
    return switch (d) {
        .unpaired_device => |x| x.side == side and x.device == index,
        .terminal_mismatch => |x| if (side == .layout) x.layout_device == index else x.ref_device == index,
        .parameter_mismatch => |x| if (side == .layout) x.layout_device == index else x.ref_device == index,
        .unpaired_net, .undeclared_param, .model_mismatch, .class_imbalance => false,
    };
}

/// Whether a discrepancy blames net `index` on `side`.
pub fn blamesNet(d: Discrepancy, side: Side, index: u32) bool {
    return switch (d) {
        .unpaired_net => |x| x.side == side and x.net == index,
        .unpaired_device, .terminal_mismatch, .parameter_mismatch, .undeclared_param, .model_mismatch, .class_imbalance => false,
    };
}

pub fn reduce(src: *const Graph, names: lvs.ParamNames) !Reduced {
    var out: Reduced = .{};
    errdefer out.deinit();
    try lvs.reduceWith(gpa, src, names, &out.g, &out.merges);
    return out;
}

/// Every column equal, as Rust's derived `PartialEq` on `Graph`.
pub fn graphEql(a: *const Graph, b: *const Graph) bool {
    inline for (@typeInfo(Graph).@"struct".field_names) |f| {
        if (!std.meta.eql(@field(a, f).items.len, @field(b, f).items.len)) return false;
        for (@field(a, f).items, @field(b, f).items) |x, y| if (!std.meta.eql(x, y)) return false;
    }
    return true;
}

pub fn expectGraphEql(want: *const Graph, got: *const Graph) !void {
    if (!graphEql(want, got)) return error.TestGraphsDiffer;
}

/// One device's parameters, sorted by name, exactly `want` (sorted by name).
pub fn expectParams(g: *const Graph, device: u32, want: []const P) !void {
    const got = try gpa.dupe(lvs.Param, g.paramsOf(device));
    defer gpa.free(got);
    std.mem.sort(lvs.Param, got, {}, struct {
        fn less(_: void, a: lvs.Param, b: lvs.Param) bool {
            return @backingInt(a.name) < @backingInt(b.name);
        }
    }.less);
    if (got.len != want.len) {
        std.debug.print("params {any}, want {any}\n", .{ got, want });
        return error.TestParamsDiffer;
    }
    for (got, want) |g_, w| {
        if (g_.name != w[0] or g_.value != w[1]) {
            std.debug.print("params {any}, want {any}\n", .{ got, want });
            return error.TestParamsDiffer;
        }
    }
}

/// Rust's `{:?}` of the verdict, byte for byte.
pub fn writeVerdict(w: *std.Io.Writer, r: *const Result) !void {
    switch (r.verdict) {
        .match => try w.writeAll("Match"),
        .inconclusive => |why| try w.writeAll(switch (why) {
            .round_limit => "Inconclusive(RoundLimit)",
            .ambiguous_top => "Inconclusive(AmbiguousTop)",
        }),
        .mismatch => {
            try w.writeAll("Mismatch([");
            for (r.found.items, 0..) |d, i| {
                if (i > 0) try w.writeAll(", ");
                try writeDiscrepancy(w, d);
            }
            try w.writeAll("])");
        },
    }
}

/// The verdict with its discrepancies' texts sorted (Rust's `canonical`):
/// equal exactly when two verdicts report the same differences.
pub fn writeCanonical(w: *std.Io.Writer, r: *const Result) !void {
    if (r.verdict != .mismatch) return writeVerdict(w, r);
    var lines: std.ArrayList([]u8) = .empty;
    defer {
        for (lines.items) |l| gpa.free(l);
        lines.deinit(gpa);
    }
    for (r.found.items) |d| {
        var buf: std.Io.Writer.Allocating = .init(gpa);
        defer buf.deinit();
        try writeDiscrepancy(&buf.writer, d);
        try lines.append(gpa, try buf.toOwnedSlice());
    }
    std.mem.sortUnstable([]u8, lines.items, {}, struct {
        fn less(_: void, a: []u8, b: []u8) bool {
            return std.mem.lessThan(u8, a, b);
        }
    }.less);
    try w.writeAll("Mismatch[");
    for (lines.items, 0..) |l, i| {
        if (i > 0) try w.writeAll(", ");
        try w.print("\"{s}\"", .{l});
    }
    try w.writeAll("]");
}

pub fn writeDiscrepancy(w: *std.Io.Writer, d: Discrepancy) !void {
    switch (d) {
        .unpaired_device => |x| try w.print("UnpairedDevice {{ side: {s}, device: {d}, model: StrId({d}) }}", .{ sideName(x.side), x.device, @backingInt(x.model) }),
        .unpaired_net => |x| {
            try w.print("UnpairedNet {{ side: {s}, net: {d}, name: ", .{ sideName(x.side), x.net });
            if (x.name) |n| try w.print("Some(StrId({d}))", .{@backingInt(n)}) else try w.writeAll("None");
            try w.writeAll(" }");
        },
        .terminal_mismatch => |x| {
            try w.print("TerminalMismatch {{ layout_device: {d}, ref_device: {d}, role: ", .{ x.layout_device, x.ref_device });
            try writeRole(w, x.role);
            try w.writeAll(" }");
        },
        .parameter_mismatch => |x| {
            try w.print("ParameterMismatch {{ layout_device: {d}, ref_device: {d}, param: StrId({d}), layout_value: ", .{ x.layout_device, x.ref_device, @backingInt(x.param) });
            try writeFloat(w, x.layout_value);
            try w.writeAll(", ref_value: ");
            try writeFloat(w, x.ref_value);
            try w.writeAll(" }");
        },
        .undeclared_param => |x| try w.print("UndeclaredParam {{ side: {s}, layout_device: {d}, ref_device: {d}, param: StrId({d}) }}", .{ sideName(x.side), x.layout_device, x.ref_device, @backingInt(x.param) }),
        .model_mismatch => |x| try w.print("ModelMismatch {{ layout_device: {d}, ref_device: {d}, layout_model: StrId({d}), ref_model: StrId({d}) }}", .{ x.layout_device, x.ref_device, @backingInt(x.layout_model), @backingInt(x.ref_model) }),
        .class_imbalance => |x| try w.print("ClassImbalance {{ layout_nodes: {d}, ref_nodes: {d} }}", .{ x.layout_nodes, x.ref_nodes }),
    }
}

// ---- private ----

fn addMos(b: *GraphBuilder, base: u32) !void {
    _ = try b.device(.mos, nch, &.{ .{ .gate, base }, .{ .source, base + 1 }, .{ .drain, base + 2 }, .{ .bulk, base + 3 } });
}

fn addBjt(b: *GraphBuilder, base: u32) !void {
    _ = try b.device(.bjt, npn, &.{ .{ .base, base }, .{ .emitter, base + 1 }, .{ .collector, base + 2 } });
}

fn sideName(side: Side) []const u8 {
    return switch (side) {
        .layout => "Layout",
        .reference => "Reference",
    };
}

fn writeRole(w: *std.Io.Writer, role: TerminalRole) !void {
    switch (role) {
        .gate => try w.writeAll("Gate"),
        .source => try w.writeAll("Source"),
        .drain => try w.writeAll("Drain"),
        .bulk => try w.writeAll("Bulk"),
        .base => try w.writeAll("Base"),
        .emitter => try w.writeAll("Emitter"),
        .collector => try w.writeAll("Collector"),
        .pin => |p| try w.print("Pin({d})", .{p}),
    }
}

/// Close to Rust's `{:?}` of an `f64` (shortest round-trip digits, `.0`
/// on a whole number); only failure messages read it, never the digest.
fn writeFloat(w: *std.Io.Writer, v: f64) !void {
    if (v == @trunc(v) and @abs(v) < 1e16) return w.print("{d}.0", .{v});
    try w.print("{e}", .{v});
}

fn printVerdict(r: *const Result) void {
    var buf: [4096]u8 = undefined;
    var w: std.Io.Writer = .fixed(&buf);
    writeVerdict(&w, r) catch {};
    std.debug.print("{s}\n", .{w.buffered()});
}
