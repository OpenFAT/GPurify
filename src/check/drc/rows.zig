//! One row type per DRC kind, and `Rule`, the tagged union that carries one
//! row in or out of a `RuleSet`. In: nothing (types). Out: the fields every
//! kind table stores, lengths in grid units, areas in square grid units.
//! Ported from crates/check/src/drc/ruleset.rs (the `Rule` variants and the
//! small types they hold); a variant's doc comment there is the kind's
//! definition (what it flags, where it reports, what it examines).
//!
//! `Rule` is the boundary value, not the storage: a `RuleSet` keeps one SoA
//! table per kind (`rule_set.zig`), and `Rule` is what a builder pushes and
//! what `RuleSet.get` gathers back. A table index (`table`, `classes`,
//! `stack`...) names a row of one of the set's CSR side tables.
//!
//! Contents:
//! - `pub const Rule = union(Kind)`, `pub fn Row(comptime k: Kind) type`
//! - one row type per kind (or shared by kinds with the same fields):
//!   `LayerLimit`, `LayerArea`, `LayerOnly`, `AnyLayer`, `TwoLayers`, `Enclosure`,
//!   `PlainEnclosure`, `FullWidth`, `CutSize`, `EolSpacing`, `PrlSpacing`, `WideSpacing`,
//!   `AttachedWideSpacing`, `Cheesing`, `Density`, `GlobalDensity`, `CriticalArea`,
//!   `DensityBalance`, `MinExtension`, `GateCorner`, `MaxDistanceToTap`, `OffGrid`, `Angle`,
//!   `RedundantVia`, `MinimumCut`, `ViaStack`, `MetalWidthVia`, `StackSpacing`, `MaxCutSpacing`,
//!   `ViaArraySpacing`, `CutSpacing`, `LayerTable`, `MultiPatterning`, `AnchoredPatterning`,
//!   `Sadp`, `SadpLineEnd`, `MustContain`, `MustBeInside`, `NetSpacing`, `EdgeSpacing`,
//!   `EdgeEnclosure`, `Count`, `AspectRatio`, `EdgeFacingSpace`, `RegionDensity`, `AllowedWidth`,
//!   `ViaRedundancy`, `DfmScore`, `CutAreaChange`, `MeanCriticalArea`, `CoverDensity`,
//!   `ProtrusionWidth`, `MinInteriorAngle`, `MinStep`, `MinStepAdjacent`, `ForbiddenSpacing`,
//!   `EolWithinSpacing`, `EolKeepOut`, `EolExtensionSpacing`, `SideLengthTwo`, `KeepOutZone`,
//!   `ConvexCornerSpacing`, `ExactPitch`, `CutClass`, `PatternMatch`
//! - `pub const DfmCheck`, `StepKind`, `StepNeighbour`, `WireBand`, `WireBand.any`,
//!   `WireBand.widthsOnly(b: WireBand) bool`, `ExtraCut`, `EolParallel`, `SideLength`,
//!   `EncloseCut`, `Eol58`, `Eol58.none`, `EolExtension`, `LineEnds`, `Pair`

const std = @import("std");
const geom = @import("geom");
const Dbu = geom.Dbu;
const DbuArea = geom.DbuArea;
const LayerId = geom.LayerId;
const LimitSense = @import("../report.zig").LimitSense;
const Kind = @import("kinds.zig").Kind;

/// Two lengths, `(a, b)`: a class's sides, a range, a keep-out's extents.
pub const Pair = [2]Dbu;

/// One layer and one length: width, spacing, edge and pitch kinds.
pub const LayerLimit = struct { layer: LayerId, limit: Dbu };
/// One layer and one area.
pub const LayerArea = struct { layer: LayerId, limit: DbuArea };
/// One layer alone.
pub const LayerOnly = struct { layer: LayerId };
/// An optional layer (`none`: every drawn layer).
pub const AnyLayer = struct { layer: ?LayerId };
/// Two layers and a length, in the engine's order.
pub const TwoLayers = struct { a: LayerId, b: LayerId, limit: Dbu };
/// An enclosure: `outer` around `inner` by `limit`, on wires of `wire`.
pub const Enclosure = struct { outer: LayerId, inner: LayerId, limit: Dbu, wire: WireBand = .any };
/// An enclosure with no band.
pub const PlainEnclosure = struct { outer: LayerId, inner: LayerId, limit: Dbu };
pub const FullWidth = struct { outer: LayerId, inner: LayerId };
pub const CutSize = struct { layer: LayerId, width: Dbu, height: Dbu };
pub const EolSpacing = struct { layer: LayerId, eol_width: Dbu, limit: Dbu };
pub const PrlSpacing = struct { layer: LayerId, prl_threshold: Dbu, limit: Dbu };
pub const WideSpacing = struct { layer: LayerId, width_threshold: Dbu, limit: Dbu };
pub const AttachedWideSpacing = struct { layer: LayerId, width_threshold: Dbu, attached: Dbu, limit: Dbu };
pub const Cheesing = struct { layer: LayerId, max_unslotted: DbuArea };
pub const Density = struct { layer: LayerId, boundary: ?LayerId, window: Dbu, step: Dbu, limit: f64, sense: LimitSense };
pub const GlobalDensity = struct { layer: LayerId, boundary: ?LayerId, limit: f64, sense: LimitSense };
pub const CriticalArea = struct { layer: LayerId, radius: Dbu, limit: DbuArea };
pub const DensityBalance = struct { a: LayerId, b: LayerId, boundary: ?LayerId, window: Dbu, step: Dbu, limit: f64 };
pub const MinExtension = struct { layer: LayerId, reference: LayerId, limit: Dbu };
pub const GateCorner = struct { layer: LayerId, reference: LayerId, of_reference: bool };
pub const MaxDistanceToTap = struct { well: LayerId, tap: LayerId, limit: Dbu };
pub const OffGrid = struct { pitch: Dbu };
/// `allowed`: bit `k` set when an edge at `45·k` degrees (mod 180) is legal.
pub const Angle = struct { layer: ?LayerId, allowed: u8 };
pub const RedundantVia = struct { layer: LayerId, min_count: u16, within: Dbu };
pub const MinimumCut = struct { cut: LayerId, wide: LayerId, other: LayerId, width: Dbu, thin: ?Pair, within: ?Dbu, min_count: u16 };
/// `stack` names a row of `RuleSet.stacks`.
pub const ViaStack = struct { stack: u32, single: bool, max_height: u16 };
pub const MetalWidthVia = struct { cut: LayerId, below: LayerId, above: LayerId, below_band: WireBand, above_band: WireBand, width: Dbu, height: Dbu };
pub const StackSpacing = struct { a: LayerId, b: LayerId, metal: LayerId, same_only: bool, limit: Dbu };
pub const MaxCutSpacing = struct { cut: LayerId, others: ?LayerId, limit: Dbu };
pub const ViaArraySpacing = struct { layer: LayerId, array_threshold: u16, limit: Dbu };
pub const CutSpacing = struct { layer: LayerId, center: bool, adjacent: u16, within: Dbu, limit: Dbu };
/// A row naming one of the set's side tables by index.
pub const LayerTable = struct { layer: LayerId, table: u32 };
pub const MultiPatterning = struct { layer: LayerId, colors: u8, color_spacing: Dbu };
pub const AnchoredPatterning = struct { layer: LayerId, anchors: [4]?LayerId, colors: u8, color_spacing: Dbu };
pub const Sadp = struct { layer: LayerId, different: Dbu, same: Dbu, track: ?Pair };
pub const SadpLineEnd = struct { layer: LayerId, ends: LineEnds };
pub const MustContain = struct { outer: LayerId, inner: LayerId, min_count: u32, max_count: u32 };
pub const MustBeInside = struct { inner: LayerId, outer: LayerId };
pub const NetSpacing = struct { layer: LayerId, other: ?LayerId, same_net: bool, limit: Dbu };
pub const EdgeSpacing = struct { a: LayerId, b: ?LayerId, limit: Dbu };
pub const EdgeEnclosure = struct { edges: LayerId, outer: LayerId, limit: Dbu };
pub const Count = struct { layer: LayerId, limit: u32, sense: LimitSense };
pub const AspectRatio = struct { layer: LayerId, limit: f64 };
pub const EdgeFacingSpace = struct { layer: LayerId, limit: Dbu, prl: Dbu };
pub const RegionDensity = struct { layer: LayerId, region: LayerId, limit: f64, sense: LimitSense };
pub const AllowedWidth = struct { layer: LayerId, widths: u32, open_last: bool };
pub const ViaRedundancy = struct { cut: LayerId, lower: LayerId, upper: LayerId, pitch: Dbu, space: Dbu, limit: f64 };
pub const DfmScore = struct { check: DfmCheck, layer: LayerId, outer: ?LayerId, required: Dbu, recommended: Dbu, rate: f64, limit: f64 };
pub const CutAreaChange = struct { pre: LayerId, post: LayerId, lower: LayerId, upper: LayerId, bands: u32 };
pub const MeanCriticalArea = struct { layer: LayerId, sizes: u32, limit: DbuArea };
pub const CoverDensity = struct { layer: LayerId, cover: LayerId, boundary: ?LayerId, window: Dbu, step: Dbu, bands: u32 };
pub const ProtrusionWidth = struct { layer: LayerId, wide: Dbu, limit: Dbu };
pub const MinInteriorAngle = struct { layer: ?LayerId, limit: f64 };
pub const MinStep = struct { layer: LayerId, limit: Dbu, kind: StepKind, length_sum: ?Dbu };
pub const MinStepAdjacent = struct { layer: LayerId, limit: Dbu, neighbour: StepNeighbour };
pub const ForbiddenSpacing = struct { layer: LayerId, min: Dbu, max: Dbu, prl: Dbu };
pub const EolWithinSpacing = struct { layer: LayerId, eol_width: Dbu, within: Dbu, parallel: ?EolParallel, end_to_end: ?Dbu, limit: Dbu, lef58: Eol58 = .none };
pub const EolKeepOut = struct { layer: LayerId, eol_width: Dbu, backward: Dbu, side: Dbu, forward: Dbu, except_within: ?Pair, corner_only: bool };
pub const EolExtensionSpacing = struct { layer: LayerId, rows: [3]?EolExtension, side_length: ?SideLengthTwo, limit: Dbu };
/// `MINLENGTH minLength [TWOSIDES]` of an extension spacing.
pub const SideLengthTwo = struct { length: Dbu, two_sides: bool };
pub const KeepOutZone = struct { layer: LayerId, class: Pair, to: ?Pair, end: Pair, side: Pair };
pub const ConvexCornerSpacing = struct { layer: LayerId, corner_to_corner: bool, except_eol: ?Dbu, limit: Dbu };
pub const ExactPitch = struct { layer: LayerId, vertical: bool, pitch: Dbu };
pub const CutClass = struct { layer: LayerId, classes: u32 };
pub const PatternMatch = struct { layer: LayerId, pattern: u32 };

/// Which check a DFM score reads.
pub const DfmCheck = enum(u8) { space, width, enclosure };

/// Which runs of short edges a `min_step` rejects (LEF `MINSTEP`).
pub const StepKind = union(enum) {
    /// `MAXEDGES n`: more than `n` short edges in a row.
    max_edges: u16,
    /// `OUTSIDECORNER`: two or more at a convex corner.
    outside_corner,
    /// `INSIDECORNER`: two or more at a concave corner.
    inside_corner,
    /// `STEP`: one or more between two long edges running the same way.
    step,
};

/// What a short edge may not have beside it (`LEF58_MINSTEP`).
pub const StepNeighbour = union(enum) {
    adjacent: struct { length: Dbu, eol: ?Dbu, except_rectangle: bool },
    between_eol: Dbu,
};

/// The wire widths (and LEF selections) at which an enclosure holds an inner
/// polygon: from `from` up to but not at `below`.
pub const WireBand = struct {
    from: Dbu = 0,
    below: ?Dbu = null,
    extra_cut: ?ExtraCut = null,
    /// Overhang length held, from `[0]` up to but not at `[1]`.
    length: [2]?Dbu = .{ null, null },

    pub const any: WireBand = .{};

    /// Whether only wire widths are stated, as a `metal_width_via` band must.
    pub fn widthsOnly(b: WireBand) bool {
        return b.extra_cut == null and b.length[0] == null and b.length[1] == null;
    }
};

/// LEF `EXCEPTEXTRACUT cutWithin`.
pub const ExtraCut = struct { within: Dbu, other: LayerId, only: bool };

/// LEF `PARALLELEDGE parSpace WITHIN parWithin [TWOEDGES]`.
pub const EolParallel = struct { space: Dbu, within: Dbu, two_edges: bool };

/// `MINLENGTH`/`MAXLENGTH` of an end of line's sides.
pub const SideLength = struct { length: Dbu, maximum: bool, two_sides: bool };

/// `ENCLOSECUT [BELOW|ABOVE] encloseDist CUTSPACING cutToMetalSpace [ALLCUTS]`.
pub const EncloseCut = struct { cut: LayerId, within: Dbu, space: Dbu, all: bool };

/// The `LEF58_SPACING ENDOFLINE` qualifiers.
pub const Eol58 = struct {
    side_length: ?SideLength = null,
    opposite_width: ?Dbu = null,
    subtract_eol_width: bool = false,
    parallel_min_length: ?Dbu = null,
    end_prl: ?Pair = null,
    /// `(space, horizontal)`.
    wrong_dir: ?struct { space: Dbu, horizontal: bool } = null,
    extension: ?Dbu = null,
    enclose_cut: ?EncloseCut = null,

    pub const none: Eol58 = .{};
};

/// One `ENDOFLINE eolWidth EXTENSION ext [ENDTOEND e2e]` row.
pub const EolExtension = struct { eol_width: Dbu, extension: Dbu, end_to_end: ?Dbu };

/// An SADP line-end rule's five lengths.
pub const LineEnds = struct { adjacent: Dbu, tip: Dbu, overlap: Dbu, corner: Dbu, offset: Dbu };

/// One rule row of any kind; the tag is its kind.
pub const Rule = union(Kind) {
    min_width: LayerLimit,
    max_width: LayerLimit,
    cut_size: CutSize,
    min_edge_length: LayerLimit,
    notch: LayerLimit,
    min_spacing: LayerLimit,
    min_spacing_diff: TwoLayers,
    projection_spacing: TwoLayers,
    eol_spacing: EolSpacing,
    prl_spacing: PrlSpacing,
    corner_to_corner: LayerLimit,
    wide_dependent_spacing: WideSpacing,
    min_area: LayerArea,
    min_enclosed_area: LayerArea,
    cheesing: Cheesing,
    density: Density,
    global_density: GlobalDensity,
    critical_area: CriticalArea,
    mean_critical_area: MeanCriticalArea,
    density_balance: DensityBalance,
    via_redundancy: ViaRedundancy,
    dfm_score: DfmScore,
    pattern_match: PatternMatch,
    cut_area_change: CutAreaChange,
    cover_density: CoverDensity,
    min_enclosure: Enclosure,
    noncoincident_enclosure: PlainEnclosure,
    full_width: FullWidth,
    asymmetric_enclosure: Enclosure,
    max_enclosure: PlainEnclosure,
    adjacent_enclosure: PlainEnclosure,
    min_extension: MinExtension,
    gate_corner: GateCorner,
    overlap: TwoLayers,
    max_distance_to_tap: MaxDistanceToTap,
    off_grid: OffGrid,
    angle: Angle,
    redundant_via: RedundantVia,
    minimum_cut: MinimumCut,
    via_stack: ViaStack,
    metal_width_via: MetalWidthVia,
    stack_spacing: StackSpacing,
    max_cut_spacing: MaxCutSpacing,
    via_array_spacing: ViaArraySpacing,
    cut_spacing: CutSpacing,
    cut_class_spacing: LayerTable,
    multi_patterning: MultiPatterning,
    anchored_patterning: AnchoredPatterning,
    sadp: Sadp,
    sadp_line_end: SadpLineEnd,
    forbidden: LayerOnly,
    must_contain: MustContain,
    must_be_inside: MustBeInside,
    net_spacing: NetSpacing,
    spacing_table: LayerTable,
    attached_wide_spacing: AttachedWideSpacing,
    edge_min_length: LayerLimit,
    edge_spacing: EdgeSpacing,
    edge_enclosure: EdgeEnclosure,
    count: Count,
    aspect_ratio: AspectRatio,
    total_area: LayerArea,
    cut_class: CutClass,
    edge_width: LayerLimit,
    edge_facing_space: EdgeFacingSpace,
    region_density: RegionDensity,
    allowed_width: AllowedWidth,
    min_interior_angle: MinInteriorAngle,
    polygon_validity: AnyLayer,
    min_step: MinStep,
    min_step_adjacent: MinStepAdjacent,
    tip_spacing_table: LayerTable,
    forbidden_spacing: ForbiddenSpacing,
    eol_within_spacing: EolWithinSpacing,
    eol_keep_out: EolKeepOut,
    eol_extension_spacing: EolExtensionSpacing,
    origin: LayerOnly,
    protrusion_width: ProtrusionWidth,
    keep_out_zone: KeepOutZone,
    two_width_spacing_table: LayerTable,
    span_length: LayerTable,
    convex_corner_spacing: ConvexCornerSpacing,
    exact_pitch: ExactPitch,
};

/// The row type of kind `k`.
pub fn Row(comptime k: Kind) type {
    return @FieldType(Rule, @tagName(k));
}

test "every kind has a row" {
    // Oracle: law. `Rule` is tagged by `Kind`, so each kind names one field.
    try std.testing.expectEqual(LayerLimit, Row(.min_width));
    try std.testing.expectEqual(ExactPitch, Row(.exact_pitch));
}
