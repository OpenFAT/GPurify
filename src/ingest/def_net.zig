//! DEF nets and the item grammar every DEF section shares: `count ; - item
//! ; … END name` sections, `+ KEY …` options, shapes, orientations, and a
//! net's connections and routing (paths, vias, `RECT` and `VIRTUAL` points,
//! extensions) with each wire's width resolved from its rule (LEF/DEF 5.8
//! pp. 251, 265-269, 321). In: the DEF token stream. Out: `Net` rows.
//! Ported from crates/ingest/src/lefdef/def.rs (`section`, `options`,
//! `net`, `routing`, `other_layer`).
//!
//! Contents:
//! - `pub fn sectionStart(lx: *Lexer) Error!void`, `pub fn sectionItem(lx: *Lexer, name: []const u8) Error!bool`
//! - `pub fn nextOption(lx: *Lexer) Error!?[]const u8`, `pub fn skipOption(lx: *Lexer) Error!void`,
//!   `pub fn plusOptions(lx: *Lexer) Error!void`
//! - `pub fn orient(lx: *Lexer) Error!Orient`
//! - `pub fn shape(arena: Allocator, lx: *Lexer, layer: []const u8, rect: bool) Error!Shape`
//! - `pub fn knownVia(lx: *const Lexer, name: []const u8, vias: []const NamedVia, lef: *const Lef) Error![]const Shape`
//! - `pub fn net(arena: Allocator, lx: *Lexer, special: bool, vias: []const NamedVia, ndrs: []const Ndr, lef: *const Lef) Error!Net`

const std = @import("std");
const Allocator = std.mem.Allocator;
const lex = @import("lefdef_lex.zig");
const Lexer = lex.Lexer;
const Error = lex.Error;
const Pt = lex.Pt;
const lefdef = @import("lefdef.zig");
const Shape = lefdef.Shape;
const Orient = lefdef.Orient;
const NamedVia = lefdef.NamedVia;
const lef_file = @import("lef.zig");
const Lef = lef_file.Lef;
const Ndr = lef_file.Ndr;
const def_file = @import("def.zig");
const Net = def_file.Net;
const Wire = def_file.Wire;
const ViaAt = def_file.ViaAt;

/// Which rule a regular wire is drawn at: the net's `NONDEFAULTRULE` else
/// the LEF width (`net`), the LEF width (`TAPER`), or `TAPERRULE name`.
const Taper = union(enum) { net, default, rule: []const u8 };

/// A wire before its rule is known: special wires carry their width.
const RawWire = struct {
    layer: []const u8,
    width: ?i64,
    taper: Taper,
    from: Pt,
    to: Pt,
    from_ext: ?i64,
    to_ext: ?i64,
};

/// A path's last point and the extension it carries.
const Last = struct { at: Pt, ext: ?i64 };

/// A section's `count ;`.
pub fn sectionStart(lx: *Lexer) Error!void {
    _ = try lx.int();
    try lx.expect(";");
}

/// Past the next item's `-`, true; past `END name`, false.
pub fn sectionItem(lx: *Lexer, name: []const u8) Error!bool {
    if (lx.eat("END")) {
        try lx.expect(name);
        return false;
    }
    try lx.expect("-");
    return true;
}

/// The next `+ KEY`'s key, or null past the item's `;`.
pub fn nextOption(lx: *Lexer) Error!?[]const u8 {
    const word = try lx.next();
    if (is(word, ";")) return null;
    if (!is(word, "+")) return lx.fail("expected + or ;, found {s}", .{word});
    return try lx.next();
}

/// Skips what an option's reader left, up to the next `+` or `;`.
pub fn skipOption(lx: *Lexer) Error!void {
    while (lx.peek()) |w| {
        if (is(w, "+") or is(w, ";")) return;
        _ = try lx.next();
    }
}

/// Skips `+ MASK n` and `+ OPC` before a shape.
pub fn plusOptions(lx: *Lexer) Error!void {
    while (lx.eat("+")) if (is(try lx.next(), "MASK")) {
        _ = try lx.next();
    };
}

pub fn orient(lx: *Lexer) Error!Orient {
    const word = try lx.next();
    return Orient.parse(word) orelse lx.fail("{s} is not an orientation", .{word});
}

/// A `RECT`'s two points on `layer` when `rect`, else a `POLYGON`'s.
pub fn shape(arena: Allocator, lx: *Lexer, layer: []const u8, rect: bool) Error!Shape {
    if (rect) {
        const a = try lx.point(null);
        return Shape.rect(arena, layer, a, try lx.point(a));
    }
    var ring: std.ArrayList(Pt) = .empty;
    while (peekIs(lx, "(")) try ring.append(arena, try lx.point(if (ring.items.len > 0) ring.items[ring.items.len - 1] else null));
    if (ring.items.len < 3) return lx.fail("a POLYGON has at least three points", .{});
    return .{ .layer = layer, .ring = ring.items };
}

/// The shapes of via `name`, from an earlier `VIAS` entry or the LEF.
pub fn knownVia(lx: *const Lexer, name: []const u8, vias: []const NamedVia, lef: *const Lef) Error![]const Shape {
    for (vias) |v| if (is(v.name, name)) return v.shapes;
    for (lef.vias.items) |v| if (is(v.name, name)) return v.shapes;
    return lx.fail("via {s} is defined in no earlier VIAS or LEF", .{name});
}

/// One `NETS` or `SPECIALNETS` item after its `-`.
pub fn net(arena: Allocator, lx: *Lexer, special: bool, vias: []const NamedVia, ndrs: []const Ndr, lef: *const Lef) Error!Net {
    const name = try lx.next();
    var connections: std.ArrayList([2][]const u8) = .empty;
    while (lx.eat("(")) {
        const comp = try lx.next();
        const pin = try lx.next();
        while (!is(try lx.next(), ")")) {}
        try connections.append(arena, .{ comp, pin });
    }
    var raw: std.ArrayList(RawWire) = .empty;
    var placed_vias: std.ArrayList(ViaAt) = .empty;
    var shapes: std.ArrayList(Shape) = .empty;
    var ndr: ?[]const u8 = null;
    const line = lx.line();
    while (try nextOption(lx)) |key| {
        if (is(key, "ROUTED") or is(key, "FIXED") or is(key, "COVER") or is(key, "NOSHIELD")) {
            try routing(arena, lx, special, vias, lef, &raw, &placed_vias, &shapes);
        } else if (is(key, "SHIELD")) {
            return lx.fail("SHIELD wiring is not read", .{});
        } else if (is(key, "SUBNET")) {
            return lx.fail("a SUBNET is not read", .{});
        } else if (is(key, "NONDEFAULTRULE")) {
            ndr = try lx.next();
        } else if (special and (is(key, "RECT") or is(key, "POLYGON"))) {
            const layer = try lx.next();
            try plusOptions(lx);
            try shapes.append(arena, try shape(arena, lx, layer, is(key, "RECT")));
        } else if (special and is(key, "VIA")) {
            const via = try lx.next();
            _ = try knownVia(lx, via, vias, lef);
            try plusOptions(lx);
            const turn: Orient = if (peekIs(lx, "(")) .N else try orient(lx);
            while (peekIs(lx, "(")) try placed_vias.append(arena, .one(via, try lx.point(null), turn));
        }
        try skipOption(lx);
    }
    const wires = try arena.alloc(Wire, raw.items.len);
    for (raw.items, wires) |w, *out| {
        const rule: ?[]const u8 = switch (w.taper) {
            .rule => |r| r,
            .net => ndr,
            .default => null,
        };
        const width = w.width orelse (if (rule) |r| ruleWidth(ndrs, lef, r, w.layer) else lefWidth(lef, w.layer)) orelse {
            lx.diag.set("DEF", line, "net {s} routes on {s}, which has no LEF WIDTH or rule width", .{ name, w.layer });
            return error.Invalid;
        };
        // The default extension: half the width for a regular wire, none for
        // a special one (5.8 pp. 268, 321).
        const ext = if (special) 0 else @divTrunc(width, 2);
        out.* = .{ .layer = w.layer, .width = width, .from = w.from, .to = w.to, .from_ext = w.from_ext orelse ext, .to_ext = w.to_ext orelse ext };
    }
    return .{ .name = name, .special = special, .connections = connections.items, .wires = wires, .vias = placed_vias.items, .shapes = shapes.items };
}

// ---- private ----

fn is(a: []const u8, b: []const u8) bool {
    return std.mem.eql(u8, a, b);
}

fn peekIs(lx: *const Lexer, word: []const u8) bool {
    return if (lx.peek()) |p| is(p, word) else false;
}

/// Rule `rule`'s width on `layer`, the DEF's rules before the LEF's.
fn ruleWidth(ndrs: []const Ndr, lef: *const Lef, rule: []const u8, layer: []const u8) ?i64 {
    const found = for (ndrs) |n| {
        if (is(n.name, rule)) break n;
    } else for (lef.ndrs.items) |n| {
        if (is(n.name, rule)) break n;
    } else return null;
    for (found.widths) |w| if (is(w.layer, layer)) return w.width;
    return null;
}

fn lefWidth(lef: *const Lef, layer: []const u8) ?i64 {
    for (lef.layers.items) |l| if (is(l.name, layer)) return l.width;
    return null;
}

/// A routing statement after `ROUTED`: paths separated by `NEW`, through
/// the next `+` or `;`.
fn routing(arena: Allocator, lx: *Lexer, special: bool, vias: []const NamedVia, lef: *const Lef, raw: *std.ArrayList(RawWire), out_vias: *std.ArrayList(ViaAt), out_shapes: *std.ArrayList(Shape)) Error!void {
    while (true) {
        var layer = try lx.next();
        const width: ?i64 = if (special) try lx.int() else null;
        var taper: Taper = .net;
        while (lx.peek()) |w| {
            if (is(w, "TAPER")) {
                _ = try lx.next();
                taper = .default;
            } else if (is(w, "TAPERRULE")) {
                _ = try lx.next();
                taper = .{ .rule = try lx.next() };
            } else if (is(w, "STYLE")) {
                return lx.fail("a wire STYLE is not read", .{});
            } else if (special and is(w, "+")) {
                _ = try lx.next();
                const option = try lx.next();
                if (is(option, "SHAPE") or is(option, "MASK")) {
                    _ = try lx.next();
                } else if (is(option, "STYLE")) {
                    return lx.fail("a wire STYLE is not read", .{});
                } else return lx.fail("unexpected + {s} in wiring", .{option});
            } else break;
        }
        var last: ?Last = null;
        while (true) {
            const word = lx.peek() orelse return;
            if (is(word, "(")) {
                _ = try lx.next();
                const x = try lx.coord(if (last) |l| l.at[0] else null);
                const y = try lx.coord(if (last) |l| l.at[1] else null);
                var ext: ?i64 = null;
                if (!peekIs(lx, ")")) {
                    ext = try lx.int();
                    if (ext.? < 0) return lx.fail("a wire extension is at least 0", .{});
                }
                try lx.expect(")");
                if (last) |l| {
                    if (l.at[0] == x and l.at[1] == y) {
                        // The same point again: an extension at a via.
                        last = .{ .at = .{ x, y }, .ext = ext orelse l.ext };
                        continue;
                    }
                    if (l.at[0] != x and l.at[1] != y) return lx.fail("a wire segment that is neither horizontal nor vertical is not read", .{});
                    try raw.append(arena, .{ .layer = layer, .width = width, .taper = taper, .from = l.at, .to = .{ x, y }, .from_ext = l.ext, .to_ext = ext });
                }
                last = .{ .at = .{ x, y }, .ext = ext };
            } else if (is(word, "MASK")) {
                _ = try lx.next();
                _ = try lx.next();
            } else if (is(word, "RECT")) {
                _ = try lx.next();
                const p = (last orelse return lx.fail("a wiring RECT before any point", .{})).at;
                try lx.expect("(");
                const d = [4]i64{ try lx.int(), try lx.int(), try lx.int(), try lx.int() };
                try lx.expect(")");
                try out_shapes.append(arena, try Shape.rect(arena, layer, .{ p[0] + d[0], p[1] + d[1] }, .{ p[0] + d[2], p[1] + d[3] }));
            } else if (is(word, "VIRTUAL")) {
                _ = try lx.next();
                last = .{ .at = try lx.point(if (last) |l| l.at else null), .ext = null };
            } else if (is(word, "NEW")) {
                _ = try lx.next();
                break;
            } else if (is(word, "+") or is(word, ";")) {
                return;
            } else {
                const name = try lx.next();
                const shapes = try knownVia(lx, name, vias, lef);
                const here = last orelse return lx.fail("via {s} before any point", .{name});
                const turn: Orient = if (lx.peek()) |p| Orient.parse(p) orelse .N else .N;
                if (lx.peek() != null and Orient.parse(lx.peek().?) != null) _ = try lx.next();
                var array: [4]i64 = .{ 1, 1, 0, 0 };
                if (lx.eat("DO")) {
                    array[0] = try lx.int();
                    try lx.expect("BY");
                    array[1] = try lx.int();
                    try lx.expect("STEP");
                    array[2] = try lx.int();
                    array[3] = try lx.int();
                    if (array[0] < 1 or array[1] < 1 or array[0] * array[1] > 1 << 20) return lx.fail("a via array of 1 to 2^20 vias", .{});
                }
                layer = try otherLayer(arena, lx, shapes, layer, name, lef);
                try out_vias.append(arena, .{ .name = name, .at = here.at, .orient = turn, .array = array });
                // The point keeps its extension: a wire leaving it on the
                // via's other layer starts with it, as OpenDB reads it.
                last = here;
            }
        }
    }
}

/// The layer a via takes a path to from `layer`: of the via's two non-cut
/// layers, the one it is not on.
fn otherLayer(arena: Allocator, lx: *const Lexer, shapes: []const Shape, layer: []const u8, via: []const u8, lef: *const Lef) Error![]const u8 {
    var metals: std.ArrayList([]const u8) = .empty;
    for (shapes) |s| {
        const cut = for (lef.layers.items) |l| {
            if (is(l.name, s.layer) and l.kind == .cut) break true;
        } else false;
        if (cut) continue;
        const seen = for (metals.items) |m| {
            if (is(m, s.layer)) break true;
        } else false;
        if (!seen) try metals.append(arena, s.layer);
    }
    if (metals.items.len == 2) {
        if (is(metals.items[0], layer)) return metals.items[1];
        if (is(metals.items[1], layer)) return metals.items[0];
    }
    return lx.fail("via {s} does not join {s} to one other layer (its LEF cut layer must be TYPE CUT)", .{ via, layer });
}
