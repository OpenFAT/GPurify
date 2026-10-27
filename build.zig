const std = @import("std");
const gompute_build = @import("gompute");
const Build = std.Build;
const Import = Build.Module.Import;

/// One owner per row, in dependency order: a module imports only rows above
/// it, so the graph is a DAG by construction (ARCHITECTURE.md, Modules).
/// `kernels`: the module root is also a Gompute kernel root, compiled for
/// CUDA and HIP; its files hold their own specs and `exportKernels` calls.
const Owner = struct { name: []const u8, deps: []const []const u8, kernels: bool = false };
const owners = [_]Owner{
    .{ .name = "geom", .deps = &.{"gompute"}, .kernels = true },
    .{ .name = "ingest", .deps = &.{"geom"} },
    .{ .name = "check", .deps = &.{ "gompute", "geom", "ingest" }, .kernels = true },
    .{ .name = "extract", .deps = &.{ "gompute", "geom", "ingest", "check" }, .kernels = true },
    .{ .name = "gpurify", .deps = &.{ "geom", "ingest", "check", "extract" } },
};

pub fn build(b: *Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{}) orelse .debug;
    const gpu = b.option(bool, "gpu", "Compile the GPU device kernels (default true)") orelse true;
    const cuda_arch = b.option([]const u8, "cuda-arch", "CUDA arch (sm_75, ...), `auto` to probe the build machine, `none` to omit") orelse "auto";
    const hip_arch = b.option([]const u8, "hip-arch", "HIP arch (gfx1100, ...), `none` to omit") orelse "gfx1100";
    const gpu_tests = b.option(bool, "gpu-tests", "Run the CPU-vs-GPU differentials; fails without a CUDA/HIP driver") orelse false;
    const ngspice_tests = b.option(bool, "ngspice-tests", "Run the Liberty differential against ngspice; fails without ngspice on PATH") orelse false;
    const comparison_tests = b.option(bool, "comparison-tests", "Run the comparisons against KLayout, Netgen, Magic, FastCap, FastHenry, OpenROAD, Yosys and ngspice (nix develop .#comparison); a missing tool fails") orelse false;
    const update_goldens = b.option(bool, "update-goldens", "Write missing or changed tests/golden files, then fail so the change is reviewed") orelse false;
    const test_filters = b.option([]const []const u8, "test-filter", "Run only the suite tests whose names contain this (repeatable)") orelse &.{};
    const slow_tests = b.option(bool, "slow-tests", "Run the field-solve tests too slow for Debug (on by default outside Debug)") orelse (optimize != .debug);

    const gompute_dep = b.dependency("gompute", .{});
    var roots: std.ArrayList(gompute_build.KernelRoot) = .empty;
    for (owners, 0..) |o, i| if (o.kernels) roots.append(b.allocator, .{
        .name = o.name,
        .root = b.path(b.fmt("src/{s}/root.zig", .{o.name})),
        .imports = &deviceImports,
        .imports_ctx = @ptrFromInt(i + 1),
    }) catch @panic("OOM");
    device_gompute = gompute_dep;
    const kernels = gompute_build.addKernels(b, gompute_dep, .{
        .kernel_roots = roots.items,
        .target = target,
        .optimize = if (optimize == .debug) .fast else optimize,
        .cuda = if (gpu) gpuArch(cuda_arch) else .{ .enabled = false },
        .hip = if (gpu) gpuArch(hip_arch) else .{ .enabled = false },
    });

    // Suites find tests/, pdks/ and docs/ through this, from any cwd.
    const paths = b.addOptions();
    paths.addOption([]const u8, "root", b.pathResolve(&.{ b.root.root_dir.path orelse ".", b.root.sub_path }));
    paths.addOption(bool, "gpu_tests", gpu_tests);
    paths.addOption(bool, "slow_tests", slow_tests);
    paths.addOption(bool, "ngspice_tests", ngspice_tests or comparison_tests);
    paths.addOption(bool, "comparison_tests", comparison_tests);
    paths.addOption(bool, "update_goldens", update_goldens);
    const paths_import: Import = .{ .name = "paths", .module = paths.createModule() };

    var mods: std.StringArrayHashMapUnmanaged(*Build.Module) = .empty;
    kernels.gompute.optimize = null;
    mods.put(b.allocator, "gompute", kernels.gompute) catch @panic("OOM");
    for (owners) |o| {
        const m = b.addModule(o.name, .{
            .root_source_file = b.path(b.fmt("src/{s}/root.zig", .{o.name})),
            .target = target,
            // Inherited from each root, so `bench` builds them ReleaseFast.
            .link_libc = gpu, // Gompute dlopens the CUDA/HIP driver
        });
        for (o.deps) |d| m.addImport(d, mods.get(d) orelse
            std.debug.panic("module '{s}' imports '{s}', which is not above it in `owners`", .{ o.name, d }));
        // A kernel root's host side asks `has_cuda`/`has_hip` before naming a
        // raw kernel, which is a compile error in a build without artifacts.
        if (o.kernels) m.addImport("gompute_kernels", kernels.kernels);
        // The shipped decks live in pdks/ at the root, outside src/gpurify.
        if (std.mem.eql(u8, o.name, "gpurify")) for ([_][]const u8{ "sky130", "gf180mcu", "ihp_sg13g2", "asap7" }) |deck|
            m.addAnonymousImport(b.fmt("{s}.deck", .{deck}), .{ .root_source_file = b.path(b.fmt("pdks/{s}.deck", .{deck})) });
        mods.put(b.allocator, o.name, m) catch @panic("OOM");
    }

    // Generators and oracles for the suites; never shipped.
    const testgen = b.createModule(.{
        .root_source_file = b.path("tests/testgen.zig"),
        .target = target,
        .imports = &.{
            .{ .name = "geom", .module = mods.get("geom").? },
            .{ .name = "ingest", .module = mods.get("ingest").? },
            .{ .name = "check", .module = mods.get("check").? },
        },
    });

    const exe = b.addExecutable(.{
        .name = "gpurify",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/main.zig"),
            .target = target,
            .optimize = optimize,
            .link_libc = gpu,
            .imports = &.{.{ .name = "gpurify", .module = mods.get("gpurify").? }},
        }),
    });
    b.installArtifact(exe);

    const run_cmd = b.addRunArtifact(exe);
    run_cmd.step.dependOn(b.getInstallStep());
    run_cmd.addPassthruArgs();
    b.step("run", "Run gpurify").dependOn(&run_cmd.step);

    // `bench`: every GPU-capable kernel, CPU against GPU, ReleaseFast
    // whatever -Doptimize says (tools/bench.zig).
    const bench = b.addExecutable(.{ .name = "bench", .root_module = b.createModule(.{
        .root_source_file = b.path("tools/bench.zig"),
        .target = target,
        .optimize = .fast,
        .link_libc = gpu,
        .imports = &.{
            .{ .name = "gompute", .module = kernels.gompute },
            .{ .name = "geom", .module = mods.get("geom").? },
            .{ .name = "check", .module = mods.get("check").? },
            .{ .name = "extract", .module = mods.get("extract").? },
            .{ .name = "gpurify", .module = mods.get("gpurify").? },
            .{ .name = "testgen", .module = testgen },
        },
    }) });
    b.step("bench", "Time every GPU-capable kernel on the CPU and the GPU").dependOn(&b.addRunArtifact(bench).step);

    // `test-<owner>` runs the owner's unit tests and its tests/<owner>.zig
    // suite; `test` runs every one of them, the CLI's and testgen's.
    const test_all = b.step("test", "Run every suite");
    // `test-cli`: the CLI's unit tests, then the built binary end to end on
    // one corpus case against Rust's golden bytes (tests/golden.rs's job:
    // exit code, stdout, stderr).
    const test_cli = b.step("test-cli", "Run the CLI's tests and the binary against a golden");
    test_cli.dependOn(&b.addRunArtifact(b.addTest(.{ .name = "cli", .root_module = exe.root_module })).step);
    const golden_path = b.pathResolve(&.{ b.root.root_dir.path orelse ".", b.root.sub_path, "tests/golden/drc/DRC_VALID_ZERO.all" });
    const golden = std.Io.Dir.cwd().readFileAlloc(b.graph.io, golden_path, b.allocator, .unlimited) catch @panic(golden_path);
    const stdout_at = (std.mem.indexOf(u8, golden, "--- stdout\n") orelse @panic("golden without stdout")) + "--- stdout\n".len;
    const stderr_at = std.mem.indexOf(u8, golden, "--- stderr\n") orelse @panic("golden without stderr");
    const e2e = b.addRunArtifact(exe);
    e2e.setCwd(b.path("."));
    e2e.addArgs(&.{ "all", "tests/fixtures/drc/DRC_VALID_ZERO.gds", "--deck", "tests/fixtures/params.deck", "--format", "json" });
    e2e.expectExitCode(std.fmt.parseInt(u8, golden["exit ".len..std.mem.indexOfScalar(u8, golden, '\n').?], 10) catch @panic("golden exit code"));
    e2e.expectStdOutEqual(golden[stdout_at..stderr_at]);
    e2e.expectStdErrEqual(golden[stderr_at + "--- stderr\n".len ..]);
    e2e.has_side_effects = true; // reads tests/ files the cache cannot see
    test_cli.dependOn(&e2e.step);
    test_all.dependOn(test_cli);
    test_all.dependOn(&b.addRunArtifact(b.addTest(.{ .name = "testgen", .root_module = testgen })).step);
    for (owners) |o| {
        const step = b.step(b.fmt("test-{s}", .{o.name}), b.fmt("Run the {s} suites", .{o.name}));
        step.dependOn(&b.addRunArtifact(b.addTest(.{ .name = o.name, .root_module = mods.get(o.name).? })).step);
        const suite = b.createModule(.{
            .root_source_file = b.path(b.fmt("tests/{s}.zig", .{o.name})),
            .target = target,
            .optimize = optimize,
            .imports = &.{ .{ .name = "testgen", .module = testgen }, paths_import },
        });
        suite.addImport(o.name, mods.get(o.name).?);
        for (o.deps) |d| suite.addImport(d, mods.get(d).?);
        // A suite reads tests/ data (goldens, fixtures) the cache cannot see.
        const suite_run = b.addRunArtifact(b.addTest(.{ .name = b.fmt("{s}-suite", .{o.name}), .root_module = suite, .filters = test_filters }));
        suite_run.has_side_effects = true;
        step.dependOn(&suite_run.step);
        test_all.dependOn(step);
    }
}

/// The device compile of an owner's root sees its owner imports rebuilt for
/// the device target; the compile analyses only what the kernels reference.
var device_gompute: *Build.Dependency = undefined;

fn deviceImports(b: *Build, target: Build.ResolvedTarget, optimize: std.lang.Optimize, ctx: ?*anyopaque) []const Import {
    var made: [owners.len]?*Build.Module = @splat(null);
    const o = owners[@intFromPtr(ctx) - 1];
    const out = b.allocator.alloc(Import, o.deps.len) catch @panic("OOM");
    var n: usize = 0;
    for (o.deps) |d| if (!std.mem.eql(u8, d, "gompute")) {
        out[n] = .{ .name = d, .module = deviceModule(b, target, optimize, d, &made) };
        n += 1;
    };
    return out[0..n];
}

fn deviceModule(b: *Build, target: Build.ResolvedTarget, optimize: std.lang.Optimize, name: []const u8, made: *[owners.len]?*Build.Module) *Build.Module {
    const i = for (owners, 0..) |o, i| (if (std.mem.eql(u8, o.name, name)) break i) else unreachable;
    if (made[i]) |m| return m;
    const m = b.createModule(.{ .root_source_file = b.path(b.fmt("src/{s}/root.zig", .{name})), .target = target, .optimize = optimize, .strip = true });
    made[i] = m;
    for (owners[i].deps) |d| m.addImport(d, if (std.mem.eql(u8, d, "gompute"))
        device_gompute.module("gompute_device")
    else
        deviceModule(b, target, optimize, d, made));
    return m;
}

fn gpuArch(arch: []const u8) gompute_build.CudaOptions {
    if (std.mem.eql(u8, arch, "none")) return .{ .enabled = false };
    if (std.mem.eql(u8, arch, "auto")) return .{};
    return .{ .gpu = .{ .name = arch } };
}
