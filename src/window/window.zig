const std = @import("std");
const wlclient = @import("wlclient");
const wlb = @import("wl_bindings");
const system = @import("system.zig");
const c = @cImport({
    @cInclude("linux/input-event-codes.h");
});

const BoundInterfaces = struct {
    compositor: wlb.WlCompositor,
    xdg_wm_base: wlb.XdgWmBase,
    decoration_manager: wlb.ZxdgDecorationManagerV1,
    dmabuf: wlb.ZwpLinuxDmabufV1,
    wl_seat: wlb.WlSeat,
};

fn bindInterfaces(client: *wlclient.Client(wlb)) !BoundInterfaces {
    var it = client.eventIt();
    try it.retrieveEvents();

    var compositor: ?wlb.WlCompositor = null;
    var xdg_wm_base: ?wlb.XdgWmBase = null;
    var decoration_manager: ?wlb.ZxdgDecorationManagerV1 = null;
    var dmabuf: ?wlb.ZwpLinuxDmabufV1 = null;
    var wl_seat: ?wlb.WlSeat = null;

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
                            wl_seat,
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
                            .wl_seat => wl_seat = try client.bind(wlb.WlSeat, g),
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
        .wl_seat = wl_seat orelse return error.NoWlSeat,
    };
}

fn resolveDriHandleFromDevt(alloc: std.mem.Allocator, val_opt: ?u64) ![]const u8 {
    const default_card = "/dev/dri/card0";
    const val = val_opt orelse {
        std.log.warn("No GPU provided by compositor, using default", .{});
        return default_card;
    };

    var dir = try std.fs.openDirAbsolute("/dev/dri", .{ .iterate = true });
    defer dir.close();

    var it = dir.iterate();

    while (try it.next()) |entry| {
        const stat = try std.posix.fstatat(dir.fd, entry.name, 0);
        if (stat.rdev == val) {
            return try std.fs.path.join(alloc, &.{ "/dev/dri", entry.name });
        }
    }

    std.log.warn("Could not find render handle, returning default", .{});
    return default_card;
}

fn registerForDmaBufFeedback(client: *wlclient.Client(wlb)) !?u64 {
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

    return main_device_dev_t;
}

pub const DefaultGlContext = struct {
    egl_ctx: system.EglContext,
    gbm_ctx: system.GbmContext,
    compositor_owned_buffers: std.AutoHashMap(u32, system.GbmContext.Buffer),

    pub fn init(alloc: std.mem.Allocator, initial_width: u32, initial_height: u32, device: []const u8) !DefaultGlContext {
        var gbm_ctx = try system.GbmContext.init(initial_width, initial_height, device);
        errdefer gbm_ctx.deinit();

        const egl_ctx = try system.EglContext.init(alloc, gbm_ctx);

        return .{
            .egl_ctx = egl_ctx,
            .gbm_ctx = gbm_ctx,
            .compositor_owned_buffers = .init(alloc),
        };
    }

    pub fn deinit(self: *DefaultGlContext) void {
        self.egl_ctx.deinit();
        self.gbm_ctx.deinit();
        self.compositor_owned_buffers.deinit();
    }

    pub const Size = struct {
        width: i32,
        height: i32,
    };

    pub fn getSize(self: *DefaultGlContext) !Size {
        return .{
            .width = try self.egl_ctx.getWidth(),
            .height = try self.egl_ctx.getHeight(),
        };
    }

    pub fn swapBuffers(self: *DefaultGlContext, window: *Window) !void {
        try self.egl_ctx.swapBuffers();

        const front_buf = try self.gbm_ctx.lockFront();

        // front buffer is owned by us until it is committed to a
        // wl_surface, then it is owned by the compositor
        errdefer self.gbm_ctx.unlock(front_buf);

        const buffer = try RenderBuffer.fromGbm(front_buf);
        defer std.posix.close(buffer.fd);

        const wl_buf_id = try window.swapBuffers(buffer);
        try self.compositor_owned_buffers.put(wl_buf_id, front_buf);
    }

    pub fn notifyGlBufferRelease(self: *DefaultGlContext, buf_id: u32) void {
        const gbm_handle = self.compositor_owned_buffers.fetchRemove(buf_id) orelse {
            std.log.err("Got release event for unknown buffer", .{});
            return;
        };

        self.gbm_ctx.unlock(gbm_handle.value);
    }
};

const NullGlCtx = struct {
    pub fn notifyGlBufferRelease(_: NullGlCtx, _: u32) void {}
};

pub const RenderBuffer = struct {
    fd: c_int,
    offset: u32,
    stride: u32,
    modifier: u64,
    width: u32,
    height: u32,
    format: u32,

    fn fromGbm(gbm_buf: system.GbmContext.Buffer) !RenderBuffer {
        return .{
            .fd = gbm_buf.fd(),
            .offset = gbm_buf.offset(),
            .stride = gbm_buf.stride(),
            .modifier = gbm_buf.modifier(),
            .width = gbm_buf.width(),
            .height = gbm_buf.height(),
            .format = gbm_buf.format(),
        };
    }
};

pub const Window = struct {
    compositor: wlb.WlCompositor,
    xdg_wm_base: wlb.XdgWmBase,
    wl_surface: wlb.WlSurface,
    wl_seat: wlb.WlSeat,
    xdg_surface: wlb.XdgSurface,
    dmabuf: wlb.ZwpLinuxDmabufV1,
    client: wlclient.Client(wlb),
    frame_callback: wlb.WlCallback,
    wl_pointer: wlb.WlPointer,

    wants_frame: bool = false,

    alloc: std.mem.Allocator,
    input_events: std.ArrayList(InputEvent) = .{},
    pending_input_events: std.ArrayList(InputEvent) = .{},

    preferred_gpu: ?u64,

    const InputEvent = union(enum) {
        pointer_movement: PointerPos,
        mouse1_down,
        mouse1_up,
    };

    const FormatTableItem = packed struct {
        format: u32,
        padding: u32,
        modifier: u64,
    };

    const FormatModifierPair = struct { format: u32, modifier: u64 };
    pub const PointerPos = struct {
        x: f32,
        y: f32,
    };

    pub fn init(alloc: std.mem.Allocator) !Window {
        var client = try wlclient.Client(wlb).init(alloc);
        errdefer client.deinit();

        const writer = client.writer();

        const bound_interfaces = try bindInterfaces(&client);

        const wl_pointer = try client.newId(wlb.WlPointer);
        try bound_interfaces.wl_seat.getPointer(writer, .{
            .id = wl_pointer.id,
        });

        const surface_feedback = try client.newId(wlb.ZwpLinuxDmabufFeedbackV1);
        try bound_interfaces.dmabuf.getDefaultFeedback(writer, .{
            .id = surface_feedback.id,
        });

        const preferred_gpu = try registerForDmaBufFeedback(&client);

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

        var ret = Window{
            .compositor = bound_interfaces.compositor,
            .xdg_wm_base = bound_interfaces.xdg_wm_base,
            .dmabuf = bound_interfaces.dmabuf,
            .wl_surface = wl_surface,
            .wl_seat = bound_interfaces.wl_seat,
            .xdg_surface = xdg_surface,
            .wl_pointer = wl_pointer,
            .frame_callback = frame_callback,
            .client = client,
            .preferred_gpu = preferred_gpu,

            .alloc = alloc,
            .input_events = .{},
            .pending_input_events = .{},
        };
        errdefer ret.deinit();

        try ret.wait();
        // On init, we should not have any outstanding gl buffers, so no
        // state to manage
        if (try ret.service(NullGlCtx{})) return error.Shutdown;

        return ret;
    }

    pub fn deinit(self: *Window) void {
        self.client.deinit();
        self.input_events.deinit(self.alloc);
        self.pending_input_events.deinit(self.alloc);
    }

    // By default users will use DefaultGlCtx above, but some users of this
    // library want to manage their own OpenGL context (e.g. sphwim within this
    // repo). Allow any type that has notifyGlBufferRelease to be used to
    // support this case
    pub fn service(self: *Window, gl_ctx: anytype) !bool {
        var it = self.client.eventIt();

        self.clearInputEvents();

        while (try it.getAvailableEvent()) |event| {
            if (try self.handleEvent(event, gl_ctx)) {
                return true;
            }
        }
        return false;
    }

    pub fn getFd(self: Window) std.posix.fd_t {
        return self.client.stream.handle;
    }

    pub fn getPreferredGpu(self: Window, alloc: std.mem.Allocator) ![]const u8 {
        return resolveDriHandleFromDevt(alloc, self.preferred_gpu);
    }

    pub fn wait(self: *Window) !void {
        var it = self.client.eventIt();
        try it.wait();
    }

    pub fn wantsFrame(self: *Window) bool {
        return self.wants_frame;
    }

    fn addBufferObjectToBufParams(
        self: *Window,
        front_buf: RenderBuffer,
        params: wlb.ZwpLinuxBufferParamsV1,
    ) !void {
        // 5 uints, a fd, and a header should be ~36 bytes? Maybe a little
        // more. 128 is plenty
        var writer_buf: [128]u8 = undefined;
        var add_writer = std.Io.Writer.fixed(&writer_buf);

        const modifier = front_buf.modifier;
        try params.add(&add_writer, .{
            // Out of band
            .fd = {},
            .plane_idx = 0, // assumed single plane
            .offset = front_buf.offset,
            .stride = front_buf.stride,
            .modifier_hi = @truncate(modifier >> 32),
            .modifier_lo = @truncate(modifier),
        });

        const buf_fd = front_buf.fd;
        try wlclient.sendMessageWithFdAttachment(
            self.client.stream,
            add_writer.buffered(),
            @bitCast(buf_fd),
        );
    }

    pub fn swapBuffers(self: *Window, front_buf: RenderBuffer) !u32 {
        const params = try self.client.newId(wlb.ZwpLinuxBufferParamsV1);
        try self.dmabuf.createParams(self.client.writer(), .{
            .params_id = params.id,
        });

        try self.addBufferObjectToBufParams(front_buf, params);

        const wl_buf = try self.client.newId(wlb.WlBuffer);
        try params.createImmed(self.client.writer(), .{
            .buffer_id = wl_buf.id,
            .width = std.math.cast(i32, front_buf.width) orelse return error.InvalidWidth,
            .height = std.math.cast(i32, front_buf.height) orelse return error.InvalidHeight,
            .format = front_buf.format,
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

        try self.wl_surface.commit(self.client.writer(), .{});

        // Commit has to be the last failable call in this scope, or a bunch of
        // errdefers will be incorrect

        errdefer comptime unreachable;

        self.wants_frame = false;
        return wl_buf.id;
    }

    fn handleEvent(self: *Window, event: wlclient.Event(wlb), gl_ctx: anytype) !bool {
        switch (event.event) {
            .wl_display => |parsed| {
                switch (parsed) {
                    .err => |err| wlclient.logWaylandErr(err),
                    .delete_id => |req| {
                        if (req.id == self.frame_callback.id) {
                            try self.wl_surface.frame(self.client.writer(), .{ .callback = self.frame_callback.id });
                            try self.wl_surface.commit(self.client.writer(), .{});
                        } else {
                            self.client.interfaces.remove(req.id);
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
                    .release => {
                        const iface = wlb.WlBuffer{ .id = event.object_id };
                        try iface.destroy(self.client.writer(), .{});

                        gl_ctx.notifyGlBufferRelease(event.object_id);
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
            .wl_pointer => |parsed| switch (parsed) {
                .frame => {
                    try self.input_events.appendSlice(self.alloc, self.pending_input_events.items);
                    self.pending_input_events.clearRetainingCapacity();
                },
                .motion => |params| {
                    const pointer_update = InputEvent{ .pointer_movement = .{
                        .x = params.surface_x.tof32(),
                        .y = params.surface_y.tof32(),
                    } };
                    try self.pending_input_events.append(self.alloc, pointer_update);
                },
                .button => |params| {
                    if (params.button == c.BTN_LEFT) {
                        const input_event: InputEvent = switch (params.state) {
                            0 => InputEvent.mouse1_up,
                            1 => InputEvent.mouse1_down,
                            else => unreachable,
                        };
                        try self.pending_input_events.append(self.alloc, input_event);
                    }
                },
                else => wlclient.logUnusedEvent(event.event),
            },
            else => wlclient.logUnusedEvent(event.event),
        }
        return false;
    }

    pub fn inputEvents(self: Window) []InputEvent {
        return self.input_events.items;
    }

    fn clearInputEvents(self: *Window) void {
        self.input_events = .{};
    }
};
