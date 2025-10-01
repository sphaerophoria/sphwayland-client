const std = @import("std");
const wlio = @import("wlio");
const Bindings = @import("wayland_bindings");
const sphtud = @import("sphtud");
const fd_cmsg = @import("fd_cmsg");
const backend = @import("backend.zig");

const CmsgHdr = extern struct {
    cmsg_len: usize,
    cmsg_level: c_int,
    cmsg_type: c_int,
};

const WlReader = struct {
    socket: std.net.Stream,
    fd_list: sphtud.util.CircularBuffer(std.posix.fd_t),
    interface: std.Io.Reader,

    fn stream(r: *std.Io.Reader, writer: *std.Io.Writer, limit: std.Io.Limit) error{EndOfStream,ReadFailed,WriteFailed}!usize{
        const self: *WlReader = @fieldParentPtr("interface", r);

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
            else => return error.ReadFailed,
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

    drm_ctx: *backend.Drm,

    fn initPinned(self: *ConnectionState, alloc: *sphtud.alloc.Sphalloc, drm_ctx: *backend.Drm, io_writer: *std.Io.Writer) !void {
        self.* = .{
            .alloc = alloc,
            .io_writer = io_writer,
            .interface_registry = try .init(alloc.general()),
            .wl_surfaces = .init(),
            .xdg_surfaces = undefined,
            .windows = .init(),
            .wl_buffers = .init(),
            .zwp_params = .init(),
            .drm_ctx = drm_ctx,
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

                        try state.drm_ctx.displayDmaBuf(
                            buffer.buf_params.fd,
                            buffer.buf_params.modifier,
                            buffer.buf_params.offset,
                            buffer.buf_params.plane_idx,
                            buffer.buf_params.stride,
                            buffer.width,
                            buffer.height,
                            buffer.format,
                        );
                    }

                    try state.io_writer.flush();
                },
                .frame => |params| {
                    var callback = Bindings.WlCallback { .id = params.callback };
                    try callback.done(state.io_writer, .{
                        .callback_data = 0,
                    });

                    try state.io_writer.flush();
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

fn handleConnection(scratch: *sphtud.alloc.BufAllocator, alloc: *sphtud.alloc.Sphalloc, drm_ctx: *backend.Drm, connection: std.net.Server.Connection) !void {

    // FIXME:  dma buf fds are not destroyed on exit

    var stream_writer = connection.stream.writer(try scratch.allocator().alloc(u8, 4096));
    const io_writer = &stream_writer.interface;

    var stream_reader = WlReader {
        .socket = connection.stream,
        .fd_list = .{
            // 100 file descriptors received before we handle any of them seems
            // like an insanely large number for a single connection
            .items = try scratch.allocator().alloc(c_int, 100),
        },
        .interface = std.Io.Reader {
            .buffer = try scratch.allocator().alloc(u8, 4096),
            .vtable = &.{
                .stream = WlReader.stream,
            },
            .seek = 0,
            .end = 0,
        },
    };
    const io_reader = &stream_reader.interface;

    var state: ConnectionState = undefined;
    try state.initPinned(alloc, drm_ctx, io_writer);

    while (true) {
        const cp = scratch.checkpoint();
        defer scratch.restore(cp);

        const header = try io_reader.takeStruct(wlio.HeaderLE, .little);

        const data = try io_reader.readAlloc(scratch.allocator(), header.size - @sizeOf(wlio.HeaderLE));
        const req = try parseRequest(header.op, data, state.interface_registry.get(header.id) orelse return error.InvalidInterface);

        var fd: ?std.posix.fd_t = null;
        // FIXME: Impl
        if (requiresFd(req)) {
            // FIXME: Crashing here is insane
            //   1. It might actually just not be here yet
            //   2. The client might not send it, in which case it's better to kill the connection
            // Crash for now so that we really notice if this ever happens
            fd = stream_reader.fd_list.pop() orelse unreachable;
        }

        try state.handleMessage(header.id, req, fd);
    }
}

pub fn main() !void {
    var tpa: sphtud.alloc.TinyPageAllocator = undefined;
    try tpa.initPinned();

    var root_alloc: sphtud.alloc.Sphalloc = undefined;
    try root_alloc.initPinned(tpa.allocator(), "root");

    var scratch = sphtud.alloc.BufAllocator.init(
        try root_alloc.arena().alloc(u8, 1 * 1024 * 1024),
    );

    var drm = try backend.initializeDrm();

    var socket = try createWaylandSocket(scratch.linear());
    while (true) {
        // FIXME hook up to event loop
        const connection = try socket.accept();
        defer connection.stream.close();

        var connection_alloc = try root_alloc.makeSubAlloc("connection");
        defer connection_alloc.deinit();

        scratch.reset();

        handleConnection(&scratch, connection_alloc, &drm, connection) catch |e| switch (e) {
            error.EndOfStream => {
                std.log.debug("connection closed", .{});
            },
            else => {
                std.log.err("connection failed: {t}\n", .{e});
            }
        };
    }
}
