//! Structural Verilog text → modules as written: ports as bits, declared
//! ranges, `assign` bit pairs, instances with their connections as bits.
//! The subset is IEEE 1364-2005's netlist subset (crates/ingest/src/netlist/
//! verilog.rs's module docs); comments and attributes are dropped, escaped
//! identifiers read without their `\`, and every construct outside the
//! subset is refused with its line. Ported from crates/ingest/src/netlist/
//! verilog.rs (`tokens`, `skip_block`, `bit_names`, `Parser`, `out_of_subset`).
//!
//! Contents:
//! - `pub const Range`, `pub const Conn`, `pub const Inst`, `pub const Module`, `Module.portBits(m: *const Module, arena: Allocator) Allocator.Error![]const []const u8`
//! - `pub fn parse(arena: Allocator, source: []const u8, modules: *std.ArrayList(Module), diag: *Diagnostic) Error!void`
//! - `pub fn bitNames(arena: Allocator, name: []const u8, range: Range) Allocator.Error![]const []const u8`

const std = @import("std");
const Allocator = std.mem.Allocator;
const netlist = @import("netlist.zig");
const Error = netlist.Error;
const Diagnostic = netlist.Diagnostic;
const Tok = @import("verilog_lex.zig").Tok;
const tokens = @import("verilog_lex.zig").tokens;

/// A declared net's `[msb:lsb]`, null for a scalar.
pub const Range = ?[2]u32;

/// One connection of an instance: by port name (bits empty for `.port()`)
/// or by position.
pub const Conn = struct { port: ?[]const u8, bits: []const []const u8, line: u32 };

/// One instance as written.
pub const Inst = struct { cell: []const u8, name: []const u8, conns: []const Conn, line: u32 };

/// One module as written.
pub const Module = struct {
    name: []const u8,
    line: u32,
    /// Port names in the port list's order.
    ports: std.ArrayList([]const u8) = .empty,
    /// Each declared name's range.
    declared: std.StringHashMapUnmanaged(Range) = .empty,
    assigns: std.ArrayList([2][]const u8) = .empty,
    insts: std.ArrayList(Inst) = .empty,

    /// The module's port bits, in port order.
    pub fn portBits(m: *const Module, arena: Allocator) Allocator.Error![]const []const u8 {
        var out: std.ArrayList([]const u8) = .empty;
        for (m.ports.items) |port| try out.appendSlice(arena, try bitNames(arena, port, m.declared.get(port) orelse null));
        return out.items;
    }
};

const keywords = [_][]const u8{ "module", "endmodule", "input", "output", "inout", "wire", "supply0", "supply1", "assign" };

/// A cursor over the tokens.
const Parser = struct {
    arena: Allocator,
    toks: []const Tok,
    at: usize = 0,
    diag: *Diagnostic,

    fn line(p: *const Parser) u32 {
        if (p.at < p.toks.len) return p.toks[p.at].line;
        return if (p.toks.len > 0) p.toks[p.toks.len - 1].line else 1;
    }

    /// The token at the cursor as written.
    fn text(p: *const Parser) []const u8 {
        return if (p.at < p.toks.len) p.toks[p.at].text else "the end of the file";
    }

    fn fail(p: *Parser, err: Error, comptime fmt: []const u8, args: anytype) Error {
        p.diag.set(p.line(), fmt, args);
        return err;
    }

    fn unexpected(p: *Parser) Error {
        return p.fail(error.Unexpected, "{s}", .{p.text()});
    }

    fn isPunct(p: *const Parser, c: u8) bool {
        return p.at < p.toks.len and p.toks[p.at].kind == .punct and p.toks[p.at].text[0] == c;
    }

    fn eat(p: *Parser, c: u8) bool {
        if (!p.isPunct(c)) return false;
        p.at += 1;
        return true;
    }

    fn expect(p: *Parser, c: u8) Error!void {
        if (!p.eat(c)) return p.unexpected();
    }

    /// The identifier at the cursor, or null.
    fn word(p: *const Parser) ?[]const u8 {
        if (p.at < p.toks.len and p.toks[p.at].kind == .ident) return p.toks[p.at].text;
        return null;
    }

    fn isWord(p: *const Parser, w: []const u8) bool {
        const got = p.word() orelse return false;
        return std.mem.eql(u8, got, w);
    }

    fn ident(p: *Parser) Error![]const u8 {
        const w = p.word() orelse return p.unexpected();
        if (isKeyword(w)) return p.unexpected();
        p.at += 1;
        return w;
    }

    fn number(p: *Parser) Error!u32 {
        if (p.at < p.toks.len) switch (p.toks[p.at].kind) {
            .number => {
                p.at += 1;
                return p.toks[p.at - 1].number;
            },
            .constant => return p.fail(error.Unsupported, "the constant {s}", .{p.text()}),
            .ident, .punct => {},
        };
        return p.unexpected();
    }

    /// `[msb:lsb]`, when one follows.
    fn range(p: *Parser) Error!Range {
        if (!p.eat('[')) return null;
        const from = try p.number();
        try p.expect(':');
        const to = try p.number();
        try p.expect(']');
        return .{ from, to };
    }

    /// A keyword outside the subset is `Unsupported`; anything else unexpected.
    fn unsupportedOrUnexpected(p: *Parser) Error {
        if (p.word()) |w| if (outOfSubset(w)) return p.fail(error.Unsupported, "{s}", .{w});
        return p.unexpected();
    }

    fn module(p: *Parser) Error!Module {
        const at_line = p.line();
        p.at += 1;
        const name = try p.ident();
        if (p.isPunct('#')) return p.fail(error.Unsupported, "the parameters of module {s}", .{name});
        var m: Module = .{ .name = name, .line = at_line };
        if (p.eat('(') and !p.eat(')')) while (true) {
            if (p.word() != null and isDirection(p.word().?)) {
                // In place: a direction, a range, then names until the next direction.
                p.at += 1;
                if (p.isWord("wire")) p.at += 1;
                const r = try p.range();
                try p.declarePort(&m, r);
                while (p.isPunct(',') and !(p.at + 1 < p.toks.len and p.toks[p.at + 1].kind == .ident and isDirection(p.toks[p.at + 1].text))) {
                    p.at += 1;
                    try p.declarePort(&m, r);
                }
            } else if (p.isPunct('.')) {
                return p.fail(error.Unsupported, "a port expression", .{});
            } else try m.ports.append(p.arena, try p.ident());
            if (p.eat(')')) break;
            try p.expect(',');
        };
        try p.expect(';');
        while (true) {
            const w = p.word() orelse return p.unsupportedOrUnexpected();
            if (std.mem.eql(u8, w, "endmodule")) {
                p.at += 1;
                return m;
            } else if (isDirection(w) or std.mem.eql(u8, w, "wire") or std.mem.eql(u8, w, "supply0") or std.mem.eql(u8, w, "supply1")) {
                try p.declaration(&m);
            } else if (std.mem.eql(u8, w, "assign")) {
                p.at += 1;
                while (true) {
                    const lhs = try p.expression(&m);
                    try p.expect('=');
                    try p.pair(&m, lhs, try p.expression(&m));
                    if (!p.eat(',')) break;
                }
                try p.expect(';');
            } else if (!isKeyword(w) and !outOfSubset(w)) {
                try p.instances(&m);
            } else return p.unsupportedOrUnexpected();
        }
    }

    fn declarePort(p: *Parser, m: *Module, r: Range) Error!void {
        const port = try p.ident();
        try m.declared.put(p.arena, port, r);
        try m.ports.append(p.arena, port);
    }

    /// `input|output|inout|wire|supply0|supply1 [range] name [= expr], ...;`
    fn declaration(p: *Parser, m: *Module) Error!void {
        const wire = p.isWord("wire");
        p.at += 1;
        if (!wire and p.isWord("wire")) p.at += 1;
        const r = try p.range();
        while (true) {
            const name = try p.ident();
            try m.declared.put(p.arena, name, r);
            if (wire and p.eat('=')) {
                const rhs = try p.expression(m);
                try p.pair(m, try bitNames(p.arena, name, r), rhs);
            }
            if (!p.eat(',')) break;
        }
        try p.expect(';');
    }

    /// Joins two equally wide expressions bit for bit.
    fn pair(p: *Parser, m: *Module, lhs: []const []const u8, rhs: []const []const u8) Error!void {
        if (lhs.len != rhs.len) return p.fail(error.Unexpected, "an assignment of {d} bits to {d}", .{ rhs.len, lhs.len });
        for (lhs, rhs) |a, b| try m.assigns.append(p.arena, .{ a, b });
    }

    /// A connection expression as its bits, most significant first.
    fn expression(p: *Parser, m: *const Module) Error![]const []const u8 {
        if (p.eat('{')) {
            var bits: std.ArrayList([]const u8) = .empty;
            while (true) {
                try bits.appendSlice(p.arena, try p.expression(m));
                if (p.eat('}')) return bits.items;
                try p.expect(',');
            }
        }
        if (p.at < p.toks.len and (p.toks[p.at].kind == .constant or p.toks[p.at].kind == .number)) {
            return p.fail(error.Unsupported, "the constant {s} in a connection", .{p.text()});
        }
        const at_line = p.line();
        const name = try p.ident();
        const declared = m.declared.get(name) orelse null;
        if (!p.eat('[')) return bitNames(p.arena, name, declared);
        const r = declared orelse {
            p.diag.set(at_line, "a bit select of the scalar {s}", .{name});
            return error.Unexpected;
        };
        const from = try p.number();
        const to = if (p.eat(':')) try p.number() else from;
        try p.expect(']');
        const lo = @min(r[0], r[1]);
        const hi = @max(r[0], r[1]);
        if (from < lo or from > hi or to < lo or to > hi) {
            p.diag.set(at_line, "{s}[{d}:{d}] outside {s}[{d}:{d}]", .{ name, from, to, name, r[0], r[1] });
            return error.Unexpected;
        }
        return bitNames(p.arena, name, .{ from, to });
    }

    /// `cell name (conns), name (conns);`
    fn instances(p: *Parser, m: *Module) Error!void {
        const cell = try p.ident();
        if (p.isPunct('#')) return p.fail(error.Unsupported, "the parameters of an instance of {s}", .{cell});
        while (true) {
            const at_line = p.line();
            const name = try p.ident();
            if (p.isPunct('[')) return p.fail(error.Unsupported, "the instance array {s}", .{name});
            try p.expect('(');
            var conns: std.ArrayList(Conn) = .empty;
            if (!p.eat(')')) while (true) {
                const conn_line = p.line();
                if (p.eat('.')) {
                    const port = try p.ident();
                    try p.expect('(');
                    const bits: []const []const u8 = if (p.eat(')')) &.{} else blk: {
                        const b = try p.expression(m);
                        try p.expect(')');
                        break :blk b;
                    };
                    try conns.append(p.arena, .{ .port = port, .bits = bits, .line = conn_line });
                } else try conns.append(p.arena, .{ .port = null, .bits = try p.expression(m), .line = conn_line });
                if (p.eat(')')) break;
                try p.expect(',');
            };
            try m.insts.append(p.arena, .{ .cell = cell, .name = name, .conns = conns.items, .line = at_line });
            if (!p.eat(',')) break;
        }
        try p.expect(';');
    }
};

/// Appends every module of `source` to `modules`, all in `arena`.
pub fn parse(arena: Allocator, source: []const u8, modules: *std.ArrayList(Module), diag: *Diagnostic) Error!void {
    var p: Parser = .{ .arena = arena, .toks = try tokens(arena, source, diag), .diag = diag };
    while (p.at < p.toks.len) {
        if (!p.isWord("module")) return p.unsupportedOrUnexpected();
        try modules.append(arena, try p.module());
    }
}

/// The bits of a net of `range`, most significant (first declared) first.
pub fn bitNames(arena: Allocator, name: []const u8, range: Range) Allocator.Error![]const []const u8 {
    const r = range orelse return arena.dupe([]const u8, &.{name});
    const n = @max(r[0], r[1]) - @min(r[0], r[1]) + 1;
    const out = try arena.alloc([]const u8, n);
    for (out, 0..) |*o, k| {
        const bit = if (r[0] >= r[1]) r[0] - @as(u32, @intCast(k)) else r[0] + @as(u32, @intCast(k));
        o.* = try std.fmt.allocPrint(arena, "{s}[{d}]", .{ name, bit });
    }
    return out;
}

// ---- private ----

/// Whether `word` is a Verilog keyword outside the subset.
fn outOfSubset(word: []const u8) bool {
    const words = [_][]const u8{ "always", "initial", "reg", "integer", "function", "task", "generate", "parameter", "localparam", "defparam", "specify", "primitive", "tri", "wand", "wor", "logic" };
    for (words) |w| if (std.mem.eql(u8, w, word)) return true;
    return false;
}

fn isKeyword(word: []const u8) bool {
    for (keywords) |w| if (std.mem.eql(u8, w, word)) return true;
    return false;
}

fn isDirection(word: []const u8) bool {
    return std.mem.eql(u8, word, "input") or std.mem.eql(u8, word, "output") or std.mem.eql(u8, word, "inout");
}

test "a bus lists its bits from the first index declared" {
    // Oracle: IEEE 1364-2005 §6.1 (a vector's bits from its msb to its lsb,
    // either order of indices).
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const want = [_][]const []const u8{ &.{ "d[2]", "d[1]", "d[0]" }, &.{ "d[0]", "d[1]" }, &.{"a"} };
    const got = [_][]const []const u8{ try bitNames(a, "d", .{ 2, 0 }), try bitNames(a, "d", .{ 0, 1 }), try bitNames(a, "a", null) };
    for (want, got) |w, g| {
        try std.testing.expectEqual(w.len, g.len);
        for (w, g) |x, y| try std.testing.expectEqualStrings(x, y);
    }
}
