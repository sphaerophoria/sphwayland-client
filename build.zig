const std = @import("std");
const process_include_paths = @import("build/process_include_paths.zig");

pub const BindingsGenerator = struct {
    b: *std.Build,
    target: std.Build.ResolvedTarget,
    optimize: std.builtin.OptimizeMode,
    wlgen: *std.Build.Step.Compile,
    wlio: *std.Build.Module,

    pub fn generate(self: *const BindingsGenerator, name: []const u8, bindings_mode: []const u8, xml: []const std.Build.LazyPath) *std.Build.Module {
        const wlgen_run = self.b.addRunArtifact(self.wlgen);

        wlgen_run.addArg(bindings_mode);

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

    pub fn importSphtud(self: Builder) *std.Build.Module {
        const gl_extensions: []const []const u8 = &.{"GL_OES_EGL_image"};
        return self.b.dependency("sphtud", .{
            .with_gl = true,
            .gl_extensions = gl_extensions,
        }).module("sphtud");
    }

    pub fn makeWlio(self: Builder) *std.Build.Module {
        return self.b.addModule("wlio", .{
            .root_source_file = self.b.path("src/wlio.zig"),
            .target = self.target,
            .optimize = self.optimize,
        });
    }

    pub fn makeWlgen(self: Builder) *std.Build.Step.Compile {
        const wlgen = self.b.addExecutable(.{
            .name = "wlgen",
            .root_module = self.b.createModule(.{
                .root_source_file = self.b.path("src/wlgen/wlgen.zig"),
                .target = self.b.graph.host,
                .optimize = self.optimize,
            }),
        });
        return wlgen;
    }

    pub fn makeClientBindings(self: Builder, wlgen: *std.Build.Step.Compile, wlio: *std.Build.Module) *std.Build.Module {
        const bindings_generator = BindingsGenerator{
            .b = self.b,
            .target = self.target,
            .optimize = self.optimize,
            .wlio = wlio,
            .wlgen = wlgen,
        };

        return bindings_generator.generate("wayland.zig", "client", &.{
            self.b.path("res/wayland.xml"),
            self.b.path("res/xdg-shell.xml"),
            self.b.path("res/xdg-decoration-unstable-v1.xml"),
            self.b.path("res/linux-dmabuf-v1.xml"),
        });
    }

    pub fn makeServerBindings(self: Builder, wlgen: *std.Build.Step.Compile, wlio: *std.Build.Module) *std.Build.Module {
        const bindings_generator = BindingsGenerator{
            .b = self.b,
            .target = self.target,
            .optimize = self.optimize,
            .wlio = wlio,
            .wlgen = wlgen,
        };

        return bindings_generator.generate("wayland.zig", "server", &.{
            self.b.path("res/wayland.xml"),
            self.b.path("res/xdg-shell.xml"),
            self.b.path("res/xdg-decoration-unstable-v1.xml"),
            self.b.path("res/linux-dmabuf-v1.xml"),
        });
    }

    pub fn makeWlCmsg(self: Builder) *std.Build.Module {
        const exe = self.b.addExecutable(.{
            .name = "gen_zig_cmsg",
            .root_module = self.b.createModule(.{
                .target = self.b.graph.host,
                .optimize = self.optimize,
            }),
        });
        exe.root_module.addCSourceFile(.{
            .file = self.b.path("build/gen_zig_cmsg.c"),
        });
        exe.linkLibC();

        const run = self.b.addRunArtifact(exe);
        const zig_source = run.addOutputFileArg("fd_cmsg.zig");

        const fd_cmsg = self.b.createModule(.{
            .root_source_file = zig_source,
        });

        const wlclient = self.b.addModule("wlcmsg", .{
            .root_source_file = self.b.path("src/wlcmsg.zig"),
        });
        wlclient.addImport("fd_cmsg", fd_cmsg);
        return wlclient;
    }

    pub fn makeWlClient(self: Builder, wlio: *std.Build.Module, wl_cmsg: *std.Build.Module, sphtud: *std.Build.Module) *std.Build.Module {
        const wlclient = self.b.addModule("wlclient", .{
            .root_source_file = self.b.path("src/wlclient.zig"),
        });
        wlclient.addImport("wlio", wlio);
        wlclient.addImport("wl_cmsg", wl_cmsg);
        wlclient.addImport("sphtud", sphtud);
        return wlclient;
    }

    pub fn makeSystemGlBindings(self: Builder) !*std.Build.Module {
        const window_translate_c_bindings = try self.translateCFixed("src/window/c_bindings.h");
        const module = window_translate_c_bindings.createModule();
        return module;
    }

    pub fn makeWindow(self: Builder, wlio: *std.Build.Module, bindings: *std.Build.Module, wlclient: *std.Build.Module, gl_bindings: *std.Build.Module, sphtud: *std.Build.Module) !*std.Build.Module {
        const sphwindow = self.b.addModule("sphwindow", .{
            .root_source_file = self.b.path("src/window/window.zig"),
            .target = self.target,
        });
        sphwindow.addImport("wlio", wlio);
        sphwindow.addIncludePath(self.b.path("src"));
        sphwindow.addImport("c_bindings", gl_bindings);
        sphwindow.addImport("wl_bindings", bindings);
        sphwindow.addImport("wlclient", wlclient);
        sphwindow.addImport("sphtud", sphtud);
        sphwindow.linkSystemLibrary("EGL", .{});
        sphwindow.linkSystemLibrary("gbm", .{});

        return sphwindow;
    }

    pub fn makeWlWaiter(self: Builder, wlio: *std.Build.Module, bindings: *std.Build.Module, wlclient: *std.Build.Module) !*std.Build.Step.Compile {
        const exe = self.b.addExecutable(.{ .name = "wait_for_wl", .root_module = self.b.createModule(.{
            .root_source_file = self.b.path("src/wl_waiter.zig"),
            .target = self.target,
        }) });
        exe.root_module.addImport("wlio", wlio);
        exe.root_module.addIncludePath(self.b.path("src"));
        exe.root_module.addImport("wl_bindings", bindings);
        exe.root_module.addImport("wlclient", wlclient);
        return exe;
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
                .root_source_file = self.b.path("src/example/main.zig"),
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

    pub fn makeWm(self: Builder, wlio: *std.Build.Module, bindings: *std.Build.Module, sphtud: *std.Build.Module, wl_cmsg: *std.Build.Module, sphwindow: *std.Build.Module) !*std.Build.Step.Compile {
        const gl_bindings_translate_c = try self.translateCFixed("src/sphwim/gl_system_bindings.h");
        const gl_bindings = gl_bindings_translate_c.createModule();

        const input_bindings_translate_c = try self.translateCFixed("src/sphwim/input.h");
        const input_bindings = input_bindings_translate_c.createModule();

        const exe = self.b.addExecutable(.{
            .name = "sphwim",
            .root_module = self.b.createModule(.{
                .root_source_file = self.b.path("src/sphwim/main.zig"),
                .target = self.target,
                .optimize = self.optimize,
            }),
        });

        exe.root_module.addImport("wlio", wlio);
        exe.root_module.addImport("wayland_bindings", bindings);
        exe.root_module.addImport("sphtud", sphtud);
        exe.root_module.addImport("wl_cmsg", wl_cmsg);
        exe.root_module.addImport("gl_system_bindings", gl_bindings);
        exe.root_module.addImport("input", input_bindings);
        exe.root_module.addImport("sphwindow", sphwindow);

        exe.linkSystemLibrary("gbm");
        exe.linkSystemLibrary("EGL");
        exe.linkSystemLibrary("input");
        exe.linkSystemLibrary("libudev");
        exe.linkSystemLibrary("GL");

        for (self.b.search_prefixes.items) |prefix| {
            exe.addSystemIncludePath(self.b.path(try std.fmt.allocPrint(self.b.allocator, "{s}/include/libdrm", .{prefix})));
        }
        exe.linkSystemLibrary("drm");
        exe.linkLibC();

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
            window_translate_c_bindings.addSystemIncludePath(std.Build.LazyPath{ .cwd_relative = p });
        }
        return window_translate_c_bindings;
    }
};

pub fn build(b: *std.Build) !void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});
    const check = b.option(bool, "check", "") orelse false;

    const builder = Builder{
        .target = target,
        .optimize = optimize,
        .b = b,
    };

    const sphtud = builder.importSphtud();
    const wlio_mod = builder.makeWlio();
    const wlgen = builder.makeWlgen();
    const client_bindings = builder.makeClientBindings(wlgen, wlio_mod);
    const wl_cmsg = builder.makeWlCmsg();
    const wlclient = builder.makeWlClient(wlio_mod, wl_cmsg, sphtud);
    const system_gl_bindings = try builder.makeSystemGlBindings();
    const sphwindow = try builder.makeWindow(wlio_mod, client_bindings, wlclient, system_gl_bindings, sphtud);
    const wait_for_wl = try builder.makeWlWaiter(wlio_mod, client_bindings, wlclient);
    const example = try builder.makeWindowExample(sphwindow);

    const server_bindings = builder.makeServerBindings(wlgen, wlio_mod);
    const wm = try builder.makeWm(wlio_mod, server_bindings, sphtud, wl_cmsg, sphwindow);

    if (check) {
        b.getInstallStep().dependOn(&example.step);
        b.getInstallStep().dependOn(&wm.step);
        b.getInstallStep().dependOn(&wlgen.step);
        b.getInstallStep().dependOn(&wait_for_wl.step);
    } else {
        b.installArtifact(example);
        b.installArtifact(wm);
        b.installArtifact(wlgen);
        b.installArtifact(wait_for_wl);
    }
}
