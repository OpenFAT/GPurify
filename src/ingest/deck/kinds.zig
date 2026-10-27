//! Every check kind the deck language spells, as data: one row per kind (and
//! per comparison, where the comparison picks the engine kind). A new engine
//! kind is one row here. In: nothing (comptime tables). Out: `kinds`, the
//! unit table, the `pex` keys, and which engine slots take edge layers.
//! Ported from crates/ingest/src/deck/kinds.rs; the rows are the Rust rows,
//! translated mechanically and in the same order (order decides ties).
//!
//! Contents:
//! - `pub const Dim = union(enum)`, `pub const Param`, `pub const Cmp`, `pub const Fixed`, `pub const Kind`
//! - `pub const Unit`, `pub const units: []const Unit`
//! - `pub const kinds: []const Kind`
//! - `pub const pex_keys`, `pub const optional_pex_keys`
//! - `pub const EdgeKind`, `pub const edge_kinds: []const EdgeKind`, `pub fn edgeSlots(engine: []const u8) []const ?bool`
//! - `pub fn dimName(dim: Dim) []const u8`

const std = @import("std");

/// What a value measures, and so which units it accepts. Each dimension
/// converts to the one unit the engine stores it in.
pub const Dim = union(enum) {
    /// Grid-checked, stored as grid units.
    length,
    /// Checked against the square of the grid, stored as square grid units.
    area,
    /// mV.
    voltage,
    /// uA.
    current,
    /// A/m.
    current_per_width,
    /// ohm.
    resistance,
    /// K.
    temperature,
    /// eV.
    energy,
    /// W/(m·K), written `W/mK`.
    thermal_conductivity,
    /// h.
    time,
    /// V/um, an electric field (numerically mV/nm).
    field,
    /// aF/um2 (PEX only).
    cap_per_area,
    /// aF/um (PEX only).
    cap_per_length,
    /// 1/K, a first-order temperature coefficient (PEX only).
    per_kelvin,
    /// 1/K², a second-order temperature coefficient (PEX only).
    per_kelvin2,
    /// aF (an LVS tolerance on a capacitance).
    capacitance,
    /// nH (an inductor's inductance, an LVS tolerance on one).
    inductance,
    /// V·m (SI), written `mV·um`: a threshold-voltage mismatch area
    /// coefficient (`matching` only).
    voltage_length,
    /// m (SI, a fraction times a length), written `%·um`: a mismatch area
    /// coefficient of a ratio (`matching` only).
    fraction_length,
    /// V/m (SI), written `uV/um`: a threshold-voltage gradient (`matching` only).
    voltage_per_length,
    /// 0..=1, written bare or as `%`.
    fraction,
    /// deg, a whole number.
    angle,
    /// A bare number.
    scalar,
    /// A bare unsigned integer.
    count,
    /// `true` or `false`.
    bool,
    /// A declared layer.
    layer,
    /// `a x b`, two lengths; the second goes to the named engine param.
    length_pair: []const u8,
    /// `[0deg, 90deg]`; one engine param per element, in degrees.
    angle_list,
    /// `["model", ..]`, device model names; one engine param per element.
    models,
    /// `["name", ..]`, quoted names that are not device models (net types,
    /// type sets, `"!"`), never looked up among the `device` statements.
    names,
    /// `(name: value, ..)`, a nested set of params.
    group: []const Param,
    /// `same` or `different`; `same` is the engine flag.
    nets,
    /// `[a, b, ..]`, lengths; one engine param per element.
    length_list,
    /// `[a, b, ..]`, voltages; one engine param per element, in mV.
    voltage_list,
    /// MHz, a frequency.
    frequency,
    /// `[a, b, ..]`, frequencies; one engine param per element, in MHz.
    frequency_list,
    /// `[[a, b, ..], ..]`, rows of current per width; one engine param per
    /// cell, row by row, in A/m.
    current_per_width_rows,
    /// `[a, b, ..]`, fractions written bare or as `%`, from 0 to 1.
    fraction_list,
    /// `[a, b, ..]`, bare whole numbers; one engine param per element.
    count_list,
    /// `[a, b, ..]`, areas, in square grid units.
    area_list,
    /// `[[a, b, ..], ..]`, rows of lengths; one engine param per cell, row by row.
    length_rows,
    /// `[a x b, ..]`, pairs of lengths; per pair, the first to the param's
    /// engine name and the second to the named one.
    length_pair_list: []const u8,
    /// One of the listed bare words; the engine param is its index, a count.
    word: []const []const u8,
    /// `[(area, n), ..]`, a piecewise-linear table (LEF's `PWL`), areas
    /// rising strictly; per point, the area to the param's engine name and
    /// the number to the named one.
    area_table: []const u8,
    /// `[none, a, ..]`, lengths or `none`; one engine param per element, a
    /// length or, for `none`, the flag `false`.
    opt_length_list,
};

/// One named argument: the deck's name, the engine's, and what it accepts.
pub const Param = struct {
    name: []const u8,
    engine: []const u8,
    dim: Dim,
    /// `none` is legal and leaves the engine param absent.
    none: bool = false,
};

/// The comparison a kind is written with.
pub const Cmp = enum {
    /// No comparison: every value is a named argument.
    absent,
    /// `>=`, a minimum.
    ge,
    /// `<=`, a maximum.
    le,
    /// `==`, an exact value.
    eq,
};

/// An engine flag a kind row implies: its name and value.
pub const Fixed = struct { []const u8, bool };

/// One row of the kind table.
pub const Kind = struct {
    /// The deck's name, `width` in `width(met1) >= 140nm`.
    name: []const u8,
    /// A bare word among the layer arguments that selects this row (`opposite`).
    modifier: ?[]const u8 = null,
    cmp: Cmp,
    /// The engine kind name `check` matches on.
    engine: []const u8,
    /// Engine layer slot `i` takes deck layer argument `layers[i]`.
    layers: []const u8,
    /// Further layer arguments follow the fixed ones.
    more: bool = false,
    /// The engine param the comparison value fills.
    limit: ?Param = null,
    params: []const Param = &.{},
    /// Engine flag params the row implies.
    fixed: []const Fixed = &.{},
};

/// A unit, the dimension it belongs to, and the power of ten to the engine
/// unit. `C` is not here: it is an offset, handled where temperatures are read.
pub const Unit = struct { name: []const u8, dim: Dim, shift: i32 };

pub const units: []const Unit = &.{
    .{ .name = "nm", .dim = .length, .shift = 0 },
    .{ .name = "um", .dim = .length, .shift = 3 },
    .{ .name = "mm", .dim = .length, .shift = 6 },
    .{ .name = "nm2", .dim = .area, .shift = 0 },
    .{ .name = "um2", .dim = .area, .shift = 6 },
    .{ .name = "mm2", .dim = .area, .shift = 12 },
    .{ .name = "mV", .dim = .voltage, .shift = 0 },
    .{ .name = "V", .dim = .voltage, .shift = 3 },
    .{ .name = "nA", .dim = .current, .shift = -3 },
    .{ .name = "uA", .dim = .current, .shift = 0 },
    .{ .name = "mA", .dim = .current, .shift = 3 },
    .{ .name = "A", .dim = .current, .shift = 6 },
    .{ .name = "uA/um", .dim = .current_per_width, .shift = 0 },
    .{ .name = "mA/um", .dim = .current_per_width, .shift = 3 },
    .{ .name = "A/m", .dim = .current_per_width, .shift = 0 },
    .{ .name = "Hz", .dim = .frequency, .shift = -6 },
    .{ .name = "kHz", .dim = .frequency, .shift = -3 },
    .{ .name = "MHz", .dim = .frequency, .shift = 0 },
    .{ .name = "GHz", .dim = .frequency, .shift = 3 },
    .{ .name = "mohm", .dim = .resistance, .shift = -3 },
    .{ .name = "ohm", .dim = .resistance, .shift = 0 },
    .{ .name = "kohm", .dim = .resistance, .shift = 3 },
    .{ .name = "Mohm", .dim = .resistance, .shift = 6 },
    .{ .name = "K", .dim = .temperature, .shift = 0 },
    .{ .name = "eV", .dim = .energy, .shift = 0 },
    .{ .name = "W/mK", .dim = .thermal_conductivity, .shift = 0 },
    .{ .name = "h", .dim = .time, .shift = 0 },
    .{ .name = "V/um", .dim = .field, .shift = 0 },
    .{ .name = "V/nm", .dim = .field, .shift = 3 },
    .{ .name = "MV/cm", .dim = .field, .shift = 2 },
    .{ .name = "aF/um2", .dim = .cap_per_area, .shift = 0 },
    .{ .name = "fF/um2", .dim = .cap_per_area, .shift = 3 },
    .{ .name = "aF/um", .dim = .cap_per_length, .shift = 0 },
    .{ .name = "fF/um", .dim = .cap_per_length, .shift = 3 },
    .{ .name = "/K", .dim = .per_kelvin, .shift = 0 },
    .{ .name = "/K2", .dim = .per_kelvin2, .shift = 0 },
    .{ .name = "aF", .dim = .capacitance, .shift = 0 },
    .{ .name = "fF", .dim = .capacitance, .shift = 3 },
    .{ .name = "pF", .dim = .capacitance, .shift = 6 },
    .{ .name = "pH", .dim = .inductance, .shift = -3 },
    .{ .name = "nH", .dim = .inductance, .shift = 0 },
    .{ .name = "uH", .dim = .inductance, .shift = 3 },
    .{ .name = "%", .dim = .fraction, .shift = -2 },
    .{ .name = "mV·um", .dim = .voltage_length, .shift = -9 },
    .{ .name = "mV.um", .dim = .voltage_length, .shift = -9 },
    .{ .name = "%·um", .dim = .fraction_length, .shift = -8 },
    .{ .name = "%.um", .dim = .fraction_length, .shift = -8 },
    .{ .name = "uV/um", .dim = .voltage_per_length, .shift = 0 },
    .{ .name = "deg", .dim = .angle, .shift = 0 },
};

/// The PEX keys, each given at most once per `pex` statement, and every one
/// but the `optional_pex_keys` required.
pub const pex_keys = [8]struct { []const u8, Dim }{
    .{ "thickness", .length },
    .{ "height", .length },
    .{ "sheet", .resistance },
    .{ "dielectric", .scalar },
    .{ "area_cap", .cap_per_area },
    .{ "fringe_cap", .cap_per_length },
    .{ "tc1", .per_kelvin },
    .{ "tc2", .per_kelvin2 },
};

/// The `pex_keys` a row may leave out: a dielectric the process does not
/// state (stated, it must be positive), and the temperature coefficients,
/// which a row gives together and exactly when the deck states a `temperature`.
pub const optional_pex_keys = [3][]const u8{ "dielectric", "tc1", "tc2" };

/// An engine kind whose layer arguments may be edge layers, and what each
/// engine layer slot takes: `true` edges, `false` polygons, null either.
pub const EdgeKind = struct { engine: []const u8, slots: []const ?bool };

/// Every other kind refuses an edge layer when the deck is read. A kind named
/// `edge_*` takes only edges, so a polygon argument picks its polygon twin.
pub const edge_kinds: []const EdgeKind = &.{
    .{ .engine = "forbidden", .slots = &.{null} },
    .{ .engine = "edge_min_length", .slots = &.{true} },
    .{ .engine = "edge_spacing", .slots = &.{ true, true } },
    .{ .engine = "edge_enclosure", .slots = &.{ true, false } },
    .{ .engine = "edge_width", .slots = &.{true} },
    .{ .engine = "edge_facing_space", .slots = &.{true} },
};

/// Every kind row, DRC then ERC, in the Rust table order: among rows alike
/// but for their named arguments, the first wins a tie.
pub const kinds: []const Kind = &.{
    // DRC.
    drc("width", .ge, "min_width", &.{0}, limit, &.{}),
    drc("width", .le, "max_width", &.{0}, limit, &.{}),
    // Exact cut size, `size(licon) == 170nm x 170nm`: every merged figure is
    // exactly that rectangle, either way round.
    drc("size", .eq, "cut_size", &.{0}, p("", "width", .{ .length_pair = "height" }), &.{}),
    drc("edge_length", .ge, "min_edge_length", &.{0}, limit, &.{}),
    // LEF MINSTEP's variants: more than `max_edges` short edges in a row, or a
    // run of short edges at an outside corner, an inside corner or a step,
    // with LENGTHSUM's allowance (`length_sum: none` for none).
    drc("min_step", .ge, "min_step", &.{0}, limit, &.{p("max_edges", "max_edges", .count)}),
    drc("min_step", .ge, "min_step", &.{0}, limit, &.{ p("corner", "corner", .{ .word = step_corners }), opt("length_sum", "length_sum", .length) }),
    // LEF58_MINSTEP's qualifiers as OpenROAD's TritonRoute checks them: a
    // short edge beside a short edge (MINADJACENTLENGTH, with NOADJACENTEOL
    // an end of line too, EXCEPTRECTANGLE), or two short edges either side of
    // a short end of line (NOBETWEENEOL).
    drc("min_step", .ge, "min_step_adjacent", &.{0}, limit, &.{ p("adjacent", "adjacent", .length), p("except_rectangle", "except_rectangle", .bool) }),
    drc("min_step", .ge, "min_step_adjacent", &.{0}, limit, &.{ p("adjacent", "adjacent", .length), p("adjacent_eol", "adjacent_eol", .length), p("except_rectangle", "except_rectangle", .bool) }),
    drc("min_step", .ge, "min_step_adjacent", &.{0}, limit, &.{p("between_eol", "between_eol", .length)}),
    // A set of legal widths, `width(L; allowed: [350nm, 690nm])` (sky130
    // rpm.1b-1f): each merged figure's narrowest width is one of them.
    drc("width", .absent, "allowed_width", &.{0}, null, &.{p("allowed", "width", .length_list)}),
    // The layer's box starts at the origin (sky130 x.19, the seal ring).
    drc("origin", .absent, "origin", &.{0}, null, &.{}),
    // A protrusion narrower than the limit from a wire at least `wide` wide
    // (LEF `PROTRUSIONWIDTH width1 LENGTH 0 WIDTH width2`).
    drc("protrusion_width", .ge, "protrusion_width", &.{0}, limit, &.{p("wide", "wide", .length)}),
    // The same with the last width open (LEF58 `WIDTHTABLE`: "all the given
    // widths are exact width values, except for the last one, which is equal
    // to or greater than the value"): `open_last: true`.
    drc("width", .absent, "allowed_width", &.{0}, null, &.{ p("allowed", "width", .length_list), p("open_last", "open_last", .bool) }),
    drc("notch", .ge, "notch", &.{0}, limit, &.{}),
    drc("space", .ge, "min_spacing", &.{0}, limit, &.{}),
    drc("space", .ge, "min_spacing_diff", &.{ 0, 1 }, limit, &.{}),
    // Facing edges only, KLayout's `projection` metric:
    // `space(lvtn, sd, projection) >= 235nm` (sky130 lvtn.3b).
    over(drc("space", .ge, "projection_spacing", &.{ 0, 1 }, limit, &.{}), .{ .modifier = "projection" }),
    drc("eol_space", .ge, "eol_spacing", &.{0}, limit, &.{p("eol_width", "eol_width", .length)}),
    // LEF `SPACING ENDOFLINE`: a keep-out reaching `within` past the end's
    // sides, optionally only beside parallel edges, with its own space
    // between two ends (`LEF58_SPACING ENDOFLINE ... ENDTOEND`).
    drc("eol_space", .ge, "eol_within_spacing", &.{0}, limit, &.{ p("eol_width", "eol_width", .length), p("within", "eol_within", .length), opt("parallel", "", .{ .group = eol_parallel }), opt("end_to_end", "end_to_end", .length) }),
    // With the `LEF58_SPACING ENDOFLINE` qualifiers, each `none` or stated.
    drc("eol_space", .ge, "eol_within_spacing", &.{0}, limit, &.{ p("eol_width", "eol_width", .length), p("within", "eol_within", .length), opt("parallel", "", .{ .group = eol_parallel }), opt("end_to_end", "end_to_end", .length), opt("side_length", "", .{ .group = eol_side_length }), opt("opposite_width", "opposite_width", .length), opt("parallel_more", "", .{ .group = eol_parallel_more }), opt("end_prl", "", .{ .group = eol_end_prl }), opt("wrong_dir", "", .{ .group = eol_wrong_dir }), opt("extension", "eol_extension", .length), opt("enclose_cut", "", .{ .group = eol_enclose_cut }) }),
    drc("prl_space", .ge, "prl_spacing", &.{0}, limit, &.{p("prl", "prl_threshold", .length)}),
    drc("corner_space", .ge, "corner_to_corner", &.{0}, limit, &.{}),
    // `LEF58_CORNERSPACING CONVEXCORNER`: the larger axis gap between facing
    // convex corners (or Euclidean, `CORNERTOCORNER`), ends of line exempt
    // with `EXCEPTEOL`.
    drc("corner_space", .ge, "convex_corner_spacing", &.{0}, limit, &.{ p("corner_to_corner", "corner_to_corner", .bool), opt("except_eol", "except_eol", .length) }),
    drc("wide_space", .ge, "wide_dependent_spacing", &.{0}, limit, &.{p("width", "width_threshold", .length)}),
    drc("area", .ge, "min_area", &.{0}, area, &.{}),
    drc("hole_area", .ge, "min_enclosed_area", &.{0}, area, &.{}),
    drc("cheesing", .le, "cheesing", &.{0}, p("", "max_unslotted", .area), &.{}),
    // Windows tile the die: a second layer names the die boundary
    // (`density(met1, prBoundary; ..)`), else the whole layout's extent.
    over(drc("density", .ge, "density", &.{0}, density_limit, density), .{ .fixed = &.{.{ "maximum", false }}, .more = true }),
    over(drc("density", .le, "density", &.{0}, density_limit, density), .{ .fixed = &.{.{ "maximum", true }}, .more = true }),
    over(drc("global_density", .ge, "global_density", &.{0}, density_limit, &.{}), .{ .fixed = &.{.{ "maximum", false }}, .more = true }),
    over(drc("global_density", .le, "global_density", &.{0}, density_limit, &.{}), .{ .fixed = &.{.{ "maximum", true }}, .more = true }),
    // Coverage of a layer inside each shape of a region layer (sky130 vpp.5a
    // "max pattern density of met3 over capacitor", vpp.11).
    over(drc("region_density", .ge, "region_density", &.{ 0, 1 }, density_limit, &.{}), .{ .fixed = &.{.{ "maximum", false }} }),
    over(drc("region_density", .le, "region_density", &.{ 0, 1 }, density_limit, &.{}), .{ .fixed = &.{.{ "maximum", true }} }),
    // The number of merged shapes on the layer in the whole layout, a minimum
    // or a maximum (IHP npn13G2.bR; one seal ring per chip).
    over(drc("count", .ge, "count", &.{0}, count, &.{}), .{ .fixed = &.{.{ "maximum", false }} }),
    over(drc("count", .le, "count", &.{0}, count, &.{}), .{ .fixed = &.{.{ "maximum", true }} }),
    // Several legal cut sizes, `size(via; allowed: [150nm x 150nm, 230nm x
    // 230nm])` (sky130 via.1b, LEF58_CUTCLASS): each merged figure is one of
    // them, either way round.
    drc("size", .absent, "cut_class", &.{0}, null, &.{p("allowed", "width", .{ .length_pair_list = "height" })}),
    // The area a layer covers in the whole layout (IHP MIM.gR).
    drc("total_area", .le, "total_area", &.{0}, area, &.{}),
    // A shape's bounding box, its longer side over its shorter (sky130 capm.6).
    drc("aspect_ratio", .le, "aspect_ratio", &.{0}, p("", "limit", .scalar), &.{}),
    // Short-circuit critical area for a square defect of half-side `radius`:
    // `critical_area(met1; radius: 100nm) <= 50um2`; with `radii` and
    // `weights`, the mean over a defect-size distribution the deck samples.
    drc("critical_area", .le, "mean_critical_area", &.{0}, area, &.{ p("radii", "radii", .length_list), p("weights", "weights", .fraction_list) }),
    // `critical_area(met1; radius: 100nm) <= 50um2`.
    drc("critical_area", .le, "critical_area", &.{0}, area, &.{p("radius", "radius", .length)}),
    // Two masks' coverage balanced per window, an optional third layer the
    // die: `density_balance(m1_c1, m1_c2; window: 10um, step: 5um) >= 0.8`.
    over(drc("density_balance", .ge, "density_balance", &.{ 0, 1 }, density_limit, density), .{ .more = true }),
    // The redundant-via rate, 1 - dead / vias (Xu et al., ASP-DAC 2005): a
    // single-cut via is dead when no cut fits beside it at `pitch`.
    drc("via_redundancy", .ge, "via_redundancy", &.{ 0, 1, 2 }, density_limit, &.{ p("pitch", "pitch", .length), p("space", "space", .length) }),
    // A DFM score over a recommended rule's findings, each 0 at the required
    // value and 1 at the recommended one, combined with a failure rate:
    // `dfm_score(met1; check: space, required: 180nm, recommended: 220nm,
    // rate: 1%) >= 0.99`. An enclosure takes the outer layer second.
    over(drc("dfm_score", .ge, "dfm_score", &.{0}, density_limit, &.{ p("check", "check", .{ .word = dfm_checks }), p("required", "required", .length), p("recommended", "recommended", .length), p("rate", "rate", .fraction) }), .{ .more = true }),
    // A deck-supplied pattern found wherever the layer matches it, in any of
    // the eight orientations, with don't-care boxes (pattern-matching DRC).
    drc("pattern", .absent, "pattern_match", &.{0}, null, &.{ p("window", "window_w", .{ .length_pair = "window_h" }), p("shapes", "shape_x", .{ .length_pair_list = "shape_y" }), opt("ignore", "ignore_x", .{ .length_pair_list = "ignore_y" }) }),
    // A connector's cut area held between two databases drawn as two layers,
    // by its cut count (sky130 ct.irdrop, via.irdrop; every value the deck's).
    drc("cut_area_change", .absent, "cut_area_change", &.{ 0, 1, 2, 3 }, null, &.{ p("cuts", "cuts", .count_list), p("change", "change", .area_list) }),
    // A layer's density per window, held to the band its coverage by a second
    // layer falls in (sky130 m1.- to m4.-, the waffle-drop rule), an optional
    // third layer the die. Every value is the deck's.
    over(drc("cover_density", .absent, "cover_density", &.{ 0, 1 }, null, &.{ p("window", "window", .length), p("step", "step", .length), p("cover", "cover", .fraction_list), p("density", "density", .fraction_list), p("inclusive", "inclusive", .bool) }), .{ .more = true }),
    // The engine takes the outer layer first; the deck writes `enclosure(inner, outer)`.
    // A wire band (`width:`, `below:`, LEF `ENCLOSURE ... WIDTH`) is one more
    // row per combination, the plain row first: a row knowing every given
    // name wins, the first on a tie.
    drc("enclosure", .ge, "min_enclosure", &.{ 1, 0 }, limit, &.{}),
    drc("enclosure", .ge, "min_enclosure", &.{ 1, 0 }, limit, wire_width),
    drc("enclosure", .ge, "min_enclosure", &.{ 1, 0 }, limit, wire_below),
    drc("enclosure", .ge, "min_enclosure", &.{ 1, 0 }, limit, wire),
    everySide(0),
    everySide(1),
    everySide(2),
    everySide(3),
    everySide(4),
    everySide(5),
    everySide(6),
    everySide(7),
    // Coincident edges exempt, `enclosure(lvtn, nwell, noncoincident)`
    // (sky130 lvtn.10).
    over(drc("enclosure", .ge, "noncoincident_enclosure", &.{ 1, 0 }, limit, &.{}), .{ .modifier = "noncoincident" }),
    // The inner spans its host along one axis: `full_width(V1, M2)` (ASAP7
    // V1.M2.AUX.2).
    drc("full_width", .absent, "full_width", &.{ 1, 0 }, null, &.{}),
    // A maximum enclosure, `enclosure(licon, npc) <= 95nm` (sky130 npc.5).
    drc("enclosure", .le, "max_enclosure", &.{ 1, 0 }, limit, &.{}),
    opposite(&.{}),
    opposite(wire_width),
    opposite(wire_below),
    opposite(wire),
    oppositeQualified(0),
    oppositeQualified(1),
    oppositeQualified(2),
    oppositeQualified(3),
    oppositeQualified(4),
    oppositeQualified(5),
    oppositeQualified(6),
    oppositeQualified(7),
    over(drc("enclosure", .ge, "adjacent_enclosure", &.{ 1, 0 }, p("", "min_one_side", .length), &.{}), .{ .modifier = "adjacent" }),
    drc("extension", .ge, "min_extension", &.{ 0, 1 }, limit, &.{}),
    // A gate's shape: `bend(poly, diff)` (poly turning on diff, sky130
    // poly.11) and `covers_corner(poly, diff)` (poly over an inner corner of
    // diff, poly.10).
    over(drc("bend", .absent, "gate_corner", &.{ 0, 1 }, null, &.{}), .{ .fixed = &.{.{ "of_reference", false }} }),
    over(drc("covers_corner", .absent, "gate_corner", &.{ 0, 1 }, null, &.{}), .{ .fixed = &.{.{ "of_reference", true }} }),
    drc("overlap", .ge, "overlap", &.{ 0, 1 }, limit, &.{}),
    drc("tap_distance", .le, "max_distance_to_tap", &.{ 0, 1 }, limit, &.{}),
    drc("off_grid", .absent, "off_grid", &.{}, null, &.{p("pitch", "pitch", .length)}),
    drc("angle", .absent, "angle", &.{}, null, &.{p("allowed", "angle", .angle_list)}),
    // One layer's edges: `angle(diff; allowed: [0deg, 90deg])` (sky130 x.2).
    drc("angle", .absent, "angle", &.{0}, null, &.{p("allowed", "angle", .angle_list)}),
    drc("redundant_via", .ge, "redundant_via", &.{0}, p("", "min_count", .count), &.{p("within", "within", .length)}),
    // LEF MINIMUMCUT on the wide layer, the via's far metal third:
    // `min_cuts(via1, met2, met1; width: 1um) >= 2` is MINIMUMCUT 2 WIDTH 1.0
    // FROMBELOW on met2.
    drc("min_cuts", .ge, "minimum_cut", &.{ 0, 1, 2 }, p("", "min_count", .count), &.{p("width", "width", .length)}),
    drc("min_cuts", .ge, "minimum_cut", &.{ 0, 1, 2 }, p("", "min_count", .count), &.{ p("width", "width", .length), p("within", "within", .length) }),
    // LEF MINIMUMCUT ... LENGTH length WITHIN distance: the thin wires
    // beside a wide one longer than `length`, with or without `within`.
    drc("min_cuts", .ge, "minimum_cut", &.{ 0, 1, 2 }, p("", "min_count", .count), &.{ p("width", "width", .length), p("length", "length", .length), p("distance", "distance", .length) }),
    drc("min_cuts", .ge, "minimum_cut", &.{ 0, 1, 2 }, p("", "min_count", .count), &.{ p("width", "width", .length), p("within", "within", .length), p("length", "length", .length), p("distance", "distance", .length) }),
    // One `LEF58_METALWIDTHVIAMAP` entry: a cut between a `below` wire and an
    // `above` wire of the given widths must be the mapped via's cut,
    // `via_map(via1, met1, met2; below_min: .., below_max: .., above_min: ..,
    // above_max: .., cut: 50nm x 50nm)`.
    drc("via_map", .absent, "metal_width_via", &.{ 0, 1, 2 }, null, &.{ p("below_min", "below_min", .length), p("below_max", "below_max", .length), p("above_min", "above_min", .length), p("above_max", "above_max", .length), p("cut", "cut_width", .{ .length_pair = "cut_height" }) }),
    // LEF `SPACING cutSpacing [SAMENET] LAYER second STACK`: cuts on two
    // layers spaced unless one net's cuts are stacked (one covering the
    // other), the cuts' nets read off the metal both land on:
    // `stack_space(via2, via1, met2) >= 200nm`, `same_net: true` for
    // `SAMENET`.
    drc("stack_space", .ge, "stack_spacing", &.{ 0, 1, 2 }, limit, &.{}),
    drc("stack_space", .ge, "stack_spacing", &.{ 0, 1, 2 }, limit, &.{p("same_net", "same_net", .bool)}),
    // A cut with no other cut within the limit, centre to centre
    // (`LEF58_MAXSPACING`): `max_space(via1) <= 2um`, or a cut class's cuts
    // against the whole cut layer, `max_space(via1_class, via1) <= 2um`.
    drc("max_space", .le, "max_cut_spacing", &.{0}, limit, &.{}),
    drc("max_space", .le, "max_cut_spacing", &.{ 0, 1 }, limit, &.{}),
    // LEF MAXVIASTACK over the cut layers listed, bottom to top:
    // `via_stack(via1, via2, via3) <= 2`.
    over(drc("via_stack", .le, "via_stack", &.{0}, p("", "max_height", .count), &.{}), .{ .more = true, .fixed = &.{.{ "single", false }} }),
    // Single-cut vias only, the metals between the cuts named so that a
    // via of two or more cuts interrupts the stack (LEF: "A double-cut or
    // larger via interrupts the stack"): `via_stack(m1, via1, m2, via2, m3,
    // single) <= 2`.
    over(drc("via_stack", .le, "via_stack", &.{0}, p("", "max_height", .count), &.{}), .{ .more = true, .modifier = "single", .fixed = &.{.{ "single", true }} }),
    drc("via_array_space", .ge, "via_array_spacing", &.{0}, limit, &.{p("array", "array_threshold", .count)}),
    // LEF cut-layer SPACING: `space(via1, center)` is CENTERTOCENTER, and
    // `adjacent_space(via1; cuts: 3, within: 250nm)` ADJACENTCUTS 3 WITHIN.
    over(drc("space", .ge, "cut_spacing", &.{0}, limit, &.{}), .{ .modifier = "center", .fixed = &.{.{ "center", true }} }),
    over(drc("adjacent_space", .ge, "cut_spacing", &.{0}, limit, adjacent), .{ .fixed = &.{.{ "center", false }} }),
    over(drc("adjacent_space", .ge, "cut_spacing", &.{0}, limit, adjacent), .{ .modifier = "center", .fixed = &.{.{ "center", true }} }),
    // LEF58_SPACINGTABLE on a cut layer, by cut class: `short`/`long` are the
    // classes' sizes, `space` two rows and columns per class (END, SIDE).
    drc("cut_class_space", .absent, "cut_class_spacing", &.{0}, null, &.{ p("short", "class_short", .length_list), p("long", "class_long", .length_list), p("space", "space", .length_rows) }),
    drc("patterning", .ge, "multi_patterning", &.{0}, p("", "color_spacing", .length), &.{p("colors", "colors", .count)}),
    // A corner whose angle inside its shape is under the limit (IHP 3.1
    // "acute angles <87 degree"); with no layer, every drawn layer.
    drc("interior_angle", .ge, "min_interior_angle", &.{}, p("", "limit", .angle), &.{}),
    drc("interior_angle", .ge, "min_interior_angle", &.{0}, p("", "limit", .angle), &.{}),
    // A drawn polygon that crosses itself or encloses no area (IHP 3.1
    // "self-intersecting polygons must be avoided"); with no layer, every
    // drawn layer.
    drc("valid", .absent, "polygon_validity", &.{}, null, &.{}),
    drc("valid", .absent, "polygon_validity", &.{0}, null, &.{}),
    // Pre-coloured shapes, one anchor layer per mask after the patterned one:
    // `patterning(met1, met1_mask1, met1_mask2; colors: 2) >= 50nm`.
    over(drc("patterning", .ge, "anchored_patterning", &.{ 0, 1 }, p("", "color_spacing", .length), &.{p("colors", "colors", .count)}), .{ .more = true }),
    // Self-aligned double patterning, US 2015/0286764 A1's colour bands and
    // odd-track widths: `sadp(m4; different: 72nm, same: 120nm,
    // track_width: 24nm, track_space: 24nm)`.
    drc("sadp", .absent, "sadp", &.{0}, null, &.{ p("different", "different", .length), p("same", "same", .length), opt("track_width", "track_width", .length), opt("track_space", "track_space", .length) }),
    // Gridded SADP line ends, Xu et al. (TCAD 2015) rules 1-4:
    // `sadp_line_end(m4; adjacent: 24nm, tip: 32nm, overlap: 58nm,
    // corner: 22nm, offset: 44nm)`.
    drc("sadp_line_end", .absent, "sadp_line_end", &.{0}, null, &.{ p("adjacent", "adjacent", .length), p("tip", "tip", .length), p("overlap", "overlap", .length), p("corner", "corner", .length), p("offset", "offset", .length) }),
    // Every shape (or edge) of the layer is a violation: `forbidden(licon and poly and diff)`.
    drc("forbidden", .absent, "forbidden", &.{0}, null, &.{}),
    // Each outer shape holds at least `count` inner shapes entirely: `contains(tap, licon) >= 1`.
    drc("contains", .ge, "must_contain", &.{ 0, 1 }, p("", "min_count", .count), &.{}),
    // At most `count` (sky130 rpm.1g "only 1 licon is allowed in ..."), or
    // exactly `count`.
    drc("contains", .le, "must_contain", &.{ 0, 1 }, p("", "max_count", .count), &.{}),
    drc("contains", .eq, "must_contain", &.{ 0, 1 }, p("", "count", .count), &.{}),
    // Every inner shape lies entirely inside the outer layer: `inside(poly_licon, npc)`.
    drc("inside", .absent, "must_be_inside", &.{ 0, 1 }, null, &.{}),
    // Spacing between shapes on the same net, or on different nets (gf180 NW.2a/2b),
    // on one layer or between two (sky130 nwell.7).
    drc("space", .ge, "net_spacing", &.{0}, limit, &.{p("nets", "same_net", .nets)}),
    drc("space", .ge, "net_spacing", &.{ 0, 1 }, limit, &.{p("nets", "same_net", .nets)}),
    // Spacing by width and parallel run length, a LEF `SPACINGTABLE`.
    drc("space_table", .absent, "spacing_table", &.{0}, null, &.{ p("prl", "prl", .length_list), p("width", "width", .length_list), p("space", "space", .length_rows) }),
    // Wide spacing measured from the wide part and what is attached to it
    // within `attached` (sky130 m1.3a).
    drc("wide_space", .ge, "attached_wide_spacing", &.{0}, limit, &.{ p("width", "width_threshold", .length), p("attached", "attached", .length) }),
    // Space between facing edges by the length class of each (ASAP7 M1.S.1
    // to M1.S.5): a square, symmetric table of cells, one row and column per
    // class threshold.
    drc("tip_space_table", .absent, "tip_spacing_table", &.{0}, null, &.{ p("length", "length", .length_list), p("space", "space", .length_rows) }),
    // Spacing by the widths of both shapes and, per width, a run: LEF
    // `SPACINGTABLE TWOWIDTHS {WIDTH width [PRL runLength] {spacing}...}`.
    drc("two_width_table", .absent, "two_width_spacing_table", &.{0}, null, &.{ p("width", "width", .length_list), p("prl", "prl", .opt_length_list), p("space", "space", .length_rows) }),
    // Every span (chord) of a shape is a legal length: one of the list, or at
    // least its last (`LEF58_SPANLENGTHTABLE`).
    drc("span_length", .absent, "span_length", &.{0}, null, &.{ p("x", "x_spans", .length_list), p("y", "y_spans", .length_list) }),
    // With `EXCEPTOTHERSPAN` per list, `none` for a list without one.
    drc("span_length", .absent, "span_length", &.{0}, null, &.{ p("x", "x_spans", .length_list), p("y", "y_spans", .length_list), opt("x_except", "x_except", .length), opt("y_except", "y_except", .length) }),
    // The exact centre-to-centre pitch of neighbouring rectangles along one
    // axis (ASAP7 FIN.S.1, GATE.S.1): `pitch(fin, vertical) == 27nm`.
    over(drc("pitch", .eq, "exact_pitch", &.{0}, limit, &.{}), .{ .modifier = "vertical", .fixed = &.{.{ "vertical", true }} }),
    over(drc("pitch", .eq, "exact_pitch", &.{0}, limit, &.{}), .{ .modifier = "horizontal", .fixed = &.{.{ "vertical", false }} }),
    // Another shape inside the keep-out box of an end of line
    // (`LEF58_EOLKEEPOUT eolWidth EXTENSION backward side forward`).
    drc("eol_keep_out", .absent, "eol_keep_out", &.{0}, null, &.{ p("eol_width", "eol_width", .length), p("backward", "backward", .length), p("side", "side", .length), p("forward", "forward", .length) }),
    // With `EXCEPTWITHIN withinLow withinHigh` and `CORNERONLY`.
    drc("eol_keep_out", .absent, "eol_keep_out", &.{0}, null, &.{ p("eol_width", "eol_width", .length), p("backward", "backward", .length), p("side", "side", .length), p("forward", "forward", .length), opt("except_within", "", .{ .group = keep_out_except }), p("corner_only", "corner_only", .bool) }),
    // Too little space from an end of line extended by its width's row
    // (`LEF58_EOLEXTENSIONSPACING spacing {ENDOFLINE eolWidth EXTENSION
    // extension [ENDTOEND endToEndExtension]} ... [MINLENGTH minLength
    // [TWOSIDES]]`): one list element per row.
    drc("eol_extension_space", .ge, "eol_extension_spacing", &.{0}, limit, &.{ p("eol_width", "eol_width", .length_list), p("extension", "extension", .length_list), p("end_to_end", "end_to_end", .opt_length_list), opt("side_length", "", .{ .group = eol_min_length }) }),
    // Another cut inside a cut class's keep-out zones (`LEF58_KEEPOUTZONE
    // CUTCLASS c1 [TO c2] ENDEXTENSION .. SIDEEXTENSION ..`).
    drc("keep_out_zone", .absent, "keep_out_zone", &.{0}, null, &.{ p("class", "short", .{ .length_pair = "long" }), opt("to", "to_short", .{ .length_pair = "to_long" }), p("end_side", "end_side", .length), p("end_forward", "end_forward", .length), p("side_side", "side_side", .length), p("side_forward", "side_forward", .length) }),
    // A gap in a forbidden range between facing edges that run alongside
    // (`LEF58_TWOWIRESFORBIDDENSPACING`).
    drc("forbidden_space", .absent, "forbidden_spacing", &.{0}, null, &.{ p("min", "min", .length), p("max", "max", .length), p("prl", "prl", .length) }),
    // Edge layers.
    drc("length", .ge, "edge_min_length", &.{0}, limit, &.{}),
    drc("space", .ge, "edge_spacing", &.{0}, limit, &.{}),
    drc("space", .ge, "edge_spacing", &.{ 0, 1 }, limit, &.{}),
    drc("enclosure", .ge, "edge_enclosure", &.{ 0, 1 }, limit, &.{}),
    // Edges facing each other across their shapes' material (back to back), as
    // a channel's length and width (sky130 poly.1b, difftap.2) or a width in
    // one direction (ASAP7 M4.W.1 on `met4.edges().horizontal()`).
    drc("width", .ge, "edge_width", &.{0}, limit, &.{}),
    // Edges whose outer sides face each other (face to face): a spacing in one
    // direction (ASAP7 M4.S.2 on `met4.edges().vertical()`).
    drc("facing_space", .ge, "edge_facing_space", &.{0}, limit, &.{}),
    // The same for pairs running alongside each other longer than `prl`
    // (`LEF58_SPACING ... WRONGDIRECTION PRL`).
    drc("facing_space", .ge, "edge_facing_space", &.{0}, limit, &.{p("prl", "prl", .length)}),
    // ERC.
    erc("antenna", &.{ 0, 1 }, true, &.{ p("max_ratio", "max_ratio", .scalar), opt("sidewall", "sidewall_thickness", .length), opt("diode", "diode_layer", .layer), opt("diode_area", "diode_area", .area), opt("diode_min", "diode_min", .area) }),
    erc("antenna_electrical", &.{ 0, 1 }, true, &.{ p("max_ratio", "max_ratio", .scalar), opt("sidewall", "sidewall_thickness", .length), p("cut_factor", "cut_factor", .scalar), opt("diode", "diode_layer", .layer), p("diode_credit", "diode_credit", .scalar), p("diode_bonus", "diode_bonus", .scalar), p("area_minus_diode", "area_minus_diode", .scalar), p("gate_plus_diode", "gate_plus_diode", .scalar), opt("diode_reduce", "diode_reduce_area", .{ .area_table = "diode_reduce" }), opt("diode_max_ratio", "diode_max_ratio_area", .{ .area_table = "diode_max_ratio" }), opt("exempt", "exempt_layer", .layer) }),
    erc("conditional_tie", &.{ 0, 1, 2, 3 }, false, &.{ p("within", "within", .length), p("spacing", "spacing", .length_list), p("max_distance", "max_distance", .length_list) }),
    erc("density_cmp", &.{0}, false, &.{ p("window", "window_x", .{ .length_pair = "window_y" }), p("step", "step_x", .{ .length_pair = "step_y" }), opt("min", "min_density", .fraction), opt("max", "max_density", .fraction), opt("max_delta", "max_neighbour_delta", .fraction), p("partial_windows", "include_partial_windows", .bool), opt("cmp", "", .{ .group = cmp_model }) }),
    erc("electromigration", &.{0}, true, &.{ p("max_density", "max_density", .current_per_width), p("max_current_per_cut", "max_current_per_cut", .current), p("blech_limit", "blech_limit", .current), p("reference_temperature", "reference_temperature", .temperature), p("activation_energy", "activation_energy_ev", .energy), p("current_exponent", "current_exponent", .scalar) }),
    erc("em_current_density", &.{0}, true, em_density),
    erc("em_rms", &.{0}, true, em_ac),
    erc("em_peak", &.{0}, true, em_ac),
    erc("esd_latchup", &.{ 0, 1 }, false, &.{ p("min_guard_ring_width", "min_guard_ring_width", .length), p("max_tap_distance", "max_tap_distance", .length), p("clamps", "clamp", .models) }),
    erc("esd_cross_domain", &.{}, false, &.{ p("diodes", "diode", .models), opt("local", "local", .models), opt("resistors", "resistor", .models), opt("min_series", "min_series", .resistance), opt("max_ground_resistance", "max_ground_resistance", .resistance), opt("coupling_resistance", "coupling_resistance", .resistance) }),
    erc("esd_exposed", &.{0}, false, &.{ p("clamps", "clamp", .models), opt("resistors", "resistor", .models), opt("rated", "rated", .models), opt("min_series", "min_series", .resistance) }),
    erc("esd_ground_coupling", &.{}, false, &.{p("diodes", "diode", .models)}),
    erc("esd_parasitic", &.{ 0, 1 }, false, &.{p("min_spacing", "min_spacing", .length)}),
    erc("esd_path", &.{0}, false, esd_path),
    // The current enters at a second layer's polygons: a guard ring under an
    // injection stress (JESD78).
    erc("esd_path", &.{ 0, 1 }, false, esd_path),
    erc("esd_topological", &.{0}, false, &.{p("clamps", "clamp", .models)}),
    erc("floating_gate", &.{}, false, &.{p("labels_are_ports", "labels_are_ports", .bool)}),
    erc("floating_well", &.{ 0, 1 }, false, &.{}),
    erc("fanout", &.{}, false, &.{p("max", "max_gates", .count)}),
    erc("net_type", &.{}, false, &.{ opt("net", "net", .names), opt("path", "path", .names), opt("break", "break", .names), opt("exclude", "exclude", .names) }),
    erc("gate_path", &.{}, false, &.{ p("ground", "ground", .bool), p("max_devices", "max_devices", .count) }),
    erc("supply_path", &.{}, false, &.{ p("both", "both", .bool), p("labels_are_ports", "labels_are_ports", .bool) }),
    erc("combinational_loop", &.{}, false, &.{}),
    erc("floating_supply", &.{}, false, &.{}),
    erc("power_switch", &.{}, false, &.{p("models", "model", .models)}),
    erc("matching", &.{0}, false, &.{p("tolerance", "tolerance", .length)}),
    erc("esd_pin_pair", &.{0}, false, &.{ p("clamps", "clamp", .models), p("current", "current", .current), p("clamp_resistance", "clamp_resistance", .resistance), p("max_resistance", "max_resistance", .resistance) }),
    erc("esd_clamp_resistance", &.{0}, false, &.{ p("clamps", "clamp", .models), p("max_resistance", "max_resistance", .resistance) }),
    erc("forward_diode", &.{0}, false, &.{p("models", "model", .models)}),
    erc("guard_ring", &.{ 0, 1 }, false, &.{ opt("max_space", "max_space", .length), opt("min_width", "min_width", .length), opt("pad", "pad", .layer), opt("near", "near", .layer), opt("within", "within", .length), opt("clear", "clear", .layer) }),
    erc("guard_ring_bias", &.{0}, false, &.{p("power", "power", .bool)}),
    erc("hv_domain", &.{}, false, &.{ p("max_delta", "max_domain_delta", .voltage), opt("isolation", "isolation", .layer) }),
    erc("ir_drop", &.{}, false, &.{}),
    erc("dynamic_ir_drop", &.{}, false, &.{}),
    erc("em_thermal", &.{0}, true, &.{ p("max_density", "max_density", .current_per_width), p("max_current_per_cut", "max_current_per_cut", .current), p("blech_limit", "blech_limit", .current), p("reference_temperature", "reference_temperature", .temperature), p("activation_energy", "activation_energy_ev", .energy), p("current_exponent", "current_exponent", .scalar), p("thermal_conductivity", "thermal_conductivity", .thermal_conductivity), p("spreading", "heat_spreading", .scalar), p("sigma", "sigma", .scalar), p("limit_failure", "limit_failure", .fraction), p("max_failure", "max_failure", .fraction) }),
    erc("latchup_victim", &.{ 0, 1, 2 }, false, &.{ p("within", "within", .length), p("max_distance", "max_distance", .length), opt("pad", "pad", .layer), opt("bias", "bias", .layer), opt("forward", "forward", .{ .word = &.{ "above", "below" } }) }),
    erc("missing_tie", &.{ 0, 1 }, false, &.{p("max_distance", "max_distance", .length)}),
    erc("multiple_drivers", &.{}, false, &.{p("max", "max_drivers", .count)}),
    erc("p2p_resistance", &.{}, false, &.{p("max", "max_resistance", .resistance)}),
    erc("reliability", &.{}, false, &.{ p("required_lifetime", "required_lifetime_hours", .time), p("reference_lifetime", "reference_lifetime_hours", .time), p("reference_stress", "reference_stress", .voltage), p("stress_exponent", "stress_exponent", .scalar), p("reference_temperature", "reference_temperature", .temperature), p("activation_energy", "activation_energy_ev", .energy), p("max_abs_voltage", "max_abs_voltage", .voltage), p("duty_cycle", "duty_cycle", .fraction) }),
    erc("soft_connection", &.{0}, true, &.{}),
    erc("supply_short", &.{ 0, 1 }, false, &.{}),
    erc("supply_short", &.{ 0, 1, 2 }, false, &.{}),
    erc("tie_area", &.{ 0, 1, 2 }, false, &.{p("min_ratio", "min_ratio", .fraction)}),
    erc("tie_high_low", &.{}, false, &.{}),
    erc("unconnected_pin", &.{0}, true, &.{}),
    erc("gate_oxide", &.{}, false, &.{ p("models", "model", .models), p("max", "max_voltage", .voltage) }),
    erc("drain_source", &.{}, false, &.{ p("models", "model", .models), p("max", "max_voltage", .voltage) }),
    erc("hot_carrier", &.{}, false, &.{ p("models", "model", .models), p("max_length", "max_length", .length) }),
    erc("well_sharing", &.{}, false, &.{ p("models", "model", .models), p("resistors", "resistors", .bool) }),
    erc("well_bias", &.{}, false, &.{ opt("pmos", "pmos", .models), opt("nmos", "nmos", .models) }),
    erc("missing_level_shifter", &.{}, false, &.{opt("shifters", "shifter", .models)}),
    erc("domain_crossing", &.{}, false, &.{}),
    // A high-voltage figure of a conductor lies inside its tag (sky130 hv.X.1,
    // hv.X.4, hvnwell.11); a net holds no tagged and untagged figure at once
    // (hvnwell.10).
    erc("hv_tag", &.{ 0, 1 }, false, &.{p("voltage", "voltage", .voltage)}),
    erc("mixed_tag", &.{ 0, 1 }, false, &.{}),
    // In the intent's power states: a gate left floating (ERC-F8), and a
    // powered transistor with a floating gate, not an isolation cell (ERC-F7).
    erc("undriven_gate", &.{}, false, &.{}),
    erc("missing_isolation", &.{}, false, &.{opt("isolation", "isolation", .models)}),
    // The field across the dielectric between two nets' shapes (JEP159A,
    // IC Validator): lateral on one layer, through the stack between two.
    erc("dielectric_field", &.{0}, false, &.{p("max_field", "max_field", .field)}),
    erc("dielectric_field", &.{ 0, 1 }, false, &.{p("max_field", "max_field", .field)}),
    // Spacing that grows with the worst-case voltage between two nets
    // (LEF58_VOLTAGESPACING, sky130 hvnwell.8): one layer, or two.
    over(erc("voltage_space", &.{0}, false, voltage_space), .{ .engine = "voltage_spacing" }),
    over(erc("voltage_space", &.{ 0, 1 }, false, voltage_space), .{ .engine = "voltage_spacing" }),
};

const limit: ?Param = p("", "limit", .length);
const area: ?Param = p("", "limit", .area);
const density: []const Param = &.{ p("window", "window", .length), p("step", "step", .length) };
const density_limit: ?Param = p("", "limit", .fraction);
const count: ?Param = p("", "limit", .count);
/// The checks a DFM score reads, in the order of the engine's index.
const dfm_checks: []const []const u8 = &.{ "space", "width", "enclosure" };
/// MINSTEP's corner kinds, in the order of the engine's index.
const step_corners: []const []const u8 = &.{ "outside", "inside", "step" };
/// A voltage-dependent spacing table: the step voltages and the spacing from
/// each one up.
const voltage_space: []const Param = &.{ p("voltage", "voltage", .voltage_list), p("space", "space", .length_list) };
/// A narrow-line current band: a metal line at most `width` wide may carry
/// `current` (IHP SG13G2 §2.15's IMAX beside JMAX).
const em_narrow: []const Param = &.{ p("width", "narrow_width", .length), p("current", "narrow_current", .current) };
/// The current-density limits of `em_current_density`, `em_rms` and `em_peak`.
const em_density: []const Param = &.{
    p("max_density", "max_density", .current_per_width),
    p("max_current_per_cut", "max_current_per_cut", .current),
    opt("narrow", "", .{ .group = em_narrow }),
};
/// The AC current-density table of `em_rms` and `em_peak`: LEF's
/// `ACCURRENTDENSITY {PEAK | RMS} FREQUENCY .. WIDTH .. TABLEENTRIES ..`,
/// one row of densities per frequency, one cell per width.
const em_ac: []const Param = &.{
    p("frequency", "frequency", .frequency_list),
    p("width", "width", .length_list),
    p("density", "density", .current_per_width_rows),
    p("max_current_per_cut", "max_current_per_cut", .current),
};
/// `esd_path`'s parameters, the same with a source layer or without.
const esd_path: []const Param = &.{
    opt("clamps", "clamp", .models),
    p("current", "current", .current),
    p("clamp_resistance", "clamp_resistance", .resistance),
    opt("max_resistance", "max_resistance", .resistance),
    opt("clamp_it2", "clamp_it2", .current_per_width),
    opt("max_density", "max_density", .current_per_width),
    opt("max_current_per_cut", "max_current_per_cut", .current),
    opt("max_voltage", "max_voltage", .voltage),
    opt("min_width", "min_width", .length),
    opt("clamp_voltage", "clamp_voltage", .voltage),
};
/// An enclosure's wire band: the wire widths the rule holds.
const wire_width: []const Param = &.{p("width", "wire_width", .length)};
const wire_below: []const Param = &.{p("below", "wire_below", .length)};
const wire: []const Param = &.{ p("width", "wire_width", .length), p("below", "wire_below", .length) };
/// LEF `ENCLOSURE ... WIDTH minWidth EXCEPTEXTRACUT cutWithin`, the metal on
/// the cuts' far side named: `except_extra_cut:` on the `WIDTH` row, which
/// then holds no cut with a redundant one, and `extra_cut:` on the
/// minimum-width rows written again for the excepted band, which then hold
/// only such cuts (`extra_cut_only`).
const except_extra: []const Param = &.{ p("width", "wire_width", .length), p("except_extra_cut", "extra_cut_within", .length), p("other", "extra_cut_other", .layer) };
const except_extra_below: []const Param = &.{ p("width", "wire_width", .length), p("below", "wire_below", .length), p("except_extra_cut", "extra_cut_within", .length), p("other", "extra_cut_other", .layer) };
const only_extra: []const Param = &.{ p("width", "wire_width", .length), p("extra_cut", "extra_cut_within", .length), p("other", "extra_cut_other", .layer) };
const only_extra_below: []const Param = &.{ p("width", "wire_width", .length), p("below", "wire_below", .length), p("extra_cut", "extra_cut_within", .length), p("other", "extra_cut_other", .layer) };
/// LEF `ENCLOSURE ... LENGTH minLength` (`length:`), and the vias whose
/// overhang length falls short of it (`length_below:`), with or without a
/// wire band's `below:`.
const length: []const Param = &.{p("length", "length_from", .length)};
const length_below: []const Param = &.{ p("length", "length_from", .length), p("below", "wire_below", .length) };
const short: []const Param = &.{p("length_below", "length_below", .length)};
const short_below: []const Param = &.{ p("length_below", "length_below", .length), p("below", "wire_below", .length) };
/// The enclosure rows beyond the plain wire bands: `(params, fixed flags)`.
const qualified = [8]struct { []const Param, []const Fixed }{
    .{ except_extra, &.{.{ "extra_cut_only", false }} },
    .{ except_extra_below, &.{.{ "extra_cut_only", false }} },
    .{ only_extra, &.{.{ "extra_cut_only", true }} },
    .{ only_extra_below, &.{.{ "extra_cut_only", true }} },
    .{ length, &.{} },
    .{ length_below, &.{} },
    .{ short, &.{} },
    .{ short_below, &.{} },
};
const adjacent: []const Param = &.{ p("cuts", "adjacent", .count), p("within", "within", .length) };
/// LEF `PARALLELEDGE parSpace WITHIN parWithin [TWOEDGES]`.
const eol_parallel: []const Param = &.{ p("space", "par_space", .length), p("within", "par_within", .length), p("two_edges", "two_edges", .bool) };
/// `LEF58_SPACING ENDOFLINE`'s `MINLENGTH [TWOSIDES]` / `MAXLENGTH`.
const eol_side_length: []const Param = &.{ p("length", "side_length", .length), p("maximum", "side_length_maximum", .bool), p("two_sides", "side_length_two_sides", .bool) };
/// `LEF58_EOLEXTENSIONSPACING`'s `MINLENGTH minLength [TWOSIDES]`.
const eol_min_length: []const Param = &.{ p("length", "side_length", .length), p("two_sides", "side_length_two_sides", .bool) };
/// `PARALLELEDGE [SUBTRACTEOLWIDTH] .. [MINLENGTH minLength]`.
const eol_parallel_more: []const Param = &.{ p("subtract_eol_width", "par_subtract_eol_width", .bool), opt("min_length", "par_min_length", .length) };
/// `LEF58_EOLKEEPOUT ... EXCEPTWITHIN withinLow withinHigh`.
const keep_out_except: []const Param = &.{ p("low", "within_low", .length), p("high", "within_high", .length) };
/// `ENDPRLSPACING endPrlSpace PRL endPrl`.
const eol_end_prl: []const Param = &.{ p("space", "end_prl_space", .length), p("prl", "end_prl", .length) };
/// `WRONGDIRSPACING wrongDirSpace`, with the layer's preferred direction.
const eol_wrong_dir: []const Param = &.{ p("space", "wrong_dir_space", .length), p("horizontal", "wrong_dir_horizontal", .bool) };
/// `ENCLOSECUT [BELOW | ABOVE] encloseDist CUTSPACING cutToMetalSpace
/// [ALLCUTS]`, the cut layer named.
const eol_enclose_cut: []const Param = &.{ p("cut", "enclose_cut_layer", .layer), p("within", "enclose_cut_within", .length), p("space", "enclose_cut_space", .length), p("all_cuts", "enclose_cut_all", .bool) };
const cmp_model: []const Param = &.{ p("target", "cmp_target_density", .fraction), p("sensitivity", "cmp_thickness_sensitivity", .length), p("max_delta", "cmp_max_abs_thickness_delta", .length) };

/// The slots `engine` takes layers in; empty for a kind that takes polygons only.
pub fn edgeSlots(engine: []const u8) []const ?bool {
    for (edge_kinds) |k| if (std.mem.eql(u8, k.engine, engine)) return k.slots;
    return &.{};
}

/// How a dimension reads in an error.
pub fn dimName(dim: Dim) []const u8 {
    return switch (dim) {
        .length => "a length",
        .area => "an area",
        .voltage => "a voltage",
        .current => "a current",
        .current_per_width => "a current per width",
        .resistance => "a resistance",
        .temperature => "a temperature",
        .energy => "an energy",
        .thermal_conductivity => "a thermal conductivity",
        .time => "a time",
        .field => "an electric field",
        .cap_per_area => "a capacitance per area",
        .cap_per_length => "a capacitance per length",
        .per_kelvin => "a coefficient per kelvin",
        .per_kelvin2 => "a coefficient per kelvin squared",
        .capacitance => "a capacitance",
        .inductance => "an inductance",
        .voltage_length => "a voltage times a length",
        .fraction_length => "a fraction times a length",
        .voltage_per_length => "a voltage per length",
        .fraction => "a fraction",
        .angle => "an angle",
        .scalar => "a number",
        .count => "a count",
        .bool => "true or false",
        .layer => "a layer",
        .length_pair => "a pair of lengths",
        .angle_list => "a list of angles",
        .models => "a list of model names",
        .names => "a list of names",
        .group => "named arguments",
        .nets => "same or different",
        .length_list => "a list of lengths",
        .length_rows => "a list of rows of lengths",
        .length_pair_list => "a list of pairs of lengths",
        .word => "one of the listed words",
        .voltage_list => "a list of voltages",
        .fraction_list => "a list of fractions",
        .count_list => "a list of counts",
        .area_list => "a list of areas",
        .area_table => "a list of (area, number) points",
        .opt_length_list => "a list of lengths or none",
        .frequency => "a frequency",
        .frequency_list => "a list of frequencies",
        .current_per_width_rows => "a list of rows of currents per width",
    };
}

// ---- private ----

fn p(name: []const u8, engine: []const u8, dim: Dim) Param {
    return .{ .name = name, .engine = engine, .dim = dim };
}

fn opt(name: []const u8, engine: []const u8, dim: Dim) Param {
    return .{ .name = name, .engine = engine, .dim = dim, .none = true };
}

/// A DRC row: one comparison.
fn drc(name: []const u8, cmp: Cmp, engine: []const u8, layers: []const u8, lim: ?Param, params: []const Param) Kind {
    return .{ .name = name, .cmp = cmp, .engine = engine, .layers = layers, .limit = lim, .params = params };
}

/// An ERC row: named arguments only.
fn erc(name: []const u8, layers: []const u8, more: bool, params: []const Param) Kind {
    return .{ .name = name, .cmp = .absent, .engine = name, .layers = layers, .more = more, .params = params };
}

/// `k` with the fields Rust's struct update (`Kind { .., ..k }`) sets.
fn over(k: Kind, m: struct { modifier: ?[]const u8 = null, fixed: []const Fixed = &.{}, more: bool = false, engine: ?[]const u8 = null }) Kind {
    var out = k;
    if (m.modifier) |word| out.modifier = word;
    if (m.fixed.len > 0) out.fixed = m.fixed;
    if (m.more) out.more = true;
    if (m.engine) |engine| out.engine = engine;
    return out;
}

/// `enclosure(inner, outer) >= len` with the `n`th `qualified` row.
fn everySide(n: usize) Kind {
    return over(drc("enclosure", .ge, "min_enclosure", &.{ 1, 0 }, limit, qualified[n][0]), .{ .fixed = qualified[n][1] });
}

/// `enclosure(inner, outer, opposite) >= len` with the `n`th `qualified` row.
fn oppositeQualified(n: usize) Kind {
    return over(opposite(qualified[n][0]), .{ .fixed = qualified[n][1] });
}

/// `enclosure(inner, outer, opposite) >= len` with `params`.
fn opposite(params: []const Param) Kind {
    return over(drc("enclosure", .ge, "asymmetric_enclosure", &.{ 1, 0 }, p("", "min_one_side", .length), params), .{ .modifier = "opposite" });
}
