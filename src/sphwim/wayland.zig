const std = @import("std");
const sphtud = @import("sphtud");
const CompositorState = @import("CompositorState.zig");
const rendering = @import("rendering.zig");
const system_gl = @import("system_gl.zig");

pub const Reader = @import("wayland/Reader.zig");
pub const Connection = @import("wayland/Connection.zig");

const ServerCtx = struct {
    server_alloc: *sphtud.alloc.Sphalloc,
    compositor_state: *CompositorState,
    render_backend: rendering.RenderBackend,
    rand: std.Random,
    gbm_context: *const system_gl.GbmContext,

    pub fn generate(self: *ServerCtx, connection: std.net.Server.Connection) !sphtud.event.LoopSphalloc.Handler {
        const connection_alloc = try self.server_alloc.makeSubAlloc("connection");
        errdefer connection_alloc.deinit();

        const ret = try connection_alloc.arena().create(Connection);
        ret.* = try Connection.init(connection_alloc, connection, self.rand, self.compositor_state, self.gbm_context);

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
    render_backend: rendering.RenderBackend,
    gbm_context: *const system_gl.GbmContext,
) !sphtud.event.net.Server(sphtud.event.LoopSphalloc, ServerCtx) {
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

    return sphtud.event.net.server(sphtud.event.LoopSphalloc, net_serv, ServerCtx{
        .server_alloc = server_alloc,
        .rand = rand,
        .compositor_state = compositor_state,
        .render_backend = render_backend,
        .gbm_context = gbm_context,
    });
}
