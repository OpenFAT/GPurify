//! Axis-aligned bounding boxes and the inclusive proximity predicates that
//! prune every pairwise scan. In: coordinates or boxes. Out: boxes, areas, and
//! overlap / containment / within-distance answers, all exact integers.
//!
//! Contents:
//! - `pub const Bbox = struct`, `Bbox.empty`,
//!   `Bbox.point(x: Dbu, y: Dbu) Bbox`,
//!   `Bbox.ofPoints(xs: []const Dbu, ys: []const Dbu) Bbox`,
//!   `Bbox.include(b: Bbox, x: Dbu, y: Dbu) Bbox`,
//!   `Bbox.merge(a: Bbox, b: Bbox) Bbox`,
//!   `Bbox.intersection(a: Bbox, b: Bbox) ?Bbox`,
//!   `Bbox.isEmpty(b: Bbox) bool`, `Bbox.overlaps(a: Bbox, b: Bbox) bool`,
//!   `Bbox.contains(a: Bbox, b: Bbox) bool`,
//!   `Bbox.within(a: Bbox, b: Bbox, distance: Dbu) bool`,
//!   `Bbox.width(b: Bbox) Dbu`, `Bbox.height(b: Bbox) Dbu`,
//!   `Bbox.area(b: Bbox) DbuArea`

const std = @import("std");
const assert = std.debug.assert;
const dbu = @import("dbu.zig");
const Dbu = dbu.Dbu;
const DbuArea = dbu.DbuArea;

/// Inclusive on both bounds: a zero-area box is a point or a segment, both
/// legal derived shapes. `lo > hi` on either axis only in an empty box.
pub const Bbox = struct {
    xlo: Dbu,
    ylo: Dbu,
    xhi: Dbu,
    yhi: Dbu,

    /// Inverted sentinel at exactly ±`max_abs_dbu`, so domain-edge points
    /// still fold; the identity of `merge`.
    pub const empty: Bbox = .{
        .xlo = dbu.max_abs_dbu,
        .ylo = dbu.max_abs_dbu,
        .xhi = -dbu.max_abs_dbu,
        .yhi = -dbu.max_abs_dbu,
    };

    pub fn point(x: Dbu, y: Dbu) Bbox {
        return .{ .xlo = x, .ylo = y, .xhi = x, .yhi = y };
    }

    /// Bounding box of a run of points; `empty` for none. Asserts equal
    /// lengths: a short run would under-size the box and prune real neighbours.
    pub fn ofPoints(xs: []const Dbu, ys: []const Dbu) Bbox {
        assert(xs.len == ys.len);
        var folded = empty;
        for (xs, ys) |x, y| folded = folded.include(x, y);
        return folded;
    }

    /// The smallest box holding `b` and `(x, y)`.
    pub fn include(b: Bbox, x: Dbu, y: Dbu) Bbox {
        return b.merge(point(x, y));
    }

    /// The smallest box holding both (a union; `union` is a Zig keyword).
    pub fn merge(a: Bbox, b: Bbox) Bbox {
        return .{
            .xlo = @min(a.xlo, b.xlo),
            .ylo = @min(a.ylo, b.ylo),
            .xhi = @max(a.xhi, b.xhi),
            .yhi = @max(a.yhi, b.yhi),
        };
    }

    /// The shared region; null exactly when `overlaps` is false.
    pub fn intersection(a: Bbox, b: Bbox) ?Bbox {
        const meet: Bbox = .{
            .xlo = @max(a.xlo, b.xlo),
            .ylo = @max(a.ylo, b.ylo),
            .xhi = @min(a.xhi, b.xhi),
            .yhi = @min(a.yhi, b.yhi),
        };
        return if (meet.isEmpty()) null else meet;
    }

    /// `lo > hi` on either axis. A zero-area box is not empty.
    pub fn isEmpty(b: Bbox) bool {
        return b.xlo > b.xhi or b.ylo > b.yhi;
    }

    /// Share at least one point; touching counts (the fail-closed direction).
    pub fn overlaps(a: Bbox, b: Bbox) bool {
        return a.within(b, 0);
    }

    /// `b` lies entirely inside `a`, boundary inclusive.
    pub fn contains(a: Bbox, b: Bbox) bool {
        return a.xlo <= b.xlo and b.xhi <= a.xhi and a.ylo <= b.ylo and b.yhi <= a.yhi;
    }

    /// Within `distance` on both axes, inclusive. Asserts `distance >= 0`.
    pub fn within(a: Bbox, b: Bbox, distance: Dbu) bool {
        assert(distance >= 0);
        return a.xlo <= b.xhi + distance and b.xlo <= a.xhi + distance and
            a.ylo <= b.yhi + distance and b.ylo <= a.yhi + distance;
    }

    /// `xhi - xlo`. Asserts the result is in domain, which fails on `empty`
    /// and on a box spanning the whole domain (`2^41` wide).
    pub fn width(b: Bbox) Dbu {
        assert(dbu.inDomain(b.xhi - b.xlo));
        return b.xhi - b.xlo;
    }

    /// `yhi - ylo`, asserted as `width`.
    pub fn height(b: Bbox) Dbu {
        assert(dbu.inDomain(b.yhi - b.ylo));
        return b.yhi - b.ylo;
    }

    /// Square database units; zero for an empty, point or segment box. Never
    /// asserts: `empty` inverts both spans, and unclamped they would multiply
    /// back to the whole domain's `+2^82`.
    pub fn area(b: Bbox) DbuArea {
        return dbu.mulWide(@max(b.xhi - b.xlo, 0), @max(b.yhi - b.ylo, 0));
    }
};
