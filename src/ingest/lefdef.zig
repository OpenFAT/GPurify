//! LEF and DEF: a placed-and-routed design as its library and its layout.
//! In: LEF text (layers, vias, cell abstracts) and DEF text (die area, rows,
//! tracks, components, pins, routed nets, fill). Out: `Lef` and `Def` as
//! written, `flatten`'s flat shapes on LEF layer names each with its net, and
//! `toGds`'s GDSII stream of them on a deck's layers. Source: the LEF/DEF 5.8
//! Language Reference (Cadence, May 2017); what the Rust module's table lists
//! as skipped is skipped by its grammar, never guessed at, and what it lists
//! as refused (a LEF `PATH` or `ITERATE`, a wire `STYLE` or 45-degree
//! segment, `SHIELD` wiring, a `SUBNET`, a regular wire on a layer with no
//! `WIDTH`, a name used before it is defined, a length between two database
//! units, a coordinate past 32 bits) is refused with its line. Names are the
//! file's text, matched as text. Ported from crates/ingest/src/lefdef/mod.rs.
//!
//! Geometry: a wire runs between two routing points at its rule's width,
//! each end extended by the point's `extValue`, else half the width (regular)
//! or 0 (special) (pp. 268, 321). A component's macro is shifted by its
//! `ORIGIN`, turned, and placed so its turned `SIZE` box's lower-left corner
//! lands on the placement point (pp. 244, 122). Orientations are
//! OpenAccess's: `N` R0, `S` R180, `W` R90, `E` R270, `FN` MY, `FS` MX, `FW`
//! MX then R90, `FE` MY then R90. A generated via's cut array is centred on
//! its origin, each metal the array grown by its enclosure and moved by its
//! `OFFSET`, all moved by `ORIGIN` (p. 341); a `PATTERN` drops the cuts it
//! marks absent (pp. 349-351).
//!
//! Contents:
//! - `pub const Error`, `pub const Diagnostic`, `pub const Pt` (lefdef_lex.zig)
//! - `pub const Shape`, `Shape.rect(arena: Allocator, layer: []const u8, a: Pt, b: Pt) Allocator.Error!Shape`,
//!   `Shape.bbox(s: Shape) [4]i64`, `Shape.moved(s: Shape, arena: Allocator, orient: Orient, at: Pt) Allocator.Error!Shape`
//! - `pub const Orient`, `Orient.parse(text: []const u8) ?Orient`, `Orient.apply(o: Orient, p: Pt) Pt`
//! - `pub const Origin`, `pub const FlatShape`, `pub const Design`, `pub const NamedVia`
//! - `pub const ViaRule`, `ViaRule.cuts(r: *const ViaRule, arena: Allocator) Allocator.Error!?[]const bool`,
//!   `ViaRule.shapes(r: *const ViaRule, arena: Allocator, out: *std.ArrayList(Shape)) Allocator.Error!void`
//! - `pub fn flatten(arena: Allocator, def: *const Def, lef: *const Lef, diag: *Diagnostic) Error![]const FlatShape`
//! - re-exported: `Lef`, `LefLayer`, `LayerKind`, `Macro`, `MacroPin`, `PinAntenna`, `AntennaKind`,
//!   `CellEdgeSpacing`, `EdgeSide`, `EdgeSpan`, `EdgeType`, `readLefInto` (lef.zig);
//!   `Def`, `Row`, `Track`, `Component`, `ViaAt`, `DefPin`, `Wire`, `Net`, `defUnits`, `readDef` (def.zig);
//!   `toGds` (lefdef_gds.zig); `exactUnits` (lefdef_lex.zig)

const std = @import("std");
const Allocator = std.mem.Allocator;
const lex = @import("lefdef_lex.zig");
const lef_file = @import("lef.zig");
const def_file = @import("def.zig");
const gds_out = @import("lefdef_gds.zig");

pub const Error = lex.Error;

pub const Diagnostic = lex.Diagnostic;

pub const Pt = lex.Pt;

pub const exactUnits = lex.exactUnits;

pub const Lef = lef_file.Lef;

pub const LefLayer = lef_file.LefLayer;

pub const LayerKind = lef_file.LayerKind;

pub const Macro = lef_file.Macro;

pub const MacroPin = lef_file.MacroPin;

pub const PinAntenna = lef_file.PinAntenna;

pub const AntennaKind = lef_file.AntennaKind;

pub const CellEdgeSpacing = lef_file.CellEdgeSpacing;

pub const EdgeSide = lef_file.EdgeSide;

pub const EdgeSpan = lef_file.EdgeSpan;

pub const EdgeType = lef_file.EdgeType;

pub const readLefInto = lef_file.readLefInto;

pub const Def = def_file.Def;

pub const Row = def_file.Row;

pub const Track = def_file.Track;

pub const Component = def_file.Component;

pub const ViaAt = def_file.ViaAt;

pub const DefPin = def_file.DefPin;

pub const Wire = def_file.Wire;

pub const Net = def_file.Net;

pub const defUnits = def_file.defUnits;

pub const readDef = def_file.readDef;

pub const toGds = gds_out.toGds;

/// A closed polygon on one LEF layer, its ring without the repeated first
/// point, in database units, in the order written (a rectangle
/// counter-clockwise from its lower-left corner).
pub const Shape = struct {
    layer: []const u8,
    ring: []const Pt,

    /// The rectangle with corners `a` and `b`, either order.
    pub fn rect(arena: Allocator, layer: []const u8, a: Pt, b: Pt) Allocator.Error!Shape {
        const x0 = @min(a[0], b[0]);
        const x1 = @max(a[0], b[0]);
        const y0 = @min(a[1], b[1]);
        const y1 = @max(a[1], b[1]);
        return .{ .layer = layer, .ring = try arena.dupe(Pt, &.{ .{ x0, y0 }, .{ x1, y0 }, .{ x1, y1 }, .{ x0, y1 } }) };
    }

    /// The bounding box `{xlo, ylo, xhi, yhi}`.
    pub fn bbox(s: Shape) [4]i64 {
        var out: [4]i64 = .{ std.math.maxInt(i64), std.math.maxInt(i64), std.math.minInt(i64), std.math.minInt(i64) };
        for (s.ring) |p| out = .{ @min(out[0], p[0]), @min(out[1], p[1]), @max(out[2], p[0]), @max(out[3], p[1]) };
        return out;
    }

    /// Turned about the origin by `orient`, then moved by `at`.
    pub fn moved(s: Shape, arena: Allocator, orient: Orient, at: Pt) Allocator.Error!Shape {
        const ring = try arena.alloc(Pt, s.ring.len);
        for (s.ring, ring) |p, *q| {
            const t = orient.apply(p);
            q.* = .{ t[0] + at[0], t[1] + at[1] };
        }
        return .{ .layer = s.layer, .ring = ring };
    }
};

/// A DEF orientation (5.8 p. 244).
pub const Orient = enum(u8) {
    /// R0.
    N,
    /// R180.
    S,
    /// R90.
    W,
    /// R270.
    E,
    /// MY.
    FN,
    /// MX.
    FS,
    /// MX then R90.
    FW,
    /// MY then R90.
    FE,

    pub fn parse(text: []const u8) ?Orient {
        return std.meta.stringToEnum(Orient, text);
    }

    /// The point turned about the origin, as OpenAccess (and OpenDB's
    /// `dbTransform`) turns it: R90 takes `(x, y)` to `(−y, x)`.
    pub fn apply(o: Orient, p: Pt) Pt {
        const x = p[0];
        const y = p[1];
        return switch (o) {
            .N => .{ x, y },
            .S => .{ -x, -y },
            .W => .{ -y, x },
            .E => .{ y, -x },
            .FN => .{ -x, y },
            .FS => .{ x, -y },
            .FW => .{ y, x },
            .FE => .{ -y, -x },
        };
    }
};

/// Where a flat shape came from.
pub const Origin = union(enum) {
    /// A net's wiring: a wire, a via in it, or a net `RECT`/`POLYGON`.
    route,
    /// A DEF pin's port, outside every component.
    pin,
    /// A component's macro pin: the component's index, the pin's in its macro.
    macro_pin: [2]u32,
    /// A component's macro obstruction, by component index.
    obstruction: u32,
    /// A `FILLS` shape.
    fill,
};

/// One shape of the flattened design; `net` is null for an obstruction,
/// fill or unconnected macro pin.
pub const FlatShape = struct { shape: Shape, net: ?[]const u8, origin: Origin };

/// A DEF and the LEF library it was read against, in the DEF's units.
pub const Design = struct { def: Def, lef: Lef };

/// A via definition: its name and its shapes about its origin.
pub const NamedVia = struct { name: []const u8, shapes: []const Shape };

/// A generated via (`VIARULE` form), 5.8 p. 341.
pub const ViaRule = struct {
    cut: Pt = .{ 0, 0 },
    /// Bottom metal, cut, top metal.
    layers: [3][]const u8 = .{ "", "", "" },
    spacing: Pt = .{ 0, 0 },
    /// Bottom x, y then top x, y.
    enclosure: [4]i64 = @splat(0),
    rowcol: Pt = .{ 1, 1 },
    origin: Pt = .{ 0, 0 },
    offset: [4]i64 = @splat(0),
    /// `PATTERN`: which cuts of the array are drawn; empty for all.
    pattern: []const u8 = "",

    /// Which cuts of the `rows × cols` array are drawn, row by row from the
    /// bottom, each left to right; null for a malformed `PATTERN`. 5.8
    /// p. 342, pp. 349-351: `numRows_rowDefinition` groups joined by `_`,
    /// `numRows` hexadecimal; a row is hex digits of four cuts each, most
    /// significant leftmost, `R` count digit a repeated digit; bits past the
    /// row's cuts ignored; a `_MR` or `_MC` suffix names a mask pattern only.
    pub fn cuts(r: *const ViaRule, arena: Allocator) Allocator.Error!?[]const bool {
        const rows = std.math.cast(usize, r.rowcol[0]) orelse return null;
        const cols = std.math.cast(usize, r.rowcol[1]) orelse return null;
        const total = std.math.mul(usize, rows, cols) catch return null;
        if (r.pattern.len == 0) {
            const all = try arena.alloc(bool, total);
            @memset(all, true);
            return all;
        }
        var pattern = r.pattern;
        if (std.mem.endsWith(u8, pattern, "_MR") or std.mem.endsWith(u8, pattern, "_MC")) pattern = pattern[0 .. pattern.len - 3];
        const parts = std.mem.count(u8, pattern, "_") + 1;
        if (parts % 2 != 0) return null;
        var out: std.ArrayList(bool) = .empty;
        var split = std.mem.splitScalar(u8, pattern, '_');
        while (split.next()) |count_text| {
            const row_text = split.next().?;
            const count = std.fmt.parseInt(usize, count_text, 16) catch return null;
            var bits: std.ArrayList(bool) = .empty;
            var k: usize = 0;
            while (k < row_text.len) : (k += 1) {
                var times: u32 = 1;
                if (row_text[k] == 'R') {
                    if (k + 2 >= row_text.len) return null;
                    times = std.fmt.charToDigit(row_text[k + 1], 16) catch return null;
                    k += 2;
                }
                const digit = std.fmt.charToDigit(row_text[k], 16) catch return null;
                for (0..times) |_| for (0..4) |b| try bits.append(arena, (digit >> @intCast(3 - b)) & 1 == 1);
            }
            const run = std.math.mul(usize, count, cols) catch return null;
            if (bits.items.len < cols or out.items.len + run > total) return null;
            for (0..count) |_| try out.appendSlice(arena, bits.items[0..cols]);
        }
        return if (out.items.len == total) out.items else null;
    }

    /// The bottom and top metals, then each drawn cut. The rule has passed
    /// the reader's check, so `cuts` decodes.
    pub fn shapes(r: *const ViaRule, arena: Allocator, out: *std.ArrayList(Shape)) Allocator.Error!void {
        const rows = r.rowcol[0];
        const cols = r.rowcol[1];
        const width = cols * r.cut[0] + (cols - 1) * r.spacing[0];
        const height = rows * r.cut[1] + (rows - 1) * r.spacing[1];
        const x0 = -@divTrunc(width, 2);
        const y0 = -@divTrunc(height, 2);
        const o = r.origin;
        for ([_]u2{ 0, 2 }, [_]usize{ 0, 2 }) |layer, side| {
            const ex = r.enclosure[side];
            const ey = r.enclosure[side + 1];
            const dx = r.offset[side] + o[0];
            const dy = r.offset[side + 1] + o[1];
            try out.append(arena, try Shape.rect(arena, r.layers[layer], .{ x0 - ex + dx, y0 - ey + dy }, .{ x0 + width + ex + dx, y0 + height + ey + dy }));
        }
        const present = (try r.cuts(arena)).?;
        for (present, 0..) |here, k| {
            if (!here) continue;
            const row: i64 = @intCast(k / @as(usize, @intCast(cols)));
            const col: i64 = @intCast(k % @as(usize, @intCast(cols)));
            const x = x0 + col * (r.cut[0] + r.spacing[0]) + o[0];
            const y = y0 + row * (r.cut[1] + r.spacing[1]) + o[1];
            try out.append(arena, try Shape.rect(arena, r.layers[1], .{ x, y }, .{ x + r.cut[0], y + r.cut[1] }));
        }
    }
};

/// A macro's placement: shifted by its origin, turned, moved by `shift`.
const Place = struct { origin: Pt, orient: Orient, shift: Pt };

/// `flatten`'s inputs and output list.
const Flatten = struct {
    arena: Allocator,
    def: *const Def,
    lef: *const Lef,
    diag: *Diagnostic,
    out: std.ArrayList(FlatShape) = .empty,

    fn fail(f: *const Flatten, comptime fmt: []const u8, args: anytype) Error {
        f.diag.set("design", 0, fmt, args);
        return error.Invalid;
    }

    /// The shapes of via `name`, the DEF's definition before the LEF's.
    fn viaShapes(f: *const Flatten, name: []const u8) Error![]const Shape {
        for (f.def.vias) |v| if (std.mem.eql(u8, v.name, name)) return v.shapes;
        for (f.lef.vias.items) |v| if (std.mem.eql(u8, v.name, name)) return v.shapes;
        return f.fail("via {s} is defined in no LEF or DEF", .{name});
    }

    fn placeVia(f: *Flatten, via: ViaAt, net: ?[]const u8, origin: Origin) Error!void {
        const shapes = try f.viaShapes(via.name);
        var i: i64 = 0;
        while (i < via.array[0]) : (i += 1) {
            var j: i64 = 0;
            while (j < via.array[1]) : (j += 1) {
                const at: Pt = .{ via.at[0] + i * via.array[2], via.at[1] + j * via.array[3] };
                for (shapes) |shape| try f.out.append(f.arena, .{ .shape = try shape.moved(f.arena, via.orient, at), .net = net, .origin = origin });
            }
        }
    }

    /// Macro shapes and `VIA pt name` statements, placed.
    fn placeAll(f: *Flatten, place: Place, shapes: []const Shape, vias: []const lef_file.ViaPoint, net: ?[]const u8, origin: Origin) Error!void {
        for (shapes) |shape| try f.out.append(f.arena, .{ .shape = try f.placed(place, shape, .{ 0, 0 }), .net = net, .origin = origin });
        for (vias) |via| for (try f.viaShapes(via.name)) |shape| {
            try f.out.append(f.arena, .{ .shape = try f.placed(place, shape, via.at), .net = net, .origin = origin });
        };
    }

    fn placed(f: *const Flatten, place: Place, shape: Shape, at: Pt) Allocator.Error!Shape {
        const shifted = try shape.moved(f.arena, .N, .{ at[0] + place.origin[0], at[1] + place.origin[1] });
        return shifted.moved(f.arena, place.orient, place.shift);
    }
};

/// The design flattened: every pin, placed macro pin and obstruction, wire,
/// via and fill, on LEF layer names, in DEF order (pins, components, nets
/// with special nets first, fills). A macro pin takes the net a DEF net
/// connects to it, `( comp pin )` or `( * pin )`; an unplaced component has
/// no shapes. Refuses a component of a macro no LEF defines and a via no LEF
/// or DEF defines.
pub fn flatten(arena: Allocator, def: *const Def, lef: *const Lef, diag: *Diagnostic) Error![]const FlatShape {
    var f: Flatten = .{ .arena = arena, .def = def, .lef = lef, .diag = diag };
    for (def.pins) |pin| {
        for (pin.shapes) |shape| try f.out.append(arena, .{ .shape = shape, .net = pin.net, .origin = .pin });
        for (pin.vias) |via| try f.placeVia(via, pin.net, .pin);
    }
    // Which net each component pin is on; `( * pin )` binds every component.
    var pin_net: std.StringHashMapUnmanaged([]const u8) = .empty;
    var every_net: std.StringHashMapUnmanaged([]const u8) = .empty;
    for (def.nets) |net| for (net.connections) |c| {
        if (std.mem.eql(u8, c[0], "*")) {
            try every_net.put(arena, c[1], net.name);
        } else {
            try pin_net.put(arena, try std.fmt.allocPrint(arena, "{s}\x00{s}", .{ c[0], c[1] }), net.name);
        }
    };
    for (def.components, 0..) |comp, index| {
        const placement = comp.placement orelse continue;
        const model = for (lef.macros.items) |*m| {
            if (std.mem.eql(u8, m.name, comp.model)) break m;
        } else return f.fail("component {s} is a {s}, which no LEF defines", .{ comp.name, comp.model });
        // Shifted by ORIGIN, turned, then moved so the turned SIZE box's
        // lower-left corner is the placement point.
        const c0 = placement.orient.apply(.{ 0, 0 });
        const c1 = placement.orient.apply(model.size);
        const place: Place = .{ .origin = model.origin, .orient = placement.orient, .shift = .{ placement.at[0] - @min(c0[0], c1[0]), placement.at[1] - @min(c0[1], c1[1]) } };
        const comp_index: u32 = @intCast(index);
        for (model.pins, 0..) |pin, pin_index| {
            const key = try std.fmt.allocPrint(arena, "{s}\x00{s}", .{ comp.name, pin.name });
            const net = pin_net.get(key) orelse every_net.get(pin.name);
            const origin: Origin = .{ .macro_pin = .{ comp_index, @intCast(pin_index) } };
            try f.placeAll(place, pin.shapes, pin.vias, net, origin);
        }
        try f.placeAll(place, model.obs, model.obs_vias, null, .{ .obstruction = comp_index });
    }
    for ([_]bool{ true, false }) |special| for (def.nets) |net| {
        if (net.special != special) continue;
        for (net.wires) |wire| {
            const r = wire.rect();
            // A special wire of width 0 carries only its vias.
            if (r[0][0] < r[1][0] and r[0][1] < r[1][1]) try f.out.append(arena, .{ .shape = try Shape.rect(arena, wire.layer, r[0], r[1]), .net = net.name, .origin = .route });
        }
        for (net.vias) |via| try f.placeVia(via, net.name, .route);
        for (net.shapes) |shape| try f.out.append(arena, .{ .shape = shape, .net = net.name, .origin = .route });
    };
    for (def.fills) |shape| try f.out.append(arena, .{ .shape = shape, .net = null, .origin = .fill });
    for (def.fill_vias) |via| try f.placeVia(via, null, .fill);
    return f.out.items;
}
