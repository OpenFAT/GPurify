//! The deck parser's state and its token-level reading: tokens → values
//! (`Val`), names and quoted strings, each error a located `Diagnostic` with
//! the current rule id prefixed. Every statement reader in `parse_*.zig`
//! works through this. Ported from crates/ingest/src/deck/parse.rs
//! (`Parser`, its token, error and value methods, `Val`, `Named`).
//!
//! Contents:
//! - `pub const PErr`, `pub const max_errors`, `pub const Span`, `pub const Val`, `pub const Named`,
//!   `Val.span(v: Val) Span`, `Val.at(v: Val, s: Span) Val`, `Val.shown(v: Val, arena: Allocator) Allocator.Error![]const u8`
//! - `pub const Binding`, `pub const Parser`,
//!   `Parser.init(arena: Allocator, scratch: Allocator, src: []const u8, toks: []const Token, layout: Grid, errors: std.ArrayList(Diagnostic)) Allocator.Error!Parser`,
//!   `Parser.peek(p: *const Parser) Token`, `Parser.peekAt(p: *const Parser, ahead: usize) Token`,
//!   `Parser.text(p: *const Parser, t: Token) []const u8`, `Parser.bump(p: *Parser) Token`,
//!   `Parser.is(p: *const Parser, word: []const u8) bool`, `Parser.eat(p: *Parser, word: []const u8) bool`,
//!   `Parser.expect(p: *Parser, word: []const u8) PErr!Token`, `Parser.found(p: *Parser, t: Token) Allocator.Error![]const u8`,
//!   `Parser.ident(p: *Parser, what: []const u8) PErr!Ident`, `pub const Ident`,
//!   `Parser.fail(p: *Parser, span: Span, comptime fmt: []const u8, args: anytype) PErr`,
//!   `Parser.failTok(p: *Parser, t: Token, comptime fmt: []const u8, args: anytype) PErr`,
//!   `Parser.recover(p: *Parser) void`, `Parser.lineEnd(p: *const Parser) bool`,
//!   `Parser.keyed(p: *Parser, statement: []const u8, keys: []const []const u8, what: []const u8, expected: []const u8, reader: anytype) PErr!void`,
//!   `Parser.minMax(p: *Parser, comptime T: type, reader: anytype) PErr![2]?T`,
//!   `Parser.value(p: *Parser) PErr!Val`, `Parser.resolve(p: *const Parser, name: []const u8, span: Span) Val`,
//!   `Parser.bound(p: *const Parser, name: []const u8) ?Val`,
//!   `Parser.quoted(p: *Parser, what: []const u8) PErr![]const u8`, `Parser.model(p: *Parser) PErr![]const u8`,
//!   `Parser.layerWord(p: *Parser) PErr![]const u8`, `Parser.layerList(p: *Parser) PErr![]const []const u8`,
//!   `Parser.isDrawn(p: *const Parser, name: []const u8) bool`,
//!   `Parser.layerName(p: *Parser, v: Val) PErr![]const u8`, `Parser.anyLayerName(p: *Parser, v: Val) PErr![]const u8`,
//!   `Parser.isEdgeLayer(p: *const Parser, name: []const u8) bool`,
//!   `Parser.forward(p: *Parser, name: []const u8, used: u32) Allocator.Error!?[]const u8`,
//!   `Parser.wrong(p: *Parser, v: Val, want: []const u8, label: []const u8) PErr`,
//!   `Parser.namedArgs(p: *Parser) PErr![]const Named`

const std = @import("std");
const Allocator = std.mem.Allocator;
const geom = @import("geom");
const Grid = geom.Grid;
const lex = @import("lex.zig");
const Token = lex.Token;
const Diagnostic = @import("diagnostic.zig").Diagnostic;
const DeckSource = @import("source.zig").DeckSource;
const units = @import("units.zig");
const Dec = units.Dec;

/// `Stop`: an error is already recorded; unwind to the statement.
pub const PErr = error{ Stop, OutOfMemory };

/// Parsing stops after this many errors.
pub const max_errors = 50;

/// A byte span in the deck text.
pub const Span = struct { start: u32, end: u32 };

/// A value as written, before a parameter gives it a dimension. Slices
/// point into the parser's copy of the text or its scratch arena.
pub const Val = union(enum) {
    /// A number and its unit (empty when bare).
    num: struct { text: []const u8, unit: []const u8, neg: bool, span: Span },
    /// A bare word: a layer, `none`, `true`, `false`, or a modifier.
    word: struct { name: []const u8, span: Span },
    /// A quoted string: a device model name.
    str: struct { text: []const u8, span: Span },
    list: struct { items: []const Val, span: Span },
    tuple: struct { items: []const Val, span: Span },
    group: struct { named: []const Named, span: Span },
    pair: struct { a: *const Val, b: *const Val, span: Span },

    pub fn span(v: Val) Span {
        return switch (v) {
            inline else => |x| x.span,
        };
    }

    /// The same value, reported at `s` (a variable's use, not its `let`).
    pub fn at(v: Val, s: Span) Val {
        var out = v;
        switch (out) {
            inline else => |*x| x.span = s,
        }
        return out;
    }

    /// How the value reads in an error.
    pub fn shown(v: Val, arena: Allocator) Allocator.Error![]const u8 {
        return switch (v) {
            .num => |n| if (n.unit.len == 0)
                std.fmt.allocPrint(arena, "{s}{s} (no unit)", .{ if (n.neg) "-" else "", n.text })
            else
                std.fmt.allocPrint(arena, "{s}{s}{s}", .{ if (n.neg) "-" else "", n.text, n.unit }),
            .word => |w| std.fmt.allocPrint(arena, "`{s}`", .{w.name}),
            .str => |s| std.fmt.allocPrint(arena, "\"{s}\"", .{s.text}),
            .list => "a list",
            .tuple => "a tuple",
            .group => "named arguments",
            .pair => "a pair",
        };
    }
};

/// `name: value`.
pub const Named = struct { name: []const u8, span: Span, value: Val };

/// A `let` or `for` binding.
pub const Binding = struct { name: []const u8, value: Val };

/// An identifier token's text and span.
pub const Ident = struct { name: []const u8, span: Span };

/// The parse in progress. `arena` holds what outlives the parse (the
/// source copy, `out`, the diagnostics); `scratch` the rest (tokens'
/// values, bindings, name sets).
pub const Parser = struct {
    arena: Allocator,
    scratch: Allocator,
    src: []const u8,
    toks: []const Token,
    pos: usize = 0,
    errors: std.ArrayList(Diagnostic),
    /// `let` and `for` bindings, innermost last.
    env: std.ArrayList(Binding) = .empty,
    /// Layers declared so far, and which of them are edge layers.
    layers: std.StringHashMapUnmanaged(void) = .empty,
    edge_layers: std.StringHashMapUnmanaged(void) = .empty,
    /// Every `layer`/`let` name in the file and where it is declared, for
    /// reporting a use before its declaration.
    ahead: std.StringHashMapUnmanaged(u32) = .empty,
    rule_ids: std.StringHashMapUnmanaged(void) = .empty,
    /// The deck's grid in nanometres.
    deck_grid: ?Dec = null,
    layout: Grid,
    /// The rule being parsed, prefixed to its errors.
    context: []const u8 = "",
    /// Layer expressions lowered so far among the current rule's arguments.
    inline_count: u32 = 0,
    touch: bool = false,
    /// Each `ignore gds(L, D)` pair, and where it was written.
    ignored_at: std.ArrayList(struct { pair: [2]u16, span: Span }) = .empty,
    /// `.in_cells` and `.not_in_cells` parsed so far.
    cell_selections: usize = 0,
    /// Where each `matching` statement's model is written, by `out.matching`
    /// row: a second statement for the model names the first one's line.
    matching_at: std.ArrayList(u32) = .empty,
    out: DeckSource = .{},

    pub fn init(arena: Allocator, scratch: Allocator, src: []const u8, toks: []const Token, layout: Grid, errors: std.ArrayList(Diagnostic)) Allocator.Error!Parser {
        var p: Parser = .{ .arena = arena, .scratch = scratch, .src = src, .toks = toks, .layout = layout, .errors = errors };
        for (toks[0 .. toks.len - 1], toks[1..]) |a, b| {
            const word = src[a.start..a.end];
            if (a.tok == .ident and (std.mem.eql(u8, word, "layer") or std.mem.eql(u8, word, "let")) and b.tok == .ident) {
                const gop = try p.ahead.getOrPut(scratch, src[b.start..b.end]);
                if (!gop.found_existing) gop.value_ptr.* = b.start;
            }
        }
        return p;
    }

    // ---- tokens ----

    pub fn peek(p: *const Parser) Token {
        return p.toks[p.pos];
    }

    pub fn peekAt(p: *const Parser, ahead: usize) Token {
        return p.toks[@min(p.pos + ahead, p.toks.len - 1)];
    }

    pub fn text(p: *const Parser, t: Token) []const u8 {
        return p.src[t.start..t.end];
    }

    pub fn bump(p: *Parser) Token {
        const t = p.peek();
        if (t.tok != .eof) p.pos += 1;
        return t;
    }

    pub fn is(p: *const Parser, word: []const u8) bool {
        const t = p.peek();
        return (t.tok == .punct or t.tok == .ident) and std.mem.eql(u8, p.text(t), word);
    }

    pub fn eat(p: *Parser, word: []const u8) bool {
        const hit = p.is(word);
        if (hit) _ = p.bump();
        return hit;
    }

    pub fn expect(p: *Parser, word: []const u8) PErr!Token {
        if (p.is(word)) return p.bump();
        const t = p.peek();
        return p.failTok(t, "expected `{s}`, found {s}", .{ word, try p.found(t) });
    }

    pub fn found(p: *Parser, t: Token) Allocator.Error![]const u8 {
        return switch (t.tok) {
            .newline => "end of line",
            .eof => "end of file",
            else => std.fmt.allocPrint(p.scratch, "`{s}`", .{p.text(t)}),
        };
    }

    pub fn ident(p: *Parser, what: []const u8) PErr!Ident {
        const t = p.peek();
        if (t.tok == .ident) {
            _ = p.bump();
            return .{ .name = p.text(t), .span = .{ .start = t.start, .end = t.end } };
        }
        return p.failTok(t, "expected {s}, found {s}", .{ what, try p.found(t) });
    }

    // ---- errors ----

    /// Records an error at `span`, prefixed with the rule being parsed, once:
    /// a `for` body reports an error once, not once per element.
    pub fn fail(p: *Parser, span: Span, comptime fmt: []const u8, args: anytype) PErr {
        const body = try std.fmt.allocPrint(p.arena, fmt, args);
        const message = if (p.context.len == 0) body else try std.fmt.allocPrint(p.arena, "{s}: {s}", .{ p.context, body });
        const d: Diagnostic = .{ .message = message, .start = span.start, .end = span.end };
        const seen = for (p.errors.items) |e| {
            if (e.start == d.start and e.end == d.end and std.mem.eql(u8, e.message, d.message)) break true;
        } else false;
        if (p.errors.items.len < max_errors and !seen) try p.errors.append(p.arena, d);
        return error.Stop;
    }

    pub fn failTok(p: *Parser, t: Token, comptime fmt: []const u8, args: anytype) PErr {
        return p.fail(.{ .start = t.start, .end = t.end }, fmt, args);
    }

    /// Skips to the end of the current statement.
    pub fn recover(p: *Parser) void {
        while (!p.lineEnd()) _ = p.bump();
    }

    /// Whether the statement ends here.
    pub fn lineEnd(p: *const Parser) bool {
        const t = p.peek().tok;
        return t == .newline or t == .eof;
    }

    /// `key value` pairs to the end of the line, each of `keys` at most
    /// once: `reader.read(p, at, key)` reads the value of `keys[at]`, stores
    /// it, and returns whether the key was not given before. `what` names a
    /// key in a syntax error, `expected` lists them after an unknown one.
    pub fn keyed(p: *Parser, statement: []const u8, keys: []const []const u8, what: []const u8, expected: []const u8, reader: anytype) PErr!void {
        while (!p.lineEnd()) {
            const key = try p.ident(what);
            const at = for (keys, 0..) |k, i| {
                if (std.mem.eql(u8, k, key.name)) break i;
            } else return p.fail(key.span, "unknown {s} key `{s}`; expected {s}", .{ statement, key.name, expected });
            if (!try reader.read(p, at, key.name)) return p.fail(key.span, "`{s}` is given twice", .{key.name});
        }
    }

    /// `>= value` and `<= value` to the end of the line, each at most once,
    /// `reader.read(p, value)` converting each: a lower and an upper bound.
    pub fn minMax(p: *Parser, comptime T: type, reader: anytype) PErr![2]?T {
        var bounds: [2]?T = .{ null, null };
        while (!p.lineEnd()) {
            const t = p.peek();
            const slot: usize = if (p.eat(">=")) 0 else if (p.eat("<=")) 1 else return p.failTok(t, "expected >= or <=, found {s}", .{try p.found(t)});
            const v = try p.value();
            const read = try reader.read(p, v);
            if (bounds[slot] != null) return p.failTok(t, "this bound is already given", .{});
            bounds[slot] = read;
        }
        return bounds;
    }

    // ---- values ----

    pub fn value(p: *Parser) PErr!Val {
        const first = try p.atom();
        if (p.is("x")) {
            _ = p.bump();
            const second = try p.atom();
            const a = try p.scratch.create(Val);
            const b = try p.scratch.create(Val);
            a.* = first;
            b.* = second;
            return .{ .pair = .{ .a = a, .b = b, .span = .{ .start = first.span().start, .end = second.span().end } } };
        }
        return first;
    }

    /// A word's binding, reported at its use; an unbound word stays a word.
    pub fn resolve(p: *const Parser, name: []const u8, span: Span) Val {
        if (p.bound(name)) |v| return v.at(span);
        return .{ .word = .{ .name = name, .span = span } };
    }

    /// The innermost binding of `name`.
    pub fn bound(p: *const Parser, name: []const u8) ?Val {
        var i = p.env.items.len;
        while (i > 0) {
            i -= 1;
            if (std.mem.eql(u8, p.env.items[i].name, name)) return p.env.items[i].value;
        }
        return null;
    }

    /// A string in quotes, `what` naming it in an error.
    pub fn quoted(p: *Parser, what: []const u8) PErr![]const u8 {
        const t = p.peek();
        if (t.tok != .str) return p.failTok(t, "expected {s}, found {s}", .{ what, try p.found(t) });
        _ = p.bump();
        return p.string(t);
    }

    /// A device model name in quotes.
    pub fn model(p: *Parser) PErr![]const u8 {
        return p.quoted("a model name in quotes");
    }

    pub fn layerWord(p: *Parser) PErr![]const u8 {
        const t = p.peek();
        if (t.tok != .ident) return p.failTok(t, "expected a layer, found {s}", .{try p.found(t)});
        _ = p.bump();
        return p.layerName(p.resolve(p.text(t), .{ .start = t.start, .end = t.end }));
    }

    pub fn layerList(p: *Parser) PErr![]const []const u8 {
        const v = try p.value();
        if (v != .list) return p.fail(v.span(), "expected a list of layers, got {s}", .{try v.shown(p.scratch)});
        const out = try p.arena.alloc([]const u8, v.list.items.len);
        for (v.list.items, out) |item, *o| o.* = try p.layerName(item);
        return out;
    }

    /// Whether `name` is a drawn layer, one declared as `gds(..)`.
    pub fn isDrawn(p: *const Parser, name: []const u8) bool {
        for (p.out.layers.items) |l| if (std.mem.eql(u8, l.name, name)) return true;
        return false;
    }

    /// A declared polygon layer's name.
    pub fn layerName(p: *Parser, v: Val) PErr![]const u8 {
        const name = try p.anyLayerName(v);
        if (p.isEdgeLayer(name)) return p.fail(v.span(), "`{s}` is an edge layer; only a check that takes edges can use it", .{name});
        return name;
    }

    /// A declared layer's name, polygons or edges.
    pub fn anyLayerName(p: *Parser, v: Val) PErr![]const u8 {
        switch (v) {
            .word => |w| {
                if (p.layers.contains(w.name)) return w.name;
                if (try p.forward(w.name, w.span.start)) |message| return p.fail(w.span, "{s}", .{message});
                return p.fail(w.span, "unknown layer `{s}`", .{w.name});
            },
            else => return p.fail(v.span(), "expected a layer, got {s}", .{try v.shown(p.scratch)}),
        }
    }

    pub fn isEdgeLayer(p: *const Parser, name: []const u8) bool {
        return p.edge_layers.contains(name);
    }

    /// "used before its declaration", when `name` is declared later.
    pub fn forward(p: *Parser, name: []const u8, used: u32) Allocator.Error!?[]const u8 {
        const declared = p.ahead.get(name) orelse return null;
        if (declared < used) return null;
        const line = std.mem.count(u8, p.src[0..declared], "\n") + 1;
        return try std.fmt.allocPrint(p.scratch, "`{s}` is used before its declaration on line {d}", .{ name, line });
    }

    /// `label needs want, got <value>`, or the forward-use message for a word
    /// declared later.
    pub fn wrong(p: *Parser, v: Val, want: []const u8, label: []const u8) PErr {
        if (v == .word) if (try p.forward(v.word.name, v.word.span.start)) |message| return p.fail(v.span(), "{s}", .{message});
        return p.fail(v.span(), "{s} needs {s}, got {s}", .{ label, want, try v.shown(p.scratch) });
    }

    /// `name: value` arguments up to `)`, separated by `,` or `;`: a group,
    /// or a rule's second argument list.
    pub fn namedArgs(p: *Parser) PErr![]const Named {
        var named: std.ArrayList(Named) = .empty;
        while (true) {
            while (p.eat(",") or p.eat(";")) {}
            if (p.eat(")")) return named.items;
            const t = p.peek();
            const next = p.peekAt(1);
            if (!(t.tok == .ident and next.tok == .punct and std.mem.eql(u8, p.text(next), ":"))) {
                return p.failTok(t, "expected `name: value` (layers come before named arguments)", .{});
            }
            _ = p.bump();
            _ = p.bump();
            try named.append(p.scratch, .{ .name = p.text(t), .span = .{ .start = t.start, .end = t.end }, .value = try p.value() });
            const after = p.peek();
            if (!(p.is(",") or p.is(";") or p.is(")"))) return p.failTok(after, "expected `,` or `)`, found {s}", .{try p.found(after)});
        }
    }

    // ---- private ----

    fn atom(p: *Parser) PErr!Val {
        const t = p.peek();
        const neg = p.is("-");
        if (neg) _ = p.bump();
        const n = p.peek();
        if (n.tok == .num) {
            _ = p.bump();
            return .{ .num = .{ .text = p.src[n.start..n.unit_at], .unit = p.src[n.unit_at..n.end], .neg = neg, .span = .{ .start = t.start, .end = n.end } } };
        }
        if (neg) return p.failTok(n, "expected a number after `-`", .{});
        const span: Span = .{ .start = t.start, .end = t.end };
        switch (t.tok) {
            .ident => {
                _ = p.bump();
                return p.resolve(p.text(t), span);
            },
            .str => {
                _ = p.bump();
                return .{ .str = .{ .text = try p.string(t), .span = span } };
            },
            .punct => {
                if (std.mem.eql(u8, p.text(t), "[")) {
                    _ = p.bump();
                    const items = try p.listItems("]");
                    return .{ .list = .{ .items = items, .span = .{ .start = t.start, .end = p.toks[p.pos - 1].end } } };
                }
                if (std.mem.eql(u8, p.text(t), "(")) {
                    _ = p.bump();
                    const next = p.peekAt(1);
                    if (p.peek().tok == .ident and next.tok == .punct and std.mem.eql(u8, p.text(next), ":")) {
                        const named = try p.namedArgs();
                        return .{ .group = .{ .named = named, .span = .{ .start = t.start, .end = p.toks[p.pos - 1].end } } };
                    }
                    const items = try p.listItems(")");
                    return .{ .tuple = .{ .items = items, .span = .{ .start = t.start, .end = p.toks[p.pos - 1].end } } };
                }
            },
            .rule_id, .num, .newline, .eof => {},
        }
        return p.failTok(t, "expected a value, found {s}", .{try p.found(t)});
    }

    fn listItems(p: *Parser, close: []const u8) PErr![]const Val {
        var out: std.ArrayList(Val) = .empty;
        while (true) {
            if (p.eat(close)) return out.items;
            try out.append(p.scratch, try p.value());
            if (!p.eat(",")) {
                _ = try p.expect(close);
                return out.items;
            }
        }
    }

    /// The text of a string token, `\"` and `\\` unescaped.
    fn string(p: *Parser, t: Token) PErr![]const u8 {
        const raw = p.src[t.start + 1 .. t.end - 1];
        if (std.mem.indexOfScalar(u8, raw, '\\') == null) return raw;
        var out: std.ArrayList(u8) = .empty;
        var i: usize = 0;
        while (i < raw.len) : (i += 1) {
            if (raw[i] != '\\') {
                try out.append(p.arena, raw[i]);
                continue;
            }
            i += 1;
            if (i >= raw.len or (raw[i] != '"' and raw[i] != '\\')) return p.failTok(t, "only \\\" and \\\\ escape in a string", .{});
            try out.append(p.arena, raw[i]);
        }
        return out.items;
    }
};
