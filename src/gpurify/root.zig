//! gpurify: the spines, the report writers, Liberty and the shipped decks
//! (ARCHITECTURE.md). Only re-exports.
//!
//! Contents:
//! - `Inputs`, `Loaded`, `DeckFn`, `NamedDeck`, `LoadError`, `LoadDiagnostic`, `load`, `loadBytes`,
//!   `isDef`, `internReportIds` (load.zig)
//! - `reference`: `readReferences`, `readReferenceText` (reference.zig)
//! - `Extracted`, `ExtractError`, `ExtractDiagnostic`, `extract`, `extractLayout` (extracted.zig)
//! - `pdks`: the four shipped decks, `pdks.decks` by name (pdks.zig)
//! - `integration`: the DEF integration checks (integration.zig)
//! - `export`: the report writers (export/*.zig)
//!   - `header`: `Header`, `Error`, `Diagnostic`
//!   - `json`: `writeReport`, `writeString`
//!   - `text`: `writeRuns`, `writeViolations`, `writeMerges`, `writeVerdict`, `writeSummary`, `Summary`, `StageStatus`
//!   - `spef`: `writeSpef`, `writeSpefCorners`; `envelope`: `envelopeInto`
//!   - `dspf`: `writeDspf`
//!   - `netlist`: `writeSpice`
//!   - `network`: the checks and node naming the three share

const load_ = @import("load.zig");
const extracted = @import("extracted.zig");
pub const reference = @import("reference.zig");
pub const pdks = @import("pdks.zig");
pub const integration = @import("integration.zig");

pub const Inputs = load_.Inputs;
pub const Loaded = load_.Loaded;
pub const DeckFn = load_.DeckFn;
pub const NamedDeck = load_.NamedDeck;
pub const LoadError = load_.Error;
pub const LoadDiagnostic = load_.Diagnostic;
pub const load = load_.load;
pub const loadBytes = load_.loadBytes;
pub const isDef = load_.isDef;
pub const internReportIds = load_.internReportIds;

pub const Extracted = extracted.Extracted;
pub const ExtractError = extracted.Error;
pub const ExtractDiagnostic = extracted.Diagnostic;
pub const extract = extracted.extract;
pub const extractLayout = extracted.extractLayout;

/// The report writers: text, JSON, SPEF, DSPF, SPICE.
pub const @"export" = struct {
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
    const std = @import("std");
    std.testing.refAllDecls(@This());
    std.testing.refAllDecls(@"export");
    inline for (.{ "header", "json", "text", "network", "envelope", "spef", "dspf", "netlist" }) |name| {
        std.testing.refAllDecls(@field(@"export", name));
    }
    _ = load_;
    _ = extracted;
    _ = reference;
    _ = pdks;
}
