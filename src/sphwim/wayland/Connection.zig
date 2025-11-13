const std = @import("std");
const sphtud = @import("sphtud");
const rendering = @import("../rendering.zig");
const Bindings = @import("wayland_bindings");
const wlio = @import("wlio");
const Reader = wlio.Reader;
const FdPool = @import("../FdPool.zig");
const CompositorState = @import("../CompositorState.zig");
const system_gl = @import("../system_gl.zig");
const server = @import("../wayland.zig");
const wl_cmsg = @import("wl_cmsg");

const Connection = @This();

const logger = std.log.scoped(.wl_connection);

alloc: *sphtud.alloc.Sphalloc,
scratch: sphtud.alloc.LinearAllocator,
fd_pool: *FdPool,

format_table: server.FormatTable,

rand: std.Random,

connection: std.net.Server.Connection,
stream_reader: *Reader,
io_reader: *std.Io.Reader,
io_writer: *std.Io.Writer,

compositor_state: *CompositorState,
gbm_context: *const system_gl.GbmContext,

interface_registry: InterfaceRegistry,
wl_surfaces: sphtud.util.AutoHashMap(WlSurfaceId, Surface),
wl_buffers: sphtud.util.AutoHashMap(WlBufferId, *RefCountedRenderBuffer),
wl_pointers: sphtud.util.AutoHashMap(WlPointerId, Pointer),
zwp_params: sphtud.util.AutoHashMap(ZwpBufferParamsId, ?BufferParams),
xdg_surfaces: sphtud.util.AutoHashMap(XdgSurfaceId, WlSurfaceId),
windows: sphtud.util.AutoHashMap(XdgToplevelId, Window),

const typical_surfaces = 2;
const max_surfaces = 100;

const typical_windows = 2;
const max_windows = 100;

const typical_zwp_buffers = 2;
const max_zwp_buffers = 100;

const typical_buffers = typical_surfaces * 2;
const max_buffers = max_surfaces * 2;
const display_id = 1;

const vtable = sphtud.event.Loop.Handler.VTable{
    .poll = poll,
    .close = close,
};

pub fn init(
    alloc: *sphtud.alloc.Sphalloc,
    scratch: sphtud.alloc.LinearAllocator,
    connection: std.net.Server.Connection,
    rand: std.Random,
    compositor_state: *CompositorState,
    gbm_context: *const system_gl.GbmContext,
    format_table: server.FormatTable,
) !Connection {
    const stream_writer = try alloc.arena().create(std.net.Stream.Writer);
    stream_writer.* = connection.stream.writer(try alloc.arena().alloc(u8, 4096));
    const io_writer = &stream_writer.interface;

    const fd_pool = try alloc.arena().create(FdPool);
    fd_pool.* = try .init(alloc, 8, 100);

    // FIXME: Make sure we're closing fds
    const stream_reader = try alloc.arena().create(Reader);
    stream_reader.* = try Reader.init(alloc.arena(), connection.stream);
    const io_reader = &stream_reader.interface;

    return .{
        .alloc = alloc,
        .scratch = scratch,
        .connection = connection,
        .rand = rand,
        .fd_pool = fd_pool,
        .format_table = format_table,
        .stream_reader = stream_reader,
        .io_writer = io_writer,
        .io_reader = io_reader,
        .compositor_state = compositor_state,
        .gbm_context = gbm_context,
        .interface_registry = try .init(alloc),
        .wl_surfaces = try .init(alloc.arena(), alloc.expansion(), typical_surfaces, max_surfaces),
        // FIXME: I don't know pick a sane number
        .wl_pointers = try .init(alloc.arena(), alloc.expansion(), 4, 4),
        .xdg_surfaces = try .init(alloc.arena(), alloc.expansion(), typical_surfaces, max_surfaces),
        .windows = try .init(alloc.arena(), alloc.expansion(), typical_windows, max_windows),
        .wl_buffers = try .init(alloc.arena(), alloc.expansion(), typical_surfaces, max_surfaces),
        .zwp_params = try .init(alloc.arena(), alloc.expansion(), typical_zwp_buffers, max_zwp_buffers),
    };
}

pub fn handler(self: *Connection) sphtud.event.Loop.Handler {
    return .{
        .ptr = self,
        .vtable = &vtable,
        .fd = self.connection.stream.handle,
        .desired_events = .{
            .read = true,
            .write = true,
        },
    };
}

pub fn requestFrame(self: *Connection, surface_id: WlSurfaceId) !void {
    const surface = self.wl_surfaces.getPtr(surface_id) orelse return error.InvalidSurface;
    const callback_id = surface.callback_id orelse return;

    const wl_callback = Bindings.WlCallback{ .id = callback_id };
    try wl_callback.done(self.io_writer, .{
        .callback_data = 0,
    });

    surface.callback_id = null;
    self.interface_registry.remove(callback_id);

    var global = Bindings.WlDisplay{ .id = display_id };
    try global.deleteId(self.io_writer, .{ .id = callback_id });
    try self.io_writer.flush();
}

pub fn requestResize(self: *Connection, wl_surface_id: WlSurfaceId, width: i32, height: i32) !void {
    const surface = self.wl_surfaces.getPtr(wl_surface_id) orelse return error.InvalidWlSurfaceId;
    const xdg_surface_id = surface.xdg_surface_id orelse return error.NotXdgSurface;
    const toplevel_id = surface.toplevel_id orelse return error.InvalidResizeTarget;

    const toplevel_interface = Bindings.XdgToplevel{ .id = toplevel_id.inner };
    try toplevel_interface.configure(self.io_writer, .{
        .width = width,
        .height = height,
        // FIXME: Hardcoded
        .states = std.mem.asBytes(&[2]u32{ 3, 4 }),
    });

    try self.emitXdgSurfaceConfigure(xdg_surface_id, surface);

    try self.io_writer.flush();
}

pub fn closeWindow(self: *Connection, toplevel_id: XdgToplevelId) !void {
    var toplevel_interface = Bindings.XdgToplevel{ .id = toplevel_id.inner };
    try toplevel_interface.close(self.io_writer, .{});
    try self.io_writer.flush();
}

pub fn notifyCursorPosition(self: *Connection, surface_id: WlSurfaceId, x: i32, y: i32) !void {
    std.debug.print("Cursor pos time :) {d} pointers\n", .{self.wl_pointers.len});
    var pointer_it = self.wl_pointers.iter();
    while (pointer_it.next()) |item| {
        var interface = Bindings.WlPointer{ .id = item.key.inner };
        if (item.val.isInSurface(surface_id)) {
            try interface.motion(self.io_writer, .{
                // FIXME: lol
                .time = 0,
                .surface_x = wlio.WlFixed.fromi32(x),
                .surface_y = wlio.WlFixed.fromi32(y),
            });
        } else {
            if (item.val.current_surface) |to_leave| {
                try interface.leave(self.io_writer, .{
                    // FIXME: ?????
                    .serial = item.val.serial,
                    .surface = to_leave.inner,
                });
            }

            // FIXME: i made this up
            item.val.serial +%= 1;

            try interface.enter(self.io_writer, .{
                .serial = item.val.serial,
                .surface = surface_id.inner,
                .surface_x = wlio.WlFixed.fromi32(x),
                .surface_y = wlio.WlFixed.fromi32(y),
            });
            item.val.current_surface = surface_id;
        }
    }
    try self.io_writer.flush();
}

pub fn updateRenderableHandle(self: *Connection, surface: WlSurfaceId, handle: CompositorState.Renderables.Handle) void {
    self.wl_surfaces.getPtr(surface).?.committed_buffer_handle = handle;
}

fn poll(ctx: ?*anyopaque, _: *sphtud.event.Loop, _: sphtud.event.PollReason) sphtud.event.Loop.PollResult {
    const self: *Connection = @ptrCast(@alignCast(ctx));
    var message_buf: [4096]u8 = undefined;
    var diagnostics = HandleMessageDiagnostics{
        .msg_buf = &message_buf,
        .err_typ = .none,
        .message = "",
    };

    self.pollError(&diagnostics) catch |e| {
        const display = Bindings.WlDisplay{ .id = display_id };

        switch (e) {
            error.ReadFailed => {
                switch (self.stream_reader.last_res) {
                    .AGAIN => return .in_progress,
                    else => {
                        logWithTrace("failure to read wl client (stream {d})", .{self.stream_reader.last_res});
                        return .complete;
                    },
                }
            },
            error.WriteFailed => {
                logWithTrace("failure to write wl client", .{});
                return .complete;
            },
            error.NoFd => {
                display.err(self.io_writer, .{
                    .object_id = display_id,
                    .code = 1, // invalid_method
                    .message = "could not find fd for message",
                }) catch {};
                self.io_writer.flush() catch {};
                return .complete;
            },
            error.OutOfMemory => {
                display.err(self.io_writer, .{
                    .object_id = display_id,
                    .code = 2, // no memory
                    .message = "memory allocated for client exhausted",
                }) catch {};
                self.io_writer.flush() catch {};
                return .complete;
            },
            error.EndOfStream => {
                logWithTrace("client closed connection", .{});
                return .complete;
            },
            error.Diagnostic => {
                const code: u32 = switch (diagnostics.err_typ) {
                    .invalid_object => 0,
                    .invalid_method => 1,
                    .none, .internal_err => 3,
                };

                display.err(self.io_writer, .{
                    .object_id = display_id,
                    .code = code,
                    .message = diagnostics.message,
                }) catch {};
                self.io_writer.flush() catch {};
                logWithTrace("{s}", .{diagnostics.message});
                return .complete;
            },
        }
    };

    return .in_progress;
}

fn logWithTrace(comptime msg: []const u8, args: anytype) void {
    logger.err(msg, args);
    if (@errorReturnTrace()) |t| {
        logger.err("{f}", .{t});
    }
}
fn pollError(self: *Connection, diagnostics: *HandleMessageDiagnostics) !void {
    var retrying = false;
    while (true) {
        const header = try self.io_reader.peekStruct(wlio.HeaderLE, .little);
        const data = (try self.io_reader.peek(header.size))[@sizeOf(wlio.HeaderLE)..];

        const interface_id = self.interface_registry.get(header.id) orelse {
            return diagnostics.makeInvalidObjectError("cannot find interface for object {d}", .{header.id});
        };

        const req = parseRequest(header.op, data, interface_id) catch |e| switch (e) {
            error.InvalidLen, error.UnknownMessage => {
                return diagnostics.makeInvalidMethodError("received malformed request", .{});
            },
        };

        var fd: ?std.posix.fd_t = null;
        if (wlio.requiresFd(req)) {
            fd = self.stream_reader.fd_list.pop() orelse {
                if (!retrying) {
                    // While wayland messages do have a max size significantly
                    // larger than this, typical messages will be ~8 bytes for
                    // the header + < 5 ints alongside
                    //
                    // This means most messages sill be <= 28 bytes. Filling a
                    // 4K buffer would give us > 140 messages
                    //
                    // If someone is sending a message requiring an fd 140
                    // messages before the file descriptor comes in, they can
                    // get shut down
                    //
                    // Try one time to fill the buffer as much as possible, if
                    // we still don't have the file descriptor, return an error
                    try self.io_reader.fillMore();
                    retrying = true;
                    continue;
                }

                return error.NoFd;
            };

            self.fd_pool.register(fd.?) catch |e| {
                std.posix.close(fd.?);
                return e;
            };
        }

        _ = try self.io_reader.discard(.limited(header.size));
        retrying = false;

        try self.handleMessage(header.id, req, fd, diagnostics);
        try self.io_writer.flush();
    }
}

fn close(ctx: ?*anyopaque) void {
    const self: *Connection = @ptrCast(@alignCast(ctx));
    var surface_it = self.wl_surfaces.iter();
    while (surface_it.next()) |surface| {
        if (surface.val.committed_buffer_handle) |h| {
            self.compositor_state.removeRenderable(h);
        }
    }

    self.fd_pool.closeAll();
    self.connection.stream.close();
    self.alloc.deinit();
}

pub const XdgSurfaceId = struct { inner: u32 };
pub const XdgToplevelId = struct { inner: u32 };
pub const WlSurfaceId = struct { inner: u32 };
pub const WlBufferId = struct { inner: u32 };
pub const WlPointerId = struct { inner: u32 };
pub const ZwpBufferParamsId = struct { inner: u32 };

const RequestFormatter = struct {
    inner: Bindings.WaylandIncomingMessage,

    pub fn format(self: RequestFormatter, writer: *std.Io.Writer) !void {
        switch (self.inner) {
            inline else => |val, t| {
                switch (@typeInfo(@TypeOf(val))) {
                    .@"struct" => {
                        try writer.print("{t}", .{t});
                    },
                    .@"union" => {
                        switch (val) {
                            inline else => |inner_val, inner_t| {
                                try writer.print("{t}::{t} {any}", .{ t, inner_t, inner_val });
                            },
                        }
                    },
                    else => comptime unreachable,
                }
            },
        }
    }
};

fn formatRequest(req: Bindings.WaylandIncomingMessage) RequestFormatter {
    return .{ .inner = req };
}

const HandleMessageDiagnostics = struct {
    msg_buf: []u8,
    err_typ: ErrType,
    message: [:0]const u8,

    const ErrType = union(enum) {
        none,
        internal_err,
        invalid_object,
        invalid_method,
    };

    fn makeMessage(self: *HandleMessageDiagnostics, comptime msg: []const u8, args: anytype) [:0]const u8 {
        return std.fmt.bufPrintZ(self.msg_buf, msg, args) catch {
            self.msg_buf[self.msg_buf.len - 1] = 0;
            return @ptrCast(self.msg_buf);
        };
    }

    fn makeInternalErr(self: *HandleMessageDiagnostics, comptime msg: []const u8, args: anytype) HandleMessageError {
        self.err_typ = .internal_err;
        self.message = self.makeMessage(msg, args);

        return error.Diagnostic;
    }

    fn makeInvalidMethodError(self: *HandleMessageDiagnostics, comptime msg: []const u8, args: anytype) HandleMessageError {
        self.err_typ = .invalid_method;
        self.message = self.makeMessage(msg, args);

        return error.Diagnostic;
    }

    fn makeInvalidObjectError(self: *HandleMessageDiagnostics, comptime msg: []const u8, args: anytype) HandleMessageError {
        self.err_typ = .invalid_object;
        self.message = self.makeMessage(msg, args);

        return error.Diagnostic;
    }
};

const HandleMessageError = error{
    OutOfMemory,
    Diagnostic,
    WriteFailed,
};

fn handleMessage(self: *Connection, object_id: u32, req: Bindings.WaylandIncomingMessage, fd: ?std.posix.fd_t, diagnostics: *HandleMessageDiagnostics) HandleMessageError!void {
    logger.debug("Received {f}", .{formatRequest(req)});

    const supported_interfaces: []const Bindings.WaylandInterfaceType = &.{
        .wl_compositor,
        .xdg_wm_base,
        .zxdg_decoration_manager_v1,
        .zwp_linux_dmabuf_v1,
        .wl_seat,
        .wl_shm,
    };

    switch (req) {
        .wl_display => |parsed| switch (parsed) {
            .get_registry => |params| {
                try self.interface_registry.put(params.registry, .wl_registry, diagnostics);

                const registry = Bindings.WlRegistry{ .id = params.registry };
                for (supported_interfaces) |interface| {
                    try registry.global(self.io_writer, .{
                        .name = @intFromEnum(interface),
                        .interface = @tagName(interface),
                        .version = Bindings.getInterfaceVersion(interface),
                    });
                }
            },
            .sync => |params| {
                // This is just a way for the caller to wait for all previous
                // messages to complete. Immediately send back what they gave
                // us
                const callback = Bindings.WlCallback{ .id = params.callback };
                try callback.done(self.io_writer, .{
                    .callback_data = 0,
                });
            },
        },
        .wl_registry => |parsed| switch (parsed) {
            .bind => |params| {
                const interface: Bindings.WaylandInterfaceType = @enumFromInt(params.name);
                try self.interface_registry.put(params.id, interface, diagnostics);

                if (params.name == @intFromEnum(Bindings.WaylandInterfaceType.wl_seat)) {
                    const wl_seat_interface = Bindings.WlSeat{ .id = params.id };
                    try wl_seat_interface.capabilities(self.io_writer, .{
                        // Advertising this causes crashes in glfw
                        .capabilities = 0,
                    });
                }
            },
        },
        .wl_region => |parsed| switch (parsed) {
            .destroy => {
                self.interface_registry.remove(object_id);
            },
            else => logUnhandledRequest(object_id, req),
        },
        .wl_compositor => |parsed| switch (parsed) {
            .create_surface => |params| {
                const wl_surface_id = WlSurfaceId{ .inner = params.id };
                try self.wl_surfaces.put(wl_surface_id, .{});
                try self.interface_registry.put(params.id, .wl_surface, diagnostics);
            },
            .create_region => |params| {
                try self.interface_registry.put(params.id, .wl_region, diagnostics);
            },
        },
        .wl_shm => |parsed| switch (parsed) {
            .create_pool => |params| {
                try self.interface_registry.put(params.id, .wl_shm_pool, diagnostics);
            },
            else => {
                logUnhandledRequest(object_id, req);
                return;
            },
        },
        .wl_seat => |parsed| switch (parsed) {
            .get_pointer => |params| {
                const pointer_id = WlPointerId{ .inner = params.id };
                try self.wl_pointers.put(pointer_id, .{});
                try self.interface_registry.put(params.id, .wl_pointer, diagnostics);
            },
            else => logUnhandledRequest(object_id, req),
        },
        .wl_shm_pool => |parsed| switch (parsed) {
            .destroy => {
                self.interface_registry.remove(object_id);
            },
            else => logUnhandledRequest(object_id, req),
        },
        .xdg_wm_base => |parsed| switch (parsed) {
            .get_xdg_surface => |params| {
                const wl_surface_id = WlSurfaceId{ .inner = params.surface };
                const xdg_id = XdgSurfaceId{ .inner = params.id };

                const surface = self.wl_surfaces.getPtr(wl_surface_id) orelse {
                    return diagnostics.makeInvalidMethodError("get_xdg_surface called with invalid wl_surface handle {d}", .{params.surface});
                };

                // FIXME: If wl_surface has a role this should emit a role error

                surface.xdg_surface_id = xdg_id;
                try self.xdg_surfaces.put(xdg_id, wl_surface_id);
                try self.interface_registry.put(params.id, .xdg_surface, diagnostics);

                try self.emitXdgSurfaceConfigure(xdg_id, surface);
            },
            else => {
                logUnhandledRequest(object_id, req);
                return;
            },
        },
        .xdg_surface => |parsed| switch (parsed) {
            .get_toplevel => |params| {
                const toplevel_id = XdgToplevelId{ .inner = params.id };
                try self.windows.put(toplevel_id, .{});
                try self.interface_registry.put(params.id, .xdg_toplevel, diagnostics);
                const toplevel = Bindings.XdgToplevel{ .id = params.id };

                try toplevel.configure(self.io_writer, .{
                    .width = 0,
                    .height = 0,
                    .states = &.{},
                });

                const xdg_surface_id = XdgSurfaceId{ .inner = object_id };
                const surface = try self.getXdgSurface(xdg_surface_id, .interface, diagnostics);
                surface.toplevel_id = toplevel_id;

                try self.emitXdgSurfaceConfigure(xdg_surface_id, surface);
            },
            .ack_configure => |params| {
                const xdg_surface_id = XdgSurfaceId{ .inner = object_id };
                const surface = try self.getXdgSurface(xdg_surface_id, .interface, diagnostics);

                if (surface.outstanding_xdg_configure == params.serial) {
                    logger.debug("xdg surface {d} acked (serial {d})", .{ xdg_surface_id.inner, params.serial });
                    surface.outstanding_xdg_configure = null;
                } else {
                    logger.debug("stale ack for xdg surface {d} with serial {d}", .{ xdg_surface_id.inner, params.serial });
                }
            },
            // FIXME: handle destroy (and check that role object already destroyed)
            else => {
                logUnhandledRequest(object_id, req);
                return;
            },
        },
        .xdg_toplevel => |parsed| switch (parsed) {
            .set_title => |params| {
                const toplevel_id = XdgToplevelId{ .inner = object_id };
                const window = self.windows.getPtr(toplevel_id) orelse {
                    return diagnostics.makeInternalErr("xdg_toplevel missing internal storage {d}", .{object_id});
                };
                try window.setTitle(self.alloc.general(), params.title);
            },
            .set_app_id => |params| {
                const toplevel_id = XdgToplevelId{ .inner = object_id };
                const window = self.windows.getPtr(toplevel_id) orelse {
                    return diagnostics.makeInternalErr("xdg_toplevel missing internal storage {d}", .{object_id});
                };
                try window.setAppId(self.alloc.general(), params.app_id);
            },
            else => {
                logUnhandledRequest(object_id, req);
                return;
            },
        },
        .wl_surface => |parsed| switch (parsed) {
            .commit => {
                const wl_surface_id = WlSurfaceId{ .inner = object_id };
                const surface = try self.getWlSurface(wl_surface_id, .param, diagnostics);

                if (surface.outstanding_xdg_configure != null) {
                    logger.debug("received commit for previous xdg state, ignoring", .{});
                    return;
                }

                if (surface.pending_buffer) |next_buf| {
                    defer surface.pending_buffer = null;

                    if (surface.committed_buffer) |ref_counted_buf| {
                        ref_counted_buf.unref(self.alloc.general(), self.fd_pool);

                        const wl_buf_iface = Bindings.WlBuffer{ .id = ref_counted_buf.buf_id.inner };
                        try wl_buf_iface.release(self.io_writer, .{});
                    }

                    surface.committed_buffer = next_buf;

                    if (surface.committed_buffer_handle) |h| {
                        self.compositor_state.swapRenderableBuffer(
                            h,
                            next_buf.render_buffer,
                            next_buf.buf_id,
                        );
                    } else blk: {
                        const toplevel_id = surface.toplevel_id orelse break :blk;
                        surface.committed_buffer_handle = try self.compositor_state.pushRenderable(
                            self,
                            wl_surface_id,
                            next_buf.render_buffer,
                            next_buf.buf_id,
                            toplevel_id,
                        );
                    }
                }
            },
            .frame => |params| {
                const wl_surface_id = WlSurfaceId{ .inner = object_id };
                const surface = try self.getWlSurface(wl_surface_id, .interface, diagnostics);

                surface.callback_id = params.callback;
            },
            .attach => |params| {
                const wl_surface_id = WlSurfaceId{ .inner = object_id };
                const surface = try self.getWlSurface(wl_surface_id, .interface, diagnostics);

                const wl_buffer_id = WlBufferId{ .inner = params.buffer };
                const buffer = try self.getWlBuffer(wl_buffer_id, .param, diagnostics);

                if (surface.pending_buffer) |old_buf| old_buf.unref(self.alloc.general(), self.fd_pool);
                surface.pending_buffer = buffer.ref();
            },
            .destroy => {
                const wl_surface_id = WlSurfaceId{ .inner = object_id };

                const surface = self.wl_surfaces.remove(wl_surface_id) orelse {
                    return diagnostics.makeInternalErr("removing wl surface {d} that does not exist", .{object_id});
                };
                surface.deinit(self.alloc.general(), self.fd_pool, self.compositor_state);

                // FIXME: Check if we leak an xdg surface here
                //

                self.interface_registry.remove(object_id);
                const global = Bindings.WlDisplay{ .id = display_id };
                try global.deleteId(self.io_writer, .{
                    .id = object_id,
                });
            },
            else => {
                logUnhandledRequest(object_id, req);
                return;
            },
        },
        .zwp_linux_buffer_params_v1 => |parsed| switch (parsed) {
            .add => |params| {
                const zwp_buf_params_id = ZwpBufferParamsId{ .inner = object_id };
                const buf_params = try self.getZwpBufferParams(zwp_buf_params_id, .interface, diagnostics);
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
                const zwp_buf_params_id = ZwpBufferParamsId{ .inner = object_id };
                const buf_params_opt = try self.getZwpBufferParams(zwp_buf_params_id, .interface, diagnostics);
                const buf_params = buf_params_opt.* orelse {
                    return diagnostics.makeInvalidMethodError("zwp_linux_buffer_params_v1::create_immed called on object {d} without a populated buffer", .{object_id});
                };

                const wl_buffer_id = WlBufferId{ .inner = params.buffer_id };

                {
                    const buf = try RefCountedRenderBuffer.init(self.alloc.general(), wl_buffer_id, buf_params, params.width, params.height, params.format, params.flags);
                    errdefer buf.unref(self.alloc.general(), self.fd_pool);

                    try self.wl_buffers.put(wl_buffer_id, buf);
                }

                // Ensure that on destroy we have nothing to cleanup, it's not
                // ours anymore
                buf_params_opt.* = null;

                try self.interface_registry.put(wl_buffer_id.inner, .wl_buffer, diagnostics);

                const iface = Bindings.ZwpLinuxBufferParamsV1{ .id = object_id };
                try iface.created(self.io_writer, .{
                    .buffer = params.buffer_id,
                });
            },
            .destroy => {
                const zwp_buf_params_id = ZwpBufferParamsId{ .inner = object_id };

                const removed_params = self.zwp_params.remove(zwp_buf_params_id) orelse {
                    return diagnostics.makeInternalErr("failed to find internal storage for params buf {d}", .{object_id});
                };

                if (removed_params) |params| {
                    self.fd_pool.close(params.fd);
                }

                self.interface_registry.remove(object_id);
            },
            else => {
                logUnhandledRequest(object_id, req);
                return;
            },
        },
        .zwp_linux_dmabuf_v1 => |parsed| switch (parsed) {
            .create_params => |params| {
                const zwp_buf_params_id = ZwpBufferParamsId{ .inner = params.params_id };
                try self.zwp_params.put(zwp_buf_params_id, null);
                try self.interface_registry.put(params.params_id, .zwp_linux_buffer_params_v1, diagnostics);
            },
            .get_default_feedback => |params| {
                try self.sendSurfaceFeedback(params, diagnostics);
            },
            .get_surface_feedback => |params| {
                try self.sendSurfaceFeedback(params, diagnostics);
            },
            else => {
                logUnhandledRequest(object_id, req);
                return;
            },
        },
        .zwp_linux_dmabuf_feedback_v1 => |parsed| switch (parsed) {
            .destroy => {
                self.interface_registry.remove(object_id);
            },
        },
        .zxdg_decoration_manager_v1 => |parsed| switch (parsed) {
            .get_toplevel_decoration => |params| {
                try self.interface_registry.put(params.id, .zxdg_toplevel_decoration_v1, diagnostics);
            },
            // FIXME: handle destroy
            else => {
                logUnhandledRequest(object_id, req);
                return;
            },
        },
        .zxdg_toplevel_decoration_v1 => |parsed| switch (parsed) {
            .destroy => {
                self.interface_registry.remove(object_id);
            },
            else => logUnhandledRequest(object_id, req),
        },
        .wl_buffer => |params| switch (params) {
            .destroy => {
                const wl_buffer_id = WlBufferId{ .inner = object_id };
                const buffer = self.wl_buffers.remove(wl_buffer_id) orelse {
                    return diagnostics.makeInternalErr("trying to remove invalid wl_buffer {d}", .{object_id});
                };
                buffer.unref(self.alloc.general(), self.fd_pool);
                self.interface_registry.remove(object_id);
            },
        },
        else => {
            logUnhandledRequest(object_id, req);
            return;
        },
    }
}

const InterfaceRegistry = struct {
    inner: sphtud.util.AutoHashMap(u32, Bindings.WaylandInterfaceType),

    fn init(sphalloc: *sphtud.alloc.Sphalloc) !InterfaceRegistry {
        var ret: InterfaceRegistry = .{
            .inner = try .init(
                sphalloc.arena(),
                sphalloc.expansion(),
                128,
                4096,
            ),
        };
        try ret.inner.put(display_id, .wl_display);
        return ret;
    }

    fn put(self: *InterfaceRegistry, object_id: u32, interface_type: Bindings.WaylandInterfaceType, diagnostics: *HandleMessageDiagnostics) !void {
        logger.debug("Registering {d} -> {t}", .{ object_id, interface_type });
        const gop = try self.inner.getOrPut(object_id);

        if (gop.found_existing) {
            return diagnostics.makeInvalidMethodError("id {d} already bound to {t}", .{ object_id, gop.val.* });
        }

        gop.val.* = interface_type;
    }

    fn remove(self: *InterfaceRegistry, object_id: u32) void {
        _ = self.inner.remove(object_id);
    }

    fn get(self: *const InterfaceRegistry, object_id: u32) ?Bindings.WaylandInterfaceType {
        return self.inner.get(object_id);
    }
};

fn parseRequest(op: u32, data: []const u8, interface: Bindings.WaylandInterfaceType) !Bindings.WaylandIncomingMessage {
    inline for (std.meta.fields(Bindings.WaylandIncomingMessage)) |field| {
        if (@field(Bindings.WaylandInterfaceType, field.name) == interface) {
            if (@hasDecl(field.type, "parse")) {
                return @unionInit(Bindings.WaylandIncomingMessage, field.name, try field.type.parse(op, data));
            } else {
                return @unionInit(Bindings.WaylandIncomingMessage, field.name, .{});
            }
        }
    }
    unreachable;
}

fn logUnhandledRequest(object_id: u32, req: Bindings.WaylandIncomingMessage) void {
    logger.warn("Unhandled request by object {d}, {any}", .{ object_id, req });
}

fn sendSurfaceFeedback(self: *Connection, params: anytype, diagnostics: *HandleMessageDiagnostics) !void {
    // If we implement GPU switching later, this will have to be stored and notified, but for now it's nbd :)
    const feedback_interface = Bindings.ZwpLinuxDmabufFeedbackV1{ .id = params.id };

    const devt = self.gbm_context.getDevt() catch |e| {
        return diagnostics.makeInternalErr("Failed to get devt handle {t}", .{e});
    };
    try feedback_interface.mainDevice(self.io_writer, .{ .device = std.mem.asBytes(&devt) });

    {
        var format_table_buf: [4096]u8 = undefined;
        var format_table_writer = std.Io.Writer.fixed(&format_table_buf);
        try feedback_interface.formatTable(&format_table_writer, .{
            .fd = {},
            .size = @intCast(self.format_table.len),
        });

        // Ensure ordering :)
        try self.io_writer.flush();
        wl_cmsg.sendMessageWithFdAttachment(self.connection.stream, format_table_writer.buffered(), self.format_table.fd) catch {
            // All other writes get clobbered to WriteFailed by std.Io.Writer, we can do the same
            return error.WriteFailed;
        };
    }

    try feedback_interface.trancheTargetDevice(self.io_writer, .{
        .device = std.mem.asBytes(&devt),
    });
    try feedback_interface.trancheFlags(self.io_writer, .{
        .flags = 1,
    });

    {
        const cp = self.scratch.checkpoint();
        defer self.scratch.restore(cp);

        const len = self.format_table.len / 16;
        const indices = try self.scratch.allocator().alloc(u16, len);

        for (0..len) |i| {
            indices[i] = @intCast(i);
        }
        try feedback_interface.trancheFormats(self.io_writer, .{
            .indices = @ptrCast(indices),
        });
    }

    try feedback_interface.done(self.io_writer, .{});
    try self.interface_registry.put(params.id, .zwp_linux_dmabuf_feedback_v1, diagnostics);
}

fn emitXdgSurfaceConfigure(self: *Connection, id: XdgSurfaceId, surface: *Surface) !void {
    surface.outstanding_xdg_configure = self.rand.int(u32);

    var xdg_surf = Bindings.XdgSurface{ .id = id.inner };
    try xdg_surf.configure(self.io_writer, .{
        .serial = surface.outstanding_xdg_configure.?,
    });
}

const IdSource = enum {
    interface,
    param,
};

fn getWlBuffer(self: *Connection, id: WlBufferId, comptime id_source: IdSource, diagnostics: *HandleMessageDiagnostics) !*RefCountedRenderBuffer {
    return self.wl_buffers.get(id) orelse {
        switch (id_source) {
            .interface => return diagnostics.makeInternalErr("wl_buffer storage missing {d}", .{id.inner}),
            .param => return diagnostics.makeInvalidMethodError("invalid wl_buffer {d}", .{id.inner}),
        }
    };
}

fn getWlSurface(self: *Connection, id: WlSurfaceId, comptime id_source: IdSource, diagnostics: *HandleMessageDiagnostics) !*Surface {
    return self.wl_surfaces.getPtr(id) orelse {
        switch (id_source) {
            .interface => return diagnostics.makeInternalErr("wl_surface storage missing {d}", .{id.inner}),
            .param => return diagnostics.makeInvalidMethodError("invalid wl_surface {d}", .{id.inner}),
        }
    };
}

fn getXdgSurface(self: *Connection, id: XdgSurfaceId, id_source: IdSource, diagnostics: *HandleMessageDiagnostics) !*Surface {
    const wl_surface_id = self.xdg_surfaces.get(id) orelse {
        switch (id_source) {
            .interface => return diagnostics.makeInternalErr("{d} does not have an xdg_surface", .{id.inner}),
            .param => return diagnostics.makeInvalidMethodError("{d} does not have an xdg_surface", .{id.inner}),
        }
    };

    return self.wl_surfaces.getPtr(wl_surface_id) orelse {
        return diagnostics.makeInternalErr("xdg_surface references invalid wl_surface {d} -> {d}", .{ id.inner, wl_surface_id.inner });
    };
}

fn getZwpBufferParams(self: *Connection, id: ZwpBufferParamsId, id_source: IdSource, diagnostics: *HandleMessageDiagnostics) !*?BufferParams {
    return self.zwp_params.getPtr(id) orelse {
        switch (id_source) {
            .interface => return diagnostics.makeInternalErr("zwp_params storage missing {d}", .{id.inner}),
            .param => return diagnostics.makeInvalidMethodError("invalid zwp_buffer_params {d}", .{id.inner}),
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

// Managed with Connection.alloc.general()
const RefCountedRenderBuffer = struct {
    ref_count: usize,
    render_buffer: rendering.RenderBuffer,
    buf_id: WlBufferId,

    fn init(alloc: std.mem.Allocator, wl_buffer: WlBufferId, params: BufferParams, width: i32, height: i32, format: u32, flags: u32) !*RefCountedRenderBuffer {
        _ = flags;

        const ret = try alloc.create(RefCountedRenderBuffer);
        ret.* = .{
            .render_buffer = .{
                .buf_fd = params.fd,
                .modifiers = params.modifier,
                .offset = params.offset,
                .plane_idx = params.plane_idx,
                .stride = params.stride,
                .width = width,
                .height = height,
                .format = format,
            },
            .ref_count = 1,
            .buf_id = wl_buffer,
        };
        return ret;
    }

    fn ref(self: *RefCountedRenderBuffer) *RefCountedRenderBuffer {
        self.ref_count += 1;
        return self;
    }

    fn unref(self: *RefCountedRenderBuffer, alloc: std.mem.Allocator, fd_pool: *FdPool) void {
        self.ref_count -= 1;
        logger.debug("{*} unrefed, count {d}\n", .{ self, self.ref_count });
        if (self.ref_count == 0) {
            fd_pool.close(self.render_buffer.buf_fd);
            alloc.destroy(self);
        }
    }
};

const BufferParams = struct {
    fd: i32,
    plane_idx: u32,
    offset: u32,
    stride: u32,
    modifier: u64,
};

const Surface = struct {
    // Buffer currently attached, but not yet committed
    pending_buffer: ?*RefCountedRenderBuffer = null,

    // Buffer currently committed
    committed_buffer: ?*RefCountedRenderBuffer = null,
    committed_buffer_handle: ?CompositorState.Renderables.Handle = null,

    callback_id: ?u32 = null,
    outstanding_xdg_configure: ?u32 = null,
    xdg_surface_id: ?XdgSurfaceId = null,
    toplevel_id: ?XdgToplevelId = null,

    fn deinit(self: Surface, alloc: std.mem.Allocator, fd_pool: *FdPool, compositor_state: *CompositorState) void {
        if (self.pending_buffer) |buf| {
            buf.unref(alloc, fd_pool);
        }

        if (self.committed_buffer) |buf| {
            buf.unref(alloc, fd_pool);
        }

        if (self.committed_buffer_handle) |handle| {
            compositor_state.removeRenderable(handle);
        }
    }
};

const Pointer = struct {
    current_surface: ?WlSurfaceId = null,
    // FIXME: Dont' just make up what this is
    serial: u32 = 0,

    fn isInSurface(self: Pointer, surface: WlSurfaceId) bool {
        const current_surface = self.current_surface orelse return false;
        return current_surface.inner == surface.inner;
    }
};

const Window = struct {
    title: []const u8 = &.{}, // Connection.alloc.general()
    app_id: []const u8 = &.{}, // Connection.alloc.general()

    fn deinit(self: *Window) void {
        self.alloc.deinit();
    }

    fn setTitle(self: *Window, alloc: std.mem.Allocator, title: []const u8) !void {
        const tmp_title: []const u8 = try alloc.dupe(u8, title);
        alloc.free(self.title);
        self.title = tmp_title;
    }

    fn setAppId(self: *Window, alloc: std.mem.Allocator, app_id: []const u8) !void {
        const tmp_id: []const u8 = try alloc.dupe(u8, app_id);
        alloc.free(self.app_id);
        self.app_id = tmp_id;
    }
};
