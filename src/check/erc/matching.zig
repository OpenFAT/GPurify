//! Matched devices (`matching`, ERC-H2 partial): the MOS units whose marker
//! centre lies in a group polygon must be identical (GF180MCU MP.1, MP.2a;
//! US10216888B2), run parallel (MP.7) and share a centroid (Karmokar et al.
//! ASP-DAC 2022; Hastings's area-weighted centroid). Units with the same
//! model and gate, channel-end (either order) and bulk nets are one device.
//! In: the store, devices, the group layer. Out: violations and one run per
//! row. Ported from crates/check/src/erc/rules/matching.rs.
//!
//! Contents:
//! - `pub fn checkMatching(r: Record, design: Design, t: *const MatchingTable) Allocator.Error!void`

const std = @import("std");
const Allocator = std.mem.Allocator;
const geom = @import("geom");
const Dbu = geom.Dbu;
const PolyId = geom.PolyId;
const StrId = geom.StrId;
const report = @import("../report.zig");
const Measurement = report.Measurement;
const NetId = @import("../topology/net.zig").NetId;
const pointInRegion = @import("../topology/taps.zig").pointInRegion;
const head = @import("head.zig");
const Record = head.Record;
const Design = head.Design;
const MatchingTable = @import("latchup_tables.zig").MatchingTable;

/// One unit's identity and geometry.
const Unit = struct {
    marker: PolyId,
    model: StrId,
    /// Gate, the two channel ends ascending, bulk.
    nets: [4]NetId,
    width: ?Dbu,
    length: ?Dbu,
};

const Key = struct { model: StrId, nets: [4]NetId };

const Sum = struct { x: f64, y: f64, area: f64, marker: PolyId };

/// Every row over every group polygon. `examined` counts the units in
/// groups. A parameter finding measures the width or length difference
/// against 0, a differing model or crossing channel the count 1 against 0,
/// at the unit's marker; a centroid finding measures the larger axis offset
/// from the first device's centroid, rounded up, against `tolerance`.
pub fn checkMatching(r: Record, design: Design, t: *const MatchingTable) Allocator.Error!void {
    const store = design.store;
    const devices = design.devices;
    var units: std.ArrayList(Unit) = .empty;
    defer units.deinit(r.gpa);
    var keys: std.ArrayList(Key) = .empty;
    defer keys.deinit(r.gpa);
    var sums: std.ArrayList(Sum) = .empty;
    defer sums.deinit(r.gpa);
    for (t.head.rule.items, t.head.severity.items, t.group.items, t.tolerance.items) |rule, severity, group_layer, tolerance| {
        const before = r.out.len();
        var examined: u64 = 0;
        const groups = store.polysOnLayer(group_layer);
        for (groups.start..groups.end) |g| {
            const ring = store.polyVerts(@fromBackingInt(@as(u32, @intCast(g))));
            if (geom.ops.windingOf(ring.xs, ring.ys) == .cw) continue;
            units.clearRetainingCapacity();
            // ponytail: every device per group polygon, groups x devices;
            // index the markers by box if designs carry many groups.
            for (0..devices.len()) |d| {
                if (devices.kind.items[d] != .mos) continue;
                const marker = devices.marker.items[d];
                if (!pointInRegion(ring.xs, ring.ys, geom.ops.centre(store.polyBbox(marker)))) continue;
                const id: @import("../topology/device.zig").DeviceId = @fromBackingInt(@as(u32, @intCast(d)));
                const term = devices.terminalsOf(id);
                var nets = [4]NetId{ .none, .none, .none, .none };
                var ends: [2]NetId = .{ .none, .none };
                var n_ends: usize = 0;
                for (term.nets, term.roles) |n, role| switch (role) {
                    .gate => nets[0] = n,
                    .source, .drain => {
                        if (n_ends < 2) ends[n_ends] = n;
                        n_ends += 1;
                    },
                    .bulk => nets[3] = n,
                    .base, .emitter, .collector, .pin => {},
                };
                if (n_ends == 2 and @backingInt(ends[1]) < @backingInt(ends[0])) std.mem.swap(NetId, &ends[0], &ends[1]);
                nets[1] = ends[0];
                nets[2] = ends[1];
                const params = devices.paramsOf(id);
                try units.append(r.gpa, .{ .marker = marker, .model = devices.model.items[d], .nets = nets, .width = lengthParam(params, .width), .length = lengthParam(params, .length) });
            }
            examined += units.items.len;
            if (units.items.len == 0) continue;
            const first = units.items[0];
            // Identical units.
            for (units.items[1..]) |u| {
                if (u.model != first.model) try push(r, design, rule, severity, u.marker, .count(1), .count(0));
                for ([2][2]?Dbu{ .{ first.width, u.width }, .{ first.length, u.length } }) |p| {
                    const a = p[0] orelse continue;
                    const b = p[1] orelse continue;
                    if (a != b) try push(r, design, rule, severity, u.marker, .length(@intCast(@abs(a - b))), .length(0));
                }
            }
            // Parallel channels, against the first unit whose axis reads.
            var reference: ?bool = null;
            for (units.items) |u| if (alongX(design, u)) |x| {
                reference = x;
                break;
            };
            if (reference) |ref| for (units.items) |u| if (alongX(design, u)) |x| if (x != ref) {
                try push(r, design, rule, severity, u.marker, .count(1), .count(0));
            };
            // Common centroid: devices in order of their first unit.
            keys.clearRetainingCapacity();
            sums.clearRetainingCapacity();
            for (units.items) |u| {
                const b = store.polyBbox(u.marker);
                const area: f64 = @floatFromInt(b.area());
                const cx = @as(f64, @floatFromInt(b.xlo + b.xhi)) / 2.0;
                const cy = @as(f64, @floatFromInt(b.ylo + b.yhi)) / 2.0;
                const key: Key = .{ .model = u.model, .nets = u.nets };
                const at = for (keys.items, 0..) |k, i| {
                    if (std.meta.eql(k, key)) break i;
                } else blk: {
                    try keys.append(r.gpa, key);
                    try sums.append(r.gpa, .{ .x = 0, .y = 0, .area = 0, .marker = u.marker });
                    break :blk keys.items.len - 1;
                };
                sums.items[at].x += area * cx;
                sums.items[at].y += area * cy;
                sums.items[at].area += area;
            }
            const ref = sums.items[0];
            const rx = ref.x / ref.area;
            const ry = ref.y / ref.area;
            for (sums.items[1..]) |s| {
                const off = @max(@abs(s.x / s.area - rx), @abs(s.y / s.area - ry));
                const measured: Measurement = .length(@intFromFloat(@ceil(off)));
                const limit: Measurement = .length(tolerance);
                if (off > @as(f64, @floatFromInt(tolerance)) and measured.violates(limit, .maximum)) try push(r, design, rule, severity, s.marker, measured, limit);
            }
        }
        try r.run(rule, before, .ran, examined);
    }
}

// ---- private ----

fn lengthParam(params: @import("../topology/device.zig").Params, want: @import("../topology/device.zig").DeviceParam) ?Dbu {
    for (params.names, params.measures) |name, m| if (name == want) switch (m) {
        .length => |l| return l,
        .area, .count, .area_share, .length_share => {},
    };
    return null;
}

/// True when a unit's channel runs along x (its marker box's x extent is
/// its length), false along y, null when the box does not say.
fn alongX(design: Design, u: Unit) ?bool {
    const length = u.length orelse return null;
    const b = design.store.polyBbox(u.marker);
    const w = b.width() == length;
    const h = b.height() == length;
    return if (w and !h) true else if (h and !w) false else null;
}

fn push(r: Record, design: Design, rule: StrId, severity: report.Severity, marker: PolyId, measured: Measurement, limit: Measurement) Allocator.Error!void {
    try r.out.push(r.gpa, .{ .rule = rule, .layer = design.store.polyLayer(marker), .severity = severity, .at = design.store.firstVertex(marker), .measured = measured, .limit = limit, .shape_a = marker, .shape_b = report.no_shape });
}
