//! SPICE/CDL and Spectre cards → `Netlist` rows. Two passes: the first
//! collects every subcircuit definition, so a call may precede the
//! `.subckt` it names; the second reads each card into the tables; instance
//! port counts are checked last. An `X` card calling a deck device model is
//! that device (catalog LVS-067); a two-pin card or Spectre primitive naming
//! no model is the deck's one recogniser of its kind (testing-plan F86, F97).
//! Ported from crates/ingest/src/netlist.rs (`Build`, `read_dialect`,
//! `spice_card`, `spectre_card`, `spice::read`, `spectre::read`).
//!
//! Contents:
//! - `pub fn readSpice(gpa: Allocator, source: []const u8, strings: *StrTable, devices: *const DeviceRecognition, diag: *Diagnostic) Error!Netlist`
//! - `pub fn readSpectre(gpa: Allocator, source: []const u8, strings: *StrTable, devices: *const DeviceRecognition, diag: *Diagnostic) Error!Netlist`

const std = @import("std");
const Allocator = std.mem.Allocator;
const geom = @import("geom");
const StrId = geom.StrId;
const StrTable = geom.StrTable;
const tables = @import("deck/tables.zig");
const DeviceKind = tables.DeviceKind;
const DeviceRecognition = tables.DeviceRecognition;
const netlist = @import("netlist.zig");
const Netlist = netlist.Netlist;
const Error = netlist.Error;
const Diagnostic = netlist.Diagnostic;
const SubcktId = netlist.SubcktId;
const RefNetId = netlist.RefNetId;
const lexer = @import("netlist_lex.zig");
const Dialect = lexer.Dialect;
const Tok = lexer.Tok;
const build = @import("netlist_build.zig");
const Build = build.Build;

/// Reads a SPICE or CDL netlist, interning its names into `strings`.
/// `devices`: the deck's recognisers, whose models an `X` card may call as
/// a device; on such a card a bare `W`/`L` is in the deck's
/// `netlist_scale`. The first error found, with its line; nothing partial.
pub fn readSpice(gpa: Allocator, source: []const u8, strings: *StrTable, devices: *const DeviceRecognition, diag: *Diagnostic) Error!Netlist {
    return readDialect(gpa, source, strings, .spice, devices, diag);
}

/// Reads a Spectre netlist: `subckt`/`ends`, `model` cards, instances of a
/// subcircuit, a model or a built-in primitive master.
pub fn readSpectre(gpa: Allocator, source: []const u8, strings: *StrTable, devices: *const DeviceRecognition, diag: *Diagnostic) Error!Netlist {
    return readDialect(gpa, source, strings, .spectre, devices, diag);
}

// ---- private ----

fn readDialect(gpa: Allocator, source: []const u8, strings: *StrTable, dialect: Dialect, devices: *const DeviceRecognition, diag: *Diagnostic) Error!Netlist {
    var b: Build = .{ .gpa = gpa, .strings = strings, .diag = diag, .dialect = dialect };
    errdefer b.out.deinit(gpa);
    defer b.deinit();
    for (devices.model, devices.kind) |m, k| try b.deck.append(gpa, .{ .name = m, .kind = k });
    std.mem.sort(build.Named, b.deck.items, {}, build.lessNamed);
    dedup(&b.deck);
    // SPICE's `X` card may call a deck model; Spectre's models are its cards.
    if (dialect == .spice) try b.models.appendSlice(gpa, b.deck.items);
    b.scale = if (devices.netlist_scale_nm) |nm| nm / 1e9 else null;
    var cards = try lexer.lex(gpa, source, dialect);
    defer cards.deinit(gpa);
    const count = cards.start.items.len - 1;
    for (0..count) |k| {
        const card = cards.card(k);
        if (!isDefinition(card, dialect)) continue;
        if (card.len < 2) return b.fail(error.Unexpected, card[0]);
        const id = try strings.intern(gpa, card[1].text);
        const at = build.lowerBound(b.defs.items, id);
        if (at < b.defs.items.len and b.defs.items[at].name == id) {
            diag.set(card[0].line, "{s}", .{card[1].text});
            return error.Redefined;
        }
        const subckt: SubcktId = @fromBackingInt(@as(u32, @intCast(b.out.subckt_name.items.len)));
        try b.out.subckt_name.append(gpa, id);
        try b.defs.insert(gpa, at, .{ .name = id, .subckt = subckt });
    }
    var next: u32 = 0;
    for (0..count) |k| switch (dialect) {
        .spice => try spiceCard(&b, cards.card(k), &next),
        .spectre => try spectreCard(&b, cards.card(k), &next),
    };
    if (b.open != null) {
        diag.set(b.open_line, "{s}", .{if (dialect == .spice) ".subckt" else "subckt"});
        return error.Unexpected;
    }
    // The terminating entry of every CSR offset column.
    const o = &b.out;
    try o.subckt_port_start.append(gpa, @intCast(o.port_net.items.len));
    try o.subckt_device_start.append(gpa, @intCast(o.device_model.items.len));
    try o.device_terminal_start.append(gpa, @intCast(o.terminal_net.items.len));
    try o.device_param_start.append(gpa, @intCast(o.param.items.len));
    // Fail closed on a miswired instantiation: every port count is known now.
    for (b.instances.items, o.instance_of.items) |inst, of| {
        const want = o.portsOf(of).len;
        if (inst.got != want) {
            diag.set(inst.line, "{s}", .{strings.resolve(inst.name)});
            diag.got = inst.got;
            diag.want = @intCast(want);
            return error.TerminalCount;
        }
    }
    return b.out;
}

fn dedup(list: *std.ArrayList(build.Named)) void {
    var kept: usize = 0;
    for (list.items) |item| {
        if (kept > 0 and list.items[kept - 1].name == item.name) continue;
        list.items[kept] = item;
        kept += 1;
    }
    list.shrinkRetainingCapacity(kept);
}

/// Is this card a subcircuit definition?
fn isDefinition(card: []const Tok, dialect: Dialect) bool {
    return switch (dialect) {
        .spice => std.ascii.eqlIgnoreCase(card[0].text, ".subckt"),
        .spectre => std.mem.eql(u8, card[0].text, "subckt"),
    };
}

/// One SPICE or CDL card.
fn spiceCard(b: *Build, card: []const Tok, next: *u32) Error!void {
    const head = card[0];
    if (head.text[0] == '.') {
        const word = head.text[1..];
        if (std.ascii.eqlIgnoreCase(word, "subckt")) return b.openSubckt(card, next);
        if (std.ascii.eqlIgnoreCase(word, "ends") or std.ascii.eqlIgnoreCase(word, "end")) return b.closeSubckt();
        return b.fail(error.Unsupported, head);
    }
    const subckt = try b.openId(head);
    const split = try lexer.splitParams(card, b.diag);
    const positional = split.head;
    const kind: DeviceKind = switch (std.ascii.toUpper(head.text[0])) {
        'M' => .mos,
        'Q' => .bjt,
        'R' => .resistor,
        'C' => .capacitor,
        'D' => .diode,
        'L' => .inductor,
        'X' => {
            if (positional.len == 0) return b.fail(error.Unexpected, head);
            const cell = positional[positional.len - 1];
            // A PDK primitive called as a subcircuit is a device when the
            // deck names it, whether or not the netlist also defines it.
            const id = try b.strings.intern(b.gpa, cell.text);
            const at = build.lowerBoundNamed(b.models.items, id);
            if (at < b.models.items.len and b.models.items[at].name == id) {
                const model_kind = b.models.items[at].kind;
                const t = try lexer.splitTerminals(model_kind, positional, head, b.diag);
                return b.device(head, model_kind, t.head, null, t.rest[0], split.rest, subckt, b.scale);
            }
            return b.instance(head, cell, positional[0 .. positional.len - 1], split.rest, subckt);
        },
        else => return b.fail(error.Unsupported, head),
    };
    // `R1 a b 1k rpoly`: two nets, the value, the model; a two-pin card may
    // leave its model out (testing-plan F86).
    const valued = kind == .resistor or kind == .capacitor or kind == .inductor;
    if (valued and positional.len == 4) return b.device(head, kind, positional[0..2], positional[2], positional[3], split.rest, subckt, null);
    if (valued and positional.len == 3 and lexer.spiceNumber(positional[2].text) != null) return b.device(head, kind, positional[0..2], positional[2], null, split.rest, subckt, null);
    if (positional.len == 2 and (valued or kind == .diode)) return b.device(head, kind, positional, null, null, split.rest, subckt, null);
    const t = try lexer.splitTerminals(kind, positional, head, b.diag);
    return b.device(head, kind, t.head, null, t.rest[0], split.rest, subckt, null);
}

/// One Spectre statement.
fn spectreCard(b: *Build, card: []const Tok, next: *u32) Error!void {
    const head = card[0];
    const h = head.text;
    if (std.mem.eql(u8, h, "subckt")) return b.openSubckt(card, next);
    if (std.mem.eql(u8, h, "ends") or std.mem.eql(u8, h, "endsubckt")) return b.closeSubckt();
    if (std.mem.eql(u8, h, "model")) {
        if (card.len < 3) return b.fail(error.Unexpected, head);
        const name = card[1];
        const master = card[2];
        const kind = lexer.spectrePrimitive(master.text) orelse return b.fail(error.Unsupported, master);
        const id = try b.strings.intern(b.gpa, name.text);
        const at = build.lowerBoundNamed(b.models.items, id);
        if (at < b.models.items.len and b.models.items[at].name == id) return b.fail(error.Redefined, name);
        try b.models.insert(b.gpa, at, .{ .name = id, .kind = kind });
        return;
    }
    // An instance statement, `name (nets…) master [params]`, classified
    // before "is a subcircuit open": a statement between subcircuits is
    // unsupported rather than misplaced.
    const split = try lexer.splitParams(card, b.diag);
    const positional = split.head;
    if (positional.len == 0) return b.fail(error.Unsupported, head);
    const master = positional[positional.len - 1];
    const master_id = try b.strings.intern(b.gpa, master.text);
    const def = build.lowerBound(b.defs.items, master_id);
    if (def < b.defs.items.len and b.defs.items[def].name == master_id) {
        const subckt = try b.openId(head);
        return b.instance(head, master, positional[0 .. positional.len - 1], split.rest, subckt);
    }
    // A `model` card's name is the model; a primitive master names none, so
    // the instance is the deck's one recogniser of its kind (F97).
    const at = build.lowerBoundNamed(b.models.items, master_id);
    const named = at < b.models.items.len and b.models.items[at].name == master_id;
    const kind = if (named) b.models.items[at].kind else lexer.spectrePrimitive(master.text) orelse return b.fail(error.Unsupported, head);
    const subckt = try b.openId(head);
    const t = try lexer.splitTerminals(kind, positional, head, b.diag);
    return b.device(head, kind, t.head, null, if (named) t.rest[0] else null, split.rest, subckt, null);
}
