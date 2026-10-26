//! Every rule kind's row constructor, for a deck built in code. In: a kind,
//! its layer arguments and its parameters, all comptime. Out: a `RuleRow`,
//! the rule as the parser would read it, which `DeckBuilder.finish` types
//! and validates as it does deck text. Ported from
//! crates/check/src/deck/rules.rs (`kinds!`, `RuleRow`, `Arg`).
//!
//! `specs` holds one row per kind (DRC in `Rule` variant order, then ERC):
//! its layer arguments in deck order, and its parameters by engine name,
//! each typed so a missing one or a bare number where a list goes does not
//! compile. One generic `row` reads it (codebase-clean-code rung 5, a
//! comptime parameter): Rust generates 140 constructors with a macro; a
//! comptime table plus one function is the cheapest form that keeps the
//! check at compile time, where 140 hand-written functions would be 140
//! bodies to keep in step. `.{ .layer = layer("met1") }` and
//! `.{ .limit = 140 }` read as the deck does.
//!
//! Lengths are `Dbu` and areas `DbuArea` on the builder's grid; every other
//! quantity an `f64` in the unit its parameter names. A Rust tuple or enum
//! argument is its engine parameters here (`adjacent` and `within`, `corner`
//! or `max_edges`), and the Rust row modifiers (`wire`, `extra_cut`, `eol58`,
//! `open_last`, ..) are the kind's optional parameters; `warning` is
//! `RuleRow.warned`.
//!
//! ponytail: values are comptime, so a row's slices are static and `row`
//! takes no allocator; a row from run-time values is a `RuleRow` literal.
//!
//! Contents:
//! - `pub const RuleRow = struct`, `RuleRow.warned(r: RuleRow) RuleRow`
//! - `pub const Corner = enum(u32)`, `pub const DfmCheck = enum(u32)`
//! - `pub const specs`, `pub const Kind = std.meta.FieldEnum(@TypeOf(specs))`
//! - `pub inline fn row(comptime kind: Kind, comptime layers: Spec(kind).Layers, comptime params: Spec(kind).Params) RuleRow`

const std = @import("std");
const geom = @import("geom");
const Dbu = geom.Dbu;
const DbuArea = geom.DbuArea;
const ingest_deck = @import("ingest").deck;
const NamedSource = ingest_deck.NamedSource;
const ParamSource = ingest_deck.ParamSource;
const ParamValue = ingest_deck.ParamValue;
const expr = @import("expr.zig");
const Expr = expr.Expr;

/// One rule before it has an id: its kind, its layer arguments in deck
/// order, and its parameters by engine name.
pub const RuleRow = struct {
    kind: []const u8,
    layers: []const Expr = &.{},
    /// Engine layer slot `i` takes `layers[slots[i]]`; empty when the
    /// engine takes the deck's order.
    slots: []const u8 = &.{},
    params: []const NamedSource = &.{},
    /// Every finding of the rule a warning (catalog DRC-110).
    warning: bool = false,

    /// The deck's `rule <id> warning ..`.
    pub fn warned(r: RuleRow) RuleRow {
        var w = r;
        w.warning = true;
        return w;
    }
};

/// LEF `MINSTEP`'s corner forms, by the index the engine reads.
pub const Corner = enum(u32) { outside, inside, step };

/// The check a DFM score reads, by the index the engine reads.
pub const DfmCheck = enum(u32) { space, width, enclosure };

/// One row per kind: `spec(layers, params)`, or `swap` where the engine
/// takes the second layer argument first.
pub const specs = .{
    .min_width = spec(struct { layer: Expr }, struct { limit: Dbu }),
    .max_width = spec(struct { layer: Expr }, struct { limit: Dbu }),
    .cut_size = spec(struct { layer: Expr }, struct { width: Dbu, height: Dbu }),
    .min_edge_length = spec(struct { layer: Expr }, struct { limit: Dbu }),
    .notch = spec(struct { layer: Expr }, struct { limit: Dbu }),
    .min_spacing = spec(struct { layer: Expr }, struct { limit: Dbu }),
    .min_spacing_diff = spec(struct { a: Expr, b: Expr }, struct { limit: Dbu }),
    .projection_spacing = spec(struct { a: Expr, b: Expr }, struct { limit: Dbu }),
    .eol_spacing = spec(struct { layer: Expr }, struct { eol_width: Dbu, limit: Dbu }),
    .prl_spacing = spec(struct { layer: Expr }, struct { prl_threshold: Dbu, limit: Dbu }),
    .corner_to_corner = spec(struct { layer: Expr }, struct { limit: Dbu }),
    .wide_dependent_spacing = spec(struct { layer: Expr }, struct { width_threshold: Dbu, limit: Dbu }),
    .min_area = spec(struct { layer: Expr }, struct { limit: DbuArea }),
    .min_enclosed_area = spec(struct { layer: Expr }, struct { limit: DbuArea }),
    .cheesing = spec(struct { layer: Expr }, struct { max_unslotted: DbuArea }),
    .density = spec(struct { layer: Expr, boundary: ?Expr = null }, struct { window: Dbu, step: Dbu, limit: f64, maximum: bool }),
    .global_density = spec(struct { layer: Expr, boundary: ?Expr = null }, struct { limit: f64, maximum: bool }),
    .critical_area = spec(struct { layer: Expr }, struct { radius: Dbu, limit: DbuArea }),
    .mean_critical_area = spec(struct { layer: Expr }, struct { radii: []const Dbu, weights: []const f64, limit: DbuArea }),
    .density_balance = spec(struct { a: Expr, b: Expr, boundary: ?Expr = null }, struct { window: Dbu, step: Dbu, limit: f64 }),
    .via_redundancy = spec(struct { cut: Expr, lower: Expr, upper: Expr }, struct { pitch: Dbu, space: Dbu, limit: f64 }),
    .dfm_score = spec(struct { layer: Expr, outer: ?Expr = null }, struct { check: DfmCheck, required: Dbu, recommended: Dbu, rate: f64, limit: f64 }),
    .pattern_match = spec(struct { layer: Expr }, struct { window_w: Dbu, window_h: Dbu, shape_x: []const Dbu, shape_y: []const Dbu, ignore_x: []const Dbu, ignore_y: []const Dbu }),
    .cut_area_change = spec(struct { pre: Expr, post: Expr, lower: Expr, upper: Expr }, struct { cuts: []const u32, change: []const DbuArea }),
    .cover_density = spec(struct { layer: Expr, by: Expr, boundary: ?Expr = null }, struct { window: Dbu, step: Dbu, cover: []const f64, density: []const f64, inclusive: bool }),
    .min_enclosure = swap(struct { inner: Expr, outer: Expr }, struct { limit: Dbu, wire_width: ?Dbu = null, wire_below: ?Dbu = null, extra_cut_within: ?Dbu = null, extra_cut_other: ?[]const u8 = null, extra_cut_only: ?bool = null, length_from: ?Dbu = null, length_below: ?Dbu = null }),
    .noncoincident_enclosure = swap(struct { inner: Expr, outer: Expr }, struct { limit: Dbu }),
    .full_width = swap(struct { inner: Expr, outer: Expr }, struct {}),
    .asymmetric_enclosure = swap(struct { inner: Expr, outer: Expr }, struct { min_one_side: Dbu, wire_width: ?Dbu = null, wire_below: ?Dbu = null, extra_cut_within: ?Dbu = null, extra_cut_other: ?[]const u8 = null, extra_cut_only: ?bool = null, length_from: ?Dbu = null, length_below: ?Dbu = null }),
    .max_enclosure = swap(struct { inner: Expr, outer: Expr }, struct { limit: Dbu }),
    .adjacent_enclosure = swap(struct { inner: Expr, outer: Expr }, struct { min_one_side: Dbu }),
    .min_extension = spec(struct { layer: Expr, reference: Expr }, struct { limit: Dbu }),
    .gate_corner = spec(struct { layer: Expr, reference: Expr }, struct { of_reference: bool }),
    .overlap = spec(struct { a: Expr, b: Expr }, struct { limit: Dbu }),
    .max_distance_to_tap = spec(struct { well: Expr, tap: Expr }, struct { limit: Dbu }),
    .off_grid = spec(struct {}, struct { pitch: Dbu }),
    .angle = spec(struct { layer: ?Expr = null }, struct { angle: []const u32 }),
    .redundant_via = spec(struct { layer: Expr }, struct { min_count: u32, within: Dbu }),
    .minimum_cut = spec(struct { cut: Expr, wide: Expr, other: Expr }, struct { width: Dbu, within: ?Dbu = null, min_count: u32, length: ?Dbu = null, distance: ?Dbu = null }),
    .via_stack = spec(struct { cuts: []const []const u8 }, struct { max_height: u32, single: ?bool = null }),
    .metal_width_via = spec(struct { cut: Expr, below: Expr, above: Expr }, struct { below_min: Dbu, below_max: Dbu, above_min: Dbu, above_max: Dbu, cut_width: Dbu, cut_height: Dbu }),
    .stack_spacing = spec(struct { a: Expr, b: Expr, metal: Expr }, struct { same_net: bool, limit: Dbu }),
    .max_cut_spacing = spec(struct { cut: Expr, others: ?Expr = null }, struct { limit: Dbu }),
    .via_array_spacing = spec(struct { layer: Expr }, struct { array_threshold: u32, limit: Dbu }),
    .cut_spacing = spec(struct { layer: Expr }, struct { center: bool, adjacent: ?u32 = null, within: ?Dbu = null, limit: Dbu }),
    .cut_class_spacing = spec(struct { layer: Expr }, struct { class_short: []const Dbu, class_long: []const Dbu, space: []const Dbu }),
    .multi_patterning = spec(struct { layer: Expr }, struct { colors: u32, color_spacing: Dbu }),
    .anchored_patterning = spec(struct { layer: Expr, anchors: []const []const u8 }, struct { colors: u32, color_spacing: Dbu }),
    .sadp = spec(struct { layer: Expr }, struct { different: Dbu, same: Dbu, track_width: ?Dbu = null, track_space: ?Dbu = null }),
    .sadp_line_end = spec(struct { layer: Expr }, struct { adjacent: Dbu, tip: Dbu, overlap: Dbu, corner: Dbu, offset: Dbu }),
    .forbidden = spec(struct { layer: Expr }, struct {}),
    // The deck's three spellings: `>= min_count`, `<= max_count`, `== count`.
    .must_contain = spec(struct { outer: Expr, inner: Expr }, struct { min_count: ?u32 = null, max_count: ?u32 = null, count: ?u32 = null }),
    .must_be_inside = spec(struct { inner: Expr, outer: Expr }, struct {}),
    .net_spacing = spec(struct { layer: Expr, other: ?Expr = null }, struct { same_net: bool, limit: Dbu }),
    .spacing_table = spec(struct { layer: Expr }, struct { prl: []const Dbu, width: []const Dbu, space: []const Dbu }),
    .attached_wide_spacing = spec(struct { layer: Expr }, struct { width_threshold: Dbu, attached: Dbu, limit: Dbu }),
    .edge_min_length = spec(struct { edges: Expr }, struct { limit: Dbu }),
    .edge_spacing = spec(struct { a: Expr, b: ?Expr = null }, struct { limit: Dbu }),
    .edge_enclosure = spec(struct { edges: Expr, outer: Expr }, struct { limit: Dbu }),
    .count = spec(struct { layer: Expr }, struct { limit: u32, maximum: bool }),
    .aspect_ratio = spec(struct { layer: Expr }, struct { limit: f64 }),
    .total_area = spec(struct { layer: Expr }, struct { limit: DbuArea }),
    .cut_class = spec(struct { layer: Expr }, struct { width: []const Dbu, height: []const Dbu }),
    .edge_width = spec(struct { edges: Expr }, struct { limit: Dbu }),
    .edge_facing_space = spec(struct { edges: Expr }, struct { limit: Dbu, prl: ?Dbu = null }),
    .region_density = spec(struct { layer: Expr, region: Expr }, struct { limit: f64, maximum: bool }),
    .allowed_width = spec(struct { layer: Expr }, struct { width: []const Dbu, open_last: ?bool = null }),
    .min_interior_angle = spec(struct { layer: ?Expr = null }, struct { limit: f64 }),
    .polygon_validity = spec(struct { layer: ?Expr = null }, struct {}),
    .min_step = spec(struct { layer: Expr }, struct { limit: Dbu, max_edges: ?u32 = null, corner: ?Corner = null, length_sum: ?Dbu = null }),
    .min_step_adjacent = spec(struct { layer: Expr }, struct { limit: Dbu, adjacent: ?Dbu = null, adjacent_eol: ?Dbu = null, except_rectangle: ?bool = null, between_eol: ?Dbu = null }),
    .tip_spacing_table = spec(struct { layer: Expr }, struct { length: []const Dbu, space: []const Dbu }),
    .forbidden_spacing = spec(struct { layer: Expr }, struct { min: Dbu, max: Dbu, prl: Dbu }),
    .eol_within_spacing = spec(struct { layer: Expr }, struct { eol_width: Dbu, eol_within: Dbu, par_space: ?Dbu = null, par_within: ?Dbu = null, two_edges: ?bool = null, end_to_end: ?Dbu = null, limit: Dbu, side_length: ?Dbu = null, side_length_maximum: ?bool = null, side_length_two_sides: ?bool = null, opposite_width: ?Dbu = null, par_subtract_eol_width: ?bool = null, par_min_length: ?Dbu = null, end_prl_space: ?Dbu = null, end_prl: ?Dbu = null, wrong_dir_space: ?Dbu = null, wrong_dir_horizontal: ?bool = null, eol_extension: ?Dbu = null, enclose_cut_layer: ?[]const u8 = null, enclose_cut_within: ?Dbu = null, enclose_cut_space: ?Dbu = null, enclose_cut_all: ?bool = null }),
    .eol_keep_out = spec(struct { layer: Expr }, struct { eol_width: Dbu, backward: Dbu, side: Dbu, forward: Dbu, within_low: ?Dbu = null, within_high: ?Dbu = null, corner_only: ?bool = null }),
    .eol_extension_spacing = spec(struct { layer: Expr }, struct { eol_width: []const Dbu, extension: []const Dbu, end_to_end: []const ?Dbu, limit: Dbu, side_length: ?Dbu = null, side_length_two_sides: ?bool = null }),
    .origin = spec(struct { layer: Expr }, struct {}),
    .protrusion_width = spec(struct { layer: Expr }, struct { wide: Dbu, limit: Dbu }),
    .keep_out_zone = spec(struct { layer: Expr }, struct { short: Dbu, long: Dbu, to_short: ?Dbu = null, to_long: ?Dbu = null, end_side: Dbu, end_forward: Dbu, side_side: Dbu, side_forward: Dbu }),
    .two_width_spacing_table = spec(struct { layer: Expr }, struct { width: []const Dbu, prl: []const ?Dbu, space: []const Dbu }),
    .span_length = spec(struct { layer: Expr }, struct { x_spans: []const Dbu, y_spans: []const Dbu, x_except: ?Dbu = null, y_except: ?Dbu = null }),
    .convex_corner_spacing = spec(struct { layer: Expr }, struct { corner_to_corner: bool, except_eol: ?Dbu = null, limit: Dbu }),
    .exact_pitch = spec(struct { layer: Expr }, struct { vertical: bool, limit: Dbu }),
    // ERC
    .antenna = spec(struct { gate: Expr, collectors: []const []const u8 }, struct { max_ratio: f64, sidewall_thickness: ?Dbu = null, diode_layer: ?[]const u8 = null, diode_area: ?DbuArea = null, diode_min: ?DbuArea = null }),
    .antenna_electrical = spec(struct { gate: Expr, collectors: []const []const u8 }, struct { max_ratio: f64, sidewall_thickness: ?Dbu = null, cut_factor: f64, diode_layer: ?[]const u8 = null, diode_credit: f64, diode_bonus: f64, area_minus_diode: f64, gate_plus_diode: f64, diode_reduce_area: []const DbuArea = &.{}, diode_reduce: []const f64 = &.{}, diode_max_ratio_area: []const DbuArea = &.{}, diode_max_ratio: []const f64 = &.{}, exempt_layer: ?[]const u8 = null }),
    .conditional_tie = spec(struct { region: Expr, tap: Expr, well: Expr, other: Expr }, struct { within: Dbu, spacing: []const Dbu, max_distance: []const Dbu }),
    .density_cmp = spec(struct { layer: Expr }, struct { window_x: Dbu, window_y: Dbu, step_x: Dbu, step_y: Dbu, min_density: ?f64 = null, max_density: ?f64 = null, max_neighbour_delta: ?f64 = null, include_partial_windows: bool, cmp_target_density: ?f64 = null, cmp_thickness_sensitivity: ?Dbu = null, cmp_max_abs_thickness_delta: ?Dbu = null }),
    .dielectric_field = spec(struct { layer: Expr, other: ?Expr = null }, struct { max_field: f64 }),
    .domain_crossing = spec(struct {}, struct {}),
    .drain_source = spec(struct {}, struct { model: []const []const u8, max_voltage: f64 }),
    .dynamic_ir_drop = spec(struct {}, struct {}),
    .electromigration = spec(struct { layers: []const []const u8 }, struct { max_density: f64, max_current_per_cut: f64, blech_limit: f64, reference_temperature: f64, activation_energy_ev: f64, current_exponent: f64 }),
    .em_current_density = spec(struct { layers: []const []const u8 }, struct { max_density: f64, max_current_per_cut: f64, narrow_width: ?Dbu = null, narrow_current: ?f64 = null }),
    .em_rms = spec(struct { layers: []const []const u8 }, struct { frequency: []const f64, width: []const Dbu, density: []const f64, max_current_per_cut: f64 }),
    .em_peak = spec(struct { layers: []const []const u8 }, struct { frequency: []const f64, width: []const Dbu, density: []const f64, max_current_per_cut: f64 }),
    .em_thermal = spec(struct { layers: []const []const u8 }, struct { max_density: f64, max_current_per_cut: f64, blech_limit: f64, reference_temperature: f64, activation_energy_ev: f64, current_exponent: f64, thermal_conductivity: f64, heat_spreading: f64, sigma: f64, limit_failure: f64, max_failure: f64 }),
    .esd_cross_domain = spec(struct {}, struct { diode: []const []const u8, local: []const []const u8, resistor: []const []const u8, min_series: ?f64 = null, max_ground_resistance: ?f64 = null, coupling_resistance: ?f64 = null }),
    .esd_exposed = spec(struct { pad: Expr }, struct { clamp: []const []const u8, resistor: []const []const u8, rated: []const []const u8, min_series: ?f64 = null }),
    .esd_ground_coupling = spec(struct {}, struct { diode: []const []const u8 }),
    .esd_latchup = spec(struct { pad: Expr, guard_ring: Expr }, struct { min_guard_ring_width: Dbu, max_tap_distance: Dbu, clamp: []const []const u8 }),
    .esd_parasitic = spec(struct { pad: Expr, diffusion: Expr }, struct { min_spacing: Dbu }),
    .esd_path = spec(struct { pad: Expr, source: ?Expr = null }, struct { clamp: []const []const u8, current: f64, clamp_resistance: f64, max_resistance: ?f64 = null, clamp_it2: ?f64 = null, max_density: ?f64 = null, max_current_per_cut: ?f64 = null, max_voltage: ?f64 = null, min_width: ?Dbu = null, clamp_voltage: ?f64 = null }),
    .esd_pin_pair = spec(struct { pad: Expr }, struct { clamp: []const []const u8, current: f64, clamp_resistance: f64, max_resistance: f64 }),
    .esd_clamp_resistance = spec(struct { pad: Expr }, struct { clamp: []const []const u8, max_resistance: f64 }),
    .esd_topological = spec(struct { pad: Expr }, struct { clamp: []const []const u8 }),
    .fanout = spec(struct {}, struct { max_gates: u32 }),
    .floating_gate = spec(struct {}, struct { labels_are_ports: bool }),
    .floating_well = spec(struct { well: Expr, tap: Expr }, struct {}),
    .power_switch = spec(struct {}, struct { model: []const []const u8 }),
    .matching = spec(struct { group: Expr }, struct { tolerance: Dbu }),
    .floating_supply = spec(struct {}, struct {}),
    .forward_diode = spec(struct { marker: Expr }, struct { model: []const []const u8 }),
    .combinational_loop = spec(struct {}, struct {}),
    .gate_oxide = spec(struct {}, struct { model: []const []const u8, max_voltage: f64 }),
    .gate_path = spec(struct {}, struct { ground: bool, max_devices: u32 }),
    .guard_ring = spec(struct { target: Expr, ring: Expr }, struct { max_space: ?Dbu = null, min_width: ?Dbu = null, pad: ?[]const u8 = null, near: ?[]const u8 = null, within: ?Dbu = null, clear: ?[]const u8 = null }),
    .guard_ring_bias = spec(struct { ring: Expr }, struct { power: bool }),
    .hot_carrier = spec(struct {}, struct { model: []const []const u8, max_length: Dbu }),
    .hv_domain = spec(struct {}, struct { max_domain_delta: f64, isolation: ?[]const u8 = null }),
    .hv_tag = spec(struct { layer: Expr, tag: Expr }, struct { voltage: f64 }),
    .ir_drop = spec(struct {}, struct {}),
    .latchup_victim = spec(struct { aggressor: Expr, region: Expr, tap: Expr }, struct { within: Dbu, max_distance: Dbu, pad: ?[]const u8 = null, bias: ?[]const u8 = null, forward: ?u32 = null }),
    .missing_isolation = spec(struct {}, struct { isolation: []const []const u8 }),
    .missing_level_shifter = spec(struct {}, struct { shifter: []const []const u8 }),
    .missing_tie = spec(struct { region: Expr, tap: Expr }, struct { max_distance: Dbu }),
    .mixed_tag = spec(struct { layer: Expr, tag: Expr }, struct {}),
    .multiple_drivers = spec(struct {}, struct { max_drivers: u32 }),
    .net_type = spec(struct {}, struct { net: []const []const u8, path: []const []const u8, @"break": []const []const u8, exclude: []const []const u8 }),
    .p2p_resistance = spec(struct {}, struct { max_resistance: f64 }),
    .reliability = spec(struct {}, struct { required_lifetime_hours: f64, reference_lifetime_hours: f64, reference_stress: f64, stress_exponent: f64, reference_temperature: f64, activation_energy_ev: f64, max_abs_voltage: f64, duty_cycle: f64 }),
    .soft_connection = spec(struct { layers: []const []const u8 }, struct {}),
    .supply_short = spec(struct { tap_a: Expr, tap_b: Expr, within: ?Expr = null }, struct {}),
    .supply_path = spec(struct {}, struct { both: bool, labels_are_ports: bool }),
    .tie_area = spec(struct { region: Expr, contact: Expr, channel: Expr }, struct { min_ratio: f64 }),
    .tie_high_low = spec(struct {}, struct {}),
    .unconnected_pin = spec(struct { layers: []const []const u8 }, struct {}),
    .undriven_gate = spec(struct {}, struct {}),
    .voltage_spacing = spec(struct { layer: Expr, other: ?Expr = null }, struct { voltage: []const f64, space: []const Dbu }),
    .well_bias = spec(struct {}, struct { pmos: []const []const u8, nmos: []const []const u8 }),
    .well_sharing = spec(struct {}, struct { model: []const []const u8, resistors: bool }),
};

/// Every kind, DRC then ERC, by the name a deck row resolves to.
pub const Kind = std.meta.FieldEnum(@TypeOf(specs));

/// The row of `kind`: `layers` and `params` are its spec's structs.
pub inline fn row(comptime kind: Kind, comptime layers: Spec(kind).Layers, comptime params: Spec(kind).Params) RuleRow {
    return comptime lower(kind, layers, params);
}

// ---- private ----

fn Spec(comptime kind: Kind) type {
    return @field(specs, @tagName(kind));
}

fn spec(comptime L: type, comptime P: type) type {
    return struct {
        const Layers = L;
        const Params = P;
        const slots: []const u8 = &.{};
    };
}

fn swap(comptime L: type, comptime P: type) type {
    return struct {
        const Layers = L;
        const Params = P;
        const slots: []const u8 = &.{ 1, 0 };
    };
}

fn lower(comptime kind: Kind, comptime layers: anytype, comptime params: anytype) RuleRow {
    const S = Spec(kind);
    var args: []const Expr = &.{};
    for (@typeInfo(S.Layers).@"struct".field_names) |f| {
        const v = @field(layers, f);
        switch (@TypeOf(v)) {
            Expr => args = args ++ .{v},
            ?Expr => if (v) |e| {
                args = args ++ .{e};
            },
            []const []const u8 => for (v) |name| {
                args = args ++ .{expr.layer(name)};
            },
            else => @compileError("a layer argument is an Expr, ?Expr or names"),
        }
    }
    var named: []const NamedSource = &.{};
    for (@typeInfo(S.Params).@"struct".field_names) |f| named = named ++ values(f, @field(params, f));
    return .{ .kind = @tagName(kind), .layers = args, .slots = S.slots, .params = named };
}

/// One parameter row per scalar, per list element, none for `null`.
fn values(comptime name: []const u8, comptime v: anytype) []const NamedSource {
    const T = @TypeOf(v);
    return switch (@typeInfo(T)) {
        .optional => if (v) |x| values(name, x) else &.{},
        .pointer => |p| if (p.child == u8) one(name, .{ .layer = v }) else blk: {
            var out: []const NamedSource = &.{};
            for (v) |x| out = out ++ element(name, x);
            break :blk out;
        },
        .@"enum" => one(name, .{ .value = .{ .count = @backingInt(v) } }),
        else => one(name, .{ .value = scalar(v) }),
    };
}

/// A list element: a name is a model, `null` the flag `false`.
fn element(comptime name: []const u8, comptime v: anytype) []const NamedSource {
    const T = @TypeOf(v);
    if (T == []const u8) return one(name, .{ .model = v });
    if (T == ?Dbu) return one(name, .{ .value = if (v) |x| .{ .length = x } else .{ .flag = false } });
    return one(name, .{ .value = scalar(v) });
}

fn scalar(comptime v: anytype) ParamValue {
    return switch (@TypeOf(v)) {
        Dbu => .{ .length = v },
        DbuArea => .{ .area = v },
        f64 => .{ .ratio = v },
        u32 => .{ .count = v },
        bool => .{ .flag = v },
        else => @compileError("no parameter value of " ++ @typeName(@TypeOf(v))),
    };
}

fn one(comptime name: []const u8, comptime value: ParamSource) []const NamedSource {
    return &.{.{ .name = name, .value = value }};
}

test "the kinds are Rust's DRC_KINDS then ERC_KINDS" {
    // Oracle: crates/check/src/deck/rules.rs `DRC_KINDS` and `ERC_KINDS`,
    // which drc/kinds.zig and erc/kinds.zig hold in the same order.
    const drc = @import("../drc/kinds.zig");
    const erc = @import("../erc/kinds.zig");
    const names = @typeInfo(Kind).@"enum".field_names;
    try std.testing.expectEqual(drc.count + erc.count, names.len);
    for (names, 0..) |n, i| {
        const want = if (i < drc.count) drc.Kind.name(@fromBackingInt(@intCast(i))) else erc.names[i - drc.count];
        try std.testing.expectEqualStrings(want, n);
    }
}

test "a row states its kind, its layers in deck order and its parameters" {
    // Oracle: crates/check/src/deck/rules.rs `min_enclosure`: deck order
    // (inner, outer), engine slots [1, 0], the limit and an optional band.
    const r = row(.min_enclosure, .{ .inner = expr.layer("via1"), .outer = expr.layer("met1") }, .{ .limit = 55, .wire_below = 1000 });
    try std.testing.expectEqualStrings("min_enclosure", r.kind);
    try std.testing.expectEqualStrings("via1", r.layers[0].node.layer);
    try std.testing.expectEqualSlices(u8, &.{ 1, 0 }, r.slots);
    try std.testing.expectEqual(@as(usize, 2), r.params.len);
    try std.testing.expectEqualStrings("wire_below", r.params[1].name);
    try std.testing.expect(!r.warning and r.warned().warning);
}
