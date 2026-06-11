const std = @import("std");
const sphtud = @import("sphtud");
const CompositorState = @import("CompositorState.zig");
const rendering = @import("rendering.zig");
const system_gl = @import("system_gl.zig");

pub const Connection = @import("wayland/Connection.zig");

pub const FormatTable = struct {
    fd: std.posix.fd_t,
    len: usize,

    pub fn init(scratch: sphtud.alloc.LinearAllocator, egl_ctx: *const system_gl.EglContext) !FormatTable {
        const cp = scratch.checkpoint();
        defer scratch.restore(cp);

        const fd = try std.posix.memfd_create("format_table", 0);

        var writer_buf: [4096]u8 = undefined;
        var writer = std.Io.Writer.fixed(&writer_buf);

        var it = try egl_ctx.formatModifierIter(scratch.allocator());
        while (try it.next()) |pair| {
            try writer.print("{s}\x00\x00\x00\x00{s}", .{
                std.mem.asBytes(&pair.format),
                std.mem.asBytes(&pair.modifier),
            });
        }

        const pos = writer.buffered().len;
        try sphtud.io.writeAll(writer.buffered(), fd);
        std.debug.assert(pos % 16 == 0);
        std.debug.assert(pos > 0);

        return .{
            .fd = fd,
            .len = pos,
        };
    }
};

pub const WaylandServer = struct {
    socket: std.posix.fd_t,
    socket_path: [:0]const u8,
    connections: sphtud.util.ObjectPool(Connection, usize),

    server_alloc: *sphtud.alloc.Sphalloc,
    scratch: sphtud.alloc.LinearAllocator,
    compositor_state: *CompositorState,
    rand: std.Random,
    gbm_context: *const system_gl.GbmContext,
    format_table: FormatTable,
    loop: *sphtud.io.Loop,

    pub const Ids = struct {
        accept: usize,
        connection: sphtud.io.IdAlloc.Range,
        total: sphtud.io.IdAlloc.Range,

        pub fn init(alloc: *sphtud.util.IdAlloc, max_connections: usize) Ids {
            const mark = alloc.mark();
            return .{
                .accept = alloc.allocOne(),
                .connection = alloc.allocMany(max_connections),
                .total = mark.range(),
            };
        }
    };

    pub fn deinit(self: *WaylandServer) void {
        self.server_alloc.deinit();
        sphtud.io.close(self.socket);
    }

    pub fn service(self: *WaylandServer, id: usize, comptime ids: Ids) !void {
        switch (id) {
            ids.accept => {
                try self.accept(ids);
            },
            ids.connection.start...ids.connection.end => {
                const conn_id = id - ids.connection.start;

                const conn = self.connections.get(conn_id);
                switch (conn.service()) {
                    .complete => {
                        conn.deinit();
                        self.connections.release(self.server_alloc.expansion(), conn_id);
                        self.loop.clearEvents(id);
                    },
                    .in_progress => {},
                }
            },
            else => unreachable,
        }
    }

    pub fn accept(self: *WaylandServer, comptime ids: Ids) !void {
        while (true) {
            const conn_fd = sphtud.io.accept(self.socket) catch |e| {
                if (e == error.WouldBlock) return;
                return e;
            };

            const connection = try self.connections.acquire(self.server_alloc.expansion());
            errdefer self.connections.release(self.server_alloc.expansion(), connection.handle);

            const connection_alloc = try self.server_alloc.makeSubAlloc("connection");
            errdefer connection_alloc.deinit();

            connection.val.* = try Connection.init(
                connection_alloc,
                self.scratch,
                conn_fd,
                self.rand,
                self.compositor_state,
                self.gbm_context,
                self.format_table,
            );
            errdefer connection.val.deinit();

            try self.loop.register(.{
                .handle = conn_fd,
                .id = ids.connection.start + connection.handle,
                .read = true,
                .write = false,
            });
        }
    }
};

pub fn makeWaylandServer(
    server_alloc: *sphtud.alloc.Sphalloc,
    scratch: sphtud.alloc.LinearAllocator,
    rand: std.Random,
    compositor_state: *CompositorState,
    gbm_context: *const system_gl.GbmContext,
    egl_context: *const system_gl.EglContext,
    loop: *sphtud.io.Loop,
    env: std.process.Environ,
    comptime ids: WaylandServer.Ids,
) !WaylandServer {
    const xdg_runtime_dir = env.getPosix("XDG_RUNTIME_DIR") orelse return error.NoXdgRuntime;

    var idx: usize = 0;

    const socket, const path = blk: while (true) {
        const cp = scratch.checkpoint();
        defer scratch.restore(cp);

        const path = try std.fmt.allocPrint(scratch.allocator(), "{s}/wayland-{d}", .{ xdg_runtime_dir, idx });

        const system = sphtud.io.system;
        const socket = try sphtud.io.socket(system.AF.UNIX, system.SOCK.STREAM, 0);

        sphtud.io.bindUnix(socket, try .init(path)) catch |e| {
            if (e != error.AddressInUse) return e;
            idx += 1;
            continue;
        };

        try sphtud.io.listen(socket, 1024);

        std.log.info("Serving on {s}", .{path});
        break :blk .{ socket, try server_alloc.arena().dupeZ(u8, path) };
    };

    const ret = WaylandServer{
        .socket = socket,
        .socket_path = path,
        .connections = try .init(
            server_alloc.arena(),
            server_alloc.expansion(),
            64,
            ids.connection.end - ids.connection.start + 1,
        ),
        .server_alloc = server_alloc,
        .scratch = scratch,
        .rand = rand,
        .compositor_state = compositor_state,
        .gbm_context = gbm_context,
        .format_table = try FormatTable.init(scratch, egl_context),
        .loop = loop,
    };

    try loop.register(.{
        .handle = socket,
        .id = ids.accept,
        .read = true,
        .write = false,
    });
    return ret;
}
