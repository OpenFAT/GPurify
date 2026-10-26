//! What every writer shares: the run's metadata it prints, and the ways it
//! refuses. Ported from src/export/mod.rs (`Header`, `WriteError`).
//!
//! Every writer appends to a caller's `*std.Io.Writer`, iterates the
//! canonical order its table guarantees (never sorts), and formats floats
//! through geom.float, so the bytes are a function of the inputs and the
//! `Header` alone. A refusal of the input is found before the first byte
//! unless its writer says otherwise; a writer that fails may have written
//! part of its output, so the caller discards it.
//!
//! Contents:
//! - `pub const Header = struct`
//! - `pub const Error = error{ Unrepresentable, UnnamedNet, SplitLabel, ShortedLabels } || std.Io.Writer.Error || std.mem.Allocator.Error`
//! - `pub const Diagnostic = struct`

const std = @import("std");
const StrId = @import("geom").StrId;

/// Run metadata: everything that may differ between two otherwise identical
/// runs. Written as given, escaped only in JSON.
pub const Header = struct {
    /// The tool's version.
    tool_version: []const u8,
    /// The deck's path, as the caller spelled it.
    deck_path: []const u8,
    /// The layout's path, as the caller spelled it; SPEF's and DSPF's
    /// design name.
    layout_path: []const u8,
    /// Passed in, never read from the clock. Null writes SPEF's required
    /// `*DATE` as `""` and leaves DSPF's and SPICE's date line out.
    timestamp: ?[]const u8 = null,
};

/// Why a writer refused; the `Diagnostic` names what.
pub const Error = error{
    /// The input holds something the format cannot say truthfully: a
    /// non-finite value, a network out of canonical order, a resistance
    /// with no far node, an element on a node outside the network, a port
    /// on a net outside the extraction. `Diagnostic.what` says which.
    Unrepresentable,
    /// SPEF and DSPF name every node after its net, and net
    /// `Diagnostic.net` has no label.
    UnnamedNet,
    /// One label, `Diagnostic.labels[0]`, names several disconnected nets,
    /// and the file names nets by label, so the pieces would read as one.
    SplitLabel,
    /// One net carries every label in `Diagnostic.labels`, a short, and the
    /// format gives a net one name.
    ShortedLabels,
} || std.Io.Writer.Error || std.mem.Allocator.Error;

/// The values behind an `Error`; only the fields its error names are set.
pub const Diagnostic = struct {
    /// `Unrepresentable`: what it was, as Rust's message spells it.
    what: []const u8 = "",
    /// `UnnamedNet`: the net.
    net: u32 = 0,
    /// `SplitLabel` (one) or `ShortedLabels` (several, ascending): the
    /// labels, a slice of the port table's name column.
    labels: []const StrId = &.{},
};
