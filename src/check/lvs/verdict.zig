//! What a comparison concluded, and why. Every row index a `Discrepancy`
//! carries is a row of that side's graph after reduction. Ported from
//! crates/check/src/lvs/verdict.rs.
//!
//! Contents:
//! - `pub const Verdict = union(enum) { match, mismatch, inconclusive: Inconclusive }`
//! - `pub const Inconclusive = enum { round_limit, ambiguous_top }`
//! - `pub const Side = enum { layout, reference }`
//! - `pub const Discrepancy = union(enum)`

const geom = @import("geom");
const StrId = geom.StrId;
const TerminalRole = @import("../topology/device.zig").TerminalRole;

/// The result of comparing one cell (catalog LVS-019). Only `match` passes.
/// A `mismatch`'s findings are the caller's `Discrepancy` list, never empty:
/// every `class_imbalance`; then for each paired device in ascending layout
/// row its identity, terminal and parameter rows; then unpaired layout
/// devices and nets; then unpaired reference devices and nets. There is no
/// path from "gave up" (`inconclusive`) to "matched".
pub const Verdict = union(enum) {
    /// After reduction every device, and every net carrying a terminal or a
    /// name, paired one to one, and each device pair agrees on kind, model,
    /// terminals and parameters.
    match,
    mismatch,
    inconclusive: Inconclusive,
};

/// Why a comparison could not conclude.
pub const Inconclusive = enum {
    /// More than `max_rounds` refinement passes in a row split a class
    /// without settling. Says nothing about whether the netlists match.
    round_limit,
    /// The reference has no unique top subcircuit; the caller that picks one
    /// returns it, `compare` never does.
    ambiguous_top,
};

/// Which netlist a discrepancy is about.
pub const Side = enum { layout, reference };

/// One concrete difference. Each reports under one id of `RULE_IDS`.
pub const Discrepancy = union(enum) {
    /// `lvs.unpaired_device`: a device whose class does not hold exactly one
    /// device per side, or one of a pair whose kinds differ (catalog LVS-012,
    /// LVS-013, LVS-049).
    unpaired_device: struct { side: Side, device: u32, model: StrId },
    /// `lvs.unpaired_net`: a net carrying a terminal or a name that no
    /// other-side net paired with (catalog LVS-001, LVS-015, LVS-016).
    unpaired_net: struct { side: Side, net: u32, name: ?StrId },
    /// `lvs.terminal_mismatch`: a paired device's terminal not on the
    /// counterpart of its partner's same-role net; `role` as written on the
    /// side it came from (catalog LVS-015).
    terminal_mismatch: struct { layout_device: u32, ref_device: u32, role: TerminalRole },
    /// `lvs.parameter_mismatch`: a parameter both state, apart by more than
    /// its bound; `NaN` always differs (catalog LVS-014).
    parameter_mismatch: struct { layout_device: u32, ref_device: u32, param: StrId, layout_value: f64, ref_value: f64 },
    /// `lvs.undeclared_param`: a parameter the paired device's reference card
    /// states and the layout does not measure; `side` is always `reference`
    /// (catalog LVS-020).
    undeclared_param: struct { side: Side, layout_device: u32, ref_device: u32, param: StrId },
    /// `lvs.model_mismatch`: two devices of one kind refinement pairs once
    /// models are set aside, and whose models differ (catalog LVS-013).
    model_mismatch: struct { layout_device: u32, ref_device: u32, layout_model: StrId, ref_model: StrId },
    /// `lvs.class_imbalance`: a class of at least two nodes on each side,
    /// a different number on each (catalog LVS-011, LVS-049).
    class_imbalance: struct { layout_nodes: u32, ref_nodes: u32 },
};
