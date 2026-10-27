//! `rule` and `stage` statements: `rule <id> <kind>(<layers>; <name: value>..)
//! [cmp value]` → one `RuleSource` row, its kind picked from the kind table by
//! name, modifier, layer count, comparison and the named arguments given. A
//! layer expression among the arguments becomes a derived layer named
//! `<rule id>@k`. Rules: docs/src/reference/deck/rules.md. Ported from
//! crates/ingest/src/deck/parse.rs (`rule`, `stage`, `rule_id`, `args`,
//! `positional`, `pick`, `cmp_text`).
//!
//! Contents:
//! - `pub fn rule(p: *Parser) PErr!void`
//! - `pub fn stage(p: *Parser, span: Span) PErr!void`
//! - `pub fn ruleId(p: *Parser, t: Token) PErr![]const u8`

const std = @import("std");
const parser = @import("parser.zig");
const Parser = parser.Parser;
const PErr = parser.PErr;
const Span = parser.Span;
const Val = parser.Val;
const Named = parser.Named;
const Token = @import("lex.zig").Token;
const kinds = @import("kinds.zig");
const Kind = kinds.Kind;
const Cmp = kinds.Cmp;
const source = @import("source.zig");
const parse_layers = @import("parse_layers.zig");
const params_mod = @import("parse_params.zig");

/// One rule statement.
pub fn rule(p: *Parser) PErr!void {
    const t = p.peek();
    if (t.tok != .rule_id) return p.failTok(t, "expected a rule id", .{});
    _ = p.bump();
    const id = try ruleId(p, t);
    if ((try p.rule_ids.getOrPut(p.scratch, id)).found_existing) return p.failTok(t, "duplicate rule id `{s}`", .{id});
    p.context = id;
    p.inline_count = 0;
    const warning = p.eat("warning");
    const name = try p.ident("a check kind");
    _ = try p.expect("(");
    var positional: std.ArrayList(Val) = .empty;
    var named: std.ArrayList(Named) = .empty;
    try args(p, &positional, &named);
    if (p.eat("(")) try named.appendSlice(p.scratch, try p.namedArgs());
    const c = p.peek();
    const cmp: ?struct { cmp: Cmp, span: Span, value: Val } = if (c.tok == .punct and isCmp(p.text(c))) blk: {
        _ = p.bump();
        const word = p.text(c);
        const which: Cmp = if (std.mem.eql(u8, word, ">=")) .ge else if (std.mem.eql(u8, word, "<=")) .le else .eq;
        break :blk .{ .cmp = which, .span = .{ .start = c.start, .end = c.end }, .value = try p.value() };
    } else null;
    const kind = try pick(p, name, &positional, if (cmp) |x| .{ x.cmp, x.span } else null, named.items);
    const slots = kinds.edgeSlots(kind.engine);
    var layers: std.ArrayList([]const u8) = .empty;
    const values = try p.scratch.alloc(Val, kind.layers.len + if (kind.more) positional.items.len - kind.layers.len else 0);
    for (kind.layers, 0..) |slot, at| values[at] = positional.items[slot];
    if (kind.more) @memcpy(values[kind.layers.len..], positional.items[kind.layers.len..]);
    for (values, 0..) |v, at| {
        const want: ?bool = if (at < slots.len) slots[at] else false;
        try layers.append(p.arena, if (want) |edges| if (!edges) try p.layerName(v) else blk: {
            const layer = try p.anyLayerName(v);
            if (!p.isEdgeLayer(layer)) return p.fail(v.span(), "`{s}` here takes an edge layer; `{s}` is polygons", .{ name.name, layer });
            break :blk layer;
        } else try p.anyLayerName(v));
    }
    var out: std.ArrayList(source.NamedSource) = .empty;
    const owner = try std.fmt.allocPrint(p.scratch, "`{s}`", .{name.name});
    try params_mod.named(p, named.items, kind.params, owner, name.span, &out);
    if (std.mem.eql(u8, kind.engine, "spacing_table")) try params_mod.spacingTable(p, named.items);
    if (std.mem.eql(u8, kind.engine, "eol_extension_spacing")) try params_mod.eolExtensionRows(p, named.items);
    if (kind.limit) |limit| if (cmp) |x| {
        var with_name = limit;
        with_name.name = kind.name;
        try params_mod.param(p, x.value, with_name, &out);
    };
    for (kind.fixed) |f| try out.append(p.arena, .{ .name = f[0], .value = .{ .value = .{ .flag = f[1] } } });
    if (warning) try out.append(p.arena, .{ .name = "warning", .value = .{ .value = .{ .flag = true } } });
    try p.out.rules.append(p.arena, .{ .id = id, .kind = kind.engine, .layers = layers.items, .params = out.items });
    // The last `stage` line's; a rule before the first one is refused there.
    if (p.out.stages.items.len > 0) try p.out.stages.items[p.out.stages.items.len - 1].rules.append(p.arena, id);
}

/// `stage <name>`: the rules after it, up to the next `stage`, are one stage.
pub fn stage(p: *Parser, span: Span) PErr!void {
    const name = try p.ident("a stage name");
    for (p.out.stages.items) |s| if (std.mem.eql(u8, s.name, name.name)) {
        return p.fail(name.span, "stage `{s}` is already stated; a stage's rules are written together", .{name.name});
    };
    if (p.out.stages.items.len == 0 and p.out.rules.items.len > 0) {
        return p.fail(span, "{d} rules come before the first `stage` line; every rule of a staged deck belongs to a stage", .{p.out.rules.items.len});
    }
    if (p.out.stages.items.len >= std.math.maxInt(u16)) return p.fail(name.span, "too many stages", .{});
    try p.out.stages.append(p.arena, .{ .name = name.name });
}

/// The rule id with every `{name}` replaced by its binding.
pub fn ruleId(p: *Parser, t: Token) PErr![]const u8 {
    var rest = p.text(t);
    var out: std.ArrayList(u8) = .empty;
    while (std.mem.indexOfScalar(u8, rest, '{')) |open| {
        try out.appendSlice(p.arena, rest[0..open]);
        const close = std.mem.indexOfScalarPos(u8, rest, open, '}') orelse return p.failTok(t, "unclosed `{{` in rule id", .{});
        const name = rest[open + 1 .. close];
        const v = p.bound(name) orelse return p.failTok(t, "`{{{s}}}` in the rule id is not a bound name or number", .{name});
        switch (v) {
            .word => |w| try out.appendSlice(p.arena, w.name),
            .num => |n| {
                try out.appendSlice(p.arena, n.text);
                try out.appendSlice(p.arena, n.unit);
            },
            else => return p.failTok(t, "`{{{s}}}` in the rule id is not a bound name or number", .{name}), // else: only a word or a number splices in
        }
        rest = rest[close + 1 ..];
    }
    try out.appendSlice(p.arena, rest);
    if (std.mem.indexOfScalar(u8, out.items, '}') != null) return p.failTok(t, "stray `}}` in rule id", .{});
    return out.items;
}

// ---- private ----

fn isCmp(word: []const u8) bool {
    return std.mem.eql(u8, word, ">=") or std.mem.eql(u8, word, "<=") or std.mem.eql(u8, word, "==");
}

/// Arguments up to `)`: positional layers then `name: value`, separated by
/// `,` or `;`.
fn args(p: *Parser, positional: *std.ArrayList(Val), named: *std.ArrayList(Named)) PErr!void {
    while (true) {
        while (p.eat(",") or p.eat(";")) {}
        if (p.eat(")")) return;
        const t = p.peek();
        const next = p.peekAt(1);
        if (t.tok == .ident and next.tok == .punct and std.mem.eql(u8, p.text(next), ":")) {
            _ = p.bump();
            _ = p.bump();
            try named.append(p.scratch, .{ .name = p.text(t), .span = .{ .start = t.start, .end = t.end }, .value = try p.value() });
        } else if (named.items.len > 0) {
            return p.failTok(t, "expected `name: value` (layers come before named arguments)", .{});
        } else {
            try positional.append(p.scratch, try positionalArg(p));
        }
        const after = p.peek();
        if (!(p.is(",") or p.is(";") or p.is(")"))) return p.failTok(after, "expected `,` or `)`, found {s}", .{try p.found(after)});
    }
}

/// A rule's layer argument: a value, or a layer expression lowered to a
/// derived layer named `<rule id>@<k>`, which no deck text can name.
fn positionalArg(p: *Parser) PErr!Val {
    const t = p.peek();
    const next = p.peekAt(1);
    const word = t.tok == .ident and std.mem.indexOfScalar(u8, p.text(t), '.') == null;
    const n = p.text(next);
    const ends = next.tok == .punct and (std.mem.eql(u8, n, ",") or std.mem.eql(u8, n, ";") or std.mem.eql(u8, n, ")"));
    if ((word and ends) or !(t.tok == .ident or p.is("("))) return p.value();
    const expr = try parse_layers.layerExpr(p);
    const span: Span = .{ .start = t.start, .end = p.toks[p.pos - 1].end };
    const edges = parse_layers.edgesOf(p, expr);
    const fold = switch (expr) {
        .layer => |name| return .{ .word = .{ .name = name, .span = span } },
        .op, .group, .call => |f| f,
    };
    p.inline_count += 1;
    const name = try std.fmt.allocPrint(p.arena, "{s}@{d}", .{ p.context, p.inline_count });
    var count: u32 = 0;
    const layers = try parse_layers.lowerOperands(p, name, fold.operands, &count);
    try p.out.derived.append(p.arena, .{ .name = name, .op = fold.op, .layers = layers });
    if (edges) try p.edge_layers.put(p.scratch, name, {});
    try p.layers.put(p.scratch, name, {});
    return .{ .word = .{ .name = name, .span = span } };
}

fn cmpText(cmp: Cmp) []const u8 {
    return switch (cmp) {
        .absent => "no comparison",
        .ge => "`>=`",
        .le => "`<=`",
        .eq => "`==`",
    };
}

fn optEql(a: ?[]const u8, b: ?[]const u8) bool {
    if (a == null or b == null) return a == null and b == null;
    return std.mem.eql(u8, a.?, b.?);
}

/// How many of `named` the kind knows.
fn known(k: *const Kind, named: []const Named) usize {
    var n: usize = 0;
    for (named) |arg| {
        for (k.params) |param| if (std.mem.eql(u8, param.name, arg.name)) {
            n += 1;
            break;
        };
    }
    return n;
}

/// The table row for a kind name, its layer count, modifier and
/// comparison; among rows alike but for their named arguments, the one
/// knowing the most of those given, the first on a tie.
fn pick(p: *Parser, name: parser.Ident, positional: *std.ArrayList(Val), cmp: ?struct { Cmp, Span }, named: []const Named) PErr!*const Kind {
    var rows: std.ArrayList(*const Kind) = .empty;
    for (kinds.kinds) |*k| if (std.mem.eql(u8, k.name, name.name)) try rows.append(p.scratch, k);
    if (rows.items.len == 0) return p.fail(name.span, "unknown check kind `{s}`", .{name.name});
    // An edge layer first picks the edge rows, a polygon layer the others;
    // when none fits, the layer check names the mismatch.
    const edges = positional.items.len > 0 and positional.items[0] == .word and p.isEdgeLayer(positional.items[0].word.name);
    var fitting: std.ArrayList(*const Kind) = .empty;
    for (rows.items) |k| {
        const fits = if (edges) kinds.edgeSlots(k.engine).len > 0 else !std.mem.startsWith(u8, k.engine, "edge_");
        if (fits) try fitting.append(p.scratch, k);
    }
    if (fitting.items.len > 0) rows = fitting;
    // A trailing bare word the kind knows as a modifier (`opposite`).
    var modifier: ?[]const u8 = null;
    if (positional.items.len > 0 and positional.items[positional.items.len - 1] == .word) {
        const word = positional.items[positional.items.len - 1].word.name;
        for (rows.items) |k| if (optEql(k.modifier, word)) {
            modifier = word;
            _ = positional.pop();
            break;
        };
    }
    const n = positional.items.len;
    var by_arity: std.ArrayList(*const Kind) = .empty;
    for (rows.items) |k| {
        if (!optEql(k.modifier, modifier)) continue;
        if (n == k.layers.len or (k.more and n > k.layers.len)) try by_arity.append(p.scratch, k);
    }
    if (by_arity.items.len == 0) {
        var arities: std.ArrayList([]const u8) = .empty;
        for (rows.items) |k| {
            if (!optEql(k.modifier, modifier)) continue;
            const a = try std.fmt.allocPrint(p.scratch, "{d}{s}", .{ k.layers.len, if (k.more) " or more" else "" });
            if (arities.items.len == 0 or !std.mem.eql(u8, arities.items[arities.items.len - 1], a)) try arities.append(p.scratch, a);
        }
        return p.fail(name.span, "`{s}` takes {s} layers, got {d}", .{ name.name, try std.mem.join(p.scratch, " or ", arities.items), n });
    }
    const given: Cmp = if (cmp) |x| x[0] else .absent;
    // A kind with forms with and without a comparison: with no comparison
    // and none of the comparison-free form's arguments named, the comparison
    // is what is missing.
    const compared = for (by_arity.items) |k| {
        if (k.cmp != .absent) break true;
    } else false;
    var best: ?*const Kind = null;
    for (by_arity.items) |k| {
        const missing_comparison = given == .absent and compared and named.len == 0 and k.params.len > 0;
        if (k.cmp != given or missing_comparison) continue;
        if (best == null or known(k, named) > known(best.?, named)) best = k;
    }
    if (best) |k| return k;
    var legal: std.ArrayList([]const u8) = .empty;
    for (by_arity.items) |k| if (!(cmp == null and compared and k.cmp == .absent)) try legal.append(p.scratch, cmpText(k.cmp));
    const joined = try std.mem.join(p.scratch, " or ", legal.items);
    const x = cmp orelse return p.fail(name.span, "`{s}` needs a comparison: {s}", .{ name.name, joined });
    if (legal.items.len == 1 and std.mem.eql(u8, legal.items[0], "no comparison")) return p.fail(x[1], "`{s}` takes no comparison; its values are named arguments", .{name.name});
    return p.fail(x[1], "{s} is not legal on `{s}`; it takes {s}", .{ cmpText(x[0]), name.name, joined });
}
