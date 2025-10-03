const std = @import("std");
const sphtud = @import("sphtud");
const Reader = @import("Reader.zig");
const rendering = @import("../rendering.zig");
const Bindings = @import("wayland_bindings");
const wlio = @import("wlio");
const CompositorState = @import("../CompositorState.zig");

const Connection = @This();

alloc: *sphtud.alloc.Sphalloc,
connection: std.net.Server.Connection,

stream_reader: *Reader,
io_reader: *std.Io.Reader,
io_writer: *std.Io.Writer,
// FIXME: WTF is the difference between state and us? Remove this...
state: *State,

const vtable = sphtud.event.Handler.VTable{
    .poll = poll,
    .close = close,
};

pub fn init(alloc: *sphtud.alloc.Sphalloc, connection: std.net.Server.Connection, compositor_state: *CompositorState, render_backend: rendering.RenderBackend, connections: *sphtud.util.RuntimeSegmentedListSphalloc(State), renderable_id: usize) !Connection {
    const stream_writer = try alloc.arena().create(std.net.Stream.Writer);
    stream_writer.* = connection.stream.writer(try alloc.arena().alloc(u8, 4096));
    const io_writer = &stream_writer.interface;

    const stream_reader = try alloc.arena().create(Reader);
    stream_reader.* = try Reader.init(alloc.arena(), connection.stream);
    const io_reader = &stream_reader.interface;

    try connections.append(undefined);
    const state = connections.getPtr(connections.len - 1);

    try state.initPinned(alloc, render_backend, compositor_state, renderable_id, io_writer);

    return .{
        .alloc = alloc,
        .connection = connection,
        .stream_reader = stream_reader,
        .io_reader = io_reader,
        .io_writer = io_writer,
        .state = state,
    };
}

pub fn handler(self: *Connection) sphtud.event.Handler {
    return .{
        .ptr = self,
        .vtable = &vtable,
        .fd = self.connection.stream.handle,
    };
}

pub fn releaseBuffer(self: *Connection, wl_buffer_id: u32) !void {
    const wl_buffer = Bindings.WlBuffer{ .id = wl_buffer_id };
    try wl_buffer.release(self.io_writer, .{});
}

pub fn requestFrame(self: *Connection, surface_id: WlSurfaceId) !void {
    const surface = self.state.wl_surfaces.get(surface_id) orelse return error.InvalidSurface;
    const callback_id = surface.callback_id orelse return;
    const wl_callback = Bindings.WlCallback{ .id = callback_id };
    try wl_callback.done(self.io_writer, .{
        .callback_data = 0,
    });
}

pub fn updateRenderableHandle(self: *Connection, surface: WlSurfaceId, handle: CompositorState.Renderables.Handle) void {
    self.state.wl_surfaces.getPtr(surface).?.handle = handle;
}

fn poll(ctx: ?*anyopaque, _: *sphtud.event.Loop) sphtud.event.PollResult {
    const self: *Connection = @ptrCast(@alignCast(ctx));
    self.pollError() catch |e| {
        switch (e) {
            error.ReadFailed => {
                switch (self.stream_reader.last_res) {
                    .AGAIN => return .in_progress,
                    else => {
                        std.log.err("Failure to read wl client {t} (stream {d}), {f}", .{ e, self.stream_reader.last_res, @errorReturnTrace().? });
                        return .complete;
                    },
                }
            },
            else => {
                std.log.err("Failure to handle wl client {t} {f}", .{ e, @errorReturnTrace().? });
                return .complete;
            },
        }
    };

    return .in_progress;
}

fn pollError(self: *Connection) !void {
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

        try self.state.handleMessage(self, header.id, req, fd);
    }
}

fn close(ctx: ?*anyopaque) void {
    const self: *Connection = @ptrCast(@alignCast(ctx));
    var surface_it = self.state.wl_surfaces.iter();
    while (surface_it.next()) |surface| {
        if (surface.val.handle) |h| {
            self.state.compositor_state.removeRenderable(h);
        }
    }

    // FIXME: All file descriptors should be attached to a pool and closed

    self.connection.stream.close();
    // FIXME: Remove connection state from list
    self.alloc.deinit();
}

pub const XdgSurfaceId = struct { inner: u32 };
pub const WlSurfaceId = struct { inner: u32 };
pub const WlBufferId = struct { inner: u32 };

pub const State = struct {
    alloc: *sphtud.alloc.Sphalloc,
    io_writer: *std.Io.Writer,
    compositor_state: *CompositorState,
    renderable_id: usize,

    interface_registry: InterfaceRegistry,
    wl_surfaces: sphtud.util.AutoHashMapSphalloc(WlSurfaceId, Surface),
    wl_buffers: sphtud.util.AutoHashMapSphalloc(WlBufferId, Buffer),

    zwp_params: IndirectLookupOwned(?BufferParams),

    xdg_surfaces: sphtud.util.AutoHashMapSphalloc(XdgSurfaceId, WlSurfaceId),
    windows: IndirectLookupOwned(Window),

    render_backend: rendering.RenderBackend,

    const typical_surfaces = 8;
    const max_surfaces = 100;

    const typical_buffers = typical_surfaces * 2;
    const max_buffers = max_surfaces * 2;

    fn initPinned(self: *State, alloc: *sphtud.alloc.Sphalloc, render_backend: rendering.RenderBackend, compositor_state: *CompositorState, renderable_id: usize, io_writer: *std.Io.Writer) !void {
        self.* = .{
            .alloc = alloc,
            .io_writer = io_writer,
            .compositor_state = compositor_state,
            .renderable_id = renderable_id,
            .interface_registry = try .init(alloc.general()),
            .wl_surfaces = try .init(alloc.arena(), alloc.block_alloc.allocator(), typical_surfaces, max_surfaces),
            .xdg_surfaces = undefined,
            .windows = .init(),
            .wl_buffers = try .init(alloc.arena(), alloc.block_alloc.allocator(), typical_surfaces, max_surfaces),
            .zwp_params = .init(),
            .render_backend = render_backend,
        };

        self.xdg_surfaces = try .init(alloc.arena(), alloc.block_alloc.allocator(), typical_surfaces, max_surfaces);
    }

    fn handleMessage(state: *State, self: *Connection, object_id: u32, req: Bindings.WaylandIncomingMessage, fd: ?std.posix.fd_t) !void {
        const supported_interfaces: []const Bindings.WaylandInterfaceType = &.{
            .wl_compositor,
            .xdg_wm_base,
            .zxdg_decoration_manager_v1,
            .zwp_linux_dmabuf_v1,
        };

        switch (req) {
            .wl_display => |parsed| switch (parsed) {
                .get_registry => |params| {
                    try state.interface_registry.put(state.alloc.general(), params.registry, .wl_registry);

                    const registry = Bindings.WlRegistry{ .id = params.registry };
                    for (supported_interfaces) |interface| {
                        try registry.global(state.io_writer, .{
                            .name = @intFromEnum(interface) + 1,
                            .interface = @tagName(interface),
                            .version = Bindings.getInterfaceVersion(interface),
                        });
                    }

                    try state.io_writer.flush();
                },
                .sync => |params| {
                    const callback = Bindings.WlCallback{ .id = params.callback };
                    try callback.done(state.io_writer, .{
                        .callback_data = 0,
                    });
                    try state.io_writer.flush();
                },
            },
            .wl_registry => |parsed| switch (parsed) {
                .bind => |params| {
                    // FIXME: These might have to be 0xff000000 or higher...
                    const interface: Bindings.WaylandInterfaceType = @enumFromInt(params.name - 1);
                    try state.interface_registry.put(state.alloc.general(), params.id, interface);
                },
            },
            .wl_compositor => |parsed| switch (parsed) {
                .create_surface => |params| {
                    const wl_surface_id = WlSurfaceId{ .inner = params.id };
                    try state.wl_surfaces.put(wl_surface_id, .{});
                    try state.interface_registry.put(state.alloc.general(), params.id, .wl_surface);
                },
                else => {
                    logUnhandledRequest(object_id, req);
                    return;
                },
            },
            .xdg_wm_base => |parsed| switch (parsed) {
                .get_xdg_surface => |params| {
                    const wl_surface_id = WlSurfaceId{ .inner = params.surface };

                    const xdg_id = XdgSurfaceId{ .inner = params.id };
                    try state.xdg_surfaces.put(xdg_id, wl_surface_id);

                    try state.interface_registry.put(state.alloc.general(), params.id, .xdg_surface);

                    var xdg_surf = Bindings.XdgSurface{ .id = xdg_id.inner };
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
                    try state.windows.insert(state.alloc.general(), params.id, .{
                        .alloc = try state.alloc.makeSubAlloc("window"),
                    });
                    try state.interface_registry.put(state.alloc.general(), params.id, .xdg_toplevel);
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
                    const wl_surface_id = WlSurfaceId{ .inner = object_id };
                    const surface = state.wl_surfaces.getPtr(wl_surface_id) orelse return error.InvalidSurface;

                    if (surface.buffer) |buf_id| {
                        const buffer = state.wl_buffers.get(buf_id) orelse unreachable;

                        const render_buffer = rendering.RenderBuffer{
                            .wl_buffer = buf_id.inner,
                            .buf_fd = buffer.buf_params.fd,
                            .modifiers = buffer.buf_params.modifier,
                            .offset = buffer.buf_params.offset,
                            .plane_idx = buffer.buf_params.plane_idx,
                            .stride = buffer.buf_params.stride,
                            .width = buffer.width,
                            .height = buffer.height,
                            .format = buffer.format,
                        };

                        if (surface.handle) |h| {
                            const metadata = state.compositor_state.getMetadata(h);
                            metadata.next_buffer = render_buffer;
                        } else {
                            surface.handle = try state.compositor_state.pushRenderable(self, wl_surface_id, render_buffer);
                        }
                    }
                },
                .frame => |params| {
                    const wl_surface_id = WlSurfaceId{ .inner = object_id };
                    const surface = state.wl_surfaces.getPtr(wl_surface_id) orelse return error.InvalidSurface;
                    surface.callback_id = params.callback;
                },
                .attach => |params| {
                    const wl_surface_id = WlSurfaceId{ .inner = object_id };
                    const surface = state.wl_surfaces.getPtr(wl_surface_id) orelse return error.InvalidSurface;
                    surface.buffer = WlBufferId{ .inner = params.buffer };
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

                    const wl_buffer_id = WlBufferId{ .inner = params.buffer_id };
                    try state.wl_buffers.put(wl_buffer_id, .{
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
                    logUnhandledRequest(object_id, req);
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
        std.log.debug("Registering {d} -> {t}", .{ object_id, interface_type });
        try self.inner.putNoClobber(alloc, object_id, interface_type);
    }

    fn get(self: *const InterfaceRegistry, object_id: u32) ?Bindings.WaylandInterfaceType {
        return self.inner.get(object_id);
    }
};

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

fn logUnhandledRequest(object_id: u32, req: Bindings.WaylandIncomingMessage) void {
    std.log.warn("Unhandled request by object {d}, {any}", .{ object_id, req });
}

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
                },
            }
        },
    }
}

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
        // FIXME: I don't think this double map thing is really helping us at all
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

const Surface = struct {
    buffer: ?WlBufferId = null,
    handle: ?CompositorState.Renderables.Handle = null,
    callback_id: ?u32 = null,
};

const Window = struct {
    alloc: *sphtud.alloc.Sphalloc, // owned
    title: []const u8 = &.{}, // alloc.general()
    app_id: []const u8 = &.{}, // alloc.general()

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
