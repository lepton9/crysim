const std = @import("std");
const zon = @import("build.zig.zon");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const crysim_mod = b.createModule(.{
        .root_source_file = b.path("src/crysim.zig"),
        .target = target,
        .optimize = optimize,
    });

    const run_cli_step = b.step("cli", "Run the cli executable");
    const exe_cli = setupClientCli(b, target, optimize, crysim_mod);
    const run_cli_cmd = b.addRunArtifact(exe_cli);
    run_cli_cmd.addPassthruArgs();
    run_cli_step.dependOn(&run_cli_cmd.step);
    run_cli_cmd.step.dependOn(b.getInstallStep());

    const run_daemon_step = b.step("daemon", "Run the daemon executable");
    const exe_daemon = setupDaemon(b, target, optimize, crysim_mod);
    const run_daemon_cmd = b.addRunArtifact(exe_daemon);
    run_daemon_cmd.addPassthruArgs();
    run_daemon_step.dependOn(&run_daemon_cmd.step);
    run_daemon_cmd.step.dependOn(b.getInstallStep());

    // Check step
    const check_step = b.step("check", "Check for compilation errors");
    check_step.dependOn(&run_cli_cmd.step);
    check_step.dependOn(&run_daemon_cmd.step);
}

pub fn setupDaemon(
    b: *std.Build,
    target: std.Build.ResolvedTarget,
    optimize: std.builtin.OptimizeMode,
    crysim_mod: *std.Build.Module,
) *std.Build.Step.Compile {
    const exe = b.addExecutable(.{
        .name = "crysimd",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/daemon/main.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{},
        }),
    });
    exe.root_module.addImport("crysim", crysim_mod);
    b.installArtifact(exe);
    return exe;
}

pub fn setupClientCli(
    b: *std.Build,
    target: std.Build.ResolvedTarget,
    optimize: std.builtin.OptimizeMode,
    crysim_mod: *std.Build.Module,
) *std.Build.Step.Compile {
    const options = b.addOptions();
    options.addOption([]const u8, "program_name", @tagName(zon.name));

    const zcli = b.lazyDependency("zcli", .{
        .target = target,
        .optimize = optimize,
        .version_tag = zon.version,
    });

    const exe = b.addExecutable(.{
        .name = "crysim",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/cli/main.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{},
        }),
    });
    exe.root_module.addImport("crysim", crysim_mod);
    if (zcli) |m| exe.root_module.addImport("zcli", m.module("zcli"));
    exe.root_module.addOptions("build_options", options);

    b.installArtifact(exe);
    return exe;
}
