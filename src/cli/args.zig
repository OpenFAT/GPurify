//! The command line → a `Cli`: what to run on which inputs, how to report
//! it, and on which backend. Ported from src/cli/args.rs.
//!
//! `gpurify <drc|erc|lvs|pex|all|lib> <layout> --deck <deck> [options]`,
//! `gpurify xor <layout> <other> --deck <deck>`,
//! `gpurify <fill|enhance> <layout> <output.gds> --deck <deck>`, or
//! `gpurify system <system.json> --reference <netlist>`. An option a
//! subcommand has no use for is refused, never dropped. Everything else
//! lives where it is already stated: the grid in the layout's `UNITS`, the
//! extra reports and temperature in the deck, `lib`'s accuracy in its spec;
//! a flag that moved there is refused with where it went. `--backend` and
//! `--threads` pick the `Device` (ARCHITECTURE.md, GPU: Selection).
//!
//! Contents:
//! - `pub const Format = enum { text, json, spef, dspf, spice }`, `pub const Edit = enum { fill, enhance }`
//! - `pub const Lib = struct { spec, output_dir, lef }`
//! - `pub const Command = union(enum) { check, xor, edit, lib, system }`
//! - `pub const Backend = enum { auto, cpu, cuda, hip }`
//! - `pub const Cli = struct`, `pub const Error = error{ Usage, OutOfMemory }`
//! - `pub fn parse(arena: Allocator, argv: []const []const u8, message: *[]const u8) Error!Cli`

const std = @import("std");
const Allocator = std.mem.Allocator;
const gpurify = @import("gpurify");
const testing = std.testing;

/// How to render the result.
pub const Format = enum { text, json, spef, dspf, spice };

/// A layout edit the deck configures, written to a new GDSII file.
pub const Edit = enum {
    /// Density fill on each `fill` line's layer (FLOW-007).
    fill,
    /// Redundant cuts and widened straps (FLOW-009).
    enhance,
};

/// What `lib` was asked for; the levels are the spec's `accuracy`.
pub const Lib = struct { spec: []const u8, output_dir: []const u8, lef: ?[]const u8 };

/// What the run does with its inputs.
pub const Command = union(enum) {
    /// `drc`, `erc`, `lvs`, `pex` or `all`: check `inputs.layout`.
    check,
    /// `xor`: compare `inputs.layout` with this layout instead of checking.
    xor: []const u8,
    /// `fill` or `enhance`: the edit and the GDSII file it writes; the
    /// report is DRC's on that file.
    edit: struct { edit: Edit, output: []const u8 },
    /// `lib`: a macro's Liberty files instead of a check.
    lib: Lib,
    /// `system`: the system description, its netlist `inputs.reference[0]`;
    /// `inputs.layout` and `inputs.deck` are empty.
    system: []const u8,
};

/// `--backend`: `auto` takes the first GPU backend that runs here, else the
/// CPU, and sends a kernel call to it only where the startup calibration
/// (gpurify/calibrate.zig) measured the GPU faster for its class; a named
/// GPU backend takes every kernel call.
pub const Backend = enum { auto, cpu, cuda, hip };

/// A parsed command line; every slice is `argv`'s or the arena's.
pub const Cli = struct {
    inputs: gpurify.Inputs,
    /// `device` is left `.cpu`: the caller builds it from `backend` and `threads`.
    options: gpurify.RunOptions,
    format: Format,
    command: Command,
    backend: Backend = .auto,
    /// Null: one per CPU.
    threads: ?u16 = null,
    /// `-o FILE`, `--format spice` only: each process corner's netlist goes
    /// to `FILE.<corner>`; the nominal one is on stdout either way.
    output: ?[]const u8 = null,
};

/// `Usage`: the command line is malformed; `message` says how.
pub const Error = error{ Usage, OutOfMemory };

/// The flags that take a value.
const Flag = enum { deck, intent, currents, reference, quasistatic, spec, @"output-dir", lef, format, backend, threads };

const Subcommand = enum { drc, erc, lvs, pex, all, lib, xor, fill, enhance, system };

/// What a subcommand checks, and which of the optional inputs it reads.
const Takes = struct { checks: gpurify.Checks, intent: bool = false, currents: bool = false, reference: bool = false, quasistatic: bool = false };

/// A flag the command line no longer takes, and what says it now.
const moved = std.StaticStringMap([]const u8).initComptime(.{
    .{ "--p2p", "the deck's `report p2p \"<net>\" at [(x, y), ..]` statement" },
    .{ "--coupling", "the deck's `report coupling \"<net>\" \"<net>\"` statement" },
    .{ "--cluster", "the deck's `report cluster <len>` statement" },
    .{ "--accuracy", "the macro spec's `accuracy` field" },
});

/// Parses `argv` (without the program name and never `compare` or `deck`,
/// which have their own command lines).
pub fn parse(arena: Allocator, argv: []const []const u8, message: *[]const u8) Error!Cli {
    if (argv.len == 0) return usage(arena, message, "expected a subcommand: drc, erc, lvs, pex, all, lib, xor, fill, enhance, system, compare or deck", .{});
    const word = argv[0];
    var layouts: std.ArrayList([]const u8) = .empty;
    var reference: std.ArrayList([]const u8) = .empty;
    var quasistatic: std.ArrayList([]const u8) = .empty;
    var lef: std.ArrayList([]const u8) = .empty;
    var deck: ?[]const u8 = null;
    var intent: ?[]const u8 = null;
    var currents: ?[]const u8 = null;
    var spec: ?[]const u8 = null;
    var output_dir: ?[]const u8 = null;
    var format: Format = .text;
    var backend: Backend = .auto;
    var threads: ?u16 = null;
    var output: ?[]const u8 = null;

    var i: usize = 1;
    while (i < argv.len) : (i += 1) {
        const token = argv[i];
        const flag = if (std.mem.startsWith(u8, token, "--")) std.meta.stringToEnum(Flag, token[2..]) else null;
        if (flag) |f| {
            // Every valued option names a path, a net or a number: none is empty.
            i += 1;
            if (i == argv.len) return usage(arena, message, "{s} wants a value", .{token});
            const value = argv[i];
            if (value.len == 0) return usage(arena, message, "{s} was given an empty value", .{token});
            switch (f) {
                .deck => deck = value,
                .intent => intent = value,
                .currents => currents = value,
                .reference => try reference.append(arena, value),
                .quasistatic => try quasistatic.append(arena, value),
                .spec => spec = value,
                .@"output-dir" => output_dir = value,
                .lef => try lef.append(arena, value),
                .format => format = std.meta.stringToEnum(Format, value) orelse
                    return usage(arena, message, "unknown --format {s}; expected text, json, spef, dspf or spice", .{value}),
                .backend => backend = std.meta.stringToEnum(Backend, value) orelse
                    return usage(arena, message, "unknown --backend {s}; expected auto, cpu, cuda or hip", .{value}),
                .threads => threads = blk: {
                    const n = std.fmt.parseInt(u16, value, 10) catch 0;
                    if (n == 0) return usage(arena, message, "--threads wants a count from 1 to 65535, got {s}", .{value});
                    break :blk n;
                },
            }
        } else if (std.mem.eql(u8, token, "-o")) {
            i += 1;
            if (i == argv.len or argv[i].len == 0) return usage(arena, message, "-o wants a file name", .{});
            output = argv[i];
        } else if (moved.get(token)) |to| {
            return usage(arena, message, "{s} is no longer an option: {s} says it now", .{ token, to });
        } else if (std.mem.startsWith(u8, token, "-")) {
            return usage(arena, message, "unknown option {s}", .{token});
        } else if (token.len == 0) {
            return usage(arena, message, "the layout file was given as an empty path", .{});
        } else try layouts.append(arena, token);
    }

    const sub = std.meta.stringToEnum(Subcommand, word) orelse
        return usage(arena, message, "unknown subcommand {s}; expected drc, erc, lvs, pex, all, lib, xor, fill, enhance, system, compare or deck", .{word});
    const takes: Takes = switch (sub) {
        // `xor` reports as the DRC stage; `fill` and `enhance` report DRC
        // on the layout they write.
        .drc, .xor, .fill, .enhance => .{ .checks = .{ .drc = true } },
        // ERC reads a reference only to place `--currents` through LVS.
        .erc => .{ .checks = .{ .erc = true }, .intent = true, .currents = true, .reference = true },
        .lvs => .{ .checks = .{ .lvs = true }, .reference = true },
        // `pex`'s reference names its netlist (PEX-017), through LVS.
        .pex => .{ .checks = .{ .pex = true }, .quasistatic = true, .reference = true },
        // `all` keeps LVS selected without a reference, so it reports Skipped.
        .all => .{ .checks = .all, .intent = true, .currents = true, .reference = true },
        // `lib` cross-checks a reference against its spec's pins; `system`'s
        // reference is the system netlist.
        .lib, .system => .{ .checks = .{}, .reference = true },
    };
    const edit: ?Edit = switch (sub) {
        .fill => .fill,
        .enhance => .enhance,
        .drc, .erc, .lvs, .pex, .all, .lib, .xor, .system => null,
    };
    const two = sub == .xor or edit != null;
    const n = layouts.items.len;
    if (!two and n > 1) return usage(arena, message, "one layout file, but a second was given: {s}", .{layouts.items[1]});
    if (two and n > 2) return usage(arena, message, "two layout files, but a third was given: {s}", .{layouts.items[2]});
    if (two and n < 2) {
        if (edit != null) return usage(arena, message, "{s} writes the edited layout to a new file: {s} <layout> <output.gds> --deck <deck>", .{ word, word });
        return usage(arena, message, "xor compares two layout files: xor <layout> <other> --deck <deck>", .{});
    }
    const is_lib = sub == .lib;
    if (!is_lib and spec != null) return usage(arena, message, "{s} takes no --spec", .{word});
    if (!is_lib and output_dir != null) return usage(arena, message, "{s} takes no --output-dir", .{word});
    // `lib` compares one macro LEF's pins; any other command reads a DEF
    // layout's LEFs, and only a DEF layout's.
    const def_layout = n > 0 and gpurify.isDef(layouts.items[0]);
    if (is_lib and (def_layout or lef.items.len > 1)) return usage(arena, message, "lib reads a GDS layout and at most one macro --lef", .{});
    if (edit != null and def_layout) return usage(arena, message, "{s} edits a GDS layout, not a DEF", .{word});
    if (!is_lib and lef.items.len > 0 and !def_layout) return usage(arena, message, "{s} takes --lef only with a DEF layout (*.def)", .{word});
    if (is_lib and format != .text) return usage(arena, message, "lib writes its files under --output-dir and takes no --format", .{});
    if (is_lib and spec == null) return usage(arena, message, "lib requires a macro spec (--spec)", .{});
    if (is_lib and output_dir == null) return usage(arena, message, "lib requires --output-dir", .{});
    if (intent != null and !takes.intent) return usage(arena, message, "{s} takes no --intent", .{word});
    if (reference.items.len > 0 and !takes.reference) return usage(arena, message, "{s} takes no --reference", .{word});
    if (currents != null and !takes.currents) return usage(arena, message, "{s} takes no --currents", .{word});
    if (currents != null and reference.items.len == 0) return usage(arena, message, "--currents needs the reference netlist (--reference): LVS is what places each simulated instance on a layout device", .{});
    if (sub == .erc and reference.items.len > 0 and currents == null) return usage(arena, message, "erc takes --reference only with --currents, which LVS places through it", .{});
    if (quasistatic.items.len > 0 and !takes.quasistatic) return usage(arena, message, "{s} takes no --quasistatic", .{word});
    if (sub == .lvs and reference.items.len == 0) return usage(arena, message, "lvs requires a reference netlist (--reference)", .{});
    // A check with no parasitic network would write an empty file that reads as clean.
    if ((format == .spef or format == .dspf or format == .spice) and !takes.checks.pex) return usage(arena, message, "--format {t} is not something this check produces", .{format});
    if (output != null and format != .spice) return usage(arena, message, "-o names where --format spice writes each corner's netlist, and the format is {t}", .{format});
    // A netlist in the reference's terms needs the pairing LVS makes.
    var checks = takes.checks;
    if ((format == .spice or format == .dspf) and reference.items.len > 0) checks.lvs = true;

    var cli: Cli = .{
        .inputs = .{ .layout = "", .deck = "", .reference = reference.items, .intent = intent, .currents = currents },
        .options = .{ .checks = checks, .quasistatic_nets = quasistatic.items },
        .format = format,
        .command = .check,
        .backend = backend,
        .threads = threads,
        .output = output,
    };
    if (sub == .system) {
        if (deck != null) return usage(arena, message, "system takes no --deck: each die names its deck in the system file", .{});
        if (n == 0) return usage(arena, message, "system needs a system description: system <system.json> --reference <netlist>", .{});
        if (reference.items.len != 1) return usage(arena, message, "system requires one system netlist (--reference)", .{});
        cli.command = .{ .system = layouts.items[0] };
        return cli;
    }
    if (n == 0) return usage(arena, message, "{s} needs a layout file: {s} <layout> --deck <deck>", .{ word, word });
    cli.inputs.layout = layouts.items[0];
    cli.inputs.deck = deck orelse return usage(arena, message, "--deck <deck> is required", .{});
    if (!is_lib) cli.inputs.lef = lef.items;
    cli.command = if (is_lib)
        .{ .lib = .{ .spec = spec.?, .output_dir = output_dir.?, .lef = if (lef.items.len > 0) lef.items[0] else null } }
    else if (edit) |e|
        .{ .edit = .{ .edit = e, .output = layouts.items[1] } }
    else if (sub == .xor)
        .{ .xor = layouts.items[1] }
    else
        .check;
    return cli;
}

// ---- private ----

fn usage(arena: Allocator, message: *[]const u8, comptime fmt: []const u8, args: anytype) Error {
    message.* = try std.fmt.allocPrint(arena, fmt, args);
    return error.Usage;
}

fn parseLine(arena: Allocator, line: []const u8) Error!Cli {
    var argv: std.ArrayList([]const u8) = .empty;
    var words = std.mem.tokenizeScalar(u8, line, ' ');
    while (words.next()) |w| try argv.append(arena, w);
    var message: []const u8 = "";
    return parse(arena, argv.items, &message);
}

fn refusal(arena: Allocator, line: []const u8) ![]const u8 {
    var argv: std.ArrayList([]const u8) = .empty;
    var words = std.mem.tokenizeScalar(u8, line, ' ');
    while (words.next()) |w| try argv.append(arena, w);
    var message: []const u8 = "";
    if (parse(arena, argv.items, &message)) |_| return error.TestUnexpectedResult else |err| try std.testing.expectEqual(error.Usage, err);
    return message;
}

test "a full command line reaches every field" {
    // Oracle: construct-from-answer, against docs/usage.md: every value reads
    // back as given, --quasistatic repeats in order, and `all` selects all four checks.
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const cli = try parseLine(a, "pex top.gds --deck d.deck --format spef --quasistatic vdd --quasistatic clk");
    try testing.expectEqualStrings("top.gds", cli.inputs.layout);
    try testing.expectEqualStrings("d.deck", cli.inputs.deck);
    try testing.expectEqual(Format.spef, cli.format);
    try testing.expectEqual(2, cli.options.quasistatic_nets.len);
    try testing.expectEqualStrings("vdd", cli.options.quasistatic_nets[0]);
    try testing.expectEqualStrings("clk", cli.options.quasistatic_nets[1]);
    const all = try parseLine(a, "all t --deck d --reference r --intent i");
    try testing.expectEqual(gpurify.Checks.all, all.options.checks);
    try testing.expect(all.inputs.reference.len == 1 and all.inputs.intent != null);
    // docs/usage.md: a Verilog top is given beside its cell library.
    const two = try parseLine(a, "lvs t --deck d --reference cells.spice --reference top.v");
    try testing.expectEqualStrings("cells.spice", two.inputs.reference[0]);
    try testing.expectEqualStrings("top.v", two.inputs.reference[1]);
}

test "a simulator netlist with a reference also runs LVS for its names" {
    // Oracle: docs/usage.md (Parasitics, PEX-017): `pex --reference
    // --format spice` names the netlist through LVS's pairing; `-o` sends
    // the corners to files; DSPF's instance section takes the same names.
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const cli = try parseLine(a, "pex ota.gds --deck sky130 --reference ota.spice --format spice -o ota.pex.spice");
    try testing.expectEqual(Format.spice, cli.format);
    try testing.expectEqual(gpurify.Checks{ .lvs = true, .pex = true }, cli.options.checks);
    try testing.expectEqualStrings("ota.pex.spice", cli.output.?);
    try testing.expectEqual(gpurify.Checks{ .lvs = true, .pex = true }, (try parseLine(a, "pex t --deck d --reference r --format dspf")).options.checks);
    // Without a reference there is nothing to pair, and SPEF needs no names.
    try testing.expectEqual(gpurify.Checks{ .pex = true }, (try parseLine(a, "pex t --deck d --format spice")).options.checks);
    try testing.expectEqual(gpurify.Checks{ .pex = true }, (try parseLine(a, "pex t --deck d --reference r --format spef")).options.checks);
}

test "lib takes its spec, directory and macro lef and runs no check" {
    // Oracle: docs/liberty.md: `lib` reads its spec, directory and macro LEF;
    // docs/usage.md: `lib` runs no check.
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const cli = try parseLine(arena.allocator(), "lib t --deck d --spec s.json --output-dir o --lef m.lef");
    try testing.expectEqualStrings("s.json", cli.command.lib.spec);
    try testing.expectEqualStrings("o", cli.command.lib.output_dir);
    try testing.expectEqualStrings("m.lef", cli.command.lib.lef.?);
    try testing.expectEqual(gpurify.Checks{}, cli.options.checks);
    try testing.expectEqual(0, cli.inputs.lef.len);
}

test "system takes its description and netlist" {
    // Oracle: docs/usage.md ("Multi-die systems"): the description is the one
    // positional file, the system netlist `--reference`, and no single-die check runs.
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const cli = try parseLine(arena.allocator(), "system stack.json --reference sys.spice --format json");
    try testing.expectEqualStrings("stack.json", cli.command.system);
    try testing.expectEqualStrings("sys.spice", cli.inputs.reference[0]);
    try testing.expectEqual(Format.json, cli.format);
    try testing.expectEqual(gpurify.Checks{}, cli.options.checks);
}

test "xor takes its two layouts in order, and no other check has a second" {
    // Oracle: construct-from-answer, against docs/usage.md.
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const cli = try parseLine(a, "xor a.gds b.gds --deck d --format json");
    try testing.expectEqualStrings("a.gds", cli.inputs.layout);
    try testing.expectEqualStrings("b.gds", cli.command.xor);
    try testing.expectEqual(Format.json, cli.format);
    try testing.expectEqual(Command.check, (try parseLine(a, "drc a.gds --deck d")).command);
}

test "a def layout takes its lefs in order" {
    // Oracle: construct-from-answer, against docs/usage.md.
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const cli = try parseLine(arena.allocator(), "pex top.def --deck d --lef tech.lef --lef cells.lef");
    try testing.expectEqualStrings("tech.lef", cli.inputs.lef[0]);
    try testing.expectEqualStrings("cells.lef", cli.inputs.lef[1]);
}

test "the defaults are text, auto and one thread per cpu" {
    // Oracle: docs/usage.md: --format defaults to text; ARCHITECTURE.md (GPU:
    // Selection): --backend defaults to auto, --threads to the CPU count (null here).
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const cli = try parseLine(a, "drc t --deck d");
    try testing.expectEqual(Format.text, cli.format);
    try testing.expectEqual(Backend.auto, cli.backend);
    try testing.expectEqual(null, cli.threads);
    const picked = try parseLine(a, "drc t --deck d --backend cuda --threads 8");
    try testing.expectEqual(Backend.cuda, picked.backend);
    try testing.expectEqual(8, picked.threads.?);
}

test "an edit writes its second file and reports drc" {
    // Oracle: construct-from-answer, against docs/usage.md: `fill` and
    // `enhance` take the layout and the file to write, report DRC, and take no
    // option of their own; without the output, or on a DEF, they are refused.
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    for ([_][]const u8{ "fill", "enhance" }, [_]Edit{ .fill, .enhance }) |word, edit| {
        const cli = try parseLine(a, try std.fmt.allocPrint(a, "{s} a.gds b.gds --deck d --format json", .{word}));
        try testing.expectEqual(edit, cli.command.edit.edit);
        try testing.expectEqualStrings("b.gds", cli.command.edit.output);
        try testing.expectEqual(gpurify.Checks{ .drc = true }, cli.options.checks);
        try testing.expectEqual(Format.json, cli.format);
        inline for (.{ "{s} a.gds --deck d", "{s} a.def b.gds --deck d", "{s} a.gds b.gds --deck d --quasistatic n" }) |bad| {
            _ = try refusal(a, try std.fmt.allocPrint(a, bad, .{word}));
        }
    }
}

test "every malformed command line is refused with its message" {
    // Oracle: the command line docs/usage.md documents (Rust's args.rs table,
    // plus --backend and --threads from ARCHITECTURE.md): each line breaks one
    // rule, and the message names that rule.
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const cases = [_][2][]const u8{
        .{ "", "expected a subcommand: drc, erc, lvs, pex, all, lib, xor, fill, enhance, system, compare or deck" },
        .{ "dcr t --deck d", "unknown subcommand dcr; expected drc, erc, lvs, pex, all, lib, xor, fill, enhance, system, compare or deck" },
        .{ "system s.json --deck d --reference r", "system takes no --deck: each die names its deck in the system file" },
        .{ "system --reference r", "system needs a system description: system <system.json> --reference <netlist>" },
        .{ "system s.json", "system requires one system netlist (--reference)" },
        .{ "system s.json --reference a --reference b", "system requires one system netlist (--reference)" },
        .{ "system s.json --reference r --intent i", "system takes no --intent" },
        .{ "system s.json --reference r --format spef", "--format spef is not something this check produces" },
        .{ "xor t --deck d", "xor compares two layout files: xor <layout> <other> --deck <deck>" },
        .{ "xor t u v --deck d", "two layout files, but a third was given: v" },
        .{ "xor t u --deck d --intent i", "xor takes no --intent" },
        .{ "xor t u --deck d --quasistatic n", "xor takes no --quasistatic" },
        .{ "xor t u --deck d --format spef", "--format spef is not something this check produces" },
        .{ "pex t --deck d --temperature 85", "unknown option --temperature" },
        .{ "lib t --deck d --output-dir o", "lib requires a macro spec (--spec)" },
        .{ "lib t --deck d --spec s", "lib requires --output-dir" },
        .{ "drc t --deck d --spec s", "drc takes no --spec" },
        .{ "drc t.gds --deck d --lef t.lef", "drc takes --lef only with a DEF layout (*.def)" },
        .{ "lib t.def --deck d --spec s --output-dir o", "lib reads a GDS layout and at most one macro --lef" },
        .{ "lib t --deck d --spec s --output-dir o --lef a --lef b", "lib reads a GDS layout and at most one macro --lef" },
        .{ "lib t --deck d --spec s --output-dir o --accuracy 2", "--accuracy is no longer an option: the macro spec's `accuracy` field says it now" },
        .{ "pex t --deck d --p2p VDD:1,2:3,4", "--p2p is no longer an option: the deck's `report p2p \"<net>\" at [(x, y), ..]` statement says it now" },
        .{ "pex t --deck d --coupling a:b", "--coupling is no longer an option: the deck's `report coupling \"<net>\" \"<net>\"` statement says it now" },
        .{ "drc t --deck d --cluster 2.5um", "--cluster is no longer an option: the deck's `report cluster <len>` statement says it now" },
        .{ "drc --deck d", "drc needs a layout file: drc <layout> --deck <deck>" },
        .{ "drc t", "--deck <deck> is required" },
        .{ "drc t u --deck d", "one layout file, but a second was given: u" },
        .{ "drc t --deck", "--deck wants a value" },
        .{ "drc t --deck d --nonsense", "unknown option --nonsense" },
        .{ "drc t --deck d --format gds", "unknown --format gds; expected text, json, spef, dspf or spice" },
        .{ "lvs t --deck d --reference r --format spice", "--format spice is not something this check produces" },
        .{ "pex t --deck d --format spef -o x", "-o names where --format spice writes each corner's netlist, and the format is spef" },
        .{ "pex t --deck d --format spice -o", "-o wants a file name" },
        .{ "drc t --deck d --grid 1000", "unknown option --grid" },
        .{ "drc t --deck d --no-strict-layers", "unknown option --no-strict-layers" },
        .{ "drc t --deck d --output o", "unknown option --output" },
        .{ "drc t --deck d --check-determinism", "unknown option --check-determinism" },
        .{ "lib t --deck d --spec s --output-dir o --work w", "unknown option --work" },
        .{ "drc t --deck d --intent i", "drc takes no --intent" },
        .{ "erc t --deck d --reference r", "erc takes --reference only with --currents, which LVS places through it" },
        .{ "erc t --deck d --currents c", "--currents needs the reference netlist (--reference): LVS is what places each simulated instance on a layout device" },
        .{ "lvs t --deck d --reference r --currents c", "lvs takes no --currents" },
        .{ "all t --deck d --quasistatic n", "all takes no --quasistatic" },
        .{ "pex t --deck d --quasistatic-inductance", "unknown option --quasistatic-inductance" },
        .{ "lib t --deck d --spec s --output-dir o --format json", "lib writes its files under --output-dir and takes no --format" },
        .{ "lvs t --deck d", "lvs requires a reference netlist (--reference)" },
        .{ "drc t --deck d --format dspf", "--format dspf is not something this check produces" },
        .{ "drc t --deck d --backend metal", "unknown --backend metal; expected auto, cpu, cuda or hip" },
        .{ "drc t --deck d --threads 0", "--threads wants a count from 1 to 65535, got 0" },
        .{ "drc t --deck d --threads many", "--threads wants a count from 1 to 65535, got many" },
    };
    for (cases) |c| testing.expectEqualStrings(c[1], try refusal(a, c[0])) catch |err| {
        std.debug.print("command line: {s}\n", .{c[0]});
        return err;
    };
}

test "erc reads a current file with its reference" {
    // Oracle: construct-from-answer, against docs/usage.md's `--currents`
    // command line (catalog ERC-E14): both paths read back as given.
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const cli = try parseLine(arena.allocator(), "erc top.gds --deck d --reference top.spice --intent i.json --currents hot.emir.json");
    try testing.expectEqualStrings("hot.emir.json", cli.inputs.currents.?);
    try testing.expectEqualStrings("top.spice", cli.inputs.reference[0]);
    try testing.expect(cli.options.checks.erc and !cli.options.checks.lvs);
}

test "an empty value is refused" {
    // Oracle: args.rs: every valued option names a path, a net or a number,
    // so none is empty.
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    var message: []const u8 = "";
    try testing.expectError(error.Usage, parse(arena.allocator(), &.{ "drc", "t", "--deck", "" }, &message));
    try testing.expectEqualStrings("--deck was given an empty value", message);
    try testing.expectError(error.Usage, parse(arena.allocator(), &.{ "drc", "", "--deck", "d" }, &message));
    try testing.expectEqualStrings("the layout file was given as an empty path", message);
}
