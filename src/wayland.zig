const std = @import("std");
const Allocator = std.mem.Allocator;
const wlw = @import("wl_writer");
const wlr = @import("wl_reader");
const HeaderLE = wlw.HeaderLE;
const cmsg = @cImport({
    @cInclude("cmsg.h");
});

pub fn Client(comptime Bindings: type) type {
    return struct {
        interfaces: InterfaceRegistry(Bindings),
        stream: std.net.Stream,
        event_reader: EventReader(Bindings) = .{},

        const Self = @This();

        pub fn init(alloc: Allocator) !Self {
            const stream = try openWaylandConnection(alloc);
            const display = Bindings.WlDisplay{ .id = 1 };
            const registry = Bindings.WlRegistry{ .id = 2 };
            try display.getRegistry(stream.writer(), .{
                .registry = registry.id,
            });

            const interfaces = try InterfaceRegistry(Bindings).init(alloc, registry);

            return .{
                .interfaces = interfaces,
                .stream = stream,
            };
        }

        pub fn deinit(self: *Self) void {
            self.interfaces.deinit();
        }

        pub fn bind(self: *Self, comptime T: type, global: Bindings.WlRegistry.Event.Global) !T {
            return try self.interfaces.bind(T, self.stream.writer(), global);
        }

        pub fn newId(self: *Self, comptime T: type) !T {
            return try self.interfaces.register(T);
        }

        pub fn registerId(self: *Self, id: u32, interface_type: Bindings.WaylandEventType) !void {
            try self.interfaces.elems.put(id, interface_type);
        }

        pub fn removeId(self: *Self, id: u32) void {
            _ = self.interfaces.elems.remove(id);
        }

        pub fn writer(self: *Self) std.net.Stream.Writer {
            return self.stream.writer();
        }

        pub fn waitAnyAvailable(self: *Self) !void {
            // FIXME: maybe wait should be somewhere else
            try EventReader(Bindings).wait(self.stream.handle);
        }

        pub fn readBlocking(self: *Self) !Event(Bindings){
            return self.event_reader.readBlocking(self.stream.handle, &self.interfaces);
        }

        pub fn readAvailable(self: *Self) !?Event(Bindings){
            return self.event_reader.readAvailable(self.stream.handle, &self.interfaces);
        }
    };
}

pub fn logUnusedEvent(event: anytype) void {
    switch (event) {
        .wl_display => |display_event| {
            switch (display_event) {
                .err => |err| logWaylandErr(err),
                else => {
                    std.log.debug("Unused event: {any}", .{event});
                },
            }
        },
        else => {
            std.log.debug("Unused event: {any}", .{event});
        },
    }
}

pub fn logWaylandErr(err: anytype) void {
    std.log.err("wl_display::error: object {d}, code: {d}, msg: {s}", .{ err.object_id, err.code, err.message });
}

pub fn sendMessageWithFdAttachment(alloc: Allocator, stream: std.net.Stream, msg: []const u8, fd: c_int) !void {
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

pub fn InterfaceRegistry(comptime Bindings: type) type {
    return struct {
        idx: u32,
        elems: InterfaceMap,
        registry: Bindings.WlRegistry,

        const Self = @This();
        const InterfaceMap = std.AutoHashMap(u32, Bindings.WaylandEventType);

        pub fn init(alloc: Allocator, registry: Bindings.WlRegistry) !Self {
            var elems = InterfaceMap.init(alloc);

            try elems.put(1, .wl_display);
            try elems.put(registry.id, .wl_registry);

            return .{
                .idx = registry.id + 1,
                .elems = elems,
                .registry = registry,
            };
        }

        pub fn deinit(self: *Self) void {
            self.elems.deinit();
        }

        pub fn get(self: Self, id: u32) ?Bindings.WaylandEventType {
            return self.elems.get(id);
        }

        pub fn bind(self: *Self, comptime T: type, writer: std.net.Stream.Writer, params: Bindings.WlRegistry.Event.Global) !T {
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

        pub fn register(self: *Self, comptime T: type) !T {
            defer self.idx += 1;
            try self.elems.put(self.idx, resolveInterfaceType(T));
            return T{
                .id = self.idx,
            };
        }

        fn resolveInterfaceType(comptime T: type) Bindings.WaylandEventType {
            inline for (std.meta.fields(Bindings.WaylandEvent)) |field| {
                if (field.type == T.Event) {
                    return @field(Bindings.WaylandEventType, field.name);
                }
            }

            @compileError("Unhandled interface type " ++ @typeName(T));
        }
    };
}

pub fn Event(comptime Bindings: type) type {
    return struct {
        object_id: u32,
        event: Bindings.WaylandEvent,
        fd: ?i32 = null,
    };
}

pub fn EventReader(comptime Bindings: type) type {
    return struct {
        in_progress: [4096]u8 = undefined,
        in_progress_len: usize = 0,
        state: union(enum) {
            header,
            content: struct {
                header: HeaderLE,
                fd: ?std.posix.fd_t,
            },
        } = .header,

        const Self = @This();

        fn readBuf(self: *Self, desired_len: usize) []u8 {
            return self.in_progress[self.in_progress_len..desired_len];
        }

        fn wait(handle: std.posix.fd_t) !void {
            var num_ready: usize = 0;
            while (num_ready == 0) {
                var pollfd = [1]std.posix.pollfd{.{
                    .fd = handle,
                    .events = std.posix.POLL.IN,
                    .revents = 0,
                }};
                num_ready = try std.posix.poll(&pollfd, -1);
            }
        }

        fn canProgress(self: *Self, handle: std.posix.fd_t) !bool {
            const needs_content = switch (self.state) {
                .content => |data| data.header.size > @sizeOf(HeaderLE),
                .header => true,
            };
            return !needs_content or try dataInSocket(handle);

        }

        pub fn readBlocking(self: *Self, handle :std.posix.fd_t, interfaces: *InterfaceRegistry(Bindings)) !Event(Bindings) {
            while (true) {
                try wait(handle);
                if (try self.readAvailable(handle, interfaces)) |event| {
                    return event;
                }
            }
        }

        pub fn readAvailable(self: *Self, handle: std.posix.fd_t, interfaces: *InterfaceRegistry(Bindings)) !?Event(Bindings) {
            while (try self.canProgress(handle)) {
                switch (self.state) {
                    .header => {
                        const desired_size = @sizeOf(HeaderLE);
                        @memset(&self.in_progress, 0);
                        const res = try readWithAncillaryFd(handle, self.readBuf(desired_size));

                        if (res.bytes_read == 0) {
                            return error.RemoteClosed;
                        }

                        self.in_progress_len += res.bytes_read;
                        if (self.in_progress_len == desired_size) {
                            self.state = .{
                                .content = .{
                                    .header = std.mem.bytesToValue(HeaderLE, self.in_progress[0..self.in_progress_len]),
                                    .fd = res.fd,
                                },
                            };
                            self.in_progress_len = 0;
                        }
                    },
                    .content => |content_data| {
                        const header = content_data.header;
                        var fd = content_data.fd;
                        const desired_size = header.size - @sizeOf(HeaderLE);
                        if (desired_size > 0) {

                            const res = try readWithAncillaryFd(handle, self.readBuf(desired_size));
                            self.in_progress_len += res.bytes_read;

                            if (res.bytes_read == 0) {
                                return error.RemoteClosed;
                            }

                            if (fd != null and res.fd != null) {
                                std.log.warn("Got two file descriptors for single event, discarding second", .{});
                            } else if (res.fd) |val| {
                                fd = val;
                            }
                        }

                        if (self.in_progress_len == desired_size) {
                            defer {
                                self.state = .header;
                                self.in_progress_len = 0;
                            }

                            const interface = interfaces.get(header.id) orelse return null;

                            inline for (std.meta.fields(Bindings.WaylandEvent)) |field| {
                                if (@field(Bindings.WaylandEventType, field.name) == interface) {
                                    if (@hasDecl(field.type, "parse")) {
                                        return .{
                                            .object_id = header.id,
                                            .event = @unionInit(Bindings.WaylandEvent, field.name, try field.type.parse(header.op, self.in_progress[0..self.in_progress_len])),
                                            .fd = fd,
                                        };
                                    } else {
                                        return .{
                                            .object_id = header.id,
                                            .event = @unionInit(Bindings.WaylandEvent, field.name, .{}),
                                            .fd = fd,
                                        };
                                    }
                                }
                            }
                        }
                    },
                }
            }

            return null;
        }
    };
}

const FdReadRes = struct {
    bytes_read: usize,
    fd: ?std.posix.fd_t,
};

fn readWithAncillaryFd(handle: std.posix.fd_t, buf: []u8) !FdReadRes{
    while (true) {
        var recv_iov = std.posix.iovec {
            .base = buf.ptr,
            .len = buf.len,
        };
        var ctrl_buf: [4096]u8 = undefined;
        var hdr = std.os.linux.msghdr {
            .name = null,
            .namelen = 0,
            .iov = @ptrCast(&recv_iov),
            .iovlen = 1,
            .control = &ctrl_buf,
            .controllen = ctrl_buf.len,
            .flags = 0,
        };

        const rc = std.os.linux.recvmsg(handle, &hdr, 0);
        const num_bytes_read: usize = switch (std.posix.errno(rc)) {
            .SUCCESS => rc,
            .INTR => continue,
            .INVAL => unreachable,
            .FAULT => unreachable,
            .AGAIN => return error.WouldBlock,
            .BADF => return error.NotOpenForReading, // Can be a race condition.
            .IO => return error.InputOutput,
            .ISDIR => return error.IsDir,
            .NOBUFS => return error.SystemResources,
            .NOMEM => return error.SystemResources,
            .NOTCONN => return error.SocketNotConnected,
            .CONNRESET => return error.ConnectionResetByPeer,
            .TIMEDOUT => return error.ConnectionTimedOut,
            else => |err| return std.posix.unexpectedErrno(err),
        };

        if (num_bytes_read == 0) {
            return error.RemoteClosed;
        }

        var out_fd: ?std.posix.fd_t = null;
        if (hdr.controllen != 0) {
            out_fd = cmsg.getFdFromCmsg(@ptrCast(hdr.control));
        }
        return .{
            .bytes_read = num_bytes_read,
            .fd = out_fd,
        };
    }
}

fn dataInSocket(socket: std.posix.fd_t) !bool {
    var pollfd = [1]std.posix.pollfd{.{
        .fd = socket,
        .events = std.posix.POLL.IN,
        .revents = 0,
    }};
    const num_ready = try std.posix.poll(&pollfd, 0);
    return num_ready != 0;
}

fn openWaylandConnection(alloc: Allocator) !std.net.Stream {
    const xdg_runtime_dir = std.posix.getenv("XDG_RUNTIME_DIR") orelse return error.NoXdgRuntime;
    const wayland_display = std.posix.getenv("WAYLAND_DISPLAY") orelse return error.NoWaylandDisplay;

    const socket_path = try std.fs.path.joinZ(alloc, &.{ xdg_runtime_dir, wayland_display });
    defer alloc.free(socket_path);

    return try std.net.connectUnixSocket(socket_path);
}
