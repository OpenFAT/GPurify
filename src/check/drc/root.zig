//! drc: a deck's DRC rows typed and run (ARCHITECTURE.md, Spines: `drc`).
//! Only re-exports.
//!
//! Data decision. Rust's 83-variant `Rule` enum (one fat row per rule,
//! sized by its largest variant) becomes one SoA table per kind
//! (`std.MultiArrayList` of that kind's row, `rule_set.zig` `Tables`) plus
//! `order: []Slot` (`{ kind, row }`) in deck order, with the rule ids and
//! severities parallel to `order`. Side tables (spacing, cut-class, class
//! and span tables, cover and cut-area bands, defect sizes, cut classes,
//! allowed widths, via stacks, patterns, net sources) are CSR columns a row
//! names by index. `Rule`, a tagged union over the row types, is only the
//! boundary value a builder pushes and `RuleSet.get` gathers back. The
//! spine (`run.zig`) iterates `order` and switches exhaustively on the
//! kind, one `RuleRun` per rule. Net rules read the extraction as a column,
//! `poly_net` (`NetTable.netColumn`), so drc sits above topology's types.
//!
//! Contents:
//! - `kinds`: `Kind`, `byName`, `count`
//! - `rows`: `Rule`, `Row`, the row types and their small types
//! - `tables`: `SpacingTable`, `CutClassTable`, `ClassTable`, `SpanTable`, `CoverBands`, `CutAreaBands`, `DefectSizes`
//! - `rule_set`: `RuleSet`, `Slot`, `Csr`
//! - `params`: `Error`, `Diagnostic`, `Reader`; `compile`: `fromDeck`; `validate`: `validate`
//! - `rule_layers`: `layersOf`; `scratch`: `Scratch`, `Ctx`; `run_` (run.zig): `run`, `ported`
//! - family files: `width`, `width_edges`, `width_step`, `pattern`
//! - aliases: `Kind`, `Rule`, `RuleSet`, `Error`, `Diagnostic`, `fromDeck`, `run`

pub const kinds = @import("kinds.zig");
pub const rows = @import("rows.zig");
pub const tables = @import("tables.zig");
pub const rule_set = @import("rule_set.zig");
pub const params = @import("params.zig");
pub const compile = @import("compile.zig");
pub const validate = @import("validate.zig");
pub const rule_layers = @import("rule_layers.zig");
pub const scratch = @import("scratch.zig");
pub const run_ = @import("run.zig");
pub const width = @import("width.zig");
pub const width_edges = @import("width_edges.zig");
pub const width_step = @import("width_step.zig");
pub const pattern = @import("pattern.zig");

pub const Kind = kinds.Kind;
pub const Rule = rows.Rule;
pub const RuleSet = rule_set.RuleSet;
pub const Error = params.Error;
pub const Diagnostic = params.Diagnostic;
pub const fromDeck = compile.fromDeck;
pub const run = run_.run;

test {
    _ = kinds;
    _ = rows;
    _ = tables;
    _ = rule_set;
    _ = compile;
    _ = validate;
    _ = rule_layers;
    _ = run_;
    _ = width;
    _ = width_edges;
    _ = width_step;
    _ = pattern;
}
