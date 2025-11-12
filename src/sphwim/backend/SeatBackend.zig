const std = @import("std");
const sphtud = @import("sphtud");
const rendering = @import("../rendering.zig");
const backend = @import("../backend.zig");
const CompositorState = @import("../CompositorState.zig");
const DrmRenderer = @import("DrmRenderBackend.zig");
const LibinputHandler = @import("LibInputInputBackend.zig");

drm: DrmRenderer,

const SeatBackend = @This();

pub fn init(alloc: std.mem.Allocator) !backend.Backend {
    const drm = try DrmRenderer.init(alloc);

    const ctx = try alloc.create(SeatBackend);
    ctx.* = .{
        .drm = drm,
    };

    return .{
        .preferred_gpu = drm.preferred_gpu,
        .initial_res = .{ .width = drm.preferred_mode.hdisplay, .height = drm.preferred_mode.vdisplay },
        .ctx = ctx,
        .vtable = &.{
            .makeHandlers = makeHandlers,
            .deinit = deinit,
        },
    };
}

fn makeHandlers(ctx: ?*anyopaque, alloc: std.mem.Allocator, renderer: *rendering.Renderer, compositor_state: *CompositorState) anyerror![]sphtud.event.Loop.Handler {
    const self: *SeatBackend = @ptrCast(@alignCast(ctx));

    const handlers = try alloc.alloc(sphtud.event.Loop.Handler, 2);
    handlers[0] = try self.drm.makeHandler(alloc, renderer);
    handlers[1] = try LibinputHandler.init(alloc, compositor_state);

    return handlers;
}

fn deinit(ctx: ?*anyopaque) void {
    const self: *SeatBackend = @ptrCast(@alignCast(ctx));
    self.drm.deinit();
}
