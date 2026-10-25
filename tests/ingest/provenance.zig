//! Net labels: their ordering contract. Ported from
//! crates/ingest/tests/provenance.rs; its two binding tests
//! (`a_label_binds_to_its_split_flank...`, `label_binding_matches_a_brute_force_scan`)
//! need `resolve_labels` and a `GeometryStore`, and move with them in wave 2.

const std = @import("std");
const testing = std.testing;
const ingest = @import("ingest");
const geom = @import("geom");

test "labels come back ascending by polygon whatever order they were attached in" {
    // Oracle: law. `labels` is documented as ascending by `PolyId`, which is
    // what lets `topology` bind labels deterministically without sorting.
    // That ordering must be a property of the table rather than of the order
    // labels happened to be attached in, so they go on in scrambled order.
    const gpa = testing.allocator;
    var strings: geom.StrTable = .empty;
    defer strings.deinit(gpa);
    var provenance: ingest.Provenance = .{};
    defer provenance.deinit(gpa);
    var attached = [_]ingest.provenance.Label{
        .{ .poly = @fromBackingInt(5), .name = try strings.intern(gpa, "vdd") },
        .{ .poly = @fromBackingInt(1), .name = try strings.intern(gpa, "clk") },
        .{ .poly = @fromBackingInt(7), .name = try strings.intern(gpa, "vss") },
        .{ .poly = @fromBackingInt(2), .name = try strings.intern(gpa, "dout") },
    };
    for (attached) |l| try provenance.label(gpa, l.poly, l.name);
    std.mem.sortUnstable(ingest.provenance.Label, &attached, {}, struct {
        fn less(_: void, a: ingest.provenance.Label, b: ingest.provenance.Label) bool {
            return @backingInt(a.poly) < @backingInt(b.poly);
        }
    }.less);
    try testing.expectEqualSlices(ingest.provenance.Label, &attached, provenance.labels());
}
