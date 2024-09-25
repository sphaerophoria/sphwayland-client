const std = @import("std");
const builtin = @import("builtin");
const Allocator = std.mem.Allocator;
const wlw = @import("wl_writer");
const wlr = @import("wl_reader");
const HeaderLE = wlw.HeaderLE;
const wlb = @import("wl_bindings");
const xdgsb = @import("xdg_shell_bindings");
const xdgdb = @import("xdg_decoration_bindings");
const dmab = @import("linux_dma_buf");
const ModelRenderer = @import("ModelRenderer.zig");
const gl_helpers = @import("gl_helpers.zig");
const gl = @import("gl.zig");

pub const std_options = std.Options{
    .log_level = .warn,
};

const cmsg = @cImport({
    @cInclude("cmsg.h");
});

fn openWaylandConnection(alloc: Allocator) !std.net.Stream {
    const xdg_runtime_dir = std.posix.getenv("XDG_RUNTIME_DIR") orelse return error.NoXdgRuntime;
    const wayland_display = std.posix.getenv("WAYLAND_DISPLAY") orelse return error.NoWaylandDisplay;

    const socket_path = try std.fs.path.joinZ(alloc, &.{ xdg_runtime_dir, wayland_display });
    defer alloc.free(socket_path);

    return try std.net.connectUnixSocket(socket_path);
}

fn logWaylandErr(err: wlb.WlDisplay.Event.Error) void {
    std.log.err("wl_display::error: object {d}, code: {d}, msg: {s}", .{ err.object_id, err.code, err.message });
}

fn sendMessageWithFdAttachment(alloc: Allocator, stream: std.net.Stream, msg: []const u8, fd: c_int) !void {
    // This has to be a comptime known value, but the alignment is kinda
    // defined by the C macros. We'll just use 8 and assume that it can't be
    // wrong
    const cmsg_buf_alignment = 8;
    const cmsg_buf = try alloc.allocWithOptions(
        u8,
        cmsg.getCmsgSpace(@sizeOf(std.posix.fd_t)),
        cmsg_buf_alignment,
        null,
    );
    defer alloc.free(cmsg_buf);

    cmsg.makeFdTransferCmsg(
        cmsg_buf.ptr,
        @ptrCast(&fd),
        @sizeOf(std.posix.fd_t),
    );

    const iov = [1]std.posix.iovec_const{.{
        .base = msg.ptr,
        .len = msg.len,
    }};

    const msghdr = std.posix.msghdr_const{
        .name = null,
        .namelen = 0,
        .iov = &iov,
        .iovlen = 1,
        .control = cmsg_buf.ptr,
        .controllen = @intCast(cmsg_buf.len),
        .flags = 0,
    };

    // FIXME: check result
    _ = try std.posix.sendmsg(stream.handle, &msghdr, 0);
}

fn logUnusedEvent(interface: InterfaceType, event: Event) !void {
    switch (interface) {
        .display => {
            const parsed = try wlb.WlDisplay.Event.parse(event.header.op, event.data);
            switch (parsed) {
                .err => |err| logWaylandErr(err),
                else => {
                    std.log.debug("Unused event: {any}", .{parsed});
                },
            }
        },
        .registry => {
            std.log.debug("Unused event: {any}", .{try wlb.WlRegistry.Event.parse(event.header.op, event.data)});
        },
        .wl_surface => {
            std.log.debug("Unused event: {any}", .{try wlb.WlSurface.Event.parse(event.header.op, event.data)});
        },
        .compositor => {
            std.log.debug("Unused compositor event", .{});
        },
        .wl_callback => {
            std.log.debug("Unused event: {any}", .{try wlb.WlCallback.Event.parse(event.header.op, event.data)});
        },
        .wl_buffer => {
            std.log.debug("Unused event: {any}", .{try wlb.WlBuffer.Event.parse(event.header.op, event.data)});
        },
        .dmabuf => {
            std.log.debug("Unused event: {any}", .{try dmab.ZwpLinuxDmabufV1.Event.parse(event.header.op, event.data)});
        },
        .dmabuf_params => {
            std.log.debug("Unused event: {any}", .{try dmab.ZwpLinuxBufferParamsV1.Event.parse(event.header.op, event.data)});
        },
        .decoration_manager => {
            std.log.debug("Unused zxdg_decoration_manager event", .{});
        },
        .top_level_decoration => {
            std.log.debug("Unused event: {any}", .{try xdgdb.ZxdgToplevelDecorationV1.Event.parse(event.header.op, event.data)});
        },
        .xdg_wm_base => {
            std.log.debug("Unused event: {any}", .{try xdgsb.XdgWmBase.Event.parse(event.header.op, event.data)});
        },
        .xdg_surface => {
            std.log.debug("Unused event: {any}", .{try xdgsb.XdgSurface.Event.parse(event.header.op, event.data)});
        },
        .xdg_toplevel => {
            std.log.debug("Unused event: {any}", .{try xdgsb.XdgToplevel.Event.parse(event.header.op, event.data)});
        },
    }
}

const InterfaceType = enum {
    display,
    registry,
    compositor,
    wl_surface,
    wl_buffer,
    wl_callback,
    xdg_wm_base,
    xdg_surface,
    xdg_toplevel,
    decoration_manager,
    top_level_decoration,
    dmabuf,
    dmabuf_params,
};

const InterfaceRegistry = struct {
    idx: u32,
    elems: InterfaceMap,
    registry: wlb.WlRegistry,

    const InterfaceMap = std.AutoHashMap(u32, InterfaceType);

    fn init(alloc: Allocator, registry: wlb.WlRegistry) !InterfaceRegistry {
        var elems = InterfaceMap.init(alloc);

        try elems.put(1, .display);
        try elems.put(registry.id, .registry);

        return .{
            .idx = registry.id + 1,
            .elems = elems,
            .registry = registry,
        };
    }

    fn deinit(self: *InterfaceRegistry) void {
        self.elems.deinit();
    }

    fn get(self: InterfaceRegistry, id: u32) ?InterfaceType {
        return self.elems.get(id);
    }

    fn bind(self: *InterfaceRegistry, comptime T: type, writer: std.net.Stream.Writer, params: wlb.WlRegistry.Event.Global) !T {
        defer self.idx += 1;

        try self.registry.bind(writer, .{
            .id_interface = params.interface,
            .id_interface_version = params.version,
            .name = params.name,
            .id = self.idx,
        });

        try self.elems.put(self.idx, resolveInterfaceType(T));

        return T{ .id = self.idx };
    }

    fn register(self: *InterfaceRegistry, comptime T: type) !T {
        defer self.idx += 1;
        try self.elems.put(self.idx, resolveInterfaceType(T));
        return T{
            .id = self.idx,
        };
    }

    fn resolveInterfaceType(comptime T: type) InterfaceType {
        return switch (T) {
            wlb.WlCompositor => .compositor,
            xdgsb.XdgWmBase => .xdg_wm_base,
            xdgdb.ZxdgDecorationManagerV1 => .decoration_manager,
            xdgdb.ZxdgToplevelDecorationV1 => .top_level_decoration,
            wlb.WlSurface => .wl_surface,
            wlb.WlCallback => .wl_callback,
            xdgsb.XdgSurface => .xdg_surface,
            xdgsb.XdgToplevel => .xdg_toplevel,
            wlb.WlBuffer => .wl_buffer,
            dmab.ZwpLinuxDmabufV1 => .dmabuf,
            dmab.ZwpLinuxBufferParamsV1 => .dmabuf_params,
            else => {
                @compileError("Unsupported interface type " ++ @typeName(T));
            },
        };
    }
};

const BoundInterfaces = struct {
    compositor: wlb.WlCompositor,
    xdg_wm_base: xdgsb.XdgWmBase,
    decoration_manager: xdgdb.ZxdgDecorationManagerV1,
    dmabuf: dmab.ZwpLinuxDmabufV1,
};

fn bindInterfaces(stream: std.net.Stream, interfaces: *InterfaceRegistry) !BoundInterfaces {
    var it = EventIt(4096).init(stream);
    try it.retrieveEvents();

    var compositor: ?wlb.WlCompositor = null;
    var xdg_wm_base: ?xdgsb.XdgWmBase = null;
    var decoration_manager: ?xdgdb.ZxdgDecorationManagerV1 = null;
    var dmabuf: ?dmab.ZwpLinuxDmabufV1 = null;

    while (try it.getAvailableEvent()) |event| {
        const interface = interfaces.get(event.header.id) orelse {
            std.log.warn("Got response for unknown interface {d}\n", .{event.header.id});
            continue;
        };

        switch (interface) {
            .display => {
                const parsed = try wlb.WlDisplay.Event.parse(event.header.op, event.data);
                switch (parsed) {
                    .err => |err| logWaylandErr(err),
                    .delete_id => {
                        std.log.warn("Unexpected delete object in binding stage", .{});
                    },
                }
            },
            .registry => {
                const action = try wlb.WlRegistry.Event.parse(event.header.op, event.data);
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

                        const writer = stream.writer();

                        switch (interface_name) {
                            .wl_compositor => compositor = try interfaces.bind(wlb.WlCompositor, writer, g),
                            .xdg_wm_base => xdg_wm_base = try interfaces.bind(xdgsb.XdgWmBase, writer, g),
                            .zxdg_decoration_manager_v1 => decoration_manager = try interfaces.bind(xdgdb.ZxdgDecorationManagerV1, writer, g),
                            .zwp_linux_dmabuf_v1 => dmabuf = try interfaces.bind(dmab.ZwpLinuxDmabufV1, writer, g),
                        }
                    },
                    .global_remove => {
                        std.log.warn("No registry to remove from", .{});
                    },
                }
            },
            else => try logUnusedEvent(interface, event),
        }
    }

    return .{
        .compositor = compositor orelse return error.NoCompositor,
        .xdg_wm_base = xdg_wm_base orelse return error.NoXdgWmBase,
        .decoration_manager = decoration_manager orelse return error.DecorationManager,
        .dmabuf = dmabuf orelse return error.NoDmaBuf,
    };
}

const App = struct {
    interfaces: *InterfaceRegistry,
    compositor: wlb.WlCompositor,
    xdg_wm_base: xdgsb.XdgWmBase,
    wl_surface: wlb.WlSurface,
    xdg_surface: xdgsb.XdgSurface,
    stream: std.net.Stream,
    frame_callback: wlb.WlCallback,
    gl_buffers: *GlBuffers,
    model_renderer: ModelRenderer,

    pub fn init(alloc: Allocator, stream: std.net.Stream, gl_buffers: *GlBuffers, interfaces: *InterfaceRegistry, bound_interfaces: BoundInterfaces) !App {
        std.log.debug("Initializing app", .{});
        const writer = stream.writer();

        const wl_surface = try interfaces.register(wlb.WlSurface);
        try bound_interfaces.compositor.createSurface(writer, .{
            .id = wl_surface.id,
        });

        const xdg_surface = try interfaces.register(xdgsb.XdgSurface);
        try bound_interfaces.xdg_wm_base.getXdgSurface(writer, .{
            .id = xdg_surface.id,
            .surface = wl_surface.id,
        });

        const toplevel = try interfaces.register(xdgsb.XdgToplevel);
        try xdg_surface.getToplevel(writer, .{ .id = toplevel.id });
        try toplevel.setAppId(writer, .{ .app_id = "sphwayland-client" });
        try toplevel.setTitle(writer, .{ .title = "sphwayland client" });

        const toplevel_decoration = try interfaces.register(xdgdb.ZxdgToplevelDecorationV1);
        try bound_interfaces.decoration_manager.getToplevelDecoration(writer, .{
            .id = toplevel_decoration.id,
            .toplevel = toplevel.id,
        });

        try wl_surface.attach(writer, .{
            .buffer = gl_buffers.getActiveWlBuffer().id,
            .x = 0,
            .y = 0,
        });
        gl_buffers.swap();

        try wl_surface.commit(writer, .{});

        const frame_callback = try interfaces.register(wlb.WlCallback);
        try wl_surface.frame(writer, .{
            .callback = frame_callback.id,
        });

        const model_renderer = try ModelRenderer.init(alloc);
        return .{
            .interfaces = interfaces,
            .compositor = bound_interfaces.compositor,
            .xdg_wm_base = bound_interfaces.xdg_wm_base,
            .wl_surface = wl_surface,
            .xdg_surface = xdg_surface,
            .frame_callback = frame_callback,
            .stream = stream,
            .gl_buffers = gl_buffers,
            .model_renderer = model_renderer,
        };
    }

    fn deinit(self: *App) void {
        self.model_renderer.deinit();
    }

    fn handleEvent(self: *App, event: Event) !bool {
        const interface = self.interfaces.get(event.header.id) orelse {
            std.log.warn("Got response for unknown interface {d}\n", .{event.header.id});
            return false;
        };

        switch (interface) {
            .display => {
                const parsed = try wlb.WlDisplay.Event.parse(event.header.op, event.data);
                switch (parsed) {
                    .err => |err| logWaylandErr(err),
                    .delete_id => |req| {
                        if (req.id == self.frame_callback.id) {
                            try self.wl_surface.frame(self.stream.writer(), .{ .callback = self.frame_callback.id });
                            try self.wl_surface.commit(self.stream.writer(), .{});
                        } else {
                            std.log.warn("Deletion of object {d} is not handled", .{req.id});
                        }
                    },
                }
            },
            .xdg_surface => {
                const parsed = try xdgsb.XdgSurface.Event.parse(event.header.op, event.data);
                try self.xdg_surface.ackConfigure(self.stream.writer(), .{
                    .serial = parsed.configure.serial,
                });
                try self.wl_surface.commit(self.stream.writer(), .{});
            },
            .xdg_wm_base => {
                const parsed = try xdgsb.XdgWmBase.Event.parse(event.header.op, event.data);
                try self.xdg_wm_base.pong(self.stream.writer(), .{
                    .serial = parsed.ping.serial,
                });
            },
            .xdg_toplevel => {
                const parsed = try xdgsb.XdgToplevel.Event.parse(event.header.op, event.data);
                switch (parsed) {
                    .close => {
                        return true;
                    },
                    else => {
                        std.log.debug("Unhandled toplevel event {any}", .{parsed});
                    },
                }
            },
            .wl_callback => {
                std.debug.assert(self.frame_callback.id == event.header.id);
                const parsed = try wlb.WlCallback.Event.parse(event.header.op, event.data);
                std.debug.assert(parsed == .done);

                const fbo = self.gl_buffers.getActiveFramebuffer();
                gl.glBindFramebuffer(gl.GL_FRAMEBUFFER, fbo);
                gl.glViewport(0, 0, GlBuffers.width, GlBuffers.height);

                gl.glClearColor(0.4, 0.4, 0.4, 1.0);
                gl.glClearDepth(1.0);
                gl.glClear(gl.GL_COLOR_BUFFER_BIT | gl.GL_DEPTH_BUFFER_BIT);

                self.model_renderer.rotate(0.01, 0.001);
                self.model_renderer.render(1.0);

                // Unlike in normal opengl, nothing is telling the system that
                // we are actually using this texture. We need to flush the
                // draw calls before asking the compositor to draw our texture
                // for us
                gl.glFlush();

                const wl_buf = self.gl_buffers.getActiveWlBuffer();
                try self.wl_surface.attach(self.stream.writer(), .{
                    .buffer = wl_buf.id,
                    .x = 0,
                    .y = 0,
                });
                self.gl_buffers.swap();
                try self.wl_surface.damageBuffer(self.stream.writer(), .{
                    .x = 0,
                    .y = 0,
                    .width = std.math.maxInt(i32),
                    .height = std.math.maxInt(i32),
                });
                try self.wl_surface.commit(self.stream.writer(), .{});
            },
            else => try logUnusedEvent(interface, event),
        }
        return false;
    }
};

const Event = struct {
    header: HeaderLE,
    data: []const u8,
};

pub fn EventIt(comptime buf_size: comptime_int) type {
    return struct {
        stream: std.net.Stream,
        buf: DoubleEndedBuf = .{},

        // Data is read into the buffer in chunks, and consumed from the
        // beginning, once we cannot read any more from the buffer, we shift
        // the remaining data back and wait for more data to show up
        //
        // Wrapping the stream in a bufreader seems like a good idea, but the
        // edge case of half a header being at the end of the buf would not be
        // handled well there
        const DoubleEndedBuf = struct {
            data: [buf_size]u8 = undefined,
            back: usize = 0,
            front: usize = 0,

            fn shift(self: *DoubleEndedBuf) void {
                std.mem.copyForwards(u8, &self.data, self.data[self.front..]);
                self.back -= self.front;
                self.front = 0;
            }
        };

        const Self = @This();

        pub fn init(stream: std.net.Stream) Self {
            return .{
                .stream = stream,
            };
        }

        // NOTE: Output data is backed by internal buffer and is invalidated on next call to next()
        pub fn retrieveEvents(self: *Self) !void {
            self.buf.shift();

            const num_bytes_read = try self.stream.read(self.buf.data[self.buf.back..]);
            if (num_bytes_read == 0) {
                return error.RemoteClosed;
            }

            self.buf.back += num_bytes_read;
        }

        pub fn getEventBlocking(self: *Self) !Event {
            while (true) {
                if (try self.getAvailableEvent()) |v| {
                    return v;
                }
                try self.wait();
            }
        }

        pub fn getAvailableEvent(self: *Self) !?Event {
            while (true) {
                if (try self.getBufferedEvent()) |v| {
                    return v;
                }

                if (!try self.dataInSocket()) {
                    return null;
                }

                try self.retrieveEvents();
            }
        }

        fn wait(self: *Self) !void {
            var num_ready: usize = 0;
            while (num_ready == 0) {
                var pollfd = [1]std.posix.pollfd{.{
                    .fd = self.stream.handle,
                    .events = std.posix.POLL.IN,
                    .revents = 0,
                }};
                num_ready = try std.posix.poll(&pollfd, -1);
            }
        }

        fn getBufferedEvent(self: *Self) !?Event {
            const header_end = self.buf.front + @sizeOf(wlw.HeaderLE);
            if (header_end > self.buf.back) {
                return null;
            }
            const header = std.mem.bytesToValue(HeaderLE, self.buf.data[self.buf.front..header_end]);
            const data_end = self.buf.front + header.size;
            if (data_end > self.buf.data.len and self.buf.front == 0) {
                return error.DataTooLarge;
            }
            if (data_end > self.buf.back) {
                return null;
            }

            defer self.buf.front = data_end;
            return .{
                .header = header,
                .data = self.buf.data[header_end..data_end],
            };
        }

        fn dataInSocket(self: *Self) !bool {
            var pollfd = [1]std.posix.pollfd{.{
                .fd = self.stream.handle,
                .events = std.posix.POLL.IN,
                .revents = 0,
            }};
            const num_ready = try std.posix.poll(&pollfd, 0);
            return num_ready != 0;
        }
    };
}

const GlBuffers = struct {
    const width = 640;
    const height = 480;

    framebuffers: [2]gl_helpers.FrameBuffer,
    wl_buffers: [2]wlb.WlBuffer,
    idx: u1 = 0,

    fn deinit(self: *GlBuffers) void {
        for (&self.framebuffers) |*fb| {
            fb.deinit();
        }
    }

    fn getActiveFramebuffer(self: *GlBuffers) u32 {
        return self.framebuffers[self.idx].fbo;
    }

    fn getActiveWlBuffer(self: *GlBuffers) *wlb.WlBuffer {
        return &self.wl_buffers[self.idx];
    }

    fn swap(self: *GlBuffers) void {
        self.idx +%= 1;
    }
};

fn waitForZwpLinuxWlBuffer(stream: std.net.Stream, interfaces: *InterfaceRegistry) !wlb.WlBuffer {
    var it = EventIt(4096).init(stream);
    while (true) {
        const event = try it.getEventBlocking();
        const interface_type = interfaces.get(event.header.id) orelse {
            std.log.debug("Unknown object: {d}\n", .{event.header.id});
            continue;
        };
        switch (interface_type) {
            .dmabuf_params => {
                const parsed = try dmab.ZwpLinuxBufferParamsV1.Event.parse(event.header.op, event.data);

                switch (parsed) {
                    .created => |s| {
                        const ret = wlb.WlBuffer{
                            .id = s.buffer,
                        };

                        try interfaces.elems.put(ret.id, .wl_buffer);
                        return ret;
                    },
                    .failed => {
                        return error.CreateDmaBuf;
                    },
                }
                break;
            },
            else => try logUnusedEvent(interface_type, event),
        }
    }
}

fn createGlBackedBuffers(
    alloc: Allocator,
    egl_context: gl_helpers.EglContext,
    stream: std.net.Stream,
    interfaces: *InterfaceRegistry,
    bound_interfaces: BoundInterfaces,
) !GlBuffers {
    const writer = stream.writer();

    var framebuffers: [2]gl_helpers.FrameBuffer = undefined;
    var wl_buffers: [2]wlb.WlBuffer = undefined;

    for (0..2) |idx| {
        const buffer_params = try interfaces.register(dmab.ZwpLinuxBufferParamsV1);
        try bound_interfaces.dmabuf.createParams(writer, .{
            .params_id = buffer_params.id,
        });

        framebuffers[idx] = gl_helpers.makeFarmeBuffer(GlBuffers.width, GlBuffers.height);

        const zwp_params = gl_helpers.makeTextureFileDescriptor(framebuffers[idx].color, egl_context.display, egl_context.context);

        var to_send = std.ArrayList(u8).init(alloc);
        defer to_send.deinit();
        try buffer_params.add(to_send.writer(), .{
            .fd = {}, // out of band,
            .plane_idx = 0, // assumed single plane
            .offset = @intCast(zwp_params.offset),
            .stride = @intCast(zwp_params.stride),
            .modifier_hi = @intCast(zwp_params.modifiers >> 32),
            .modifier_lo = @truncate(zwp_params.modifiers),
        });

        try sendMessageWithFdAttachment(alloc, stream, to_send.items, zwp_params.fd);

        try buffer_params.create(writer, .{
            .width = GlBuffers.width,
            .height = GlBuffers.height,
            .format = @bitCast(zwp_params.fourcc),
            .flags = 1,
        });

        wl_buffers[idx] = try waitForZwpLinuxWlBuffer(stream, interfaces);
    }

    return .{
        .framebuffers = framebuffers,
        .wl_buffers = wl_buffers,
    };
}

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();

    const alloc = gpa.allocator();

    const stream = try openWaylandConnection(alloc);

    const display = wlb.WlDisplay{ .id = 1 };
    const registry = wlb.WlRegistry{ .id = 2 };
    try display.getRegistry(stream.writer(), .{
        .registry = registry.id,
    });

    var interfaces = try InterfaceRegistry.init(alloc, registry);
    defer interfaces.deinit();

    const bound_interfaces = try bindInterfaces(stream, &interfaces);

    var egl_context = try gl_helpers.EglContext.init();
    defer egl_context.deinit();
    gl_helpers.initializeGlParams();

    var gl_buffers = try createGlBackedBuffers(alloc, egl_context, stream, &interfaces, bound_interfaces);
    defer gl_buffers.deinit();

    var app = try App.init(alloc, stream, &gl_buffers, &interfaces, bound_interfaces);
    defer app.deinit();
    var it = EventIt(4096).init(stream);

    while (true) {
        const event = try it.getEventBlocking();
        const close = try app.handleEvent(event);
        if (close) return;
    }
}
