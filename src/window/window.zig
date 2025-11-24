const std = @import("std");
const sphtud = @import("sphtud");
const wlclient = @import("wlclient");
const wlb = @import("wl_bindings");
const system = @import("system.zig");
const c = @cImport({
    @cInclude("linux/input-event-codes.h");
    @cInclude("xkbcommon/xkbcommon.h");
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
        defer event.deinit();

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
        return try alloc.dupe(u8, default_card);
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

    pub fn requestResize(self: *DefaultGlContext, width: i32, height: i32) !void {
        if (width == 0 and height == 0) return;

        try self.egl_ctx.updateSurface(null);
        try self.gbm_ctx.updateSurfaceSize(@bitCast(width), @bitCast(height));
        try self.egl_ctx.updateSurface(self.gbm_ctx.surface);
    }
};

const NullGlCtx = struct {
    pub fn notifyGlBufferRelease(_: NullGlCtx, _: u32) void {}

    // Window writes down pending buffer config. If we don't have a opengl
    // context yet, we have no buffer to resize. The initial buffer size can
    // be set according to what is stashed in the Window.pending_surface_info
    pub fn requestResize(_: NullGlCtx, _: i32, _: i32) !void {}
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

pub const Key = struct {
    keycode: u32,
    state: State,
    // FIXME: Pointer to xkbcommon abstraction that doesn't exist yet
    window: *const Window,

    // FIXME: Should this be duplicated from wayland xml?
    const State = enum(u8) {
        released = 0,
        pressed = 1,
        repeated = 2,
    };

    pub fn toUtf8(self: Key, alloc: std.mem.Allocator) ![]const u8 {
        const keymap = self.window.keymap orelse return error.NoKeymap;
        const len = c.xkb_state_key_get_utf8(keymap.state, self.keycode, null, 0);
        if (len < 0) {
            return error.InvalidKey;
        }

        // Need one byte for null even though we don't want it :(
        const ret = try alloc.alloc(u8, @intCast(len + 1));
        const err = c.xkb_state_key_get_utf8(keymap.state, self.keycode, ret.ptr, ret.len);
        if (err != len) return error.InvalidKey;
        return ret[0 .. ret.len - 1];
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
    wl_keyboard: wlb.WlKeyboard,

    // FIXME: Surely this needs an abstraction somewhere...
    // FIXME: These need to be freed ding dong
    xkb: *c.xkb_context,
    keymap: ?struct {
        keymap: *c.xkb_keymap,
        state: *c.xkb_state,
    },

    first_configure: bool = true,
    wants_frame: bool = false,

    format_info: struct {
        pending: struct {
            mapped_formats: []const FormatTableItem = &.{},

            // Buffer here as a setting cannot be observed until atomically
            // committed with done()
            preferred_gpu: ?u64 = null,
            preferred_format: ?FormatModifierPair = null,
        } = .{},

        preferred_gpu: ?u64 = null,
        preferred_format: ?FormatModifierPair = null,
    },

    pending_surface_info: struct {
        width: i32 = 0,
        height: i32 = 0,
    },

    alloc: sphtud.util.ExpansionAlloc,
    input_events: sphtud.util.RuntimeSegmentedListUnmanaged(InputEvent),
    pending_input_events: sphtud.util.RuntimeSegmentedListUnmanaged(InputEvent),

    const InputEvent = union(enum) {
        pointer_movement: PointerPos,
        key: Key,
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

    pub fn init(arena: std.mem.Allocator, expansion_alloc: sphtud.util.ExpansionAlloc) !Window {
        var client = try wlclient.Client(wlb).init(arena, expansion_alloc);
        errdefer client.deinit();

        const writer = client.writer();

        const bound_interfaces = try bindInterfaces(&client);

        const xkb_context: *c.xkb_context = c.xkb_context_new(0) orelse return error.XkbInit;
        errdefer c.xkb_context_unref(xkb_context);

        const wl_pointer = try client.newId(wlb.WlPointer);
        try bound_interfaces.wl_seat.getPointer(writer, .{
            .id = wl_pointer.id,
        });

        const wl_keyboard = try client.newId(wlb.WlKeyboard);
        try bound_interfaces.wl_seat.getKeyboard(writer, .{
            .id = wl_keyboard.id,
        });

        const surface_feedback = try client.newId(wlb.ZwpLinuxDmabufFeedbackV1);
        try bound_interfaces.dmabuf.getDefaultFeedback(writer, .{
            .id = surface_feedback.id,
        });

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

        const typical_input_events = 24;
        const max_input_events = 1024;

        var ret = Window{
            .compositor = bound_interfaces.compositor,
            .xdg_wm_base = bound_interfaces.xdg_wm_base,
            .dmabuf = bound_interfaces.dmabuf,
            .wl_surface = wl_surface,
            .wl_seat = bound_interfaces.wl_seat,
            .xdg_surface = xdg_surface,
            .wl_pointer = wl_pointer,
            .wl_keyboard = wl_keyboard,
            .xkb = xkb_context,
            .keymap = null,
            .frame_callback = frame_callback,
            .client = client,
            .alloc = expansion_alloc,
            .input_events = try .init(arena, expansion_alloc, typical_input_events, max_input_events),
            .pending_input_events = try .init(arena, expansion_alloc, typical_input_events, max_input_events),
            .pending_surface_info = .{},
            .format_info = .{},
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
    }

    // By default users will use DefaultGlCtx above, but some users of this
    // library want to manage their own OpenGL context (e.g. sphwim within this
    // repo). Allow any type that has notifyGlBufferRelease to be used to
    // support this case
    pub fn service(self: *Window, gl_ctx: anytype) !bool {
        var it = self.client.eventIt();

        self.clearInputEvents();

        while (try it.getAvailableEvent()) |event| {
            defer event.deinit();

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
        return resolveDriHandleFromDevt(alloc, self.format_info.preferred_gpu);
    }

    pub fn getPreferredFormat(self: Window) ?FormatModifierPair {
        return self.format_info.preferred_format;
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

        try params.destroy(self.client.writer(), .{});
        self.client.removeId(params.id);

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
            .xdg_surface => |parsed| switch (parsed) {
                .configure => |params| {
                    try self.xdg_surface.ackConfigure(self.client.writer(), .{
                        .serial = params.serial,
                    });

                    try gl_ctx.requestResize(self.pending_surface_info.width, self.pending_surface_info.height);

                    if (self.first_configure) {
                        self.first_configure = false;
                        self.wants_frame = true;
                    }
                },
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
                    .configure => |params| {
                        self.pending_surface_info.width = params.width;
                        self.pending_surface_info.height = params.height;
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

                        self.client.removeId(event.object_id);

                        gl_ctx.notifyGlBufferRelease(event.object_id);
                    },
                }
            },
            .zwp_linux_buffer_params_v1 => |parsed| {
                switch (parsed) {
                    .created, .failed => {
                        var params = wlb.ZwpLinuxBufferParamsV1{ .id = event.object_id };
                        try params.destroy(self.client.writer(), .{});

                        self.client.removeId(event.object_id);
                    },
                }
            },
            .wl_pointer => |parsed| switch (parsed) {
                .frame => {
                    var block_it = self.pending_input_events.blockIter();
                    while (block_it.next()) |block| {
                        try self.input_events.appendSlice(self.alloc, block);
                    }
                    self.pending_input_events.clear(self.alloc);
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
            .wl_keyboard => |parsed| switch (parsed) {
                .keymap => |params| blk: {
                    switch (params.format) {
                        // FIXME: Parse enum correctly ding dong
                        0 => {
                            break :blk;
                        },
                        1 => {},
                        else => return error.UnhandledKeymap,
                    }

                    const mapped = try std.posix.mmap(
                        null,
                        params.size,
                        std.posix.system.PROT.READ,
                        .{ .TYPE = .PRIVATE },
                        event.fd.?,
                        0,
                    );
                    defer std.posix.munmap(mapped);

                    {
                        const keymap = c.xkb_keymap_new_from_string(
                            self.xkb,
                            mapped.ptr,
                            // Stolen from glfw
                            c.XKB_KEYMAP_FORMAT_TEXT_V1,
                            c.XKB_KEYMAP_COMPILE_NO_FLAGS,
                        ) orelse return error.InvalidKeymap;
                        errdefer c.xkb_keymap_unref(keymap);
                        const state = c.xkb_state_new(keymap) orelse return error.XkbState;

                        self.keymap = .{
                            .keymap = keymap,
                            .state = state,
                        };
                    }
                },
                .key => |params| {
                    try self.input_events.append(self.alloc, .{
                        // lol x11 history
                        .key = .{
                            .keycode = params.key + 8,
                            .state = try std.meta.intToEnum(Key.State, params.state),
                            .window = self,
                        },
                    });
                },
                else => wlclient.logUnusedEvent(event.event),
            },
            .zwp_linux_dmabuf_feedback_v1 => |feedback| switch (feedback) {
                .main_device => |device| {
                    self.format_info.pending.preferred_gpu = std.mem.bytesToValue(u64, device.device);
                },
                .tranche_formats => |params| {
                    if (params.indices.len == 0) return error.NoIndices;
                    const index = params.indices[0];

                    const mapped_formats = self.format_info.pending.mapped_formats;
                    if (index >= mapped_formats.len) return error.InvalidIndex;
                    const table_entry = self.format_info.pending.mapped_formats[index];

                    self.format_info.pending.preferred_format = .{
                        .format = table_entry.format,
                        .modifier = table_entry.modifier,
                    };
                },
                .format_table => |params| {
                    const fd = event.fd orelse return error.NoFd;
                    const mapped = try std.posix.mmap(
                        null,
                        params.size,
                        std.posix.system.PROT.READ,
                        .{ .TYPE = .PRIVATE },
                        fd,
                        0,
                    );

                    self.format_info.pending.mapped_formats = std.mem.bytesAsSlice(FormatTableItem, mapped);
                },
                .done => {
                    if (self.format_info.pending.mapped_formats.len != 0) {
                        std.posix.munmap(@alignCast(std.mem.sliceAsBytes(self.format_info.pending.mapped_formats)));
                    }

                    self.format_info.preferred_gpu = self.format_info.pending.preferred_gpu;
                    self.format_info.preferred_format = self.format_info.pending.preferred_format;
                    self.format_info.pending = .{};
                },
                else => wlclient.logUnusedEvent(event.event),
            },
            else => wlclient.logUnusedEvent(event.event),
        }
        return false;
    }

    pub fn inputEvents(self: Window) sphtud.util.RuntimeSegmentedList(InputEvent).Iter {
        return self.input_events.iter();
    }

    fn clearInputEvents(self: *Window) void {
        self.input_events.clear(self.alloc);
    }
};
