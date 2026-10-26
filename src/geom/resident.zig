//! The run-lifetime device copy of the store columns the integer row kernels
//! read: `poly_vert_start`, `poly_vert_len`, `verts_x`, `verts_y`. In: a
//! `GeometryStore`, on the first kernel call that goes to the GPU. Out: one
//! device buffer (one geom.bulk upload) and each column's device address,
//! reused by every later call, so a call moves only its own pair list and
//! results (ARCHITECTURE.md, GPU).
//!
//! The caller owns it: the run spine makes an `empty` one, passes it down
//! next to `Device`, and frees it when the checks end. Nothing is uploaded
//! until a call needs it, so an all-CPU run uploads nothing. A kernel call
//! given none uploads into a temporary of its own (immediate mode).
//!
//! Invariant: the copy mirrors the store as it was at upload. The store is
//! append-only and load derives every layer before the checks start, which
//! never append, so the store's row and vertex counts equal the copy's at
//! every use; `columns` asserts it.
//!
//! Contents:
//! - `pub const ResidentStore = struct`, `ResidentStore.empty`, `deinit`,
//!   `columns(r: *ResidentStore, comptime backend: Device.Backend, raw: anytype, gpa: Allocator, store: *const GeometryStore) !*const [4]usize`

const std = @import("std");
const assert = std.debug.assert;
const Allocator = std.mem.Allocator;
const g = @import("gompute");
const Device = @import("device.zig").Device;
const GeometryStore = @import("store.zig").GeometryStore;
const bulk = @import("bulk.zig");

pub const ResidentStore = struct {
    /// The one device buffer, by backend; `.cpu` while nothing is uploaded.
    buffer: union(Device.Backend) {
        cpu,
        cuda: g.runtime.cuda.Buffer,
        hip: g.runtime.hip.Buffer,
    } = .cpu,
    /// Device addresses of `poly_vert_start`, `poly_vert_len`, `verts_x`,
    /// `verts_y`; kernel arguments point here.
    address: [4]usize = @splat(0),
    /// The store's row and vertex counts at upload.
    polys: u32 = 0,
    verts: usize = 0,

    /// Nothing uploaded.
    pub const empty: ResidentStore = .{};

    pub fn deinit(r: *ResidentStore) void {
        switch (r.buffer) {
            .cpu => {},
            inline .cuda, .hip => |*b| b.free(),
        }
        r.* = .empty;
    }

    /// The columns' device addresses on `backend`, uploading them through
    /// `raw` (a `g.RawKernel` handle of that backend; `gpa` holds the
    /// staging block during the upload only) on the first call. Asserts
    /// `store` is the one uploaded, unchanged.
    pub fn columns(r: *ResidentStore, comptime backend: Device.Backend, raw: anytype, gpa: Allocator, store: *const GeometryStore) !*const [4]usize {
        if (r.buffer == .cpu) {
            const bytes = std.mem.sliceAsBytes;
            const cols = [_][]const u8{ bytes(store.poly_vert_start.items), bytes(store.poly_vert_len.items), bytes(store.verts_x.items), bytes(store.verts_y.items) };
            var offsets: [4]usize = undefined;
            const buffer = try bulk.upload(@TypeOf(raw.*), raw, gpa, &cols, &.{}, &offsets, &r.address);
            r.buffer = @unionInit(@TypeOf(r.buffer), @tagName(backend), buffer);
            r.polys = store.polyCount();
            r.verts = store.verts_x.items.len;
        }
        assert(r.buffer == backend);
        assert(r.polys == store.polyCount() and r.verts == store.verts_x.items.len);
        return &r.address;
    }
};
