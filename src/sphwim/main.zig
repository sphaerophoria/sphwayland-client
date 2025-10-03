const std = @import("std");
const sphtud = @import("sphtud");
const rendering = @import("rendering.zig");
const wayland = @import("wayland.zig");
const Bindings = @import("wayland_bindings");
const CompositorState = @import("CompositorState.zig");

pub const std_option = std.Options{
    .log_level = .warn,
};

fn createWaylandSocket(alloc: sphtud.alloc.LinearAllocator) !std.net.Server {
    const xdg_runtime_dir = std.posix.getenv("XDG_RUNTIME_DIR") orelse return error.NoXdgRuntime;

    var idx: usize = 0;

    while (true) {
        const cp = alloc.checkpoint();
        defer alloc.restore(cp);

        const path = try std.fmt.allocPrint(alloc.allocator(), "{s}/wayland-{d}", .{ xdg_runtime_dir, idx });

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
        return ret;
    }
}

const WlServerContext = struct {
    server_alloc: *sphtud.alloc.Sphalloc,
    compositor_state: *CompositorState,
    render_backend: rendering.RenderBackend,

    pub fn generate(self: *WlServerContext, connection: std.net.Server.Connection) !sphtud.event.Handler {
        const connection_alloc = try self.server_alloc.makeSubAlloc("connection");
        errdefer connection_alloc.deinit();

        const ret = try connection_alloc.arena().create(wayland.Connection);
        ret.* = try wayland.Connection.init(connection_alloc, connection, self.compositor_state, self.render_backend);

        return ret.handler();
    }

    pub fn close(self: *WlServerContext) void {
        self.server_alloc.deinit();
    }
};

const VsyncHandler = struct {
    render_backend: rendering.RenderBackend,
    compositor_state: *CompositorState,
    last: std.time.Instant,

    const vtable = sphtud.event.Handler.VTable{
        .poll = poll,
        .close = close,
    };

    fn handler(self: *VsyncHandler) sphtud.event.Handler {
        return .{
            .ptr = self,
            .fd = self.render_backend.event_fd,
            .vtable = &vtable,
        };
    }

    fn poll(ctx: ?*anyopaque, _: *sphtud.event.Loop) sphtud.event.PollResult {
        const self: *VsyncHandler = @ptrCast(@alignCast(ctx));
        self.render_backend.service() catch {
            return .complete;
        };

        const now = std.time.Instant.now() catch return .complete;
        defer self.last = now;

        // FIXME: This is probably over triggering
        self.compositor_state.updateBuffers() catch return .complete;
        var buffers = self.compositor_state.renderables.locked_buffers.iter();
        while (buffers.next()) |buffer| {
            if (buffer.locked) continue;
            self.render_backend.displayBuffer(buffer.buffer, &buffer.locked) catch return .complete;
        }

        std.debug.print("flipppy floppy {d}\n", .{now.since(self.last) / std.time.ns_per_ms});

        // Notify all connections that it is time to rerender
        return .in_progress;
    }

    fn close(ctx: ?*anyopaque) void {
        _ = ctx;
    }
};

const PeriodicMemoryDumper = struct {
    root: *sphtud.alloc.Sphalloc,
    scratch: *sphtud.alloc.BufAllocator,
    timer: std.posix.fd_t,

    fn init(root: *sphtud.alloc.Sphalloc, scratch: *sphtud.alloc.BufAllocator) !PeriodicMemoryDumper {
        const fd = try std.posix.timerfd_create(.MONOTONIC, .{ .NONBLOCK = true });

        const timer = std.posix.system.itimerspec {
            .it_value = .{
                .sec = 0.0,
                .nsec = 1.0,
            },
            .it_interval = .{
                .sec = 5.0,
                .nsec = 0.0,
            },
        };
        try std.posix.timerfd_settime(fd, .{ .ABSTIME = false }, &timer, null);

        return .{
            .root = root,
            .scratch = scratch,
            .timer = fd,
        };

    }

    const vtable = sphtud.event.Handler.VTable{
        .poll = poll,
        .close = close,
    };

    fn handler(self: *PeriodicMemoryDumper) sphtud.event.Handler {
        return .{
            .ptr = self,
            .fd = self.timer,
            .vtable = &vtable,
        };
    }

    fn poll(ctx: ?*anyopaque, _: *sphtud.event.Loop) sphtud.event.PollResult {
        const self: *PeriodicMemoryDumper = @ptrCast(@alignCast(ctx));
        self.pollError() catch return .complete;
        return .in_progress;
    }

    fn pollError(self: *PeriodicMemoryDumper) !void {
        const cp = self.scratch.checkpoint();
        defer self.scratch.restore(cp);

        var num_triggers: u64 = 0;
        _ = try std.posix.read(self.timer, std.mem.asBytes(&num_triggers));

        const snapshot = try sphtud.alloc.MemoryTracker.snapshot(self.scratch.allocator(), self.root, 100);
        std.log.info("Dumping memory usage", .{});
        for (snapshot) |elem| {
            std.log.info("{s}: {d}", .{elem.name, elem.memory_used});
        }
    }

    fn close(ctx: ?*anyopaque) void {
        const self: *PeriodicMemoryDumper = @ptrCast(@alignCast(ctx));
        std.posix.close(self.timer);
    }
};

pub fn main() !void {
    var tpa: sphtud.alloc.TinyPageAllocator = undefined;
    try tpa.initPinned();

    var root_alloc: sphtud.alloc.Sphalloc = undefined;
    try root_alloc.initPinned(tpa.allocator(), "root");

    var scratch = sphtud.alloc.BufAllocator.init(
        try root_alloc.arena().alloc(u8, 1 * 1024 * 1024),
    );

    const render_backend = try rendering.initRenderBackend(root_alloc.arena());

    var compositor_state = try CompositorState.init(&root_alloc, render_backend);
    var memory_dumper = try PeriodicMemoryDumper.init(&root_alloc, &scratch);

    var vsync_handler = VsyncHandler{
        .render_backend = render_backend,
        .last = try std.time.Instant.now(),
        .compositor_state = &compositor_state,
    };

    var loop = try sphtud.event.Loop.init(&root_alloc);
    try loop.register(vsync_handler.handler());
    var server_context = WlServerContext{
        .server_alloc = try root_alloc.makeSubAlloc("server"),
        .render_backend = render_backend,
        .compositor_state = &compositor_state,
    };

    const socket = try createWaylandSocket(scratch.linear());
    var server = try sphtud.event.net.server(socket, &server_context);
    try loop.register(server.handler());
    try loop.register(memory_dumper.handler());

    while (true) {
        scratch.reset();
        try loop.wait(&scratch);
    }
}
