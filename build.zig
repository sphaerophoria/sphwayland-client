const std = @import("std");

pub const BindingsGenerator = struct {
    b: *std.Build,
    target: std.Build.ResolvedTarget,
    optimize: std.builtin.OptimizeMode,
    wlgen: *std.Build.Step.Compile,
    wl_writer: *std.Build.Module,
    wl_reader: *std.Build.Module,

    pub fn generate(self: *const BindingsGenerator, name: []const u8, xml: []const std.Build.LazyPath) *std.Build.Module {
        const wlgen_run = self.b.addRunArtifact(self.wlgen);
        for (xml) |x| {
            wlgen_run.addFileArg(x);
        }
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
    wlgen.linkLibC();
    b.installArtifact(wlgen);

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

    const wayland_bindings = bindings_generator.generate(
        "wayland.zig",
        &.{
            b.path("res/wayland.xml"),
            b.path("res/xdg-shell.xml"),
            b.path("res/xdg-decoration-unstable-v1.xml"),
            b.path("res/linux-dmabuf-v1.xml"),
        });

    const sphwayland = b.addModule("sphwayland", .{
        .root_source_file = b.path("src/wayland.zig"),
    });
    sphwayland.addImport("wl_writer", wl_writer_mod);
    sphwayland.addImport("wl_reader", wl_reader_mod);
    sphwayland.addCSourceFile(.{
        .file = b.path("src/cmsg.c"),
    });
    sphwayland.addIncludePath(b.path("src"));

    const exe = b.addExecutable(.{
        .name = "sphwayland-client",
        .root_source_file = b.path("src/main.zig"),
        .target = target,
        .optimize = optimize,
    });

    exe.linkSystemLibrary("GL");
    exe.linkSystemLibrary("EGL");
    exe.addIncludePath(b.path("src"));
    exe.addCSourceFile(.{
        .file = b.path("src/stb_image.c"),
    });
    exe.linkLibC();

    exe.root_module.addImport("sphwayland", sphwayland);
    exe.root_module.addImport("wl_bindings", wayland_bindings);

    b.installArtifact(exe);
}
