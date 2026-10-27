//! The parasitic statements: `pex`, `corner`, `temperature`, `pex_fill`,
//! `pex_device`, `pex_tsv`, `pex_substrate` and `extraction` → their rows of
//! the `DeckSource`, every value one a process can have
//! (docs/src/reference/deck/extraction.md). Ported from
//! crates/ingest/src/deck/parse.rs (`pex`, `corner`, `pex_values`,
//! `temperature`, `pex_fill`, `pex_device`, `pex_tsv`, `pex_substrate`,
//! `extraction`, `kelvin`, `pex_keys`).
//!
//! Contents:
//! - `pub fn pex(p: *Parser) PErr!void`, `pub fn corner(p: *Parser) PErr!void`
//! - `pub fn temperature(p: *Parser, span: Span) PErr!void`
//! - `pub fn pexFill(p: *Parser) PErr!void`, `pub fn pexDevice(p: *Parser) PErr!void`,
//!   `pub fn pexTsv(p: *Parser) PErr!void`, `pub fn pexSubstrate(p: *Parser, span: Span) PErr!void`
//! - `pub fn extraction(p: *Parser, span: Span) PErr!void`
//! - each statement's local `Reader.read`, the `keyed`/`minMax` callback

const std = @import("std");
const parser = @import("parser.zig");
const Parser = parser.Parser;
const PErr = parser.PErr;
const Span = parser.Span;
const tables = @import("tables.zig");
const kinds = @import("kinds.zig");
const convert = @import("convert.zig");

/// The `pex_keys` names, joined.
const pex_key_list = blk: {
    var s: []const u8 = "";
    for (kinds.pex_keys, 0..) |k, i| s = s ++ (if (i == 0) "" else ", ") ++ k[0];
    break :blk s;
};

/// `pex <layer> <key> <value> ..`: one row, every key but the optional ones required.
pub fn pex(p: *Parser) PErr!void {
    const layer = try p.layerWord();
    for (p.out.pex.items) |row| if (eql(row.layer, layer)) return p.failTok(p.toks[p.pos - 1], "`{s}` already has a pex row", .{layer});
    const row = try pexValues(p, layer);
    var missing: std.ArrayList([]const u8) = .empty;
    for (kinds.pex_keys, row) |key, v| {
        const optional = for (kinds.optional_pex_keys) |o| {
            if (eql(o, key[0])) break true;
        } else false;
        if (v == null and !optional) try missing.append(p.scratch, key[0]);
    }
    if (missing.items.len > 0) return p.failTok(p.peek(), "pex `{s}` is missing {s}", .{ layer, try std.mem.join(p.scratch, ", ", missing.items) });
    // One coefficient alone is a resistance law half written.
    if ((row[6] == null) != (row[7] == null)) return p.failTok(p.peek(), "pex `{s}` gives one of tc1 and tc2; give both, or neither", .{layer});
    try p.out.pex.append(p.arena, .{ .layer = layer, .row = .{
        .thickness_nm = row[0] orelse 0,
        .height_nm = row[1] orelse 0,
        .sheet_res_ohm_sq = row[2] orelse 0,
        .dielectric_k = row[3] orelse 0,
        .area_cap_af_um2 = row[4] orelse 0,
        .fringe_cap_af_um = row[5] orelse 0,
        .tc = if (row[6]) |tc1| .{ tc1, row[7].? } else null,
    } });
}

/// `corner <name> <layer> <key> <value> ..`: a layer's `pex` values at a
/// process corner, at least one; each corner names each layer once.
pub fn corner(p: *Parser) PErr!void {
    const name = try p.ident("a corner name");
    const layer = try p.layerWord();
    const at = p.toks[p.pos - 1];
    for (p.out.corners.items) |line| if (eql(line.corner, name.name) and eql(line.layer, layer)) {
        return p.failTok(at, "corner `{s}` already states `{s}`", .{ name.name, layer });
    };
    const values = try pexValues(p, layer);
    for (values) |v| {
        if (v != null) break;
    } else return p.failTok(at, "corner `{s}` states nothing for `{s}`; expected {s}", .{ name.name, layer, pex_key_list });
    try p.out.corners.append(p.arena, .{ .corner = name.name, .layer = layer, .values = values });
}

/// `temperature <operating> nominal <nominal>`.
pub fn temperature(p: *Parser, span: Span) PErr!void {
    const operating = try kelvin(p, "temperature");
    _ = try p.expect("nominal");
    const nominal = try kelvin(p, "nominal");
    const was = p.out.temperature;
    p.out.temperature = .{ .operating_k = operating, .nominal_k = nominal };
    if (was != null) return p.fail(span, "the temperature is already stated", .{});
}

/// `pex_fill <layer> floating|grounded|ignored`.
pub fn pexFill(p: *Parser) PErr!void {
    const layer = try p.layerWord();
    const word = try p.ident("floating, grounded or ignored");
    const treatment = std.meta.stringToEnum(tables.FillTreatment, word.name) orelse
        return p.fail(word.span, "unknown fill treatment `{s}`; expected floating, grounded or ignored", .{word.name});
    try p.out.pex_models.fill.append(p.arena, .{ .layer = layer, .treatment = treatment });
}

/// `pex_device "<model>" gate_contact_cap <c> gate_diffusion_cap <c>`, both
/// required, zero or more.
pub fn pexDevice(p: *Parser) PErr!void {
    const model = try p.model();
    const Reader = struct {
        values: [2]?f64 = .{ null, null },
        pub fn read(r: *@This(), q: *Parser, at: usize, key: []const u8) PErr!bool {
            const v = try q.value();
            const af = (try convert.quantity(q, v, .cap_per_length, key)).toF64();
            if (!(af >= 0.0 and std.math.isFinite(af))) return q.fail(v.span(), "{s} must be zero or more", .{key});
            return replace(&r.values[at], af);
        }
    };
    var r: Reader = .{};
    const keys = "gate_contact_cap or gate_diffusion_cap";
    try p.keyed("pex_device", &.{ "gate_contact_cap", "gate_diffusion_cap" }, keys, keys, &r);
    if (r.values[0] == null or r.values[1] == null) return p.failTok(p.peek(), "pex_device states both gate_contact_cap and gate_diffusion_cap", .{});
    try p.out.pex_models.device.append(p.arena, .{ .model = model, .gate_contact_af_um = r.values[0].?, .gate_diffusion_af_um = r.values[1].? });
}

/// `pex_tsv <layer> length <l> liner <t> liner_k <k>`, every value
/// required and positive.
pub fn pexTsv(p: *Parser) PErr!void {
    const layer = try p.layerWord();
    const Reader = struct {
        values: [3]?f64 = .{ null, null, null },
        pub fn read(r: *@This(), q: *Parser, at: usize, key: []const u8) PErr!bool {
            const v = try q.value();
            const number = try convert.physical(q, v, if (at == 2) .scalar else .length, key);
            if (!(number > 0.0 and std.math.isFinite(number))) return q.fail(v.span(), "{s} must be positive", .{key});
            return replace(&r.values[at], number);
        }
    };
    var r: Reader = .{};
    const keys = "length, liner or liner_k";
    try p.keyed("pex_tsv", &.{ "length", "liner", "liner_k" }, keys, keys, &r);
    if (r.values[0] == null or r.values[1] == null or r.values[2] == null) return p.failTok(p.peek(), "pex_tsv states length, liner and liner_k", .{});
    try p.out.pex_models.tsv.append(p.arena, .{ .layer = layer, .length_nm = r.values[0].?, .liner_nm = r.values[1].?, .liner_k = r.values[2].? });
}

/// `pex_substrate ports [layers] backside grounded|floating profile
/// [(thickness, resistivity Ω·cm), ..]`, at most once, every key required.
pub fn pexSubstrate(p: *Parser, span: Span) PErr!void {
    if (p.out.pex_models.substrate != null) return p.fail(span, "pex_substrate is stated twice", .{});
    const Reader = struct {
        ports: ?[]const []const u8 = null,
        grounded: ?bool = null,
        layers: ?[]const [2]f64 = null,
        pub fn read(r: *@This(), q: *Parser, at: usize, _: []const u8) PErr!bool {
            switch (at) {
                0 => {
                    const was = r.ports;
                    r.ports = try q.layerList();
                    return was == null;
                },
                1 => {
                    const word = try q.ident("grounded or floating");
                    const grounded = if (eql(word.name, "grounded")) true else if (eql(word.name, "floating")) false else return q.fail(word.span, "unknown backside `{s}`; expected grounded or floating", .{word.name});
                    const was = r.grounded;
                    r.grounded = grounded;
                    return was == null;
                },
                else => {
                    const was = r.layers;
                    r.layers = try profile(q);
                    return was == null;
                },
            }
        }
    };
    var r: Reader = .{};
    const keys = "ports, backside or profile";
    try p.keyed("pex_substrate", &.{ "ports", "backside", "profile" }, keys, keys, &r);
    if (r.ports == null or r.grounded == null or r.layers == null) return p.failTok(p.peek(), "pex_substrate states ports, backside and profile", .{});
    p.out.pex_models.substrate = .{ .ports = r.ports.?, .grounded = r.grounded.?, .layers = r.layers.? };
}

/// `extraction <type> [coupling_threshold <capacitance>] [coupling_halo <ratio>]`, at most once.
pub fn extraction(p: *Parser, span: Span) PErr!void {
    const word = try p.ident("an extraction type");
    const kind = std.meta.stringToEnum(tables.ExtractionKind, word.name) orelse
        return p.fail(word.span, "unknown extraction type `{s}`; expected r, c, cc, rc or rcc", .{word.name});
    var threshold: ?f64 = null;
    var halo: ?f64 = null;
    while (!p.lineEnd()) {
        const key = try p.ident("`coupling_threshold` or `coupling_halo`");
        if (eql(key.name, "coupling_halo")) {
            const v = try p.value();
            const ratio = (try convert.quantity(p, v, .scalar, "coupling_halo")).toF64();
            if (!(ratio > 0.0)) return p.fail(v.span(), "coupling_halo must be positive", .{});
            if (kind == .r) return p.fail(key.span, "coupling_halo is how far capacitance is looked for, and `r` keeps none", .{});
            if (!replace(&halo, ratio)) return p.fail(key.span, "`coupling_halo` is given twice", .{});
            continue;
        }
        if (!eql(key.name, "coupling_threshold")) return p.fail(key.span, "unknown extraction key `{s}`; expected coupling_threshold or coupling_halo", .{key.name});
        const v = try p.value();
        const af = (try convert.quantity(p, v, .capacitance, "coupling_threshold")).toF64();
        if (!(af >= 0.0)) return p.fail(v.span(), "coupling_threshold must be zero or more", .{});
        if (af > 0.0 and !kind.keepsCoupling()) return p.fail(key.span, "coupling_threshold grounds the coupling below it, and `{s}` keeps no coupling", .{word.name});
        if (!replace(&threshold, af)) return p.fail(key.span, "`coupling_threshold` is given twice", .{});
    }
    const was = p.out.extraction;
    p.out.extraction = .{ .kind = kind, .coupling_threshold_af = threshold orelse 0, .coupling_halo = halo };
    if (was != null) return p.fail(span, "the extraction type is already stated", .{});
}

// ---- private ----

fn eql(a: []const u8, b: []const u8) bool {
    return std.mem.eql(u8, a, b);
}

/// Sets `slot`; whether it was empty.
fn replace(slot: *?f64, v: f64) bool {
    const was = slot.*;
    slot.* = v;
    return was == null;
}

/// The `key value` pairs of a `pex` row or a `corner` line, each key at
/// most once, each value one a process can have; null for a key not given.
fn pexValues(p: *Parser, layer: []const u8) PErr!tables.CornerValues {
    const Reader = struct {
        layer: []const u8,
        row: tables.CornerValues = @splat(null),
        pub fn read(r: *@This(), q: *Parser, at: usize, key: []const u8) PErr!bool {
            const v = try q.value();
            const number = (try convert.quantity(q, v, kinds.pex_keys[at][1], key)).toF64();
            // A thickness, and a dielectric that is stated, are positive; a
            // temperature coefficient takes either sign; nothing else is
            // below zero. Past f64's range a decimal reads as infinite.
            const finite = std.math.isFinite(number);
            const positive = eql(key, "thickness") or eql(key, "dielectric");
            const signed = eql(key, "tc1") or eql(key, "tc2");
            const physical = finite and (signed or number > 0.0 or (!positive and number >= 0.0));
            const bound: []const u8 = if (positive) "positive and finite" else if (signed) "finite" else "zero or more, and finite";
            if (!physical) return q.fail(v.span(), "pex `{s}`: {s} must be {s}", .{ r.layer, key, bound });
            return replace(&r.row[at], number);
        }
    };
    var r: Reader = .{ .layer = layer };
    var names: [kinds.pex_keys.len][]const u8 = undefined;
    for (kinds.pex_keys, &names) |k, *n| n.* = k[0];
    try p.keyed("pex", &names, "a pex key", pex_key_list, &r);
    return r.row;
}

/// A temperature, absolute, above absolute zero.
fn kelvin(p: *Parser, label: []const u8) PErr!f64 {
    const v = try p.value();
    const k = try convert.physical(p, v, .temperature, label);
    if (k > 0.0) return k;
    return p.fail(v.span(), "{s} must be above absolute zero", .{label});
}

/// `[(thickness, resistivity), ..]`, each layer's values positive.
fn profile(q: *Parser) PErr![]const [2]f64 {
    const v = try q.value();
    if (v != .list) return q.fail(v.span(), "expected a profile [(thickness, resistivity), ..]", .{});
    const rows = try q.arena.alloc([2]f64, v.list.items.len);
    for (v.list.items, rows) |item, *row| {
        if (item != .tuple) return q.fail(item.span(), "expected a layer (thickness, resistivity in ohm·cm)", .{});
        if (item.tuple.items.len != 2) return q.fail(item.tuple.span, "a substrate layer is (thickness, resistivity in ohm·cm)", .{});
        const t = try convert.physical(q, item.tuple.items[0], .length, "thickness");
        const rho = try convert.physical(q, item.tuple.items[1], .scalar, "resistivity");
        if (!(t > 0.0 and std.math.isFinite(t) and rho > 0.0 and std.math.isFinite(rho))) return q.fail(item.tuple.span, "a substrate layer's thickness and resistivity are positive", .{});
        row.* = .{ t, rho };
    }
    if (rows.len == 0) return q.fail(v.span(), "a profile has at least one layer", .{});
    return rows;
}
