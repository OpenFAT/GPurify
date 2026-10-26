//! The load stage: input paths → `Loaded`, everything read from disk in one
//! string table on the grid the layout's `UNITS` record states. Ported from
//! src/engine/pipeline.rs (`Inputs`, `Loaded`, `load`, `load_with`,
//! `load_bytes`, `load_from`, `is_def`, `intern_report_ids`, `LoadError`).
//!
//! Order fixes every `StrId`: the layout's names, then the deck's, the
//! reference's, the intent's and the report rule ids. The layout's grid is
//! read before the deck is compiled, because every deck length is converted
//! onto it. Everything `Loaded` holds lives in the caller's `load_arena`;
//! file bytes and the parsed GDSII library die in `gpa` before `load` returns.
//!
//! Contents:
//! - `pub const Inputs = struct`, `pub const Loaded = struct`
//! - `pub const DeckFn`, `pub const NamedDeck = struct { name, build }`
//! - `pub const Stage = enum`, `pub const Diagnostic = struct`, `pub const Error`
//! - `pub fn load(gpa: Allocator, load_arena: Allocator, io: std.Io, dir: std.Io.Dir, inputs: Inputs, decks: []const NamedDeck, diag: *Diagnostic) Error!Loaded`
//! - `pub fn loadBytes(gpa: Allocator, load_arena: Allocator, io: std.Io, dir: std.Io.Dir, inputs: Inputs, gds: []const u8, decks: []const NamedDeck, diag: *Diagnostic) Error!Loaded`
//! - `pub const Die = struct { grid, deck, store, provenance }`
//! - `pub fn loadDie(gpa: Allocator, load_arena: Allocator, io: std.Io, dir: std.Io.Dir, layout: []const u8, deck: []const u8, strings: *StrTable, diag: *Diagnostic) Error!Die`
//! - `pub fn readDie(load_arena: Allocator, gds: []const u8, deck: []const u8, deck_file: []const u8, strings: *StrTable, diag: *Diagnostic) Error!Die`
//! - `pub fn isDef(layout: []const u8) bool`
//! - `pub fn internReportIds(gpa: Allocator, strings: *StrTable) Allocator.Error!void`

const std = @import("std");
const Allocator = std.mem.Allocator;
const geom = @import("geom");
const Grid = geom.Grid;
const StrTable = geom.StrTable;
const GeometryStore = geom.GeometryStore;
const ingest = @import("ingest");
const lefdef = ingest.lefdef;
const check = @import("check");
const compile = check.deck.compile;
const CompiledDeck = compile.CompiledDeck;
const reference_ = @import("reference.zig");
const integration = @import("integration.zig");

/// What a run was asked to work on: paths under the caller's `dir`.
pub const Inputs = struct {
    /// GDSII, whose `UNITS` record sets the run's grid, or a DEF (`*.def`),
    /// whose `UNITS DISTANCE MICRONS` does, drawn with `lef`.
    layout: []const u8,
    /// The LEF files a DEF reads, technology first; empty for GDSII.
    lef: []const []const u8 = &.{},
    /// The deck file, or the name of a `NamedDeck` the binary carries.
    deck: []const u8,
    /// At most one SPICE or Spectre netlist and any number of structural
    /// Verilog files (`.v`), read together. Empty: LVS is skipped.
    reference: []const []const u8 = &.{},
    /// The design-intent JSON. Null: the intent-gated ERC rules skip.
    intent: ?[]const u8 = null,
};

/// Everything read from disk; every slice lives in the load arena.
pub const Loaded = struct {
    /// Every name the run knows, in the order the module doc gives.
    strings: StrTable,
    /// The layout's database unit; every deck length is on it.
    grid: Grid,
    /// The compiled deck: layers, connectivity, devices, stack, every rule typed.
    deck: CompiledDeck,
    /// The flattened layout, derived layers computed, on the deck's layer ids.
    store: GeometryStore,
    /// The layout's labels, placed and bound to polygons, and its black boxes.
    provenance: ingest.Provenance,
    /// The reference netlist, flattened below its unique top; non-null
    /// exactly when `Inputs.reference` is non-empty.
    reference: ?ingest.netlist.Netlist,
    /// Non-null exactly when `Inputs.intent` is.
    intent: ?ingest.intent.DesignIntent,
    /// The DEF and its LEFs, when the layout is a DEF.
    design: ?lefdef.Design,
};

/// One layout read with its deck: what `load` reads besides the reference
/// and the intent, and what a multi-die system reads per die. Its names are
/// in the string table it was read into; it lives in the load arena.
pub const Die = struct {
    grid: Grid,
    deck: CompiledDeck,
    store: GeometryStore,
    provenance: ingest.Provenance,
};

/// A deck a binary carries, built on the layout's grid into `strings` at the
/// point a deck file would be compiled.
pub const DeckFn = *const fn (gpa: Allocator, arena: Allocator, grid: Grid, strings: *StrTable, diag: *compile.Diag) compile.Error!CompiledDeck;

/// `Inputs.deck` equal to `name` builds `build` instead of reading a file.
pub const NamedDeck = struct { name: []const u8, build: DeckFn };

/// Which input a load error is about; its reader's field in `Diagnostic`.
pub const Stage = enum(u8) { layout, deck, reference, intent, lefdef, labels };

/// Where a load failed: the stage, the path at fault, and that reader's detail.
pub const Diagnostic = struct {
    stage: Stage = .layout,
    path: []const u8 = "",
    gds: ingest.gds.Diagnostic = .{},
    deck: compile.Diag = .{},
    netlist: ingest.netlist.Diagnostic = .{},
    intent: ingest.intent.Diagnostic = .{},
    lefdef: lefdef.Diagnostic = .{},
    /// The label that landed on no shape (`Unplaced`).
    label: ingest.provenance.PlacedLabel = undefined,
};

/// Every reader's refusals, plus: a file that cannot be read
/// (`Unreadable`), two non-Verilog reference netlists (`SeveralNetlists`,
/// `path` the second), and a DEF unit that is not a grid (`BadUnits`).
pub const Error = ingest.gds.Error || compile.Error || ingest.netlist.Error ||
    ingest.intent.Error || lefdef.Error || ingest.LabelError ||
    error{ Unreadable, SeveralNetlists, BadUnits };

/// The deck to compile: a carried one, or file text named `path`.
const DeckIn = struct { builtin: ?DeckFn, text: []const u8, path: []const u8 };

/// Reads every input (module doc), the layout from `inputs.layout`.
pub fn load(gpa: Allocator, load_arena: Allocator, io: std.Io, dir: std.Io.Dir, inputs: Inputs, decks: []const NamedDeck, diag: *Diagnostic) Error!Loaded {
    return loadFrom(gpa, load_arena, io, dir, inputs, null, decks, diag);
}

/// `load`, with the layout given as GDSII bytes (`inputs.layout` only names
/// it): what a layout edit checks before writing it.
pub fn loadBytes(gpa: Allocator, load_arena: Allocator, io: std.Io, dir: std.Io.Dir, inputs: Inputs, gds: []const u8, decks: []const NamedDeck, diag: *Diagnostic) Error!Loaded {
    return loadFrom(gpa, load_arena, io, dir, inputs, gds, decks, diag);
}

/// Reads one layout and its deck file into `strings`, as `load` does: the
/// deck file, then the layout's bytes, then `readDie`.
pub fn loadDie(gpa: Allocator, load_arena: Allocator, io: std.Io, dir: std.Io.Dir, layout: []const u8, deck: []const u8, strings: *StrTable, diag: *Diagnostic) Error!Die {
    const text = try readFile(load_arena, io, dir, deck, .deck, diag);
    const bytes = try readGds(gpa, io, dir, layout, diag);
    defer gpa.free(bytes);
    return readDie(load_arena, bytes, text, deck, strings, diag);
}

/// Reads GDSII `gds` and the deck text `deck` (named `deck_file` in its
/// diagnostic) into `strings`, layout names first: flattened through the
/// deck, layers derived, labels bound.
pub fn readDie(load_arena: Allocator, gds: []const u8, deck: []const u8, deck_file: []const u8, strings: *StrTable, diag: *Diagnostic) Error!Die {
    diag.* = .{ .stage = .layout };
    const lib = try ingest.gds.Library.parse(load_arena, gds, strings, &diag.gds);
    var out: Die = .{ .grid = try lib.grid(&diag.gds), .deck = undefined, .store = .empty, .provenance = .{} };
    out.deck = try compileDeck(load_arena, .{ .builtin = null, .text = deck, .path = deck_file }, out.grid, strings, diag);
    diag.* = .{ .stage = .layout };
    var tags: std.ArrayList(u64) = .empty;
    try ingest.layout.flattenInto(load_arena, &lib, &out.deck.deck.layers, strings, .reject, .top, &out.store, &out.provenance, &tags, &diag.gds);
    try ingest.layout.deriveLayersInto(load_arena, &out.store, &out.deck.deck.layers, &out.provenance, strings, tags.items);
    diag.stage = .labels;
    try ingest.resolveLabels(load_arena, &out.provenance, &out.store, &out.deck.deck.connectivity, &diag.label);
    return out;
}

/// Whether `layout` names a DEF (`*.def`, any case).
pub fn isDef(layout: []const u8) bool {
    return std.ascii.endsWithIgnoreCase(layout, ".def");
}

/// Interns every LVS and integration report rule id, so the checks (which
/// read `Loaded` shared) find them. A `Loaded` built another way calls it
/// before `runChecks`.
pub fn internReportIds(gpa: Allocator, strings: *StrTable) Allocator.Error!void {
    try check.lvs.internRuleIds(gpa, strings);
    for (integration.rule_ids) |name| _ = try strings.intern(gpa, name);
}

// ---- private ----

fn loadFrom(gpa: Allocator, arena: Allocator, io: std.Io, dir: std.Io.Dir, inputs: Inputs, gds: ?[]const u8, decks: []const NamedDeck, diag: *Diagnostic) Error!Loaded {
    const builtin: ?DeckFn = for (decks) |d| (if (std.mem.eql(u8, d.name, inputs.deck)) break d.build) else null;
    const deck_text: []const u8 = if (builtin == null) try readFile(arena, io, dir, inputs.deck, .deck, diag) else "";
    const deck_in: DeckIn = .{ .builtin = builtin, .text = deck_text, .path = inputs.deck };

    var out: Loaded = .{ .strings = .empty, .grid = undefined, .deck = undefined, .store = .empty, .provenance = .{}, .reference = null, .intent = null, .design = null };
    // ponytail: the parsed library interns into `strings`, so it shares the
    // load arena and outlives its last read; a second table if that matters.
    const lib = if (gds == null and isDef(inputs.layout))
        try readDefLayout(gpa, arena, io, dir, inputs, deck_in, &out, diag)
    else blk: {
        const owned = if (gds == null) try readGds(gpa, io, dir, inputs.layout, diag) else null;
        defer if (owned) |b| gpa.free(b);
        diag.* = .{ .stage = .layout, .path = inputs.layout };
        // Layout strings are interned before the deck's, which fixes every StrId.
        const lib = try ingest.gds.Library.parse(arena, gds orelse owned.?, &out.strings, &diag.gds);
        out.grid = try lib.grid(&diag.gds);
        out.deck = try compileDeck(arena, deck_in, out.grid, &out.strings, diag);
        break :blk lib;
    };

    // Flatten, derive, black boxes, labels.
    diag.* = .{ .stage = .layout, .path = inputs.layout };
    const layers = &out.deck.deck.layers;
    var tags: std.ArrayList(u64) = .empty;
    try ingest.layout.flattenInto(arena, &lib, layers, &out.strings, .reject, .top, &out.store, &out.provenance, &tags, &diag.gds);
    try ingest.layout.deriveLayersInto(arena, &out.store, layers, &out.provenance, &out.strings, tags.items);
    try ingest.layout.blackBoxesInto(arena, &lib, out.deck.deck.lvs.blackbox, layers, &out.strings, &out.provenance, &diag.gds);
    diag.stage = .labels;
    try ingest.resolveLabels(arena, &out.provenance, &out.store, &out.deck.deck.connectivity, &diag.label);

    if (inputs.reference.len != 0) out.reference = try readReference(arena, io, dir, inputs.reference, &out.deck.deck, &out.strings, diag);
    if (inputs.intent) |path| {
        diag.* = .{ .stage = .intent, .path = path };
        out.intent = try ingest.intent.readIntent(arena, arena, io, dir, path, &out.strings, &diag.intent);
    }
    try internReportIds(arena, &out.strings);
    return out;
}

fn compileDeck(arena: Allocator, d: DeckIn, grid: Grid, strings: *StrTable, diag: *Diagnostic) Error!CompiledDeck {
    diag.* = .{ .stage = .deck, .path = d.path };
    if (d.builtin) |build| return build(arena, arena, grid, strings, &diag.deck);
    return compile.compile(arena, arena, d.text, grid, strings, &diag.deck);
}

fn readFile(arena: Allocator, io: std.Io, dir: std.Io.Dir, path: []const u8, stage: Stage, diag: *Diagnostic) Error![]const u8 {
    return dir.readFileAlloc(io, path, arena, .unlimited) catch |err| {
        if (err == error.OutOfMemory) return error.OutOfMemory;
        diag.* = .{ .stage = stage, .path = path };
        return error.Unreadable;
    };
}

fn readGds(gpa: Allocator, io: std.Io, dir: std.Io.Dir, path: []const u8, diag: *Diagnostic) Error![]u8 {
    diag.* = .{ .stage = .layout, .path = path };
    return ingest.gds.readGdsBytes(gpa, io, dir, path);
}

/// A DEF states its grid in its UNITS; its LEFs are read on it, then the
/// deck, whose layers the design is drawn on as GDSII and parsed back.
fn readDefLayout(gpa: Allocator, arena: Allocator, io: std.Io, dir: std.Io.Dir, inputs: Inputs, deck_in: DeckIn, out: *Loaded, diag: *Diagnostic) Error!ingest.gds.Library {
    const text = try readFile(arena, io, dir, inputs.layout, .lefdef, diag);
    diag.* = .{ .stage = .lefdef, .path = inputs.layout };
    const dbu = try lefdef.defUnits(arena, text, &diag.lefdef);
    var lef: lefdef.Lef = .{};
    for (inputs.lef) |path| {
        const lef_text = try readFile(arena, io, dir, path, .lefdef, diag);
        diag.* = .{ .stage = .lefdef, .path = path };
        try lefdef.readLefInto(arena, lef_text, dbu, &lef, &diag.lefdef);
    }
    diag.* = .{ .stage = .lefdef, .path = inputs.layout };
    const def = try lefdef.readDef(arena, text, &lef, &diag.lefdef);
    out.grid = Grid.init(dbu) catch return error.BadUnits;
    out.deck = try compileDeck(arena, deck_in, out.grid, &out.strings, diag);
    diag.* = .{ .stage = .lefdef, .path = inputs.layout };
    const flat = try lefdef.flatten(arena, &def, &lef, &diag.lefdef);
    const bytes = try lefdef.toGds(gpa, flat, dbu, def.design, &out.deck.deck.layers, &out.deck.deck.connectivity, &out.strings, &diag.lefdef);
    defer gpa.free(bytes);
    out.design = .{ .def = def, .lef = lef };
    diag.* = .{ .stage = .layout, .path = inputs.layout };
    return ingest.gds.Library.parse(arena, bytes, &out.strings, &diag.gds);
}

/// The reference files: `.v` structural Verilog, any other one SPICE or
/// Spectre netlist (`.scs`/`.spectre` decide the dialect only when no
/// subcircuit opener does). LVS compares leaf devices, so the netlist is
/// flattened below its unique top but for the deck's black boxes; with no
/// unique top it is kept, and LVS reports that instead of guessing.
fn readReference(arena: Allocator, io: std.Io, dir: std.Io.Dir, paths: []const []const u8, d: *const ingest.deck.Deck, strings: *StrTable, diag: *Diagnostic) Error!ingest.netlist.Netlist {
    var netlist: ?reference_.Text = null;
    var netlist_path: []const u8 = "";
    var verilog: std.ArrayList([]const u8) = .empty;
    for (paths) |path| {
        const text = try readFile(arena, io, dir, path, .reference, diag);
        const ext = std.fs.path.extension(path);
        if (std.mem.eql(u8, ext, ".v")) {
            try verilog.append(arena, text);
            continue;
        }
        if (netlist != null) {
            diag.* = .{ .stage = .reference, .path = path };
            return error.SeveralNetlists;
        }
        netlist = .{ .text = text, .spectre_by_name = std.mem.eql(u8, ext, ".scs") or std.mem.eql(u8, ext, ".spectre") };
        netlist_path = path;
    }
    diag.* = .{ .stage = .reference, .path = if (netlist != null) netlist_path else paths[0] };
    const read = try reference_.readReferences(arena, netlist, verilog.items, &d.devices, strings, &diag.netlist);
    const top = read.top orelse return read.netlist;
    return ingest.netlist.flattenTopWith(arena, &read.netlist, top, d.lvs.blackbox, strings, &diag.netlist);
}
