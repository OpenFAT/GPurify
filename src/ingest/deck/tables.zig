//! The lowered deck's tables: what `lower` writes and every engine reads.
//! In: nothing (types). Out: `Deck` and its tables, every name a `StrId`,
//! every layer a `LayerId`, every length a `Dbu` on the layout grid the deck
//! was read against. Field names follow the Rust deck so later ports map
//! one to one; Rust tuples are named structs here. Every slice lives in the
//! arena the deck was lowered into. Ported from crates/ingest/src/deck/mod.rs.
//!
//! Contents:
//! - `pub const Deck`
//! - `pub const Reports`, `P2p`, `Coupling`, `Edits`, `FillSpec`, `WidenSpec`
//! - `pub const PexModels`, `FillRow`, `FillTreatment`, `FillTreatment.word(t: FillTreatment) []const u8`,
//!   `SubstrateModel`, `TsvModel`, `DeviceParasitics`
//! - `pub const TemperatureLaw`, `TemperatureRow`
//! - `pub const Stages`, `StageOf`, `Stages.of(s: Stages, rule: StrId) ?u16`
//! - `pub const ProcessCorner`, `CornerStated`, `CornerValues`
//! - `pub const Extraction`, `ExtractionKind`, `ExtractionKind.keepsCoupling(k: ExtractionKind) bool`
//! - `pub const RuleSpec`, `ParamValue`, `NamedValue`, `RuleTable`,
//!   `RuleTable.layersOf(t: RuleTable, rule: RuleSpec) []const LayerId`,
//!   `RuleTable.paramsOf(t: RuleTable, rule: RuleSpec) []const NamedValue`,
//!   `RuleTable.findParam(t: RuleTable, rule: RuleSpec, name: StrId) ?ParamValue`
//! - `pub const Connectivity`, `pub const Waiver`
//! - `pub const DeviceRecognition`, `DeviceValue`, `DeviceKind`
//! - `pub const Matching`, `MatchingBasis`, `MatchingRow`, `matching_keys`
//! - `pub const LvsControls`, `ModelParam`, `Permute`, `SameNets`, `UnusedFilter`,
//!   `UnusedFilter.all`, `UnusedFilter.name(f: UnusedFilter) []const u8`,
//!   `LvsLde`, `LdeWell`, `LvsCount`, `LvsRange`, `LvsLimit`, `LvsLimit.less(a: LvsLimit, b: LvsLimit) bool`,
//!   `LvsTolerance`
//! - `pub const ProcessStack`
//! - `pub const AbsoluteUnit`, `pub fn absoluteUnit(param: []const u8) ?AbsoluteUnit`
//! - `pub fn pinNames(kind: DeviceKind) []const []const u8`

const std = @import("std");
const geom = @import("geom");
const Dbu = geom.Dbu;
const DbuArea = geom.DbuArea;
const LayerId = geom.LayerId;
const StrId = geom.StrId;
const Qty = geom.Qty;
const LayerTable = @import("layers.zig").LayerTable;
const Dim = @import("kinds.zig").Dim;

/// A parsed, validated, grid-resolved deck, built by `parseDeck` or by
/// `lower` from a `DeckSource`. Only meaningful with a layout on the grid it
/// was parsed against.
pub const Deck = struct {
    /// The `grid` statement, nm: what every deck length is a multiple of;
    /// null for a deck built in code without one.
    grid_nm: ?f64 = null,
    /// Drawn and derived layers, and the stream pairs the deck ignores.
    layers: LayerTable = .{},
    /// Every `rule` statement, in deck order.
    rules: RuleTable = .{},
    /// The `connect` statements: what carries a net, and how layers join.
    connectivity: Connectivity = .{},
    /// The `device` statements.
    devices: DeviceRecognition = .{},
    /// The `matching` statements: a device model's mismatch coefficients, as
    /// stated, at most one row per model.
    matching: []const MatchingRow = &.{},
    /// The `pex` statements: the parasitic stack, per layer.
    stack: ProcessStack = .{},
    /// The `temperature` statement's operating temperature, absolute; null
    /// when the deck states none. `stack.sheet_res_ohm_sq` is already at it.
    temperature: ?Qty(.temperature, .base) = null,
    /// The `extraction` statement: which parasitics PEX writes out.
    extraction: Extraction = .{},
    /// Each process corner's whole stack, in the order the deck first names
    /// them. Empty: the nominal stack alone.
    corners: []const ProcessCorner = &.{},
    /// The order a staged run checks the rules in.
    stages: Stages = .{},
    /// Each `waive` line: a rule and the layer whose shapes waive it.
    waivers: []const Waiver = &.{},
    /// The drawn layer whose shapes' extent is the die; null: the drawn
    /// layers' extent is the die.
    boundary: ?LayerId = null,
    /// The `temperature` statement and the `pex` coefficients as written.
    temperature_law: ?TemperatureLaw = null,
    /// The `lvs` statements.
    lvs: LvsControls = .{},
    /// The parasitic models beyond the stack (`pex_fill`, …), as written.
    pex_models: PexModels = .{},
    /// The layout edits the deck configures (`fill`, `widen`), as written.
    edits: Edits = .{},
    /// What the text report adds after the findings (`report`), as written.
    reports: Reports = .{},
};

/// The `report` statements: measurements printed after the findings, none
/// a check. Shared with `DeckSource`, so its lists grow in the deck's arena.
pub const Reports = struct {
    /// `report p2p "<net>" at [(x, y), ..]`, in deck order (catalog PEX-016).
    p2p: std.ArrayList(P2p) = .empty,
    /// `report coupling "<net>" "<net>"`, in deck order (catalog PEX-016).
    coupling: std.ArrayList(Coupling) = .empty,
    /// `report cluster <len>`, at most once (catalog FLOW-010).
    cluster: ?Dbu = null,
};

/// A net and two or more points on it.
pub const P2p = struct { net: []const u8, points: []const [2]Dbu };
/// Two nets whose total coupling capacitance a PEX run reports.
pub const Coupling = struct { a: []const u8, b: []const u8 };

/// What `gpurify fill` and `gpurify enhance` draw (catalog FLOW-007, FLOW-009).
pub const Edits = struct {
    fill: std.ArrayList(FillSpec) = .empty,
    widen: std.ArrayList(WidenSpec) = .empty,
};

/// `fill <layer> for <density layer> size <len> space <len> keep <len> avoid [..]`.
pub const FillSpec = struct {
    /// The drawn layer the fill goes on.
    layer: []const u8,
    /// The layer whose density rules the fill meets.
    density: []const u8,
    /// A fill square's side; positive.
    size: Dbu,
    /// The gap between neighbouring fill squares; positive.
    space: Dbu,
    /// The least distance from a fill square to a shape of `avoid`.
    keep: Dbu,
    avoid: []const []const u8,
};

/// `widen <layer> net "<pattern>" by <len>`.
pub const WidenSpec = struct {
    layer: []const u8,
    /// A glob over net names: `*` any run, `?` one character.
    net: []const u8,
    /// How far each long side moves out; positive.
    by: Dbu,
};

/// The parasitic models beyond the `pex` stack, by layer name as written.
pub const PexModels = struct {
    /// `pex_fill <layer> floating|grounded|ignored` (catalog PEX-012).
    fill: std.ArrayList(FillRow) = .empty,
    /// `pex_device "<model>" gate_contact_cap <c> gate_diffusion_cap <c>` (PEX-011).
    device: std.ArrayList(DeviceParasitics) = .empty,
    /// `pex_tsv <cut layer> length <l> liner <t> liner_k <k>` (PEX-015).
    tsv: std.ArrayList(TsvModel) = .empty,
    /// `pex_substrate ...`, at most one (PEX-013).
    substrate: ?SubstrateModel = null,
};

pub const FillRow = struct { layer: []const u8, treatment: FillTreatment };

/// How PEX treats metal fill, as StarRC and Quantus offer it.
pub const FillTreatment = enum {
    floating,
    grounded,
    ignored,

    /// The word the deck writes.
    pub fn word(t: FillTreatment) []const u8 {
        return @tagName(t);
    }
};

/// The `pex_substrate` line.
pub const SubstrateModel = struct {
    /// The port layers (taps, wells), as written.
    ports: []const []const u8,
    /// Whether the backside is a grounded contact.
    grounded: bool,
    /// Each layer's `(thickness nm, resistivity Ω·cm)`, top-down.
    layers: []const [2]f64,
};

/// One `pex_tsv` line.
pub const TsvModel = struct { layer: []const u8, length_nm: f64, liner_nm: f64, liner_k: f64 };

/// One `pex_device` line, each capacitance per µm of gate width per side.
pub const DeviceParasitics = struct { model: []const u8, gate_contact_af_um: f64, gate_diffusion_af_um: f64 };

/// `temperature T nominal T0` and, per `pex` row, its sheet resistance at
/// `T0` with its coefficients, kept so the deck can be written again.
pub const TemperatureLaw = struct {
    operating_k: f64,
    nominal_k: f64,
    rows: []const TemperatureRow,
};

/// One `pex` row's layer, sheet resistance at `T0` (Ω/sq) and `tc1`, `tc2`.
pub const TemperatureRow = struct { layer: LayerId, sheet_ohm_sq: f64, tc1: f64, tc2: f64 };

/// A staged deck's stages: a run checks them in order, and once a stage
/// finds an error the later stages are not checked.
pub const Stages = struct {
    /// Each stage's name, in deck order. Empty: the deck is not staged.
    name: []const StrId = &.{},
    /// Each staged rule's id and its stage, an index into `name`.
    of_rule: []const StageOf = &.{},

    /// The stage `rule` is checked in: its own, or the last one for a rule no
    /// stage lists; null when the deck is not staged.
    pub fn of(s: Stages, rule: StrId) ?u16 {
        if (s.name.len == 0) return null;
        for (s.of_rule) |r| if (r.rule == rule) return r.stage;
        return std.math.lossyCast(u16, s.name.len - 1);
    }
};

pub const StageOf = struct { rule: StrId, stage: u16 };

/// A process corner: the nominal stack with the corner's stated values in
/// place of the nominal ones.
pub const ProcessCorner = struct {
    name: StrId,
    /// Every layer's row at this corner, indexed as `Deck.stack` is.
    stack: ProcessStack,
    /// The corner's lines as written, so the deck prints exactly.
    stated: []const CornerStated,
};

pub const CornerStated = struct { layer: LayerId, values: CornerValues };

/// A `corner` line's values, in `pex_keys` order: thickness (nm), height
/// (nm), sheet (Ω/sq at nominal), dielectric, area_cap (aF/µm²), fringe_cap
/// (aF/µm), tc1 (1/K), tc2 (1/K²); null where the line states none.
pub const CornerValues = [8]?f64;

/// The `extraction` statement. Without one, every element is kept (`rcc`).
pub const Extraction = struct {
    kind: ExtractionKind = .rcc,
    /// A coupling below this many aF is grounded; zero grounds none.
    coupling_threshold_af: f64 = 0,
    /// `coupling_halo n`; null: no reach stated, so no capacitance extracted.
    coupling_halo: ?f64 = null,
};

/// An extraction type, as Calibre names them.
pub const ExtractionKind = enum {
    r,
    c,
    cc,
    rc,
    rcc,

    /// Whether the type keeps coupling capacitance between nets.
    pub fn keepsCoupling(k: ExtractionKind) bool {
        return k == .cc or k == .rcc;
    }
};

/// One rule, layers resolved and lengths already `Dbu`. Its layers are
/// `RuleTable.layer_ref[layer_start..][0..layer_len]`, its parameters likewise.
pub const RuleSpec = struct {
    /// The rule's id with every `{name}` replaced; unique within a deck.
    id: StrId,
    /// The engine kind the deck's spelling resolved to (`min_width`).
    kind: StrId,
    layer_start: u32,
    layer_len: u32,
    param_start: u32,
    param_len: u32,
};

/// A rule parameter, already in the unit the engines store.
pub const ParamValue = union(enum) {
    /// A length in grid units, exact on the layout grid.
    length: Dbu,
    /// Any other real number in its dimension's engine unit (mV, µA, A/m,
    /// ohm, K, eV, h; a ratio bare, `%` already divided).
    ratio: f64,
    /// A whole count, or an angle in whole degrees.
    count: u32,
    /// `true`/`false`, `nets: same`, `maximum`, or `warning`.
    flag: bool,
    /// An area in square grid units.
    area: DbuArea,
    layer: LayerId,
    /// A device model name a `device` statement declares, interned.
    model: StrId,
};

pub const NamedValue = struct { name: StrId, value: ParamValue };

/// Every rule in the deck, SoA with CSR side arrays.
pub const RuleTable = struct {
    /// One row per `rule` statement, in deck order.
    spec: []const RuleSpec = &.{},
    /// Every rule's layer arguments, in the order its engine kind takes them.
    layer_ref: []const LayerId = &.{},
    /// Parameter name and value; a list is one row per element.
    param: []const NamedValue = &.{},

    pub fn layersOf(t: RuleTable, rule: RuleSpec) []const LayerId {
        return t.layer_ref[rule.layer_start..][0..rule.layer_len];
    }

    pub fn paramsOf(t: RuleTable, rule: RuleSpec) []const NamedValue {
        return t.param[rule.param_start..][0..rule.param_len];
    }

    /// One parameter by name: the first row for a list, null when absent.
    pub fn findParam(t: RuleTable, rule: RuleSpec, name: StrId) ?ParamValue {
        for (t.paramsOf(rule)) |row| if (row.name == name) return row.value;
        return null;
    }
};

/// What connects to what. `via_cut` pairs with `via_connects`, and
/// `label_layer` with `label_names`, by index.
pub const Connectivity = struct {
    /// The layers that carry a net, in the order written.
    conductors: []const LayerId = &.{},
    via_cut: []const LayerId = &.{},
    via_connects: []const [2]LayerId = &.{},
    /// Whether shapes on one conductor layer connect by touching.
    intra_layer_touch: bool = false,
    /// Net-only layers, each one net (the substrate); not conductors.
    global: []const LayerId = &.{},
    /// The drawn layer a `TEXT` is on...
    label_layer: []const LayerId = &.{},
    /// ...and the conductor whose shapes it names.
    label_names: []const LayerId = &.{},
};

pub const Waiver = struct { rule: StrId, layer: LayerId };

/// How to recognise devices: one row per `device` statement. A terminal's
/// role is its position: `mos` gate, source, drain, bulk; `bjt` base,
/// emitter, collector, bulk; two-pin kinds pin 0, pin 1.
pub const DeviceRecognition = struct {
    kind: []const DeviceKind = &.{},
    /// The layer each of whose shapes is one device.
    marker: []const LayerId = &.{},
    /// Recogniser `i`'s terminals are `terminal[terminal_start[i]..terminal_start[i + 1]]`;
    /// one longer than `kind`, or empty with no device.
    terminal_start: []const u32 = &.{},
    terminal: []const LayerId = &.{},
    model: []const StrId = &.{},
    /// One row per recogniser; a table built by hand may leave it short.
    value: []const DeviceValue = &.{},
    /// A `mos` row's `fins` layer: its size is the count of that layer's
    /// shapes under the marker (`nfin`), never a width. One row per
    /// recogniser, null for none; a table built by hand may leave it short.
    fins: []const ?LayerId = &.{},
    /// The `netlist_scale` statement, nm.
    netlist_scale_nm: ?f64 = null,
};

/// The values a `device` statement may give; null is not computed, never zero.
pub const DeviceValue = struct {
    sheet_ohm_sq: ?f64 = null,
    area_cap_af_um2: ?f64 = null,
    fringe_cap_af_um: ?f64 = null,
    inductance_nh: ?f64 = null,
    on_gate_min_mv: ?f64 = null,
    on_gate_max_mv: ?f64 = null,
};

/// The device families, in the deck as `mos`, `bjt`, `resistor`,
/// `capacitor`, `diode`, `inductor`; `cell` is a black box no statement declares.
pub const DeviceKind = enum { mos, bjt, resistor, capacitor, diode, inductor, cell };

/// A device model's mismatch coefficients in SI, each positive, null where
/// the deck states none: unknown, never zero. W, L and A_E are drawn.
pub const Matching = struct {
    /// V·m: σ(ΔV_T) = avt / √(W·L).
    avt: ?f64 = null,
    /// m (a fraction times a length): σ(Δβ/β) = abeta / √(W·L).
    abeta: ?f64 = null,
    /// m: a resistor body's σ(ΔR/R) = ar / √(W·L).
    ar: ?f64 = null,
    /// V/m: the threshold-voltage gradient, σ(ΔV_T) = svt · D for two
    /// devices D apart.
    svt: ?f64 = null,
    /// m: σ(ΔI_S/I_S) = ka / √A_E, A_E the emitter area.
    ka: ?f64 = null,
};

/// What a `matching` statement's area coefficients (all but `svt`) are of:
/// the difference between two identical devices (`pair`, Pelgrom's), or
/// one device (`single`, a SPICE mismatch model's), √2 times smaller.
pub const MatchingBasis = enum { pair, single };

/// One `matching` statement, its model interned, its values as stated.
pub const MatchingRow = struct { model: StrId, basis: MatchingBasis, stated: Matching };

/// The `matching` keys, each a `Matching` field: what it measures, the
/// device kind whose model it belongs to, and the unit it is printed in.
pub const matching_keys = [_]struct { name: []const u8, dim: Dim, kind: DeviceKind, unit: []const u8 }{
    .{ .name = "avt", .dim = .voltage_length, .kind = .mos, .unit = "mV·um" },
    .{ .name = "abeta", .dim = .fraction_length, .kind = .mos, .unit = "%·um" },
    .{ .name = "ar", .dim = .fraction_length, .kind = .resistor, .unit = "%·um" },
    .{ .name = "svt", .dim = .voltage_per_length, .kind = .mos, .unit = "uV/um" },
    .{ .name = "ka", .dim = .fraction_length, .kind = .bjt, .unit = "%·um" },
};

/// The `lvs` statements, models interned.
pub const LvsControls = struct {
    default_tolerance: ?f64 = null,
    tolerance: []const LvsTolerance = &.{},
    ignore_parameter: []const ModelParam = &.{},
    asymmetric: []const StrId = &.{},
    permute: []const Permute = &.{},
    ignore: []const StrId = &.{},
    ignore_shorted: []const StrId = &.{},
    ports_by_name: bool = false,
    range: []const LvsRange = &.{},
    relaxed: bool = false,
    connect_implicit: []const []const u8 = &.{},
    connect_explicit: []const []const StrId = &.{},
    max_res: ?f64 = null,
    min_caps: ?f64 = null,
    same_nets: []const SameNets = &.{},
    count: []const LvsCount = &.{},
    lde: []const LvsLde = &.{},
    recognize_gates: bool = false,
    /// `lvs split_gates`: the inner nets of transistor chains drawn as split
    /// fingers are joined before reduction (KLayout's `split_gates`).
    split_gates: bool = false,
    blackbox: []const []const u8 = &.{},
    filter_unused: []const UnusedFilter = &.{},
    supply: []const StrId = &.{},
};

pub const ModelParam = struct { model: StrId, param: StrId };
/// Two interchangeable pins of a model, positions in its terminal order.
pub const Permute = struct { model: StrId, a: u8, b: u8 };
pub const SameNets = struct { layout: StrId, reference: StrId };

/// One `lvs filter_unused` pattern (US 8,751,985 B1 col. 7).
pub const UnusedFilter = enum {
    ae,
    af,
    ag,
    c,
    u,

    /// Every option, in the order the deck spells them.
    pub const all = [_]UnusedFilter{ .ae, .af, .ag, .c, .u };

    pub fn name(f: UnusedFilter) []const u8 {
        return @tagName(f);
    }
};

/// One `lvs lde` statement (catalog LVS-074).
pub const LvsLde = struct { model: StrId, od: StrId, max: Dbu, well: ?LdeWell };
pub const LdeWell = struct { layer: StrId, scref: Dbu };

/// One `lvs count` statement: bounds on a model's layout device count.
pub const LvsCount = struct { model: StrId, min: ?u32, max: ?u32 };

/// One `lvs range` statement.
pub const LvsRange = struct { model: StrId, param: StrId, min: ?LvsLimit, max: ?LvsLimit };

/// A bound of an `lvs range` row, of its parameter's kind.
pub const LvsLimit = union(enum) {
    length: Dbu,
    area: DbuArea,
    count: u32,

    /// Rust's derived order: by kind, then by value.
    pub fn less(a: LvsLimit, b: LvsLimit) bool {
        if (std.meta.activeTag(a) != std.meta.activeTag(b)) return @backingInt(a) < @backingInt(b);
        return switch (a) {
            .length => |v| v < b.length,
            .area => |v| v < b.area,
            .count => |v| v < b.count,
        };
    }
};

/// One `lvs tolerance` statement: `|a - b| <= absolute + relative·max(|a|, |b|)`.
pub const LvsTolerance = struct {
    model: StrId,
    param: StrId,
    relative: f64,
    /// In the parameter's SI unit.
    absolute: f64,
    /// As the deck states it, in `absoluteUnit(param)`.
    stated: f64,
};

/// Per-layer process parameters indexed by `LayerId`: empty without a `pex`
/// statement, `LayerTable.len` long otherwise; 0.0 is "not stated".
pub const ProcessStack = struct {
    thickness_nm: []f64 = &.{},
    height_nm: []f64 = &.{},
    /// Ohms per square at the deck's operating temperature (ngspice
    /// resistor law, catalog PEX-007).
    sheet_res_ohm_sq: []f64 = &.{},
    area_cap_af_um2: []f64 = &.{},
    fringe_cap_af_um: []f64 = &.{},
    dielectric_k: []f64 = &.{},
};

/// The unit an absolute tolerance is written in, and its factor to SI.
pub const AbsoluteUnit = struct { unit: []const u8, to_si: f64 };

/// The unit an absolute tolerance on `param` is written in: a length in nm,
/// an area in nm², ohms, aF, nH, or a count; null for an unknown parameter.
pub fn absoluteUnit(param: []const u8) ?AbsoluteUnit {
    const table = [_]struct { []const []const u8, AbsoluteUnit }{
        .{ &.{ "w", "l", "ps", "pd", "pe", "perim" }, .{ .unit = "nm", .to_si = 1e-9 } },
        .{ &.{ "area", "as", "ad", "ae" }, .{ .unit = "nm2", .to_si = 1e-18 } },
        .{ &.{"r"}, .{ .unit = "ohm", .to_si = 1.0 } },
        .{ &.{"c"}, .{ .unit = "aF", .to_si = 1e-18 } },
        .{ &.{"ind"}, .{ .unit = "nH", .to_si = 1e-9 } },
        .{ &.{ "m", "nf", "nfin" }, .{ .unit = "", .to_si = 1.0 } },
    };
    for (table) |row| for (row[0]) |p| if (std.mem.eql(u8, p, param)) return row[1];
    return null;
}

/// The names `lvs permute` gives the pins of a device of `kind`, in its
/// terminal order (Netgen's pin names for the SPICE primitives).
pub fn pinNames(kind: DeviceKind) []const []const u8 {
    return switch (kind) {
        .mos => &.{ "gate", "source", "drain", "bulk" },
        .bjt => &.{ "base", "emitter", "collector" },
        .resistor, .inductor => &.{ "end_a", "end_b" },
        .capacitor => &.{ "top", "bottom" },
        .diode => &.{ "anode", "cathode" },
        .cell => &.{},
    };
}
