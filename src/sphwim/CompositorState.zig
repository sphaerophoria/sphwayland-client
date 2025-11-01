const std = @import("std");
const sphtud = @import("sphtud");
const wayland = @import("wayland.zig");
const rendering = @import("rendering.zig");
const FdPool = @import("FdPool.zig");
const builtin = @import("builtin");

scratch: *sphtud.alloc.BufAllocator,
compositor_res: rendering.Resolution,
cursor_pos: CursorPos,
renderables: Renderables,
render_backend: rendering.RenderBackend,

const CursorPos = struct {
    x: f32,
    y: f32,
};

const CompositorState = @This();

pub fn init(alloc: *sphtud.alloc.Sphalloc, scratch: *sphtud.alloc.BufAllocator, random: std.Random, current_res: rendering.Resolution, render_backend: rendering.RenderBackend) !CompositorState {
    return .{
        .scratch = scratch,
        .compositor_res = current_res,
        .cursor_pos = .{
            .x = @floatFromInt(current_res.width / 2),
            .y = @floatFromInt(current_res.height / 2),
        },
        .renderables = try .init(alloc, scratch.linear(), random),
        .render_backend = render_backend,
    };
}

pub fn requestFrame(self: *CompositorState) !void {
    var it = self.renderables.storage.iter();
    while (it.next()) |item| {
        const si = item.val.source_info;
        try si.connection.requestFrame(si.surface);
    }
}

pub fn notifyCursorMovement(self: *CompositorState, dx: f32, dy: f32) void {
    self.cursor_pos.x = std.math.clamp(self.cursor_pos.x + dx, 0, asf32(self.compositor_res.width));
    self.cursor_pos.y = std.math.clamp(self.cursor_pos.y + dy, 0, asf32(self.compositor_res.height));
}

pub fn notifyCursorPosition(self: *CompositorState, x: f32, y: f32) void {
    self.cursor_pos.x = std.math.clamp(x, 0, asf32(self.compositor_res.width));
    self.cursor_pos.y = std.math.clamp(y, 0, asf32(self.compositor_res.height));
}

pub const SourceInfo = struct {
    connection: *wayland.Connection,
    surface: wayland.Connection.WlSurfaceId,
    buffer_id: wayland.Connection.WlBufferId,
};

// Ties wayland surfaces that are ready to their renderable state
pub const Renderables = struct {
    expansion_alloc: std.mem.Allocator,
    storage: sphtud.util.ObjectPoolSphalloc(Renderable, Handle),
    debug: ExtraDebug,

    const ExtraDebug = if (builtin.mode == .Debug) struct {
        scratch: sphtud.alloc.LinearAllocator,
        random: std.Random,
    } else void;

    pub const Renderable = struct {
        source_info: SourceInfo,
        buffer: rendering.RenderBuffer,
    };

    pub fn init(alloc: *sphtud.alloc.Sphalloc, scratch: sphtud.alloc.LinearAllocator, random: std.Random) !Renderables {
        return .{
            .expansion_alloc = alloc.block_alloc.allocator(),
            .storage = try .init(
                alloc.arena(),
                100,
                10000,
            ),
            .debug = if (builtin.mode == .Debug) .{
                .scratch = scratch,
                .random = random,
            } else {},
        };
    }

    pub fn swapBuffer(self: *Renderables, handle: Renderables.Handle, new_buffer: rendering.RenderBuffer, new_buffer_id: wayland.Connection.WlBufferId) void {
        const item = self.storage.get(handle);
        item.source_info.buffer_id = new_buffer_id;
        item.buffer = new_buffer;
    }

    pub fn push(
        self: *Renderables,
        connection: *wayland.Connection,
        surface: wayland.Connection.WlSurfaceId,
        buffer: rendering.RenderBuffer,
        buffer_id: wayland.Connection.WlBufferId,
    ) !Handle {
        const item = try self.storage.acquire(self.expansion_alloc);

        item.val.* = .{
            .source_info = .{
                .connection = connection,
                .surface = surface,
                .buffer_id = buffer_id,
            },
            .buffer = buffer,
        };

        return item.handle;
    }

    pub fn remove(self: *Renderables, handle: Renderables.Handle) void {
        self.storage.release(self.expansion_alloc, handle);
        const move_ctx = self.storageMoveCtx();
        self.storage.defragIfDensityLow(self.expansion_alloc, 0.8, move_ctx);
        self.storage.relciamMemory(self.expansion_alloc, move_ctx);

        if (builtin.mode == .Debug) {
            const cp = self.debug.scratch.checkpoint();
            defer self.debug.scratch.restore(cp);

            // Ensure that our move context is updating who he is supposed to
            // update. If we scramble on every object removal it will force us
            // to notice more often if something is wrong
            self.storage.scramble(
                self.expansion_alloc,
                self.debug.scratch.allocator(),
                self.debug.random,
                move_ctx,
            ) catch {
                std.log.err("failed to scramble for testing", .{});
            };
        }
    }

    const StorageMoveCtx = struct {
        parent: *Renderables,

        pub fn notifyMoved(self: StorageMoveCtx, _: Handle, to: Handle) void {
            const moved_elem = self.parent.storage.get(to);
            moved_elem.source_info.connection.updateRenderableHandle(moved_elem.source_info.surface, to);
        }
    };

    fn storageMoveCtx(self: *Renderables) StorageMoveCtx {
        return .{
            .parent = self,
        };
    }

    pub const Handle = struct {
        inner: usize,

        pub fn fromIdx(idx: usize) Handle {
            return .{ .inner = idx };
        }

        pub fn toIdx(self: Handle) usize {
            return self.inner;
        }
    };
};

fn asf32(in: anytype) f32 {
    return @floatFromInt(in);
}
