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

    fn init(root: *sphtud.alloc.Sphalloc, scratch: *sphtud.alloc.BufAllocator) !PeriodicMemoryDumper {
        const fd = try std.posix.timerfd_create(.MONOTONIC, .{ .NONBLOCK = true });

        const timer = std.posix.system.itimerspec{
            .it_value = .{
                .sec = 0.0,
                .nsec = 1.0,
            },
            .it_interval = .{
                .sec = 5.0,
                .nsec = 0.0,
            },
        };
        try std.posix.timerfd_settime(fd, .{ .ABSTIME = false }, &timer, null);

        return .{
            .root = root,
            .scratch = scratch,
            .timer = fd,
        };
    }

    const vtable = sphtud.event.LoopSphalloc.Handler.VTable{
        .poll = poll,
        .close = close,
    };

    fn handler(self: *PeriodicMemoryDumper) sphtud.event.LoopSphalloc.Handler {
        return .{
            .ptr = self,
            .fd = self.timer,
            .vtable = &vtable,
            .desired_events = .{
                .read = true,
                .write = true,
            },
        };
    }

    fn poll(ctx: ?*anyopaque, _: *sphtud.event.LoopSphalloc, _: sphtud.event.PollReason) sphtud.event.LoopSphalloc.PollResult {
        const self: *PeriodicMemoryDumper = @ptrCast(@alignCast(ctx));
        self.pollError() catch return .complete;
        return .in_progress;
    }

    fn pollError(self: *PeriodicMemoryDumper) !void {
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

    fn close(ctx: ?*anyopaque) void {
        const self: *PeriodicMemoryDumper = @ptrCast(@alignCast(ctx));
        std.posix.close(self.timer);
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
}

pub fn main() !void {
    var tpa: sphtud.alloc.TinyPageAllocator = undefined;
    try tpa.initPinned();

    var root_alloc: sphtud.alloc.Sphalloc = undefined;
    try root_alloc.initPinned(tpa.allocator(), "root");

    var scratch_buf: [1 * 1024 * 1024]u8 = undefined;
    var scratch = sphtud.alloc.BufAllocator.init(&scratch_buf);

    var system_running: bool = true;

    const render_backend = try backend.initBackend(root_alloc.general(), &system_running);
    defer render_backend.deinit();

    var gbm_context = try system_gl.GbmContext.init(render_backend.initial_res.width, render_backend.initial_res.height, render_backend.preferred_gpu);
    errdefer gbm_context.deinit();

    var egl_context = try system_gl.EglContext.init(scratch.linear(), gbm_context);
    errdefer egl_context.deinit();

    try sphtud.render.initGl(system_gl.getProcAddress);

    initializeGlParams();

    var rng_seed: u64 = undefined;
    try std.posix.getrandom(std.mem.asBytes(&rng_seed));
    var rng = std.Random.DefaultPrng.init(rng_seed);

    var compositor_state = try CompositorState.init(&root_alloc, &scratch, rng.random(), render_backend.initial_res);
    var memory_dumper = try PeriodicMemoryDumper.init(&root_alloc, &scratch);

    var gl_alloc = try sphtud.render.GlAlloc.init(&root_alloc);
    defer gl_alloc.deinit();

    const image_renderer = try sphtud.render.xyuvt_program.ImageRenderer.init(&gl_alloc, .rgba);

    var renderer = try rendering.Renderer.init(
        &root_alloc,
        scratch.linear(),
        &gl_alloc,
        &egl_context,
        &gbm_context,
        &compositor_state,
        image_renderer,
    );

    var loop = try sphtud.event.LoopSphalloc.init(
        root_alloc.arena(),
        root_alloc.block_alloc.allocator(),
    );

    var server = try wayland.makeWaylandServer(
        try root_alloc.makeSubAlloc("server"),
        scratch.linear(),
        rng.random(),
        &compositor_state,
        &gbm_context,
        &egl_context,
    );
    try loop.register(server.handler());
    try loop.register(memory_dumper.handler());
    const handlers = try render_backend.makeHandlers(root_alloc.arena(), &renderer, &compositor_state);
    for (handlers) |handler| {
        try loop.register(handler);
    }

    while (system_running) {
        scratch.reset();
        try loop.wait(scratch.linear());
    }
}
