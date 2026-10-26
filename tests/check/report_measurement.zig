//! Which side of a limit is a violation, and what stops a NaN passing every
//! rule. Ported from crates/check/tests/report/measurement.rs.
//!
//! Not ported: `comparing_two_dimensions_is_a_programming_error_rather_than_an_answer`
//! caught Rust's panic; `violates` asserts one kind, which a Zig test cannot
//! observe, and a table row cannot hold two kinds at all (one `kind` column).

const std = @import("std");
const testing = std.testing;
const check = @import("check");
const Measurement = check.report.Measurement;

const Triple = struct { what: []const u8, below: Measurement, at: Measurement, above: Measurement };

/// One dimension's worth of ordered values: below the limit, at it, above
/// it. Every kind appears exactly once.
const ordered_triples = [_]Triple{
    .{ .what = "a spacing", .below = .length(90), .at = .length(100), .above = .length(110) },
    .{ .what = "a minimum area", .below = .area(9_000), .at = .area(10_000), .above = .area(11_000) },
    .{ .what = "an antenna ratio", .below = .ratio(49.5), .at = .ratio(50.0), .above = .ratio(50.5) },
    .{ .what = "a via count", .below = .count(1), .at = .count(2), .above = .count(3) },
    .{ .what = "a supply voltage", .below = .voltage(.{ .raw = 1_700 }), .at = .voltage(.{ .raw = 1_800 }), .above = .voltage(.{ .raw = 1_900 }) },
    .{ .what = "a branch current", .below = .current(.{ .raw = 90 }), .at = .current(.{ .raw = 100 }), .above = .current(.{ .raw = 110 }) },
    .{ .what = "a point-to-point resistance", .below = .resistance(.{ .raw = 9 }), .at = .resistance(.{ .raw = 10 }), .above = .resistance(.{ .raw = 11 }) },
};

comptime {
    // A new kind that forgets its row here is caught at compile time.
    std.debug.assert(ordered_triples.len == @typeInfo(check.report.Kind).@"enum".field_names.len);
}

test "minimum is violated below its limit and maximum above it" {
    // Oracle: closed form. `minimum` is violated below its limit and by
    // nothing else; `maximum` above it and by nothing else, for every kind.
    for (ordered_triples) |t| {
        try testing.expect(t.below.violates(t.at, .minimum));
        try testing.expect(!t.above.violates(t.at, .minimum));
        try testing.expect(t.above.violates(t.at, .maximum));
        try testing.expect(!t.below.violates(t.at, .maximum));
    }
}

test "a measurement exactly at its limit violates neither sense" {
    // Oracle: closed form. A shape exactly at its limit is legal under both
    // senses: the boundary an off-by-one comparison lands on.
    for (ordered_triples) |t| {
        try testing.expect(!t.at.violates(t.at, .minimum));
        try testing.expect(!t.at.violates(t.at, .maximum));
    }
}

test "exactly one sense fires on any two unequal measurements" {
    // Oracle: law. On two unequal values exactly one of the two senses calls
    // it a violation, whichever way round they sit.
    for (ordered_triples) |t| {
        for ([2][2]Measurement{ .{ t.below, t.above }, .{ t.above, t.below } }) |pair| {
            try testing.expect(pair[0].violates(pair[1], .minimum) != pair[0].violates(pair[1], .maximum));
        }
    }
}

test "isFinite rejects every non-finite value and accepts every exact one" {
    // Oracle: law. A NaN or infinite limit passes everything silently, so
    // `isFinite` rejects every non-finite f64 in every kind that holds one,
    // and accepts every exact value.
    const nan = std.math.nan(f64);
    const inf = std.math.inf(f64);
    const rejected = [_]Measurement{
        .ratio(nan),                .ratio(inf),                  .ratio(-inf),
        .voltage(.{ .raw = nan }),  .voltage(.{ .raw = inf }),    .current(.{ .raw = nan }),
        .current(.{ .raw = -inf }), .resistance(.{ .raw = nan }), .resistance(.{ .raw = inf }),
    };
    for (rejected) |m| try testing.expect(!m.isFinite());
    const accepted = [_]Measurement{
        .length(0),                  .length(-1),                    .area(0),
        .area(std.math.maxInt(u64)), .count(0),                      .count(std.math.maxInt(u32)),
        .ratio(0),                   .ratio(std.math.floatMax(f64)), .voltage(.{ .raw = -1_800 }),
        .current(.{ .raw = 0 }),     .resistance(.{ .raw = 1e12 }),
    };
    for (accepted) |m| try testing.expect(m.isFinite());
}
