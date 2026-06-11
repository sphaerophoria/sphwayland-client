const std = @import("std");
const sphtud = @import("sphtud");
const CompositorState = @import("../CompositorState.zig");
const rendering = @import("../rendering.zig");

const NullRenderBackend = @This();

fd: std.posix.fd_t,

pub fn init() !NullRenderBackend {
    const fd = try sphtud.io.timerfd_create(.BOOTTIME);

    try sphtud.io.timerfd_settime(fd, .{ .rel = .fromSeconds(1) }, .fromSeconds(1));

    return .{
        .fd = fd,
    };
}

pub fn getFd(self: *const NullRenderBackend) std.posix.fd_t {
    return self.fd;
}

pub fn deinit(self: *NullRenderBackend) void {
    sphtud.io.close(self.fd);
}

pub fn service(self: *NullRenderBackend, renderer: *rendering.Renderer, _: *CompositorState) !void {
    var read_time: u64 = undefined;
    _ = try sphtud.io.read(self.fd, std.mem.asBytes(&read_time));

    const buf = try renderer.render();
    if (buf) |b| {
        renderer.releaseBuffer(b);
    }
}
