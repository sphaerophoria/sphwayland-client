const std = @import("std");
const rendering = @import("../rendering.zig");

timer_expired: bool,

const NullRenderBackend = @This();

pub fn init(alloc: std.mem.Allocator) !rendering.RenderBackend {

    const fd = try std.posix.timerfd_create( .MONOTONIC, .{});
    const now = try std.posix.clock_gettime(.MONOTONIC);
    var next = std.posix.system.itimerspec {
        .it_value = .{
            .sec = now.sec + 1,
            .nsec = now.nsec,
        },
        .it_interval = .{
            .sec = 1,
            .nsec = 0,
        },
    };
    try std.posix.timerfd_settime(fd, .{ .ABSTIME = true }, &next, null);

    const ret = try alloc.create(NullRenderBackend);

    ret.* = .{
        .timer_expired = true,
    };

    return .{
        .ctx = ret,
        .event_fd = fd,
        .vtable = &.{
            .wantsRender = wantsRender,
            .displayBuffer = displayBuffer,
            .service = service,
        },
    };
}

fn wantsRender(ctx: ?*anyopaque) bool {
    const self: *NullRenderBackend = @ptrCast(@alignCast(ctx));
    return self.timer_expired;
}

fn displayBuffer(ctx: ?*anyopaque, _: rendering.RenderBuffer) !void {
    const self: *NullRenderBackend = @ptrCast(@alignCast(ctx));
    self.timer_expired = false;
}

fn service(ctx: ?*anyopaque, fd: std.posix.fd_t) !void {
    const self: *NullRenderBackend = @ptrCast(@alignCast(ctx));
    std.debug.print("Service time\n", .{});

    var read_time: u64 = undefined;
    _ = try std.posix.read(fd, std.mem.asBytes(&read_time));
    self.timer_expired = true;
}
