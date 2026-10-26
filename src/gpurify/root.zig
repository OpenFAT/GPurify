//! gpurify: the spines, the report writers, Liberty and the shipped decks
//! (ARCHITECTURE.md). Only re-exports.
//!
//! Contents:
//! - `Inputs`, `Loaded`, `DeckFn`, `NamedDeck`, `LoadError`, `LoadDiagnostic`, `load`, `loadBytes`,
//!   `isDef`, `internReportIds` (load.zig)
//! - `reference`: `readReferences`, `readReferenceText` (reference.zig)
//! - `Extracted`, `ExtractError`, `ExtractDiagnostic`, `extract`, `extractLayout` (extracted.zig)
//! - `Checks`, `RunOptions`, `Outputs`, `Corner`, `Summary`, `StageStatus`, `CheckError`, `RunError`,
//!   `RunDiagnostic`, `Run`, `run`, `runChecks`, `summarize`, `appendStage` (run.zig);
//!   `designExtent` (checks_erc.zig), `paramNames` (checks_lvs.zig)
//! - `pdks`: the four shipped decks, `pdks.decks` by name (pdks.zig)
//! - `integration`: the DEF integration checks (integration.zig)
//! - `triage`: `Clusters`, `clusterInto` (triage.zig); `p2p`: `resistanceInto`, `coupling` (p2p.zig);
//!   `xor`: `Xor`, `run` (xor.zig)
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
pub const triage = @import("triage.zig");
pub const p2p = @import("p2p.zig");
pub const xor = @import("xor.zig");
const run_ = @import("run.zig");
pub const designExtent = @import("checks_erc.zig").designExtent;
pub const paramNames = @import("checks_lvs.zig").paramNames;

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

pub const Checks = run_.Checks;
pub const RunOptions = run_.RunOptions;
pub const Outputs = run_.Outputs;
pub const Corner = run_.Corner;
pub const Summary = run_.Summary;
pub const StageStatus = run_.StageStatus;
pub const CheckError = run_.Error;
pub const RunError = run_.RunError;
pub const RunDiagnostic = run_.Diagnostic;
pub const Run = run_.Run;
pub const run = run_.run;
pub const runChecks = run_.runChecks;
pub const summarize = run_.summarize;
pub const appendStage = run_.appendStage;

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
    _ = run_;
    _ = integration;
    _ = triage;
    _ = p2p;
    _ = xor;
    _ = @import("checks_drc.zig");
    _ = @import("checks_erc.zig");
    _ = @import("checks_lvs.zig");
    _ = @import("checks_pex.zig");
    _ = @import("checks_after.zig");
}
