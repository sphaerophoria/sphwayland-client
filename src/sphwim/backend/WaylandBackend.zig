const std = @import("std");
const sphtud = @import("sphtud");
const rendering = @import("../rendering.zig");
const backend = @import("../backend.zig");
const sphwindow = @import("sphwindow");
const CompositorState = @import("../CompositorState.zig");
const system_gl = @import("../system_gl.zig");

const WaylandRenderBackend = @This();

const logger = std.log.scoped(.wayland_renderer);

window: sphwindow.Window,
system_running: *bool,
outstanding_buffers: sphtud.util.AutoHashMapLinear(u32, system_gl.GbmContext.Buffer),

pub fn init(alloc: std.mem.Allocator, system_running: *bool) !backend.Backend {
    const ctx = try alloc.create(WaylandRenderBackend);

    ctx.* = .{
        .window = try sphwindow.Window.init(alloc),
        .system_running = system_running,
        // Anything over quadruple buffering would be quite surprising to me
        .outstanding_buffers = try .init(alloc, alloc, 4, 4),
    };

    return .{
        .preferred_gpu = try ctx.window.getPreferredGpu(alloc),
        .initial_res = .{ .width = 1024, .height = 768 },
        .ctx = ctx,
        .vtable = &.{
            .makeHandlers = makeHandlers,
            .deinit = deinit,
        },
    };
}

fn deinit(ctx: ?*anyopaque) void {
    const self: *WaylandRenderBackend = @ptrCast(@alignCast(ctx));
    self.window.deinit();
}

const Handler = struct {
    parent: *WaylandRenderBackend,
    renderer: *rendering.Renderer,
    compositor_state: *CompositorState,

    fn close(_: ?*anyopaque) void {}

    fn poll(ctx: ?*anyopaque, _: *sphtud.event.LoopSphalloc, _: sphtud.event.PollReason) sphtud.event.LoopSphalloc.PollResult {
        const self: *Handler = @ptrCast(@alignCast(ctx));
        self.parent.pollError(self.renderer, self.compositor_state) catch |e| {
            logger.err("Failed to poll: {t}", .{e});
            return .in_progress;
        };

        return .in_progress;
    }
};

fn makeHandlers(ctx: ?*anyopaque, alloc: std.mem.Allocator, renderer: *rendering.Renderer, compositor_state: *CompositorState) ![]sphtud.event.LoopSphalloc.Handler {
    const self: *WaylandRenderBackend = @ptrCast(@alignCast(ctx));
    const fd = self.window.getFd();

    const handler_ctx = try alloc.create(Handler);
    handler_ctx.* = .{
        .parent = self,
        .renderer = renderer,
        .compositor_state = compositor_state,
    };

    const handlers = try alloc.alloc(sphtud.event.LoopSphalloc.Handler, 1);
    handlers[0] = .{
        .ptr = handler_ctx,
        .fd = fd,
        .desired_events = .{
            .read = true,
            .write = false,
        },
        .vtable = &.{
            .poll = Handler.poll,
            .close = Handler.close,
        },
    };

    return handlers;
}

fn pollError(self: *WaylandRenderBackend, renderer: *rendering.Renderer, compositor_state: *CompositorState) !void {
    if (try self.window.service(OutstandingBufNotifier{
        .outstanding_buffers = &self.outstanding_buffers,
        .renderer = renderer,
    })) {
        self.system_running.* = false;
    }

    if (self.window.pointerUpdate()) |update| {
        compositor_state.notifyCursorPosition(update.x, update.y);
    }

    if (!self.window.wantsFrame()) {
        return;
    }

    if (try renderer.render()) |buf| {
        try self.displayBuffer(renderer, buf);
    }
}

fn displayBuffer(self: *WaylandRenderBackend, renderer: *rendering.Renderer, buffer: system_gl.GbmContext.Buffer) !void {
    errdefer renderer.gbm_ctx.unlock(buffer);

    const fd = try buffer.fd();
    defer std.posix.close(fd);

    const client_raw_buffer = sphwindow.RenderBuffer{
        .fd = fd,
        .modifier = buffer.modifier(),
        .offset = buffer.offset(),
        .stride = buffer.stride(),
        .width = std.math.cast(u32, buffer.width()) orelse return error.InvalidWidth,
        .height = std.math.cast(u32, buffer.height()) orelse return error.InvalidHeight,
        .format = buffer.format(),
    };

    const buf_id = try self.window.swapBuffers(client_raw_buffer);
    try self.outstanding_buffers.put(buf_id, buffer);
}

const OutstandingBufNotifier = struct {
    outstanding_buffers: *sphtud.util.AutoHashMapLinear(u32, system_gl.GbmContext.Buffer),
    renderer: *rendering.Renderer,

    pub fn notifyGlBufferRelease(self: @This(), buf_id: u32) void {
        const buffer = self.outstanding_buffers.remove(buf_id) orelse {
            logger.err("Got a buffer release for a buffer we are not tracking", .{});
            return;
        };

        self.renderer.releaseBuffer(buffer);
    }
};
