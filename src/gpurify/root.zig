//! gpurify: the spines, the report writers, Liberty and the shipped decks
//! (ARCHITECTURE.md). Only re-exports. The spines are wave 5; the writers
//! are here.
//!
//! Contents:
//! - `export`: the report writers (export/*.zig)
//!   - `float`: Rust's `{}`, `{:?}` and `{:.6}` of an `f64` (`display`, `debug`, `fixed6`)
//!   - `header`: `Header`, `Error`, `Diagnostic`
//!   - `json`: `writeReport`, `writeString`
//!   - `text`: `writeRuns`, `writeViolations`, `writeMerges`, `writeVerdict`, `writeSummary`, `Summary`, `StageStatus`
//!   - `spef`: `writeSpef`, `writeSpefCorners`; `envelope`: `envelopeInto`
//!   - `dspf`: `writeDspf`
//!   - `netlist`: `writeSpice`
//!   - `network`: the checks and node naming the three share

/// The report writers: text, JSON, SPEF, DSPF, SPICE.
pub const @"export" = struct {
    pub const float = @import("export/float.zig");
    pub const header = @import("export/header.zig");
    pub const json = @import("export/json.zig");
    pub const text = @import("export/text.zig");
    pub const network = @import("export/network.zig");
    pub const envelope = @import("export/envelope.zig");
    pub const spef = @import("export/spef.zig");
    pub const dspf = @import("export/dspf.zig");
    pub const netlist = @import("export/netlist.zig");
    pub const Header = header.Header;
    pub const Error = header.Error;
    pub const Diagnostic = header.Diagnostic;
};

test {
    @import("std").testing.refAllDecls(@"export");
    inline for (.{ "float", "header", "json", "text", "network", "envelope", "spef", "dspf", "netlist" }) |name| {
        @import("std").testing.refAllDecls(@field(@"export", name));
    }
}
