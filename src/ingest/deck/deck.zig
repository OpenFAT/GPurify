//! The process deck's public surface; only re-exports. Deck text and the
//! layout's grid → a `Deck` (layers, rules, connectivity, devices, PEX
//! stack, lvs controls), every limit converted to grid units exactly or
//! refused. The language: docs/deck.md. Ported from crates/ingest/src/deck.
//!
//! Contents:
//! - `parseDeck`, `parseSource` (parse.zig); `lower` (lower.zig); `print`, `PrintError` (print.zig)
//! - `fromTables`, `fromControls` (decompile.zig)
//! - `Error`, `Diag`, `Diagnostic`, `render`, `locate` (diagnostic.zig)
//! - tables.zig: `Deck`, `Reports`, `Edits`, `FillSpec`, `WidenSpec`, `PexModels`, `FillTreatment`, `SubstrateModel`, `TsvModel`, `DeviceParasitics`, `TemperatureLaw`, `Stages`, `ProcessCorner`, `CornerValues`, `Extraction`, `ExtractionKind`, `RuleSpec`, `ParamValue`, `NamedValue`, `RuleTable`, `Connectivity`, `Waiver`, `DeviceRecognition`, `DeviceValue`, `DeviceKind`, `LvsControls`, `UnusedFilter`, `ModelParam`, `Permute`, `SameNets`, `LdeWell`, `LvsLde`, `LvsCount`, `LvsRange`, `LvsLimit`, `LvsTolerance`, `ProcessStack`, `absoluteUnit`, `pinNames`
//! - layers.zig: `LayerTable`, `DerivedOp`, `Range`, `max_cell_selections`
//! - source.zig: `DeckSource`, `DerivedSource`, `RuleSource`, `ParamSource`, `NamedSource`, `ConnectivitySource`, `DeviceSource`, `StackSource`, `CornerSource`, `LvsSrc`

const tables = @import("tables.zig");
const layers = @import("layers.zig");
const source = @import("source.zig");
const diagnostic = @import("diagnostic.zig");

pub const parseDeck = @import("parse.zig").parseDeck;
pub const parseSource = @import("parse.zig").parseSource;
pub const lower = @import("lower.zig").lower;
pub const print = @import("print.zig").print;
pub const PrintError = @import("print_layers.zig").PrintError;
pub const fromTables = @import("decompile.zig").fromTables;
pub const fromControls = @import("decompile.zig").fromControls;

pub const Error = diagnostic.Error;
pub const Diag = diagnostic.Diag;
pub const Diagnostic = diagnostic.Diagnostic;
pub const render = diagnostic.render;
pub const locate = diagnostic.locate;

pub const Deck = tables.Deck;
pub const Reports = tables.Reports;
pub const Edits = tables.Edits;
pub const FillSpec = tables.FillSpec;
pub const WidenSpec = tables.WidenSpec;
pub const PexModels = tables.PexModels;
pub const FillTreatment = tables.FillTreatment;
pub const SubstrateModel = tables.SubstrateModel;
pub const TsvModel = tables.TsvModel;
pub const DeviceParasitics = tables.DeviceParasitics;
pub const TemperatureLaw = tables.TemperatureLaw;
pub const Stages = tables.Stages;
pub const ProcessCorner = tables.ProcessCorner;
pub const CornerValues = tables.CornerValues;
pub const Extraction = tables.Extraction;
pub const ExtractionKind = tables.ExtractionKind;
pub const RuleSpec = tables.RuleSpec;
pub const ParamValue = tables.ParamValue;
pub const NamedValue = tables.NamedValue;
pub const RuleTable = tables.RuleTable;
pub const Connectivity = tables.Connectivity;
pub const Waiver = tables.Waiver;
pub const DeviceRecognition = tables.DeviceRecognition;
pub const DeviceValue = tables.DeviceValue;
pub const DeviceKind = tables.DeviceKind;
pub const LvsControls = tables.LvsControls;
pub const UnusedFilter = tables.UnusedFilter;
pub const ModelParam = tables.ModelParam;
pub const Permute = tables.Permute;
pub const SameNets = tables.SameNets;
pub const LdeWell = tables.LdeWell;
pub const LvsLde = tables.LvsLde;
pub const LvsCount = tables.LvsCount;
pub const LvsRange = tables.LvsRange;
pub const LvsLimit = tables.LvsLimit;
pub const LvsTolerance = tables.LvsTolerance;
pub const ProcessStack = tables.ProcessStack;
pub const absoluteUnit = tables.absoluteUnit;
pub const pinNames = tables.pinNames;

pub const LayerTable = layers.LayerTable;
pub const DerivedOp = layers.DerivedOp;
pub const Range = layers.Range;
pub const max_cell_selections = layers.max_cell_selections;

pub const DeckSource = source.DeckSource;
pub const DerivedSource = source.DerivedSource;
pub const RuleSource = source.RuleSource;
pub const ParamSource = source.ParamSource;
pub const NamedSource = source.NamedSource;
pub const ConnectivitySource = source.ConnectivitySource;
pub const DeviceSource = source.DeviceSource;
pub const StackSource = source.StackSource;
pub const CornerSource = source.CornerSource;
pub const LvsSrc = source.LvsSrc;

test {
    _ = @import("lex.zig");
    _ = @import("layers.zig");
    _ = @import("units.zig");
    _ = @import("print_layers.zig");
}
