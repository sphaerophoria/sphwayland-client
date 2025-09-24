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
        event_buf: DoubleEndedBuf = .{},
        stream_writer: std.net.Stream.Writer,

        const Self = @This();

        pub fn init(alloc: Allocator) !Self {
            const stream = try openWaylandConnection(alloc);
            const display = Bindings.WlDisplay{ .id = 1 };
            const registry = Bindings.WlRegistry{ .id = 2 };
            var stream_writer = stream.writer(&.{});
            try display.getRegistry(&stream_writer.interface, .{
                .registry = registry.id,
            });

            const interfaces = try InterfaceRegistry(Bindings).init(alloc, registry);

            return .{
                .interfaces = interfaces,
                .stream = stream,
                .stream_writer = stream_writer,
            };
        }

        pub fn deinit(self: *Self) void {
            self.interfaces.deinit();
        }

        pub fn bind(self: *Self, comptime T: type, global: Bindings.WlRegistry.Event.Global) !T {
            return try self.interfaces.bind(T, &self.stream_writer.interface, global);
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

        pub fn eventIt(self: *Self) EventIt(Bindings) {
            return EventIt(Bindings).init(self);
        }

        pub fn writer(self: *Self) *std.Io.Writer {
            return &self.stream_writer.interface;
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
    const cmsg_buf_alignment: std.mem.Alignment  = .@"8";
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

        pub fn bind(self: *Self, comptime T: type, writer: *std.Io.Writer, params: Bindings.WlRegistry.Event.Global) !T {
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

// Data is read into the buffer in chunks, and consumed from the
// beginning, once we cannot read any more from the buffer, we shift
// the remaining data back and wait for more data to show up
//
// Wrapping the stream in a bufreader seems like a good idea, but the
// edge case of half a header being at the end of the buf would not be
// handled well there
const DoubleEndedBuf = struct {
    data: [4096]u8 = undefined,
    back: usize = 0,
    front: usize = 0,

    fn shift(self: *DoubleEndedBuf) void {
        std.mem.copyForwards(u8, &self.data, self.data[self.front..]);
        self.back -= self.front;
        self.front = 0;
    }
};

pub fn EventIt(comptime Bindings: type) type {
    return struct {
        client: *Client(Bindings),

        const Self = @This();

        pub const Event = struct {
            object_id: u32,
            event: Bindings.WaylandEvent,
        };

        pub fn init(client: *Client(Bindings)) Self {
            return .{
                .client = client,
            };
        }

        // NOTE: Output data is backed by internal buffer and is invalidated on next call to next()
        pub fn retrieveEvents(self: *Self) !void {
            self.client.event_buf.shift();

            const num_bytes_read = try self.client.stream.read(self.client.event_buf.data[self.client.event_buf.back..]);
            if (num_bytes_read == 0) {
                return error.RemoteClosed;
            }

            self.client.event_buf.back += num_bytes_read;
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
                    .fd = self.client.stream.handle,
                    .events = std.posix.POLL.IN,
                    .revents = 0,
                }};
                num_ready = try std.posix.poll(&pollfd, -1);
            }
        }

        fn getBufferedEvent(self: *Self) !?Event {
            const header_end = self.client.event_buf.front + @sizeOf(wlw.HeaderLE);
            if (header_end > self.client.event_buf.back) {
                return null;
            }
            const header = std.mem.bytesToValue(HeaderLE, self.client.event_buf.data[self.client.event_buf.front..header_end]);
            const data_end = self.client.event_buf.front + header.size;
            if (data_end > self.client.event_buf.data.len and self.client.event_buf.front == 0) {
                return error.DataTooLarge;
            }
            if (data_end > self.client.event_buf.back) {
                return null;
            }

            defer self.client.event_buf.front = data_end;

            const data = self.client.event_buf.data[header_end..data_end];
            const interface = self.client.interfaces.get(header.id) orelse return null;

            inline for (std.meta.fields(Bindings.WaylandEvent)) |field| {
                if (@field(Bindings.WaylandEventType, field.name) == interface) {
                    if (@hasDecl(field.type, "parse")) {
                        return .{
                            .object_id = header.id,
                            .event = @unionInit(Bindings.WaylandEvent, field.name, try field.type.parse(header.op, data)),
                        };
                    } else {
                        return .{
                            .object_id = header.id,
                            .event = @unionInit(Bindings.WaylandEvent, field.name, .{}),
                        };
                    }
                }
            }

            unreachable;
        }

        fn dataInSocket(self: *Self) !bool {
            var pollfd = [1]std.posix.pollfd{.{
                .fd = self.client.stream.handle,
                .events = std.posix.POLL.IN,
                .revents = 0,
            }};
            const num_ready = try std.posix.poll(&pollfd, 0);
            return num_ready != 0;
        }
    };
}

fn openWaylandConnection(alloc: Allocator) !std.net.Stream {
    const xdg_runtime_dir = std.posix.getenv("XDG_RUNTIME_DIR") orelse return error.NoXdgRuntime;
    const wayland_display = std.posix.getenv("WAYLAND_DISPLAY") orelse return error.NoWaylandDisplay;

    const socket_path = try std.fs.path.joinZ(alloc, &.{ xdg_runtime_dir, wayland_display });
    defer alloc.free(socket_path);

    return try std.net.connectUnixSocket(socket_path);
}
