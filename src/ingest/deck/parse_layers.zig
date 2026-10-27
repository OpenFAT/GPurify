//! Layer expressions: `a and b`, `(a or b) not c`, `met1.sized(1um).holes()` →
//! `LExpr` trees, then rows of `DerivedSource` (nested operations become hidden
//! layers `name#k`, numbered in post-order). One operator folds into one row; a
//! parenthesised chain is its own row. Semantics:
//! docs/src/reference/deck/layers.md (Derived layers). Ported from
//! crates/ingest/src/deck/parse.rs (`layer_expr`, `layer_term`, `call`,
//! `bounds`, `edges_of`, `lower_operands`, `LExpr`).
//!
//! Contents:
//! - `pub const LExpr`, `pub const Fold`
//! - `pub fn layerExpr(p: *Parser) PErr!LExpr`
//! - `pub fn edgesOf(p: *const Parser, e: LExpr) bool`
//! - `pub fn lowerOperands(p: *Parser, name: []const u8, operands: []const LExpr, count: *u32) PErr![]const []const u8`

const std = @import("std");
const geom = @import("geom");
const Dbu = geom.Dbu;
const parser = @import("parser.zig");
const Parser = parser.Parser;
const PErr = parser.PErr;
const Span = parser.Span;
const DerivedOp = @import("layers.zig").DerivedOp;
const max_cell_selections = @import("layers.zig").max_cell_selections;
const kinds = @import("kinds.zig");
const convert = @import("convert.zig");

/// A layer expression before lowering.
pub const LExpr = union(enum) {
    layer: []const u8,
    /// A left fold of one operator.
    op: Fold,
    /// A parenthesised fold, kept apart from the chain around it.
    group: Fold,
    /// `receiver.op(argument)`: the receiver, then the layer argument if any.
    call: Fold,
};

pub const Fold = struct { op: DerivedOp, operands: []const LExpr };

/// `term { op term }`, the same operator folding into one row.
pub fn layerExpr(p: *Parser) PErr!LExpr {
    var left = try layerTerm(p);
    while (true) {
        const op: DerivedOp = if (p.is("and")) .@"and" else if (p.is("or")) .@"or" else if (p.is("not")) .not else return left;
        const at = p.bump();
        const right = try layerTerm(p);
        if (edgesOf(p, left) != edgesOf(p, right)) return p.failTok(at, "cannot combine an edge layer with a polygon layer", .{});
        const operands = if (left == .op and std.meta.activeTag(left.op.op) == std.meta.activeTag(op))
            try append(p, left.op.operands, right)
        else
            try p.scratch.dupe(LExpr, &.{ left, right });
        left = .{ .op = .{ .op = op, .operands = operands } };
    }
}

/// Whether a layer expression is edges.
pub fn edgesOf(p: *const Parser, e: LExpr) bool {
    var at = e;
    while (true) switch (at) {
        .layer => |name| return p.isEdgeLayer(name),
        .op, .group, .call => |f| {
            if (f.op.makesEdges()) |edges| return edges;
            const next = f.operands[0];
            at = next;
        },
    };
}

/// Operand names for a row; a nested chain becomes a hidden derived layer
/// named `name#k`, which no deck text can name.
pub fn lowerOperands(p: *Parser, name: []const u8, operands: []const LExpr, count: *u32) PErr![]const []const u8 {
    const out = try p.arena.alloc([]const u8, operands.len);
    for (operands, out) |operand, *o| o.* = switch (operand) {
        .layer => |layer| layer,
        .op, .group, .call => |f| blk: {
            const layers = try lowerOperands(p, name, f.operands, count);
            count.* += 1;
            const hidden = try std.fmt.allocPrint(p.arena, "{s}#{d}", .{ name, count.* });
            try p.out.derived.append(p.arena, .{ .name = hidden, .op = f.op, .layers = layers });
            break :blk hidden;
        },
    };
    return out;
}

// ---- private ----

fn append(p: *Parser, operands: []const LExpr, next: LExpr) PErr![]const LExpr {
    const out = try p.scratch.alloc(LExpr, operands.len + 1);
    @memcpy(out[0..operands.len], operands);
    out[operands.len] = next;
    return out;
}

fn layerTerm(p: *Parser) PErr!LExpr {
    var method: ?struct { name: []const u8, span: Span } = null;
    var term: LExpr = if (p.eat("(")) blk: {
        const inner = try layerExpr(p);
        _ = try p.expect(")");
        // A parenthesised chain is its own row, never merged into the outer one.
        if (inner == .op) {
            const fold = inner.op;
            break :blk .{ .group = fold };
        }
        break :blk inner;
    } else blk: {
        const word = try p.ident("a layer");
        // `met1.sized(..)` lexes as one word.
        var base = word.name;
        if (std.mem.indexOfScalar(u8, word.name, '.')) |dot| {
            base = word.name[0..dot];
            method = .{ .name = word.name[dot + 1 ..], .span = .{ .start = word.span.start + @as(u32, @intCast(dot)), .end = word.span.end } };
        }
        const v = p.resolve(base, .{ .start = word.span.start, .end = word.span.start + @as(u32, @intCast(base.len)) });
        break :blk .{ .layer = try p.anyLayerName(v) };
    };
    while (true) {
        const m = if (method) |pending| pending else if (p.is(".")) blk: {
            const dot = p.bump();
            const t = p.peek();
            if (t.tok != .ident) return p.failTok(t, "expected a layer operation after `.`", .{});
            _ = p.bump();
            break :blk @TypeOf(method.?){ .name = p.text(t), .span = .{ .start = dot.start, .end = t.end } };
        } else return term;
        method = null;
        const next = try call(p, term, m.name, m.span);
        term = next;
    }
}

fn eql(a: []const u8, b: []const u8) bool {
    return std.mem.eql(u8, a, b);
}

fn oneOf(op: []const u8, words: []const []const u8) bool {
    for (words) |w| if (eql(op, w)) return true;
    return false;
}

/// One `.op(..)` applied to `receiver`. `takes`: the receiver the op takes,
/// `true` edges, `false` polygons, null either.
fn call(p: *Parser, receiver: LExpr, op: []const u8, span: Span) PErr!LExpr {
    const edges = edgesOf(p, receiver);
    var derived: DerivedOp = undefined;
    var takes: ?bool = false;
    var argument: ?LExpr = null;
    if (eql(op, "sized")) {
        _ = try p.expect("(");
        const v = try p.value();
        const dx = try convert.length(p, v, "sized");
        var dy = dx;
        if (p.eat(",")) {
            const second = try p.value();
            dy = try convert.length(p, second, "sized");
            if (std.math.sign(dx) * std.math.sign(dy) < 0) return p.fail(second.span(), "`sized(dx, dy)` grows or shrinks both axes; chain two `sized` for one of each", .{});
        }
        _ = try p.expect(")");
        derived = .{ .sized = .{ .dx = dx, .dy = dy } };
    } else if (oneOf(op, &.{ "interacting", "not_interacting", "inside", "outside", "inside_part", "outside_part", "overlapping", "not_overlapping", "covering", "not_covering" })) {
        _ = try p.expect("(");
        const at = p.peek();
        const other = try layerExpr(p);
        _ = try p.expect(")");
        if (edgesOf(p, other)) return p.failTok(at, "`.{s}` takes a polygon layer", .{op});
        const picks = [_]struct { []const u8, DerivedOp, ?bool }{
            .{ "interacting", .{ .interacting = true }, null },
            .{ "not_interacting", .{ .interacting = false }, null },
            .{ "inside", .inside, false },
            .{ "outside", .outside, false },
            .{ "not_overlapping", .outside, false },
            .{ "overlapping", .overlapping, false },
            .{ "covering", .{ .covering = true }, false },
            .{ "not_covering", .{ .covering = false }, false },
            .{ "inside_part", .{ .part = true }, true },
            .{ "outside_part", .{ .part = false }, true },
        };
        for (picks) |pick| if (eql(op, pick[0])) {
            derived = pick[1];
            takes = pick[2];
        };
        argument = other;
    } else if (eql(op, "extended")) {
        derived = try extended(p);
        takes = true;
    } else if (oneOf(op, &.{ "holes", "extents", "edges" })) {
        _ = try p.expect("(");
        _ = try p.expect(")");
        derived = if (eql(op, "holes")) .holes else if (eql(op, "extents")) .extents else .edges;
    } else if (oneOf(op, &.{ "rectangles", "non_rectangles", "squares", "non_squares" })) {
        _ = try p.expect("(");
        _ = try p.expect(")");
        derived = .{ .rectangles = .{ .square = std.mem.endsWith(u8, op, "squares"), .keep = !std.mem.startsWith(u8, op, "non_") } };
    } else if (oneOf(op, &.{ "with_bbox_max", "with_bbox_min" })) {
        const r = try bounds(p, op, .length, false);
        derived = .{ .with_bbox = .{ .longer = eql(op, "with_bbox_max"), .lo = r.lo, .hi = r.hi } };
    } else if (oneOf(op, &.{ "with_rect", "without_rect" })) {
        _ = try p.expect("(");
        const v = try p.value();
        if (v != .pair) return p.wrong(v, "a box `w x h`", op);
        const w = try convert.length(p, v.pair.a.*, op);
        const h = try convert.length(p, v.pair.b.*, op);
        if (w <= 0 or h <= 0) return p.fail(v.span(), "`.{s}` takes a box with positive sides", .{op});
        _ = try p.expect(")");
        derived = .{ .with_rect = .{ .keep = eql(op, "with_rect"), .w = w, .h = h } };
    } else if (eql(op, "with_area")) {
        derived = .{ .with_area = try bounds(p, op, .area, false) };
    } else if (eql(op, "with_width")) {
        derived = .{ .with_width = try bounds(p, op, .length, true) };
    } else if (eql(op, "with_length")) {
        derived = .{ .with_length = try bounds(p, op, .length, false) };
        takes = true;
    } else if (oneOf(op, &.{ "horizontal", "vertical" })) {
        _ = try p.expect("(");
        _ = try p.expect(")");
        derived = .{ .oriented = eql(op, "vertical") };
        takes = true;
    } else if (eql(op, "texts_outside")) {
        if (!(receiver == .layer and p.isDrawn(receiver.layer))) return p.fail(span, "`.texts_outside` reads the texts drawn on a `gds(..)` layer; apply it to one", .{});
        _ = try p.expect("(");
        const at = p.peek();
        const other = try layerExpr(p);
        _ = try p.expect(")");
        if (edgesOf(p, other)) return p.failTok(at, "`.texts_outside` takes a polygon layer", .{});
        derived = .texts_outside;
        argument = other;
    } else if (oneOf(op, &.{ "with_text", "without_text" })) {
        _ = try p.expect("(");
        const at = p.peek();
        const texts = try p.layerWord();
        if (!p.isDrawn(texts)) return p.failTok(at, "`{s}` is derived; text is drawn on a GDS layer", .{texts});
        _ = try p.expect(",");
        const t = p.peek();
        const pattern = try p.quoted("a text pattern in quotes");
        if (pattern.len == 0) return p.failTok(t, "an empty pattern matches no text", .{});
        _ = try p.expect(")");
        const index: u32 = @intCast(p.out.texts.items.len);
        try p.out.texts.append(p.arena, pattern);
        derived = .{ .with_text = .{ .keep = eql(op, "with_text"), .text = index } };
        argument = .{ .layer = texts };
    } else if (oneOf(op, &.{ "in_cells", "not_in_cells" })) {
        derived = try inCells(p, receiver, op, span);
    } else return p.fail(span, "unknown layer operation `.{s}`", .{op});
    if (takes) |want| if (want != edges) {
        return p.fail(span, "`.{s}` needs {s}, not {s}", .{ op, if (want) "an edge layer" else "a polygon layer", if (want) "polygons" else "edges" });
    };
    const operands = if (argument) |a| try p.scratch.dupe(LExpr, &.{ receiver, a }) else try p.scratch.dupe(LExpr, &.{receiver});
    return .{ .call = .{ .op = derived, .operands = operands } };
}

/// `extended(begin: .., end: .., out: .., in: ..)`, in that order, each 0 or
/// more, `out` or `in` above 0.
fn extended(p: *Parser) PErr!DerivedOp {
    const open = try p.expect("(");
    var by: [4]Dbu = .{ 0, 0, 0, 0 };
    for ([_][]const u8{ "begin", "end", "out", "in" }, 0..) |name, at| {
        if (at > 0) _ = try p.expect(",");
        const t = p.peek();
        const word = try p.ident(try std.fmt.allocPrint(p.scratch, "`{s}:`", .{name}));
        if (!eql(word.name, name)) return p.failTok(t, "`extended` takes `begin:`, `end:`, `out:` and `in:`, in that order", .{});
        _ = try p.expect(":");
        const v = try p.value();
        by[at] = try convert.length(p, v, "extended");
        if (by[at] < 0) return p.fail(v.span(), "`extended` takes lengths of 0 or more", .{});
    }
    const close = try p.expect(")");
    if (by[2] == 0 and by[3] == 0) return p.fail(.{ .start = open.start, .end = close.end }, "`extended` needs `out` or `in` above 0: a box needs a width", .{});
    return .{ .extended = .{ .begin = by[0], .end = by[1], .outside = by[2], .inside = by[3] } };
}

/// `in_cells("pattern", ..)` on a drawn receiver.
fn inCells(p: *Parser, receiver: LExpr, op: []const u8, span: Span) PErr!DerivedOp {
    if (!(receiver == .layer and p.isDrawn(receiver.layer))) return p.fail(span, "`.{s}` selects a drawn layer's shapes by the cell they are drawn in; apply it to a `gds(..)` layer", .{op});
    _ = try p.expect("(");
    const first: u32 = @intCast(p.out.texts.items.len);
    while (true) {
        const t = p.peek();
        const pattern = try p.quoted("a cell-name pattern in quotes");
        if (pattern.len == 0) return p.failTok(t, "an empty pattern matches no cell", .{});
        // KLayout reads these as classes, alternatives and escapes; refused
        // rather than matched differently.
        if (std.mem.indexOfAny(u8, pattern, "[]{}\\") != null) return p.failTok(t, "a cell-name pattern takes `*` and `?` only; `[`, `]`, `{{`, `}}` and `\\` are refused", .{});
        try p.out.texts.append(p.arena, pattern);
        if (!p.eat(",")) break;
    }
    _ = try p.expect(")");
    const count: u32 = @as(u32, @intCast(p.out.texts.items.len)) - first;
    // Each selection is one bit of a placement's tag.
    if (p.cell_selections >= max_cell_selections) return p.fail(span, "a deck holds at most {d} `.in_cells` and `.not_in_cells` selections", .{max_cell_selections});
    p.cell_selections += 1;
    return .{ .in_cells = .{ .keep = eql(op, "in_cells"), .first = first, .count = count } };
}

/// `(cmp value {, cmp value})`: at most one bound each side, or one `==`;
/// inclusive, in grid units. With `square`, a length bound `n` is on
/// `2·n·|n|`, so a strict bound stays exact on an irrational width: `> 70`
/// is `>= 9801`.
fn bounds(p: *Parser, op: []const u8, dim: kinds.Dim, square: bool) PErr!@import("layers.zig").Range {
    const open = try p.expect("(");
    var lo: ?i128 = null;
    var hi: ?i128 = null;
    while (true) {
        const t = p.peek();
        const cmp = p.text(t);
        if (t.tok != .punct or !oneOf(cmp, &.{ ">=", ">", "<=", "<", "==" })) return p.failTok(t, "expected a bound such as `>= 1um`, found {s}", .{try p.found(t)});
        _ = p.bump();
        const v = try p.value();
        const raw: i128 = if (dim == .area) try convert.area(p, v, op) else try convert.length(p, v, op);
        const n = if (square) 2 * raw * @as(i128, @intCast(@abs(raw))) else raw;
        const low: ?i128 = if (eql(cmp, ">=") or eql(cmp, "==")) n else if (eql(cmp, ">")) n + 1 else null;
        const high: ?i128 = if (eql(cmp, "<=") or eql(cmp, "==")) n else if (eql(cmp, "<")) n - 1 else null;
        if ((low != null and lo != null) or (high != null and hi != null)) return p.failTok(t, "`.{s}` takes one bound on each side", .{op});
        lo = lo orelse low;
        hi = hi orelse high;
        if (!p.eat(",")) break;
    }
    const close = try p.expect(")");
    const r: @import("layers.zig").Range = .{ .lo = lo orelse std.math.minInt(i128), .hi = hi orelse std.math.maxInt(i128) };
    if (r.lo > r.hi) return p.fail(.{ .start = open.start, .end = close.end }, "the range is empty", .{});
    return r;
}
