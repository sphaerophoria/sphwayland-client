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

        stream: std.posix.fd_t,
        stream_reader: *wlio.Reader,

        stream_writer: sphtud.io.Writer,

        const Self = @This();

        pub fn init(alloc: Allocator, expansion_alloc: sphtud.util.ExpansionAlloc, env: std.process.Environ) !Self {
            const stream = try openWaylandConnection(env);
            const display = Bindings.WlDisplay{ .id = 1 };
            const registry = Bindings.WlRegistry{ .id = 2 };
            var stream_writer = sphtud.io.Writer.init(stream, &.{});
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
            sphtud.io.close(self.stream);
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
                .id_interface_version = T.version,
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
                sphtud.io.close(fd);
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
                    .fd = self.client.stream,
                    .events = std.posix.POLL.IN,
                    .revents = 0,
                }};
                num_ready = try std.posix.poll(&pollfd, -1);
            }
        }

        const EventData = struct {
            header: wlio.HeaderLE,
            data: []const u8,
        };

        fn peekEventData(self: *Self) !EventData {
            var io_reader = std.Io.Reader.fixed(self.client.stream_reader.interface.buffered());
            const header = try io_reader.peekStruct(wlio.HeaderLE, .little);
            const full_data = try io_reader.take(header.size);
            const data = full_data[@sizeOf(wlio.HeaderLE)..];

            return .{
                .header = header,
                .data = data,
            };
        }

        fn getBufferedEvent(self: *Self) !?Event(Bindings) {
            const event_data = self.peekEventData() catch |e| switch (e) {
                error.EndOfStream => return null,
                else => return e,
            };

            self.client.stream_reader.interface.toss(event_data.header.size);

            const interface = self.client.interfaces.get(event_data.header.id) orelse return null;

            inline for (std.meta.fields(Bindings.WaylandIncomingMessage)) |field| {
                if (@field(Bindings.WaylandInterfaceType, field.name) == interface) {
                    const msg: Bindings.WaylandIncomingMessage = if (@hasDecl(field.type, "parse"))
                        @unionInit(Bindings.WaylandIncomingMessage, field.name, try field.type.parse(event_data.header.op, event_data.data))
                    else
                        @unionInit(Bindings.WaylandIncomingMessage, field.name, .{});

                    var fd: ?std.posix.fd_t = null;
                    if (wlio.requiresFd(msg)) {
                        fd = self.client.stream_reader.fd_list.pop() orelse return error.NoFd;
                    }

                    return .{
                        .object_id = event_data.header.id,
                        .event = msg,
                        .fd = fd,
                    };
                }
            }

            unreachable;
        }

        fn dataInSocket(self: *Self) !bool {
            var pollfd = [1]std.posix.pollfd{.{
                .fd = self.client.stream,
                .events = std.posix.POLL.IN,
                .revents = 0,
            }};
            const num_ready = try std.posix.poll(&pollfd, 0);
            return num_ready != 0;
        }
    };
}

fn openWaylandConnection(env: std.process.Environ) !std.posix.fd_t {
    const xdg_runtime_dir = env.getPosix("XDG_RUNTIME_DIR") orelse return error.NoXdgRuntime;
    const wayland_display = env.getPosix("WAYLAND_DISPLAY") orelse return error.NoWaylandDisplay;

    var path_buf: [std.fs.max_path_bytes]u8 = undefined;
    var tmp_alloc = std.heap.FixedBufferAllocator.init(&path_buf);
    const socket_path = try std.fs.path.join(tmp_alloc.allocator(), &.{ xdg_runtime_dir, wayland_display });

    const system = sphtud.io.system;
    const socket = try sphtud.io.socket(system.AF.UNIX, system.SOCK.STREAM, 0);

    try sphtud.io.setBlockMode(socket, .block);

    const unix_addr = try std.Io.net.UnixAddress.init(socket_path);
    try sphtud.io.connectUnix(socket, unix_addr);

    return socket;
}
