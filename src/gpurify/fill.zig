//! Density fill (catalog FLOW-007): `gpurify fill` draws square fill shapes
//! on the deck's fill layer until the density rules hold, as the deck's
//! `fill` lines state them. In: a loaded layout and its deck. Out: per
//! `fill` line, the fill layer and its new squares (`fillInto`), which
//! `fillGds` writes into the layout's GDSII. Ported from src/engine/fill.rs.
//!
//! Sites are a grid of `size` squares at a pitch of `size + space` from the
//! die's lower-left corner, inside the die, each at least `keep` from every
//! shape of the `avoid` layers (square to their merged rectangles, so a
//! corner keeps the distance diagonally as well), `space` from fill already
//! drawn, and on nothing of the density layer. They are taken in rows from
//! the bottom, left to right, each only while a window it lies in is below
//! a `density` or `global_density` minimum on the density layer, and only
//! if no window it lies in then passes that layer's maximum: fill tops each
//! window up to its minimum, never over a maximum. A window it cannot bring
//! up stays short, and the deck's own rule reports it.
//!
//! Contents:
//! - `pub const Filled = struct { layer, squares }`, `pub const Error`, `pub const Diagnostic`
//! - `pub fn fillInto(scratch: Allocator, arena: Allocator, loaded: *const Loaded, out: *std.ArrayList(Filled), diag: *Diagnostic) Error!void`
//! - `pub fn fillGds(gpa: Allocator, arena: Allocator, io: std.Io, dir: std.Io.Dir, inputs: Inputs, decks: []const NamedDeck, counts: *std.ArrayList(u32), diag: *Diagnostic) (Error || load.Error)![]u8`

const std = @import("std");
const Allocator = std.mem.Allocator;
const geom = @import("geom");
const Bbox = geom.Bbox;
const LayerId = geom.LayerId;
const GeometryStore = geom.GeometryStore;
const ValidatedLayer = geom.ValidatedLayer;
const ingest = @import("ingest");
const FillSpec = ingest.deck.FillSpec;
const LimitSense = @import("check").report.LimitSense;
const load_ = @import("load.zig");
const Loaded = load_.Loaded;
const Inputs = load_.Inputs;
const NamedDeck = load_.NamedDeck;

/// One `fill` line's layer and its new squares, row by row from the bottom.
pub const Filled = struct { layer: LayerId, squares: []const Bbox };

/// `NotRectilinear`: a layer a line reads is not rectilinear, is an edge
/// layer or was not computed (fill places rectangles against rectangles);
/// `NoDensityRule`: no density rule measures the line's density layer.
pub const Error = error{ NotRectilinear, NoDensityRule } || Allocator.Error;

/// The line (its fill layer's name) and the layer at fault.
pub const Diagnostic = struct { fill: []const u8 = "", layer: []const u8 = "", load: load_.Diagnostic = .{} };

/// One density rule's windows over a die: a `side_x` by `side_y` window
/// every `stride`, `cols` by `ways` of them (a whole-die rule is one window,
/// the die), each window's covered area and the rule's limit.
const Windows = struct {
    x0: i64,
    y0: i64,
    side_x: i64,
    side_y: i64,
    stride: i64,
    cols: i64,
    ways: i64,
    /// A window's area: `side²` for a swept window, which may hang past the
    /// die and counts the outside as empty (as `density` measures it).
    whole: f64,
    limit: f64,
    sense: LimitSense,
    covered: []i128,

    /// The windows `b` overlaps with positive area: rows, then columns.
    fn under(w: *const Windows, b: Bbox) [2][2]i64 {
        return .{ hit(b.ylo, b.yhi, w.y0, w.side_y, w.stride, w.ways), hit(b.xlo, b.xhi, w.x0, w.side_x, w.stride, w.cols) };
    }

    fn window(w: *const Windows, ix: i64, iy: i64) Bbox {
        const x = w.x0 + ix * w.stride;
        const y = w.y0 + iy * w.stride;
        return .{ .xlo = x, .ylo = y, .xhi = x + w.side_x, .yhi = y + w.side_y };
    }

    fn slot(w: *const Windows, ix: i64, iy: i64) usize {
        return @intCast(iy * w.cols + ix);
    }

    fn add(w: *Windows, b: Bbox) void {
        const u = w.under(b);
        var iy = u[0][0];
        while (iy < u[0][1]) : (iy += 1) {
            var ix = u[1][0];
            while (ix < u[1][1]) : (ix += 1) w.covered[w.slot(ix, iy)] += overlap(b, w.window(ix, iy));
        }
    }

    /// Whether a window `b` overlaps is below this minimum.
    fn wants(w: *const Windows, b: Bbox) bool {
        if (w.sense != .minimum) return false;
        const u = w.under(b);
        var iy = u[0][0];
        while (iy < u[0][1]) : (iy += 1) {
            var ix = u[1][0];
            while (ix < u[1][1]) : (ix += 1) if (w.fraction(w.covered[w.slot(ix, iy)]) < w.limit) return true;
        }
        return false;
    }

    /// Whether adding `b` keeps every window it overlaps within this maximum.
    fn allows(w: *const Windows, b: Bbox) bool {
        if (w.sense == .minimum) return true;
        const u = w.under(b);
        var iy = u[0][0];
        while (iy < u[0][1]) : (iy += 1) {
            var ix = u[1][0];
            while (ix < u[1][1]) : (ix += 1) if (w.fraction(w.covered[w.slot(ix, iy)] + overlap(b, w.window(ix, iy))) > w.limit) return false;
        }
        return true;
    }

    /// As `density` computes it, so a fraction this calls legal the rule does.
    fn fraction(w: *const Windows, covered: i128) f64 {
        return @as(f64, @floatFromInt(covered)) / w.whole;
    }
};

/// The site grid of one fill line: which sites an obstacle blocks.
const Sites = struct {
    x0: i64,
    y0: i64,
    size: i64,
    pitch: i64,
    cols: i64,
    rows: i64,
    blocked: []bool,

    /// Blocks every site within `clear` of `r`.
    fn block(s: Sites, r: Bbox, clear: i64) void {
        const ys = hit(r.ylo - clear, r.yhi + clear, s.y0, s.size, s.pitch, s.rows);
        const xs = hit(r.xlo - clear, r.xhi + clear, s.x0, s.size, s.pitch, s.cols);
        var iy = ys[0];
        while (iy < ys[1]) : (iy += 1) {
            var ix = xs[0];
            while (ix < xs[1]) : (ix += 1) s.blocked[@intCast(iy * s.cols + ix)] = true;
        }
    }
};

/// The fill each of the deck's `fill` lines draws, in deck order, into
/// `out`; squares in `arena`.
pub fn fillInto(scratch: Allocator, arena: Allocator, loaded: *const Loaded, out: *std.ArrayList(Filled), diag: *Diagnostic) Error!void {
    for (loaded.deck.deck.edits.fill.items) |spec| try out.append(arena, try fillOne(scratch, arena, loaded, spec, diag));
}

/// `inputs.layout`'s GDSII with every `fill` line's squares added on its
/// layer's stream pair, as `gpurify fill` writes it (in `arena`), and how
/// many squares each line drew into `counts`.
pub fn fillGds(gpa: Allocator, arena: Allocator, io: std.Io, dir: std.Io.Dir, inputs: Inputs, decks: []const NamedDeck, counts: *std.ArrayList(u32), diag: *Diagnostic) (Error || load_.Error)![]u8 {
    diag.load = .{ .stage = .layout, .path = inputs.layout };
    const bytes = try ingest.gds.readGdsBytes(gpa, io, dir, inputs.layout);
    defer gpa.free(bytes);
    const loaded = try load_.loadBytes(gpa, arena, io, dir, inputs, bytes, decks, &diag.load);
    var scratch: std.heap.ArenaAllocator = .init(gpa);
    defer scratch.deinit();
    var filled: std.ArrayList(Filled) = .empty;
    try fillInto(scratch.allocator(), arena, &loaded, &filled, diag);
    var boxes: std.ArrayList(ingest.layout.StreamBox) = .empty;
    for (filled.items) |f| {
        const pair = loaded.deck.deck.layers.streamOf(f.layer);
        for (f.squares) |b| try boxes.append(scratch.allocator(), .{ .stream = pair, .box = b });
        try counts.append(arena, @intCast(f.squares.len));
    }
    return ingest.layout.withBoxes(arena, bytes, boxes.items, &diag.load.gds);
}

// ---- private ----

/// The indices `i` in `0..n` whose span `origin + i·stride .. + side`
/// overlaps `lo..hi` with positive length, as `[first, end)`.
fn hit(lo: i64, hi: i64, origin: i64, side: i64, stride: i64, n: i64) [2]i64 {
    const first = std.math.clamp(@divFloor(lo - origin - side, stride) + 1, 0, n);
    const last = @min(@divFloor(hi - origin - 1, stride), n - 1);
    return .{ first, @max(last + 1, first) };
}

fn overlap(a: Bbox, b: Bbox) i128 {
    const w = @max(@min(a.xhi, b.xhi) - @max(a.xlo, b.xlo), 0);
    const h = @max(@min(a.yhi, b.yhi) - @max(a.ylo, b.ylo), 0);
    return @as(i128, w) * h;
}

/// `layer` merged and cut into disjoint rectangles; null when it cannot be.
fn rectsOf(scratch: Allocator, loaded: *const Loaded, layer: LayerId) Allocator.Error!?[]const Bbox {
    const store = &loaded.store;
    if (store.isUncomputed(layer) or loaded.deck.deck.layers.isEdges(layer)) return null;
    var drawn: ValidatedLayer = .empty;
    if (try geom.view.validateLayer(scratch, store, layer, .rectilinear, &drawn) != null) return null;
    var merged: ValidatedLayer = .empty;
    try geom.boolean.unionInto(scratch, &drawn, &ValidatedLayer.empty, &merged);
    var out: std.ArrayList(Bbox) = .empty;
    var start: std.ArrayList(u32) = .empty;
    try geom.rects.decomposeInto(scratch, &merged, &out, &start);
    return out.items;
}

fn extentOf(store: *const GeometryStore, first: usize, end: usize) Bbox {
    var out = Bbox.empty;
    for (first..end) |l| for (store.layerBboxes(@fromBackingInt(@as(u16, @intCast(l))))) |b| {
        out = out.merge(b);
    };
    return out;
}

fn fillOne(scratch: Allocator, arena: Allocator, loaded: *const Loaded, spec: FillSpec, diag: *Diagnostic) Error!Filled {
    const store = &loaded.store;
    const deck = &loaded.deck;
    const layers = &deck.deck.layers;
    const layer = layers.id(&loaded.strings, spec.layer).?; // the deck checked its fill layers
    const density = layers.id(&loaded.strings, spec.density).?;
    diag.fill = spec.layer;
    const drawn: usize = if (deck.drc.first_derived) |l| @backingInt(l) else store.layerCount();
    const drawn_extent = extentOf(store, 0, drawn);

    // Every density rule on the layer, its windows over its own die.
    const covered = try read(scratch, loaded, density, diag);
    var rules: std.ArrayList(Windows) = .empty;
    var die = Bbox.empty;
    for (deck.drc.order.items) |slot| {
        const boundary: ?LayerId, const swept: ?[2]i64, const limit: f64, const sense: LimitSense = switch (slot.kind) {
            .density => blk: {
                const r = deck.drc.table(.density).get(slot.row);
                if (r.layer != density) continue;
                break :blk .{ r.boundary, .{ r.window, r.step }, r.limit, r.sense };
            },
            .global_density => blk: {
                const r = deck.drc.table(.global_density).get(slot.row);
                if (r.layer != density) continue;
                break :blk .{ r.boundary, null, r.limit, r.sense };
            },
            else => continue,
        };
        const own = if (boundary) |b| extentOf(store, @backingInt(b), @backingInt(b) + 1) else drawn_extent;
        if (own.isEmpty()) continue;
        die = if (die.isEmpty()) own else (die.intersection(own) orelse Bbox.empty);
        const w = own.xhi - own.xlo;
        const h = own.yhi - own.ylo;
        var windows: Windows = if (swept) |s| .{ .x0 = own.xlo, .y0 = own.ylo, .side_x = s[0], .side_y = s[0], .stride = s[1], .cols = positions(w, s[0], s[1]), .ways = positions(h, s[0], s[1]), .whole = @floatFromInt(@as(i128, s[0]) * s[0]), .limit = limit, .sense = sense, .covered = &.{} } else .{ .x0 = own.xlo, .y0 = own.ylo, .side_x = w, .side_y = h, .stride = @max(w, h, 1), .cols = 1, .ways = 1, .whole = @floatFromInt(@as(i128, w) * h), .limit = limit, .sense = sense, .covered = &.{} };
        windows.covered = try scratch.alloc(i128, @intCast(windows.cols * windows.ways));
        @memset(windows.covered, 0);
        for (covered) |r| if (r.intersection(own)) |inside| windows.add(inside);
        try rules.append(scratch, windows);
    }
    if (rules.items.len == 0) {
        diag.layer = spec.density;
        return error.NoDensityRule;
    }
    if (die.isEmpty()) return .{ .layer = layer, .squares = &.{} };

    // The site grid, and the sites each obstacle blocks.
    const size = spec.size;
    const pitch = spec.size + spec.space;
    const cols = siteCount(die.xhi - die.xlo, size, pitch);
    const rows = siteCount(die.yhi - die.ylo, size, pitch);
    const sites: Sites = .{ .x0 = die.xlo, .y0 = die.ylo, .size = size, .pitch = pitch, .cols = cols, .rows = rows, .blocked = try scratch.alloc(bool, @intCast(cols * rows)) };
    @memset(sites.blocked, false);
    for (spec.avoid) |name| for (try read(scratch, loaded, layers.id(&loaded.strings, name).?, diag)) |r| sites.block(r, spec.keep);
    for (try read(scratch, loaded, layer, diag)) |r| sites.block(r, spec.space);
    for (covered) |r| sites.block(r, 0);

    var placed: std.ArrayList(Bbox) = .empty;
    var iy: i64 = 0;
    while (iy < rows) : (iy += 1) {
        var ix: i64 = 0;
        while (ix < cols) : (ix += 1) {
            if (sites.blocked[@intCast(iy * cols + ix)]) continue;
            const x = die.xlo + ix * pitch;
            const y = die.ylo + iy * pitch;
            const site: Bbox = .{ .xlo = x, .ylo = y, .xhi = x + size, .yhi = y + size };
            const wanted = for (rules.items) |*w| (if (w.wants(site)) break true) else false;
            const allowed = for (rules.items) |*w| (if (!w.allows(site)) break false) else true;
            if (!wanted or !allowed) continue;
            for (rules.items) |*w| w.add(site);
            try placed.append(arena, site);
        }
    }
    return .{ .layer = layer, .squares = placed.items };
}

fn read(scratch: Allocator, loaded: *const Loaded, layer: LayerId, diag: *Diagnostic) Error![]const Bbox {
    return try rectsOf(scratch, loaded, layer) orelse {
        diag.layer = loaded.strings.resolve(loaded.deck.deck.layers.name(layer));
        return error.NotRectilinear;
    };
}

fn positions(span: i64, side: i64, step: i64) i64 {
    return @divTrunc(@max(span - side, 0) + step - 1, step) + 1;
}

fn siteCount(span: i64, size: i64, pitch: i64) i64 {
    return if (span < size) 0 else @divTrunc(span - size, pitch) + 1;
}
