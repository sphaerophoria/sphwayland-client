const std = @import("std");
const wlclient = @import("wlclient");
const wlb = @import("wl_bindings");
const system = @import("system.zig");

const BoundInterfaces = struct {
    compositor: wlb.WlCompositor,
    xdg_wm_base: wlb.XdgWmBase,
    decoration_manager: wlb.ZxdgDecorationManagerV1,
    dmabuf: wlb.ZwpLinuxDmabufV1,
};

fn bindInterfaces(client: *wlclient.Client(wlb)) !BoundInterfaces {
    var it = client.eventIt();
    try it.retrieveEvents();

    var compositor: ?wlb.WlCompositor = null;
    var xdg_wm_base: ?wlb.XdgWmBase = null;
    var decoration_manager: ?wlb.ZxdgDecorationManagerV1 = null;
    var dmabuf: ?wlb.ZwpLinuxDmabufV1 = null;

    while (try it.getAvailableEvent()) |event| {
        switch (event.event) {
            .wl_display => |parsed| {
                switch (parsed) {
                    .err => |err| wlclient.logWaylandErr(err),
                    .delete_id => {
                        std.log.warn("Unexpected delete object in binding stage", .{});
                    },
                }
            },
            .wl_registry => |action| {
                switch (action) {
                    .global => |g| blk: {
                        const DesiredInterfaces = enum {
                            wl_compositor,
                            xdg_wm_base,
                            zxdg_decoration_manager_v1,
                            zwp_linux_dmabuf_v1,
                        };

                        const interface_name = std.meta.stringToEnum(DesiredInterfaces, g.interface) orelse {
                            std.log.debug("Unused interface {s}", .{g.interface});
                            break :blk;
                        };

                        switch (interface_name) {
                            .wl_compositor => compositor = try client.bind(wlb.WlCompositor, g),
                            .xdg_wm_base => xdg_wm_base = try client.bind(wlb.XdgWmBase, g),
                            .zxdg_decoration_manager_v1 => decoration_manager = try client.bind(wlb.ZxdgDecorationManagerV1, g),
                            .zwp_linux_dmabuf_v1 => dmabuf = try client.bind(wlb.ZwpLinuxDmabufV1, g),
                        }
                    },
                    .global_remove => {
                        std.log.warn("No registry to remove from", .{});
                    },
                }
            },
            else => wlclient.logUnusedEvent(event.event),
        }
    }

    return .{
        .compositor = compositor orelse return error.NoCompositor,
        .xdg_wm_base = xdg_wm_base orelse return error.NoXdgWmBase,
        .decoration_manager = decoration_manager orelse return error.DecorationManager,
        .dmabuf = dmabuf orelse return error.NoDmaBuf,
    };
}


fn resolveDriHandleFromDevt(alloc: std.mem.Allocator, val_opt: ?u64) ![]const u8 {
    const default_card = "/dev/dri/card0";
    const val = val_opt orelse {
        std.log.warn("No GPU provided by compositor, using default", .{});
        return default_card;
    };

    var dir = try std.fs.openDirAbsolute("/dev/dri", .{ .iterate = true } );
    defer dir.close();

    var it = dir.iterate();

    while (try it.next()) |entry|{
        const stat = try std.posix.fstatat(dir.fd, entry.name, 0);
        if (stat.rdev == val) {
            return try std.fs.path.join(alloc, &.{"/dev/dri", entry.name});
        }
    }

    std.log.warn("Could not find render handle, returning default", .{});
    return default_card;
}

fn registerForDmaBufFeedback(alloc: std.mem.Allocator, client: *wlclient.Client(wlb)) ![]const u8 {
    var it = client.eventIt();
    try it.retrieveEvents();

    var main_device_dev_t: ?u64 = null;

    while (try it.getAvailableEvent()) |event| switch (event.event) {
        .zwp_linux_dmabuf_feedback_v1 => |feedback| switch (feedback) {
            .main_device => |device| {
                std.debug.print("Got main device {any}\n", .{device.device});
                main_device_dev_t = std.mem.bytesToValue(u64, device.device);
            },
            else => wlclient.logUnusedEvent(event.event),
        },
        else => wlclient.logUnusedEvent(event.event),
    };

    return try resolveDriHandleFromDevt(alloc, main_device_dev_t);
}

pub const Window = struct {
    egl_ctx: system.EglContext,
    gbm_ctx: system.GbmContext,

    compositor: wlb.WlCompositor,
    xdg_wm_base: wlb.XdgWmBase,
    wl_surface: wlb.WlSurface,
    xdg_surface: wlb.XdgSurface,
    dmabuf: wlb.ZwpLinuxDmabufV1,
    client: wlclient.Client(wlb),
    frame_callback: wlb.WlCallback,

    compositor_owned_buffers: std.AutoHashMap(u32, system.GbmContext.Buffer),
    wants_frame: bool = false,

    pub fn init(alloc: std.mem.Allocator) !Window {
        var client = try wlclient.Client(wlb).init(alloc);
        errdefer client.deinit();

        const writer = client.writer();

        const bound_interfaces = try bindInterfaces(&client);

        const surface_feedback = try client.newId(wlb.ZwpLinuxDmabufFeedbackV1);
        try bound_interfaces.dmabuf.getDefaultFeedback(writer, .{
            .id = surface_feedback.id,
        });

        var desired_gpu_device_buf: [4096]u8 = undefined;
        var desired_gpu_alloc = std.heap.FixedBufferAllocator.init(&desired_gpu_device_buf);
        const desired_gpu_device = try registerForDmaBufFeedback(desired_gpu_alloc.allocator(), &client);

        var gbm_context = try system.GbmContext.init(640, 480, desired_gpu_device);
        errdefer gbm_context.deinit();

        var egl_context = try system.EglContext.init(alloc, gbm_context);
        errdefer egl_context.deinit();

        const wl_surface = try client.newId(wlb.WlSurface);
        try bound_interfaces.compositor.createSurface(writer, .{
            .id = wl_surface.id,
        });

        const xdg_surface = try client.newId(wlb.XdgSurface);
        try bound_interfaces.xdg_wm_base.getXdgSurface(writer, .{
            .id = xdg_surface.id,
            .surface = wl_surface.id,
        });

        const toplevel = try client.newId(wlb.XdgToplevel);
        try xdg_surface.getToplevel(writer, .{ .id = toplevel.id });
        try toplevel.setAppId(writer, .{ .app_id = "sphwayland-client" });
        try toplevel.setTitle(writer, .{ .title = "sphwayland client" });

        const toplevel_decoration = try client.newId(wlb.ZxdgToplevelDecorationV1);
        try bound_interfaces.decoration_manager.getToplevelDecoration(writer, .{
            .id = toplevel_decoration.id,
            .toplevel = toplevel.id,
        });

        try wl_surface.commit(writer, .{});

        const frame_callback = try client.newId(wlb.WlCallback);
        try wl_surface.frame(writer, .{
            .callback = frame_callback.id,
        });

        return .{
            .egl_ctx = egl_context,
            .gbm_ctx = gbm_context,
            .compositor = bound_interfaces.compositor,
            .xdg_wm_base = bound_interfaces.xdg_wm_base,
            .dmabuf = bound_interfaces.dmabuf,
            .wl_surface = wl_surface,
            .xdg_surface = xdg_surface,
            .frame_callback = frame_callback,
            .client = client,
            .compositor_owned_buffers = .init(alloc),
        };
    }

    pub fn deinit(self: *Window) void {
        self.compositor_owned_buffers.deinit();
        self.egl_ctx.deinit();
        self.gbm_ctx.deinit();
        self.client.deinit();
    }

    pub fn service(self: *Window) !bool {
        var it = self.client.eventIt();
        while (try it.getAvailableEvent()) |event| {
            if (try self.handleEvent(event)) {
                return true;
            }
        }
        return false;
    }

    pub fn wait(self: *Window) !void {
        var it = self.client.eventIt();
        try it.wait();
    }

    const Size = struct {
        width: i32,
        height: i32,
    };

    pub fn getSize(self: *Window) !Size {
        return .{
            .width = try self.egl_ctx.getWidth(),
            .height = try self.egl_ctx.getHeight(),
        };
    }

    pub fn wantsFrame(self: *Window) bool {
        return self.wants_frame;
    }

    fn addBufferObjectToBufParams(
        self: *Window,
        alloc: std.mem.Allocator,
        front_buf: system.GbmContext.Buffer,
        params: wlb.ZwpLinuxBufferParamsV1,
    ) !void {
        var add_writer = std.Io.Writer.Allocating.init(alloc);
        defer add_writer.deinit();

        const modifier = front_buf.modifier();
        try params.add(&add_writer.writer, .{
            // Out of band
            .fd = {},
            .plane_idx = 0, // assumed single plane
            .offset = front_buf.offset(),
            .stride = front_buf.stride(),
            .modifier_hi = @truncate(modifier >> 32),
            .modifier_lo = @truncate(modifier),
        });

        const buf_fd = front_buf.fd();
        try wlclient.sendMessageWithFdAttachment(
            self.client.stream,
            add_writer.written(),
            @bitCast(buf_fd),
        );
        std.posix.close(buf_fd);
    }

    pub fn swapBuffers(self: *Window, alloc: std.mem.Allocator) !void {
        try self.egl_ctx.swapBuffers();

        const front_buf = try self.gbm_ctx.lockFront();

        // front buffer is owned by us until it is committed to a
        // wl_surface, then it is owned by the compositor
        errdefer self.gbm_ctx.unlock(front_buf);

        const params = try self.client.newId(wlb.ZwpLinuxBufferParamsV1);
        try self.dmabuf.createParams(self.client.writer(), .{
            .params_id = params.id,
        });

        try self.addBufferObjectToBufParams(alloc, front_buf, params);

        const wl_buf = try self.client.newId(wlb.WlBuffer);
        try params.createImmed(self.client.writer(), .{
            .buffer_id = wl_buf.id,
            .width = std.math.cast(i32, front_buf.width()) orelse return error.InvalidWidth,
            .height = std.math.cast(i32, front_buf.height()) orelse return error.InvalidHeight,
            .format = front_buf.format(),
            .flags = 0,
        });

        try self.wl_surface.attach(self.client.writer(), .{
            .buffer = wl_buf.id,
            .x = 0,
            .y = 0,
        });

        try self.wl_surface.damageBuffer(self.client.writer(), .{
            .x = 0,
            .y = 0,
            .width = std.math.maxInt(i32),
            .height = std.math.maxInt(i32),
        });

        try self.compositor_owned_buffers.put(wl_buf.id, front_buf);
        errdefer _ = self.compositor_owned_buffers.remove(wl_buf.id);

        try self.wl_surface.commit(self.client.writer(), .{});

        // Commit has to be the last failable call in this scope, or a bunch of
        // errdefers will be incorrect

        errdefer comptime unreachable;

        self.wants_frame = false;
    }

    fn handleEvent(self: *Window, event: wlclient.Event(wlb)) !bool {
        switch (event.event) {
            .wl_display => |parsed| {
                switch (parsed) {
                    .err => |err| wlclient.logWaylandErr(err),
                    .delete_id => |req| {
                        if (req.id == self.frame_callback.id) {
                            try self.wl_surface.frame(self.client.writer(), .{ .callback = self.frame_callback.id });
                            try self.wl_surface.commit(self.client.writer(), .{});
                        } else {
                            std.log.warn("Deletion of object {d} is not handled", .{req.id});
                        }
                    },
                }
            },
            .xdg_surface => |parsed| {
                try self.xdg_surface.ackConfigure(self.client.writer(), .{
                    .serial = parsed.configure.serial,
                });

                self.wants_frame = true;
            },
            .xdg_wm_base => |parsed| {
                try self.xdg_wm_base.pong(self.client.writer(), .{
                    .serial = parsed.ping.serial,
                });
            },
            .xdg_toplevel => |parsed| {
                switch (parsed) {
                    .close => {
                        return true;
                    },
                    else => {
                        std.log.debug("Unhandled toplevel event {any}", .{parsed});
                    },
                }
            },
            .wl_callback => |parsed| {
                //std.debug.assert(self.frame_callback.id == event.header.id);
                std.debug.assert(parsed == .done);

                self.wants_frame = true;
            },
            .wl_buffer => |parsed| {
                switch (parsed) {
                    .release => blk: {
                        const gbm_handle = self.compositor_owned_buffers.get(event.object_id) orelse {
                            std.log.err("Got release event for unknown buffer", .{});
                            break :blk;
                        };
                        self.gbm_ctx.unlock(gbm_handle);

                        const iface = wlb.WlBuffer{ .id = event.object_id };
                        try iface.destroy(self.client.writer(), .{});
                    },
                }
            },
            .zwp_linux_buffer_params_v1 => |parsed| {
                switch (parsed) {
                    .created, .failed => {
                        var params = wlb.ZwpLinuxBufferParamsV1{ .id = event.object_id };
                        try params.destroy(self.client.writer(), .{});
                    },
                }
            },
            else => wlclient.logUnusedEvent(event.event),
        }
        return false;
    }
};
