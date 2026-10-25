//! The DEF reader: a design's die, rows, tracks, vias, components, pins,
//! nets and fill, in its own database units (LEF/DEF 5.8 Language
//! Reference). In: DEF text and its LEF library. Out: a `Def`, its lists in
//! the arena given. Nets and the item grammar are def_net.zig's. Ported from
//! crates/ingest/src/lefdef/def.rs.
//!
//! Contents:
//! - `pub const Row`, `pub const Track`, `pub const Placement`, `pub const Component`, `pub const ViaAt`,
//!   `ViaAt.one(name: []const u8, at: Pt, orient: Orient) ViaAt`, `pub const DefPin`,
//!   `pub const Wire`, `Wire.rect(w: Wire) [2]Pt`, `pub const Net`, `pub const Def`
//! - `pub fn defUnits(arena: Allocator, text: []const u8, diag: *Diagnostic) Error!i64`
//! - `pub fn readDef(arena: Allocator, text: []const u8, lef: *const Lef, diag: *Diagnostic) Error!Def`

const std = @import("std");
const Allocator = std.mem.Allocator;
const lex = @import("lefdef_lex.zig");
const Lexer = lex.Lexer;
const Error = lex.Error;
const Diagnostic = lex.Diagnostic;
const Pt = lex.Pt;
const lefdef = @import("lefdef.zig");
const Shape = lefdef.Shape;
const Orient = lefdef.Orient;
const ViaRule = lefdef.ViaRule;
const NamedVia = lefdef.NamedVia;
const lef_file = @import("lef.zig");
const Lef = lef_file.Lef;
const Ndr = lef_file.Ndr;
const LayerWidth = lef_file.LayerWidth;
const items = @import("def_net.zig");

/// One `ROW`: `num` sites of `site` from `origin`, `step` apart.
pub const Row = struct {
    name: []const u8,
    /// The LEF `SITE` it is made of.
    site: []const u8,
    /// The first site's placement point.
    origin: Pt,
    orient: Orient,
    /// `DO numX BY numY`; `{1, 1}` when absent.
    num: Pt = .{ 1, 1 },
    /// `STEP stepX stepY`; `{0, 0}` when absent.
    step: Pt = .{ 0, 0 },
};

/// One `TRACKS` statement.
pub const Track = struct {
    /// `X`: tracks at x positions (vertical wires); `Y`: at y positions.
    x: bool,
    start: i64,
    count: i64,
    step: i64,
    layers: []const []const u8,
};

/// `PLACED`, `FIXED` or `COVER`: where and how.
pub const Placement = struct { at: Pt, orient: Orient };

/// One `COMPONENTS` entry: the instance, the LEF macro it places, and where;
/// null when unplaced.
pub const Component = struct { name: []const u8, model: []const u8, placement: ?Placement };

/// A via placed in wiring, a pin or fill: its definition's shapes turned by
/// `orient` and moved to `at`, `array[0] × array[1]` times `array[2],
/// array[3]` apart (`DO … STEP …`).
pub const ViaAt = struct {
    name: []const u8,
    at: Pt,
    orient: Orient,
    array: [4]i64 = .{ 1, 1, 0, 0 },

    /// One via, not an array.
    pub fn one(name: []const u8, at: Pt, orient: Orient) ViaAt {
        return .{ .name = name, .at = at, .orient = orient };
    }
};

/// One `PINS` entry, its shapes already placed. A port with no placement
/// has no shapes (5.8: "the PINS statement describes logical pins, without
/// placement or physical information").
pub const DefPin = struct {
    name: []const u8,
    net: []const u8,
    shapes: []const Shape,
    vias: []const ViaAt,
};

/// One wire segment of a net's routing, centre line and rule resolved: from
/// `from` to `to` (horizontal or vertical), `width` wide, running
/// `from_ext` past `from` and `to_ext` past `to`.
pub const Wire = struct {
    layer: []const u8,
    width: i64,
    from: Pt,
    to: Pt,
    from_ext: i64,
    to_ext: i64,

    /// The rectangle the segment draws, `{lower-left, upper-right}`.
    pub fn rect(w: Wire) [2]Pt {
        const a = w.from;
        const b = w.to;
        const half = @divTrunc(w.width, 2);
        const forward = a[0] < b[0] or (a[0] == b[0] and a[1] <= b[1]);
        const lo_ext = if (forward) w.from_ext else w.to_ext;
        const hi_ext = if (forward) w.to_ext else w.from_ext;
        const lo: Pt = .{ @min(a[0], b[0]), @min(a[1], b[1]) };
        const hi: Pt = .{ @max(a[0], b[0]), @max(a[1], b[1]) };
        if (a[0] == b[0]) return .{ .{ lo[0] - half, lo[1] - lo_ext }, .{ lo[0] + w.width - half, hi[1] + hi_ext } };
        return .{ .{ lo[0] - lo_ext, lo[1] - half }, .{ hi[0] + hi_ext, lo[1] + w.width - half } };
    }
};

/// One `NETS` or `SPECIALNETS` entry.
pub const Net = struct {
    name: []const u8,
    /// From `SPECIALNETS`.
    special: bool,
    /// `( comp pin )` connections; `comp` is `*` for every component and
    /// `PIN` for a DEF pin.
    connections: []const [2][]const u8,
    wires: []const Wire,
    /// The vias in its wiring, and a special net's `VIA` statements.
    vias: []const ViaAt,
    /// A special net's `RECT` and `POLYGON` shapes, and every wiring `RECT`.
    shapes: []const Shape,
};

/// One DEF file.
pub const Def = struct {
    design: []const u8 = "",
    /// `UNITS DISTANCE MICRONS`: database units per micrometre.
    dbu: i64 = 0,
    /// `DIEAREA` as a ring (two points become the rectangle's four).
    die_area: []const Pt = &.{},
    rows: []const Row = &.{},
    tracks: []const Track = &.{},
    /// The `VIAS` section's vias, each its shapes about its origin.
    vias: []const NamedVia = &.{},
    components: []const Component = &.{},
    pins: []const DefPin = &.{},
    /// Every net, special and regular, in file order.
    nets: []const Net = &.{},
    fills: []const Shape = &.{},
    fill_vias: []const ViaAt = &.{},
};

/// The database units per micrometre a DEF states (`UNITS DISTANCE MICRONS
/// n`), which its LEFs are read at. Refuses no `UNITS` statement and a value
/// that is not a positive integer.
pub fn defUnits(arena: Allocator, text: []const u8, diag: *Diagnostic) Error!i64 {
    var lx: Lexer = try .init(arena, text, "DEF", diag);
    while (lx.peek()) |word| {
        _ = try lx.next();
        if (!is(word, "UNITS")) continue;
        try lx.expect("DISTANCE");
        try lx.expect("MICRONS");
        const units = try lx.int();
        if (units <= 0) return lx.fail("UNITS DISTANCE MICRONS must be positive", .{});
        return units;
    }
    diag.set("DEF", 0, "no UNITS DISTANCE MICRONS statement", .{});
    return error.Invalid;
}

/// Reads a DEF against its LEF library, read at `defUnits`: the LEF gives a
/// regular wire's width and the layers a via joins. Refuses a malformed
/// statement, a construct lefdef.zig lists as refused, a name used before it
/// is defined, and a missing `UNITS`.
pub fn readDef(arena: Allocator, text: []const u8, lef: *const Lef, diag: *Diagnostic) Error!Def {
    var lx: Lexer = try .init(arena, text, "DEF", diag);
    var def: Def = .{};
    var die_area: std.ArrayList(Pt) = .empty;
    var rows: std.ArrayList(Row) = .empty;
    var tracks: std.ArrayList(Track) = .empty;
    var vias: std.ArrayList(NamedVia) = .empty;
    var ndrs: std.ArrayList(Ndr) = .empty;
    var components: std.ArrayList(Component) = .empty;
    var pins: std.ArrayList(DefPin) = .empty;
    var nets: std.ArrayList(Net) = .empty;
    var fills: std.ArrayList(Shape) = .empty;
    var fill_vias: std.ArrayList(ViaAt) = .empty;
    while (lx.peek()) |word| {
        _ = try lx.next();
        if (is(word, "DESIGN")) {
            def.design = try lx.next();
            try lx.expect(";");
        } else if (is(word, "UNITS")) {
            try lx.expect("DISTANCE");
            try lx.expect("MICRONS");
            def.dbu = try lx.int();
            try lx.expect(";");
        } else if (is(word, "DIEAREA")) {
            var prev: ?Pt = null;
            while (peekIs(&lx, "(")) {
                const p = try lx.point(prev);
                try die_area.append(arena, p);
                prev = p;
            }
            try lx.expect(";");
            if (die_area.items.len == 2) {
                const r = try Shape.rect(arena, "", die_area.items[0], die_area.items[1]);
                die_area.clearRetainingCapacity();
                try die_area.appendSlice(arena, r.ring);
            } else if (die_area.items.len < 3) return lx.fail("DIEAREA has two points or a polygon of three or more", .{});
        } else if (is(word, "ROW")) {
            try rows.append(arena, try row(&lx));
        } else if (is(word, "TRACKS")) {
            try tracks.append(arena, try track(arena, &lx));
        } else if (is(word, "VIAS")) {
            try items.sectionStart(&lx);
            while (try items.sectionItem(&lx, "VIAS")) {
                const name = try lx.next();
                try vias.append(arena, .{ .name = name, .shapes = try defVia(arena, &lx) });
            }
        } else if (is(word, "NONDEFAULTRULES")) {
            try items.sectionStart(&lx);
            while (try items.sectionItem(&lx, "NONDEFAULTRULES")) {
                const name = try lx.next();
                var widths: std.ArrayList(LayerWidth) = .empty;
                while (!is(try lx.next(), ";")) {
                    if (!lx.eat("LAYER")) continue;
                    const layer = try lx.next();
                    try lx.expect("WIDTH");
                    try widths.append(arena, .{ .layer = layer, .width = try lx.int() });
                }
                try ndrs.append(arena, .{ .name = name, .widths = widths.items });
            }
        } else if (is(word, "COMPONENTS")) {
            try items.sectionStart(&lx);
            while (try items.sectionItem(&lx, "COMPONENTS")) {
                const name = try lx.next();
                const model = try lx.next();
                var placement: ?Placement = null;
                while (try items.nextOption(&lx)) |key| {
                    if (is(key, "PLACED") or is(key, "FIXED") or is(key, "COVER")) {
                        const at = try lx.point(null);
                        placement = .{ .at = at, .orient = try items.orient(&lx) };
                    }
                    try items.skipOption(&lx);
                }
                try components.append(arena, .{ .name = name, .model = model, .placement = placement });
            }
        } else if (is(word, "PINS")) {
            try items.sectionStart(&lx);
            while (try items.sectionItem(&lx, "PINS")) try pins.append(arena, try pin(arena, &lx, vias.items, lef));
        } else if (is(word, "NETS") or is(word, "SPECIALNETS")) {
            try items.sectionStart(&lx);
            while (try items.sectionItem(&lx, word)) try nets.append(arena, try items.net(arena, &lx, is(word, "SPECIALNETS"), vias.items, ndrs.items, lef));
        } else if (is(word, "FILLS")) {
            try items.sectionStart(&lx);
            while (try items.sectionItem(&lx, "FILLS")) try fill(arena, &lx, &fills, &fill_vias);
        } else if (is(word, "BEGINEXT")) {
            while (!is(try lx.next(), "ENDEXT")) {}
        } else if (for ([_][]const u8{ "PROPERTYDEFINITIONS", "REGIONS", "GROUPS", "SCANCHAINS", "BLOCKAGES", "PINPROPERTIES", "SLOTS", "STYLES", "GCELLGRIDS" }) |s| {
            if (is(word, s)) break true;
        } else false) {
            try lx.skipToEnd(word);
        } else if (is(word, "END")) {
            try lx.expect("DESIGN");
            break;
        } else try lx.skipStatement();
    }
    if (def.dbu <= 0) {
        diag.set("DEF", 0, "no positive UNITS DISTANCE MICRONS", .{});
        return error.Invalid;
    }
    def.die_area = die_area.items;
    def.rows = rows.items;
    def.tracks = tracks.items;
    def.vias = vias.items;
    def.components = components.items;
    def.pins = pins.items;
    def.nets = nets.items;
    def.fills = fills.items;
    def.fill_vias = fill_vias.items;
    return def;
}

// ---- private ----

fn is(a: []const u8, b: []const u8) bool {
    return std.mem.eql(u8, a, b);
}

fn peekIs(lx: *const Lexer, word: []const u8) bool {
    return if (lx.peek()) |p| is(p, word) else false;
}

fn fill(arena: Allocator, lx: *Lexer, fills: *std.ArrayList(Shape), fill_vias: *std.ArrayList(ViaAt)) Error!void {
    if (lx.eat("VIA")) {
        const name = try lx.next();
        try items.plusOptions(lx);
        while (peekIs(lx, "(")) try fill_vias.append(arena, .one(name, try lx.point(null), .N));
        return lx.expect(";");
    }
    try lx.expect("LAYER");
    const layer = try lx.next();
    try items.plusOptions(lx);
    while (true) {
        const kind = try lx.next();
        if (is(kind, ";")) return;
        if (!is(kind, "RECT") and !is(kind, "POLYGON")) return lx.fail("unexpected {s} in a fill", .{kind});
        try fills.append(arena, try items.shape(arena, lx, layer, is(kind, "RECT")));
    }
}

fn row(lx: *Lexer) Error!Row {
    const name = try lx.next();
    const site = try lx.next();
    const origin: Pt = .{ try lx.int(), try lx.int() };
    var out: Row = .{ .name = name, .site = site, .origin = origin, .orient = try items.orient(lx) };
    if (lx.eat("DO")) {
        out.num[0] = try lx.int();
        try lx.expect("BY");
        out.num[1] = try lx.int();
        if (lx.eat("STEP")) out.step = .{ try lx.int(), try lx.int() };
    }
    try lx.skipStatement();
    return out;
}

fn track(arena: Allocator, lx: *Lexer) Error!Track {
    const axis = try lx.next();
    if (!is(axis, "X") and !is(axis, "Y")) return lx.fail("TRACKS takes X or Y, not {s}", .{axis});
    const start = try lx.int();
    try lx.expect("DO");
    const count = try lx.int();
    try lx.expect("STEP");
    const step = try lx.int();
    var layers: std.ArrayList([]const u8) = .empty;
    while (true) {
        const word = try lx.next();
        if (is(word, ";")) {
            break;
        } else if (is(word, "MASK")) {
            _ = try lx.next();
            _ = lx.eat("SAMEMASK");
        } else if (is(word, "LAYER")) {
            while (lx.peek() != null and !peekIs(lx, ";")) try layers.append(arena, try lx.next());
        } else return lx.fail("unexpected {s} in TRACKS", .{word});
    }
    return .{ .x = is(axis, "X"), .start = start, .count = count, .step = step, .layers = layers.items };
}

/// A `VIAS` item after its name: `+ RECT`/`+ POLYGON` shapes, or a
/// generated via's `+ VIARULE` parameters.
fn defVia(arena: Allocator, lx: *Lexer) Error![]const Shape {
    var shapes: std.ArrayList(Shape) = .empty;
    var rule: ?ViaRule = null;
    while (true) {
        const sep = try lx.next();
        if (is(sep, ";")) break;
        if (!is(sep, "+")) return lx.fail("expected + or ;, found {s}", .{sep});
        const key = try lx.next();
        if (is(key, "RECT") or is(key, "POLYGON")) {
            const layer = try lx.next();
            if (peekIs(lx, "+")) {
                _ = try lx.next();
                try lx.expect("MASK");
                _ = try lx.next();
            }
            try shapes.append(arena, try items.shape(arena, lx, layer, is(key, "RECT")));
        } else if (is(key, "VIARULE")) {
            _ = try lx.next();
            rule = .{};
        } else if (is(key, "PATTERNNAME")) {
            _ = try lx.next(); // The name of the pattern a fixed via was made from (5.6).
        } else {
            const r = if (rule) |*r| r else return lx.fail("{s} without VIARULE", .{key});
            if (is(key, "PATTERN")) {
                r.pattern = try lx.next();
            } else if (is(key, "CUTSIZE")) {
                r.cut = .{ try lx.int(), try lx.int() };
            } else if (is(key, "CUTSPACING")) {
                r.spacing = .{ try lx.int(), try lx.int() };
            } else if (is(key, "ROWCOL")) {
                r.rowcol = .{ try lx.int(), try lx.int() };
            } else if (is(key, "ORIGIN")) {
                r.origin = .{ try lx.int(), try lx.int() };
            } else if (is(key, "LAYERS")) {
                for (&r.layers) |*slot| slot.* = try lx.next();
            } else if (is(key, "ENCLOSURE") or is(key, "OFFSET")) {
                var v: [4]i64 = undefined;
                for (&v) |*slot| slot.* = try lx.int();
                if (is(key, "ENCLOSURE")) r.enclosure = v else r.offset = v;
            } else return lx.fail("unexpected {s} in a via", .{key});
        }
    }
    try lef_file.generated(arena, lx, rule, &shapes);
    return shapes.items;
}

/// One `PINS` item: each port's shapes and vias, given about its placement,
/// turned and moved when the next port starts or the item ends.
fn pin(arena: Allocator, lx: *Lexer, vias: []const NamedVia, lef: *const Lef) Error!DefPin {
    const name = try lx.next();
    var net: []const u8 = "";
    var shapes: std.ArrayList(Shape) = .empty;
    var placed_vias: std.ArrayList(ViaAt) = .empty;
    var port_shapes: std.ArrayList(Shape) = .empty;
    var port_vias: std.ArrayList(ViaAt) = .empty;
    var placed: ?Placement = null;
    while (try items.nextOption(lx)) |key| {
        if (is(key, "NET")) {
            net = try lx.next();
        } else if (is(key, "PORT")) {
            try closePort(arena, &port_shapes, &port_vias, placed, &shapes, &placed_vias);
            placed = null;
        } else if (is(key, "LAYER") or is(key, "POLYGON")) {
            const layer = try lx.next();
            while (peekIs(lx, "MASK") or peekIs(lx, "SPACING") or peekIs(lx, "DESIGNRULEWIDTH")) {
                _ = try lx.next();
                _ = try lx.next();
            }
            try port_shapes.append(arena, try items.shape(arena, lx, layer, is(key, "LAYER")));
        } else if (is(key, "VIA")) {
            const via = try lx.next();
            _ = try items.knownVia(lx, via, vias, lef);
            if (lx.eat("MASK")) _ = try lx.next();
            try port_vias.append(arena, .one(via, try lx.point(null), .N));
        } else if (is(key, "PLACED") or is(key, "FIXED") or is(key, "COVER")) {
            const at = try lx.point(null);
            placed = .{ .at = at, .orient = try items.orient(lx) };
        }
        try items.skipOption(lx);
    }
    try closePort(arena, &port_shapes, &port_vias, placed, &shapes, &placed_vias);
    if (net.len == 0) return lx.fail("pin {s} has no + NET", .{name});
    return .{ .name = name, .net = net, .shapes = shapes.items, .vias = placed_vias.items };
}

/// Moves a finished port's shapes and vias to its placement, or drops them
/// when it has none.
fn closePort(arena: Allocator, port_shapes: *std.ArrayList(Shape), port_vias: *std.ArrayList(ViaAt), placed: ?Placement, shapes: *std.ArrayList(Shape), vias: *std.ArrayList(ViaAt)) Allocator.Error!void {
    defer port_shapes.clearRetainingCapacity();
    defer port_vias.clearRetainingCapacity();
    const p = placed orelse return;
    for (port_shapes.items) |s| try shapes.append(arena, try s.moved(arena, p.orient, p.at));
    for (port_vias.items) |v| {
        const t = p.orient.apply(v.at);
        var moved = v;
        moved.at = .{ t[0] + p.at[0], t[1] + p.at[1] };
        try vias.append(arena, moved);
    }
}
