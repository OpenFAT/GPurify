//! A deck back to text, the inverse of the parser: `parseSource` of
//! `print`'s text gives back an equivalent `DeckSource`, one that lowers to
//! the same `Deck` in the same string table. Every value is written in the
//! unit the engines store it in, as the shortest decimal that reads back to
//! the same number; a hidden layer is written back as the expression that
//! made it, where it was made, so every layer keeps its id. Ported from
//! crates/ingest/src/deck/print.rs (`print`, `deck`, `write_rule`,
//! `connectivity`, `devices`, `lvs`).
//!
//! Contents:
//! - `pub fn print(arena: Allocator, doc: *const DeckSource, grid: Grid, why: *[]const u8) PrintError![]const u8`

const std = @import("std");
const Allocator = std.mem.Allocator;
const geom = @import("geom");
const Grid = geom.Grid;
const source = @import("source.zig");
const DeckSource = source.DeckSource;
const RuleSource = source.RuleSource;
const kinds = @import("kinds.zig");
const print_layers = @import("print_layers.zig");
const Printer = print_layers.Printer;
const PrintError = print_layers.PrintError;
const print_rules = @import("print_rules.zig");
const devices = @import("parse_statements.zig").devices;

/// Writes `doc`, read for the layout grid `grid`, as deck text in `arena`:
/// the grid, drawn layers, ignored pairs, derived layers and rules in
/// declaration order (each rule where its first inline layer was made),
/// then connectivity, devices, `lvs`, the stack, corners, waivers and the
/// rest. `for` loops and `let` bindings are not reconstructed.
/// `Unprintable` for what the language cannot state; `why` says what.
pub fn print(arena: Allocator, doc: *const DeckSource, grid: Grid, why: *[]const u8) PrintError![]const u8 {
    const p: Printer = .{ .arena = arena, .source = doc, .grid = grid, .why = why };
    var out: std.ArrayList(u8) = .empty;
    try out.print(arena, "grid {s}\n", .{try p.length(1)});
    for (doc.layers.items) |l| try out.print(arena, "layer {s} = gds({d}, {d})\n", .{ l.name, l.stream[0], l.stream[1] });
    for (doc.ignored.items) |pair| try out.print(arena, "ignore gds({d}, {d})\n", .{ pair[0], pair[1] });
    // Rules in order; one whose inline layers were made between two derived
    // layers is written there, with every rule before it, so each layer
    // keeps its id.
    var written: usize = 0;
    var stage: usize = 0;
    for (doc.derived.items) |row| {
        if (std.mem.indexOfScalar(u8, row.name, '#') != null) continue;
        const at_sign = std.mem.indexOfScalar(u8, row.name, '@') orelse {
            try out.print(arena, "layer {s} = {s}\n", .{ row.name, try p.expr(row) });
            continue;
        };
        const owner = row.name[0..at_sign];
        const done = for (doc.rules.items[0..written]) |r| {
            if (std.mem.eql(u8, r.id, owner)) break true;
        } else false;
        if (done) continue;
        const at = for (doc.rules.items[written..], 0..) |r, i| {
            if (std.mem.eql(u8, r.id, owner)) break i;
        } else return p.unprintable("layer {s} belongs to no rule", .{row.name});
        for (doc.rules.items[written .. written + at + 1]) |r| try writeRule(&p, r, &stage, &out);
        written += at + 1;
    }
    for (doc.rules.items[written..]) |r| try writeRule(&p, r, &stage, &out);
    // Stages no rule is in, after the last rule.
    if (stage < doc.stages.items.len) for (doc.stages.items[stage..]) |s| try out.print(arena, "stage {s}\n", .{s.name});
    if (doc.temperature) |t| try out.print(arena, "temperature {s}K nominal {s}K\n", .{ try p.number(t.operating_k), try p.number(t.nominal_k) });
    try connectivity(&p, &out);
    try deviceLines(&p, &out);
    try lvs(&p, &out);
    for (doc.pex.items) |row| {
        const r = row.row;
        try out.print(arena, "pex {s} thickness {s}nm height {s}nm sheet {s}ohm area_cap {s}aF/um2 fringe_cap {s}aF/um", .{ row.layer, try p.number(r.thickness_nm), try p.number(r.height_nm), try p.number(r.sheet_res_ohm_sq), try p.number(r.area_cap_af_um2), try p.number(r.fringe_cap_af_um) });
        if (r.dielectric_k != 0.0) try out.print(arena, " dielectric {s}", .{try p.number(r.dielectric_k)});
        if (r.tc) |tc| try out.print(arena, " tc1 {s}/K tc2 {s}/K2", .{ try p.number(tc[0]), try p.number(tc[1]) });
        try out.append(arena, '\n');
    }
    const corner_units = [_][]const u8{ "nm", "nm", "ohm", "", "aF/um2", "aF/um", "/K", "/K2" };
    for (doc.corners.items) |line| {
        try out.print(arena, "corner {s} {s}", .{ line.corner, line.layer });
        for (kinds.pex_keys, line.values, corner_units) |key, value, unit| {
            if (value) |v| try out.print(arena, " {s} {s}{s}", .{ key[0], try p.number(v), unit });
        }
        try out.append(arena, '\n');
    }
    for (doc.waivers.items) |w| try out.print(arena, "waive {s} {s}\n", .{ w.rule, w.layer });
    if (doc.boundary) |b| try out.print(arena, "boundary {s}\n", .{b});
    if (doc.netlist_scale_nm) |nm| try out.print(arena, "netlist_scale {s}nm\n", .{try p.number(nm)});
    try models(&p, &out);
    return out.items;
}

// ---- private ----

/// Writes `r`, headed by the `stage` lines up to its own (the last stage
/// for a rule no stage lists); `stage` counts the stages headed so far.
fn writeRule(p: *const Printer, r: RuleSource, stage: *usize, out: *std.ArrayList(u8)) PrintError!void {
    const stages = p.source.stages.items;
    if (stages.len == 0) return out.print(p.arena, "{s}\n", .{try print_rules.rule(p, r)});
    const own = for (stages, 0..) |s, i| {
        const listed = for (s.rules.items) |id| {
            if (std.mem.eql(u8, id, r.id)) break true;
        } else false;
        if (listed) break i;
    } else stages.len - 1;
    if (own + 1 < stage.*) return p.unprintable("rule {s} is in stage {s}, which an earlier rule's stage follows", .{ r.id, stages[own].name });
    while (stage.* <= own) : (stage.* += 1) try out.print(p.arena, "stage {s}\n", .{stages[stage.*].name});
    try out.print(p.arena, "{s}\n", .{try print_rules.rule(p, r)});
}

fn connectivity(p: *const Printer, out: *std.ArrayList(u8)) PrintError!void {
    const c = &p.source.connectivity;
    const a = p.arena;
    if (c.conductors.items.len > 0) try out.print(a, "connect conductors [{s}]\n", .{try std.mem.join(a, ", ", c.conductors.items)});
    if (c.intra_layer_touch) try out.appendSlice(a, "connect touch_within_layer\n");
    for (c.global.items) |g| try out.print(a, "connect global {s}\n", .{g});
    for (c.vias.items) |v| try out.print(a, "connect via {s} [{s}, {s}]\n", .{ v.layer, v.connects[0], v.connects[1] });
    for (c.labels.items) |l| try out.print(a, "connect label {s} names {s}\n", .{ l.layer, l.names });
}

fn deviceLines(p: *const Printer, out: *std.ArrayList(u8)) PrintError!void {
    const a = p.arena;
    for (p.source.devices.items) |d| {
        // A cell is in no device statement's table; `lvs blackbox` declares one.
        const kind = for (devices) |e| {
            if (e[1] == d.kind) break e[0];
        } else "cell";
        try out.print(a, "device {s} {s} model {s} terminals [{s}]", .{ kind, d.marker, try p.quoted(d.model), try std.mem.join(a, ", ", d.terminals) });
        const v = d.value;
        const values = [_]struct { []const u8, ?f64, []const u8 }{
            .{ "sheet", v.sheet_ohm_sq, "ohm" },
            .{ "area_cap", v.area_cap_af_um2, "aF/um2" },
            .{ "fringe_cap", v.fringe_cap_af_um, "aF/um" },
            .{ "inductance", v.inductance_nh, "nH" },
            .{ "on_gate_min", v.on_gate_min_mv, "mV" },
            .{ "on_gate_max", v.on_gate_max_mv, "mV" },
        };
        for (values) |row| if (row[1]) |x| try out.print(a, " {s} {s}{s}", .{ row[0], try p.number(x), row[2] });
        try out.append(a, '\n');
    }
}

/// The `lvs` statements, a kind at a time, each kind in deck order.
fn lvs(p: *const Printer, out: *std.ArrayList(u8)) PrintError!void {
    const s = &p.source.lvs;
    const a = p.arena;
    if (s.default_tolerance) |f| try out.print(a, "lvs tolerance default relative {s}\n", .{try p.number(f)});
    for (s.tolerance.items) |row| {
        try out.print(a, "lvs tolerance {s} {s}", .{ try p.quoted(row.model), row.param });
        if (row.relative > 0.0 or row.absolute == 0.0) try out.print(a, " relative {s}", .{try p.number(row.relative)});
        if (row.absolute > 0.0) {
            const unit = @import("tables.zig").absoluteUnit(row.param) orelse return p.unprintable("`{s}` takes no absolute tolerance", .{row.param});
            try out.print(a, " absolute {s}{s}", .{ try p.number(row.absolute), unit.unit });
        }
        try out.append(a, '\n');
    }
    for (s.ignore_parameter.items) |row| try out.print(a, "lvs ignore_parameter {s} {s}\n", .{ try p.quoted(row.a), row.b });
    for (s.asymmetric.items) |m| try out.print(a, "lvs asymmetric {s}\n", .{try p.quoted(m)});
    for (s.permute.items) |row| try out.print(a, "lvs permute {s} {s} {s}\n", .{ try p.quoted(row.model), row.a, row.b });
    for (s.ignore.items) |m| try out.print(a, "lvs ignore {s}\n", .{try p.quoted(m)});
    for (s.ignore_shorted.items) |m| try out.print(a, "lvs ignore_shorted {s}\n", .{try p.quoted(m)});
    if (s.ports_by_name) try out.appendSlice(a, "lvs ports_by_name\n");
    if (s.recognize_gates) try out.appendSlice(a, "lvs recognize_gates\n");
    if (s.filter_unused.items.len > 0) {
        var names: std.ArrayList([]const u8) = .empty;
        for (s.filter_unused.items) |o| try names.append(a, o.name());
        try out.print(a, "lvs filter_unused {s}\n", .{try std.mem.join(a, " ", names.items)});
    }
    if (s.supply.items.len > 0) try out.print(a, "lvs supply {s}\n", .{try p.quotedAll(s.supply.items, " ")});
    for (s.blackbox.items) |pattern| try out.print(a, "lvs blackbox {s}\n", .{try p.quoted(pattern)});
    for (s.range.items) |row| {
        try out.print(a, "lvs range {s} {s}", .{ try p.quoted(row.model), row.param });
        for ([2]?@import("tables.zig").LvsLimit{ row.min, row.max }, [2][]const u8{ ">=", "<=" }) |limit, cmp| {
            const l = limit orelse continue;
            const text = switch (l) {
                .length => |len| try p.dbu(len),
                .area => |ar| try p.area(ar),
                .count => |n| try std.fmt.allocPrint(a, "{d}", .{n}),
            };
            try out.print(a, " {s} {s}", .{ cmp, text });
        }
        try out.append(a, '\n');
    }
    if (s.topology) |relaxed| try out.print(a, "lvs topology {s}\n", .{if (relaxed) "relaxed" else "strict"});
    for (s.connect_implicit.items) |pattern| try out.print(a, "lvs connect_implicit {s}\n", .{try p.quoted(pattern)});
    for (s.connect_explicit.items) |group| try out.print(a, "lvs connect_explicit {s}\n", .{try p.quotedAll(group, " ")});
    if (s.max_res) |ohm| try out.print(a, "lvs max_res {s}ohm\n", .{try p.number(ohm)});
    if (s.min_caps) |af| try out.print(a, "lvs min_caps {s}aF\n", .{try p.number(af)});
    for (s.lde.items) |row| {
        try out.print(a, "lvs lde {s} od {s} max {s}", .{ try p.quoted(row.model), row.od, try p.dbu(row.max) });
        if (row.well) |w| try out.print(a, " well {s} scref {s}", .{ w.layer, try p.dbu(w.scref) });
        try out.append(a, '\n');
    }
    for (s.count.items) |row| {
        try out.print(a, "lvs count {s}", .{try p.quoted(row.model)});
        if (row.min) |n| try out.print(a, " >= {d}", .{n});
        if (row.max) |n| try out.print(a, " <= {d}", .{n});
        try out.append(a, '\n');
    }
    for (s.same_nets.items) |row| try out.print(a, "lvs same_nets {s} {s}\n", .{ try p.quoted(row.a), try p.quoted(row.b) });
}

/// The cold models and edits: `pex_fill`, `pex_tsv`, `pex_substrate`,
/// `fill`, `widen`, `report`, `pex_device`, `extraction`, in Rust's order.
fn models(p: *const Printer, out: *std.ArrayList(u8)) PrintError!void {
    const d = p.source;
    const a = p.arena;
    for (d.pex_models.fill.items) |f| try out.print(a, "pex_fill {s} {s}\n", .{ f.layer, f.treatment.word() });
    for (d.pex_models.tsv.items) |t| try out.print(a, "pex_tsv {s} length {s}nm liner {s}nm liner_k {s}\n", .{ t.layer, try p.number(t.length_nm), try p.number(t.liner_nm), try p.number(t.liner_k) });
    if (d.pex_models.substrate) |s| {
        const layers = try a.alloc([]const u8, s.layers.len);
        for (s.layers, layers) |l, *text| text.* = try std.fmt.allocPrint(a, "({s}nm, {s})", .{ try p.number(l[0]), try p.number(l[1]) });
        try out.print(a, "pex_substrate ports [{s}] backside {s} profile [{s}]\n", .{ try std.mem.join(a, ", ", s.ports), if (s.grounded) "grounded" else "floating", try std.mem.join(a, ", ", layers) });
    }
    for (d.edits.fill.items) |f| try out.print(a, "fill {s} for {s} size {s} space {s} keep {s} avoid [{s}]\n", .{ f.layer, f.density, try p.dbu(f.size), try p.dbu(f.space), try p.dbu(f.keep), try std.mem.join(a, ", ", f.avoid) });
    for (d.edits.widen.items) |w| try out.print(a, "widen {s} net {s} by {s}\n", .{ w.layer, try p.quoted(w.net), try p.dbu(w.by) });
    for (d.reports.p2p.items) |r| {
        const points = try a.alloc([]const u8, r.points.len);
        for (r.points, points) |pt, *text| text.* = try std.fmt.allocPrint(a, "({s}, {s})", .{ try p.dbu(pt[0]), try p.dbu(pt[1]) });
        try out.print(a, "report p2p {s} at [{s}]\n", .{ try p.quoted(r.net), try std.mem.join(a, ", ", points) });
    }
    for (d.reports.coupling.items) |c| try out.print(a, "report coupling {s} {s}\n", .{ try p.quoted(c.a), try p.quoted(c.b) });
    if (d.reports.cluster) |reach| try out.print(a, "report cluster {s}\n", .{try p.dbu(reach)});
    for (d.pex_models.device.items) |dev| try out.print(a, "pex_device {s} gate_contact_cap {s}aF/um gate_diffusion_cap {s}aF/um\n", .{ try p.quoted(dev.model), try p.number(dev.gate_contact_af_um), try p.number(dev.gate_diffusion_af_um) });
    if (d.extraction) |e| {
        try out.print(a, "extraction {s}", .{@tagName(e.kind)});
        if (e.coupling_threshold_af != 0.0) try out.print(a, " coupling_threshold {s}aF", .{try p.number(e.coupling_threshold_af)});
        if (e.coupling_halo) |h| try out.print(a, " coupling_halo {s}", .{try p.number(h)});
        try out.append(a, '\n');
    }
}
