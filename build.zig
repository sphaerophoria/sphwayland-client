const std = @import("std");

const BindingsGenerator = struct {
    b: *std.Build,
    target: std.Build.ResolvedTarget,
    optimize: std.builtin.OptimizeMode,
    wlgen: *std.Build.Step.Compile,
    wl_writer: *std.Build.Module,
    wl_reader: *std.Build.Module,

    fn generate(self: *const BindingsGenerator, name: []const u8, xml: std.Build.LazyPath) *std.Build.Module {
        const wlgen_run = self.b.addRunArtifact(self.wlgen);
        wlgen_run.addFileArg(xml);
        const bindings = wlgen_run.addOutputFileArg(name);

        const bindings_mod = self.b.addModule("bindings", .{
            .root_source_file = bindings,
            .target = self.target,
            .optimize = self.optimize,
        });
        bindings_mod.addImport("wl_writer", self.wl_writer);
        bindings_mod.addImport("wl_reader", self.wl_reader);

        return bindings_mod;
    }
};

pub fn build(b: *std.Build) !void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const wlgen = b.addExecutable(.{
        .name = "wlgen",
        .root_source_file = b.path("src/wlgen.zig"),
        .target = target,
        .optimize = optimize,
    });
    wlgen.linkSystemLibrary("expat");
    wlgen.linkLibC();
    const wl_writer_mod = b.addModule("wl_writer", .{
        .root_source_file = b.path("src/wl_writer.zig"),
        .target = target,
        .optimize = optimize,
    });

    const wl_reader_mod = b.addModule("wl_reader", .{
        .root_source_file = b.path("src/wl_reader.zig"),
        .target = target,
        .optimize = optimize,
    });

    const bindings_generator = BindingsGenerator{
        .b = b,
        .target = target,
        .optimize = optimize,
        .wl_writer = wl_writer_mod,
        .wl_reader = wl_reader_mod,
        .wlgen = wlgen,
    };

    const wayland_bindings = bindings_generator.generate("wayland.zig", b.path("res/wayland.xml"));
    const xdg_shell_bindings = bindings_generator.generate("xdg_shell.zig", b.path("res/xdg-shell.xml"));
    const xdg_decoration_bindings = bindings_generator.generate("xdg_decoration.zig", b.path("res/xdg-decoration-unstable-v1.xml"));

    const exe = b.addExecutable(.{
        .name = "sphwayland-client",
        .root_source_file = b.path("src/main.zig"),
        .target = target,
        .optimize = optimize,
    });

    exe.addIncludePath(b.path("src"));
    exe.addCSourceFile(.{
        .file = b.path("src/cmsg.c"),
    });
    exe.linkLibC();

    exe.root_module.addImport("wl_bindings", wayland_bindings);
    exe.root_module.addImport("xdg_shell_bindings", xdg_shell_bindings);
    exe.root_module.addImport("xdg_decoration_bindings", xdg_decoration_bindings);
    exe.root_module.addImport("wl_writer", wl_writer_mod);
    exe.root_module.addImport("wl_reader", wl_reader_mod);

    b.installArtifact(exe);
}
