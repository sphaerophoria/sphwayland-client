const std = @import("std");
const process_include_paths = @import("build/process_include_paths.zig");

pub const BindingsGenerator = struct {
    b: *std.Build,
    target: std.Build.ResolvedTarget,
    optimize: std.builtin.OptimizeMode,
    wlgen: *std.Build.Step.Compile,
    wlio: *std.Build.Module,

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
        bindings_mod.addImport("wlio", self.wlio);

        return bindings_mod;
    }
};

const Builder = struct {
    target: std.Build.ResolvedTarget,
    optimize: std.builtin.OptimizeMode,
    b: *std.Build,

    pub fn makeWlio(self: Builder) *std.Build.Module {
        return self.b.addModule("wlio", .{
            .root_source_file = self.b.path("src/wlio.zig"),
            .target = self.target,
            .optimize = self.optimize,
        });
    }

    pub fn makeBindings(self: Builder, wlio: *std.Build.Module) *std.Build.Module {
        const wlgen = self.b.addExecutable(.{
            .name = "wlgen",
            .root_module = self.b.createModule(.{
                .root_source_file = self.b.path("src/wlgen/wlgen.zig"),
                .target = self.b.graph.host,
                .optimize = self.optimize,
            }),
        });
        wlgen.linkLibC();
        self.b.installArtifact(wlgen);

        const bindings_generator = BindingsGenerator{
            .b = self.b,
            .target = self.target,
            .optimize = self.optimize,
            .wlio = wlio,
            .wlgen = wlgen,
        };

        return bindings_generator.generate(
            "wayland.zig",
            &.{
                self.b.path("res/wayland.xml"),
                self.b.path("res/xdg-shell.xml"),
                self.b.path("res/xdg-decoration-unstable-v1.xml"),
                self.b.path("res/linux-dmabuf-v1.xml"),
            });
    }

    pub fn makeWlClient(self: Builder, wlio: *std.Build.Module) *std.Build.Module {
        const wlclient = self.b.addModule("wlclient", .{
            .root_source_file = self.b.path("src/wlclient/wlclient.zig"),
        });
        wlclient.addImport("wlio", wlio);
        wlclient.addIncludePath(self.b.path("src/wlclient"));
        wlclient.addCSourceFile(.{
            .file = self.b.path("src/wlclient/cmsg.c"),
        });
        return wlclient;
    }

    pub fn makeWindow(self: Builder, wlio: *std.Build.Module, bindings: *std.Build.Module, wlclient: *std.Build.Module) !*std.Build.Module {
        const window_translate_c_bindings = try self.translateCFixed("src/window/c_bindings.h");
        const window_bindings_mod = window_translate_c_bindings.createModule();

        const sphwindow = self.b.addModule("sphwindow", .{
            .root_source_file = self.b.path("src/window/window.zig"),
            .target = self.target,
        });
        sphwindow.addImport("wlio", wlio);
        sphwindow.addIncludePath(self.b.path("src"));
        sphwindow.addImport("c_bindings", window_bindings_mod);
        sphwindow.addImport("wl_bindings", bindings);
        sphwindow.addImport("wlclient", wlclient);

        sphwindow.linkSystemLibrary("EGL", .{});
        sphwindow.linkSystemLibrary("gbm", .{});

        return sphwindow;
    }

    pub fn makeWindowExample(self: Builder, sphwindow: *std.Build.Module) !*std.Build.Step.Compile {
        const gl_bindings_translate_c = try self.translateCFixed("src/example/gl.h");
        const gl_bindings = gl_bindings_translate_c.createModule();

        const stbi_mod = self.b.addTranslateC(.{
            .root_source_file = self.b.path("src/example/stb_image.h"),
            .target = self.target,
            .optimize = self.optimize,
        }).createModule();

        const exe = self.b.addExecutable(.{
            .name = "sphwayland-client",
            .root_module = self.b.createModule(.{
                .root_source_file =  self.b.path("src/example/main.zig"),
                .target = self.target,
                .optimize = self.optimize,
            }),
        });

        exe.linkSystemLibrary("GL");
        exe.root_module.addImport("gl", gl_bindings);
        exe.root_module.addImport("stbi", stbi_mod);
        exe.addIncludePath(self.b.path("src/example"));
        exe.addCSourceFile(.{
            .file = self.b.path("src/example/stb_image.c"),
        });
        exe.linkLibC();

        exe.root_module.addImport("sphwindow", sphwindow);

        return exe;
    }

    fn translateCFixed(self: Builder, path: []const u8) !*std.Build.Step.TranslateC {
        const window_translate_c_bindings = self.b.addTranslateC(.{
            .root_source_file = self.b.path(path),
            .target = self.target,
            .optimize = self.optimize,
        });

        var include_it = try process_include_paths.IncludeIter.init(self.b.allocator);
        while (include_it.next()) |p| {
            window_translate_c_bindings.addSystemIncludePath(std.Build.LazyPath { .cwd_relative = p });
        }
        return window_translate_c_bindings;
    }
};

pub fn build(b: *std.Build) !void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});
    const check = b.option(bool, "check", "") orelse false;

    const builder = Builder {
        .target = target,
        .optimize = optimize,
        .b = b,
    };

    const wlio_mod = builder.makeWlio();
    const wayland_bindings = builder.makeBindings(wlio_mod);
    const wlclient = builder.makeWlClient(wlio_mod);
    const sphwindow = try builder.makeWindow(wlio_mod, wayland_bindings, wlclient);
    const example = try builder.makeWindowExample(sphwindow);

    if (check) {
        b.getInstallStep().dependOn(&example.step);
    } else {
        b.installArtifact(example);
    }
}
