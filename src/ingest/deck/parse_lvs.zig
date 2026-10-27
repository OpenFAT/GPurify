//! `lvs <control> ...` statements → the `LvsSrc` rows, each control as
//! docs/deck.md ("LVS controls") spells it; models stay names until
//! lowering. Ported from crates/ingest/src/deck/parse.rs (`lvs`,
//! `model_once`, `lvs_range`, `lvs_lde`, `lvs_count`,
//! `lvs_ignore_parameter`, `lvs_tolerance`, `absolute_dim`).
//!
//! Contents:
//! - `pub fn lvs(p: *Parser) PErr!void`
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
const kinds = @import("kinds.zig");
const Dim = kinds.Dim;
const convert = @import("convert.zig");
const source = @import("source.zig");

/// One `lvs` control.
pub fn lvs(p: *Parser) PErr!void {
    const control = try p.ident("an lvs control");
    const c = control.name;
    const src = &p.out.lvs;
    if (eql(c, "tolerance")) return tolerance(p);
    if (eql(c, "ignore_parameter")) return ignoreParameter(p);
    if (eql(c, "permute")) {
        const model = try p.model();
        const a = try p.ident("a pin name");
        const b = try p.ident("a pin name");
        return src.permute.append(p.arena, .{ .model = model, .a = a.name, .b = b.name });
    }
    if (eql(c, "ignore")) return modelOnce(p, control.span, &src.ignore, "\"{s}\" is already ignored");
    if (eql(c, "range")) return range(p);
    if (eql(c, "connect_implicit")) return src.connect_implicit.append(p.arena, try p.quoted("a label pattern in quotes"));
    if (eql(c, "connect_explicit")) {
        var names: std.ArrayList([]const u8) = .empty;
        while (p.peek().tok == .str) try names.append(p.arena, try p.quoted("a label in quotes"));
        if (names.items.len < 2) return p.failTok(p.peek(), "connect_explicit joins two labels or more, each in quotes", .{});
        return src.connect_explicit.append(p.arena, names.items);
    }
    if (eql(c, "topology")) {
        const policy = try p.ident("strict or relaxed");
        const relaxed = if (eql(policy.name, "strict")) false else if (eql(policy.name, "relaxed")) true else return p.fail(policy.span, "unknown topology `{s}`; expected strict or relaxed", .{policy.name});
        const was = src.topology;
        src.topology = relaxed;
        if (was != null) return p.fail(control.span, "the topology is already stated", .{});
        return;
    }
    if (eql(c, "filter_unused")) {
        var options: std.ArrayList(tables.UnusedFilter) = .empty;
        while (p.peek().tok == .ident) {
            const word = try p.ident("a filter option");
            const option = for (tables.UnusedFilter.all) |o| {
                if (eql(o.name(), word.name)) break o;
            } else return p.fail(word.span, "unknown filter option `{s}`; expected ae, af, ag, c or u", .{word.name});
            try options.append(p.scratch, option);
        }
        const t = p.peek();
        if (try src.filterUnused(p.arena, options.items)) |why| return p.failTok(t, "{s}", .{why});
        return;
    }
    if (eql(c, "supply")) {
        var names: std.ArrayList([]const u8) = .empty;
        while (p.peek().tok == .str) try names.append(p.scratch, try p.quoted("a net name in quotes"));
        const t = p.peek();
        if (try src.addSupply(p.arena, names.items)) |why| return p.failTok(t, "{s}", .{why});
        return;
    }
    if (eql(c, "blackbox")) {
        const t = p.peek();
        const pattern = try p.quoted("a cell-name pattern in quotes");
        if (try src.addBlackbox(p.arena, pattern)) |why| return p.failTok(t, "{s}", .{why});
        return;
    }
    if (eql(c, "recognize_gates")) return flagOnce(p, control.span, &src.recognize_gates, "gates are already recognised");
    if (eql(c, "split_gates")) return flagOnce(p, control.span, &src.split_gates, "split gates are already joined");
    if (eql(c, "ports_by_name")) return flagOnce(p, control.span, &src.ports_by_name, "ports are already compared by name");
    if (eql(c, "ignore_shorted")) return modelOnce(p, control.span, &src.ignore_shorted, "shorted \"{s}\" devices are already ignored");
    if (eql(c, "max_res") or eql(c, "min_caps")) {
        const v = try p.value();
        const max_res = eql(c, "max_res");
        const slot = if (max_res) &src.max_res else &src.min_caps;
        if (slot.* != null) return p.fail(control.span, "`{s}` is already stated", .{c});
        const amount = (try convert.quantity(p, v, if (max_res) .resistance else .capacitance, c)).toF64();
        if (!(amount > 0.0)) return p.fail(v.span(), "`{s}` must be positive", .{c});
        slot.* = amount;
        return;
    }
    if (eql(c, "count")) return count(p);
    if (eql(c, "lde")) return lde(p);
    if (eql(c, "same_nets")) {
        const layout = try p.quoted("a layout net label in quotes");
        const reference = try p.quoted("a reference net name in quotes");
        for (src.same_nets.items) |row| if (eql(row.a, layout) or eql(row.b, reference)) {
            return p.fail(control.span, "each net is paired by one same_nets statement at most", .{});
        };
        return src.same_nets.append(p.arena, .{ .a = layout, .b = reference });
    }
    if (eql(c, "asymmetric")) return modelOnce(p, control.span, &src.asymmetric, "\"{s}\" is already asymmetric");
    return p.fail(control.span, "unknown lvs control `{s}`; expected tolerance, ignore_parameter, asymmetric, permute, ignore, ignore_shorted, ports_by_name, range, topology, connect_implicit, connect_explicit, max_res, min_caps, same_nets, count, lde, recognize_gates, split_gates, blackbox, filter_unused or supply", .{c});
}

// ---- private ----

fn eql(a: []const u8, b: []const u8) bool {
    return std.mem.eql(u8, a, b);
}

fn flagOnce(p: *Parser, span: Span, flag: *bool, comptime twice: []const u8) PErr!void {
    if (flag.*) return p.fail(span, twice, .{});
    flag.* = true;
}

/// A model in quotes added to `list`, which names each model once.
fn modelOnce(p: *Parser, span: Span, list: *std.ArrayList([]const u8), comptime twice: []const u8) PErr!void {
    const model = try p.model();
    for (list.items) |m| if (eql(m, model)) return p.fail(span, twice, .{model});
    try list.append(p.arena, model);
}

fn lower(p: *Parser, name: []const u8) PErr![]const u8 {
    const out = try p.arena.alloc(u8, name.len);
    return std.ascii.lowerString(out, name);
}

/// `lvs range "model" param >= min <= max`, either bound or both, each of
/// the parameter's kind, converted to the layout's grid.
fn range(p: *Parser) PErr!void {
    const model = try p.model();
    const word = try p.ident("a parameter name");
    const param = try lower(p, word.name);
    const dim: Dim = for ([_][]const u8{ "w", "l", "perim", "ps", "pd", "pe" }) |n| {
        if (eql(n, param)) break .length;
    } else for ([_][]const u8{ "area", "as", "ad", "ae" }) |n| {
        if (eql(n, param)) break .area;
    } else if (eql(param, "nf") or eql(param, "nfin")) .count else return p.fail(word.span, "`{s}` is not measured on a device; expected w, l, perim, ps, pd, pe, area, as, ad, ae, nf or nfin", .{param});
    for (p.out.lvs.range.items) |row| if (eql(row.model, model) and eql(row.param, param)) {
        return p.fail(word.span, "`{s}` of \"{s}\" already has a range", .{ param, model });
    };
    const Reader = struct {
        dim: Dim,
        param: []const u8,
        pub fn read(r: @This(), q: *Parser, v: Val) PErr!tables.LvsLimit {
            return switch (r.dim) {
                .length => .{ .length = try convert.length(q, v, r.param) },
                .area => .{ .area = try convert.area(q, v, r.param) },
                else => .{ .count = try convert.count(q, v, r.param) }, // else: the three kinds above are the only ones chosen
            };
        }
    };
    const b = try p.minMax(tables.LvsLimit, Reader{ .dim = dim, .param = param });
    if (b[0] == null and b[1] == null) return p.failTok(p.peek(), "a range needs >=, <= or both", .{});
    if (b[0] != null and b[1] != null and b[1].?.less(b[0].?)) return p.fail(word.span, "the range admits no value", .{});
    try p.out.lvs.range.append(p.arena, .{ .model = model, .param = param, .min = b[0], .max = b[1] });
}

/// `lvs lde "model" od <layer> max <length> [well <layer> scref <length>]`,
/// the keys in any order, each once; `od` and `max` needed, `well` and
/// `scref` together.
fn lde(p: *Parser) PErr!void {
    const model = try p.model();
    const span = p.peek();
    for (p.out.lvs.lde.items) |row| if (eql(row.model, model)) return p.failTok(span, "\"{s}\" already has an lde row", .{model});
    const Reader = struct {
        od: ?[]const u8 = null,
        max: ?Dbu = null,
        well: ?[]const u8 = null,
        scref: ?Dbu = null,
        pub fn read(r: *@This(), q: *Parser, at: usize, key: []const u8) PErr!bool {
            switch (at) {
                0, 2 => {
                    const slot = if (at == 0) &r.od else &r.well;
                    const was = slot.*;
                    slot.* = try q.layerWord();
                    return was == null;
                },
                else => {
                    const v = try q.value();
                    const len = try convert.length(q, v, key);
                    if (len <= 0) return q.fail(v.span(), "`{s}` must be positive", .{key});
                    const slot = if (at == 1) &r.max else &r.scref;
                    const was = slot.*;
                    slot.* = len;
                    return was == null;
                },
            }
        }
    };
    var r: Reader = .{};
    const keys = "od, max, well or scref";
    try p.keyed("lde", &.{ "od", "max", "well", "scref" }, keys, keys, &r);
    if (r.od == null or r.max == null) return p.failTok(p.peek(), "an lde row needs od and max", .{});
    if ((r.well == null) != (r.scref == null)) return p.failTok(p.peek(), "well and scref go together", .{});
    const well: ?source.LdeWellSrc = if (r.well) |w| .{ .layer = w, .scref = r.scref.? } else null;
    try p.out.lvs.lde.append(p.arena, .{ .model = model, .od = r.od.?, .max = r.max.?, .well = well });
}

/// `lvs count "model" >= min <= max`, either bound or both.
fn count(p: *Parser) PErr!void {
    const model = try p.model();
    const span = p.peek();
    for (p.out.lvs.count.items) |row| if (eql(row.model, model)) return p.failTok(span, "\"{s}\" already has a count", .{model});
    const Reader = struct {
        pub fn read(_: @This(), q: *Parser, v: Val) PErr!u32 {
            return convert.count(q, v, "count");
        }
    };
    const b = try p.minMax(u32, Reader{});
    if (b[0] == null and b[1] == null) return p.failTok(p.peek(), "a count needs >=, <= or both", .{});
    if (b[0] != null and b[1] != null and b[1].? < b[0].?) return p.failTok(span, "the count admits no value", .{});
    try p.out.lvs.count.append(p.arena, .{ .model = model, .min = b[0], .max = b[1] });
}

/// `lvs ignore_parameter "model" param`; `m` counts devices and is no
/// parameter to ignore.
fn ignoreParameter(p: *Parser) PErr!void {
    const model = try p.model();
    const word = try p.ident("a parameter name");
    const param = try lower(p, word.name);
    if (eql(param, "m")) return p.fail(word.span, "`m` counts devices, and cannot be ignored", .{});
    for (p.out.lvs.ignore_parameter.items) |row| if (eql(row.a, model) and eql(row.b, param)) {
        return p.fail(word.span, "`{s}` is already ignored", .{param});
    };
    try p.out.lvs.ignore_parameter.append(p.arena, .{ .a = model, .b = param });
}

/// The kind an absolute tolerance on `param` is written as.
fn absoluteDim(param: []const u8) ?Dim {
    const unit = (tables.absoluteUnit(param) orelse return null).unit;
    if (eql(unit, "nm")) return .length;
    if (eql(unit, "nm2")) return .area;
    if (eql(unit, "ohm")) return .resistance;
    if (eql(unit, "aF")) return .capacitance;
    if (eql(unit, "nH")) return .inductance;
    return .count;
}

/// `lvs tolerance "model" param relative r absolute a`, either part or
/// both, or `lvs tolerance default relative r`.
fn tolerance(p: *Parser) PErr!void {
    const t = p.peek();
    if (t.tok == .ident and eql(p.text(t), "default")) {
        _ = p.bump();
        _ = try p.expect("relative");
        const v = try p.value();
        const fraction = (try convert.quantity(p, v, .fraction, "relative")).toF64();
        if (p.out.lvs.defaultTolerance(fraction)) |why| return p.fail(v.span(), "{s}", .{why});
        return;
    }
    const model = try p.model();
    const word = try p.ident("a parameter name");
    const param = try lower(p, word.name);
    for (p.out.lvs.tolerance.items) |row| if (eql(row.model, model) and eql(row.param, param)) {
        return p.fail(word.span, "`{s}` of \"{s}\" already has a tolerance", .{ param, model });
    };
    var relative: ?f64 = null;
    var absolute: ?f64 = null;
    while (!p.lineEnd()) {
        const key = try p.ident("relative or absolute");
        const v = try p.value();
        if (eql(key.name, "relative")) {
            const fraction = (try convert.quantity(p, v, .fraction, key.name)).toF64();
            if (!(fraction >= 0.0 and fraction <= 1.0)) return p.fail(v.span(), "a relative tolerance is a fraction: 0 to 1, or 0% to 100%", .{});
            if (relative != null) return p.fail(key.span, "`{s}` is given twice", .{key.name});
            relative = fraction;
        } else if (eql(key.name, "absolute")) {
            const dim = absoluteDim(param) orelse return p.fail(key.span, "`{s}` has no known unit, so it takes a relative tolerance only", .{param});
            const amount = (try convert.quantity(p, v, dim, key.name)).toF64();
            if (amount < 0.0) return p.fail(v.span(), "an absolute tolerance is zero or more", .{});
            if (absolute != null) return p.fail(key.span, "`{s}` is given twice", .{key.name});
            absolute = amount;
        } else return p.fail(key.span, "unknown tolerance part `{s}`; expected relative or absolute", .{key.name});
    }
    if (relative == null and absolute == null) return p.failTok(p.peek(), "a tolerance needs relative, absolute or both", .{});
    try p.out.lvs.tolerance.append(p.arena, .{ .model = model, .param = param, .relative = relative orelse 0, .absolute = absolute orelse 0 });
}
