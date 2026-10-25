const std = @import("std");
const gompute_build = @import("gompute");
const Build = std.Build;
const Import = Build.Module.Import;

/// One owner per row, in dependency order: a module imports only rows above
/// it, so the graph is a DAG by construction (ARCHITECTURE.md, Modules).
const Owner = struct { name: []const u8, deps: []const []const u8 };
const owners = [_]Owner{
    .{ .name = "geom", .deps = &.{"gompute"} },
    .{ .name = "ingest", .deps = &.{"geom"} },
    .{ .name = "check", .deps = &.{ "gompute", "geom", "ingest" } },
    .{ .name = "extract", .deps = &.{ "gompute", "geom", "ingest", "check" } },
    .{ .name = "gpurify", .deps = &.{ "geom", "ingest", "check", "extract" } },
};

/// Gompute kernel roots: device-compiled leaves that import only `gompute`.
const kernel_roots = [_]struct { []const u8, []const u8 }{
    .{ "geom", "src/geom/root.zig" },
};

pub fn build(b: *Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{}) orelse .debug;
    const gpu = b.option(bool, "gpu", "Compile the GPU device kernels (default true)") orelse true;
    const cuda_arch = b.option([]const u8, "cuda-arch", "CUDA arch (sm_75, ...), `auto` to probe the build machine, `none` to omit") orelse "auto";
    const hip_arch = b.option([]const u8, "hip-arch", "HIP arch (gfx1100, ...), `none` to omit") orelse "gfx1100";

    const gompute_dep = b.dependency("gompute", .{});
    var roots: [kernel_roots.len]gompute_build.KernelRoot = undefined;
    for (kernel_roots, &roots) |k, *root| root.* = .{ .name = k[0], .root = b.path(k[1]) };
    const kernels = gompute_build.addKernels(b, gompute_dep, .{
        .kernel_roots = &roots,
        .target = target,
        .optimize = if (optimize == .debug) .fast else optimize,
        .cuda = if (gpu) gpuArch(cuda_arch) else .{ .enabled = false },
        .hip = if (gpu) gpuArch(hip_arch) else .{ .enabled = false },
    });

    // Suites find tests/, pdks/ and docs/ through this, from any cwd.
    const paths = b.addOptions();
    paths.addOption([]const u8, "root", b.pathResolve(&.{ b.root.root_dir.path orelse ".", b.root.sub_path }));
    const paths_import: Import = .{ .name = "paths", .module = paths.createModule() };

    var mods: std.StringArrayHashMapUnmanaged(*Build.Module) = .empty;
    mods.put(b.allocator, "gompute", kernels.gompute) catch @panic("OOM");
    for (owners) |o| {
        const m = b.addModule(o.name, .{
            .root_source_file = b.path(b.fmt("src/{s}/root.zig", .{o.name})),
            .target = target,
            .optimize = optimize,
            .link_libc = gpu, // Gompute dlopens the CUDA/HIP driver
        });
        for (o.deps) |d| m.addImport(d, mods.get(d) orelse
            std.debug.panic("module '{s}' imports '{s}', which is not above it in `owners`", .{ o.name, d }));
        mods.put(b.allocator, o.name, m) catch @panic("OOM");
    }

    // Generators and oracles for the suites; never shipped.
    const testgen = b.createModule(.{
        .root_source_file = b.path("tests/testgen.zig"),
        .target = target,
        .optimize = optimize,
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

    // `test-<owner>` runs the owner's unit tests and its tests/<owner>.zig
    // suite; `test` runs every one of them, the CLI's and testgen's.
    const test_all = b.step("test", "Run every suite");
    test_all.dependOn(&b.addRunArtifact(b.addTest(.{ .name = "cli", .root_module = exe.root_module })).step);
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
        step.dependOn(&b.addRunArtifact(b.addTest(.{ .name = b.fmt("{s}-suite", .{o.name}), .root_module = suite })).step);
        test_all.dependOn(step);
    }
}

fn gpuArch(arch: []const u8) gompute_build.CudaOptions {
    if (std.mem.eql(u8, arch, "none")) return .{ .enabled = false };
    if (std.mem.eql(u8, arch, "auto")) return .{};
    return .{ .gpu = .{ .name = arch } };
}
