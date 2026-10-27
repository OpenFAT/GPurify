//! Deck text → `DeckSource` → `Deck`: the parser's spine. Lexes, reads
//! statements one per line (continuing past an error to report up to 50),
//! expands `let`, `for` and `if` in place, and lowers. The language:
//! docs/src/reference/deck/README.md. Ported from
//! crates/ingest/src/deck/parse.rs (`parse_deck`, `parse_source`, `statements`,
//! `statement`, `for_`, `if_`, `block_end`, `for_header`).
//!
//! Contents:
//! - `pub fn parseDeck(arena: Allocator, gpa: Allocator, text: []const u8, layout: Grid, strings: *StrTable, diag: *Diag) Error!Deck`
//! - `pub fn parseSource(arena: Allocator, gpa: Allocator, text: []const u8, layout: Grid, diag: *Diag) Error!DeckSource`

const std = @import("std");
const Allocator = std.mem.Allocator;
const geom = @import("geom");
const Grid = geom.Grid;
const StrTable = geom.StrTable;
const diagnostic = @import("diagnostic.zig");
const Error = diagnostic.Error;
const Diag = diagnostic.Diag;
const Diagnostic = diagnostic.Diagnostic;
const lex = @import("lex.zig");
const Token = lex.Token;
const parser = @import("parser.zig");
const Parser = parser.Parser;
const PErr = parser.PErr;
const Span = parser.Span;
const Val = parser.Val;
const DeckSource = @import("source.zig").DeckSource;
const Deck = @import("tables.zig").Deck;
const lower = @import("lower.zig").lower;
const statements_mod = @import("parse_statements.zig");
const rules = @import("parse_rules.zig");
const lvs = @import("parse_lvs.zig");
const pex = @import("parse_pex.zig");

const Header = struct { pattern: []const parser.Ident, items: []const Val, open: Token };

/// Parses deck text and lowers it, interning every name into `strings`
/// (which allocates with `gpa`); the deck lives in `arena`. `layout` is the
/// layout's grid: every length must be a multiple of the deck's own `grid`
/// and convert to `layout` exactly. The same text and table state give the
/// same ids. `Invalid` with every syntax, name, unit and grid error, then
/// `Malformed` for the first contradiction; on error `strings` may have
/// gained names.
pub fn parseDeck(arena: Allocator, gpa: Allocator, text: []const u8, layout: Grid, strings: *StrTable, diag: *Diag) Error!Deck {
    var grid_nm: ?f64 = null;
    const doc = try parseWith(arena, gpa, text, layout, diag, &grid_nm);
    var deck = try lower(arena, gpa, &doc, strings, diag);
    deck.grid_nm = grid_nm;
    return deck;
}

/// Parses deck text to its `DeckSource` in `arena`, every value on
/// `layout`'s grid and every name still a name; `gpa` backs the parse's
/// scratch, freed before return. `Invalid`, as `parseDeck` gives it.
pub fn parseSource(arena: Allocator, gpa: Allocator, text: []const u8, layout: Grid, diag: *Diag) Error!DeckSource {
    var grid_nm: ?f64 = null;
    return parseWith(arena, gpa, text, layout, diag, &grid_nm);
}

// ---- private ----

/// `parseSource`, and the deck's `grid` statement in nm into `grid_nm`: a
/// `DeckSource` holds lengths on the layout grid alone, so the deck's own
/// grid reaches only the lowered `Deck`.
fn parseWith(arena: Allocator, gpa: Allocator, text: []const u8, layout: Grid, diag: *Diag, grid_nm: *?f64) Error!DeckSource {
    var scratch_state: std.heap.ArenaAllocator = .init(gpa);
    defer scratch_state.deinit();
    const scratch = scratch_state.allocator();
    const src = try arena.dupe(u8, text);
    var lex_errors: std.ArrayList(Diagnostic) = .empty;
    const toks = try lex.lex(scratch, src, &lex_errors);
    // The diagnostics outlive `scratch`: the parser's list is the arena's.
    var errors: std.ArrayList(Diagnostic) = .empty;
    try errors.appendSlice(arena, lex_errors.items);
    var p = try Parser.init(arena, scratch, src, toks, layout, errors);
    try statements(&p, toks.len - 1);
    try statements_mod.checkIgnored(&p);
    if (p.errors.items.len > 0) {
        const found = p.errors.items[0..@min(p.errors.items.len, parser.max_errors)];
        for (found) |*d| diagnostic.locate(d, src);
        diag.diagnostics = found;
        return error.Invalid;
    }
    grid_nm.* = if (p.deck_grid) |g| g.toF64() else null;
    return p.out;
}

/// Statements until token index `end`.
fn statements(p: *Parser, end: usize) Allocator.Error!void {
    while (p.pos < end and p.errors.items.len < parser.max_errors) {
        if (p.peek().tok == .newline) {
            _ = p.bump();
            continue;
        }
        p.context = "";
        const done = statement(p);
        p.context = "";
        const t = p.peek();
        if (done) |_| {
            if (t.tok == .newline or t.tok == .eof or p.pos == end) continue;
            const err = p.failTok(t, "expected end of line, found {s}", .{try p.found(t)});
            if (err == error.OutOfMemory) return error.OutOfMemory;
            p.recover();
        } else |err| {
            if (err == error.OutOfMemory) return error.OutOfMemory;
            p.recover();
        }
    }
}

fn statement(p: *Parser) PErr!void {
    const word = try p.ident("a statement");
    const w = word.name;
    const span = word.span;
    if (eql(w, "grid")) return statements_mod.grid(p, span);
    if (eql(w, "let")) return statements_mod.let_(p);
    if (eql(w, "layer")) return statements_mod.layer(p);
    if (eql(w, "rule")) return rules.rule(p);
    if (eql(w, "for")) return forLoop(p);
    if (eql(w, "if")) return ifBlock(p);
    if (eql(w, "connect")) return statements_mod.connect(p);
    if (eql(w, "device")) return statements_mod.device(p);
    if (eql(w, "matching")) return statements_mod.matching(p);
    if (eql(w, "pex")) return pex.pex(p);
    if (eql(w, "pex_fill")) return pex.pexFill(p);
    if (eql(w, "pex_device")) return pex.pexDevice(p);
    if (eql(w, "pex_tsv")) return pex.pexTsv(p);
    if (eql(w, "pex_substrate")) return pex.pexSubstrate(p, span);
    if (eql(w, "temperature")) return pex.temperature(p, span);
    if (eql(w, "extraction")) return pex.extraction(p, span);
    if (eql(w, "corner")) return pex.corner(p);
    if (eql(w, "stage")) return rules.stage(p, span);
    if (eql(w, "waive")) return statements_mod.waive(p);
    if (eql(w, "boundary")) return statements_mod.boundary(p, span);
    if (eql(w, "netlist_scale")) return statements_mod.netlistScale(p, span);
    if (eql(w, "ignore")) return statements_mod.ignore(p);
    if (eql(w, "lvs")) return lvs.lvs(p);
    if (eql(w, "fill")) return statements_mod.fill(p);
    if (eql(w, "widen")) return statements_mod.widen(p);
    if (eql(w, "report")) return statements_mod.report(p);
    return p.fail(span, "unknown statement `{s}`; expected grid, let, layer, ignore, rule, for, if, connect, device, matching, pex, pex_fill, pex_device, pex_tsv, pex_substrate, temperature, lvs, extraction, corner, stage, waive, boundary, netlist_scale, fill, widen or report", .{w});
}

fn eql(a: []const u8, b: []const u8) bool {
    return std.mem.eql(u8, a, b);
}

/// `for x in [..] { .. }` or `for (a, b) in [(..), ..] { .. }`: the body
/// read once per element, its bindings undone after each.
fn forLoop(p: *Parser) PErr!void {
    const header = forHeader(p) catch |err| {
        if (err == error.OutOfMemory) return err;
        // Skip the body: its names are unbound and would only add noise.
        while (!p.lineEnd() and !p.is("{")) _ = p.bump();
        if (p.is("{")) {
            const open = p.bump();
            _ = blockEnd(p, open) catch |e| if (e == error.OutOfMemory) return e;
        }
        return err;
    };
    const body = p.pos;
    const end = try blockEnd(p, header.open);
    for (header.items) |item| {
        const mark = p.env.items.len;
        const bound = bindItem(p, header.pattern, item);
        if (bound) |_| {
            p.pos = body;
            try statements(p, end - 1);
        } else |err| if (err == error.OutOfMemory) return err;
        p.env.shrinkRetainingCapacity(mark);
    }
    p.pos = end;
}

fn bindItem(p: *Parser, pattern: []const parser.Ident, item: Val) PErr!void {
    if (pattern.len == 1) return statements_mod.bind(p, pattern[0].name, pattern[0].span, item);
    if (item == .tuple and item.tuple.items.len == pattern.len) {
        for (pattern, item.tuple.items) |name, part| try statements_mod.bind(p, name.name, name.span, part);
        return;
    }
    return p.fail(item.span(), "expected a tuple of {d}, got {s}", .{ pattern.len, try item.shown(p.scratch) });
}

/// `if name { .. }` or `if not name { .. }`: the block's statements are read
/// when the name is bound to `true` (`false` with `not`), skipped unread
/// otherwise.
fn ifBlock(p: *Parser) PErr!void {
    const negate = p.eat("not");
    const name = try p.ident("a switch name");
    const v = p.bound(name.name) orelse return p.fail(name.span, "`{s}` is not bound; write `let {s} = true` (or false) before the `if`", .{ name.name, name.name });
    const on = if (v == .word and eql(v.word.name, "true")) true else if (v == .word and eql(v.word.name, "false")) false else return p.fail(name.span, "`if` takes a name bound to true or false; `{s}` is {s}", .{ name.name, try v.shown(p.scratch) });
    const open = try p.expect("{");
    const body = p.pos;
    const end = try blockEnd(p, open);
    if (on != negate) {
        p.pos = body;
        try statements(p, end - 1);
    }
    p.pos = end;
}

/// The token index after the `}` matching `open`; leaves `pos` there.
fn blockEnd(p: *Parser, open: Token) PErr!usize {
    var depth: usize = 1;
    var end = p.pos;
    while (depth > 0) : (end += 1) {
        const t = p.toks[end];
        if (t.tok == .eof) return p.failTok(open, "unclosed `{{`", .{});
        if (t.tok == .punct and eql(p.text(t), "{")) depth += 1;
        if (t.tok == .punct and eql(p.text(t), "}")) depth -= 1;
    }
    p.pos = end;
    return end;
}

fn forHeader(p: *Parser) PErr!Header {
    var pattern: std.ArrayList(parser.Ident) = .empty;
    if (p.eat("(")) {
        while (true) {
            try pattern.append(p.scratch, try p.ident("a loop variable"));
            if (!p.eat(",")) break;
        }
        _ = try p.expect(")");
    } else try pattern.append(p.scratch, try p.ident("a loop variable"));
    _ = try p.expect("in");
    const list = try p.value();
    if (list != .list) return p.fail(list.span(), "`for` needs a list, got {s}", .{try list.shown(p.scratch)});
    const open = try p.expect("{");
    return .{ .pattern = pattern.items, .items = list.list.items, .open = open };
}
