//! What a merge sums and what must agree: the parameter names a merge reads,
//! each device law's sums, and the signature two devices must share to be
//! one. In: a device's kind and parameters. Out: values and key rows the
//! reduce passes compare. Ported from crates/check/src/lvs/reduce.rs
//! (`ParamNames`, `Law`, `signature`, `sums_width`, `parallel_sums`,
//! `count_of`, `is_channel`, `series_passive`).
//!
//! Contents:
//! - `pub const ParamNames = struct`, `across(n: ParamNames, name: StrId) ?StrId`,
//!   `tolerance(n: ParamNames, name: StrId, default: f64) f64`, `diffusionsIn(n: ParamNames, params: []const Param) usize`
//! - `pub const Law = struct`, `of(kind: DeviceKind, params: []const Param, names: ParamNames) ?Law`,
//!   `combines(law: Law, name: StrId) bool`, `times(law: Law, name: StrId, value: f64, m: f64) f64`,
//!   `sums(law: Law) Sums`, `seriesSums(law: Law, kind: DeviceKind, names: ParamNames) ?Sums`
//! - `pub const Sums = [6]?StrId`, `pub const Sig = struct { name: u32, bits: u64 }`
//! - `pub fn is(opt: ?StrId, name: StrId) bool`, `pub fn states(params: []const Param, name: ?StrId) bool`
//! - `pub fn sumsWidth(kind: DeviceKind, params: []const Param, names: ParamNames) bool`
//! - `pub fn parallelSums(wide: bool, names: ParamNames) Sums`
//! - `pub fn countOf(params: []const Param, multiplier: StrId) f64`
//! - `pub fn isChannel(role: TerminalRole) bool`, `pub fn seriesPassive(kind: DeviceKind) bool`
//! - `pub fn signatureInto(gpa: Allocator, params: []const Param, summed: []const ?StrId, ignored: ?StrId, out: *std.ArrayList(Sig)) Allocator.Error!void`
//! - `pub fn sigOrder(a: []const Sig, b: []const Sig) std.math.Order`

const std = @import("std");
const Allocator = std.mem.Allocator;
const geom = @import("geom");
const StrId = geom.StrId;
const DeviceKind = @import("ingest").deck.DeviceKind;
const TerminalRole = @import("../topology/device.zig").TerminalRole;
const Param = @import("graph.zig").Param;

/// Which interned parameter names mean what to a merge. A name absent from
/// both netlists is null. The default names nothing, and then nothing
/// merges: no `W` to sum, no count to keep, no `L` for a series merge.
pub const ParamNames = struct {
    /// `W`: summed by a parallel merge of MOS stating it, multiplied by `m`.
    width: ?StrId = null,
    /// `L`: summed by a series merge, which needs it on both devices.
    length: ?StrId = null,
    /// `nf`: summed by a parallel merge of MOS stating `W`.
    fingers: ?StrId = null,
    /// `m`: folded into a MOS's `W` when `width` is named; any other
    /// device's count in parallel, which a parallel merge sums.
    multiplier: ?StrId = null,
    /// `as`, `ad`, `ps`, `pd`: each belongs to one channel end.
    diffusion: [4]?StrId = @splat(null),
    /// `r`, `c`, `area`, `perim`, `ae`, `pe`: a value and what adds with it
    /// under `relaxed`.
    values: [6]?StrId = @splat(null),
    /// `ind`: combines under `relaxed` as a resistance does (catalog LVS-065).
    inductance: ?StrId = null,
    /// `sa`, `sb`: a transistor stating either merges only in parallel.
    stress: [2]?StrId = @splat(null),
    /// Logic-gate reduction (the deck's `lvs recognize_gates`; LVS-047).
    gates: bool = false,
    /// Netgen's `property topology relaxed` (the deck's `lvs topology relaxed`).
    relaxed: bool = false,

    /// The name at the channel's other end: `ad` for `as`, `pd` for `ps` and
    /// back; any other name itself. Null where that name is no name of the run.
    pub fn across(n: ParamNames, name: StrId) ?StrId {
        for (n.diffusion, 0..) |d, at| if (is(d, name)) return n.diffusion[at ^ 1];
        return name;
    }

    /// The run's relative tolerance for `name`: `default`, except a count
    /// (`m`, `nf`), a whole number that agrees only exactly (testing-plan F99).
    pub fn tolerance(n: ParamNames, name: StrId, default: f64) f64 {
        return if (is(n.multiplier, name) or is(n.fingers, name)) 0.0 else default;
    }

    /// How many of the four diffusion names `params` states.
    pub fn diffusionsIn(n: ParamNames, params: []const Param) usize {
        var count: usize = 0;
        for (n.diffusion) |d| count += @intFromBool(d != null and states(params, d));
        return count;
    }
};

/// Up to six names a merge combines; null slots are none.
pub const Sums = [6]?StrId;

/// One parameter of a merge signature: name and value bits (zero for a
/// summed one, which must be stated by both or neither).
pub const Sig = struct { name: u32, bits: u64 };

/// How a relaxed merge combines a passive's or bipolar's parameters: the
/// value, whether it combines harmonically (a resistance), what else adds.
pub const Law = struct {
    value: StrId,
    harmonic: bool,
    adds: [3]?StrId,

    /// Null under the strict policy, for a MOS or a black box, and for a
    /// device that states no value.
    pub fn of(kind: DeviceKind, params: []const Param, names: ParamNames) ?Law {
        if (!names.relaxed) return null;
        const v = names.values;
        const law: Law = switch (kind) {
            .resistor => .{ .value = v[0] orelse return null, .harmonic = true, .adds = .{ names.width, v[2], v[3] } },
            .capacitor => .{ .value = v[1] orelse return null, .harmonic = false, .adds = .{ v[2], v[3], null } },
            .diode => .{ .value = v[2] orelse return null, .harmonic = false, .adds = .{ v[3], null, null } },
            .bjt => .{ .value = v[4] orelse return null, .harmonic = false, .adds = .{ v[5], v[2], v[3] } },
            .inductor => .{ .value = names.inductance orelse return null, .harmonic = true, .adds = .{ null, null, null } },
            .mos, .cell => return null,
        };
        return if (states(params, law.value)) law else null;
    }

    pub fn combines(law: Law, name: StrId) bool {
        if (name == law.value) return true;
        for (law.adds) |a| if (is(a, name)) return true;
        return false;
    }

    /// `name`'s value for `m` devices of `value` in parallel.
    pub fn times(law: Law, name: StrId, value: f64, m: f64) f64 {
        return if (law.harmonic and name == law.value) value / m else value * m;
    }

    /// The names a parallel merge under this law combines.
    pub fn sums(law: Law) Sums {
        return .{ law.value, law.adds[0], law.adds[1], law.adds[2], null, null };
    }

    /// The names a series merge of `kind` combines: the value by the
    /// opposite law, `area` and `perim` adding, a resistor's `l` too
    /// (KLayout's serial combiners). A resistor's `w` must agree. Null for a
    /// kind that never merges in series.
    pub fn seriesSums(law: Law, kind: DeviceKind, names: ParamNames) ?Sums {
        const area = names.values[2];
        const perim = names.values[3];
        return switch (kind) {
            .resistor => .{ law.value, names.length, area, perim, null, null },
            .capacitor => .{ law.value, area, perim, null, null, null },
            .inductor => .{ law.value, null, null, null, null, null },
            .mos, .bjt, .diode, .cell => null,
        };
    }
};

/// Whether `opt` names `name`.
pub fn is(opt: ?StrId, name: StrId) bool {
    return if (opt) |o| o == name else false;
}

/// Whether `params` states `name` (never, for a null name).
pub fn states(params: []const Param, name: ?StrId) bool {
    const n = name orelse return false;
    for (params) |p| if (p.name == n) return true;
    return false;
}

/// Whether a parallel merge sums this device's `W`: a MOS stating one.
/// Every other device, a MOS with no `W` included, keeps its count in `m`
/// (testing-plan F83).
pub fn sumsWidth(kind: DeviceKind, params: []const Param, names: ParamNames) bool {
    return kind == .mos and states(params, names.width);
}

/// The parameters a parallel merge of MOS stating `W` sums: `W`, `nf` and
/// the four diffusions. Any other device sums its count instead.
pub fn parallelSums(wide: bool, names: ParamNames) Sums {
    if (!wide) return @splat(null);
    const d = names.diffusion;
    return .{ names.width, names.fingers, d[0], d[1], d[2], d[3] };
}

/// A device's count: its `m`, or 1 when it states none.
pub fn countOf(params: []const Param, multiplier: StrId) f64 {
    for (params) |p| if (p.name == multiplier) return p.value;
    return 1.0;
}

/// The two ends of a MOS channel, which a merge exchanges, consumes, counts.
pub fn isChannel(role: TerminalRole) bool {
    return switch (role) {
        .source, .drain => true,
        .gate, .bulk, .base, .emitter, .collector, .pin => false,
    };
}

/// A passive a relaxed series merge takes: two pins each.
pub fn seriesPassive(kind: DeviceKind) bool {
    return switch (kind) {
        .resistor, .capacitor, .inductor => true,
        .mos, .bjt, .diode, .cell => false,
    };
}

/// Appends `params` as `(name, bits)` ascending to `out`: what must agree
/// for a merge summing `summed`. A summed name keeps its name with its
/// value blanked; `ignored` is left out, so it need not agree.
pub fn signatureInto(gpa: Allocator, params: []const Param, summed: []const ?StrId, ignored: ?StrId, out: *std.ArrayList(Sig)) Allocator.Error!void {
    const from = out.items.len;
    for (params) |p| {
        if (is(ignored, p.name)) continue;
        var blank = false;
        for (summed) |s| blank = blank or is(s, p.name);
        try out.append(gpa, .{ .name = @backingInt(p.name), .bits = if (blank) 0 else @bitCast(p.value) });
    }
    std.mem.sortUnstable(Sig, out.items[from..], {}, sigLess);
}

/// Lexicographic order of two signatures, a prefix first (Rust's slice `Ord`).
pub fn sigOrder(a: []const Sig, b: []const Sig) std.math.Order {
    for (a[0..@min(a.len, b.len)], b[0..@min(a.len, b.len)]) |x, y| {
        if (x.name != y.name) return std.math.order(x.name, y.name);
        if (x.bits != y.bits) return std.math.order(x.bits, y.bits);
    }
    return std.math.order(a.len, b.len);
}

// ---- private ----

fn sigLess(_: void, a: Sig, b: Sig) bool {
    if (a.name != b.name) return a.name < b.name;
    return a.bits < b.bits;
}
