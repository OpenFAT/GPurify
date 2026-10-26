//! Layouts holding exactly one deliberate violation, at a known coordinate,
//! with a known measurement. In: the shape to build, its centre, the
//! measured amount and the limit. Out: a `ViolationCase` (store, ids, the
//! expected `Violation`, the shape count). `at` is the midpoint of the thing
//! measured (a gap's middle, an area's centre, an edge's midpoint); each
//! `ShapeKind` says which. Ported from crates/testgen/src/violation.rs.
//!
//! Contents:
//! - `pub const Amount = union(enum)`, `Amount.measurement(a: Amount) Measurement`
//! - `pub const ViolationShape = struct`, `pub const ShapeKind = union(enum)`
//! - `pub const ViolationCase = struct`, `ViolationCase.deinit(c: *ViolationCase, gpa: Allocator) void`
//! - `pub fn layoutWithViolation(gpa: Allocator, shape: ViolationShape, at: [2]i64, measured: Amount, limit: Amount) Allocator.Error!ViolationCase`

const std = @import("std");
const Allocator = std.mem.Allocator;
const assert = std.debug.assert;
const geom = @import("geom");
const LayerId = geom.LayerId;
const StrId = geom.StrId;
const GeometryStore = geom.GeometryStore;
const report = @import("check").report;
const Measurement = report.Measurement;
const Severity = report.Severity;
const Violation = report.Violation;
const shapes = @import("shapes.zig");
const Handle = shapes.Handle;
const Ids = shapes.Ids;
const LayoutBuilder = shapes.LayoutBuilder;

/// A measured quantity in this module's plain integers. As `measured` it
/// shapes the geometry (each `ShapeKind` takes one dimension; another
/// panics); as `limit` it is copied into the expected row unread.
pub const Amount = union(enum) {
    length: i64,
    area: i128,
    /// An antenna ratio, a density fraction, an angle in degrees.
    ratio: f64,
    count: u32,
    millivolts: f64,
    microamps: f64,
    ohms: f64,

    /// The report's measurement of the same quantity.
    pub fn measurement(a: Amount) Measurement {
        return switch (a) {
            .length => |v| .length(shapes.dbu(v)),
            .area => |v| .area(v),
            .ratio => |v| .ratio(v),
            .count => |v| .count(v),
            .millivolts => |v| .voltage(.{ .raw = v }),
            .microamps => |v| .current(.{ .raw = v }),
            .ohms => |v| .resistance(.{ .raw = v }),
        };
    }

    // ---- private ----

    fn length_(a: Amount, what: []const u8) i64 {
        return switch (a) {
            .length => |v| v,
            .area, .ratio, .count, .millivolts, .microamps, .ohms => std.debug.panic("{s} needs a length, got {any}", .{ what, a }),
        };
    }

    fn area_(a: Amount, what: []const u8) i128 {
        return switch (a) {
            .area => |v| v,
            .length, .ratio, .count, .millivolts, .microamps, .ohms => std.debug.panic("{s} needs an area, got {any}", .{ what, a }),
        };
    }

    fn ratio_(a: Amount, what: []const u8) f64 {
        return switch (a) {
            .ratio => |v| v,
            .length, .area, .count, .millivolts, .microamps, .ohms => std.debug.panic("{s} needs a ratio, got {any}", .{ what, a }),
        };
    }

    fn count_(a: Amount, what: []const u8) u32 {
        return switch (a) {
            .count => |v| v,
            .length, .area, .ratio, .millivolts, .microamps, .ohms => std.debug.panic("{s} needs a count, got {any}", .{ what, a }),
        };
    }
};

/// What to build, and which rule must find it.
pub const ViolationShape = struct {
    rule: StrId,
    severity: Severity,
    kind: ShapeKind,
};

/// The configuration to realise; reported on the first layer it names. A
/// length halved to centre geometry on `at` must be positive and even.
pub const ShapeKind = union(enum) {
    /// A rectangle `measured` wide and `run` tall, centred on `at`. Length.
    width: struct { layer: LayerId, run: i64 },
    /// A rectangle with a `measured`-long bottom edge whose midpoint is
    /// `at`, `body` tall. Length.
    edge_length: struct { layer: LayerId, body: i64 },
    /// Two rectangles across a gap of `measured` in x, each `extent` wide
    /// and `2 * extent` tall; `at` the gap's middle. Length; (left, right).
    spacing: struct { layer: LayerId, extent: i64 },
    /// A U whose notch is `measured` wide; `at` the notch void's centre
    /// (`arm + thickness` even). Length.
    notch: struct { layer: LayerId, arm: i64, thickness: i64 },
    /// A line `width` wide whose end faces a wide neighbour across
    /// `measured`; `at` the gap's middle. Length; (line, neighbour).
    end_of_line: struct { layer: LayerId, width: i64, extent: i64 },
    /// Two `size` squares whose nearest corners are `legs` apart, so
    /// `legs.0² + legs.1² = measured²`; `at` the corners' midpoint. Length.
    corner_to_corner: struct { layer: LayerId, size: i64, legs: [2]i64 },
    /// A rectangle of area `measured`, `width` wide, centred on `at`. Area.
    area: struct { layer: LayerId, width: i64 },
    /// A ring whose hole (`hole_width` wide, its own clockwise polygon) has
    /// area `measured`, `margin` of material around; `at` its centre. Area.
    enclosed_area: struct { layer: LayerId, margin: i64, hole_width: i64 },
    /// An `inner_size` square on `inner`, cleared by `measured` on the left
    /// by an `outer` rectangle and by `inner_size` elsewhere; `at` the
    /// deficient margin's middle. Length; (inner, outer).
    enclosure: struct { outer: LayerId, inner: LayerId, inner_size: i64 },
    /// A line crossing a bar (`width` wide, `4 * width` tall) and running
    /// `measured` past its right edge; `at` that stub's middle. Length;
    /// (line, bar).
    extension: struct { line: LayerId, crossed: LayerId, width: i64 },
    /// Two rectangles on two layers overlapping by `measured` in x; `at`
    /// the overlap's centre. Length; (left on `a`, right on `b`).
    overlap: struct { a: LayerId, b: LayerId, extent: i64 },
    /// `spacing` across two layers. Length; (left on `a`, right on `b`).
    separation: struct { a: LayerId, b: LayerId, size: i64 },
    /// A `size` square whose lower-left corner `at` is `measured` off a
    /// `grid` multiple in x. Length.
    off_grid: struct { layer: LayerId, size: i64, grid: i64 },
    /// A right triangle, counter-clockwise, whose hypotenuse rises `run[1]`
    /// over `run[0]` at `measured` degrees from `at`. Ratio.
    angle: struct { layer: LayerId, run: [2]i64 },
    /// A `window` centred on `at` holding `filled` `cell` squares packed
    /// from its lower-left corner one unit apart, covering `measured`. Ratio.
    density: struct { layer: LayerId, window: i64, cell: i64, filled: u32 },
    /// A `gate_side` square on `gate` under a metal square, both centred on
    /// `at`, with metal-to-gate area ratio `measured`. Ratio; (gate, metal).
    antenna: struct { gate: LayerId, metal: LayerId, gate_side: i64 },
    /// `measured` cut squares of side `size` along +x at `pitch`; `at` the
    /// first's centre. Count.
    via_array: struct { cut: LayerId, size: i64, pitch: i64 },
    /// Three `size` squares at an L's corners, `gap` apart: an odd conflict
    /// cycle. `measured` exactly 3. Count; (first, second).
    odd_cycle: struct { layer: LayerId, size: i64, gap: i64 },
};

/// A layout with one violation in it, and the violation.
pub const ViolationCase = struct {
    store: GeometryStore,
    ids: Ids,
    /// The row the rule must report, store ids filled in.
    expected: Violation,
    /// Every shape in the layout: the floor of an `examined` assertion.
    shapes: u32,

    pub fn deinit(c: *ViolationCase, gpa: Allocator) void {
        c.store.deinit(gpa);
        c.ids.deinit(gpa);
    }
};

/// Builds a layout whose only violation is the stated one. `measured`
/// shapes the geometry; `limit` only fills the expected row. Panics when the
/// request cannot be built exactly, naming why.
pub fn layoutWithViolation(gpa: Allocator, shape: ViolationShape, at: [2]i64, measured: Amount, limit: Amount) Allocator.Error!ViolationCase {
    const layers = layersOf(shape.kind);
    var lb = LayoutBuilder.init(@max(@backingInt(layers[0]), @backingInt(layers[1] orelse layers[0])) + 1);
    defer lb.deinit(gpa);
    const pair = try build(gpa, &lb, shape.kind, at, measured);
    var case: ViolationCase = .{ .store = .empty, .ids = .{}, .expected = undefined, .shapes = lb.pushed };
    errdefer case.deinit(gpa);
    try lb.finish(gpa, &case.store, &case.ids);
    case.expected = .{
        .rule = shape.rule,
        .layer = layers[0],
        .severity = shape.severity,
        .at = shapes.point(at[0], at[1]),
        .measured = measured.measurement(),
        .limit = limit.measurement(),
        .shape_a = case.ids.of(pair[0]),
        .shape_b = if (pair[1]) |h| case.ids.of(h) else report.no_shape,
    };
    return case;
}

// ---- private ----

/// The reported layer, and the second layer where the shape uses one.
fn layersOf(kind: ShapeKind) struct { LayerId, ?LayerId } {
    return switch (kind) {
        inline .width, .edge_length, .spacing, .notch, .end_of_line, .corner_to_corner, .area, .enclosed_area, .off_grid, .angle, .density, .odd_cycle => |k| .{ k.layer, null },
        .enclosure => |k| .{ k.inner, k.outer },
        .extension => |k| .{ k.line, k.crossed },
        .overlap => |k| .{ k.a, k.b },
        .separation => |k| .{ k.a, k.b },
        .antenna => |k| .{ k.gate, k.metal },
        .via_array => |k| .{ k.cut, null },
    };
}

/// Half of an even span: an odd one has no integer midpoint and is refused.
fn half(span: i64, what: []const u8) i64 {
    if (span <= 0 or @mod(span, 2) != 0) std.debug.panic("{s} is {d}; it must be positive and even so its midpoint is a coordinate", .{ what, span });
    return @divExact(span, 2);
}

fn cellArea(side: i64) f64 {
    const s: f64 = @floatFromInt(side);
    return s * s;
}

fn build(gpa: Allocator, lb: *LayoutBuilder, kind: ShapeKind, at: [2]i64, measured: Amount) Allocator.Error!struct { Handle, ?Handle } {
    const ax = at[0];
    const ay = at[1];
    switch (kind) {
        .width => |k| {
            const w = half(measured.length_("a width"), "the width");
            const h = half(k.run, "the run");
            return .{ try lb.rect(gpa, @backingInt(k.layer), ax - w, ay - h, ax + w, ay + h), null };
        },
        .edge_length => |k| {
            const e = half(measured.length_("an edge length"), "the edge length");
            assert(k.body > 0);
            return .{ try lb.rect(gpa, @backingInt(k.layer), ax - e, ay, ax + e, ay + k.body), null };
        },
        .spacing => |k| {
            const p = try shapes.spacedPair(lb, gpa, @backingInt(k.layer), at, measured.length_("a spacing"), k.extent);
            return .{ p[0], p[1] };
        },
        .notch => |k| {
            const gap = measured.length_("a notch");
            const g = half(gap, "the notch");
            // The void spans y0 + thickness to y0 + arm: centring it on `ay`
            // fixes y0.
            const y0 = ay - half(k.thickness + k.arm, "the notch void span");
            return .{ try lb.shape(gpa, @backingInt(k.layer), shapes.uShape(ax - g - k.thickness, y0, k.arm, k.thickness, gap)), null };
        },
        .end_of_line => |k| {
            const g = half(measured.length_("an end-of-line spacing"), "the spacing");
            const w = half(k.width, "the line width");
            assert(k.extent > 0);
            const line = try lb.rect(gpa, @backingInt(k.layer), ax - w, ay - g - k.extent, ax + w, ay - g);
            return .{ line, try lb.rect(gpa, @backingInt(k.layer), ax - k.extent, ay + g, ax + k.extent, ay + g + k.extent) };
        },
        .corner_to_corner => |k| {
            const d = measured.length_("a corner distance");
            assert(k.legs[0] * k.legs[0] + k.legs[1] * k.legs[1] == d * d);
            const dx = half(k.legs[0], "the x leg");
            const dy = half(k.legs[1], "the y leg");
            assert(k.size > 0);
            const a = try lb.rect(gpa, @backingInt(k.layer), ax - dx - k.size, ay - dy - k.size, ax - dx, ay - dy);
            return .{ a, try lb.rect(gpa, @backingInt(k.layer), ax + dx, ay + dy, ax + dx + k.size, ay + dy + k.size) };
        },
        .area => |k| {
            const target = measured.area_("an area");
            assert(k.width > 0 and @mod(target, k.width) == 0);
            const w = half(k.width, "the width");
            const h = half(@intCast(@divExact(target, k.width)), "the height");
            return .{ try lb.rect(gpa, @backingInt(k.layer), ax - w, ay - h, ax + w, ay + h), null };
        },
        .enclosed_area => |k| {
            const target = measured.area_("an enclosed area");
            assert(k.margin > 0 and k.hole_width > 0 and @mod(target, k.hole_width) == 0);
            const w = half(k.hole_width, "the hole width");
            const h = half(@intCast(@divExact(target, k.hole_width)), "the hole height");
            const outer = try lb.shape(gpa, @backingInt(k.layer), shapes.rect(ax - w - k.margin, ay - h - k.margin, ax + w + k.margin, ay + h + k.margin));
            _ = try lb.shape(gpa, @backingInt(k.layer), shapes.hole(ax - w, ay - h, ax + w, ay + h));
            return .{ outer, null };
        },
        .enclosure => |k| {
            const enc = measured.length_("an enclosure");
            const e = half(enc, "the enclosure");
            assert(k.inner_size > 0);
            // Only the left margin is deficient.
            const left = ax + e;
            const bottom = ay - @divTrunc(k.inner_size, 2);
            const top = bottom + k.inner_size;
            const inner = try lb.rect(gpa, @backingInt(k.inner), left, bottom, left + k.inner_size, top);
            return .{ inner, try lb.rect(gpa, @backingInt(k.outer), left - enc, bottom - k.inner_size, left + 2 * k.inner_size, top + k.inner_size) };
        },
        .extension => |k| {
            const e = half(measured.length_("an extension"), "the extension");
            const w = half(k.width, "the line width");
            const bar = try lb.rect(gpa, @backingInt(k.crossed), ax - e - k.width, ay - 2 * k.width, ax - e, ay + 2 * k.width);
            return .{ try lb.rect(gpa, @backingInt(k.line), ax - e - 3 * k.width, ay - w, ax + e, ay + w), bar };
        },
        .overlap => |k| {
            const o = half(measured.length_("an overlap"), "the overlap");
            const h = half(k.extent, "the extent");
            const left = try lb.rect(gpa, @backingInt(k.a), ax - k.extent, ay - h, ax + o, ay + h);
            return .{ left, try lb.rect(gpa, @backingInt(k.b), ax - o, ay - h, ax + k.extent, ay + h) };
        },
        .separation => |k| {
            const g = half(measured.length_("a separation"), "the separation");
            assert(k.size > 0);
            const left = try lb.rect(gpa, @backingInt(k.a), ax - g - k.size, ay - k.size, ax - g, ay + k.size);
            return .{ left, try lb.rect(gpa, @backingInt(k.b), ax + g, ay - k.size, ax + g + k.size, ay + k.size) };
        },
        .off_grid => |k| {
            assert(k.grid > 0 and k.size > 0 and @mod(ax, k.grid) == measured.length_("a grid offset"));
            return .{ try lb.rect(gpa, @backingInt(k.layer), ax, ay, ax + k.size, ay + k.size), null };
        },
        .angle => |k| {
            const degrees = measured.ratio_("an angle");
            assert(k.run[0] != 0 and k.run[1] != 0);
            const actual = std.math.radiansToDegrees(std.math.atan2(@as(f64, @floatFromInt(k.run[1])), @as(f64, @floatFromInt(k.run[0]))));
            assert(@abs(actual - degrees) < 1e-9);
            // The right angle sits on whichever leg keeps the triangle
            // counter-clockwise; the hypotenuse still leaves `at`.
            const corner: [2]i64 = if (std.math.sign(k.run[0]) == std.math.sign(k.run[1])) .{ ax, ay + k.run[1] } else .{ ax + k.run[0], ay };
            return .{ try lb.push(gpa, @backingInt(k.layer), &.{ ax, ax + k.run[0], corner[0] }, &.{ ay, ay + k.run[1], corner[1] }), null };
        },
        .density => |k| {
            const fraction = measured.ratio_("a density");
            assert(k.window > 0 and k.cell > 0 and k.filled > 0);
            const window_area = cellArea(k.window);
            assert(@abs(@as(f64, @floatFromInt(k.filled)) * cellArea(k.cell) / window_area - fraction) < 1e-12);
            // One clear unit between cells so they stay distinct polygons.
            const per_row = @divTrunc(k.window, k.cell + 1);
            assert(per_row > 0);
            const corner = half(k.window, "the window");
            var first: ?Handle = null;
            for (0..k.filled) |i| {
                const col = @mod(@as(i64, @intCast(i)), per_row);
                const row = @divTrunc(@as(i64, @intCast(i)), per_row);
                assert((row + 1) * (k.cell + 1) <= k.window);
                const x = ax - corner + col * (k.cell + 1);
                const y = ay - corner + row * (k.cell + 1);
                const h = try lb.rect(gpa, @backingInt(k.layer), x, y, x + k.cell, y + k.cell);
                if (first == null) first = h;
            }
            return .{ first.?, null };
        },
        .antenna => |k| {
            const ratio = measured.ratio_("an antenna ratio");
            assert(k.gate_side > 0);
            const gate_area = cellArea(k.gate_side);
            const metal_side: i64 = @intFromFloat(@round(@sqrt(gate_area * ratio)));
            assert(@abs(cellArea(metal_side) / gate_area - ratio) < 1e-12);
            const g = half(k.gate_side, "the gate side");
            const m = half(metal_side, "the derived metal side");
            const gate = try lb.rect(gpa, @backingInt(k.gate), ax - g, ay - g, ax + g, ay + g);
            return .{ gate, try lb.rect(gpa, @backingInt(k.metal), ax - m, ay - m, ax + m, ay + m) };
        },
        .via_array => |k| {
            const cuts = measured.count_("a via count");
            assert(cuts > 0 and k.size > 0 and k.pitch > k.size);
            const s = half(k.size, "the cut side");
            var first: ?Handle = null;
            for (0..cuts) |i| {
                const cx = ax + @as(i64, @intCast(i)) * k.pitch;
                const h = try lb.rect(gpa, @backingInt(k.cut), cx - s, ay - s, cx + s, ay + s);
                if (first == null) first = h;
            }
            return .{ first.?, null };
        },
        .odd_cycle => |k| {
            assert(measured.count_("an odd cycle") == 3);
            assert(k.size > 0 and k.gap > 0);
            const s = half(k.size, "the square side");
            const step = k.size + k.gap;
            const l = @backingInt(k.layer);
            const a = try lb.rect(gpa, l, ax - s, ay - s, ax + s, ay + s);
            const b = try lb.rect(gpa, l, ax - s + step, ay - s, ax + s + step, ay + s);
            _ = try lb.rect(gpa, l, ax - s, ay - s + step, ax + s, ay + s + step);
            return .{ a, b };
        },
    }
}

test "the angle triangle winds counter-clockwise in every quadrant" {
    // Oracle: closed form. A right triangle with legs 300 and 200 has twice
    // its area 60 000, positive for a counter-clockwise ring, in every
    // quadrant (F35).
    const gpa = std.testing.allocator;
    for ([_][2]i64{ .{ 300, 200 }, .{ -300, 200 }, .{ -300, -200 }, .{ 300, -200 } }) |run| {
        const degrees = std.math.radiansToDegrees(std.math.atan2(@as(f64, @floatFromInt(run[1])), @as(f64, @floatFromInt(run[0]))));
        var case = try layoutWithViolation(gpa, .{ .rule = @fromBackingInt(0), .severity = .@"error", .kind = .{ .angle = .{ .layer = @fromBackingInt(0), .run = run } } }, .{ 1000, 1000 }, .{ .ratio = degrees }, .{ .count = 1 });
        defer case.deinit(gpa);
        const r = case.store.polyVerts(@fromBackingInt(0));
        try std.testing.expectEqual(@as(i128, 60_000), geom.ops.area2(r.xs, r.ys));
    }
}

test "half halves an even span" {
    // Oracle: the documented contract of `half`: 40 halves to 20. (Rust also
    // caught the panic on 41 and 0; a Zig test cannot catch a panic.)
    try std.testing.expectEqual(@as(i64, 20), half(40, "a gap"));
}
