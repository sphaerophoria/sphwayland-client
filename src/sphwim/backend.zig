const std = @import("std");
const sphtud = @import("sphtud");
const rendering = @import("rendering.zig");
const CompositorState = @import("CompositorState.zig");
const WaylandBackend = @import("backend/WaylandBackend.zig");
const NullBackend = @import("backend/NullBackend.zig");
const DrmRenderer = @import("backend/DrmRenderBackend.zig");
const LibinputHandler = @import("backend/LibInputInputBackend.zig");

const logger = std.log.scoped(.backend);

pub const Ids = struct {
    wayland_client: usize,
    drm: usize,
    libinput: usize,
    null_backend: usize,
    total: sphtud.util.IdAlloc.Range,

    pub fn init(alloc: *sphtud.util.IdAlloc) Ids {
        const mark = alloc.mark();

        return .{
            .wayland_client = alloc.allocOne(),
            .drm = alloc.allocOne(),
            .libinput = alloc.allocOne(),
            .null_backend = alloc.allocOne(),
            .total = mark.range(),
        };
    }
};

pub const Backend = struct {
    initial_res: rendering.Resolution,
    preferred_gpu: [:0]const u8,
    inner: union(enum) {
        wayland: WaylandBackend,
        seat: struct {
            drm: DrmRenderer,
            input: LibinputHandler,
        },
        null_backend: NullBackend,
    },

    pub fn deinit(self: *Backend) void {
        switch (self.inner) {
            .wayland => |*w| {
                w.deinit();
            },
            .seat => |*s| {
                s.drm.deinit();
                s.input.deinit();
            },
            .null_backend => |*n| {
                n.deinit();
            },
        }
    }

    pub fn serviceFirst(self: *Backend, renderer: *rendering.Renderer, compositor_state: *CompositorState) !void {
        switch (self.inner) {
            .wayland => |*w| try w.service(renderer, compositor_state),
            .seat => |*s| {
                try s.drm.render(renderer);
            },
            .null_backend => {},
        }
    }

    pub fn service(self: *Backend, renderer: *rendering.Renderer, compositor_state: *CompositorState, id: usize, comptime ids: Ids) !void {
        switch (id) {
            ids.wayland_client => {
                try self.inner.wayland.service(renderer, compositor_state);
            },
            ids.drm => {
                try self.inner.seat.drm.service(renderer);
            },
            ids.libinput => {
                try self.inner.seat.input.service(compositor_state);
            },
            ids.null_backend => {
                try self.inner.null_backend.service(renderer, compositor_state);
            },
            else => unreachable,
        }
    }
};

fn initSeat(alloc: std.mem.Allocator, env: std.process.Environ, loop: *sphtud.io.Loop, comptime ids: Ids) !Backend {
    const drm = try DrmRenderer.init(alloc);
    errdefer drm.deinit();

    const input = try LibinputHandler.init(env);
    errdefer input.deinit();

    try loop.register(.{
        .handle = drm.dri_file,
        .id = ids.drm,
        .read = true,
        .write = false,
    });

    try loop.register(.{
        .handle = input.getFd(),
        .id = ids.libinput,
        .read = true,
        .write = false,
    });

    return .{
        .initial_res = .{ .width = drm.preferred_mode.hdisplay, .height = drm.preferred_mode.vdisplay },
        .preferred_gpu = drm.preferred_gpu,
        .inner = .{
            .seat = .{
                .drm = drm,
                .input = input,
            },
        },
    };
}

pub fn initBackend(alloc: std.mem.Allocator, expansion_alloc: sphtud.util.ExpansionAlloc, env: std.process.Environ, system_running: *bool, loop: *sphtud.io.Loop, comptime ids: Ids) !Backend {
    if (WaylandBackend.init(alloc, expansion_alloc, env, system_running)) |res| {
        try loop.register(.{
            .handle = res.getFd(),
            .id = ids.wayland_client,
            .read = true,
            .write = false,
        });

        return .{
            .initial_res = .{ .width = 1024, .height = 768 },
            .preferred_gpu = try res.window.getPreferredGpu(alloc),
            .inner = .{
                .wayland = res,
            },
        };
    } else |e| {
        logger.info("Failed to init wayland render backend: {t}", .{e});
    }

    if (initSeat(alloc, env, loop, ids)) |res| {
        return res;
    } else |e| {
        logger.info("Failed to init drm render backend: {t}", .{e});
    }

    logger.warn("Failed to init any render backend, using null backend", .{});
    const null_backend = try NullBackend.init();
    try loop.register(.{
        .handle = null_backend.getFd(),
        .id = ids.null_backend,
        .read = true,
        .write = false,
    });

    return .{
        .initial_res = .{ .width = 640, .height = 480 },
        .preferred_gpu = "/dev/dri/card0",
        .inner = .{
            .null_backend = null_backend,
        },
    };
}
