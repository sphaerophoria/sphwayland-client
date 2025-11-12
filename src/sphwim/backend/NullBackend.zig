const std = @import("std");
const sphtud = @import("sphtud");
const CompositorState = @import("../CompositorState.zig");
const rendering = @import("../rendering.zig");
const backend = @import("../backend.zig");

const NullRenderBackend = @This();

fd: std.posix.fd_t,

pub fn init(alloc: std.mem.Allocator) !backend.Backend {
    const ctx = try alloc.create(NullRenderBackend);
    ctx.* = .{
        .fd = try std.posix.timerfd_create(.MONOTONIC, .{}),
    };
    var next = std.posix.system.itimerspec{
        .it_value = .{
            .sec = 1,
            .nsec = 0,
        },
        .it_interval = .{
            .sec = 1,
            .nsec = 0,
        },
    };
    try std.posix.timerfd_settime(ctx.fd, .{}, &next, null);

    return .{
        .preferred_gpu = "/dev/dri/card0",
        .initial_res = .{ .width = 640, .height = 480 },
        .ctx = ctx,
        .vtable = &.{
            .makeHandlers = makeHandlers,
            .deinit = deinit,
        },
    };
}

fn deinit(ctx: ?*anyopaque) void {
    const self: *NullRenderBackend = @ptrCast(@alignCast(ctx));
    std.posix.close(self.fd);
}

const Handler = struct {
    parent: *NullRenderBackend,
    renderer: *rendering.Renderer,

    fn poll(ctx: ?*anyopaque, _: *sphtud.event.Loop, _: sphtud.event.PollReason) sphtud.event.Loop.PollResult {
        const self: *Handler = @ptrCast(@alignCast(ctx));

        self.pollError() catch |e| {
            std.log.err("Timer poll failed: {t}", .{e});
            return .complete;
        };

        return .in_progress;
    }

    fn pollError(self: *Handler) !void {
        var read_time: u64 = undefined;
        _ = try std.posix.read(self.parent.fd, std.mem.asBytes(&read_time));

        const buf = try self.renderer.render();
        if (buf) |b| {
            self.renderer.releaseBuffer(b);
        }
    }

    fn close(_: ?*anyopaque) void {}
};

fn makeHandlers(ctx: ?*anyopaque, alloc: std.mem.Allocator, renderer: *rendering.Renderer, _: *CompositorState) anyerror![]sphtud.event.Loop.Handler {
    const self: *NullRenderBackend = @ptrCast(@alignCast(ctx));

    const handler_ctx = try alloc.create(Handler);
    handler_ctx.* = .{
        .parent = self,
        .renderer = renderer,
    };

    const handlers = try alloc.alloc(sphtud.event.Loop.Handler, 1);
    handlers[0] = .{
        .ptr = handler_ctx,
        .vtable = &.{
            .poll = Handler.poll,
            .close = Handler.close,
        },
        .fd = self.fd,
        .desired_events = .{
            .read = true,
            .write = false,
        },
    };

    return handlers;
}
