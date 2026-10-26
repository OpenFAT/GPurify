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
//! - family files: `patterning`, `patterning_color`, `via_cuts`, `via_stack`, `via_connectors`, `dfm`, `overlay`, `overlay_octilinear`, `overlay_enclosure`, `overlay_strips`, `presence`, `edge`, `grid`, `area_critical`, `area_density`, `area`, `density`, `facing_span`, `facing_keep_out`, `facing`, `facing_edges`, `width`, `width_edges`, `width_step`, `pattern`, `runs`, `parts`, `spacing`,
//!   `spacing_ends`, `spacing_net`, `spacing_table`
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
pub const runs = @import("runs.zig");
pub const parts = @import("parts.zig");
pub const spacing = @import("spacing.zig");
pub const spacing_ends = @import("spacing_ends.zig");
pub const spacing_net = @import("spacing_net.zig");
pub const spacing_table = @import("spacing_table.zig");
pub const facing_edges = @import("facing_edges.zig");
pub const facing = @import("facing.zig");
pub const facing_keep_out = @import("facing_keep_out.zig");
pub const facing_span = @import("facing_span.zig");
pub const density = @import("density.zig");
pub const area = @import("area.zig");
pub const area_density = @import("area_density.zig");
pub const area_critical = @import("area_critical.zig");
pub const grid = @import("grid.zig");
pub const edge = @import("edge.zig");
pub const presence = @import("presence.zig");
pub const overlay_strips = @import("overlay_strips.zig");
pub const overlay_enclosure = @import("overlay_enclosure.zig");
pub const overlay_octilinear = @import("overlay_octilinear.zig");
pub const overlay = @import("overlay.zig");
pub const dfm = @import("dfm.zig");
pub const patterning = @import("patterning.zig");
pub const patterning_color = @import("patterning_color.zig");
pub const via_cuts = @import("via_cuts.zig");
pub const via_stack = @import("via_stack.zig");
pub const via_connectors = @import("via_connectors.zig");

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
    _ = runs;
    _ = parts;
    _ = spacing;
    _ = spacing_ends;
    _ = spacing_net;
    _ = spacing_table;
    _ = facing_edges;
    _ = facing;
    _ = facing_keep_out;
    _ = facing_span;
    _ = density;
    _ = area;
    _ = area_density;
    _ = area_critical;
    _ = grid;
    _ = edge;
    _ = presence;
    _ = overlay_strips;
    _ = overlay_enclosure;
    _ = overlay_octilinear;
    _ = overlay;
    _ = dfm;
    _ = patterning;
    _ = patterning_color;
    _ = via_cuts;
    _ = via_stack;
    _ = via_connectors;
}
