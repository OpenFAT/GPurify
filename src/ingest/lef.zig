//! The LEF reader: technology layers, vias, sites, non-default widths and
//! cell abstracts, in DEF database units (LEF/DEF 5.8 Language Reference).
//! In: LEF text and the DEF's units per micrometre. Out: rows appended to a
//! `Lef`. Ported from crates/ingest/src/lefdef/lef.rs.
//!
//! Contents:
//! - `pub const LayerKind`, `pub const LefLayer`, `pub const ViaPoint`, `pub const MacroPin`,
//!   `pub const AntennaKind`, `pub const PinAntenna`, `pub const CellEdgeSpacing`,
//!   `pub const EdgeSide`, `pub const EdgeSpan`, `pub const EdgeType`, `pub const Macro`,
//!   `pub const Site`, `pub const LayerWidth`, `pub const Ndr`, `pub const Lef`
//! - `pub fn readLefInto(arena: Allocator, text: []const u8, dbu: i64, lef: *Lef, diag: *Diagnostic) Error!void`
//! - `pub fn generated(arena: Allocator, lx: *const Lexer, rule: ?ViaRule, shapes: *std.ArrayList(Shape)) Error!void`

const std = @import("std");
const Allocator = std.mem.Allocator;
const lex = @import("lefdef_lex.zig");
const Lexer = lex.Lexer;
const Error = lex.Error;
const Diagnostic = lex.Diagnostic;
const Pt = lex.Pt;
const lefdef = @import("lefdef.zig");
const Shape = lefdef.Shape;
const ViaRule = lefdef.ViaRule;
const NamedVia = lefdef.NamedVia;
const props = @import("lef_props.zig");

/// A LEF layer's `TYPE`.
pub const LayerKind = enum(u8) {
    /// Carries wires.
    routing,
    /// Via cuts between two routing or masterslice layers.
    cut,
    /// Poly or diffusion, below the routing.
    masterslice,
    /// The outline of an irregular macro.
    overlap,
    /// Any other type (`IMPLANT`, `TSV`, …), not a conductor here.
    other,
};

/// One `LAYER`, lengths in database units.
pub const LefLayer = struct {
    name: []const u8,
    /// `other` until a `TYPE` statement says.
    kind: LayerKind = .other,
    /// The default wire width: what a regular DEF wire on it is drawn at.
    width: ?i64 = null,
    /// `PITCH` x and y (one value gives both).
    pitch: ?Pt = null,
    /// `DIRECTION HORIZONTAL` (true) or `VERTICAL`.
    horizontal: ?bool = null,
};

/// A `VIA pt name` statement: the via and where its origin goes.
pub const ViaPoint = struct { name: []const u8, at: Pt };

/// One macro `PIN`: its ports' shapes and vias, unplaced, and its antenna
/// statements (5.8 pp. 140-142), the last of each kind and layer kept; gate
/// areas and ratios are the default oxide model's (`OXIDE1` or none).
pub const MacroPin = struct {
    name: []const u8,
    shapes: []const Shape = &.{},
    vias: []const ViaPoint = &.{},
    antenna: []const PinAntenna = &.{},
};

/// What a macro pin's antenna statement states.
pub const AntennaKind = enum(u8) {
    /// `ANTENNAPARTIALMETALAREA`, µm².
    partial_metal,
    /// `ANTENNAPARTIALMETALSIDEAREA`, µm².
    partial_metal_side,
    /// `ANTENNAPARTIALCUTAREA`, µm².
    partial_cut,
    /// `ANTENNADIFFAREA`, µm².
    diff,
    /// `ANTENNAGATEAREA`, µm².
    gate,
    /// `ANTENNAMAXAREACAR`: the cumulative area ratio on the layer.
    max_area_car,
    /// `ANTENNAMAXSIDEAREACAR`.
    max_side_area_car,
    /// `ANTENNAMAXCUTCAR`.
    max_cut_car,
};

/// One macro pin antenna statement: an area in µm² or a ratio, and its
/// `LAYER` or null for every layer.
pub const PinAntenna = struct { kind: AntennaKind, value: f64, layer: ?[]const u8 };

/// One `EDGETYPE` entry of a library's `LEF58_CELLEDGESPACINGTABLE`: the
/// least spacing between cell edges of two types (ISPD 2014 Suite A slides
/// 16, 27; ICCAD 2017 Problem C), the same either way round.
pub const CellEdgeSpacing = struct {
    first: []const u8,
    second: []const u8,
    /// Database units.
    spacing: i64 = 0,
    /// `EXCEPTABUTTED`: two edges that touch are exempt.
    except_abutted: bool = false,
    /// Options no public text defines (`EXCEPTNONFILLERINBETWEEN`,
    /// `OPTIONAL`, `SOFT`, `EXACT`); an entry with any is not checked.
    undefined: []const []const u8 = &.{},
};

/// The side of a cell an `EdgeType` types, in the macro's own frame.
pub const EdgeSide = enum(u8) { left, right, top, bottom };

/// Which stretch of its side an `EdgeType` covers: the whole side, the
/// n-th row or half row from 1 at the bottom, or a range in database units.
pub const EdgeSpan = union(enum) { whole, cell_row: u32, half_row: u32, range: Pt };

/// One `EDGETYPE` statement of a macro's `LEF58_EDGETYPE` property.
pub const EdgeType = struct { side: EdgeSide, name: []const u8, span: EdgeSpan };

/// One `MACRO`: a cell's abstract.
pub const Macro = struct {
    /// As a DEF component's model names it.
    name: []const u8,
    /// `CLASS`'s first word (`CORE`, `BLOCK`, `PAD`, …); empty when none.
    class: []const u8 = "",
    /// `CLASS CORE SPACER`: a filler cell.
    spacer: bool = false,
    edge_types: []const EdgeType = &.{},
    /// `ORIGIN`, added to every shape before placement.
    origin: Pt = .{ 0, 0 },
    /// `SIZE width BY height`.
    size: Pt = .{ 0, 0 },
    pins: []const MacroPin = &.{},
    obs: []const Shape = &.{},
    obs_vias: []const ViaPoint = &.{},
};

pub const Site = struct { name: []const u8, size: Pt };

pub const LayerWidth = struct { layer: []const u8, width: i64 };

/// A `NONDEFAULTRULE`'s wire width per layer.
pub const Ndr = struct { name: []const u8, widths: []const LayerWidth };

/// One or more LEF files read into one library in DEF database units; a
/// later definition of a name is appended, and the first one found is used.
/// Lists grow in the arena `readLefInto` is given.
pub const Lef = struct {
    manufacturing_grid: ?i64 = null,
    layers: std.ArrayList(LefLayer) = .empty,
    vias: std.ArrayList(NamedVia) = .empty,
    sites: std.ArrayList(Site) = .empty,
    ndrs: std.ArrayList(Ndr) = .empty,
    macros: std.ArrayList(Macro) = .empty,
    cell_edge_spacing: std.ArrayList(CellEdgeSpacing) = .empty,
};

const antenna_words = std.StaticStringMap(AntennaKind).initComptime(.{
    .{ "ANTENNAPARTIALMETALAREA", .partial_metal },
    .{ "ANTENNAPARTIALMETALSIDEAREA", .partial_metal_side },
    .{ "ANTENNAPARTIALCUTAREA", .partial_cut },
    .{ "ANTENNADIFFAREA", .diff },
    .{ "ANTENNAGATEAREA", .gate },
    .{ "ANTENNAMAXAREACAR", .max_area_car },
    .{ "ANTENNAMAXSIDEAREACAR", .max_side_area_car },
    .{ "ANTENNAMAXCUTCAR", .max_cut_car },
});

/// Reads one LEF file into `lef`, every length converted to `dbu` units per
/// micrometre. Refuses a malformed statement, a `PATH` or `ITERATE`, a via
/// `PATTERN` that does not fit its `ROWCOL`, and a length between two
/// database units; an unknown layer type reads as `other`.
pub fn readLefInto(arena: Allocator, text: []const u8, dbu: i64, lef: *Lef, diag: *Diagnostic) Error!void {
    var lx: Lexer = try .init(arena, text, "LEF", diag);
    while (lx.peek()) |word| {
        _ = try lx.next();
        if (is(word, "END")) {
            _ = try lx.next(); // `END LIBRARY`, the last statement.
        } else if (is(word, "UNITS") or is(word, "SPACING")) {
            try lx.skipToEnd(word);
        } else if (is(word, "PROPERTYDEFINITIONS")) {
            // `object name type [RANGE …] [value] ;`; a library string
            // property may carry its value here.
            while (true) {
                const object = try lx.next();
                if (is(object, "END")) {
                    try lx.expect("PROPERTYDEFINITIONS");
                    break;
                }
                const name = try lx.next();
                var value: ?[]const u8 = null;
                while (true) {
                    const token = try lx.next();
                    if (is(token, ";")) break;
                    if (token[0] == '"') value = token;
                }
                if (value != null and is(object, "LIBRARY")) try props.libraryProperty(arena, &lx, dbu, lef, name, value.?);
            }
        } else if (is(word, "PROPERTY")) {
            // `PROPERTY name value [name value …] ;`.
            while (true) {
                const name = try lx.next();
                if (is(name, ";")) break;
                try props.libraryProperty(arena, &lx, dbu, lef, name, try lx.next());
            }
        } else if (is(word, "MANUFACTURINGGRID")) {
            lef.manufacturing_grid = try lx.microns(dbu);
            try lx.expect(";");
        } else if (is(word, "LAYER")) {
            try lef.layers.append(arena, try layer(&lx, dbu));
        } else if (is(word, "VIA")) {
            try lef.vias.append(arena, try via(arena, &lx, dbu));
        } else if (is(word, "SITE")) {
            const name = try lx.next();
            var size: Pt = .{ 0, 0 };
            while (true) {
                const w = try lx.next();
                if (is(w, "END")) {
                    try lx.expect(name);
                    break;
                } else if (is(w, "SIZE")) {
                    size[0] = try lx.microns(dbu);
                    try lx.expect("BY");
                    size[1] = try lx.microns(dbu);
                    try lx.expect(";");
                } else try lx.skipStatement();
            }
            try lef.sites.append(arena, .{ .name = name, .size = size });
        } else if (is(word, "NONDEFAULTRULE")) {
            try lef.ndrs.append(arena, try ndr(arena, &lx, dbu, lef));
        } else if (is(word, "BEGINEXT")) {
            while (!is(try lx.next(), "ENDEXT")) {}
        } else if (is(word, "VIARULE")) {
            try lx.skipToEnd(try lx.next());
        } else if (is(word, "MACRO")) {
            try lef.macros.append(arena, try macro(arena, &lx, dbu));
        } else try lx.skipStatement();
    }
}

/// Adds a generated via's cut and enclosure shapes to `shapes`, once its
/// rule is checked; nothing for a fixed via.
pub fn generated(arena: Allocator, lx: *const Lexer, rule: ?ViaRule, shapes: *std.ArrayList(Shape)) Error!void {
    const r = rule orelse return;
    if (r.rowcol[0] < 1 or r.rowcol[1] < 1 or r.cut[0] <= 0 or r.cut[1] <= 0) return lx.fail("a generated via needs a positive CUTSIZE and ROWCOL", .{});
    if (r.rowcol[0] > 1024 or r.rowcol[1] > 1024) return lx.fail("a generated via of more than 1024 cuts a side is not read", .{});
    for (r.layers) |l| if (l.len == 0) return lx.fail("a generated via needs its LAYERS", .{});
    if (try r.cuts(arena) == null) return lx.fail("via cut PATTERN {s} does not give the {d} rows of {d} cuts its ROWCOL states", .{ r.pattern, r.rowcol[0], r.rowcol[1] });
    try r.shapes(arena, shapes);
}

// ---- private ----

fn is(a: []const u8, b: []const u8) bool {
    return std.mem.eql(u8, a, b);
}

fn ndr(arena: Allocator, lx: *Lexer, dbu: i64, lef: *Lef) Error!Ndr {
    const name = try lx.next();
    var widths: std.ArrayList(LayerWidth) = .empty;
    while (true) {
        const word = try lx.next();
        if (is(word, "END")) {
            try lx.expect(name);
            break;
        } else if (is(word, "LAYER")) {
            const l = try lx.next();
            while (true) {
                const w = try lx.next();
                if (is(w, "END")) {
                    try lx.expect(l);
                    break;
                } else if (is(w, "WIDTH")) {
                    try widths.append(arena, .{ .layer = l, .width = try lx.microns(dbu) });
                    try lx.expect(";");
                } else try lx.skipStatement();
            }
        } else if (is(word, "VIA")) {
            try lef.vias.append(arena, try via(arena, lx, dbu));
        } else if (is(word, "SPACING")) {
            try lx.skipToEnd("SPACING");
        } else try lx.skipStatement();
    }
    return .{ .name = name, .widths = widths.items };
}

fn layer(lx: *Lexer, dbu: i64) Error!LefLayer {
    const name = try lx.next();
    var out: LefLayer = .{ .name = name };
    while (true) {
        const word = try lx.next();
        if (is(word, "END")) {
            try lx.expect(name);
            return out;
        } else if (is(word, "TYPE")) {
            const t = try lx.next();
            out.kind = if (is(t, "ROUTING")) .routing else if (is(t, "CUT")) .cut else if (is(t, "MASTERSLICE")) .masterslice else if (is(t, "OVERLAP")) .overlap else .other;
            try lx.skipStatement();
        } else if (is(word, "WIDTH")) {
            out.width = try lx.microns(dbu);
            try lx.expect(";");
        } else if (is(word, "PITCH")) {
            const x = try lx.microns(dbu);
            const y = if (lx.peek() != null and is(lx.peek().?, ";")) x else try lx.microns(dbu);
            out.pitch = .{ x, y };
            try lx.expect(";");
        } else if (is(word, "DIRECTION")) {
            const d = try lx.next();
            out.horizontal = if (is(d, "HORIZONTAL")) true else if (is(d, "VERTICAL")) false else null;
            try lx.skipStatement();
        } else if (is(word, "ACCURRENTDENSITY") or is(word, "DCCURRENTDENSITY")) {
            // `… type value ;`, or `… type` and its own `FREQUENCY`,
            // `CUTAREA`, `WIDTH` statements through `TABLEENTRIES … ;`.
            _ = try lx.next();
            if (lx.peek()) |w| if (!isFloat(w)) while (!is(try lx.next(), "TABLEENTRIES")) {};
            try lx.skipStatement();
        } else if (!is(word, ";")) try lx.skipStatement();
    }
}

/// Whether Rust's `str::parse::<f64>` reads `text`: a decimal, `inf` or
/// `nan`, no hex and no `_`.
fn isFloat(text: []const u8) bool {
    if (std.mem.indexOfAny(u8, text, "_xXpP") != null) return false;
    _ = std.fmt.parseFloat(f64, text) catch return false;
    return true;
}

/// A `VIA` after its keyword, through `END name`: its fixed shapes or a
/// generated via's rule.
fn via(arena: Allocator, lx: *Lexer, dbu: i64) Error!NamedVia {
    const name = try lx.next();
    _ = lx.eat("DEFAULT");
    var shapes: std.ArrayList(Shape) = .empty;
    var rule: ?ViaRule = null;
    var on: []const u8 = "";
    while (true) {
        const word = try lx.next();
        if (is(word, "END")) {
            try lx.expect(name);
            break;
        } else if (is(word, "LAYER")) {
            on = try lx.next();
            try lx.skipStatement();
        } else if (is(word, "RECT") or is(word, "POLYGON")) {
            try shapes.append(arena, try geometry(arena, lx, dbu, on, word));
        } else if (is(word, "VIARULE")) {
            _ = try lx.next();
            try lx.expect(";");
            rule = .{};
        } else if (is(word, "PATTERN")) {
            const r = if (rule) |*r| r else return lx.fail("PATTERN without VIARULE", .{});
            r.pattern = try lx.next();
            _ = lx.eat(";");
        } else if (std.meta.stringToEnum(enum { CUTSIZE, CUTSPACING, ROWCOL, ORIGIN, ENCLOSURE, OFFSET, LAYERS }, word)) |key| {
            const r = if (rule) |*r| r else return lx.fail("via rule data without VIARULE", .{});
            switch (key) {
                .LAYERS => for (&r.layers) |*slot| {
                    slot.* = try lx.next();
                },
                .ENCLOSURE, .OFFSET => {
                    var v: [4]i64 = undefined;
                    for (&v) |*slot| slot.* = try lx.microns(dbu);
                    if (key == .ENCLOSURE) r.enclosure = v else r.offset = v;
                },
                .ROWCOL => r.rowcol = .{ try lx.int(), try lx.int() },
                .CUTSIZE => r.cut = .{ try lx.microns(dbu), try lx.microns(dbu) },
                .CUTSPACING => r.spacing = .{ try lx.microns(dbu), try lx.microns(dbu) },
                .ORIGIN => r.origin = .{ try lx.microns(dbu), try lx.microns(dbu) },
            }
            try lx.expect(";");
        } else try lx.skipStatement();
    }
    try generated(arena, lx, rule, &shapes);
    return .{ .name = name, .shapes = shapes.items };
}

/// `RECT [MASK n] pt pt ;` or `POLYGON [MASK n] pt pt pt … ;` on `on`.
fn geometry(arena: Allocator, lx: *Lexer, dbu: i64, on: []const u8, word: []const u8) Error!Shape {
    if (on.len == 0) return lx.fail("{s} before any LAYER", .{word});
    try mask(lx);
    var points: std.ArrayList(Pt) = .empty;
    while (lx.peek() == null or !is(lx.peek().?, ";")) try points.append(arena, try point(lx, dbu));
    try lx.expect(";");
    if (is(word, "RECT")) {
        if (points.items.len != 2) return lx.fail("a RECT has two points", .{});
        return Shape.rect(arena, on, points.items[0], points.items[1]);
    }
    if (points.items.len < 3) return lx.fail("a POLYGON has at least three points", .{});
    return .{ .layer = on, .ring = points.items };
}

/// A LEF point, `x y` in micrometres, bracketed or not.
fn point(lx: *Lexer, dbu: i64) Error!Pt {
    const bracketed = lx.eat("(");
    const at: Pt = .{ try lx.microns(dbu), try lx.microns(dbu) };
    if (bracketed) try lx.expect(")");
    return at;
}

/// Skips a `MASK n`, and refuses `ITERATE` geometry.
fn mask(lx: *Lexer) Error!void {
    if (lx.eat("MASK")) _ = try lx.next();
    if (lx.peek()) |w| if (is(w, "ITERATE")) return lx.fail("ITERATE geometry is not read", .{});
}

/// `LAYER`/`RECT`/`POLYGON`/`VIA` statements up to `END`.
fn geometries(arena: Allocator, lx: *Lexer, dbu: i64, shapes: *std.ArrayList(Shape), vias: *std.ArrayList(ViaPoint)) Error!void {
    var on: []const u8 = "";
    while (true) {
        const word = try lx.next();
        if (is(word, "END")) {
            return;
        } else if (is(word, "LAYER")) {
            on = try lx.next();
            try lx.skipStatement();
        } else if (is(word, "RECT") or is(word, "POLYGON")) {
            try shapes.append(arena, try geometry(arena, lx, dbu, on, word));
        } else if (is(word, "VIA")) {
            try mask(lx);
            const at = try point(lx, dbu);
            try vias.append(arena, .{ .name = try lx.next(), .at = at });
            try lx.expect(";");
        } else if (is(word, "PATH")) {
            return lx.fail("PATH geometry is not read", .{});
        } else if (!is(word, ";")) try lx.skipStatement();
    }
}

fn macro(arena: Allocator, lx: *Lexer, dbu: i64) Error!Macro {
    const name = try lx.next();
    var out: Macro = .{ .name = name };
    var edge_types: std.ArrayList(EdgeType) = .empty;
    var pins: std.ArrayList(MacroPin) = .empty;
    var obs: std.ArrayList(Shape) = .empty;
    var obs_vias: std.ArrayList(ViaPoint) = .empty;
    while (true) {
        const word = try lx.next();
        if (is(word, "END")) {
            try lx.expect(name);
            break;
        } else if (is(word, "CLASS")) {
            out.class = try lx.next();
            out.spacer = is(out.class, "CORE") and lx.peek() != null and is(lx.peek().?, "SPACER");
            try lx.skipStatement();
        } else if (is(word, "PROPERTY")) {
            while (true) {
                const key = try lx.next();
                if (is(key, ";")) break;
                const value = try lx.next();
                if (is(key, "LEF58_EDGETYPE")) try props.edgeTypes(arena, lx, dbu, value, &edge_types);
            }
        } else if (is(word, "ORIGIN")) {
            out.origin = try point(lx, dbu);
            try lx.expect(";");
        } else if (is(word, "SIZE")) {
            const w = try lx.microns(dbu);
            try lx.expect("BY");
            out.size = .{ w, try lx.microns(dbu) };
            try lx.expect(";");
        } else if (is(word, "PIN")) {
            try pins.append(arena, try pin(arena, lx, dbu));
        } else if (is(word, "OBS")) {
            try geometries(arena, lx, dbu, &obs, &obs_vias);
        } else if (is(word, "DENSITY")) {
            // `DENSITY LAYER l ; RECT … value ; … END`.
            while (!is(try lx.next(), "END")) {}
        } else if (!is(word, ";")) try lx.skipStatement();
    }
    out.edge_types = edge_types.items;
    out.pins = pins.items;
    out.obs = obs.items;
    out.obs_vias = obs_vias.items;
    return out;
}

fn pin(arena: Allocator, lx: *Lexer, dbu: i64) Error!MacroPin {
    const name = try lx.next();
    var shapes: std.ArrayList(Shape) = .empty;
    var vias: std.ArrayList(ViaPoint) = .empty;
    var antenna: std.ArrayList(PinAntenna) = .empty;
    var oxide1 = true;
    while (true) {
        const word = try lx.next();
        if (antenna_words.get(word)) |kind| {
            const statement = try antennaStatement(lx, kind);
            // The oxide model governs gate areas and ratios only.
            const modelled = switch (kind) {
                .partial_metal, .partial_metal_side, .partial_cut, .diff => false,
                .gate, .max_area_car, .max_side_area_car, .max_cut_car => true,
            };
            if (oxide1 or !modelled) {
                var k: usize = 0;
                while (k < antenna.items.len) {
                    const a = antenna.items[k];
                    if (a.kind == kind and sameLayer(a.layer, statement.layer)) _ = antenna.orderedRemove(k) else k += 1;
                }
                try antenna.append(arena, statement);
            }
        } else if (is(word, "END")) {
            try lx.expect(name);
            break;
        } else if (is(word, "ANTENNAMODEL")) {
            oxide1 = is(try lx.next(), "OXIDE1");
            try lx.expect(";");
        } else if (is(word, "PORT")) {
            try geometries(arena, lx, dbu, &shapes, &vias);
        } else if (!is(word, ";")) try lx.skipStatement();
    }
    return .{ .name = name, .shapes = shapes.items, .vias = vias.items, .antenna = antenna.items };
}

fn sameLayer(a: ?[]const u8, b: ?[]const u8) bool {
    if (a == null or b == null) return a == null and b == null;
    return is(a.?, b.?);
}

/// An antenna statement's `value [LAYER name] ;`; a ratio names its `LAYER`.
fn antennaStatement(lx: *Lexer, kind: AntennaKind) Error!PinAntenna {
    const text = try lx.next();
    const value = if (isFloat(text)) std.fmt.parseFloat(f64, text) catch unreachable else std.math.nan(f64);
    if (!(std.math.isFinite(value) and value >= 0)) return lx.fail("antenna value {s} is not a number of zero or more", .{text});
    const on: ?[]const u8 = if (lx.eat("LAYER")) try lx.next() else null;
    const ratio = kind == .max_area_car or kind == .max_side_area_car or kind == .max_cut_car;
    if (ratio and on == null) return lx.fail("an ANTENNAMAX*CAR statement names its LAYER", .{});
    try lx.expect(";");
    return .{ .kind = kind, .value = value, .layer = on };
}
