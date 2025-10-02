const std = @import("std");
const wlio = @import("wlio");
const Bindings = @import("wayland_bindings");
const sphtud = @import("sphtud");
const fd_cmsg = @import("fd_cmsg");
const rendering = @import("rendering.zig");

pub const std_option = std.Options {
    .log_level = .warn,
};

const CmsgHdr = extern struct {
    cmsg_len: usize,
    cmsg_level: c_int,
    cmsg_type: c_int,
};

const WlReader = struct {
    socket: std.net.Stream,
    fd_list: sphtud.util.CircularBuffer(std.posix.fd_t),
    last_res: std.os.linux.E = .SUCCESS,
    interface: std.Io.Reader,

    fn stream(r: *std.Io.Reader, writer: *std.Io.Writer, limit: std.Io.Limit) error{EndOfStream,ReadFailed,WriteFailed}!usize{
        const self: *WlReader = @fieldParentPtr("interface", r);
        self.last_res = .SUCCESS;

        const dest = limit.slice(try writer.writableSliceGreedy(1));

        var iov: [1]std.posix.iovec = .{.{
            .base = dest.ptr,
            .len = dest.len,
        }};
        var control: [fd_cmsg.fd_cmsg_space]u8 = undefined;
        var msg_header = std.os.linux.msghdr {
            .name = null,
            .namelen = 0,
            .iov = &iov,
            .iovlen = 1,
            .control = &control,
            .controllen = control.len,
            .flags = 0,
        };

        // FIXME: Read many
        const ret = std.os.linux.recvmsg(
            self.socket.handle,
            &msg_header,
            0);

        if (ret == 0) return error.EndOfStream;

        const linux_err: std.os.linux.E = .init(ret);
        switch (linux_err) {
            .SUCCESS => {},
            else => {
                self.last_res = linux_err;
                return error.ReadFailed;
            },
        }

        if (msg_header.controllen >= @sizeOf(CmsgHdr)) {
            const hdr = std.mem.bytesToValue(CmsgHdr, &control);
            if (hdr.cmsg_level == std.os.linux.SOL.SOCKET) {
                const fd: c_int = std.mem.bytesToValue(c_int, control[fd_cmsg.fd_cmsg_data_offs..][0..4]);
                self.fd_list.pushNoClobber(fd) catch {
                    std.log.err("Dropped file descriptor", .{});
                    std.posix.close(fd);
                };
            }
        }

        writer.advance(@intCast(ret));
        return @intCast(ret);
    }
};

// std.Io.Reader
//  -- typical path just reads data as normal
//    * Cannot use read()
//  * Check for  file descriptors
//  * Put them out of band somewhere

fn createWaylandSocket(alloc: sphtud.alloc.LinearAllocator) !std.net.Server {
    const xdg_runtime_dir = std.posix.getenv("XDG_RUNTIME_DIR") orelse return error.NoXdgRuntime;

    var idx: usize = 0;

    while (true) {
        const cp = alloc.checkpoint();
        defer alloc.restore(cp);

        const path = try std.fmt.allocPrint(alloc.allocator(), "{s}/wayland-{d}", .{xdg_runtime_dir, idx});

        const addr = try std.net.Address.initUnix(path);
        const ret =  addr.listen(.{
            .reuse_address = false,
        }) catch |e| {
            switch (e) {
                error.AddressInUse => {},
                else => return e,
            }
            idx += 1;
            continue;
        };

        std.log.info("Serving on {s}", .{path});
        return ret;
    }
}

fn parseRequest(op: u32, data: []const u8, interface: Bindings.WaylandInterfaceType) !Bindings.WaylandIncomingMessage {
    inline for (std.meta.fields(Bindings.WaylandIncomingMessage)) |field| {
        if (@field(Bindings.WaylandInterfaceType, field.name) == interface) {
            if (@hasDecl(field.type, "parse")) {
                const ret = @unionInit(Bindings.WaylandIncomingMessage, field.name, try field.type.parse(op, data));
                return ret;
            } else {
                unreachable;
            }
        }
    }
    unreachable;
}

const Surface = struct {
    xdg_surface_id: ?u32 = null,
    // FIXME: Strong type storage vs wayland handles
    buffer: ?usize = null,
};

const gpa_vtable = blk: {
    var gpa: std.heap.GeneralPurposeAllocator(.{}) = .init;
    break :blk gpa.allocator().vtable;
};

const Window = struct {
    // FIXME: Should have own allocator
    alloc: *sphtud.alloc.Sphalloc, // owned
    title: []const u8 = &.{}, // alloc.general()
    app_id: []const u8 = &.{}, // alloc.general()
    surface: usize,

    fn deinit(self: *Window) void {
        self.alloc.deinit();
    }

    fn setTitle(self: *Window, title: []const u8) !void {
        const tmp_title: []const u8 = try self.alloc.general().dupe(u8, title);
        self.alloc.general().free(self.title);
        self.title = tmp_title;
    }

    fn setAppId(self: *Window, app_id: []const u8) !void {
        const tmp_id: []const u8 = try self.alloc.general().dupe(u8, app_id);
        self.alloc.general().free(self.app_id);
        self.app_id = tmp_id;
    }
};

fn IndirectLookupRef(comptime T: type) type {
    return struct {
        storage: *std.ArrayList(T),
        mapping: std.AutoArrayHashMapUnmanaged(u32, usize),


        const Self = @This();

        fn insert(self: *Self, gpa: std.mem.Allocator, object_id: u32, elem_idx: usize) !void {
            const gop = try self.mapping.getOrPut(gpa, object_id);
            if (gop.found_existing) return error.AlreadyExists;
            gop.value_ptr.* = elem_idx;
        }

        fn getHandle(self: *Self, object_id: u32) ?usize {
            return self.mapping.get(object_id);
        }
    };
 }

fn IndirectLookupOwned(comptime T: type) type {
    return struct {
        storage: std.ArrayList(T),
        mapping: std.AutoArrayHashMapUnmanaged(u32, usize),

        const Self = @This();

        fn init() Self {
            return .{
                .storage = .{},
                .mapping = .{},
            };
        }

        fn insert(self: *Self, alloc: std.mem.Allocator, object_id: u32, elem: T) !void {
            const elem_idx = self.storage.items.len;
            try self.storage.append(alloc, elem);
            const gop = try self.mapping.getOrPut(alloc, object_id);
            if (gop.found_existing) return error.AlreadyExists;
            gop.value_ptr.* = elem_idx;
        }

        fn get(self: *Self, object_id: u32) ?T {
            const elem_idx = self.mapping.get(object_id) orelse return null;
            return self.storage.items[elem_idx];
        }

        fn getPtr(self: *Self, object_id: u32) ?*T {
            const elem_idx = self.mapping.get(object_id) orelse return null;
            return &self.storage.items[elem_idx];
        }

        fn getHandle(self: *Self, object_id: u32) ?usize {
            return self.mapping.get(object_id);
        }
    };
 }

const InterfaceRegistry = struct {
    inner: std.AutoArrayHashMapUnmanaged(u32, Bindings.WaylandInterfaceType),

    fn init(gpa: std.mem.Allocator) !InterfaceRegistry {
        var ret: InterfaceRegistry = .{
            .inner = .{},
        };
        try ret.put(gpa, 1, .wl_display);
        return ret;
    }

    fn put(self: *InterfaceRegistry, alloc: std.mem.Allocator, object_id: u32, interface_type: Bindings.WaylandInterfaceType) !void {
        std.log.debug("Registering {d} -> {t}", .{object_id, interface_type});
        try self.inner.putNoClobber(alloc, object_id,  interface_type);
    }

    fn get(self: *const InterfaceRegistry, object_id: u32) ?Bindings.WaylandInterfaceType {
        return self.inner.get(object_id);
    }
};

const Buffer = struct {
    buf_params: BufferParams,
    width: i32,
    height: i32,
    format: u32,
    flags: u32,
};

const BufferParams = struct {
    fd: i32,
    plane_idx: u32,
    offset: u32,
    stride: u32,
    modifier: u64,
};

fn logUnhandledRequest(object_id: u32, req: Bindings.WaylandIncomingMessage) void {
    std.log.warn("Unhandled request by object {d}, {any}", .{object_id, req});
}

const ConnectionState = struct {
    alloc: *sphtud.alloc.Sphalloc,
    io_writer: *std.Io.Writer,

    interface_registry: InterfaceRegistry,
    wl_surfaces: IndirectLookupOwned(Surface),
    wl_buffers: IndirectLookupOwned(Buffer),

    zwp_params: IndirectLookupOwned(?BufferParams),
    // Self reference xdg_surfaces -> wl_surfaces
    xdg_surfaces: IndirectLookupRef(Surface),
    windows: IndirectLookupOwned(Window),
    frame_callback: ?u32 = null,

    render_backend: rendering.RenderBackend,

    fn initPinned(self: *ConnectionState, alloc: *sphtud.alloc.Sphalloc, render_backend: rendering.RenderBackend, io_writer: *std.Io.Writer) !void {
        self.* = .{
            .alloc = alloc,
            .io_writer = io_writer,
            .interface_registry = try .init(alloc.general()),
            .wl_surfaces = .init(),
            .xdg_surfaces = undefined,
            .windows = .init(),
            .wl_buffers = .init(),
            .zwp_params = .init(),
            .render_backend = render_backend,
        };

        self.xdg_surfaces = .{
            .storage = &self.wl_surfaces.storage,
            .mapping = .{},
        };
    }

    fn handleMessage(state: *ConnectionState, object_id: u32, req: Bindings.WaylandIncomingMessage, fd: ?std.posix.fd_t) !void {
        const supported_interfaces: []const Bindings.WaylandInterfaceType= &.{
            .wl_compositor,
            .xdg_wm_base,
            .zxdg_decoration_manager_v1,
            .zwp_linux_dmabuf_v1,
        };

        switch (req) {
            .wl_display => |parsed| switch (parsed)  {
                .get_registry => |params| {
                    try state.interface_registry.put(state.alloc.general(), params.registry, .wl_registry);

                    const registry = Bindings.WlRegistry { .id = params.registry };
                    for (supported_interfaces) |interface| {
                        try registry.global(state.io_writer, .{
                            .name = @intFromEnum(interface) + 1,
                            .interface = @tagName(interface),
                            .version = Bindings.getInterfaceVersion(interface),
                        });
                    }

                    try state.io_writer.flush();
                },
                else => {
                    logUnhandledRequest(object_id, req);
                    return;
                },
            },
            .wl_registry => |parsed| switch (parsed) {
                .bind => |params| {
                    // FIXME: These might have to be 0xff000000 or higher...
                    const interface: Bindings.WaylandInterfaceType = @enumFromInt(params.name - 1);
                    try state.interface_registry.put(state.alloc.general(), params.id,  interface);
                },
            },
            .wl_compositor => |parsed| switch (parsed) {
                .create_surface => |params| {
                    try state.wl_surfaces.insert(state.alloc.general(), params.id, .{});
                    try state.interface_registry.put(state.alloc.general(), params.id,  .wl_surface);
                },
                else => {
                    logUnhandledRequest(object_id, req);
                    return;
                },
            },
            .xdg_wm_base => |parsed| switch (parsed) {
                .get_xdg_surface => |params| {
                    const handle = state.wl_surfaces.getHandle(params.surface) orelse return error.InvalidSurface;

                    // FIXME: Better API?
                    const surface = &state.wl_surfaces.storage.items[handle];
                    surface.xdg_surface_id = params.id;

                    try state.xdg_surfaces.insert(state.alloc.general(), params.id, handle);

                    try state.interface_registry.put(state.alloc.general(), params.id, .xdg_surface);

                    const xdg_id = surface.xdg_surface_id orelse return error.InvalidSurface;
                    var xdg_surf = Bindings.XdgSurface { .id = xdg_id };
                    try xdg_surf.configure(state.io_writer, .{
                        // FIXME: Random number that is confirmed in ack
                        .serial = 1234,
                    });
                    try state.io_writer.flush();
                },
                else => {
                    logUnhandledRequest(object_id, req);
                    return;
                },
            },
            .xdg_surface => |parsed| switch (parsed) {
                .get_toplevel => |params| {
                    const surface_id = state.xdg_surfaces.getHandle(object_id) orelse return error.InvalidSurface;

                    try state.windows.insert(state.alloc.general(), params.id, .{
                        .alloc = try state.alloc.makeSubAlloc("window"),
                        .surface = surface_id,
                    });
                    try state.interface_registry.put(state.alloc.general(), params.id,  .xdg_toplevel);
                },
                .ack_configure => {},
                else => {
                    logUnhandledRequest(object_id, req);
                    return;
                },
            },
            .xdg_toplevel => |parsed| switch (parsed) {
                .set_title => |params| {
                    const window = state.windows.getPtr(object_id) orelse return error.InvalidWindow;
                    try window.setTitle(params.title);
                },
                .set_app_id => |params| {
                    const window = state.windows.getPtr(object_id) orelse return error.InvalidWindow;
                    try window.setAppId(params.app_id);
                },
                else => {
                    logUnhandledRequest(object_id, req);
                    return;
                },
            },
            .wl_surface => |parsed| switch (parsed) {
                .commit => {
                    const surface = state.wl_surfaces.get(object_id) orelse return error.InvalidSurface;


                    if (surface.buffer) |buf_handle| {
                        const buffer = state.wl_buffers.storage.items[buf_handle];

                        try state.render_backend.displayBuffer(
                            .{
                                .buf_fd = buffer.buf_params.fd,
                                .modifiers = buffer.buf_params.modifier,
                                .offset = buffer.buf_params.offset,
                                .plane_idx = buffer.buf_params.plane_idx,
                                .stride = buffer.buf_params.stride,
                                .width = buffer.width,
                                .height = buffer.height,
                                .format = buffer.format,
                            },
                        );
                    }
                },
                .frame => |params| {
                    state.frame_callback = params.callback;
                },
                .attach => |params| {
                    const surface = state.wl_surfaces.getPtr(object_id) orelse return error.InvalidSurface;
                    surface.buffer = state.wl_buffers.getHandle(params.buffer);
                },
                else => {
                    logUnhandledRequest(object_id, req);
                    return;
                },
            },
            .zwp_linux_buffer_params_v1 => |parsed| switch (parsed) {
                .add => |params| {
                    const buf_params = state.zwp_params.getPtr(object_id) orelse return error.InvalidObject;
                    var modifier: u64 = params.modifier_hi;
                    modifier <<= 32;
                    modifier |= params.modifier_lo;

                    buf_params.* = .{
                        .fd = fd.?,
                        .plane_idx = params.plane_idx,
                        .offset = params.offset,
                        .stride = params.stride,
                        .modifier = modifier,
                    };
                },
                .create_immed => |params| {
                    const buf_params_opt = state.zwp_params.get(object_id) orelse return error.InvalidObject;
                    const buf_params = buf_params_opt orelse return error.EmptyZwpParams;

                    try state.wl_buffers.insert(state.alloc.general(), params.buffer_id, .{
                        .buf_params = buf_params,
                        .width = params.width,
                        .height = params.height,
                        .format = params.format,
                        .flags = params.flags,
                    });
                },
                else => {
                    logUnhandledRequest(object_id, req);
                    return;
                },
            },
            .zwp_linux_dmabuf_v1 => |parsed| switch (parsed) {
                .create_params => |params| {
                    try state.zwp_params.insert(state.alloc.general(), params.params_id, null);
                    try state.interface_registry.put(state.alloc.general(), params.params_id, .zwp_linux_buffer_params_v1);
                },
                else => {
                    logUnhandledRequest(object_id, req);
                    return;
                },
            },
            .zxdg_decoration_manager_v1 => |parsed| switch (parsed) {
                .get_toplevel_decoration => |_| {
                    // Whatever
                },
                else => {
                    logUnhandledRequest(object_id, req);
                    return;
                },
            },
            else => {
                logUnhandledRequest(object_id, req);
                return;
            },
        }

    }
};


fn requiresFd(req: Bindings.WaylandIncomingMessage) bool {
    switch (req) {
        inline else => |_, t| {
            const interface_message = @field(req, @tagName(t));
            if (@typeInfo(@TypeOf(interface_message)) == .@"struct") {
                return false;

            }
            switch (interface_message) {
                inline else => |_, t2| {
                    const concrete_message = @field(interface_message, @tagName(t2));
                    return @TypeOf(concrete_message).requires_fd;
                }
            }
        }
    }
}

const WlConnection = struct {
    alloc: *sphtud.alloc.Sphalloc,
    connection: std.net.Server.Connection,

    stream_reader: *WlReader,
    io_reader: *std.Io.Reader,
    io_writer: *std.Io.Writer,
    state: *ConnectionState,

    const vtable = sphtud.event.Handler.VTable {
        .poll = poll,
        .close = close,
    };

    fn init(alloc: *sphtud.alloc.Sphalloc, connection: std.net.Server.Connection, render_backend: rendering.RenderBackend, connections: *sphtud.util.RuntimeSegmentedListSphalloc(ConnectionState)) !WlConnection {
        const stream_writer = try alloc.arena().create(std.net.Stream.Writer);
        stream_writer.* = connection.stream.writer(try alloc.arena().alloc(u8, 4096));
        const io_writer = &stream_writer.interface;

        const stream_reader = try alloc.arena().create(WlReader);
        stream_reader.* =  WlReader {
            .socket = connection.stream,
            .fd_list = .{
                // 100 file descriptors received before we handle any of them seems
                // like an insanely large number for a single connection
                .items = try alloc.arena().alloc(c_int, 100),
            },
            .interface = std.Io.Reader {
                .buffer = try alloc.arena().alloc(u8, 4096),
                .vtable = &.{
                    .stream = WlReader.stream,
                },
                .seek = 0,
                .end = 0,
            },
        };
        const io_reader = &stream_reader.interface;

        try connections.append(undefined);
        const state = connections.getPtr(connections.len - 1);
        try state.initPinned(alloc, render_backend, io_writer);

        return .{
            .alloc = alloc,
            .connection = connection,
            .stream_reader = stream_reader,
            .io_reader = io_reader,
            .io_writer = io_writer,
            .state = state,

        };
    }

    fn handler(self: *WlConnection) sphtud.event.Handler {
        return .{
            .ptr = self,
            .vtable = &vtable,
            .fd = self.connection.stream.handle,
        };
    }

    fn poll(ctx: ?*anyopaque, _: *sphtud.event.Loop) sphtud.event.PollResult {
        const self: *WlConnection = @ptrCast(@alignCast(ctx));
        self.pollError()  catch |e| {
            switch (e) {
                error.ReadFailed => {
                    switch (self.stream_reader.last_res) {
                        .AGAIN => return .in_progress,
                        else => {
                            std.log.err("Failure to read wl client {t} (stream {d}), {f}", .{e, self.stream_reader.last_res, @errorReturnTrace().?});
                            return .complete;

                        },
                    }
                },
                else => {
                    std.log.err("Failure to handle wl client {t} {f}", .{e, @errorReturnTrace().?});
                    return .complete;
                },
            }
        };

        return .in_progress;
    }

    fn pollError(self: *WlConnection) !void {
        while (true) {

            const header = try self.io_reader.peekStruct(wlio.HeaderLE, .little);
            const data = (try self.io_reader.peek(header.size))[@sizeOf(wlio.HeaderLE)..];
            _ = try self.io_reader.discard(.limited(header.size));

            const req = try parseRequest(header.op, data, self.state.interface_registry.get(header.id) orelse return error.InvalidInterface);

            var fd: ?std.posix.fd_t = null;
            // FIXME: Impl
            if (requiresFd(req)) {
                // FIXME: Crashing here is insane
                //   1. It might actually just not be here yet
                //   2. The client might not send it, in which case it's better to kill the connection
                // Crash for now so that we really notice if this ever happens
                fd = self.stream_reader.fd_list.pop() orelse unreachable;
            }

            try self.state.handleMessage(header.id, req, fd);
        }
    }

    fn close(ctx: ?*anyopaque) void {
        const self: *WlConnection = @ptrCast(@alignCast(ctx));
        self.connection.stream.close();
        // FIXME: Remove connection state from list
        self.alloc.deinit();
    }
};

const WlServerContext = struct {
    server_alloc: *sphtud.alloc.Sphalloc,
    connections: *sphtud.util.RuntimeSegmentedListSphalloc(ConnectionState),
    render_backend: rendering.RenderBackend,

    pub fn generate(self: *WlServerContext, connection: std.net.Server.Connection) !sphtud.event.Handler {
        const connection_alloc = try self.server_alloc.makeSubAlloc("connection");
        errdefer connection_alloc.deinit();

        const ret = try connection_alloc.arena().create(WlConnection);
        ret.* = try WlConnection.init(connection_alloc, connection, self.render_backend, self.connections);

        return ret.handler();
    }

    pub fn close(self: *WlServerContext) void {
        self.server_alloc.deinit();
    }
};

const VsyncHandler = struct {
    render_backend: rendering.RenderBackend,
    connection_states: *sphtud.util.RuntimeSegmentedListSphalloc(ConnectionState),
    last: std.time.Instant,

    const vtable = sphtud.event.Handler.VTable {
        .poll = poll,
        .close = close,
    };

    fn handler(self: *VsyncHandler) sphtud.event.Handler {
        return .{
            .ptr = self,
            .fd = self.render_backend.event_fd,
            .vtable = &vtable,
        };
    }

    fn poll(ctx: ?*anyopaque, _: *sphtud.event.Loop) sphtud.event.PollResult {
        const self: *VsyncHandler = @ptrCast(@alignCast(ctx));
        self.render_backend.service() catch {
            return .complete;
        };

        if (!self.render_backend.wantsRender()) {
            return .in_progress;
        }

        const now = std.time.Instant.now() catch return .complete;
        defer self.last = now;

        var it = self.connection_states.iter();
        while (it.next()) |state| {
            if (state.frame_callback) |id| {
                var callback = Bindings.WlCallback { .id = id };
                callback.done(state.io_writer, .{
                    .callback_data = 0,
                }) catch unreachable;

                // FIXME: Do we have to ensure only the buffers currently queued get relaesed
                const buffer_keys = state.wl_buffers.mapping.keys();
                for (buffer_keys) |buffer_id| {
                    var buffer = Bindings.WlBuffer { .id = buffer_id };
                    buffer.release(state.io_writer, .{}) catch unreachable;
                }
                // FIXME: Cleanup any corresponding buffers
                state.wl_buffers.storage.clearRetainingCapacity();
                state.wl_buffers.mapping.clearRetainingCapacity();

                state.io_writer.flush() catch unreachable;

            }
        }

        std.debug.print("flipppy floppy {d}\n", .{now.since(self.last) / std.time.ns_per_ms});

        // Notify all connections that it is time to rerender
        return .in_progress;
    }

    fn close(ctx: ?*anyopaque) void {
        _ = ctx;
    }
};

pub fn main() !void {
    var tpa: sphtud.alloc.TinyPageAllocator = undefined;
    try tpa.initPinned();

    var root_alloc: sphtud.alloc.Sphalloc = undefined;
    try root_alloc.initPinned(tpa.allocator(), "root");

    var scratch = sphtud.alloc.BufAllocator.init(
        try root_alloc.arena().alloc(u8, 1 * 1024 * 1024),
    );

    var connections = try sphtud.util.RuntimeSegmentedListSphalloc(ConnectionState).init(
        root_alloc.arena(),
        root_alloc.block_alloc.allocator(),
        10,
        10 * 1024,
    );

    const render_backend = try rendering.initRenderBackend(root_alloc.arena());

    var vsync_handler = VsyncHandler {
        .render_backend = render_backend,
        .last = try std.time.Instant.now(),
        .connection_states = &connections,
    };

    var loop = try sphtud.event.Loop.init(&root_alloc);
    try loop.register(vsync_handler.handler());
    var server_context = WlServerContext{
        .server_alloc = try root_alloc.makeSubAlloc("server"),
        .connections = &connections,
        .render_backend = render_backend,
    };

    const socket = try createWaylandSocket(scratch.linear());
    var server = try sphtud.event.net.server(socket, &server_context);
    try loop.register(server.handler());

    while (true) {
        scratch.reset();
        try loop.wait(&scratch);
    }
}
