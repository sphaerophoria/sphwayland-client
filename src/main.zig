const std = @import("std");
const builtin = @import("builtin");
const Allocator = std.mem.Allocator;
const wlw = @import("wl_writer");
const wlr = @import("wl_reader");
const HeaderLE = wlw.HeaderLE;
const wlb = @import("wl_bindings");
const xdgsb = @import("xdg_shell_bindings");
const xdgdb = @import("xdg_decoration_bindings");

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

fn handleDisplayEvent(event: anytype) !void {
    const parsed = try wlb.WlDisplay.Event.parse(event.header.op, event.data);
    switch (parsed) {
        .err => |err| {
            std.log.err("wl_display::error: object {d}, code: {d}, msg: {s}", .{ err.object_id, err.code, err.message });
        },
        .delete_id => std.log.warn("Unimplemented handler for wl_display::delete_id", .{}),
    }
}

fn createShmPool(alloc: Allocator, stream: std.net.Stream, wl_shm: wlb.WlShm, pixels: ShmPixelBuf, id: u32) !void {
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
        @ptrCast(&pixels.fd),
        @sizeOf(std.posix.fd_t),
    );

    var wl_shm_buf = std.ArrayList(u8).init(alloc);
    defer wl_shm_buf.deinit();
    try wl_shm.createPool(wl_shm_buf.writer(), .{
        .id = id,
        .fd = {}, // Sent as cmsg attachment
        .size = @intCast(pixels.size()),
    });

    const iov = [1]std.posix.iovec_const{.{
        .base = wl_shm_buf.items.ptr,
        .len = wl_shm_buf.items.len,
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
            std.log.warn("Unused event: {any}", .{try wlb.WlDisplay.Event.parse(event.header.op, event.data)});
        },
        .registry => {
            std.log.warn("Unused event: {any}", .{try wlb.WlRegistry.Event.parse(event.header.op, event.data)});
        },
        .wl_surface => {
            std.log.warn("Unused event: {any}", .{try wlb.WlSurface.Event.parse(event.header.op, event.data)});
        },
        .compositor => {
            std.log.warn("Unused compositor event", .{});
        },
        .wl_shm => {
            std.log.warn("Unused event: {any}", .{try wlb.WlShm.Event.parse(event.header.op, event.data)});
        },
        .wl_shm_pool => {
            std.log.warn("Unused wl_shm_pool event", .{});
        },
        .wl_buffer => {
            std.log.warn("Unused event: {any}", .{try wlb.WlBuffer.Event.parse(event.header.op, event.data)});
        },
        .decoration_manager => {
            std.log.warn("Unused zxdg_decoration_manager event", .{});
        },
        .top_level_decoration => {
            std.log.warn("Unused event: {any}", .{try xdgdb.ZxdgToplevelDecorationV1.Event.parse(event.header.op, event.data)});
        },
        .xdg_wm_base => {
            std.log.warn("Unused event: {any}", .{try xdgsb.XdgWmBase.Event.parse(event.header.op, event.data)});
        },
        .xdg_surface => {
            std.log.warn("Unused event: {any}", .{try xdgsb.XdgSurface.Event.parse(event.header.op, event.data)});
        },
        .xdg_toplevel => {
            std.log.warn("Unused event: {any}", .{try xdgsb.XdgToplevel.Event.parse(event.header.op, event.data)});
        },
    }
}

const InterfaceType = enum {
    display,
    registry,
    compositor,
    wl_surface,
    wl_buffer,
    wl_shm,
    wl_shm_pool,
    xdg_wm_base,
    xdg_surface,
    xdg_toplevel,
    decoration_manager,
    top_level_decoration,
};

const InterfaceRegistry = struct {
    idx: u32,
    elems: InterfaceMap,
    registry: wlb.WlRegistry,

    const InterfaceMap = std.AutoHashMap(u32, InterfaceType);

    fn init(alloc: Allocator, registry: wlb.WlRegistry) !InterfaceRegistry {
        var elems = InterfaceMap.init(alloc);

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
            wlb.WlShm => .wl_shm,
            wlb.WlShmPool => .wl_shm_pool,
            xdgdb.ZxdgDecorationManagerV1 => .decoration_manager,
            xdgdb.ZxdgToplevelDecorationV1 => .top_level_decoration,
            wlb.WlSurface => .wl_surface,
            xdgsb.XdgSurface => .xdg_surface,
            xdgsb.XdgToplevel => .xdg_toplevel,
            wlb.WlBuffer => .wl_buffer,
            else => {
                @compileError("Unsupported interface type " ++ @typeName(T));
            },
        };
    }
};

const BoundInterfaces = struct {
    compositor: wlb.WlCompositor,
    xdg_wm_base: xdgsb.XdgWmBase,
    wl_shm: wlb.WlShm,
    decoration_manager: xdgdb.ZxdgDecorationManagerV1,
};

fn bindInterfaces(stream: std.net.Stream, interfaces: *InterfaceRegistry) !BoundInterfaces {
    var it = EventIt(4096).init(stream);
    try it.retrieveEvents();

    var compositor: ?wlb.WlCompositor = null;
    var xdg_wm_base: ?xdgsb.XdgWmBase = null;
    var wl_shm: ?wlb.WlShm = null;
    var decoration_manager: ?xdgdb.ZxdgDecorationManagerV1 = null;

    while (try it.getAvailableEvent()) |event| {
        const interface = interfaces.get(event.header.id) orelse {
            std.log.warn("Got response for unknown interface {d}\n", .{event.header.id});
            continue;
        };

        switch (interface) {
            .display => try handleDisplayEvent(event),
            .registry => {
                const action = try wlb.WlRegistry.Event.parse(event.header.op, event.data);
                switch (action) {
                    .global => |g| blk: {
                        const DesiredInterfaces = enum {
                            wl_compositor,
                            xdg_wm_base,
                            wl_shm,
                            zxdg_decoration_manager_v1,
                        };

                        const interface_name = std.meta.stringToEnum(DesiredInterfaces, g.interface) orelse {
                            std.log.debug("Unused interface {s}", .{g.interface});
                            break :blk;
                        };

                        const writer = stream.writer();

                        switch (interface_name) {
                            .wl_compositor => compositor = try interfaces.bind(wlb.WlCompositor, writer, g),
                            .xdg_wm_base => xdg_wm_base = try interfaces.bind(xdgsb.XdgWmBase, writer, g),
                            .wl_shm => wl_shm = try interfaces.bind(wlb.WlShm, writer, g),
                            .zxdg_decoration_manager_v1 => decoration_manager = try interfaces.bind(xdgdb.ZxdgDecorationManagerV1, writer, g),
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
        .wl_shm = wl_shm orelse return error.NoWlShm,
        .decoration_manager = decoration_manager orelse return error.DecorationManager,
    };
}

const ShmPixelBuf = struct {
    fd: std.posix.fd_t,
    width: u32,
    pixels: []u32,

    pub fn init() !ShmPixelBuf {
        const shm_file = try std.posix.memfd_create("sphwayland-client-pixbuf", 0);

        const buf_width = 640;
        const buf_height = 480;
        const buf_size = buf_width * buf_height * 4;
        try std.posix.ftruncate(shm_file, buf_size);

        const map_flags = std.posix.system.MAP{ .TYPE = .SHARED };
        const pixel_buf = try std.posix.mmap(
            null,
            buf_size,
            std.posix.system.PROT.READ | std.posix.system.PROT.WRITE,
            map_flags,
            shm_file,
            0,
        );

        const pixels = std.mem.bytesAsSlice(u32, pixel_buf[0..buf_size]);

        @memset(pixels, 0xff00ffff);

        return .{
            .fd = shm_file,
            .width = buf_width,
            .pixels = pixels,
        };
    }

    fn height(self: ShmPixelBuf) usize {
        return self.pixels.len / self.width;
    }

    fn pitch(self: ShmPixelBuf) usize {
        return self.width * 4;
    }

    fn size(self: ShmPixelBuf) usize {
        return self.pixels.len * 4;
    }
};

const App = struct {
    interfaces: *InterfaceRegistry,
    compositor: wlb.WlCompositor,
    xdg_wm_base: xdgsb.XdgWmBase,
    wl_surface: wlb.WlSurface,
    xdg_surface: xdgsb.XdgSurface,
    stream: std.net.Stream,
    pixels: ShmPixelBuf,

    pub fn init(alloc: Allocator, stream: std.net.Stream, interfaces: *InterfaceRegistry, bound_interfaces: BoundInterfaces) !App {
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

        try wl_surface.commit(writer, .{});

        const pixels = try ShmPixelBuf.init();

        const wl_shm_pool = try interfaces.register(wlb.WlShmPool);

        try createShmPool(alloc, stream, bound_interfaces.wl_shm, pixels, wl_shm_pool.id);

        const wl_buffer = try interfaces.register(wlb.WlBuffer);

        try wl_shm_pool.createBuffer(writer, .{
            .id = wl_buffer.id,
            .offset = 0,
            .width = @intCast(pixels.width),
            .height = @intCast(pixels.height()),
            .stride = @intCast(pixels.pitch()),
            // FIXME: Generate from wlgen xrgb8888
            .format = 1,
        });

        try wl_surface.attach(writer, .{
            .buffer = wl_buffer.id,
            .x = 0,
            .y = 0,
        });

        try wl_surface.commit(writer, .{});

        return .{
            .interfaces = interfaces,
            .compositor = bound_interfaces.compositor,
            .xdg_wm_base = bound_interfaces.xdg_wm_base,
            .wl_surface = wl_surface,
            .xdg_surface = xdg_surface,
            .stream = stream,
            .pixels = pixels,
        };
    }

    fn handleEvent(self: *App, event: Event) !bool {
        const interface = self.interfaces.get(event.header.id) orelse {
            std.log.warn("Got response for unknown interface {d}\n", .{event.header.id});
            return false;
        };

        switch (interface) {
            .display => try handleDisplayEvent(event),
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
                        std.log.warn("Unhandled toplevel event {any}", .{parsed});
                    },
                }
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

    var app = try App.init(alloc, stream, &interfaces, bound_interfaces);
    var it = EventIt(4096).init(stream);

    while (true) {
        const event = try it.getEventBlocking();
        const close = try app.handleEvent(event);
        if (close) return;
    }
}
