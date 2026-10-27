//! Reference netlists: SPICE/CDL and Spectre text (and structural Verilog
//! over either, `verilog.zig`) → one `Netlist`, hierarchy kept. Anything
//! outside the declared subset is an error with its source line, never a
//! guess. The subset is crates/ingest/src/netlist.rs's module docs: both
//! dialects read subcircuit definitions with ports, device cards with every
//! terminal before any `name=value`, and subcircuit instances; a call may
//! come before the definition it names; every card sits in a subcircuit.
//! Ported from crates/ingest/src/netlist.rs (types, `top`, `top_in`).
//!
//! Contents:
//! - `pub const max_flat_elements`, `pub const max_cell_pins`, `pub const max_hierarchy_depth`
//! - `pub const Error`, `pub const Diagnostic`, `Diagnostic.token(d: *const Diagnostic) []const u8`,
//!   `Diagnostic.has(d: *const Diagnostic) []const u8`,
//!   `Diagnostic.set(d: *Diagnostic, line: u32, comptime fmt: []const u8, args: anytype) void`,
//!   `Diagnostic.setHas(d: *Diagnostic, comptime fmt: []const u8, args: anytype) void`
//! - `pub const SubcktId`, `pub const RefNetId`, `pub const Param`, `pub const Placement`
//! - `pub const Netlist`, `Netlist.deinit(n: *Netlist, gpa: Allocator) void`,
//!   `Netlist.subcktCount(n: *const Netlist) u32`,
//!   `Netlist.portsOf(n: *const Netlist, cell: SubcktId) []const RefNetId`,
//!   `Netlist.devicesOf(n: *const Netlist, cell: SubcktId) [2]u32`,
//!   `Netlist.terminalsOf(n: *const Netlist, device: u32) []const RefNetId`,
//!   `Netlist.paramsOf(n: *const Netlist, device: u32) []const Param`,
//!   `Netlist.blackBoxPorts(n: *const Netlist, row: u32) []const StrId`,
//!   `Netlist.top(n: *const Netlist, gpa: Allocator) Allocator.Error!?SubcktId`,
//!   `Netlist.topIn(n: *const Netlist, gpa: Allocator, first: u32, end: u32) Allocator.Error!?SubcktId`

const std = @import("std");
const Allocator = std.mem.Allocator;
const geom = @import("geom");
const StrId = geom.StrId;
const DeviceKind = @import("deck/tables.zig").DeviceKind;

/// The most devices, nets and instances a reference may flatten to: a
/// layout's flat polygon cap (2^28), since every device and net of a layout
/// is at least one polygon. Counted before anything is expanded.
pub const max_flat_elements: u64 = 1 << 28;

/// The most ports a subcircuit kept whole as a black box may have: a
/// device's pins are told apart by a one-byte position.
pub const max_cell_pins: u32 = 256;

/// The deepest placement chain a reference may have, the top included, as
/// a layout's: flattening recurses once per level.
pub const max_hierarchy_depth: u32 = 1024;

/// Why a netlist was refused; `Diagnostic` carries the line and token.
pub const Error = error{
    /// A token that does not fit the card: a missing name, a malformed
    /// `name=value`, a positional token after a parameter, a subcircuit
    /// opened inside another or never closed.
    Unexpected,
    /// A construct outside the subset.
    Unsupported,
    /// An instance of a subcircuit the file never defines.
    UndefinedSubckt,
    /// A subcircuit, or a Spectre `model`, defined twice.
    Redefined,
    /// A device or instance with the wrong number of terminals: `got`, `want`.
    TerminalCount,
    /// A card with no model where the deck has no one recogniser of its
    /// kind; `has` says what the deck has.
    NoModel,
    /// A subcircuit that places itself; the token names it.
    CyclicHierarchy,
    /// A placement chain deeper than `max_hierarchy_depth`; the token names
    /// the subcircuit the chain passes the cap at.
    TooDeep,
    /// A top that flattens to more than `max_flat_elements`; `count`.
    TooLarge,
    /// A black box with more than `max_cell_pins` ports: token, `got`.
    TooManyPins,
    OutOfMemory,
};

/// Where and on what a read failed. Texts are copied in, truncated past
/// their buffers, so the diagnostic outlives the source.
pub const Diagnostic = struct {
    /// 1-based line; a continued card reports the line the token is on.
    line: u32 = 0,
    got: u32 = 0,
    want: u32 = 0,
    count: u64 = 0,
    token_len: u16 = 0,
    has_len: u16 = 0,
    token_buf: [240]u8 = undefined,
    has_buf: [240]u8 = undefined,

    /// The offending token, or the name an error names.
    pub fn token(d: *const Diagnostic) []const u8 {
        return d.token_buf[0..d.token_len];
    }

    /// `NoModel`'s account of what the deck has.
    pub fn has(d: *const Diagnostic) []const u8 {
        return d.has_buf[0..d.has_len];
    }

    /// Records `line` and the token text.
    pub fn set(d: *Diagnostic, line: u32, comptime fmt: []const u8, args: anytype) void {
        d.line = line;
        const out = std.fmt.bufPrint(&d.token_buf, fmt, args) catch d.token_buf[0..];
        d.token_len = @intCast(out.len);
    }

    pub fn setHas(d: *Diagnostic, comptime fmt: []const u8, args: anytype) void {
        const out = std.fmt.bufPrint(&d.has_buf, fmt, args) catch d.has_buf[0..];
        d.has_len = @intCast(out.len);
    }
};

/// A subcircuit definition: its position in file order.
pub const SubcktId = enum(u32) { _ };
/// A net: a row of `Netlist.net_name`, belonging to exactly one subcircuit.
pub const RefNetId = enum(u32) { _ };

/// A device parameter: interned name and value in SI base units.
pub const Param = struct { name: StrId, value: f64 };

/// One instance `flattenTop` expanded.
pub const Placement = struct {
    /// The instance path, `X1.X2`, interned.
    path: StrId,
    /// The placed subcircuit's name.
    cell: StrId,
    /// The flattened device rows `[first, end)` it holds, inner placements included.
    devices: [2]u32,
};

/// A parsed reference netlist, hierarchy preserved. Columns grouped into
/// tables share a row index; each `*_start` column is CSR, one longer than
/// its table. Every list is owned by the allocator `deinit` takes.
pub const Netlist = struct {
    /// One row per subcircuit definition, indexed by `SubcktId`.
    subckt_name: std.ArrayList(StrId) = .empty,
    subckt_port_start: std.ArrayList(u32) = .empty,
    /// Every subcircuit's port nets, in definition order.
    port_net: std.ArrayList(RefNetId) = .empty,
    /// Devices belonging to each subcircuit, CSR into the device columns.
    subckt_device_start: std.ArrayList(u32) = .empty,
    /// One row per device: its model, interned.
    device_model: std.ArrayList(StrId) = .empty,
    device_kind: std.ArrayList(DeviceKind) = .empty,
    /// The card's name as written (`MN1`), interned; a black box's, its
    /// instance name. Flattened, a device's full name is its innermost
    /// placement's path, a dot, then this (a black box: the path alone).
    device_name: std.ArrayList(StrId) = .empty,
    device_terminal_start: std.ArrayList(u32) = .empty,
    /// Terminal nets in the card's order, which is the role: MOS drain,
    /// gate, source, bulk; BJT collector, base, emitter[, substrate]; two-pin
    /// pin 0, pin 1. Not `DeviceRecognition`'s order (gate first).
    terminal_net: std.ArrayList(RefNetId) = .empty,
    device_param_start: std.ArrayList(u32) = .empty,
    /// SI base units, suffixes expanded; SPICE names lowercased.
    param: std.ArrayList(Param) = .empty,
    /// One row per subcircuit instance, in file order: the callee...
    instance_of: std.ArrayList(SubcktId) = .empty,
    /// ...the caller...
    instance_subckt: std.ArrayList(SubcktId) = .empty,
    /// ...and its name (`X1`), interned.
    instance_name: std.ArrayList(StrId) = .empty,
    /// The caller's nets on the callee's ports, CSR; empty with no instance.
    instance_net_start: std.ArrayList(u32) = .empty,
    instance_net: std.ArrayList(RefNetId) = .empty,
    /// One row per net: its name, interned, and its subcircuit.
    net_name: std.ArrayList(StrId) = .empty,
    net_subckt: std.ArrayList(SubcktId) = .empty,
    /// What `flattenTop` expanded, a placement before the ones inside it.
    placements: std.ArrayList(Placement) = .empty,
    /// Each subcircuit `flattenTopWith` kept whole, once, in first-placed
    /// order, and its port names in port order (CSR).
    black_box_cell: std.ArrayList(StrId) = .empty,
    black_box_port_start: std.ArrayList(u32) = .empty,
    black_box_port: std.ArrayList(StrId) = .empty,

    pub fn deinit(n: *Netlist, gpa: Allocator) void {
        inline for (.{ "subckt_name", "subckt_port_start", "port_net", "subckt_device_start", "device_model", "device_kind", "device_name", "device_terminal_start", "terminal_net", "device_param_start", "param", "instance_of", "instance_subckt", "instance_name", "instance_net_start", "instance_net", "net_name", "net_subckt", "placements", "black_box_cell", "black_box_port_start", "black_box_port" }) |f| @field(n, f).deinit(gpa);
    }

    pub fn subcktCount(n: *const Netlist) u32 {
        return @intCast(n.subckt_name.items.len);
    }

    /// The port nets of `cell`, in port order.
    pub fn portsOf(n: *const Netlist, cell: SubcktId) []const RefNetId {
        return run(RefNetId, n.port_net.items, n.subckt_port_start.items, @backingInt(cell));
    }

    /// The device rows a subcircuit holds directly, `[first, end)`.
    pub fn devicesOf(n: *const Netlist, cell: SubcktId) [2]u32 {
        const row = @backingInt(cell);
        return .{ n.subckt_device_start.items[row], n.subckt_device_start.items[row + 1] };
    }

    pub fn terminalsOf(n: *const Netlist, device: u32) []const RefNetId {
        return run(RefNetId, n.terminal_net.items, n.device_terminal_start.items, device);
    }

    pub fn paramsOf(n: *const Netlist, device: u32) []const Param {
        return run(Param, n.param.items, n.device_param_start.items, device);
    }

    /// The port names of black box `row`.
    pub fn blackBoxPorts(n: *const Netlist, row: u32) []const StrId {
        return run(StrId, n.black_box_port.items, n.black_box_port_start.items, row);
    }

    /// The one subcircuit nothing instantiates; null when not unique or
    /// none: LVS refuses, never guesses. A subcircuit named as a device
    /// card's model is that device's definition and never the top.
    pub fn top(n: *const Netlist, gpa: Allocator) Allocator.Error!?SubcktId {
        return n.topIn(gpa, 0, n.subcktCount());
    }

    /// The one subcircuit of rows `[first, end)` nothing instantiates, as
    /// `top` asks of all: a Verilog top level over a cell library.
    pub fn topIn(n: *const Netlist, gpa: Allocator, first: u32, end: u32) Allocator.Error!?SubcktId {
        const instantiated = try gpa.alloc(bool, n.subcktCount());
        defer gpa.free(instantiated);
        @memset(instantiated, false);
        for (n.instance_of.items) |callee| instantiated[@backingInt(callee)] = true;
        // A subcircuit named as a card's model is that device's definition,
        // called as a device rather than placed (catalog LVS-067).
        const models = try gpa.dupe(StrId, n.device_model.items);
        defer gpa.free(models);
        std.mem.sortUnstable(StrId, models, {}, lessId);
        for (n.subckt_name.items, instantiated) |name, *seen| {
            if (std.sort.binarySearch(StrId, models, name, orderId) != null) seen.* = true;
        }
        var found: ?SubcktId = null;
        for (first..end) |row| {
            if (instantiated[row]) continue;
            if (found != null) return null;
            found = @fromBackingInt(@as(u32, @intCast(row)));
        }
        return found;
    }
};

// ---- private ----

/// Row `row`'s run of `items` in the CSR column `start`.
fn run(comptime T: type, items: []const T, start: []const u32, row: usize) []const T {
    return items[start[row]..start[row + 1]];
}

fn lessId(_: void, a: StrId, b: StrId) bool {
    return @backingInt(a) < @backingInt(b);
}

fn orderId(want: StrId, item: StrId) std.math.Order {
    return std.math.order(@backingInt(want), @backingInt(item));
}
