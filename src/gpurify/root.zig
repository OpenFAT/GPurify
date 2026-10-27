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
//! - `calibrate`: `--backend auto`'s per-class thresholds, `measure`, `minWork`, `crossover` (calibrate.zig)
//! - `pdks`: the four shipped decks, `pdks.decks` by name (pdks.zig)
//! - `integration`: the DEF integration checks (integration.zig)
//! - `triage`: `Clusters`, `clusterInto` (triage.zig); `p2p`: `resistanceInto`, `coupling` (p2p.zig);
//!   `xor`: `Xor`, `run` (xor.zig)
//! - `fill`: `fillInto`, `fillGds` (fill.zig); `enhance`: `enhanceGds` (enhance.zig);
//!   `incremental`: `DrcState`, `check`, `recheck`, `reach` (incremental.zig)
//! - `system`: `SystemRun`, `run`, `checkSystem`, `allModels` (system.zig); `system_checks`: bumps,
//!   bonds, alignment, `assemble`, pins, ESD rails (system_checks.zig)
//! - `subckt_build`: `buildInto`, the netlist in the reference's terms (subckt_build.zig)
//! - `Die`, `loadDie`, `readDie` (load.zig)
//! - `export`: the report writers (export/*.zig)
//!   - `header`: `Header`, `Error`, `Diagnostic`
//!   - `json`: `writeReport`, `writeString`
//!   - `text`: `writeRuns`, `writeViolations`, `writeMerges`, `writeVerdict`, `writeSummary`, `Summary`, `StageStatus`
//!   - `spef`: `writeSpef`, `writeSpefCorners`; `envelope`: `envelopeInto`
//!   - `dspf`: `writeDspf`, `writeDspfSubckt`
//!   - `netlist`: `writeSpice`; `subckt`: `Subckt`, `Value`, `writeCard`
//!   - `network`: the checks and node naming the three share
//! - `liberty`: Liberty generation (liberty/*.zig): `generate`, `Request`, `Generated`, `spec`
//!   (also `numbers`, `write`, `circuit`, `spice`, `session`, `measure`, `measure_static`, `measure_constraint`,
//!   `assemble`, `field`, `prepare`, `static_caps`, `corner`, `generate_`, `File`, `Accuracy`)
//! - `Device`, `float` (geom); `foreign`: `Read`, `Error`, `Diagnostic`, `readSpefInto`, `readDspfInto`,
//!   `ParasiticNetwork`, `Comparison`, `Errors`, `compareInto`, `errors` (extract), for `gpurify compare`

const geom_ = @import("geom");
const extract_ = @import("extract");
const load_ = @import("load.zig");
const extracted = @import("extracted.zig");
pub const reference = @import("reference.zig");
pub const pdks = @import("pdks.zig");
pub const calibrate = @import("calibrate.zig");
pub const integration = @import("integration.zig");
pub const triage = @import("triage.zig");
pub const p2p = @import("p2p.zig");
pub const xor = @import("xor.zig");
pub const fill = @import("fill.zig");
pub const enhance = @import("enhance.zig");
pub const incremental = @import("incremental.zig");
pub const system = @import("system.zig");
pub const system_checks = @import("system_checks.zig");
pub const subckt_build = @import("subckt_build.zig");
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
pub const Die = load_.Die;
pub const loadDie = load_.loadDie;
pub const readDie = load_.readDie;
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
    pub const subckt = @import("export/subckt.zig");
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

/// The backend a run's kernels go to (geom's).
pub const Device = geom_.Device;
/// Rust-exact float text (geom's), for report lines the CLI prints.
pub const float = geom_.float;

/// Another tool's parasitic netlists, read and compared net by net
/// (extract's), as `gpurify compare` does.
pub const foreign = struct {
    pub const Read = extract_.foreign.Read;
    pub const Error = extract_.foreign.Error;
    pub const Diagnostic = extract_.foreign.Diagnostic;
    pub const readSpefInto = extract_.spef.readInto;
    pub const readDspfInto = extract_.dspf.readInto;
    pub const ParasiticNetwork = extract_.network.ParasiticNetwork;
    pub const Comparison = extract_.compare.Comparison;
    pub const Errors = extract_.compare.Errors;
    pub const compareInto = extract_.compare.compareInto;
    pub const errors = extract_.compare.errors;
};

// ---- private ----

/// `std.testing.refAllDecls`, recursing into the namespaces this module
/// declares, so a pub function no test calls yet is still compiled.
fn refAll(comptime T: type) void {
    const std = @import("std");
    inline for (comptime std.meta.declarations(T)) |name| {
        const decl = @field(T, name);
        if (@TypeOf(decl) == type) switch (@typeInfo(decl)) {
            .@"struct", .@"union", .@"enum" => refAll(decl),
            else => {},
        } else _ = &@field(T, name);
    }
}

test {
    refAll(@This());
    inline for (.{ @import("checks_drc.zig"), @import("checks_erc.zig"), @import("checks_lvs.zig"), @import("checks_pex.zig"), @import("checks_after.zig"), @import("currents.zig") }) |file| refAll(file);
}
