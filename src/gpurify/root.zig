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
//! - `liberty`: Liberty generation (liberty/*.zig): `generate`, `Request`, `Generated`, `spec`

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

/// Liberty generation: a `.lib` per corner and a Verilog blackbox.
pub const liberty = struct {
    pub const spec = @import("liberty/spec.zig");
    pub const numbers = @import("liberty/numbers.zig");
    pub const write = @import("liberty/write.zig");
    pub const circuit = @import("liberty/circuit.zig");
    pub const spice = @import("liberty/spice.zig");
    pub const session = @import("liberty/session.zig");
    pub const measure = @import("liberty/measure.zig");
    pub const measure_static = @import("liberty/measure_static.zig");
    pub const measure_constraint = @import("liberty/measure_constraint.zig");
    pub const assemble = @import("liberty/assemble.zig");
    pub const field = @import("liberty/field.zig");
    pub const prepare = @import("liberty/prepare.zig");
    pub const static_caps = @import("liberty/static_caps.zig");
    pub const corner = @import("liberty/corner.zig");
    pub const generate_ = @import("liberty/generate.zig");
    pub const generate = generate_.generate;
    pub const Request = generate_.Request;
    pub const Generated = generate_.Generated;
    pub const File = generate_.File;
    pub const Error = generate_.Error;
    pub const Accuracy = spec.Accuracy;
    pub const Diagnostic = spec.Diagnostic;
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
    std.testing.refAllDecls(liberty);
    inline for (comptime std.meta.declarations(liberty)) |name| if (@TypeOf(@field(liberty, name)) == type and @typeInfo(@field(liberty, name)) == .@"struct") std.testing.refAllDecls(@field(liberty, name));
}
