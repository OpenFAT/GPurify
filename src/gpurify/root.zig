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

/// The report writers: text, JSON, SPEF, DSPF, SPICE.
pub const @"export" = struct {
    pub const float = @import("export/float.zig");
    pub const header = @import("export/header.zig");
    pub const json = @import("export/json.zig");
    pub const text = @import("export/text.zig");
    pub const Header = header.Header;
    pub const Error = header.Error;
    pub const Diagnostic = header.Diagnostic;
};

test {
    _ = @"export".float;
    _ = @"export".header;
    _ = @"export".json;
    _ = @"export".text;
}
