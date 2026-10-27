//! SPICE instance cards for recognised devices: where a terminal stands on
//! its family's card and what a card calls each measure. In: a device's
//! `TerminalRole`s, `DeviceKind` and `DeviceParam`s. Out: card positions and
//! parameter names, for the netlists `pex --format spice` and Liberty write.
//!
//! Contents:
//! - `pub fn cardRank(role: TerminalRole) u8`, `pub fn cardName(kind: DeviceKind, param: DeviceParam) ?[]const u8`

const DeviceKind = @import("ingest").deck.DeviceKind;
const device = @import("device.zig");
const TerminalRole = device.TerminalRole;
const DeviceParam = device.DeviceParam;

/// Where a terminal of `role` stands on its family's SPICE card: `d g s
/// b`, `c b e`, a pin at its position.
pub fn cardRank(role: TerminalRole) u8 {
    return switch (role) {
        .drain, .collector => 0,
        .gate, .base => 1,
        .source, .emitter => 2,
        .bulk => 3,
        .pin => |position| position,
    };
}

/// The name a simulator's instance card gives a measure of a device of
/// `kind`, as the SPICE primitives and PDK models take them: a diode's
/// perimeter `pj`; null for one no card takes (a MOS's `area` and `perim`,
/// which its diffusions say, and a bipolar's emitter measures).
pub fn cardName(kind: DeviceKind, param: DeviceParam) ?[]const u8 {
    return switch (param) {
        .width => "w",
        .length => "l",
        .fins => "nfin",
        .fingers => "nf",
        .source_area => "as",
        .drain_area => "ad",
        .source_perimeter => "ps",
        .drain_perimeter => "pd",
        .area => if (kind == .mos) null else "area",
        .perimeter => if (kind == .mos) null else if (kind == .diode) "pj" else "perim",
        .emitter_area, .emitter_perimeter => null,
    };
}
