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
preferred_mode: c.drmModeModeInfo,
crtc_set: bool = false,

pub fn init(alloc: std.mem.Allocator) !rendering.RenderBackend {
    const f = try std.fs.openFileAbsolute("/dev/dri/card0", .{
        .mode = .read_write,
    });

    const resources: *c.drmModeRes = c.drmModeGetResources(f.handle) orelse return error.GetResourcers;
    defer c.drmModeFreeResources(resources);

    const connector = getFirstConnectedConnector(f, resources) orelse return error.NoConnector;
    defer c.drmModeFreeConnector(connector);

    // References connector memory
    const preferred_mode = getPreferredMode(connector) orelse return error.NoMode;

    const encoder: *c.drmModeEncoder = c.drmModeGetEncoder(f.handle, connector.encoder_id) orelse return error.NoEncoder;
    defer c.drmModeFreeEncoder(encoder);

    const crtc: *c.drmModeCrtc = c.drmModeGetCrtc(f.handle, encoder.crtc_id) orelse return error.NoEncoder;
    defer c.drmModeFreeCrtc(crtc);

    try drmErrCheck(c.drmSetMaster(f.handle), error.SetMaster);

    try drmErrCheck(
        c.drmModeSetCrtc(f.handle, crtc.crtc_id, 0, 0, 0, 0, 0, 0),
        error.BlankScreen,
    );

    const ret = try alloc.create(Drm);
    ret.* = .{
        .crtc_id = crtc.crtc_id,
        .dri_file = f,
        .connector_id = connector.connector_id,
        .preferred_mode = preferred_mode.*,
    };

    return .{
        .ctx = ret,
        .event_fd = f.handle,
        .vtable = &.{
            .displayBuffer = displayBuffer,
            .currentResolution = currentResolution,
            .service = service,
            .deinit = deinit,
        },
    };
}

pub fn deinit(ctx: ?*anyopaque, _: std.posix.fd_t) void {
    const self: *Drm = @ptrCast(@alignCast(ctx));
    self.dri_file.close();
}

fn drmErrCheck(rc: c_int, on_err: anyerror) !void {
    if (rc != 0) {
        const errno = std.c._errno();
        std.log.err("drm returning {t} due to {d}", .{ on_err, errno.* });
        return on_err;
    }
}

fn service(_: ?*anyopaque, fd: std.posix.fd_t) !void {
    var evctx = c.drmEventContext{
        .version = 2,
        .page_flip_handler = pageFlipHandler,
    };
    _ = c.drmHandleEvent(fd, &evctx);
}

fn displayBuffer(ctx: ?*anyopaque, buffer: rendering.RenderBuffer, locked_flag: *bool) !void {
    const self: *Drm = @ptrCast(@alignCast(ctx));

    const fb_id = try self.fbFromRenderBuffer(buffer);

    // Buffer is on GPU, we are not allowed to delete it :)
    locked_flag.* = true;

    // Some systems need a valid framebuffer on first crtc set. We could do an
    // initial render before initializing DRM, but the rest of the codebase is
    // simpler if we just lazily initialize on the first render call
    if (!self.crtc_set) {
        try drmErrCheck(
            c.drmModeSetCrtc(
                self.dri_file.handle,
                self.crtc_id,
                fb_id,
                0,
                0,
                &self.connector_id,
                1,
                &self.preferred_mode,
            ),
            error.SetMode,
        );
        self.crtc_set = true;
    }

    try drmErrCheck(
        c.drmModePageFlip(
            self.dri_file.handle,
            self.crtc_id,
            fb_id,
            c.DRM_MODE_PAGE_FLIP_EVENT,
            locked_flag,
        ),
        error.PageFlip,
    );
}

fn currentResolution(ctx: ?*anyopaque, _: std.posix.fd_t) !rendering.Resolution {
    const self: *Drm = @ptrCast(@alignCast(ctx));
    return .{
        .width = self.preferred_mode.hdisplay,
        .height = self.preferred_mode.vdisplay,
    };
}

fn fbFromRenderBuffer(self: *Drm, buffer: rendering.RenderBuffer) !u32 {
    var dri_prime_handle = c.drm_prime_handle{
        .flags = 0,
        .fd = buffer.buf_fd,
        .handle = 0,
    };

    try drmErrCheck(
        c.drmIoctl(self.dri_file.handle, c.DRM_IOCTL_PRIME_FD_TO_HANDLE, &dri_prime_handle),
        error.CreateHandle,
    );

    // Is this ok to do here? GEM handle is created, attached to fb, and
    // immediately closed. If the framebuffer holds on in the kernel, closing
    // is NBD. If for some reason the GEM handle has to be valid until we call
    // page flip this will close too early. I suspect it's ok, but haven't
    // confirmed
    defer {
        var gem_close = c.drm_gem_close{
            .handle = dri_prime_handle.handle,
        };

        const ret = c.drmIoctl(self.dri_file.handle, c.DRM_IOCTL_GEM_CLOSE, &gem_close);
        if (ret != 0) {
            std.log.err("Failed to release gem handle: {d}", .{ret});
        }
    }

    var fb_id: u32 = undefined;

    var handles: [4]u32 = @splat(0);
    var strides: [4]u32 = @splat(0);
    var offsets: [4]u32 = @splat(0);
    var modifiers: [4]u64 = @splat(0);

    handles[0] = dri_prime_handle.handle;
    strides[0] = buffer.stride;
    offsets[0] = buffer.offset;
    modifiers[0] = buffer.modifiers;

    // FIXME: If this fails once, it will fail every frame, double syscalling
    // is stupid
    const ret = c.drmModeAddFB2WithModifiers(
        self.dri_file.handle,
        @intCast(buffer.width),
        @intCast(buffer.height),
        buffer.format,
        &handles,
        &strides,
        &offsets,
        &modifiers,
        &fb_id,
        c.DRM_MODE_FB_MODIFIERS,
    );

    if (ret != 0) {
        const errno = std.c._errno();
        std.log.debug("Failed to call fb with modifiers {d}", .{errno.*});
    }

    try drmErrCheck(
        c.drmModeAddFB2(
            self.dri_file.handle,
            @intCast(buffer.width),
            @intCast(buffer.height),
            buffer.format,
            &handles,
            &strides,
            &offsets,
            &fb_id,
            0,
        ),
        error.AddFb,
    );

    return fb_id;
}

fn pageFlipHandler(fd: c_int, frame: c_uint, sec: c_uint, usec: c_uint, data: ?*anyopaque) callconv(.c) void {
    _ = fd;
    _ = frame;
    _ = sec;
    _ = usec;
    const locked: *bool = @ptrCast(@alignCast(data));
    locked.* = false;
}

fn getFirstConnectedConnector(f: std.fs.File, resources: *c.drmModeRes) ?*c.drmModeConnector {
    for (resources.connectors[0..@intCast(resources.count_connectors)]) |connector_id| {
        const connector: *c.drmModeConnector = c.drmModeGetConnectorCurrent(f.handle, connector_id) orelse continue;

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
