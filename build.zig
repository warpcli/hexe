const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    // Get ghostty-vt module from dependency
    const ghostty_vt_mod = if (b.lazyDependency("ghostty", .{
        .target = target,
        .optimize = optimize,
    })) |ghostty_dep| ghostty_dep.module("ghostty-vt") else null;

    // Get argonaut module from dependency
    const argonaut_mod = if (b.lazyDependency("argonaut", .{
        .target = target,
        .optimize = optimize,
    })) |argonaut_dep| argonaut_dep.module("argonaut") else null;

    // Get ziglua dependency for embedded Lua
    const ziglua_dep = b.lazyDependency("ziglua", .{
        .target = target,
        .optimize = optimize,
    });

    // Create core module
    const core_module = b.createModule(.{
        .root_source_file = b.path("src/core/mod.zig"),
        .target = target,
        .optimize = optimize,
        .link_libc = true,
    });
    if (ghostty_vt_mod) |vt| {
        core_module.addImport("ghostty-vt", vt);
    }
    if (ziglua_dep) |dep| {
        const zlua_mod = dep.module("zlua");
        core_module.addImport("zlua", zlua_mod);
    }

    // Create shp module (shell prompt/status bar segments)
    const shp_module = b.createModule(.{
        .root_source_file = b.path("src/modules/shp/mod.zig"),
        .target = target,
        .optimize = optimize,
    });
    shp_module.addImport("core", core_module);

    // Create pop module (popup/overlay system)
    const pop_module = b.createModule(.{
        .root_source_file = b.path("src/modules/pop/mod.zig"),
        .target = target,
        .optimize = optimize,
    });
    pop_module.addImport("core", core_module);

    // Create mux module for unified CLI
    const mux_module = b.createModule(.{
        .root_source_file = b.path("src/modules/mux/main.zig"),
        .target = target,
        .optimize = optimize,
        .link_libc = true,
    });
    mux_module.addImport("core", core_module);
    mux_module.addImport("shp", shp_module);
    mux_module.addImport("pop", pop_module);
    if (ghostty_vt_mod) |vt| {
        mux_module.addImport("ghostty-vt", vt);
    }

    // Create ses module for unified CLI
    const ses_module = b.createModule(.{
        .root_source_file = b.path("src/modules/ses/main.zig"),
        .target = target,
        .optimize = optimize,
        .link_libc = true,
    });
    ses_module.addImport("core", core_module);

    // Create pod module (per-pane PTY + scrollback; launched via `hexe pod daemon`)
    const pod_module = b.createModule(.{
        .root_source_file = b.path("src/modules/pod/mod.zig"),
        .target = target,
        .optimize = optimize,
        .link_libc = true,
    });
    pod_module.addImport("core", core_module);

    // Build unified hexe CLI executable
    const cli_root = b.createModule(.{
        .root_source_file = b.path("src/cli/main.zig"),
        .target = target,
        .optimize = optimize,
        .link_libc = true,
    });
    cli_root.addImport("core", core_module);
    cli_root.addImport("mux", mux_module);
    cli_root.addImport("ses", ses_module);
    cli_root.addImport("pod", pod_module);
    cli_root.addImport("shp", shp_module);
    if (argonaut_mod) |arg| {
        cli_root.addImport("argonaut", arg);
    }
    const cli_exe = b.addExecutable(.{
        .name = "hexe",
        .root_module = cli_root,
    });
    b.installArtifact(cli_exe);

    // Run hexe step
    const run_hexe = b.addRunArtifact(cli_exe);
    run_hexe.step.dependOn(b.getInstallStep());
    if (b.args) |args| {
        run_hexe.addArgs(args);
    }
    const run_step = b.step("run", "Run hexe");
    run_step.dependOn(&run_hexe.step);
}
