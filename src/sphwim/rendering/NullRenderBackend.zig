const std = @import("std");
const rendering = @import("../rendering.zig");

const NullRenderBackend = @This();

pub fn init() !rendering.RenderBackend {
    const fd = try std.posix.timerfd_create(.MONOTONIC, .{});
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
    try std.posix.timerfd_settime(fd, .{}, &next, null);

    return .{
        .ctx = null,
        .event_fd = fd,
        .vtable = &.{
            .displayBuffer = displayBuffer,
            .currentResolution = currentResolution,
            .service = service,
            .deinit = deinit,
        },
    };
}

fn deinit(_: ?*anyopaque, fd: std.posix.fd_t) void {
    std.posix.close(fd);
}

fn currentResolution(_: ?*anyopaque, _: std.posix.fd_t) !rendering.Resolution {
    return .{
        .width = 640,
        .height = 480,
    };
}

fn displayBuffer(_: ?*anyopaque, _: rendering.RenderBuffer, locked: *bool) !void {
    locked.* = false;
}

fn service(_: ?*anyopaque, fd: std.posix.fd_t) !void {
    var read_time: u64 = undefined;
    _ = try std.posix.read(fd, std.mem.asBytes(&read_time));
}
