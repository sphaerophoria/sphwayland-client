const std = @import("std");
const sphtud = @import("sphtud");
const wayland = @import("wayland.zig");
const rendering = @import("rendering.zig");
const FdPool = @import("FdPool.zig");

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

pub fn init(alloc: *sphtud.alloc.Sphalloc, scratch: *sphtud.alloc.BufAllocator, current_res: rendering.Resolution, render_backend: rendering.RenderBackend) !CompositorState {
    return .{
        .scratch = scratch,
        .compositor_res = current_res,
        .cursor_pos = .{
            .x = @floatFromInt(current_res.width / 2),
            .y = @floatFromInt(current_res.height / 2),
        },
        .renderables = try .init(alloc),
        .render_backend = render_backend,
    };
}

pub fn requestFrame(self: *CompositorState) !void {
    var it = self.renderables.source_info.iter();
    while (it.next()) |si| {
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
    source_info: sphtud.util.RuntimeSegmentedListSphalloc(SourceInfo),
    buffers: sphtud.util.RuntimeSegmentedListSphalloc(rendering.RenderBuffer),

    pub fn init(alloc: *sphtud.alloc.Sphalloc) !Renderables {
        return .{
            .source_info = try .init(
                alloc.arena(),
                alloc.block_alloc.allocator(),
                100,
                10000,
            ),
            .buffers = try .init(
                alloc.arena(),
                alloc.block_alloc.allocator(),
                100,
                10000,
            ),
        };
    }

    pub fn swapBuffer(self: *Renderables, handle: Renderables.Handle, new_buffer: rendering.RenderBuffer, new_buffer_id: wayland.Connection.WlBufferId) void {
        const source_info = self.source_info.getPtr(handle.inner);

        source_info.buffer_id = new_buffer_id;
        self.buffers.getPtr(handle.inner).* = new_buffer;
    }

    pub fn push(
        self: *Renderables,
        connection: *wayland.Connection,
        surface: wayland.Connection.WlSurfaceId,
        buffer: rendering.RenderBuffer,
        buffer_id: wayland.Connection.WlBufferId,
    ) !Handle {
        const renderable_id = self.source_info.len;

        try self.source_info.append(.{
            .connection = connection,
            .surface = surface,
            .buffer_id = buffer_id,
        });

        try self.buffers.append(buffer);

        std.debug.assert(self.buffers.len == self.source_info.len);

        return .{ .inner = renderable_id };
    }

    pub fn remove(self: *Renderables, handle: Renderables.Handle) void {
        self.source_info.swapRemove(handle.inner);
        self.buffers.swapRemove(handle.inner);

        if (handle.inner < self.source_info.len) {
            const moved = self.source_info.getPtr(handle.inner);
            moved.connection.updateRenderableHandle(moved.surface, handle);
        }
    }

    pub const Handle = struct {
        inner: usize,
    };
};

fn asf32(in: anytype) f32 {
    return @floatFromInt(in);
}
