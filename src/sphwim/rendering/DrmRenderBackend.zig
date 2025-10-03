const std = @import("std");
const c = @cImport({
    @cInclude("xf86drm.h");
    @cInclude("xf86drmMode.h");
});

const rendering = @import("../rendering.zig");
const Drm = @This();

crtc_id: u32,
dri_file: std.fs.File,
connector_id: u32,
preferred_mode: *c.drmModeModeInfo,

// FIXME: Deinit or file pool
pub fn init(alloc: std.mem.Allocator) !rendering.RenderBackend {
    const f = try std.fs.openFileAbsolute("/dev/dri/card0", .{
        .mode = .read_write,
    });

    const resources: *c.drmModeRes = c.drmModeGetResources(f.handle) orelse return error.GetResourcers;
    const connector = getFirstConnectedConnector(f, resources) orelse return error.NoConnector;
    const preferred_mode = getPreferredMode(connector) orelse return error.NoMode;

    const encoder: *c.drmModeEncoder = c.drmModeGetEncoder(f.handle, connector.encoder_id) orelse return error.NoEncoder;
    const crtc: *c.drmModeCrtc = c.drmModeGetCrtc(f.handle, encoder.crtc_id) orelse return error.NoEncoder;

    _ = c.drmModeSetCrtc(f.handle, crtc.crtc_id, 0, 0, 0, &connector.connector_id, 1, preferred_mode);

    const ret = try alloc.create(Drm);
    ret.* = .{
        .crtc_id = crtc.crtc_id,
        .dri_file = f,
        .connector_id = connector.connector_id,
        .preferred_mode = preferred_mode,
    };

    return .{
        .ctx = ret,
        .event_fd = f.handle,
        .vtable = &.{
            .displayBuffer = displayBuffer,
            .service = service,
        },
    };
}

fn service(ctx: ?*anyopaque, fd: std.posix.fd_t) !void {
    _ = fd;
    const self: *Drm = @ptrCast(@alignCast(ctx));
    var evctx = c.drmEventContext{
        .version = 2,
        .page_flip_handler = pageFlipHandler,
    };
    _ = c.drmHandleEvent(self.dri_file.handle, &evctx);
}

fn displayBuffer(ctx: ?*anyopaque, buffer: rendering.RenderBuffer, locked_flag: *bool) !void {
    const self: *Drm = @ptrCast(@alignCast(ctx));
    var dri_prime_handle = c.drm_prime_handle{
        .flags = 0,
        .fd = buffer.buf_fd,
        .handle = 0,
    };
    const ret = c.drmIoctl(self.dri_file.handle, c.DRM_IOCTL_PRIME_FD_TO_HANDLE, &dri_prime_handle);
    if (ret < 0) {
        return error.CreateHandle;
    }
    std.debug.print("modifiers: {x}\n", .{buffer.modifiers});

    const plane_res = c.drmModeGetPlaneResources(self.dri_file.handle);
    if (plane_res == null) {
        const errno = std.c._errno();
        std.debug.print("err code: {d}\n", .{errno.*});
        return error.GetPlanes;
    }
    std.debug.print("Foudn {d} planes\n", .{plane_res[0].count_planes});
    for (0..plane_res[0].count_planes) |res_idx| {
        const plane_id = plane_res[0].planes[res_idx];
        const plane = c.drmModeGetPlane(self.dri_file.handle, plane_id);
        for (0..plane[0].count_formats) |i| {
            const as_chars = std.mem.asBytes(&plane[0].formats[i]);
            std.debug.print("{d}: {s}\n", .{ plane_id, as_chars });
        }
    }
    var fb_id: u32 = undefined;
    var handles: [4]u32 = @splat(0);
    var strides: [4]u32 = @splat(0);
    var offsets: [4]u32 = @splat(0);
    var modifierss: [4]u64 = @splat(0);
    handles[0] = dri_prime_handle.handle;
    strides[0] = buffer.stride;
    offsets[0] = buffer.offset;
    modifierss[0] = buffer.modifiers;
    if (c.drmModeAddFB2WithModifiers(self.dri_file.handle, @intCast(buffer.width), @intCast(buffer.height), buffer.format, &handles, &strides, &offsets, &modifierss, &fb_id, c.DRM_MODE_FB_MODIFIERS) != 0) {
        const errno = std.c._errno();
        std.debug.print("err code: {d}\n", .{errno.*});

        if (c.drmModeAddFB2(self.dri_file.handle, @intCast(buffer.width), @intCast(buffer.height), buffer.format, &handles, &strides, &offsets, &fb_id, 0) != 0) {
            std.debug.print("err code: {d}\n", .{errno.*});
            return error.AddFb;
        }
    }

    locked_flag.* = true;
    // FIXME: Err check
    _ = c.drmModePageFlip(self.dri_file.handle, self.crtc_id, fb_id, c.DRM_MODE_PAGE_FLIP_EVENT, locked_flag);
}

fn pageFlipHandler(fd: c_int, frame: c_uint, sec: c_uint, usec: c_uint, data: ?*anyopaque) callconv(.c) void {
    _ = fd;
    _ = frame;
    _ = sec;
    _ = usec;

    std.debug.print("Page flip handler time baybeee\n", .{});
    const page_flip_complete: *bool = @ptrCast(@alignCast(data));
    page_flip_complete.* = true;
}

fn getFirstConnectedConnector(f: std.fs.File, resources: *c.drmModeRes) ?*c.drmModeConnector {
    for (resources.connectors[0..@intCast(resources.count_connectors)]) |connector_id| {
        const connector: *c.drmModeConnector = c.drmModeGetConnectorCurrent(f.handle, connector_id) orelse continue;

        std.debug.print("connector\n", .{});
        if (connector.connection == c.DRM_MODE_CONNECTED) {
            return connector;
        }

        c.drmModeFreeConnector(connector);
    }
    return null;
}

fn getPreferredMode(connector: *c.drmModeConnector) ?*c.drmModeModeInfo {
    for (connector.modes[0..@intCast(connector.count_modes)]) |*mode| {
        if (mode.type & c.DRM_MODE_TYPE_PREFERRED != 0) {
            return mode;
        }
    }
    return null;
}

fn drawRect(data: []u32, stride: usize, x1: usize, y1: usize, x2: usize, y2: usize, color: u32) void {
    const elem_size = @sizeOf(@TypeOf(data[0]));
    std.debug.assert(stride % elem_size == 0);
    for (y1..y2) |y| {
        for (x1..x2) |x| {
            const pix_pos = y * (stride / elem_size) + x;
            data[pix_pos] = color;
        }
    }
}
