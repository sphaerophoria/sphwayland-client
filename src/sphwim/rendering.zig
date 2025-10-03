const std = @import("std");
const DrmRenderBackend = @import("rendering/DrmRenderBackend.zig");
const NullRenderBackend = @import("rendering/NullRenderBackend.zig");

pub const RenderBuffer = struct {
    wl_buffer: u32,
    buf_fd: c_int,
    modifiers: u64,
    offset: u32,
    plane_idx: u32,
    stride: u32,
    width: i32,
    height: i32,
    format: u32,
};

pub const RenderBackend = struct {
    ctx: ?*anyopaque,
    event_fd: std.posix.fd_t,
    vtable: *const VTable,

    const VTable = struct {
        displayBuffer: *const fn (ctx: ?*anyopaque, render_buffer: RenderBuffer, locked_flag: *bool) anyerror!void,
        service: *const fn (ctx: ?*anyopaque, fd: std.posix.fd_t) anyerror!void,
    };

    pub fn displayBuffer(self: RenderBackend, render_buffer: RenderBuffer, locked_flag: *bool) !void {
        try self.vtable.displayBuffer(self.ctx, render_buffer, locked_flag);
    }

    pub fn service(self: RenderBackend) !void {
        try self.vtable.service(self.ctx, self.event_fd);
    }
};

pub fn initRenderBackend(alloc: std.mem.Allocator) !RenderBackend {
    if (DrmRenderBackend.init(alloc)) |backend| {
        return backend;
    } else |e| {
        std.log.info("Failed to init drm render backend: {t}", .{e});
    }

    std.log.warn("Failed to init render backend, using null backend", .{});
    return try NullRenderBackend.init(alloc);
}
