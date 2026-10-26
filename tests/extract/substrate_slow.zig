//! The substrate solve's release-tier test, from
//! crates/extract/tests/pex/substrate.rs (`#[ignore]` there: a two-minute
//! solve). Runs under `-Dslow-tests`, on by default outside Debug.
//!
//! Contents: the test.

const std = @import("std");
const testing = std.testing;
const substrate_tests = @import("substrate.zig");

test "a square contact converges to a part in two thousand" {
    // Oracle: closed form (Read's square-plate capacitance and the slab's
    // image series) and mesh-refinement convergence, one level finer than
    // the merge-tier test: within 0.5 %, extrapolated within 0.05 %.
    var errors: [4]f64 = undefined;
    const extrapolated = try substrate_tests.errorsTo(3, &errors);
    try testing.expect(errors[3] < 0.005);
    try testing.expect(extrapolated < 0.0005);
}
