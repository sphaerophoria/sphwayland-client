const std = @import("std");
const sphtud = @import("sphtud");
const wayland = @import("wayland.zig");
const rendering = @import("rendering.zig");

renderables: Renderables,
render_backend: rendering.RenderBackend,

const CompositorState = @This();

pub fn init(alloc: *sphtud.alloc.Sphalloc, render_backend: rendering.RenderBackend) !CompositorState {
    return .{
        .renderables = try .init(alloc),
        .render_backend = render_backend,
    };
}

pub fn getMetadata(self: *CompositorState, handle: Renderables.Handle) *RenderableMetadata {
    return self.renderables.metadata.getPtr(handle.inner);
}

pub fn pushRenderable(self: *CompositorState, connection: *wayland.Connection, surface: wayland.Connection.WlSurfaceId, buffer: rendering.RenderBuffer) !Renderables.Handle {
    const renderable_id = self.renderables.metadata.len;
    try self.renderables.metadata.append(.{
        .connection = connection,
        .surface = surface,
        .next_buffer = buffer,
    });

    try self.renderables.locked_buffers.append(buffer);

    std.debug.assert(self.renderables.locked_buffers.len == self.renderables.metadata.len);

    try connection.requestFrame(surface);
    try connection.io_writer.flush();

    // Workaround for having no DRI wakeups cause we aren't rendering a background
    if (renderable_id == 0) {
        try self.render_backend.displayBuffer(buffer);
    }

    return .{ .inner = renderable_id };
}

pub fn removeRenderable(self: *CompositorState, handle: Renderables.Handle) void {
    self.renderables.metadata.swapRemove(handle.inner);
    // FIXME: Surely we should be closing the file handle
    self.renderables.locked_buffers.swapRemove(handle.inner);

    if (handle.inner < self.renderables.metadata.len) {
        const moved = self.renderables.metadata.getPtr(handle.inner);
        moved.connection.updateRenderableHandle(moved.surface, handle);
    }
}

pub fn updateBuffers(self: *CompositorState) !void {
    var metadata_it = self.renderables.metadata.iter();
    var locked_it = self.renderables.locked_buffers.iter();

    std.debug.assert(self.renderables.metadata.len == self.renderables.locked_buffers.len);

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
};
