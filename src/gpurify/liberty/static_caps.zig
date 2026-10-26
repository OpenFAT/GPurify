//! `analytical`/`field` pin capacitance: each signal pin's wire capacitance
//! plus every touching device terminal's static model capacitance, averaged
//! over the pin's swing. In: the lumped circuit, the wire capacitance per
//! net, a corner. Out: each non-supply input pin's `capacitance`. Ported
//! from src/liberty/mod.rs (`Prepared::static_caps`).
//!
//! Each device touching a pin is its own test: a card with that pin's
//! terminals on a source `vt<t>` swept over nine points of the pin's swing
//! (an analog pin sits at its bias), every other terminal on a DC bias
//! (`vb<k>`, one per distinct rail, bit for bit), and the AC current read
//! as `−Im(I)/ω` at `analog_frequency_hz`.
//!
//! Contents:
//! - `pub fn staticCaps(arena: Allocator, env: Env, macro: *const MacroSpec, corner: *const CornerSpec, c: *const Circuit, wire_ff: []const f64, deck_path: []const u8, pins: []Pin, diag: *Diagnostic) Error!void`

const std = @import("std");
const Allocator = std.mem.Allocator;
const NetId = @import("check").topology.net.NetId;
const spec = @import("spec.zig");
const MacroSpec = spec.MacroSpec;
const CornerSpec = spec.CornerSpec;
const Diagnostic = spec.Diagnostic;
const Circuit = @import("circuit.zig").Circuit;
const spice = @import("spice.zig");
const fmtSi = spice.fmtSi;
const session_ = @import("session.zig");
const Session = session_.Session;
const Env = session_.Env;
const Error = session_.Error;
const Pin = @import("write.zig").Pin;

/// Points of each digital pin's swing.
const points = 9;

/// The one sweep, run on a one-session pool.
const Run = struct {
    commands: []const u8,
    values: []?f64,
    tests: usize,

    fn task(run: *const Run, session: *Session, scratch: Allocator, _: u32, diag: *Diagnostic) Error!void {
        const results = try session.run(scratch, run.commands, diag);
        for (0..run.tests) |t| for (0..points) |k| {
            run.values[t * points + k] = session_.need(&results, try scratch.print("c{d}_{d}", .{ t, k }));
        };
    }
};

/// Measures and sets every input, clock and analog pin's capacitance.
pub fn staticCaps(arena: Allocator, env: Env, macro: *const MacroSpec, corner: *const CornerSpec, c: *const Circuit, wire_ff: []const f64, deck_path: []const u8, pins: []Pin, diag: *Diagnostic) Error!void {
    var deck: std.ArrayList(u8) = .empty;
    for (corner.models) |line| try deck.print(arena, "{s}\n", .{line});
    if (macro.simulator.scale != 1.0) try deck.print(arena, ".option scale={f}\n", .{fmtSi(macro.simulator.scale)});
    try deck.print(arena, ".temp {f}\n", .{fmtSi(corner.temperature)});
    var biases: std.ArrayList(f64) = .empty;
    // Per test source: the pin it measures, and its swing.
    var test_pin: std.ArrayList(usize) = .empty;
    var test_swing: std.ArrayList([]const f64) = .empty;
    var cards: std.ArrayList(u8) = .empty;
    for (macro.pins, 0..) |pin, p| {
        if (pin.role.isSupply() or pin.role == .output) continue;
        const nets = c.pinNets(p);
        const swing: []const f64 = if (pin.role == .analog) try arena.dupe(f64, &.{pin.bias orelse 0.0}) else blk: {
            const lo = supply(corner, pin.ground);
            const hi = supply(corner, pin.power);
            const s = try arena.alloc(f64, points);
            for (s, 0..) |*v, k| v.* = lo + (hi - lo) * @as(f64, @floatFromInt(k)) / @as(f64, points - 1);
            break :blk s;
        };
        for (0..c.deviceCount()) |d| {
            const terms = c.terminal_net.items[c.terminal_start.items[d]..c.terminal_start.items[d + 1]];
            const roles = c.terminal_role.items[c.terminal_start.items[d]..c.terminal_start.items[d + 1]];
            const touches = for (terms) |n| (if (contains(nets, n)) break true) else false;
            if (!touches) continue;
            const t = test_pin.items.len;
            var bulk: f64 = 0.0;
            for (roles, terms) |role, n| if (role == .bulk) {
                bulk = pinned(macro, corner, c, n) orelse 0.0;
                break;
            };
            try cards.print(arena, "{s}t{d}", .{ macro.simulator.prefix, t });
            for (terms) |n| {
                if (contains(nets, n)) {
                    try cards.print(arena, " t{d}", .{t});
                    continue;
                }
                const v = pinned(macro, corner, c, n) orelse bulk;
                const k = for (biases.items, 0..) |b, i| (if (@as(u64, @bitCast(b)) == @as(u64, @bitCast(v))) break i) else blk: {
                    try biases.append(arena, v);
                    break :blk biases.items.len - 1;
                };
                try cards.print(arena, " b{d}", .{k});
            }
            try cards.print(arena, " {s}", .{c.device_model.items[d]});
            var w: std.Io.Writer.Allocating = .fromArrayList(arena, &cards);
            const params = c.paramsOf(d);
            for (params.names, params.values) |name, value| spice.writeParam(&w.writer, name, value, macro.simulator.scale) catch return error.OutOfMemory;
            cards = w.toArrayList();
            try cards.print(arena, "\nvt{d} t{d} 0 DC {f} AC 1\n", .{ t, t, fmtSi(swing[0]) });
            try test_pin.append(arena, p);
            try test_swing.append(arena, swing);
        }
    }
    for (biases.items, 0..) |v, k| try deck.print(arena, "vb{d} b{d} 0 DC {f}\n", .{ k, k, fmtSi(v) });
    try deck.appendSlice(arena, cards.items);
    try deck.appendSlice(arena, ".end\n");
    env.dir.writeFile(env.io, .{ .sub_path = deck_path, .data = deck.items }) catch |err| {
        diag.message = try arena.print("io: {s}: {s}", .{ deck_path, @errorName(err) });
        return error.Io;
    };

    const f = fmtSi(macro.characterization.analog_frequency_hz);
    var commands: std.ArrayList(u8) = .empty;
    for (0..points) |k| {
        for (test_swing.items, 0..) |swing, t| try commands.print(arena, "alter vt{d} dc = {f}\n", .{ t, fmtSi(if (k < swing.len) swing[k] else swing[0]) });
        try commands.print(arena, "ac lin 1 {f} {f}\n", .{ f, f });
        for (0..test_swing.items.len) |t| try commands.print(arena, "let c{d} = -imag(vt{d}#branch)/(2*pi*{f})\necho \"RES c{d}_{d} $&c{d}\"\n", .{ t, t, f, t, k, t });
        try commands.appendSlice(arena, "destroy all\n");
    }
    // Each test's value at each point, null where not measured.
    const values = try arena.alloc(?f64, test_pin.items.len * points);
    @memset(values, null);
    if (test_pin.items.len > 0) {
        const run: Run = .{ .commands = commands.items, .values = values, .tests = test_pin.items.len };
        try session_.runPool(env, macro.simulator, deck_path, corner.name, 1, 1, &run, Run.task, arena, diag);
    }
    for (macro.pins, pins, 0..) |pin, *out, p| {
        if (pin.role.isSupply() or pin.role == .output) continue;
        var wire_pf: f64 = 0.0;
        for (c.pinNets(p)) |n| wire_pf += if (@backingInt(n) < wire_ff.len) wire_ff[@backingInt(n)] else 0.0;
        wire_pf *= 1e-3;
        var device_pf: f64 = 0.0;
        for (test_pin.items, test_swing.items, 0..) |owner, swing, t| {
            if (owner != p) continue;
            const row = values[t * points ..][0..swing.len];
            for (row) |v| if (v == null) {
                diag.message = try arena.print("corner {s}: static capacitance of {s}'s devices", .{ corner.name, pin.name });
                return error.Measure;
            };
            // Trapezoid mean over the swing: charge over swing.
            const mean = if (row.len == 1) row[0].? else blk: {
                const n = row.len - 1;
                var inner: f64 = 0.0;
                for (row[1..n]) |v| inner += v.?;
                break :blk (0.5 * (row[0].? + row[n].?) + inner) / @as(f64, @floatFromInt(n));
            };
            device_pf += mean * 1e12;
        }
        const total = wire_pf + device_pf;
        out.capacitance = .{ total, total };
    }
}

// ---- private ----

fn supply(corner: *const CornerSpec, name: ?[]const u8) f64 {
    return if (name) |n| corner.supplies.get(n).? else 0.0;
}

fn contains(nets: []const NetId, net: NetId) bool {
    return std.mem.indexOfScalar(NetId, nets, net) != null;
}

/// A net's DC voltage when the spec pins it: a supply's corner voltage, an
/// input's related ground, an analog pin's bias; else unknown.
fn pinned(macro: *const MacroSpec, corner: *const CornerSpec, c: *const Circuit, net: NetId) ?f64 {
    for (macro.pins, 0..) |p, i| {
        if (!contains(c.pinNets(i), net)) continue;
        return switch (p.role) {
            .power, .ground, .nwell, .pwell => corner.supplies.get(p.name).?,
            .input, .clock => supply(corner, p.ground),
            .analog => p.bias,
            .output => null,
        };
    }
    return null;
}
