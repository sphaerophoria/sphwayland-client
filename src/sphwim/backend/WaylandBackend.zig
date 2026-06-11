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
outstanding_buffers: sphtud.util.AutoHashMap(u32, system_gl.GbmContext.Buffer),

pub fn init(alloc: std.mem.Allocator, expansion_alloc: sphtud.util.ExpansionAlloc, env: std.process.Environ, system_running: *bool) !WaylandRenderBackend {
    return .{
        .window = try sphwindow.Window.init(alloc, expansion_alloc, env),
        .system_running = system_running,
        // Anything over quadruple buffering would be quite surprising to me
        .outstanding_buffers = try .init(alloc, .linear(alloc), 4, 4),
    };
}

pub fn getFd(self: *const WaylandRenderBackend) std.posix.fd_t {
    return self.window.getFd();
}

pub fn deinit(self: *WaylandRenderBackend) void {
    self.window.deinit();
}

pub fn service(self: *WaylandRenderBackend, renderer: *rendering.Renderer, compositor_state: *CompositorState) !void {
    if (try self.window.service(GlCtxProxy{
        .outstanding_buffers = &self.outstanding_buffers,
        .renderer = renderer,
    })) {
        self.system_running.* = false;
    }

    var input_event_it = self.window.inputEvents();
    while (input_event_it.next()) |event| switch (event.*) {
        .pointer_movement => |pos| try compositor_state.notifyCursorPosition(pos.x, pos.y),
        .mouse1_down => try compositor_state.notifyMouse1Down(),
        .mouse1_up => compositor_state.notifyMouse1Up(),
    };

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
    defer sphtud.io.close(fd);

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

const GlCtxProxy = struct {
    outstanding_buffers: *sphtud.util.AutoHashMap(u32, system_gl.GbmContext.Buffer),
    renderer: *rendering.Renderer,

    pub fn notifyGlBufferRelease(self: @This(), buf_id: u32) void {
        const buffer = self.outstanding_buffers.remove(buf_id) orelse {
            logger.err("Got a buffer release for a buffer we are not tracking", .{});
            return;
        };

        self.renderer.releaseBuffer(buffer);
    }

    pub fn requestResize(self: @This(), width: i32, height: i32) !void {
        // sphwim does not yet support being resized, just ingore
        _ = self;
        _ = width;
        _ = height;
    }
};
