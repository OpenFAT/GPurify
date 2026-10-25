//! Whole-text globs: a pattern and a text → whether the pattern matches all of
//! it. `*` matches any run, `?` one character (one UTF-8 code point), and
//! every other character itself, case included. The deck's text patterns
//! (`with_text`, `lvs connect_implicit`) and cell names (`in_cells`, `lvs
//! blackbox`) match so. KLayout's glob also reads `[…]`, `{a,b}` and `\`
//! (docs/klayout-mirror.md, Q3); a cell-name pattern holding one is refused by
//! the deck parser, so the two read every accepted pattern alike.
//!
//! Contents:
//! - `pub fn globMatches(pattern: []const u8, text: []const u8) bool`

const std = @import("std");

/// Whether `pattern` matches the whole of `text`. Linear backtracking on the
/// last `*`, so O(|pattern|·|text|) at worst and no allocation.
pub fn globMatches(pattern: []const u8, text: []const u8) bool {
    var p: usize = 0;
    var t: usize = 0;
    // The last `*` and the text offset it was tried at, to widen on a miss.
    var star: ?struct { at: usize, from: usize } = null;
    while (t < text.len) {
        const t_len = charLen(text, t);
        if (p < pattern.len and pattern[p] == '*') {
            star = .{ .at = p, .from = t };
            p += 1;
            continue;
        }
        if (p < pattern.len) {
            const p_len = charLen(pattern, p);
            if ((p_len == 1 and pattern[p] == '?') or
                std.mem.eql(u8, pattern[p..][0..p_len], text[t..][0..t_len]))
            {
                p += p_len;
                t += t_len;
                continue;
            }
        }
        const s = star orelse return false;
        const next = s.from + charLen(text, s.from);
        p = s.at + 1;
        t = next;
        star = .{ .at = s.at, .from = next };
    }
    for (pattern[p..]) |c| if (c != '*') return false;
    return true;
}

// ---- private ----

/// The byte length of the code point at `at`; an invalid lead byte is one.
fn charLen(bytes: []const u8, at: usize) usize {
    const len = std.unicode.utf8ByteSequenceLength(bytes[at]) catch return 1;
    return if (at + len <= bytes.len) len else 1;
}

test "a glob matches the whole text" {
    // Oracle: the glob `docs/deck.md` documents for `with_text`: `*` any run,
    // `?` one character, every other character itself, case included, over the
    // whole text; each pair is decided by hand (`[V]DD` is literal).
    const yes = [_][2][]const u8{
        .{ "VDD", "VDD" },   .{ "VDD*", "VDD" }, .{ "VDD*", "VDDIO" },
        .{ "*IO", "VDDIO" }, .{ "V?D", "VDD" },  .{ "a*b*c", "axxbyyc" },
        .{ "*", "" },
        .{ "?", "é" },
    };
    for (yes) |c| try std.testing.expect(globMatches(c[0], c[1]));
    const no = [_][2][]const u8{
        .{ "VDD", "VDDIO" },  .{ "VDD", "vdd" },      .{ "V?D", "VD" },
        .{ "*IO", "VDDIOX" }, .{ "a*b*c", "axxbyy" }, .{ "[V]DD", "VDD" },
        .{ "??", "é" },
    };
    for (no) |c| try std.testing.expect(!globMatches(c[0], c[1]));
}
