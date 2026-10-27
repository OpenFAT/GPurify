//! check: everything that reads a design and reports on it. Only re-exports;
//! check's Gompute kernel root.
//!
//! Files import only files above them in this order (a test in
//! tests/check.zig greps for back edges): report → rects → proximity →
//! topology/ → drc/ → erc/ → lvs/ → deck/.
//!
//! # Rule reference
//!
//! Every rule kind a deck can name, the Zig item that checks it, and the
//! check catalog (tests/check-catalog.tsv) rows it covers. The catalog lists
//! every check a signoff verifier is expected to handle, with the foundry
//! manual, standard or tool that defines each one. The user docs
//! (docs/src/reference) describe each row, what is missing from a partial
//! one, and the deck language itself.
//!
//! ## Design rules
//!
//! Each row of a deck's DRC section becomes one `drc.Rule` in a
//! `drc.RuleSet`. `L` is a layer or layer expression, `E` and `F` edge layers.
//!
//! | Deck | Kind | Checked by | Flags | Catalog |
//! |---|---|---|---|---|
//! | `width(L) >= len` | `min_width` | `drc.Rule.min_width` | a shape narrower than the limit anywhere | DRC-010, DRC-037, DRC-038, DRC-073, DRC-090, DRC-095, DRC-096, DRC-116, ERC-C11 |
//! | `width(L) <= len` | `max_width` | `drc.Rule.max_width` | a part of a shape wider than the limit in every direction | DRC-012 |
//! | `size(L) == w x h` | `cut_size` | `drc.Rule.cut_size` | a cut that is not exactly that rectangle | DRC-013, DRC-014 |
//! | `edge_length(L) >= len` | `min_edge_length` | `drc.Rule.min_edge_length` | an edge shorter than the limit | DRC-020, DRC-038, DRC-116 |
//! | `notch(L) >= len` | `notch` | `drc.Rule.notch` | a gap inside one shape narrower than the limit | DRC-024, DRC-038, DRC-116 |
//! | `space(L) >= len` | `min_spacing` | `drc.Rule.min_spacing` | two shapes on one layer closer than the limit | DRC-023, DRC-037, DRC-038, DRC-060, DRC-064, DRC-116 |
//! | `space(A, B) >= len` | `min_spacing_diff` | `drc.Rule.min_spacing_diff` | a shape on A closer than the limit to one on B | DRC-038, DRC-047, DRC-064, DRC-065, DRC-073, DRC-090, DRC-116, ERC-C11 |
//! | `space(A, B, projection) >= len` | `projection_spacing` | `drc.Rule.projection_spacing` | facing edges of A and B too close | DRC-055 |
//! | `eol_space(L; eol_width: len) >= len` | `eol_spacing` | `drc.Rule.eol_spacing` | too little space at an end of line | DRC-029, DRC-031 |
//! | `prl_space(L; prl: len) >= len` | `prl_spacing` | `drc.Rule.prl_spacing` | shapes running side by side for `prl`, too close | DRC-026, DRC-064 |
//! | `corner_space(L) >= len` | `corner_to_corner` | `drc.Rule.corner_to_corner` | two shapes whose corners are too close | DRC-032 |
//! | `wide_space(L; width: len) >= len` | `wide_dependent_spacing` | `drc.Rule.wide_dependent_spacing` | too little space from the wide part of a shape | DRC-025 |
//! | `wide_space(L; width: len, attached: len) >= len` | `attached_wide_spacing` | `drc.Rule.attached_wide_spacing` | the same, also from what is attached to the wide part | DRC-028 |
//! | `space(L[, L2]; nets: same \| different) >= len` | `net_spacing` | `drc.Rule.net_spacing` | same-net or different-net shapes too close, on one layer or two | DRC-080, DRC-081 |
//! | `space_table(L; prl: [..], width: [..], space: [[..]])` | `spacing_table` | `drc.Rule.spacing_table` | two shapes closer than their table cell | DRC-025, DRC-026, DRC-027 |
//! | `area(L) >= area` | `min_area` | `drc.Rule.min_area` | a shape smaller than the limit | DRC-017, DRC-116, ERC-A9 |
//! | `hole_area(L) >= area` | `min_enclosed_area` | `drc.Rule.min_enclosed_area` | a hole smaller than the limit | DRC-019, DRC-116 |
//! | `cheesing(L) <= area` | `cheesing` | `drc.Rule.cheesing` | a shape larger than the limit with no slot | DRC-075, ERC-E12 |
//! | `density(L[, boundary]; window: len, step: len) >= frac` | `density` | `drc.Rule.density` | a window with coverage outside the limit | DRC-071 |
//! | `global_density(L[, boundary]) >= frac` | `global_density` | `drc.Rule.global_density` | coverage of the whole die outside the limit | DRC-070 |
//! | `critical_area(L; radius: len) <= area` | `critical_area` | `drc.Rule.critical_area` | too much short-circuit critical area for one defect size | DRC-112 |
//! | `density_balance(A, B[, boundary]; window: len, step: len) >= frac` | `density_balance` | `drc.Rule.density_balance` | a window where two masks' coverage is out of balance | DRC-104 |
//! | `enclosure(inner, outer[; width: len, below: len]) >= len` | `min_enclosure` | `drc.Rule.min_enclosure` | an inner shape not surrounded by the limit on every side | DRC-040, DRC-043, DRC-090, DRC-096, DRC-116 |
//! | `enclosure(inner, outer, opposite[; width: len, below: len]) >= len` | `asymmetric_enclosure` | `drc.Rule.asymmetric_enclosure` | an inner shape without the limit on two opposite sides | DRC-041, DRC-042, DRC-043 |
//! | `enclosure(inner, outer, adjacent) >= len` | `adjacent_enclosure` | `drc.Rule.adjacent_enclosure` | an inner shape with a corner where neither edge meeting it has the limit | DRC-042 |
//! | `enclosure(inner, outer, noncoincident) >= len` | `noncoincident_enclosure` | `drc.Rule.noncoincident_enclosure` | an inner shape too close to outer's edge where their edges do not coincide | DRC-054, DRC-116 |
//! | `full_width(inner, outer)` | `full_width` | `drc.Rule.full_width` | an inner shape not spanning its host along either axis | DRC-053 |
//! | `enclosure(inner, outer) <= len` | `max_enclosure` | `drc.Rule.max_enclosure` | an outer shape reaching too far past what it holds | DRC-044 |
//! | `extension(A, B) >= len` | `min_extension` | `drc.Rule.min_extension` | A not extending past B by the limit | DRC-045 |
//! | `bend(A, B)`, `covers_corner(A, B)` | `gate_corner` | `drc.Rule.gate_corner` | A turning on B, or A over an inner corner of B | DRC-052 |
//! | `overlap(A, B) >= len` | `overlap` | `drc.Rule.overlap` | A and B overlapping by less than the limit | DRC-046 |
//! | `tap_distance(well, tap) <= len` | `max_distance_to_tap` | `drc.Rule.max_distance_to_tap` | a point of a well too far from a tap | ERC-D1 |
//! | `off_grid(; pitch: len)` | `off_grid` | `drc.Rule.off_grid` | a vertex off the manufacturing grid | DRC-001 |
//! | `angle([L]; allowed: [..])` | `angle` | `drc.Rule.angle` | an edge at an angle not in the list | DRC-002, DRC-003, DRC-037 |
//! | `redundant_via(L; within: len) >= count` | `redundant_via` | `drc.Rule.redundant_via` | a cut with too few neighbours | DRC-066, DRC-117 |
//! | `min_cuts(cut, wide, other; width: len[, within: len]) >= count` | `minimum_cut` | `drc.Rule.minimum_cut` | a via on a wide wire with too few cuts | DRC-066 |
//! | `via_stack(cut1, cut2, ..) <= count` | `via_stack` | `drc.Rule.via_stack` | a stack of overlapping cuts too tall | DRC-065 |
//! | `via_map(C, B, A; below_min, below_max, above_min, above_max, cut: w x h)` | `metal_width_via` | `drc.Rule.metal_width_via` | a cut between wires of mapped widths that is not the mapped via's cut (`LEF58_METALWIDTHVIAMAP`) | DRC-067 |
//! | `stack_space(A, B, M[; same_net: bool]) >= len` | `stack_spacing` | `drc.Rule.stack_spacing` | cuts on two layers too close unless one net's cuts are stacked (LEF `SPACING LAYER STACK`) | DRC-065 |
//! | `max_space(C[, A]) <= len` | `max_cut_spacing` | `drc.Rule.max_cut_spacing` | a cut with no other cut's centre within the limit (`LEF58_MAXSPACING`) | DRC-034 |
//! | `via_array_space(L; array: count) >= len` | `via_array_spacing` | `drc.Rule.via_array_spacing` | cuts in a large cluster too close | DRC-062 |
//! | `space(L, center) >= len`, `adjacent_space(L[, center]; cuts: count, within: len) >= len` | `cut_spacing` | `drc.Rule.cut_spacing` | cut centres too close, or cuts with many close neighbours too close | DRC-061, DRC-062 |
//! | `cut_class_space(L; short: [..], long: [..], space: [[..]])` | `cut_class_spacing` | `drc.Rule.cut_class_spacing` | two cuts closer than their cut-class cell | DRC-063, DRC-064 |
//! | `patterning(L; colors: count) >= len` | `multi_patterning` | `drc.Rule.multi_patterning` | shapes that cannot be split onto that many masks | DRC-100, DRC-101 |
//! | `patterning(L, A1, ..; colors: count) >= len` | `anchored_patterning` | `drc.Rule.anchored_patterning` | pre-coloured shapes whose masks no split honours | DRC-101, DRC-102 |
//! | `sadp(L; different, same, track_width, track_space)` | `sadp` | `drc.Rule.sadp` | a self-aligned double patterning colour cycle with an odd number of different-colour pairs, or a line spanning an even number of tracks | DRC-128 |
//! | `sadp_line_end(L; adjacent, tip, overlap, corner, offset)` | `sadp_line_end` | `drc.Rule.sadp_line_end` | gridded SADP line ends too close on one track, or overlapping, apart or offset too little on adjacent tracks | DRC-128 |
//! | `forbidden(L)` | `forbidden` | `drc.Rule.forbidden` | every shape on `L` | DRC-005, DRC-006, DRC-018, DRC-050, DRC-074, DRC-090, DRC-095, DRC-097, ERC-A10 |
//! | `contains(outer, inner) >= count` (or `<=`, `==`) | `must_contain` | `drc.Rule.must_contain` | an outer shape holding too few, or too many, inner shapes | DRC-048, DRC-049, DRC-085, DRC-090 |
//! | `inside(inner, outer)` | `must_be_inside` | `drc.Rule.must_be_inside` | an inner shape not entirely inside outer | DRC-007, DRC-048 |
//! | `length(E) >= len` | `edge_min_length` | `drc.Rule.edge_min_length` | an edge on an edge layer shorter than the limit | DRC-021, DRC-051 |
//! | `space(E[, F]) >= len` | `edge_spacing` | `drc.Rule.edge_spacing` | parallel edges on edge layers too close | DRC-051 |
//! | `enclosure(E, L) >= len` | `edge_enclosure` | `drc.Rule.edge_enclosure` | an edge whose outside is not covered by L for the limit | DRC-051 |
//! | `count(L) >= n`, `count(L) <= n` | `count` | `drc.Rule.count` | too few or too many shapes on `L` in the whole layout | DRC-091, DRC-095 |
//! | `size(L; allowed: [w x h, ..])` | `cut_class` | `drc.Rule.cut_class` | a cut whose size is none of the listed classes | DRC-014 |
//! | `min_step(L; max_edges: n \| corner: .., length_sum: ..) >= len` | `min_step` | `drc.Rule.min_step` | a run of short edges LEF `MINSTEP` rejects: too many in a row, or at a corner or step | DRC-020 |
//! | `min_step(L; adjacent: .., except_rectangle: .. \| between_eol: ..) >= len` | `min_step_adjacent` | `drc.Rule.min_step_adjacent` | a short edge beside a short edge or end of line, or two either side of a short end of line (`LEF58_MINSTEP`) | DRC-020 |
//! | `interior_angle([L]) >= deg` | `min_interior_angle` | `drc.Rule.min_interior_angle` | a drawn corner whose angle inside its shape is under the limit: an acute angle | DRC-003 |
//! | `valid([L])` | `polygon_validity` | `drc.Rule.polygon_validity` | a drawn polygon that crosses itself or encloses no area | DRC-004 |
//! | `width(L; allowed: [w, ..])`, `.., open_last: true)` | `allowed_width` | `drc.Rule.allowed_width` | a shape whose width is none of the listed widths (or, open, under the last) | DRC-015, DRC-090 |
//! | `width(E) >= len` | `edge_width` | `drc.Rule.edge_width` | two edges facing each other across their shapes closer than the limit: a channel length or width, a width in one direction | DRC-011, DRC-016, DRC-090 |
//! | `facing_space(E[; prl: len]) >= len` | `edge_facing_space` | `drc.Rule.edge_facing_space` | two edges whose outer sides face each other closer than the limit: a spacing in one direction | DRC-016 |
//! | `region_density(L, R) >= frac`, `<= frac` | `region_density` | `drc.Rule.region_density` | a shape of `R` inside which `L` covers too little or too much | DRC-072, DRC-075 |
//! | `total_area(L) <= area` | `total_area` | `drc.Rule.total_area` | more area on `L` in the whole layout than the limit | DRC-091 |
//! | `aspect_ratio(L) <= r` | `aspect_ratio` | `drc.Rule.aspect_ratio` | a shape whose bounding box is longer than `r` times its width | DRC-022 |
//! | `tip_space_table(L; length: [..], space: [[..]])` | `tip_spacing_table` | `drc.Rule.tip_spacing_table` | facing edges closer than the cell their two length classes select | DRC-031 |
//! | `forbidden_space(L; min: len, max: len, prl: len)` | `forbidden_spacing` | `drc.Rule.forbidden_spacing` | facing edges running alongside at a gap in a forbidden range | DRC-033 |
//! | `eol_space(L; eol_width: len, within: len, parallel: .., end_to_end: ..) >= len` | `eol_within_spacing` | `drc.Rule.eol_within_spacing` | too little space in a LEF end-of-line keep-out, with parallel-edge and end-to-end qualifiers | DRC-029 |
//! | `eol_keep_out(L; eol_width: len, backward: len, side: len, forward: len)` | `eol_keep_out` | `drc.Rule.eol_keep_out` | another shape inside an end of line's keep-out box | DRC-030 |
//! | `eol_extension_space(L; eol_width: [..], extension: [..], end_to_end: [..], side_length: ..) >= len` | `eol_extension_spacing` | `drc.Rule.eol_extension_spacing` | too little space from an end of line extended by its width's row | DRC-030 |
//! | `via_redundancy(cut, lower, upper; pitch, space) >= rate` | `via_redundancy` | `drc.Rule.via_redundancy` | a design whose share of vias that are or can be doubled is below the limit | DRC-117 |
//! | `dfm_score(L[, outer]; check, required, recommended, rate) >= score` | `dfm_score` | `drc.Rule.dfm_score` | a design whose DFM score over a recommended rule's findings is below the sign-off | DRC-111 |
//! | `pattern(L; window: w x h, shapes: [..], ignore: [..] \| none)` | `pattern_match` | `drc.Rule.pattern_match` | a place where the layer matches a deck-supplied pattern in any orientation | DRC-114 |
//! | `cut_area_change(pre, post, lower, upper; cuts: [..], change: [..])` | `cut_area_change` | `drc.Rule.cut_area_change` | a connector whose cut area changed between two databases by more than its cut count allows | DRC-068 |
//! | `critical_area(L; radii: [..], weights: [..]) <= area` | `mean_critical_area` | `drc.Rule.mean_critical_area` | too much mean short-circuit critical area over a deck-sampled defect-size distribution | DRC-112 |
//! | `cover_density(L, C[, boundary]; window, step, cover: [..], density: [..], inclusive)` | `cover_density` | `drc.Rule.cover_density` | a window whose density is below the band its coverage by another layer picks | DRC-076 |
//! | `origin(L)` | `origin` | `drc.Rule.origin` | a layer whose box does not start at the origin | DRC-095, DRC-097 |
//! | `protrusion_width(L; wide: len) >= len` | `protrusion_width` | `drc.Rule.protrusion_width` | a part narrower than the limit attached to a part at least `wide` wide | DRC-125 |
//! | `keep_out_zone(L; class: s x l, to: s x l \| none, end_side, end_forward, side_side, side_forward)` | `keep_out_zone` | `drc.Rule.keep_out_zone` | another cut inside a cut class's side or end keep-out zone | DRC-126 |
//! | `two_width_table(L; width: [..], prl: [..], space: [[..]])` | `two_width_spacing_table` | `drc.Rule.two_width_spacing_table` | two shapes closer than the cell both their widths select | DRC-027 |
//! | `span_length(L; x: [..], y: [..])` | `span_length` | `drc.Rule.span_length` | a span of a shape not on the list of legal spans | DRC-036 |
//! | `corner_space(L; corner_to_corner: bool, except_eol: len \| none) >= len` | `convex_corner_spacing` | `drc.Rule.convex_corner_spacing` | facing convex corners closer than the limit, by the larger axis gap, ends of line exempt | DRC-031, DRC-032 |
//! | `pitch(L, vertical \| horizontal) == len` | `exact_pitch` | `drc.Rule.exact_pitch` | neighbouring rectangles whose centres are not exactly the pitch apart | DRC-035 |
//!
//! ## Electrical rules
//!
//! Each ERC row becomes one row of the `erc.RuleSet` table for its kind. The
//! voltage rules read what each net can reach from the supplies in the
//! design-intent file.
//!
//! | Deck | Kind | Checked by | Flags | Catalog |
//! |---|---|---|---|---|
//! | `antenna(gate, collectors..; max_ratio, sidewall, diode, diode_area, diode_min)` | `antenna` | `erc.RuleSet.tables.antenna` | collector area above `max_ratio` times the gate area, a gate on a `diode` net skipped; with `diode_area` a fix hint, the diode that clears it | ERC-A1, ERC-A2, ERC-A3, ERC-A4, ERC-A8, ERC-A9, ERC-A11, ERC-A12, ERC-A13, ERC-A14, ERC-A15 |
//! | `antenna_electrical(gate, collectors..; ..)` | `antenna_electrical` | `erc.RuleSet.tables.antenna_electrical` | the cumulative ratio, with diode credit; a fix hint, the least diode that clears it | ERC-A4, ERC-A5, ERC-A6, ERC-A7, ERC-A8, ERC-A9, ERC-A12, ERC-A13, ERC-A14, ERC-A15 |
//! | `conditional_tie(region, tap, well, other; within, spacing, max_distance)` | `conditional_tie` | `erc.RuleSet.tables.conditional_tie` | a region too far from a tap for the band its neighbours' well spacing puts it in | ERC-D1a |
//! | `density_cmp(L; window, step, ..)` | `density_cmp` | `erc.RuleSet.tables.density_cmp` | metal density, or CMP thickness, out of range | DRC-071, DRC-113, ERC-B1 |
//! | `electromigration(layers..; ..)` | `electromigration` | `erc.RuleSet.tables.electromigration` | a wire or cut above its rated current at temperature | ERC-E4, ERC-E5, ERC-E6 |
//! | `em_rms(layers..; ..)` | `em_rms` | `erc.RuleSet.tables.em_rms` | a wire or cut above its RMS current limit, under the intent's RMS currents | ERC-E7 |
//! | `em_peak(layers..; ..)` | `em_peak` | `erc.RuleSet.tables.em_peak` | a wire or cut above its peak current limit, under the intent's peak currents | ERC-E7 |
//! | `em_current_density(layers..; ..)` | `em_current_density` | `erc.RuleSet.tables.em_current_density` | a wire or cut above its instantaneous current limit | ERC-C7, ERC-D4, ERC-E1, ERC-E2, ERC-E3, ERC-E10 |
//! | `ir_drop()` | `ir_drop` | `erc.RuleSet.tables.ir_drop` | a node whose drop exceeds its net's limit | ERC-E8 |
//! | `dynamic_ir_drop()` | `dynamic_ir_drop` | `erc.RuleSet.tables.dynamic_ir_drop` | a node whose drop in the worst switching cycle exceeds its net's limit | ERC-E11 |
//! | `em_thermal(layers..; ..)` | `em_thermal` | `erc.RuleSet.tables.em_thermal` | a wire or cut above its rated current at its self-heated temperature, or a chip too likely to fail by EM | ERC-E13 |
//! | `p2p_resistance(; max)` | `p2p_resistance` | `erc.RuleSet.tables.p2p_resistance` | two points on one net too far apart in resistance | ERC-C6, ERC-D4 |
//! | `reliability(; ..)` | `reliability` | `erc.RuleSet.tables.reliability` | a device whose predicted lifetime is too short | ERC-E5, ERC-F5 |
//! | `forward_diode(marker; models)` | `forward_diode` | `erc.RuleSet.tables.forward_diode` | a diode the supplies can forward-bias that no latch-up marker covers | ERC-D8 |
//! | `guard_ring(target, ring; max_space, min_width, pad, near, within, clear)` | `guard_ring` | `erc.RuleSet.tables.guard_ring` | a target no closed ring surrounds, one too far inside its ring, a ring too narrow, or a ring holding other `clear` area | ERC-D2, ERC-D6, ERC-D7, ERC-D8 |
//! | `guard_ring_bias(ring; power)` | `guard_ring_bias` | `erc.RuleSet.tables.guard_ring_bias` | an n-type ring or tap off the most positive supply, a p-type one off ground | ERC-D3, ERC-D6 |
//! | `hv_domain(; max_delta, isolation)` | `hv_domain` | `erc.RuleSet.tables.hv_domain` | a device spanning supply domains too far apart | DRC-083, ERC-F10 |
//! | `hv_tag(L, tag; voltage)` | `hv_tag` | `erc.RuleSet.tables.hv_tag` | a figure on a net that can reach `voltage` or more, not inside `tag` | DRC-083 |
//! | `undriven_gate()` | `undriven_gate` | `erc.RuleSet.tables.undriven_gate` | a gate net that floats in a declared power state | ERC-F8 |
//! | `missing_isolation(; isolation)` | `missing_isolation` | `erc.RuleSet.tables.missing_isolation` | a powered transistor whose gate floats in a declared power state | ERC-F7, ERC-H1 |
//! | `mixed_tag(L, tag)` | `mixed_tag` | `erc.RuleSet.tables.mixed_tag` | an untagged figure on a net that also holds a tagged one | ERC-F10 |
//! | `esd_latchup(pad, guard_ring; ..)` | `esd_latchup` | `erc.RuleSet.tables.esd_latchup` | a narrow or untapped guard ring, or an unclamped pad | ERC-C1, ERC-D2 |
//! | `esd_topological(pad; clamps)` | `esd_topological` | `erc.RuleSet.tables.esd_topological` | a pad with no clamp path to both supplies | ERC-C1 |
//! | `esd_cross_domain(; diodes, local, resistors, min_series, max_ground_resistance, coupling_resistance)` | `esd_cross_domain` | `erc.RuleSet.tables.esd_cross_domain` | a gate driven from another power domain whose ground is not coupled to its own by anti-parallel diodes, or that has no local clamp to its own ground | ERC-C4, ERC-C9 |
//! | `esd_exposed(pad; clamps, resistors, rated, min_series)` | `esd_exposed` | `erc.RuleSet.tables.esd_exposed` | a gate a pad exposes with no clamp path of its own, or an output driver at a pad that is not ESD-rated | ERC-C3 |
//! | `esd_ground_coupling(; diodes)` | `esd_ground_coupling` | `erc.RuleSet.tables.esd_ground_coupling` | a ground domain no chain of anti-parallel diodes couples to the others | ERC-C5 |
//! | `esd_parasitic(pad, diffusion; min_spacing)` | `esd_parasitic` | `erc.RuleSet.tables.esd_parasitic` | a pad's junction closer to another net's than a parasitic device allows | ERC-C10 |
//! | `esd_path(pad[, source]; clamps, current, clamp_resistance, max_resistance, clamp_it2, max_density, max_current_per_cut, max_voltage, min_width, clamp_voltage)` | `esd_path` | `erc.RuleSet.tables.esd_path` | under a forced current, a pin-to-supply discharge path (or a guard ring's path to its supply) too resistive, a pin rising too high, or a clamp, wire or cut too small for its share | ERC-C2, ERC-C6, ERC-C7, ERC-C8, ERC-C14, ERC-D4 |
//! | `esd_pin_pair(pad; clamps, current, clamp_resistance, max_resistance)` | `esd_pin_pair` | `erc.RuleSet.tables.esd_pin_pair` | two signal pins whose discharge path resistance through their clamps and supplies is above `max_resistance` | ERC-C6 |
//! | `esd_clamp_resistance(pad; clamps, max_resistance)` | `esd_clamp_resistance` | `erc.RuleSet.tables.esd_clamp_resistance` | a pin-to-clamp interconnect resistance above `max_resistance` (a clamp too far from its pad) | ERC-C14 |
//! | `floating_gate(; labels_are_ports)` | `floating_gate` | `erc.RuleSet.tables.floating_gate` | a net that only reaches gates | ERC-G1 |
//! | `fanout(; max)` | `fanout` | `erc.RuleSet.tables.fanout` | a net driving more than `max` transistor gates | ERC-H4 |
//! | `supply_path(; both, labels_are_ports)` | `supply_path` | `erc.RuleSet.tables.supply_path` | a net whose path through MOS channels and resistors reaches no supply, or with `both` misses power or ground; with `labels_are_ports` a path stops at a labelled net | ERC-G9 |
//! | `power_switch(; models)` | `power_switch` | `erc.RuleSet.tables.power_switch` | a power switch not joining an always-on supply to a switched one, or whose control floats in a power state | ERC-F14 |
//! | `matching(group; tolerance)` | `matching` | `erc.RuleSet.tables.matching` | a matched group's unit of another model or size, a channel across the others, or a device off the group's common centroid | ERC-H2 |
//! | `floating_supply()` | `floating_supply` | `erc.RuleSet.tables.floating_supply` | a piece of a declared supply cut off from the piece its grid is fed through | ERC-E9 |
//! | `combinational_loop()` | `combinational_loop` | `erc.RuleSet.tables.combinational_loop` | a cycle of channel-connected components, each driving the next through a gate | ERC-G8 |
//! | `gate_path(; ground, max_devices)` | `gate_path` | `erc.RuleSet.tables.gate_path` | a transistor gate whose shortest path to ground (or power) passes more than `max_devices` devices | ERC-H3 |
//! | `net_type(; net, path, break, exclude)` | `net_type` | `erc.RuleSet.tables.net_type` | a net whose own net types meet `net` and whose path's types meet `path`, over the intent's net types | ERC-H3 |
//! | `hot_carrier(; models, max_length)` | `hot_carrier` | `erc.RuleSet.tables.hot_carrier` | a minimum-length transistor used in both directions, each side driven high and low without it | ERC-F4 |
//! | `floating_well(well, tap)` | `floating_well` | `erc.RuleSet.tables.floating_well` | a well with no tap | DRC-085, ERC-G2 |
//! | `latchup_victim(aggressor, region, tap; within, max_distance, pad, bias, forward)` | `latchup_victim` | `erc.RuleSet.tables.latchup_victim` | a region near an injecting (pad-connected) junction too far from a tap | ERC-D5 |
//! | `missing_tie(region, tap; max_distance)` | `missing_tie` | `erc.RuleSet.tables.missing_tie` | a region too far from a tap | ERC-D1 |
//! | `multiple_drivers(; max)` | `multiple_drivers` | `erc.RuleSet.tables.multiple_drivers` | a net with too many drivers | ERC-G3 |
//! | `soft_connection(layers..)` | `soft_connection` | `erc.RuleSet.tables.soft_connection` | a net held together only through high-resistance layers | LVS-003, ERC-G5 |
//! | `supply_short(tap_a, tap_b[, within])` | `supply_short` | `erc.RuleSet.tables.supply_short` | a net touching both kinds of tap | ERC-G4 |
//! | `tie_area(region, contact, channel; min_ratio)` | `tie_area` | `erc.RuleSet.tables.tie_area` | a well or ring whose tap contact area is too small a share of its channel area | ERC-D1b |
//! | `tie_high_low()` | `tie_high_low` | `erc.RuleSet.tables.tie_high_low` | a gate tied straight to a rail | ERC-G7 |
//! | `unconnected_pin(layers..)` | `unconnected_pin` | `erc.RuleSet.tables.unconnected_pin` | a shape that reaches no device | DRC-084, ERC-E9, ERC-G6 |
//! | `gate_oxide(; models, max)` | `gate_oxide` | `erc.RuleSet.tables.gate_oxide` | a gate that can differ from its channel by more than max | ERC-F2 |
//! | `drain_source(; models, max)` | `drain_source` | `erc.RuleSet.tables.drain_source` | a drain that can differ from its source by more than max | ERC-F3 |
//! | `well_bias(; pmos, nmos)` | `well_bias` | `erc.RuleSet.tables.well_bias` | a well that can forward-bias a junction | ERC-D3, ERC-F12 |
//! | `well_sharing(; models, resistors)` | `well_sharing` | `erc.RuleSet.tables.well_sharing` | a transistor whose channel reaches its well's net neither directly, through a resistor, nor through a chain of transistors in the same well | ERC-D9 |
//! | `missing_level_shifter(; shifters)` | `missing_level_shifter` | `erc.RuleSet.tables.missing_level_shifter` | a gate driven from another power domain | ERC-F6 |
//! | `domain_crossing()` | `domain_crossing` | `erc.RuleSet.tables.domain_crossing` | a channel joining two power domains | ERC-F9 |
//! | `dielectric_field(L[, L2]; max_field)` | `dielectric_field` | `erc.RuleSet.tables.dielectric_field` | two nets' shapes whose voltage over their separation exceeds the field limit | ERC-F13 |
//! | `voltage_space(L[, L2]; voltage: [..], space: [..])` | `voltage_spacing` | `erc.RuleSet.tables.voltage_spacing` | shapes on two nets closer than the voltage between them allows | DRC-082, ERC-F11 |
//!
//! ## Layout against schematic
//!
//! LVS compares the extracted layout with a reference netlist (`lvs.compare`)
//! and reports under these ids. The first seven are `lvs.Discrepancy` variants;
//! the rest are checks on the layout's own graph (`lvs.checkLayout`), and
//! on its devices' measures where the deck states ranges
//! (`lvs.checkParamRanges`).
//!
//! | Report id | Raised by | Flags | Catalog |
//! |---|---|---|---|
//! | `lvs.unpaired_device` | `lvs.Discrepancy.unpaired_device` | a device with no partner on the other side | LVS-011, LVS-012, LVS-013, LVS-049 |
//! | `lvs.unpaired_net` | `lvs.Discrepancy.unpaired_net` | a net with no partner on the other side | LVS-001, LVS-015, LVS-016 |
//! | `lvs.terminal_mismatch` | `lvs.Discrepancy.terminal_mismatch` | paired devices whose terminals reach different nets | LVS-015 |
//! | `lvs.parameter_mismatch` | `lvs.Discrepancy.parameter_mismatch` | paired devices whose parameters differ beyond the tolerance | LVS-014, LVS-076 |
//! | `lvs.undeclared_param` | `lvs.Discrepancy.undeclared_param` | a parameter the reference card states that the layout does not measure | LVS-020 |
//! | `lvs.model_mismatch` | `lvs.Discrepancy.model_mismatch` | two devices wired alike whose models differ | LVS-013 |
//! | `lvs.class_imbalance` | `lvs.Discrepancy.class_imbalance` | a class with different member counts on the two sides | LVS-012, LVS-015, LVS-049 |
//! | `lvs.floating_net` | `lvs.checkLayout` | a layout net that reaches no device | LVS-006 |
//! | `lvs.label_conflict` | `lvs.checkLayout` | one label on several nets | DRC-084, LVS-001, LVS-002 |
//! | `lvs.net_seed_conflict` | `lvs.checkLayout` | several labels on one net: a short between named nets | DRC-086, LVS-001, LVS-005 |
//! | `lvs.terminal_net` | `lvs.checkLayout` | a device marker no recogniser could bind, or a terminal on no net | LVS-004 |
//! | `lvs.terminal_count` | `lvs.checkLayout` | a device with the wrong number of terminals | LVS-004 |
//! | `lvs.param_range` | `lvs.checkParamRanges` | a device parameter outside the range the deck states for its model | LVS-068 |
//! | `lvs.short_path` | `lvs.checkNetSeedConflicts` | a step of the path a short between two labels runs along | DRC-086, LVS-005 |
//! | `lvs.device_count` | `lvs.checkDeviceCounts` | more or fewer devices of a model than the deck allows | LVS-068 |
//! | `lvs.unpaired_instance` | `lvs.recordUnpairedInstances` | a reference instance none of whose devices paired, the outermost such | LVS-017 |
//!
//! Contents:
//! - `report`: `Violations`, `Violation`, `Measurement`, `RuleRun`, `recordRun`, ...
//! - `proximity`: `Validated`, `Scratch`, `prepare*`, `crossPairs`, `judgedPairs`, net spacing, `wholeAt`, ...
//! - `proximity_distance`: `pairDistancesInto`, the `cappedDist2` row kernel
//! - `proximity_inside`: `insideWhere`, `taggedFigures`, `mergedInto`
//! - `topology`: `net` (`NetTable`, `extractNetsInto`, edge builders), `device` (`DeviceTable`,
//!   `recogniseInto`), `card` (`cardRank`, `cardName`), `channel` (`refuseConductingChannels`), `port` (`PortTable`, `bindPortsInto`),
//!   `taps` (`untiedPoints*`); aliases `NetId`, `NetTable`, `extractNetsInto`, `DeviceId`,
//!   `DeviceTable`, `TerminalRole`, `recogniseInto`, `refuseConductingChannels`, `PortTable`, `bindPortsInto`
//! - `drc` (drc/root.zig): `Kind`, `Rule`, `RuleSet`, `fromDeck`, `run`, the kind tables and families
//! - `erc` (erc/root.zig): facts, voltage, the power grid and its solves, the kind tables, `RuleSet`, `check`
//! - `deck`: `compile` (`CompiledDeck`, `compile`, `fromDeck`), `source` (`sourceOf`, `print`), `builder`
//!   (`DeckBuilder`, `RuleRow`), `query` (`minWidth`, `requiredSpacing`, `enclosure`, ...), `custom`
//!   (`CustomRule`, `CustomCtx`, `Findings`, `runCustom`), `rules` (`row`, `specs`, `RuleRow`), `expr`
//!   (`Expr`, `layer`, `Bound`); aliases `CompiledDeck`, `DeckBuilder`, `RuleRow`
//! - `lvs`: layout versus schematic (lvs/root.zig: `Graph`, `compareTraced`, `checkLayout`, ...)
//! - `rects`: `LayerRects`, `SortedRects`, owners, `polyDist2`, `segDist2`, `Holes`, `inMaterial`, ...
pub const report = @import("report.zig");
pub const rects = @import("rects.zig");
pub const proximity = @import("proximity.zig");
pub const proximity_distance = @import("proximity_distance.zig");
pub const proximity_inside = @import("proximity_inside.zig");
pub const drc = @import("drc/root.zig");
/// Layout versus schematic: graphs, reduction, refinement, verdicts.
pub const lvs = @import("lvs/root.zig");
pub const erc = @import("erc/root.zig");
/// The deck compiled for the engine.
pub const deck = struct {
    pub const compile = @import("deck/compile.zig");
    pub const source = @import("deck/source.zig");
    pub const builder = @import("deck/builder.zig");
    pub const query = @import("deck/query.zig");
    pub const custom = @import("deck/custom.zig");
    pub const rules = @import("deck/rules.zig");
    pub const expr = @import("deck/expr.zig");
    pub const CompiledDeck = compile.CompiledDeck;
    pub const DeckBuilder = builder.DeckBuilder;
    pub const RuleRow = rules.RuleRow;
};

/// Electrical structure from geometry: nets, devices, ports, tap reach.
pub const topology = struct {
    pub const net = @import("topology/net.zig");
    pub const device = @import("topology/device.zig");
    pub const card = @import("topology/card.zig");
    pub const channel = @import("topology/channel.zig");
    pub const port = @import("topology/port.zig");
    pub const taps = @import("topology/taps.zig");
    pub const NetId = net.NetId;
    pub const NetTable = net.NetTable;
    pub const extractNetsInto = net.extractNetsInto;
    pub const DeviceId = device.DeviceId;
    pub const DeviceTable = device.DeviceTable;
    pub const TerminalRole = device.TerminalRole;
    pub const recogniseInto = device.recogniseInto;
    pub const refuseConductingChannels = channel.refuseConductingChannels;
    pub const PortTable = port.PortTable;
    pub const bindPortsInto = port.bindPortsInto;
};

// The device compile reads only this root's comptime blocks: name every
// kernel-owning file here.
comptime {
    _ = proximity_distance;
    _ = drc.density;
}

// ---- private ----

/// `std.testing.refAllDecls`, recursing into the namespaces and types this
/// module declares, so a pub function no test calls yet is still compiled.
fn refAll(comptime T: type) void {
    const std = @import("std");
    inline for (comptime std.meta.declarations(T)) |name| {
        const decl = @field(T, name);
        if (@TypeOf(decl) == type) switch (@typeInfo(decl)) {
            .@"struct", .@"union", .@"enum" => refAll(decl),
            else => {},
        } else _ = &@field(T, name);
    }
}

test {
    // Every pub body analyzed, called by a test yet or not.
    refAll(@This());
    _ = report;
    _ = rects;
    _ = proximity;
    _ = proximity_distance;
    _ = proximity_inside;
    _ = topology.net;
    _ = topology.device;
    _ = topology.card;
    _ = topology.channel;
    _ = topology.port;
    _ = topology.taps;
    _ = drc;
    _ = erc;
    _ = deck.compile;
    _ = deck.source;
    _ = deck.builder;
    _ = deck.query;
    _ = deck.custom;
    _ = deck.rules;
    _ = deck.expr;
    _ = lvs;
}
