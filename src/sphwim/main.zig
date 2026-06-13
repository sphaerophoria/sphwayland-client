const std = @import("std");
const sphtud = @import("sphtud");
const rendering = @import("rendering.zig");
const wayland = @import("wayland.zig");
const Bindings = @import("wayland_bindings");
const CompositorState = @import("CompositorState.zig");
const system_gl = @import("system_gl.zig");
const gl = sphtud.render.gl;
const backend = @import("backend.zig");

pub const std_options = std.Options{
    .log_level = .warn,
};

const PeriodicMemoryDumper = struct {
    root: *sphtud.alloc.Sphalloc,
    scratch: *sphtud.alloc.BufAllocator,
    timer: std.posix.fd_t,

    pub fn init(root: *sphtud.alloc.Sphalloc, scratch: *sphtud.alloc.BufAllocator) !PeriodicMemoryDumper {
        const fd = try sphtud.io.timerfd_create(.BOOTTIME);
        try sphtud.io.timerfd_settime(fd, .{ .rel = .fromSeconds(1) }, .fromSeconds(5));

        return .{
            .root = root,
            .scratch = scratch,
            .timer = fd,
        };
    }

    pub fn deinit(self: *PeriodicMemoryDumper) void {
        sphtud.io.close(self.timer);
    }

    pub fn service(self: *PeriodicMemoryDumper) !void {
        const cp = self.scratch.checkpoint();
        defer self.scratch.restore(cp);

        var num_triggers: u64 = 0;
        _ = try std.posix.read(self.timer, std.mem.asBytes(&num_triggers));

        const snapshot = try sphtud.alloc.MemoryTracker.snapshot(self.scratch.allocator(), self.root, 100);
        std.log.info("Dumping memory usage", .{});
        for (snapshot) |elem| {
            std.log.info("{s}: {d}", .{ elem.name, elem.memory_used });
        }
    }
};

fn debugCallback(_: gl.GLenum, _: gl.GLenum, _: gl.GLuint, _: gl.GLenum, length: gl.GLsizei, message: [*c]const gl.GLchar, _: ?*const anyopaque) callconv(.c) void {
    std.log.debug("GL: {s}\n", .{message[0..@intCast(length)]});
}

pub fn initializeGlParams() void {
    gl.glEnable(gl.GL_DEBUG_OUTPUT);
    gl.glDebugMessageCallback(debugCallback, null);
    gl.glBlendFunc(gl.GL_SRC_ALPHA, gl.GL_ONE_MINUS_SRC_ALPHA);
    gl.glEnable(gl.GL_BLEND);
    gl.glEnable(gl.GL_DEPTH_TEST);
    gl.glDepthFunc(gl.GL_LESS);
}

const Ids = struct {
    backend: backend.Ids,
    wayland: wayland.WaylandServer.Ids,
    memory_dumper: usize,
    signal: usize,

    const max_wl_clients = 4096;

    fn init() Ids {
        var alloc = sphtud.util.IdAlloc.init;

        return .{
            .backend = .init(&alloc),
            .wayland = .init(&alloc, max_wl_clients),
            .memory_dumper = alloc.allocOne(),
            .signal = alloc.allocOne(),
        };
    }
};

const ids = Ids.init();

fn genBlockMask() std.os.linux.sigset_t {
    const system = std.os.linux;
    var set = system.sigemptyset();
    system.sigaddset(&set, system.SIG.PIPE);
    system.sigaddset(&set, system.SIG.INT);
    return set;
}

fn genFdMask() std.os.linux.sigset_t {
    const system = std.os.linux;
    var set = system.sigemptyset();
    system.sigaddset(&set, system.SIG.INT);
    return set;
}

const block_sigmask = genBlockMask();
const fd_sigmask = genFdMask();

pub fn main(init: std.process.Init.Minimal) !void {
    _ = std.os.linux.sigprocmask(std.os.linux.SIG.BLOCK, &block_sigmask, null);

    var tpa: sphtud.alloc.TinyPageAllocator = undefined;
    try tpa.initPinned();

    var root_alloc: sphtud.alloc.Sphalloc = undefined;
    try root_alloc.initPinned(tpa.allocator(), "root");

    var scratch_buf: [1 * 1024 * 1024]u8 = undefined;
    var scratch = sphtud.alloc.BufAllocator.init(&scratch_buf);

    var system_running: bool = true;

    var chain_buf: [100]usize = undefined;
    var loop = try sphtud.io.Loop.init(&chain_buf);

    var render_backend = try backend.initBackend(root_alloc.arena(), root_alloc.expansion(), init.environ, &system_running, &loop, ids.backend);
    defer render_backend.deinit();

    var gbm_context = try system_gl.GbmContext.init(render_backend.initial_res.width, render_backend.initial_res.height, render_backend.preferred_gpu);
    errdefer gbm_context.deinit();

    var egl_context = try system_gl.EglContext.init(scratch.linear(), gbm_context);
    errdefer egl_context.deinit();

    try sphtud.render.initGl(system_gl.getProcAddress);

    initializeGlParams();

    var rng_seed: u64 = undefined;
    try sphtud.io.getrandom(std.mem.asBytes(&rng_seed));
    var rng = std.Random.DefaultPrng.init(rng_seed);

    var compositor_state = try CompositorState.init(&root_alloc, &scratch, render_backend.initial_res);

    var memory_dumper = try PeriodicMemoryDumper.init(&root_alloc, &scratch);
    defer memory_dumper.deinit();
    try loop.register(.{
        .id = ids.memory_dumper,
        .handle = memory_dumper.timer,
        .read = true,
        .write = false,
    });

    var gl_alloc = try sphtud.render.GlAlloc.init(&root_alloc);
    defer gl_alloc.deinit();

    const image_renderer = try sphtud.render.xyuvt_program.ImageRenderer.init(&gl_alloc, .rgba);
    const solid_color_renderer = try sphtud.render.xyt_program.solidColorProgram(&gl_alloc);

    var renderer = try rendering.Renderer.init(
        &root_alloc,
        scratch.linear(),
        &gl_alloc,
        &egl_context,
        &gbm_context,
        &compositor_state,
        image_renderer,
        solid_color_renderer,
    );

    var server = try wayland.makeWaylandServer(
        try root_alloc.makeSubAlloc("server"),
        scratch.linear(),
        rng.random(),
        &compositor_state,
        &gbm_context,
        &egl_context,
        &loop,
        init.environ,
        ids.wayland,
    );

    defer sphtud.io.unlink(server.socket_path) catch {};

    const signal_fd = try sphtud.io.signalfd(&fd_sigmask);
    try loop.register(.{
        .id = ids.signal,
        .handle = signal_fd,
        .read = true,
        .write = false,
    });

    try render_backend.serviceFirst(&renderer, &compositor_state);

    while (system_running) {
        scratch.reset();
        const event = try loop.poll(-1) orelse continue;

        switch (event) {
            ids.backend.total.start...ids.backend.total.end => {
                try render_backend.service(&renderer, &compositor_state, event, ids.backend);
            },
            ids.wayland.total.start...ids.wayland.total.end => {
                try server.service(event, ids.wayland);
            },
            ids.memory_dumper => {
                try memory_dumper.service();
            },
            ids.signal => {
                system_running = false;
            },
            else => unreachable,
        }
    }
}

test {
    std.testing.refAllDecls(@This());
}
