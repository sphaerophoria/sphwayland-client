const std = @import("std");
const sphtud = @import("sphtud");
const wayland = @import("wayland.zig");
const rendering = @import("rendering.zig");

renderables: Renderables,

const CompositorState = @This();

pub fn init(alloc: *sphtud.alloc.Sphalloc) !CompositorState {
    return .{
        .renderables = try .init(alloc),
    };
}

pub const RenderableMetadata = struct {
    connection: *wayland.Connection,
    surface: wayland.Connection.WlSurfaceId,
    next_buffer: rendering.RenderBuffer,
};

// Ties wayland surfaces that are ready to their renderable state
pub const Renderables = struct {
    metadata: sphtud.util.RuntimeSegmentedListSphalloc(RenderableMetadata),
    locked_buffers: sphtud.util.RuntimeSegmentedListSphalloc(rendering.RenderBuffer),

    pub fn init(alloc: *sphtud.alloc.Sphalloc) !Renderables {
        return .{
            .metadata = try .init(
                alloc.arena(),
                alloc.block_alloc.allocator(),
                100,
                10000,
            ),
            .locked_buffers = try .init(
                alloc.arena(),
                alloc.block_alloc.allocator(),
                100,
                10000,
            ),
        };
    }

    pub const Handle = struct {
        inner: usize,
    };

    pub fn getMetadata(self: *Renderables, handle: Handle) *RenderableMetadata {
        return self.metadata.getPtr(handle.inner);
    }

    pub fn pushRenderable(self: *Renderables, connection: *wayland.Connection, surface: wayland.Connection.WlSurfaceId, buffer: rendering.RenderBuffer) !Handle {
        const renderable_id = self.metadata.len;
        try self.metadata.append(.{
            .connection = connection,
            .surface = surface,
            .next_buffer = buffer,
        });

        try self.locked_buffers.append(buffer);

        std.debug.assert(self.locked_buffers.len == self.metadata.len);

        try connection.requestFrame(surface);
        try connection.io_writer.flush();

        return .{ .inner = renderable_id };
    }

    pub fn removeRenderable(self: *Renderables, handle: Handle) void {
        self.metadata.swapRemove(handle.inner);
        // FIXME: Surely we should be closing the file handle
        self.locked_buffers.swapRemove(handle.inner);

        if (handle.inner < self.metadata.len) {
            const moved = self.metadata.getPtr(handle.inner);
            moved.connection.updateRenderableHandle(moved.surface, handle);
        }
    }

    pub fn updateBuffers(self: *Renderables) !void {
        var metadata_it = self.metadata.iter();
        var locked_it = self.locked_buffers.iter();

        std.debug.assert(self.metadata.len == self.locked_buffers.len);

        var i: usize = 0;
        while (metadata_it.next()) |metadata| {
            defer i += 1;

            const locked_buffer = locked_it.next() orelse unreachable;

            const next_buffer = metadata.next_buffer;

            if (next_buffer.buf_fd == locked_buffer.buf_fd) {
                continue;
            }

            try metadata.connection.releaseBuffer(locked_buffer.wl_buffer);
            locked_buffer.* = next_buffer;

            try metadata.connection.requestFrame(metadata.surface);
            try metadata.connection.io_writer.flush();
        }
    }
};

