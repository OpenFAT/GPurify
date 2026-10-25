//! The netlist tables under construction, and the row writers every card
//! reader calls: a net by name in the open subcircuit, a subcircuit opened
//! and closed, a parameter in SI units, a device, an instance. Ported from
//! crates/ingest/src/netlist.rs (`Build` and its methods).
//!
//! Contents:
//! - `pub const Named`, `pub const Def`, `pub const PendingInstance`
//! - `pub const Build`, `Build.deinit(b: *Build) void`,
//!   `Build.fail(b: *Build, err: Error, t: Tok) Error`,
//!   `Build.openId(b: *Build, head: Tok) Error!SubcktId`,
//!   `Build.openSubckt(b: *Build, card: []const Tok, next: *u32) Error!void`,
//!   `Build.closeSubckt(b: *Build) Error!void`,
//!   `Build.device(b: *Build, head: Tok, kind: DeviceKind, nets: []const Tok, value: ?Tok, model: ?Tok, params: []const Tok, subckt: SubcktId, scale: ?f64) Error!void`,
//!   `Build.instance(b: *Build, head: Tok, cell: Tok, nets: []const Tok, params: []const Tok, subckt: SubcktId) Error!void`
//! - `pub fn lessNamed(_: void, a: Named, b: Named) bool`
//! - `pub fn lowerBound(defs: []const Def, name: StrId) usize`, `pub fn lowerBoundNamed(rows: []const Named, name: StrId) usize`

const std = @import("std");
const Allocator = std.mem.Allocator;
const geom = @import("geom");
const StrId = geom.StrId;
const StrTable = geom.StrTable;
const tables = @import("deck/tables.zig");
const DeviceKind = tables.DeviceKind;
const netlist = @import("netlist.zig");
const Netlist = netlist.Netlist;
const Error = netlist.Error;
const Diagnostic = netlist.Diagnostic;
const SubcktId = netlist.SubcktId;
const RefNetId = netlist.RefNetId;
const lexer = @import("netlist_lex.zig");
const Dialect = lexer.Dialect;
const Tok = lexer.Tok;

/// A model name and its device family, sorted by id for binary search.
pub const Named = struct { name: StrId, kind: DeviceKind };
/// A subcircuit definition by name, sorted by id.
pub const Def = struct { name: StrId, subckt: SubcktId };
/// Where an instance was written, its name and terminal count, for the
/// arity check at end of file.
pub const PendingInstance = struct { line: u32, name: StrId, got: u32 };

/// The tables under construction plus the side tables a parse needs.
pub const Build = struct {
    gpa: Allocator,
    strings: *StrTable,
    diag: *Diagnostic,
    dialect: Dialect,
    out: Netlist = .{},
    /// `net_of[name]` is the net that name has in the open subcircuit, or
    /// `no_net`; reset per subcircuit.
    net_of: std.ArrayList(u32) = .empty,
    defs: std.ArrayList(Def) = .empty,
    /// Spectre `model` cards, or for SPICE the deck's models an `X` card
    /// may call.
    models: std.ArrayList(Named) = .empty,
    /// The deck's device models, one row per name.
    deck: std.ArrayList(Named) = .empty,
    /// The deck's `netlist_scale`, metres.
    scale: ?f64 = null,
    /// The open subcircuit and the `net_name` row its nets start at.
    open: ?struct { subckt: SubcktId, first_net: u32 } = null,
    open_line: u32 = 0,
    instances: std.ArrayList(PendingInstance) = .empty,

    pub fn deinit(b: *Build) void {
        b.net_of.deinit(b.gpa);
        b.defs.deinit(b.gpa);
        b.models.deinit(b.gpa);
        b.deck.deinit(b.gpa);
        b.instances.deinit(b.gpa);
    }

    /// `err` at `t`'s line, naming its text.
    pub fn fail(b: *Build, err: Error, t: Tok) Error {
        b.diag.set(t.line, "{s}", .{t.text});
        return err;
    }

    /// The subcircuit a card sits in; a card outside every subcircuit has no
    /// row to land in, so it is refused rather than dropped.
    pub fn openId(b: *Build, head: Tok) Error!SubcktId {
        const o = b.open orelse return b.fail(error.Unsupported, head);
        return o.subckt;
    }

    pub fn openSubckt(b: *Build, card: []const Tok, next: *u32) Error!void {
        const head = card[0];
        if (b.open != null or card.len < 2) return b.fail(error.Unexpected, head);
        // The definition pass walked the same cards in the same order.
        const id: SubcktId = @fromBackingInt(next.*);
        next.* += 1;
        try b.out.subckt_port_start.append(b.gpa, @intCast(b.out.port_net.items.len));
        try b.out.subckt_device_start.append(b.gpa, @intCast(b.out.device_model.items.len));
        b.open = .{ .subckt = id, .first_net = @intCast(b.out.net_name.items.len) };
        b.open_line = head.line;
        for (card[2..]) |port| {
            // A parameterised subcircuit has nowhere to keep its parameters.
            if (std.mem.indexOfScalar(u8, port.text, '=') != null) return b.fail(error.Unsupported, port);
            try b.out.port_net.append(b.gpa, try b.net(port.text, id));
        }
    }

    pub fn closeSubckt(b: *Build) Error!void {
        const o = b.open orelse return;
        b.open = null;
        for (b.out.net_name.items[o.first_net..]) |name| b.net_of.items[@backingInt(name)] = no_net;
    }

    /// A device card: `value`, an `R`/`C`/`L` card's positional value, is
    /// stored as its first parameter; a null `model` binds the card to the
    /// deck's one recogniser of its kind; `scale` is metres per unit of a
    /// bare length, as on a PDK model's `X` card.
    pub fn device(b: *Build, head: Tok, kind: DeviceKind, nets: []const Tok, value: ?Tok, model: ?Tok, params: []const Tok, subckt: SubcktId, scale: ?f64) Error!void {
        // A bare number where a model name belongs is refused rather than
        // interned as a model name.
        if (model) |m| if (lexer.spiceNumber(m.text) != null) {
            b.diag.set(m.line, "{s} with no model after it", .{m.text});
            return error.Unsupported;
        };
        const primary: ?netlist.Param = if (value) |tok| blk: {
            const number = lexer.spiceNumber(tok.text) orelse return b.fail(error.Unexpected, tok);
            const name: []const u8 = switch (kind) {
                .capacitor => "c",
                .inductor => "ind",
                else => "r", // else: only a resistor, capacitor or inductor states a value
            };
            break :blk .{ .name = try b.strings.intern(b.gpa, name), .value = number };
        } else null;
        // Not stored; interned only because interning order is report order.
        _ = try b.strings.intern(b.gpa, head.text);
        const model_id = if (model) |m| try b.strings.intern(b.gpa, m.text) else try b.onlyModel(head, kind);
        const o = &b.out;
        try o.device_terminal_start.append(b.gpa, @intCast(o.terminal_net.items.len));
        try o.device_param_start.append(b.gpa, @intCast(o.param.items.len));
        try o.device_model.append(b.gpa, model_id);
        try o.device_kind.append(b.gpa, kind);
        // Card order is the role, so terminals are pushed as written.
        for (nets) |n| try o.terminal_net.append(b.gpa, try b.net(n.text, subckt));
        const first = o.param.items.len;
        if (primary) |p| try o.param.append(b.gpa, p);
        for (params) |tok| {
            const p = try b.param(tok, kind, scale);
            // A parameter stated twice: which one is meant is a guess.
            for (o.param.items[first..]) |seen| if (seen.name == p.name) return b.fail(error.Unexpected, tok);
            try o.param.append(b.gpa, p);
        }
    }

    pub fn instance(b: *Build, head: Tok, cell: Tok, nets: []const Tok, params: []const Tok, subckt: SubcktId) Error!void {
        // A parameterised instantiation has nowhere to land.
        if (params.len > 0) return b.fail(error.Unsupported, params[0]);
        const id = try b.strings.intern(b.gpa, cell.text);
        const at = lowerBound(b.defs.items, id);
        if (at == b.defs.items.len or b.defs.items[at].name != id) return b.fail(error.UndefinedSubckt, cell);
        const name = try b.strings.intern(b.gpa, head.text);
        const o = &b.out;
        try o.instance_of.append(b.gpa, b.defs.items[at].subckt);
        try o.instance_subckt.append(b.gpa, subckt);
        try o.instance_name.append(b.gpa, name);
        try b.instances.append(b.gpa, .{ .line = head.line, .name = name, .got = @intCast(nets.len) });
        if (o.instance_net_start.items.len == 0) try o.instance_net_start.append(b.gpa, 0);
        for (nets) |n| try o.instance_net.append(b.gpa, try b.net(n.text, subckt));
        try o.instance_net_start.append(b.gpa, @intCast(o.instance_net.items.len));
    }

    // ---- private ----

    /// The net a name denotes in `subckt`, created on first mention.
    fn net(b: *Build, name: []const u8, subckt: SubcktId) Error!RefNetId {
        const id = try b.strings.intern(b.gpa, name);
        const slot = @backingInt(id);
        if (slot >= b.net_of.items.len) try b.net_of.appendNTimes(b.gpa, no_net, slot + 1 - b.net_of.items.len);
        if (b.net_of.items[slot] != no_net) return @fromBackingInt(b.net_of.items[slot]);
        const row: u32 = @intCast(b.out.net_name.items.len);
        try b.out.net_name.append(b.gpa, id);
        try b.out.net_subckt.append(b.gpa, subckt);
        b.net_of.items[slot] = row;
        return @fromBackingInt(row);
    }

    /// One `name=value`: SPICE names lowercased; a two-pin card's `a`, `p`,
    /// `pj` read as `area`, `perim` (testing-plan F87); an inductor's `l` as
    /// `ind`; a bare length times `scale`, a bare area times its square.
    fn param(b: *Build, tok: Tok, kind: DeviceKind, scale: ?f64) Error!netlist.Param {
        const eq = std.mem.indexOfScalar(u8, tok.text, '=') orelse return b.fail(error.Unexpected, tok);
        const raw_key = tok.text[0..eq];
        const text = tok.text[eq + 1 ..];
        if (raw_key.len == 0) return b.fail(error.Unexpected, tok);
        var value = lexer.spiceNumber(text) orelse return b.fail(error.Unexpected, tok);
        var buf: [64]u8 = undefined;
        if (raw_key.len > buf.len) return b.fail(error.Unexpected, tok);
        var key: []const u8 = if (b.dialect == .spice) std.ascii.lowerString(&buf, raw_key) else raw_key;
        const two_pin = kind == .resistor or kind == .capacitor or kind == .diode;
        if (b.dialect == .spice and two_pin) {
            if (std.mem.eql(u8, key, "a")) key = "area" else if (std.mem.eql(u8, key, "p") or std.mem.eql(u8, key, "pj")) key = "perim";
        }
        if (kind == .inductor and std.ascii.eqlIgnoreCase(key, "l")) key = "ind";
        const bare = text.len > 0 and (std.ascii.isDigit(text[text.len - 1]) or text[text.len - 1] == '.');
        if (scale) |s| if (bare) if (tables.absoluteUnit(key)) |u| {
            if (std.mem.eql(u8, u.unit, "nm")) value *= s else if (std.mem.eql(u8, u.unit, "nm2")) value *= s * s;
        };
        return .{ .name = try b.strings.intern(b.gpa, key), .value = value };
    }

    /// The model a card naming none is: the deck's one recogniser of `kind`.
    fn onlyModel(b: *Build, head: Tok, kind: DeviceKind) Error!StrId {
        var found: ?StrId = null;
        var n: usize = 0;
        for (b.deck.items) |d| if (d.kind == kind) {
            found = d.name;
            n += 1;
        };
        if (n == 1) return found.?;
        const what = @tagName(kind);
        if (n == 0) {
            b.diag.setHas("the deck has no {s} recogniser to bind it to", .{what});
        } else {
            var names: std.ArrayList([]const u8) = .empty;
            defer names.deinit(b.gpa);
            for (b.deck.items) |d| if (d.kind == kind) try names.append(b.gpa, b.strings.resolve(d.name));
            const joined = try std.mem.join(b.gpa, ", ", names.items);
            defer b.gpa.free(joined);
            b.diag.setHas("the deck has several {s} models: {s}", .{ what, joined });
        }
        return b.fail(error.NoModel, head);
    }
};

/// `net_of`'s "this name is not a net of the open subcircuit".
const no_net: u32 = std.math.maxInt(u32);

pub fn lessNamed(_: void, a: Named, b: Named) bool {
    return @backingInt(a.name) < @backingInt(b.name);
}

/// The insertion point of `name` in `defs`, sorted by id.
pub fn lowerBound(defs: []const Def, name: StrId) usize {
    var lo: usize = 0;
    var hi: usize = defs.len;
    while (lo < hi) {
        const mid = lo + (hi - lo) / 2;
        if (@backingInt(defs[mid].name) < @backingInt(name)) lo = mid + 1 else hi = mid;
    }
    return lo;
}

/// The insertion point of `name` in `rows`, sorted by id.
pub fn lowerBoundNamed(rows: []const Named, name: StrId) usize {
    var lo: usize = 0;
    var hi: usize = rows.len;
    while (lo < hi) {
        const mid = lo + (hi - lo) / 2;
        if (@backingInt(rows[mid].name) < @backingInt(name)) lo = mid + 1 else hi = mid;
    }
    return lo;
}
