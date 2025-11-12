const std = @import("std");
const sphtud = @import("sphtud");
const CompositorState = @import("CompositorState.zig");
const rendering = @import("rendering.zig");
const system_gl = @import("system_gl.zig");

pub const Reader = @import("wayland/Reader.zig");
pub const Connection = @import("wayland/Connection.zig");

pub const FormatTable = struct {
    fd: std.posix.fd_t,
    len: usize,

    pub fn init(scratch: sphtud.alloc.LinearAllocator, egl_ctx: *const system_gl.EglContext) !FormatTable {
        const cp = scratch.checkpoint();
        defer scratch.restore(cp);

        const fd = try std.posix.memfd_create("format_table", 0);

        const f = std.fs.File{ .handle = fd };

        var writer_buf: [4096]u8 = undefined;
        var writer = f.writer(&writer_buf);

        var it = try egl_ctx.formatModifierIter(scratch.allocator());
        while (try it.next()) |pair| {
            try writer.interface.print("{s}\x00\x00\x00\x00{s}", .{
                std.mem.asBytes(&pair.format),
                std.mem.asBytes(&pair.modifier),
            });
        }
        try writer.interface.flush();
        std.debug.assert(writer.pos % 16 == 0);
        std.debug.assert(writer.pos > 0);

        return .{
            .fd = fd,
            .len = writer.pos,
        };
    }
};

const ServerCtx = struct {
    scratch: sphtud.alloc.LinearAllocator,
    server_alloc: *sphtud.alloc.Sphalloc,
    compositor_state: *CompositorState,
    rand: std.Random,
    gbm_context: *const system_gl.GbmContext,
    format_table: FormatTable,

    pub fn generate(self: *ServerCtx, connection: std.net.Server.Connection) !sphtud.event.Loop.Handler {
        const connection_alloc = try self.server_alloc.makeSubAlloc("connection");
        errdefer connection_alloc.deinit();

        const ret = try connection_alloc.arena().create(Connection);
        ret.* = try Connection.init(connection_alloc, self.scratch, connection, self.rand, self.compositor_state, self.gbm_context, self.format_table);

        return ret.handler();
    }

    pub fn close(self: *ServerCtx) void {
        self.server_alloc.deinit();
    }
};

pub fn makeWaylandServer(
    server_alloc: *sphtud.alloc.Sphalloc,
    scratch: sphtud.alloc.LinearAllocator,
    rand: std.Random,
    compositor_state: *CompositorState,
    gbm_context: *const system_gl.GbmContext,
    egl_context: *const system_gl.EglContext,
) !sphtud.event.net.Server(ServerCtx) {
    const xdg_runtime_dir = std.posix.getenv("XDG_RUNTIME_DIR") orelse return error.NoXdgRuntime;

    var idx: usize = 0;

    const net_serv = blk: while (true) {
        const cp = scratch.checkpoint();
        defer scratch.restore(cp);

        const path = try std.fmt.allocPrint(scratch.allocator(), "{s}/wayland-{d}", .{ xdg_runtime_dir, idx });

        const addr = try std.net.Address.initUnix(path);
        const ret = addr.listen(.{
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
        break :blk ret;
    };

    return sphtud.event.net.server(net_serv, ServerCtx{
        .server_alloc = server_alloc,
        .scratch = scratch,
        .rand = rand,
        .compositor_state = compositor_state,
        .gbm_context = gbm_context,
        .format_table = try FormatTable.init(scratch, egl_context),
    });
}
