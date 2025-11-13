const std = @import("std");
const sphtud = @import("sphtud");
const Allocator = std.mem.Allocator;
const wlio = @import("wlio");
const HeaderLE = wlio.HeaderLE;
const wl_cmsg = @import("wl_cmsg");

// Re-export so wlclient users don't need to manually import wl_cmsg
pub const sendMessageWithFdAttachment = wl_cmsg.sendMessageWithFdAttachment;

pub fn Client(comptime Bindings: type) type {
    return struct {
        interfaces: InterfaceRegistry(Bindings),

        stream: std.net.Stream,
        stream_reader: *wlio.Reader,

        stream_writer: std.net.Stream.Writer,

        const Self = @This();

        pub fn init(alloc: Allocator, expansion_alloc: sphtud.util.ExpansionAlloc) !Self {
            const stream = try openWaylandConnection();
            const display = Bindings.WlDisplay{ .id = 1 };
            const registry = Bindings.WlRegistry{ .id = 2 };
            var stream_writer = stream.writer(&.{});
            try display.getRegistry(&stream_writer.interface, .{
                .registry = registry.id,
            });

            const interfaces = try InterfaceRegistry(Bindings).init(alloc, expansion_alloc, registry);

            const stream_reader = try alloc.create(wlio.Reader);
            stream_reader.* = try wlio.Reader.init(alloc, stream);

            return .{
                .interfaces = interfaces,
                .stream_reader = stream_reader,
                .stream = stream,
                .stream_writer = stream_writer,
            };
        }

        pub fn deinit(self: *Self) void {
            self.stream_reader.deinit();
            self.stream.close();
        }

        pub fn bind(self: *Self, comptime T: type, global: Bindings.WlRegistry.IncomingMessage.Global) !T {
            return try self.interfaces.bind(T, &self.stream_writer.interface, global);
        }

        pub fn newId(self: *Self, comptime T: type) !T {
            return self.interfaces.register(T);
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

pub fn InterfaceRegistry(comptime Bindings: type) type {
    return struct {
        idx: u32,
        elems: InterfaceMap,
        registry: Bindings.WlRegistry,

        const Self = @This();
        const InterfaceMap = sphtud.util.AutoHashMap(u32, Bindings.WaylandInterfaceType);

        pub fn init(alloc: Allocator, expansion_alloc: sphtud.util.ExpansionAlloc, registry: Bindings.WlRegistry) !Self {
            // How many outstanding wayland objects could we possibly have? I'd
            // guess we have around 30 things bound, 64 seems like ~2x and a
            // power of 2, 1024 seems bonkers bananas
            var elems = try InterfaceMap.init(alloc, expansion_alloc, 64, 1024);

            try elems.put(1, .wl_display);
            try elems.put(registry.id, .wl_registry);

            return .{
                .idx = registry.id + 1,
                .elems = elems,
                .registry = registry,
            };
        }

        pub fn get(self: Self, id: u32) ?Bindings.WaylandInterfaceType {
            return self.elems.get(id);
        }

        pub fn bind(self: *Self, comptime T: type, writer: *std.Io.Writer, params: Bindings.WlRegistry.IncomingMessage.Global) !T {
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

        pub fn remove(self: *Self, object_id: u32) void {
            _ = self.elems.remove(object_id);
        }

        fn resolveInterfaceType(comptime T: type) Bindings.WaylandInterfaceType {
            inline for (std.meta.fields(Bindings.WaylandIncomingMessage)) |field| {
                if (field.type == T.IncomingMessage) {
                    return @field(Bindings.WaylandInterfaceType, field.name);
                }
            }

            @compileError("Unhandled interface type " ++ @typeName(T));
        }
    };
}

pub fn Event(comptime Bindings: type) type {
    return struct {
        object_id: u32,
        event: Bindings.WaylandIncomingMessage,
        fd: ?std.posix.fd_t,

        pub fn deinit(self: @This()) void {
            if (self.fd) |fd| {
                std.posix.close(fd);
            }
        }
    };
}

pub fn EventIt(comptime Bindings: type) type {
    return struct {
        client: *Client(Bindings),

        const Self = @This();

        pub fn init(client: *Client(Bindings)) Self {
            return .{
                .client = client,
            };
        }

        // NOTE: Output data is backed by internal buffer and is invalidated on next call to next()
        pub fn retrieveEvents(self: *Self) !void {
            try self.client.stream_reader.interface.fillMore();
        }

        pub fn getAvailableEvent(self: *Self) !?Event(Bindings) {
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

        pub fn wait(self: *Self) !void {
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

        fn getBufferedEvent(self: *Self) !?Event(Bindings) {
            var io_reader = std.Io.Reader.fixed(self.client.stream_reader.interface.buffered());

            const header = io_reader.peekStruct(wlio.HeaderLE, .little) catch |e| switch (e) {
                error.EndOfStream => return null,
                else => return e,
            };
            // FIXME: Split out so we don't have to double end of stream check
            const full_data = io_reader.take(header.size) catch |e| switch (e) {
                error.EndOfStream => return null,
                else => return e,
            };
            const data = full_data[@sizeOf(wlio.HeaderLE)..];

            self.client.stream_reader.interface.toss(header.size);

            const interface = self.client.interfaces.get(header.id) orelse return null;

            inline for (std.meta.fields(Bindings.WaylandIncomingMessage)) |field| {
                if (@field(Bindings.WaylandInterfaceType, field.name) == interface) {
                    const msg: Bindings.WaylandIncomingMessage = if (@hasDecl(field.type, "parse"))
                        @unionInit(Bindings.WaylandIncomingMessage, field.name, try field.type.parse(header.op, data))
                    else
                        @unionInit(Bindings.WaylandIncomingMessage, field.name, .{});

                    var fd: ?std.posix.fd_t = null;
                    if (wlio.requiresFd(msg)) {
                        fd = self.client.stream_reader.fd_list.pop() orelse return error.NoFd;
                    }

                    return .{
                        .object_id = header.id,
                        .event = msg,
                        .fd = fd,
                    };
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

fn openWaylandConnection() !std.net.Stream {
    const xdg_runtime_dir = std.posix.getenv("XDG_RUNTIME_DIR") orelse return error.NoXdgRuntime;
    const wayland_display = std.posix.getenv("WAYLAND_DISPLAY") orelse return error.NoWaylandDisplay;

    var path_buf: [std.fs.max_path_bytes]u8 = undefined;
    var tmp_alloc = std.heap.FixedBufferAllocator.init(&path_buf);
    const socket_path = try std.fs.path.join(tmp_alloc.allocator(), &.{ xdg_runtime_dir, wayland_display });

    return try std.net.connectUnixSocket(socket_path);
}
