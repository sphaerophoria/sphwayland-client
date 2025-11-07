const std = @import("std");
const sphtud = @import("sphtud");
const CompositorState = @import("../CompositorState.zig");
const c = @cImport({
    @cInclude("xf86drm.h");
    @cInclude("xf86drmMode.h");
});

const rendering = @import("../rendering.zig");
const Drm = @This();
const system_gl = @import("../system_gl.zig");

crtc_id: u32,
dri_file: std.fs.File,
connector_id: u32,
preferred_mode: c.drmModeModeInfo,
crtc_set: bool = false,
outstanding_buffer: ?system_gl.GbmContext.Buffer,

pub fn init(alloc: std.mem.Allocator) !rendering.RenderBackend {
    const best_gpu = try selectBestGPU(alloc);
    std.log.info("Rendering on GPU {s}", .{best_gpu});
    const f = try std.fs.openFileAbsolute(best_gpu, .{
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
        .outstanding_buffer = null,
    };

    return .{
        .preferred_gpu = best_gpu,
        .initial_res = .{
            .width = preferred_mode.hdisplay,
            .height = preferred_mode.vdisplay,
        },
        .ctx = ret,
        .vtable = &.{
            .makeHandler = makeHandler,
            .deinit = deinit,
        },
    };
}

pub fn deinit(ctx: ?*anyopaque) void {
    const self: *Drm = @ptrCast(@alignCast(ctx));
    self.dri_file.close();
}

const Handler = struct {
    parent: *Drm,
    renderer: *rendering.Renderer,

    pub fn close(_: ?*anyopaque) void {}

    fn poll(ctx: ?*anyopaque, _: *sphtud.event.LoopSphalloc, reason: sphtud.event.PollReason) sphtud.event.LoopSphalloc.PollResult {
        const self: *Handler = @ptrCast(@alignCast(ctx));

        self.pollError(reason) catch |e| {
            std.log.err("Failed to poll: {t}", .{e});
            return .in_progress;
        };

        return .in_progress;
    }

    fn pollError(self: *Handler, reason: sphtud.event.PollReason) !void {
        if (reason == .init) {
            // Initial render to kick off vsync loop
            try self.render();
            return;
        }

        var evctx = c.drmEventContext{
            .version = 2,
            .page_flip_handler = pageFlipHandler,
        };
        _ = c.drmHandleEvent(self.parent.dri_file.handle, &evctx);

        if (self.parent.outstanding_buffer == null) {
            try self.render();
        }
    }

    fn render(self: *Handler) !void {
        std.debug.assert(self.parent.outstanding_buffer == null);

        const gbm_buffer = (try self.renderer.render()) orelse return;
        self.parent.outstanding_buffer = gbm_buffer;

        const render_buffer = try rendering.RenderBuffer.fromGbm(gbm_buffer);
        defer render_buffer.deinit();

        const fb_id = try self.parent.fbFromRenderBuffer(render_buffer);

        // Some systems need a valid framebuffer on first crtc set. We could do an
        // initial render before initializing DRM, but the rest of the codebase is
        // simpler if we just lazily initialize on the first render call
        if (!self.parent.crtc_set) {
            try drmErrCheck(
                c.drmModeSetCrtc(
                    self.parent.dri_file.handle,
                    self.parent.crtc_id,
                    fb_id,
                    0,
                    0,
                    &self.parent.connector_id,
                    1,
                    &self.parent.preferred_mode,
                ),
                error.SetMode,
            );
            self.parent.crtc_set = true;
        }

        try drmErrCheck(
            c.drmModePageFlip(
                self.parent.dri_file.handle,
                self.parent.crtc_id,
                fb_id,
                c.DRM_MODE_PAGE_FLIP_EVENT,
                self,
            ),
            error.PageFlip,
        );
    }
};

fn makeHandler(ctx: ?*anyopaque, alloc: std.mem.Allocator, renderer: *rendering.Renderer) !sphtud.event.LoopSphalloc.Handler {
    const self: *Drm = @ptrCast(@alignCast(ctx));

    const handler_ctx = try alloc.create(Handler);
    handler_ctx.* = .{
        .parent = self,
        .renderer = renderer,
    };

    return .{
        .desired_events = .{
            .read = true,
            .write = false,
        },
        .fd = self.dri_file.handle,
        .ptr = handler_ctx,
        .vtable = &.{
            .poll = Handler.poll,
            .close = Handler.close,
        },
    };
}

fn drmErrCheck(rc: c_int, on_err: anyerror) !void {
    if (rc != 0) {
        const errno = std.c._errno();
        std.log.err("drm returning {t} due to {d}", .{ on_err, errno.* });
        return on_err;
    }
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

    if (ret == 0) {
        return fb_id;
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
    const handler: *Handler = @ptrCast(@alignCast(data));
    const to_release = handler.parent.outstanding_buffer.?;
    handler.renderer.releaseBuffer(to_release);
    handler.parent.outstanding_buffer = null;
}

fn getFirstConnectedConnector(f: std.fs.File, resources: *c.drmModeRes) ?*c.drmModeConnector {
    for (resources.connectors[0..@intCast(resources.count_connectors)]) |connector_id| {
        const connector: *c.drmModeConnector = c.drmModeGetConnector(f.handle, connector_id) orelse continue;

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

const GPUSelectionInfo = struct {
    path: []const u8 = "",
    num_internal_displays: usize = 0,
    num_external_displays: usize = 0,
    num_display_ports: usize = 0,

    fn fromFile(path: []const u8, f: std.fs.File) !GPUSelectionInfo {
        const resources: *c.drmModeRes = c.drmModeGetResources(f.handle) orelse return error.GetResourcers;
        defer c.drmModeFreeResources(resources);

        var count_internal_displays: usize = 0;
        var count_external_displays: usize = 0;
        var count_display_ports: usize = 0;

        for (resources.connectors[0..@intCast(resources.count_connectors)]) |connector_id| {
            const connector: *c.drmModeConnector = c.drmModeGetConnectorCurrent(f.handle, connector_id) orelse {
                std.log.warn("Failed to get connector properties for connector {d}", .{connector_id});
                continue;
            };
            defer c.drmModeFreeConnector(connector);

            if (connector.connection != c.DRM_MODE_CONNECTED) continue;

            const is_internal = isInternal(connector.connector_type);
            const is_non_desktop = if (is_internal) false else try isNonDesktop(
                f.handle,
                connector.props[0..@intCast(connector.count_props)],
                connector.prop_values[0..@intCast(connector.count_props)],
            );

            count_internal_displays += if (is_internal) 1 else 0;
            count_external_displays += if (is_non_desktop) 0 else 1;
            count_display_ports += 1;
        }

        return .{
            .path = path,
            .num_internal_displays = count_internal_displays,
            .num_external_displays = count_external_displays,
            .num_display_ports = count_display_ports,
        };
    }

    fn isNonDesktop(handle: std.posix.fd_t, connector_properties: []u32, connector_values: []u64) !bool {
        for (connector_properties, connector_values) |prop_id, val| {
            const prop: *c.drmModePropertyRes = c.drmModeGetProperty(handle, prop_id) orelse return error.NoProperty;
            defer c.drmModeFreeProperty(prop);

            const name = std.mem.span(@as([*c]u8, @ptrCast(&prop.name)));
            if (std.mem.eql(u8, name, "non-desktop")) {
                return val > 0;
            }
        }

        return false;
    }

    fn isInternal(connector_type: u32) bool {
        // Fully stolen from kwin :)
        return connector_type == c.DRM_MODE_CONNECTOR_LVDS or connector_type == c.DRM_MODE_CONNECTOR_eDP or connector_type == c.DRM_MODE_CONNECTOR_DSI;
    }

    fn otherIsBetter(self: GPUSelectionInfo, other: GPUSelectionInfo) bool {
        if (other.num_internal_displays != self.num_internal_displays) {
            std.log.debug("{s} has more internal displays than {s}", .{ other.path, self.path });
            return other.num_internal_displays > self.num_internal_displays;
        }
        if (other.num_external_displays != self.num_external_displays) {
            std.log.debug("{s} has more external displays than {s}", .{ other.path, self.path });
            return other.num_external_displays > self.num_external_displays;
        }

        const ret = self.num_display_ports > other.num_display_ports;
        if (ret) {
            std.log.debug("{s} has more ports than {s}", .{ other.path, self.path });
        }
        return ret;
    }
};

fn selectBestGPU(alloc: std.mem.Allocator) ![]const u8 {
    var dir = try std.fs.openDirAbsolute("/dev/dri", .{ .iterate = true });
    defer dir.close();

    var best = GPUSelectionInfo{};

    var it = dir.iterate();
    while (try it.next()) |entry| {
        if (entry.kind != .character_device) continue;
        const f = try dir.openFile(entry.name, .{ .mode = .read_write });
        defer f.close();

        const entry_info = GPUSelectionInfo.fromFile(entry.name, f) catch |e| {
            std.log.warn("Failed to get GPU info for {s} ({t}), skipping\n", .{ entry.name, e });
            continue;
        };
        if (best.otherIsBetter(entry_info)) {
            best = entry_info;
        }
    }

    return try std.fs.path.join(alloc, &.{ "/dev/dri", best.path });
}
