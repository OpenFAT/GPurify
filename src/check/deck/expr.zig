//! Layer expressions for a deck built in code: a layer, or operations on
//! layers, as a derived layer or a rule argument writes them. In: names and
//! operations, at comptime (`layer("m").@"and"(layer("n")).group()`). Out:
//! an `Expr` tree, and its derived rows named as the parser names them
//! (`lowerNamed`): the inner operations `name#k` in post-order, then the
//! layer itself. Ported from crates/check/src/deck/builder.rs (`LayerExpr`,
//! `Node`, `Bound`, `range`, `lower_named`, `lower_operands`).
//!
//! `a.@"and"(b).@"and"(c)` is one fold of three operands, as `a and b and c`
//! is; `group` closes a fold, as parentheses do. What an operation refuses
//! (an empty range, `sized` growing one axis and shrinking the other) rides
//! on the expression as its `fault`, which the builder reports.
//!
//! ponytail: every expression is built at comptime, so its operand slices
//! are static and no allocator is passed; an expression from run-time data
//! needs an arena-built `Node` instead.
//!
//! Contents:
//! - `pub const Expr = struct`, `pub const Node = union(enum)`, `pub const Bound = union(enum)`
//! - `pub inline fn layer(comptime name: []const u8) Expr`
//! - `Expr.@"and"`, `@"or"`, `not`, `group`, `sized`, `sizedXy`, `overlapping`, `covering`,
//!   `notCovering`, `extended`, `interacting`, `notInteracting`, `inside`, `outside`, `insidePart`,
//!   `outsidePart`, `holes`, `extents`, `edges`, `rectangles`, `nonRectangles`, `squares`,
//!   `nonSquares`, `horizontal`, `vertical`, `withBboxMax`, `withBboxMin`, `withRect`, `withoutRect`,
//!   `withText`, `withoutText`, `textsOutside`, `inCells`, `notInCells`, `withArea`, `withWidth`,
//!   `withLength` (each `(comptime e: Expr, comptime ..) Expr`)
//! - `pub fn lowerNamed(arena: Allocator, out: *Rows, name: []const u8, node: Node) Allocator.Error!void`
//! - `pub const Rows = struct`

const std = @import("std");
const Allocator = std.mem.Allocator;
const geom = @import("geom");
const Dbu = geom.Dbu;
const ingest_deck = @import("ingest").deck;
const DerivedOp = ingest_deck.DerivedOp;
const DerivedSource = ingest_deck.DerivedSource;

/// A layer expression and the first thing its construction refused.
pub const Expr = struct {
    node: Node,
    /// Worded as the parser words it for deck text.
    fault: ?[]const u8 = null,

    /// `e and other`.
    pub inline fn @"and"(comptime e: Expr, comptime other: Expr) Expr {
        return comptime e.fold(.@"and", other);
    }

    /// `e or other`.
    pub inline fn @"or"(comptime e: Expr, comptime other: Expr) Expr {
        return comptime e.fold(.@"or", other);
    }

    /// `e not other`.
    pub inline fn not(comptime e: Expr, comptime other: Expr) Expr {
        return comptime e.fold(.not, other);
    }

    /// `(e)`: a further `and`, `or` or `not` takes it as one operand.
    pub inline fn group(comptime e: Expr) Expr {
        comptime var g = e;
        switch (g.node) {
            .layer => {},
            .op => |*o| o.chain = false,
        }
        return g;
    }

    pub inline fn sized(comptime e: Expr, comptime by: Dbu) Expr {
        return comptime e.call(.{ .sized = .{ .dx = by, .dy = by } }, null, &.{});
    }

    /// `.sized(dx, dy)`; one axis growing and the other shrinking is refused.
    pub inline fn sizedXy(comptime e: Expr, comptime dx: Dbu, comptime dy: Dbu) Expr {
        const fault: ?[]const u8 = if (std.math.sign(dx) * std.math.sign(dy) < 0) "`sized(dx, dy)` grows or shrinks both axes; chain two `sized` for one of each" else null;
        return comptime e.call(.{ .sized = .{ .dx = dx, .dy = dy } }, null, &.{}).withFault(fault);
    }

    pub inline fn overlapping(comptime e: Expr, comptime other: Expr) Expr {
        return comptime e.call(.overlapping, other, &.{});
    }

    pub inline fn covering(comptime e: Expr, comptime other: Expr) Expr {
        return comptime e.call(.{ .covering = true }, other, &.{});
    }

    pub inline fn notCovering(comptime e: Expr, comptime other: Expr) Expr {
        return comptime e.call(.{ .covering = false }, other, &.{});
    }

    /// `.extended(begin:, end:, out:, in:)` on edges; a negative length, or
    /// `out` and `inside` both 0, is refused.
    pub inline fn extended(comptime e: Expr, comptime begin: Dbu, comptime end: Dbu, comptime out: Dbu, comptime inside_: Dbu) Expr {
        const fault: ?[]const u8 = if (begin < 0 or end < 0 or out < 0 or inside_ < 0)
            "`extended` takes lengths of 0 or more"
        else if (out == 0 and inside_ == 0)
            "`extended` needs `out` or `in` above 0: a box needs a width"
        else
            null;
        return comptime e.call(.{ .extended = .{ .begin = begin, .end = end, .outside = out, .inside = inside_ } }, null, &.{}).withFault(fault);
    }

    pub inline fn interacting(comptime e: Expr, comptime other: Expr) Expr {
        return comptime e.call(.{ .interacting = true }, other, &.{});
    }

    pub inline fn notInteracting(comptime e: Expr, comptime other: Expr) Expr {
        return comptime e.call(.{ .interacting = false }, other, &.{});
    }

    pub inline fn inside(comptime e: Expr, comptime other: Expr) Expr {
        return comptime e.call(.inside, other, &.{});
    }

    pub inline fn outside(comptime e: Expr, comptime other: Expr) Expr {
        return comptime e.call(.outside, other, &.{});
    }

    pub inline fn insidePart(comptime e: Expr, comptime other: Expr) Expr {
        return comptime e.call(.{ .part = true }, other, &.{});
    }

    pub inline fn outsidePart(comptime e: Expr, comptime other: Expr) Expr {
        return comptime e.call(.{ .part = false }, other, &.{});
    }

    pub inline fn holes(comptime e: Expr) Expr {
        return comptime e.call(.holes, null, &.{});
    }

    pub inline fn extents(comptime e: Expr) Expr {
        return comptime e.call(.extents, null, &.{});
    }

    pub inline fn edges(comptime e: Expr) Expr {
        return comptime e.call(.edges, null, &.{});
    }

    pub inline fn rectangles(comptime e: Expr) Expr {
        return comptime e.call(.{ .rectangles = .{ .square = false, .keep = true } }, null, &.{});
    }

    pub inline fn nonRectangles(comptime e: Expr) Expr {
        return comptime e.call(.{ .rectangles = .{ .square = false, .keep = false } }, null, &.{});
    }

    pub inline fn squares(comptime e: Expr) Expr {
        return comptime e.call(.{ .rectangles = .{ .square = true, .keep = true } }, null, &.{});
    }

    pub inline fn nonSquares(comptime e: Expr) Expr {
        return comptime e.call(.{ .rectangles = .{ .square = true, .keep = false } }, null, &.{});
    }

    pub inline fn horizontal(comptime e: Expr) Expr {
        return comptime e.call(.{ .oriented = false }, null, &.{});
    }

    pub inline fn vertical(comptime e: Expr) Expr {
        return comptime e.call(.{ .oriented = true }, null, &.{});
    }

    /// A bound on the bounding box's longer side.
    pub inline fn withBboxMax(comptime e: Expr, comptime bounds: []const Bound) Expr {
        const r = comptime range("with_bbox_max", bounds, identity);
        return comptime e.call(.{ .with_bbox = .{ .longer = true, .lo = r.lo, .hi = r.hi } }, null, &.{}).withFault(r.fault);
    }

    /// A bound on the bounding box's shorter side.
    pub inline fn withBboxMin(comptime e: Expr, comptime bounds: []const Bound) Expr {
        const r = comptime range("with_bbox_min", bounds, identity);
        return comptime e.call(.{ .with_bbox = .{ .longer = false, .lo = r.lo, .hi = r.hi } }, null, &.{}).withFault(r.fault);
    }

    pub inline fn withRect(comptime e: Expr, comptime w: Dbu, comptime h: Dbu) Expr {
        return comptime e.call(.{ .with_rect = .{ .keep = true, .w = w, .h = h } }, null, &.{});
    }

    pub inline fn withoutRect(comptime e: Expr, comptime w: Dbu, comptime h: Dbu) Expr {
        return comptime e.call(.{ .with_rect = .{ .keep = false, .w = w, .h = h } }, null, &.{});
    }

    /// The shapes holding a text drawn on `texts` that matches `pattern`.
    pub inline fn withText(comptime e: Expr, comptime texts: Expr, comptime pattern: []const u8) Expr {
        return comptime e.call(.{ .with_text = .{ .keep = true, .text = 0 } }, texts, &.{pattern});
    }

    pub inline fn withoutText(comptime e: Expr, comptime texts: Expr, comptime pattern: []const u8) Expr {
        return comptime e.call(.{ .with_text = .{ .keep = false, .text = 0 } }, texts, &.{pattern});
    }

    pub inline fn textsOutside(comptime e: Expr, comptime shapes: Expr) Expr {
        return comptime e.call(.texts_outside, shapes, &.{});
    }

    pub inline fn inCells(comptime e: Expr, comptime patterns: []const []const u8) Expr {
        return comptime e.call(.{ .in_cells = .{ .keep = true, .first = 0, .count = 0 } }, null, patterns);
    }

    pub inline fn notInCells(comptime e: Expr, comptime patterns: []const []const u8) Expr {
        return comptime e.call(.{ .in_cells = .{ .keep = false, .first = 0, .count = 0 } }, null, patterns);
    }

    pub inline fn withArea(comptime e: Expr, comptime bounds: []const Bound) Expr {
        const r = comptime range("with_area", bounds, identity);
        return comptime e.call(.{ .with_area = .{ .lo = r.lo, .hi = r.hi } }, null, &.{}).withFault(r.fault);
    }

    /// A bound on the narrowest width, stored as twice its signed square
    /// as the parser stores it.
    pub inline fn withWidth(comptime e: Expr, comptime bounds: []const Bound) Expr {
        const r = comptime range("with_width", bounds, twiceSquare);
        return comptime e.call(.{ .with_width = .{ .lo = r.lo, .hi = r.hi } }, null, &.{}).withFault(r.fault);
    }

    /// On edges.
    pub inline fn withLength(comptime e: Expr, comptime bounds: []const Bound) Expr {
        const r = comptime range("with_length", bounds, identity);
        return comptime e.call(.{ .with_length = .{ .lo = r.lo, .hi = r.hi } }, null, &.{}).withFault(r.fault);
    }

    // ---- private ----

    /// Extends `e` when it is an open fold of `op`.
    fn fold(e: Expr, op: DerivedOp, other: Expr) Expr {
        const node: Node = switch (e.node) {
            .op => |o| if (o.chain and std.meta.activeTag(o.op) == std.meta.activeTag(op))
                .{ .op = .{ .op = op, .operands = o.operands ++ [_]Node{other.node}, .chain = true } }
            else
                .{ .op = .{ .op = op, .operands = &.{ e.node, other.node }, .chain = true } },
            .layer => .{ .op = .{ .op = op, .operands = &.{ e.node, other.node }, .chain = true } },
        };
        return .{ .node = node, .fault = e.fault orelse other.fault };
    }

    /// An operation on `e`, with an optional layer argument.
    fn call(e: Expr, op: DerivedOp, argument: ?Expr, patterns: []const []const u8) Expr {
        if (argument) |a| return .{
            .node = .{ .op = .{ .op = op, .operands = &.{ e.node, a.node }, .chain = false, .patterns = patterns } },
            .fault = e.fault orelse a.fault,
        };
        return .{ .node = .{ .op = .{ .op = op, .operands = &.{e.node}, .chain = false, .patterns = patterns } }, .fault = e.fault };
    }

    fn withFault(e: Expr, fault: ?[]const u8) Expr {
        return .{ .node = e.node, .fault = e.fault orelse fault };
    }
};

/// An expression's tree.
pub const Node = union(enum) {
    layer: []const u8,
    op: struct {
        op: DerivedOp,
        operands: []const Node,
        /// An unparenthesised fold, which a further operation of its kind extends.
        chain: bool,
        /// `with_text`'s pattern, or `in_cells`' patterns.
        patterns: []const []const u8 = &.{},
    },
};

/// One side of a range: the deck's `>=`, `>`, `<=`, `<` and `==`, on a
/// length or an area.
pub const Bound = union(enum) {
    at_least: i128,
    above: i128,
    at_most: i128,
    below: i128,
    exactly: i128,
};

/// Derived rows and, per row, its text or cell patterns.
pub const Rows = struct {
    derived: *std.ArrayList(DerivedSource),
    patterns: *std.ArrayList([]const []const u8),
};

const Range = struct { lo: i128, hi: i128, fault: ?[]const u8 };

/// The plain layer `name`.
pub inline fn layer(comptime name: []const u8) Expr {
    return .{ .node = .{ .layer = name } };
}

/// Appends the derived rows of `layer name = node`: its inner operations as
/// `name#k` in post-order, then `name` itself. `node` is an operation.
pub fn lowerNamed(arena: Allocator, out: Rows, name: []const u8, node: Node) Allocator.Error!void {
    const o = node.op;
    var count: u32 = 0;
    const operands = try lowerOperands(arena, out, name, o.operands, &count);
    try out.derived.append(arena, .{ .name = name, .op = o.op, .layers = operands });
    try out.patterns.append(arena, o.patterns);
}

// ---- private ----

fn lowerOperands(arena: Allocator, out: Rows, name: []const u8, operands: []const Node, count: *u32) Allocator.Error![]const []const u8 {
    const names = try arena.alloc([]const u8, operands.len);
    for (operands, names) |operand, *n| n.* = switch (operand) {
        .layer => |l| l,
        .op => |o| blk: {
            const inner = try lowerOperands(arena, out, name, o.operands, count);
            count.* += 1;
            const hidden = try std.fmt.allocPrint(arena, "{s}#{d}", .{ name, count.* });
            try out.derived.append(arena, .{ .name = hidden, .op = o.op, .layers = inner });
            try out.patterns.append(arena, o.patterns);
            break :blk hidden;
        },
    };
    return names;
}

fn identity(v: i128) i128 {
    return v;
}

fn twiceSquare(v: i128) i128 {
    return 2 * v * @as(i128, @intCast(@abs(v)));
}

/// Inclusive bounds as the parser stores them, the `i128` extremes for an
/// open side, and the fault in them if any.
fn range(comptime op: []const u8, bounds: []const Bound, value: fn (i128) i128) Range {
    var lo: ?i128 = null;
    var hi: ?i128 = null;
    for (bounds) |b| {
        const low: ?i128, const high: ?i128 = switch (b) {
            .at_least => |v| .{ value(v), null },
            .above => |v| .{ value(v) + 1, null },
            .at_most => |v| .{ null, value(v) },
            .below => |v| .{ null, value(v) - 1 },
            .exactly => |v| .{ value(v), value(v) },
        };
        if ((low != null and lo != null) or (high != null and hi != null)) return .{ .lo = std.math.minInt(i128), .hi = std.math.maxInt(i128), .fault = "`." ++ op ++ "` takes one bound on each side" };
        lo = lo orelse low;
        hi = hi orelse high;
    }
    const r: Range = .{ .lo = lo orelse std.math.minInt(i128), .hi = hi orelse std.math.maxInt(i128), .fault = null };
    if (bounds.len == 0) return .{ .lo = r.lo, .hi = r.hi, .fault = "`." ++ op ++ "` needs a bound such as `>= 1um`" };
    if (r.lo > r.hi) return .{ .lo = r.lo, .hi = r.hi, .fault = "the range is empty" };
    return r;
}

test "a fold extends until a group closes it" {
    // Oracle: crates/check/src/deck/builder.rs `LayerExpr` rustdoc: `a and b
    // and c` is one fold of three operands; `(a and b) and c` two rows.
    const chain = comptime layer("a").@"and"(layer("b")).@"and"(layer("c"));
    try std.testing.expectEqual(@as(usize, 3), chain.node.op.operands.len);
    const grouped = comptime layer("a").@"and"(layer("b")).group().@"and"(layer("c"));
    try std.testing.expectEqual(@as(usize, 2), grouped.node.op.operands.len);
    try std.testing.expect(grouped.node.op.operands[0] == .op);
}

test "a range nothing satisfies is the expression's fault" {
    // Oracle: the parser's words for `m.with_area(>= 2nm2, <= 1nm2)`.
    const e = comptime layer("m").withArea(&.{ .{ .at_least = 2 }, .{ .at_most = 1 } });
    try std.testing.expectEqualStrings("the range is empty", e.fault.?);
}
