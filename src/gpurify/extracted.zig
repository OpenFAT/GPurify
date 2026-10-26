//! The extract stage: a layout's store, deck and labels → `Extracted` (nets,
//! devices, ports), shared read-only by every check. Ported from
//! src/engine/pipeline.rs (`Extracted`, `extract`, `extract_layout`,
//! `ExtractError`).
//!
//! A MOS channel marker over live conductor would fuse source and drain
//! into one net and report the short as clean, so it is refused before nets
//! exist; devices read nets, and ports bind to them.
//!
//! Contents:
//! - `pub const Extracted = struct { nets, devices, ports }`
//! - `pub const Error`, `pub const Diagnostic`
//! - `pub fn extract(extract_arena: Allocator, loaded: *const Loaded, diag: *Diagnostic) Error!Extracted`
//! - `pub fn extractLayout(extract_arena: Allocator, store: *const GeometryStore, deck: *const Deck, provenance: *const Provenance, diag: *Diagnostic) Error!Extracted`

const std = @import("std");
const Allocator = std.mem.Allocator;
const geom = @import("geom");
const GeometryStore = geom.GeometryStore;
const ingest = @import("ingest");
const Deck = ingest.deck.Deck;
const Provenance = ingest.Provenance;
const topology = @import("check").topology;
const Loaded = @import("load.zig").Loaded;

/// Everything derived from what was loaded; every table lives in the extract arena.
pub const Extracted = struct {
    /// Nets traced through the deck's conductors and vias.
    nets: topology.NetTable = .{},
    /// Devices recognised from the deck's marker layers, terminals on `nets`.
    devices: topology.DeviceTable = .{},
    /// Net names from labels, bound as drawn: an open names every piece, a
    /// short carries every name.
    ports: topology.PortTable = .{},
};

/// `ConductingChannel`/`Geometry`: a channel marker over conductor, or a
/// layer that does not validate (`Diagnostic`). `OrphanLabel`: a label on a
/// shape on no net. A short between labelled nets is not an error here: LVS
/// reports it as `lvs.net_seed_conflict`.
pub const Error = topology.channel.ChannelError || topology.port.PortError || Allocator.Error;

pub const Diagnostic = topology.channel.ChannelDiagnostic;

/// `extractLayout` over a `Loaded`.
pub fn extract(extract_arena: Allocator, loaded: *const Loaded, diag: *Diagnostic) Error!Extracted {
    return extractLayout(extract_arena, &loaded.store, &loaded.deck.deck, &loaded.provenance, diag);
}

/// Channels refused, nets, devices, ports, in that order.
pub fn extractLayout(extract_arena: Allocator, store: *const GeometryStore, deck: *const Deck, provenance: *const Provenance, diag: *Diagnostic) Error!Extracted {
    var out: Extracted = .{};
    diag.* = .none;
    try topology.refuseConductingChannels(extract_arena, store, &deck.connectivity, &deck.devices, diag);
    try topology.extractNetsInto(extract_arena, store, &deck.connectivity, &out.nets);
    try topology.recogniseInto(extract_arena, store, &out.nets, &deck.devices, &out.devices);
    try topology.bindPortsInto(extract_arena, &out.nets, provenance.labels(), &out.ports);
    return out;
}
