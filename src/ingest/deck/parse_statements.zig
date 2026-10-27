//! The deck's one-line statements other than rules, `lvs` and the parasitic
//! stack: `grid`, `let`, `layer`, `ignore`, `connect`, `device`, `matching`,
//! `fill`, `widen`, `report`, `waive`, `boundary`, `netlist_scale` → rows of
//! the `DeckSource`. Grammar: docs/src/reference/deck/README.md (Statements).
//! Ported from crates/ingest/src/deck/parse.rs (the statement methods of those
//! names, `bind`, `unbound`, `check_ignored`, `gds_pair`, `net_name`);
//! `matching` is new in the rewrite (UW-ASIC/GPurify#84).
//!
//! Contents:
//! - `pub fn grid(p: *Parser, span: Span) PErr!void`, `pub fn let_(p: *Parser) PErr!void`
//! - `pub fn bind(p: *Parser, name: []const u8, span: Span, v: Val) PErr!void`
//! - `pub fn layer(p: *Parser) PErr!void`, `pub fn ignore(p: *Parser) PErr!void`,
//!   `pub fn checkIgnored(p: *Parser) Allocator.Error!void`
//! - `pub fn connect(p: *Parser) PErr!void`, `pub fn device(p: *Parser) PErr!void`, `pub fn matching(p: *Parser) PErr!void`
//! - `pub fn fill(p: *Parser) PErr!void`, `pub fn widen(p: *Parser) PErr!void`, `pub fn report(p: *Parser) PErr!void`
//! - `pub fn waive(p: *Parser) PErr!void`, `pub fn boundary(p: *Parser, span: Span) PErr!void`,
//!   `pub fn netlistScale(p: *Parser, span: Span) PErr!void`
//! - `pub const devices`
//! - each statement's local `Reader.read`, the `keyed`/`minMax` callback

const std = @import("std");
const geom = @import("geom");
const Dbu = geom.Dbu;
const parser = @import("parser.zig");
const Parser = parser.Parser;
const PErr = parser.PErr;
const Span = parser.Span;
const Val = parser.Val;
const tables = @import("tables.zig");
const DeviceKind = tables.DeviceKind;
const convert = @import("convert.zig");
const Dim = @import("kinds.zig").Dim;
const parse_layers = @import("parse_layers.zig");
const parse_rules = @import("parse_rules.zig");

/// The device kinds a `device` statement names, by word.
pub const devices = [_]struct { []const u8, DeviceKind }{
    .{ "mos", .mos },             .{ "bjt", .bjt },     .{ "resistor", .resistor },
    .{ "capacitor", .capacitor }, .{ "diode", .diode }, .{ "inductor", .inductor },
};

/// The `matching` keys, as `keyed` takes them.
const matching_names = blk: {
    var names: [tables.matching_keys.len][]const u8 = undefined;
    for (tables.matching_keys, &names) |k, *n| n.* = k.name;
    break :blk names;
};
const matching_list = "avt, abeta, ar, svt or ka";

pub fn grid(p: *Parser, span: Span) PErr!void {
    const v = try p.value();
    if (p.deck_grid != null) return p.fail(span, "the grid is already stated", .{});
    const nm = try convert.quantity(p, v, .length, "grid");
    if (nm.m <= 0) return p.fail(v.span(), "the grid must be positive", .{});
    p.deck_grid = nm;
}

pub fn let_(p: *Parser) PErr!void {
    const name = try p.ident("a name");
    _ = try p.expect("=");
    const v = try p.value();
    return bind(p, name.name, name.span, v);
}

/// Binds a name once; a name taken by a binding or a layer is an error.
pub fn bind(p: *Parser, name: []const u8, span: Span, v: Val) PErr!void {
    try unbound(p, name, span);
    try p.env.append(p.scratch, .{ .name = name, .value = v });
}

pub fn layer(p: *Parser) PErr!void {
    const name = try p.ident("a layer name");
    _ = try p.expect("=");
    try unbound(p, name.name, name.span);
    if (p.is("gds") and p.peekAt(1).tok == .punct and std.mem.eql(u8, p.text(p.peekAt(1)), "(")) {
        _ = p.bump();
        try p.out.layers.append(p.arena, .{ .name = name.name, .stream = try gdsPair(p) });
    } else {
        const expr = try parse_layers.layerExpr(p);
        if (parse_layers.edgesOf(p, expr)) try p.edge_layers.put(p.scratch, name.name, {});
        const fold = switch (expr) {
            .layer => return p.fail(name.span, "a derived layer needs an operator (and, or, not) or an operation (`.sized(..)`)", .{}),
            .op, .group, .call => |f| f,
        };
        var count: u32 = 0;
        const operands = try parse_layers.lowerOperands(p, name.name, fold.operands, &count);
        try p.out.derived.append(p.arena, .{ .name = name.name, .op = fold.op, .layers = operands });
    }
    try p.layers.put(p.scratch, name.name, {});
}

/// `ignore gds(L, D)`: geometry on this stream pair is dropped, not refused.
pub fn ignore(p: *Parser) PErr!void {
    const word = try p.ident("`gds`");
    if (!std.mem.eql(u8, word.name, "gds")) return p.fail(word.span, "expected `gds(layer, datatype)`, found `{s}`", .{word.name});
    const pair = try gdsPair(p);
    const at: Span = .{ .start = word.span.start, .end = p.toks[p.pos -| 1].end };
    for (p.ignored_at.items) |seen| if (seen.pair[0] == pair[0] and seen.pair[1] == pair[1]) {
        return p.fail(at, "gds({d}, {d}) is already ignored", .{ pair[0], pair[1] });
    };
    try p.ignored_at.append(p.scratch, .{ .pair = pair, .span = at });
    try p.out.ignored.append(p.arena, pair);
}

/// An ignored pair that is also a declared layer contradicts itself; run
/// once every statement is read, because a layer may be declared later.
pub fn checkIgnored(p: *Parser) std.mem.Allocator.Error!void {
    for (p.ignored_at.items) |ig| for (p.out.layers.items) |l| {
        if (l.stream[0] != ig.pair[0] or l.stream[1] != ig.pair[1]) continue;
        const err = p.fail(ig.span, "gds({d}, {d}) is ignored, but layer `{s}` is declared on it", .{ ig.pair[0], ig.pair[1], l.name });
        if (err == error.OutOfMemory) return error.OutOfMemory;
        break;
    };
}

pub fn connect(p: *Parser) PErr!void {
    const what = try p.ident("conductors, touch_within_layer, global, via or label");
    const c = &p.out.connectivity;
    if (eql(what.name, "conductors")) {
        try c.conductors.appendSlice(p.arena, try p.layerList());
    } else if (eql(what.name, "touch_within_layer")) {
        if (p.touch) return p.fail(what.span, "touch_within_layer is already stated", .{});
        p.touch = true;
        c.intra_layer_touch = true;
    } else if (eql(what.name, "global")) {
        try c.global.append(p.arena, try p.layerWord());
    } else if (eql(what.name, "via")) {
        const cut = try p.layerWord();
        const list_at = p.peek();
        const joined = try p.layerList();
        if (joined.len != 2) return p.failTok(list_at, "a via joins 2 layers, got {d}", .{joined.len});
        try c.vias.append(p.arena, .{ .layer = cut, .connects = .{ joined[0], joined[1] } });
    } else if (eql(what.name, "label")) {
        const text = try p.layerWord();
        _ = try p.expect("names");
        try c.labels.append(p.arena, .{ .layer = text, .names = try p.layerWord() });
    } else return p.fail(what.span, "unknown connect `{s}`; expected conductors, touch_within_layer, global, via or label", .{what.name});
}

pub fn device(p: *Parser) PErr!void {
    const word = try p.ident("a device kind");
    const kind = for (devices) |d| {
        if (eql(d[0], word.name)) break d[1];
    } else return p.fail(word.span, "unknown device kind `{s}`; expected mos, bjt, resistor, capacitor, diode or inductor", .{word.name});
    const marker = try p.layerWord();
    _ = try p.expect("model");
    const model = try p.model();
    _ = try p.expect("terminals");
    const terminals = try p.layerList();
    var value: tables.DeviceValue = .{};
    var fins: ?[]const u8 = null;
    while (!p.lineEnd()) {
        const key = try p.ident("a device value");
        if (eql(key.name, "fins")) {
            if (kind != .mos) return p.fail(key.span, "`fins` is a mos's value, not {s} {s}'s", .{ article(wordOf(kind)), wordOf(kind) });
            if (fins != null) return p.fail(key.span, "`fins` is given twice", .{});
            fins = try p.layerWord();
            continue;
        }
        // A transistor is an n- or a p-channel switch, never both.
        if ((eql(key.name, "on_gate_min") and value.on_gate_max_mv != null) or (eql(key.name, "on_gate_max") and value.on_gate_min_mv != null)) {
            return p.fail(key.span, "a transistor takes on_gate_min (n-channel) or on_gate_max (p-channel), not both", .{});
        }
        const Slot = struct { []const u8, *?f64, Dim, DeviceKind };
        const slots = [_]Slot{
            .{ "sheet", &value.sheet_ohm_sq, .resistance, .resistor },
            .{ "area_cap", &value.area_cap_af_um2, .cap_per_area, .capacitor },
            .{ "fringe_cap", &value.fringe_cap_af_um, .cap_per_length, .capacitor },
            .{ "inductance", &value.inductance_nh, .inductance, .inductor },
            .{ "on_gate_min", &value.on_gate_min_mv, .voltage, .mos },
            .{ "on_gate_max", &value.on_gate_max_mv, .voltage, .mos },
        };
        const slot = for (slots) |s| {
            if (eql(s[0], key.name)) break s;
        } else return p.fail(key.span, "unknown device value `{s}`; expected sheet (a resistor), area_cap or fringe_cap (a capacitor), inductance (an inductor), on_gate_min, on_gate_max or fins (a mos)", .{key.name});
        if (slot[3] != kind) {
            const owner = wordOf(slot[3]);
            const own = wordOf(kind);
            return p.fail(key.span, "`{s}` is {s} {s}'s value, not {s} {s}'s", .{ key.name, article(owner), owner, article(own), own });
        }
        const stated = try p.value();
        const number = (try convert.quantity(p, stated, slot[2], key.name)).toF64();
        // A decimal past f64's range reads as infinite: no value at all.
        if (!std.math.isFinite(number)) return p.fail(stated.span(), "`{s}` is too large a number", .{key.name});
        if (slot[1].* != null) return p.fail(key.span, "`{s}` is given twice", .{key.name});
        slot[1].* = number;
    }
    try p.out.devices.append(p.arena, .{ .kind = kind, .marker = marker, .model = model, .terminals = terminals, .value = value, .fins = fins });
}

/// `matching "<model>" pair|single <key> <value> ..`: a device model's
/// mismatch coefficients, at least one, each positive and given once; one
/// statement per model.
pub fn matching(p: *Parser) PErr!void {
    const at = p.peek();
    const model = try p.model();
    for (p.out.matching.items, p.matching_at.items) |row, first| if (eql(row.model, model)) {
        const line = std.mem.count(u8, p.src[0..first], "\n") + 1;
        return p.failTok(at, "matching \"{s}\" is already stated on line {d}", .{ model, line });
    };
    const word = try p.ident("pair or single");
    const basis = std.meta.stringToEnum(tables.MatchingBasis, word.name) orelse
        return p.fail(word.span, "unknown basis `{s}`; expected pair or single", .{word.name});
    const Reader = struct {
        values: [tables.matching_keys.len]?f64 = @splat(null),
        pub fn read(r: *@This(), q: *Parser, key_at: usize, key: []const u8) PErr!bool {
            const v = try q.value();
            const si = (try convert.quantity(q, v, tables.matching_keys[key_at].dim, key)).toF64();
            if (!(si > 0.0 and std.math.isFinite(si))) return q.fail(v.span(), "{s} must be positive", .{key});
            const was = r.values[key_at];
            r.values[key_at] = si;
            return was == null;
        }
    };
    var r: Reader = .{};
    try p.keyed("matching", &matching_names, "a matching key", matching_list, &r);
    for (r.values) |v| {
        if (v != null) break;
    } else return p.failTok(at, "matching \"{s}\" states nothing; expected {s}", .{ model, matching_list });
    var stated: tables.Matching = .{};
    inline for (tables.matching_keys, r.values) |k, v| @field(stated, k.name) = v;
    try p.matching_at.append(p.scratch, at.start);
    try p.out.matching.append(p.arena, .{ .model = model, .basis = basis, .stated = stated });
}

/// `fill <layer> for <layer> size <l> space <l> keep <l> avoid [..]`, every
/// key required once, in any order.
pub fn fill(p: *Parser) PErr!void {
    const on = try p.layerWord();
    _ = try p.expect("for");
    const density = try p.layerWord();
    const Reader = struct {
        lengths: [3]?Dbu = .{ null, null, null },
        avoid: ?[]const []const u8 = null,
        pub fn read(r: *@This(), q: *Parser, at: usize, key: []const u8) PErr!bool {
            if (at == 3) {
                const was = r.avoid;
                r.avoid = try q.layerList();
                return was == null;
            }
            const v = try q.value();
            const len = try convert.length(q, v, key);
            // `keep` may be zero (fill may touch what it avoids); the rest draw.
            if (len < 0 or (at < 2 and len == 0)) return q.fail(v.span(), "{s} must be positive", .{key});
            const was = r.lengths[at];
            r.lengths[at] = len;
            return was == null;
        }
    };
    var r: Reader = .{};
    const keys = "size, space, keep or avoid";
    try p.keyed("fill", &.{ "size", "space", "keep", "avoid" }, keys, keys, &r);
    if (r.lengths[0] == null or r.lengths[1] == null or r.lengths[2] == null or r.avoid == null) {
        return p.failTok(p.peek(), "fill states size, space, keep and avoid", .{});
    }
    try p.out.edits.fill.append(p.arena, .{ .layer = on, .density = density, .size = r.lengths[0].?, .space = r.lengths[1].?, .keep = r.lengths[2].?, .avoid = r.avoid.? });
}

/// `widen <layer> net "<pattern>" by <len>`.
pub fn widen(p: *Parser) PErr!void {
    const on = try p.layerWord();
    _ = try p.expect("net");
    const net = try p.quoted("a net name pattern in quotes");
    _ = try p.expect("by");
    const v = try p.value();
    const by = try convert.length(p, v, "by");
    if (by <= 0) return p.fail(v.span(), "by must be positive", .{});
    try p.out.edits.widen.append(p.arena, .{ .layer = on, .net = net, .by = by });
}

/// `report p2p "<net>" at [(x, y), ..]`, `report coupling "<net>" "<net>"`,
/// or `report cluster <len>`.
pub fn report(p: *Parser) PErr!void {
    const word = try p.ident("p2p, coupling or cluster");
    if (eql(word.name, "p2p")) {
        const net = try netName(p);
        _ = try p.expect("at");
        const v = try p.value();
        if (v != .list) return p.fail(v.span(), "expected a list of points [(x, y), ..]", .{});
        const points = try p.arena.alloc([2]Dbu, v.list.items.len);
        for (v.list.items, points) |item, *pt| {
            if (item != .tuple) return p.fail(item.span(), "expected a point (x, y)", .{});
            if (item.tuple.items.len != 2) return p.fail(item.tuple.span, "a point is (x, y)", .{});
            pt.* = .{ try convert.length(p, item.tuple.items[0], "x"), try convert.length(p, item.tuple.items[1], "y") };
        }
        if (points.len < 2) return p.fail(v.span(), "report p2p needs two or more points", .{});
        try p.out.reports.p2p.append(p.arena, .{ .net = net, .points = points });
    } else if (eql(word.name, "coupling")) {
        const a = try netName(p);
        try p.out.reports.coupling.append(p.arena, .{ .a = a, .b = try netName(p) });
    } else if (eql(word.name, "cluster")) {
        const v = try p.value();
        const reach = try convert.length(p, v, "cluster");
        if (reach < 0) return p.fail(v.span(), "cluster must be zero or more", .{});
        if (p.out.reports.cluster != null) {
            p.out.reports.cluster = reach;
            return p.fail(word.span, "report cluster is already stated", .{});
        }
        p.out.reports.cluster = reach;
    } else return p.fail(word.span, "unknown report `{s}`; expected p2p, coupling or cluster", .{word.name});
}

/// `waive <rule id> <layer>`: the rule is checked when the deck is lowered,
/// since it may come later; a rule may have several waiver layers, each once.
pub fn waive(p: *Parser) PErr!void {
    const t = p.peek();
    if (t.tok != .rule_id) return p.failTok(t, "expected the id of the rule to waive", .{});
    _ = p.bump();
    const rule = try parse_rules.ruleId(p, t);
    const on = try p.layerWord();
    for (p.out.waivers.items) |w| if (eql(w.rule, rule) and eql(w.layer, on)) {
        return p.failTok(p.toks[p.pos - 1], "`{s}` is already waived by `{s}`", .{ rule, on });
    };
    try p.out.waivers.append(p.arena, .{ .rule = rule, .layer = on });
}

/// `boundary <layer>`, at most once.
pub fn boundary(p: *Parser, span: Span) PErr!void {
    const on = try p.layerWord();
    const was = p.out.boundary;
    p.out.boundary = on;
    if (was != null) return p.fail(span, "the boundary is already stated", .{});
}

/// `netlist_scale <length>`, at most once.
pub fn netlistScale(p: *Parser, span: Span) PErr!void {
    const v = try p.value();
    const nm = (try convert.quantity(p, v, .length, "netlist_scale")).toF64();
    if (!(nm > 0.0)) return p.fail(v.span(), "netlist_scale must be positive", .{});
    const was = p.out.netlist_scale_nm;
    p.out.netlist_scale_nm = nm;
    if (was != null) return p.fail(span, "the netlist scale is already stated", .{});
}

// ---- private ----

fn eql(a: []const u8, b: []const u8) bool {
    return std.mem.eql(u8, a, b);
}

/// Refuses a name a binding or a layer already takes.
fn unbound(p: *Parser, name: []const u8, span: Span) PErr!void {
    if (p.bound(name) != null or p.layers.contains(name)) return p.fail(span, "`{s}` is already bound", .{name});
}

/// `(layer, datatype)` after the word `gds`.
fn gdsPair(p: *Parser) PErr![2]u16 {
    _ = try p.expect("(");
    const l = try gdsNumber(p);
    _ = try p.expect(",");
    const d = try gdsNumber(p);
    _ = try p.expect(")");
    return .{ l, d };
}

fn gdsNumber(p: *Parser) PErr!u16 {
    const t = p.peek();
    if (t.tok == .num) {
        _ = p.bump();
        if (t.unit_at == t.end) if (std.fmt.parseInt(u16, p.text(t), 10)) |n| return n else |_| {};
    }
    return p.failTok(t, "expected a GDS number from 0 to 65535", .{});
}

fn wordOf(kind: DeviceKind) []const u8 {
    for (devices) |d| if (d[1] == kind) return d[0];
    return "";
}

fn article(word: []const u8) []const u8 {
    return if (word.len > 0 and std.mem.indexOfScalar(u8, "aeiou", word[0]) != null) "an" else "a";
}

/// A net name in quotes, not empty.
fn netName(p: *Parser) PErr![]const u8 {
    const t = p.peek();
    const name = try p.quoted("a net name in quotes");
    if (name.len == 0) return p.failTok(t, "a net name is not empty", .{});
    return name;
}
