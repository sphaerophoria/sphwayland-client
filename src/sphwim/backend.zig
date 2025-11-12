const std = @import("std");
const sphtud = @import("sphtud");
const rendering = @import("rendering.zig");
const CompositorState = @import("CompositorState.zig");
const SeatBackend = @import("backend/SeatBackend.zig");
const WaylandBackend = @import("backend/WaylandBackend.zig");
const NullBackend = @import("backend/NullBackend.zig");

const logger = std.log.scoped(.backend);

pub const Backend = struct {
    preferred_gpu: []const u8,
    initial_res: rendering.Resolution,
    ctx: ?*anyopaque,
    vtable: *const VTable,

    const VTable = struct {
        makeHandlers: *const fn (ctx: ?*anyopaque, alloc: std.mem.Allocator, renderer: *rendering.Renderer, compositor_state: *CompositorState) anyerror![]sphtud.event.Loop.Handler,
        deinit: *const fn (ctx: ?*anyopaque) void,
    };

    pub fn makeHandlers(self: Backend, alloc: std.mem.Allocator, renderer: *rendering.Renderer, compositor_state: *CompositorState) ![]sphtud.event.Loop.Handler {
        return self.vtable.makeHandlers(self.ctx, alloc, renderer, compositor_state);
    }

    pub fn deinit(self: Backend) void {
        return self.vtable.deinit(self.ctx);
    }
};

pub fn initBackend(alloc: std.mem.Allocator, expansion_alloc: sphtud.util.ExpansionAlloc, system_running: *bool) !Backend {
    if (WaylandBackend.init(alloc, expansion_alloc, system_running)) |res| {
        return res;
    } else |e| {
        logger.info("Failed to init wayland render backend: {t}", .{e});
    }

    if (SeatBackend.init(alloc)) |res| {
        return res;
    } else |e| {
        logger.info("Failed to init drm render backend: {t}", .{e});
    }

    logger.warn("Failed to init render backend, using null backend", .{});
    return try NullBackend.init(alloc);
}
