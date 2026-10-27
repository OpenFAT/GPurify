//! The deck's `lvs` statements a fixture states, as the oracle reads them from
//! docs/src/reference/deck/lvs-controls.md, the deck lines that state them, and
//! what the layout measures on a drawn passive. Ported from
//! tests/exhaustive/lvs.rs (`Controls`, `pin_names`, `measured`, `close`).
//!
//! Contents:
//! - `pub const Absolute`, `pub const Tolerance`, `pub const Permuted`, `pub const SameNet`, `pub const Classes`
//! - `pub const Controls = struct`, `valueLaw`, `kept`, `classes`, `series`, `strip`, `deck`, `close`
//! - `pub fn pinNames(model: Model) []const []const u8`
//! - `pub fn measured(model: Model, name: []const u8) ?f64`
//! - `pub fn close(a: f64, b: f64) bool`

const std = @import("std");
const Allocator = std.mem.Allocator;
const circuit = @import("lvs_circuit.zig");
const Model = circuit.Model;
const Dev = circuit.Dev;
const Circuit = circuit.Circuit;

/// An absolute tolerance as the deck writes it and in SI.
pub const Absolute = struct { text: []const u8, si: f64 };

/// `lvs tolerance`: model, parameter, the relative part, and the absolute
/// part, when stated.
pub const Tolerance = struct { model: Model, param: []const u8, relative: f64, absolute: ?Absolute };

/// `lvs permute`: model and two pin positions in `Dev.pins` order.
pub const Permuted = struct { model: Model, a: usize, b: usize };

/// `lvs same_nets`: a layout label and a reference net name.
pub const SameNet = struct { layout: []const u8, reference: []const u8 };

/// Pin positions as classes of interchangeable pins: `class[k]` is the
/// smallest position of `k`'s class.
pub const Classes = [4]usize;

/// The controls a fixture states; the default states none.
pub const Controls = struct {
    tolerance: []const Tolerance = &.{},
    /// `lvs ignore_parameter`: model and parameter.
    ignored: []const struct { Model, []const u8 } = &.{},
    /// `lvs asymmetric`: MOS models whose source and drain do not swap.
    asymmetric: []const Model = &.{},
    permuted: []const Permuted = &.{},
    /// `lvs ignore`: models whose devices are left out on both sides.
    left_out: []const Model = &.{},
    /// `lvs ignore_shorted`: models whose dummies, every pin on one net,
    /// are left out on both sides.
    dummies_out: []const Model = &.{},
    /// `lvs ports_by_name`: each reference port pairs only with the layout
    /// net its name labels.
    ports_by_name: bool = false,
    /// `lvs topology relaxed`: parallel resistors and capacitors stating
    /// their value combine by its law.
    relaxed: bool = false,
    /// `lvs max_res`: as the deck writes it, and in ohms.
    max_res: ?Absolute = null,
    /// `lvs min_caps`: as the deck writes it, and in farads.
    min_caps: ?Absolute = null,
    same_nets: []const SameNet = &.{},
    /// `lvs recognize_gates`: a stack or a parallel group of plain,
    /// identical transistors takes its inputs in any order.
    gates: bool = false,
    /// `lvs filter_unused`: the options, as the deck spells them.
    unused: []const []const u8 = &.{},
    /// `lvs supply`: the supply net names `filter_unused c` reads.
    supply: []const []const u8 = &.{},
    /// `lvs blackbox`: cell-name patterns.
    boxed: []const []const u8 = &.{},

    /// The value a relaxed parallel merge combines on `model`, and whether
    /// harmonically: a resistor's `r` (`1 / Σ 1/r`), a capacitor's `c` (added),
    /// as docs/src/reference/deck/lvs-controls.md (Merging by value) says; null
    /// under the strict policy and for any other model.
    pub fn valueLaw(k: *const Controls, model: Model) ?struct { []const u8, bool } {
        if (!k.relaxed) return null;
        return switch (model) {
            .r => .{ "r", true },
            .c => .{ "c", false },
            .l => .{ "ind", true },
            .n, .p, .h, .b, .d, .q => null,
        };
    }

    /// `c` without the devices the controls leave out, as if never drawn or
    /// written: every one of an ignored model, each dummy (every pin on one
    /// net) of a model ignored when shorted, `filter_unused` on the drawing,
    /// and `max_res` and `min_caps` (docs/src/reference/deck/lvs-controls.md,
    /// Devices left out), each resistor above the one and capacitor below the
    /// other, its value what was drawn (`measured`) or what the card writes.
    /// Its nets stay, and `reduce` keeps only those a device or a port holds.
    pub fn kept(k: *const Controls, arena: Allocator, c: *const Circuit, drawn: bool) !Circuit {
        // `filter_unused` (docs/src/reference/deck/lvs-controls.md), on the
        // drawing alone and judged as drawn: a pin floats when its net holds no
        // other pin and is no port (no label).
        const held = try arena.alloc(usize, c.nets());
        @memset(held, 0);
        for (c.devs) |*d| for (d.pinsOf()) |p| {
            held[p] += 1;
        };
        var devs: std.ArrayList(Dev) = .empty;
        for (c.devs) |d| {
            if (try unused(k, c, held, &d, drawn)) continue;
            const dummy = for (d.pinsOf()) |p| (if (p != d.pins[0]) break false) else true;
            const value: ?f64 = switch (d.model) {
                .r => if (drawn) measured(d.model, "r") else d.value,
                .c => if (drawn) measured(d.model, "c") else d.value,
                .n, .p, .h, .b, .d, .q, .l => null,
            };
            const open = switch (d.model) {
                .r => k.max_res != null and value != null and value.? > k.max_res.?.si,
                .c => k.min_caps != null and value != null and value.? < k.min_caps.?.si,
                .n, .p, .h, .b, .d, .q, .l => false,
            };
            if (open or has(k.left_out, d.model) or (dummy and has(k.dummies_out, d.model))) continue;
            try devs.append(arena, d);
        }
        var out = try c.clone(arena);
        out.devs = devs.items;
        return out;
    }

    /// The pin positions of `model` (in `Dev.pins` order) as classes of
    /// interchangeable pins, as docs/src/reference/deck/lvs-controls.md
    /// (Interchangeable pins) gives them: a MOS's source and drain (1, 2)
    /// unless the model is asymmetric, a resistor's ends (0, 1), joined with
    /// every `lvs permute` pair of the model and closed under chaining.
    pub fn classes(k: *const Controls, model: Model) Classes {
        var class: Classes = .{ 0, 1, 2, 3 };
        if (model.isMos() and !has(k.asymmetric, model)) join(&class, 1, 2);
        switch (model) {
            .r, .l => join(&class, 0, 1),
            .n, .p, .h, .b, .c, .d, .q => {},
        }
        for (k.permuted) |p| if (p.model == model) join(&class, p.a, p.b);
        return class;
    }

    /// Whether transistors of `model` merge in series: only while their
    /// classes are the default ones, the channel the only pair.
    pub fn series(k: *const Controls, model: Model) bool {
        return std.mem.eql(usize, &k.classes(model), &.{ 0, 1, 1, 3 });
    }

    /// `c` with every parameter `lvs ignore_parameter` names dropped from
    /// its cards. Dropped from both sides is the same thing: the layout is
    /// measured only on what the reference's cards declare.
    pub fn strip(k: *const Controls, arena: Allocator, c: *const Circuit) !Circuit {
        const out = try c.clone(arena);
        for (out.devs) |*dev| {
            const model = dev.model;
            dev.writes_w = dev.writes_w and !ignores(k, model, "w");
            dev.writes_l = dev.writes_l and !ignores(k, model, "l");
            if (ignores(k, model, "area")) dev.area = null;
            if (ignores(k, model, model.primary())) dev.value = null;
            var kept_params: u8 = 0;
            for (0..dev.nparams) |i| if (!ignores(k, model, dev.params[i].name)) {
                dev.params[kept_params] = dev.params[i];
                kept_params += 1;
            };
            dev.nparams = kept_params;
        }
        return out;
    }

    /// The deck lines stating these controls.
    pub fn deck(k: *const Controls, arena: Allocator) ![]const u8 {
        var out: std.ArrayList(u8) = .empty;
        for (k.ignored) |row| try out.print(arena, "lvs ignore_parameter \"{s}\" {s}\n", .{ row[0].name(), row[1] });
        for (k.asymmetric) |m| try out.print(arena, "lvs asymmetric \"{s}\"\n", .{m.name()});
        for (k.left_out) |m| try out.print(arena, "lvs ignore \"{s}\"\n", .{m.name()});
        for (k.dummies_out) |m| try out.print(arena, "lvs ignore_shorted \"{s}\"\n", .{m.name()});
        if (k.ports_by_name) try out.appendSlice(arena, "lvs ports_by_name\n");
        if (k.relaxed) try out.appendSlice(arena, "lvs topology relaxed\n");
        if (k.max_res) |r| try out.print(arena, "lvs max_res {s}\n", .{r.text});
        if (k.min_caps) |cap| try out.print(arena, "lvs min_caps {s}\n", .{cap.text});
        if (k.gates) try out.appendSlice(arena, "lvs recognize_gates\n");
        for (k.boxed) |pattern| try out.print(arena, "lvs blackbox \"{s}\"\n", .{pattern});
        if (k.unused.len != 0) try out.print(arena, "lvs filter_unused {s}\n", .{try std.mem.join(arena, " ", k.unused)});
        if (k.supply.len != 0) {
            try out.appendSlice(arena, "lvs supply");
            for (k.supply, 0..) |n, i| try out.print(arena, "{s}\"{s}\"", .{ if (i == 0) " " else " ", n });
            try out.append(arena, '\n');
        }
        for (k.same_nets) |row| try out.print(arena, "lvs same_nets \"{s}\" \"{s}\"\n", .{ row.layout, row.reference });
        for (k.permuted) |p| {
            const names = pinNames(p.model);
            try out.print(arena, "lvs permute \"{s}\" {s} {s}\n", .{ p.model.name(), names[p.a], names[p.b] });
        }
        for (k.tolerance) |t| {
            try out.print(arena, "lvs tolerance \"{s}\" {s}", .{ t.model.name(), t.param });
            if (t.relative > 0.0) try out.print(arena, " relative {d}", .{t.relative});
            if (t.absolute) |a| try out.print(arena, " absolute {s}", .{a.text});
            try out.append(arena, '\n');
        }
        return out.items;
    }

    /// Whether `a` and `b`, values of `param` on `model` in a unit `si` times
    /// SI's, agree: under the model's row,
    /// `|a - b| <= absolute + relative * max(|a|, |b|)` with the parts adding
    /// as docs/src/reference/deck/lvs-controls.md (Tolerances) says; with no
    /// row, `close`.
    pub fn close(k: *const Controls, model: Model, param: []const u8, a: f64, b: f64, si: f64) bool {
        for (k.tolerance) |t| if (t.model == model and std.mem.eql(u8, t.param, param)) {
            const absolute = if (t.absolute) |abs| abs.si else 0.0;
            return @abs(a - b) * si <= absolute + t.relative * @max(@abs(a), @abs(b)) * si;
        };
        return closeDefault(a, b);
    }
};

/// The names docs/src/reference/deck/lvs-controls.md (Interchangeable pins)
/// gives `lvs permute` a pin of `model`, in `Dev.pins` order.
pub fn pinNames(model: Model) []const []const u8 {
    return switch (model) {
        .n, .p, .h, .b => &.{ "gate", "source", "drain", "bulk" },
        .r, .l => &.{ "end_a", "end_b" },
        .c => &.{ "top", "bottom" },
        .d => &.{ "anode", "cathode" },
        .q => &.{ "base", "emitter", "collector" },
    };
}

/// What the layout measures on a drawn passive or bipolar of `model`, in
/// SI, from the drawer's marker, 800 (1600 for a bipolar) by 400 nm, and
/// `extra_deck`'s coefficients: the marker's `area` and `perim`; a
/// resistor's body along its pads, `l` 800 nm, across them `w` 400 nm, and
/// `r` = 100 ohm/sq x 800 / 400 = 200 ohm; a capacitor's `c` = 1 fF/um² x
/// 0.32 um² + 0.1 fF/um x 2.4 um = 0.56 fF; a bipolar's emitter, its middle
/// pad 400 nm square, `ae` 0.16 um² and `pe` 1.6 um. Nothing else.
pub fn measured(model: Model, name: []const u8) ?f64 {
    const along: f64 = if (model == .q) 1600e-9 else 800e-9;
    const across: f64 = 400e-9;
    const area = along * across;
    const perim = 2.0 * (along + across);
    const eq = std.mem.eql;
    if (eq(u8, name, "area")) return area;
    if (eq(u8, name, "perim")) return perim;
    return switch (model) {
        .r => if (eq(u8, name, "l")) along else if (eq(u8, name, "w")) across else if (eq(u8, name, "r")) 100.0 * along / across else null,
        .c => if (eq(u8, name, "c")) 1e-3 * area + 1e-10 * perim else null,
        // The emitter, the middle pad, 400 nm square.
        .q => if (eq(u8, name, "ae")) 400e-9 * 400e-9 else if (eq(u8, name, "pe")) 1600e-9 else null,
        // The deck's `inductance 2nH`, every device of the recogniser.
        .l => if (eq(u8, name, "ind")) 2e-9 else null,
        .n, .p, .h, .b, .d => null,
    };
}

/// `|a - b| <= tol * max(|a|, |b|)`, the definition in `CompareOptions`.
pub fn close(a: f64, b: f64) bool {
    return closeDefault(a, b);
}

// ---- private ----

fn closeDefault(a: f64, b: f64) bool {
    return @abs(a - b) <= circuit.tolerance * @max(@abs(a), @abs(b));
}

fn has(models: []const Model, m: Model) bool {
    return std.mem.findScalar(Model, models, m) != null;
}

fn join(class: *Classes, a: usize, b: usize) void {
    const keep = @min(class[a], class[b]);
    const gone = @max(class[a], class[b]);
    for (class) |*k| if (k.* == gone) {
        k.* = keep;
    };
}

/// Whether `lvs ignore_parameter` names `name` on `model`.
fn ignores(k: *const Controls, model: Model, name: []const u8) bool {
    for (k.ignored) |row| if (row[0] == model and std.mem.eql(u8, row[1], name)) return true;
    return false;
}

/// Whether `filter_unused` (docs/src/reference/deck/lvs-controls.md) drops
/// drawn device `d`.
fn unused(k: *const Controls, c: *const Circuit, held: []const usize, d: *const Dev, drawn: bool) !bool {
    if (!drawn or !d.model.isMos()) return false;
    const g = d.pins[0];
    const s = d.pins[1];
    const dr = d.pins[2];
    const floats = struct {
        fn at(cc: *const Circuit, h: []const usize, net: usize) bool {
            return h[net] == 1 and !cc.ports[net];
        }
    }.at;
    const supply = c.ports[g] and for (k.supply) |n| (if (std.mem.eql(u8, n, c.names[g])) break true) else false;
    for (k.unused) |option| {
        const hit = if (std.mem.eql(u8, option, "ae"))
            floats(c, held, g) and floats(c, held, s) and floats(c, held, dr)
        else if (std.mem.eql(u8, option, "af"))
            s == dr
        else if (std.mem.eql(u8, option, "ag"))
            for (d.pinsOf()) |p| (if (p != g) break false) else true
        else if (std.mem.eql(u8, option, "u"))
            floats(c, held, s) and floats(c, held, dr)
        else if (std.mem.eql(u8, option, "c"))
            supply and (floats(c, held, s) or floats(c, held, dr))
        else
            return error.TestNoFilterOption;
        if (hit) return true;
    }
    return false;
}
