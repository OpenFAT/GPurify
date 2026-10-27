//! The decks GPurify ships, as text compiled into the binary (`pdks/*.deck`,
//! reached through build.zig's anonymous imports), each compiled on a
//! layout's grid by name. Ported from src/pdks.rs.
//!
//! Every deck is authored on its own `grid` (5 nm, or 1 nm for asap7) and
//! compiles on any layout grid that grid divides.
//!
//! Contents:
//! - `pub const sky130`, `gf180mcu`, `ihp_sg13g2`, `asap7: []const u8`
//! - `pub const all: [4]NamedText` (sorted by stem)
//! - `pub const decks: [5]NamedDeck` (each text compiled on the layout grid;
//!   `generic_finfet` is asap7's old name)

const std = @import("std");
const Allocator = std.mem.Allocator;
const geom = @import("geom");
const compile = @import("check").deck.compile;
const NamedDeck = @import("load.zig").NamedDeck;

/// SkyWater SKY130 (`sky130A`, five-metal aluminium back end).
pub const sky130: []const u8 = @embedFile("sky130.deck");
/// GlobalFoundries GF180MCU (1P6M, MIM option B).
pub const gf180mcu: []const u8 = @embedFile("gf180mcu.deck");
/// IHP SG13G2 (130 nm SiGe BiCMOS, five thin and two thick metals).
pub const ihp_sg13g2: []const u8 = @embedFile("ihp_sg13g2.deck");
/// ASAP7, the predictive 7 nm FinFET PDK (release 1p7). No fab builds it.
pub const asap7: []const u8 = @embedFile("asap7.deck");

pub const NamedText = struct { name: []const u8, text: []const u8 };

/// Every shipped deck with its file stem, sorted by stem.
pub const all = [4]NamedText{
    .{ .name = "asap7", .text = asap7 },
    .{ .name = "gf180mcu", .text = gf180mcu },
    .{ .name = "ihp_sg13g2", .text = ihp_sg13g2 },
    .{ .name = "sky130", .text = sky130 },
};

/// `all`, each compiled on the layout grid when `Inputs.deck` names it, in
/// `all`'s order, then asap7 under its old name.
pub const decks = [5]NamedDeck{
    .{ .name = "asap7", .build = Build(asap7).build },
    .{ .name = "gf180mcu", .build = Build(gf180mcu).build },
    .{ .name = "ihp_sg13g2", .build = Build(ihp_sg13g2).build },
    .{ .name = "sky130", .build = Build(sky130).build },
    .{ .name = "generic_finfet", .build = Build(asap7).build },
};

// ---- private ----

fn Build(comptime text: []const u8) type {
    return struct {
        fn build(gpa: Allocator, arena: Allocator, grid: geom.Grid, strings: *geom.StrTable, diag: *compile.Diag) compile.Error!compile.CompiledDeck {
            return compile.compile(gpa, arena, text, grid, strings, diag);
        }
    };
}
