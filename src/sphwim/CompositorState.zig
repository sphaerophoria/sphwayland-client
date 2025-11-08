const std = @import("std");
const sphtud = @import("sphtud");
const wayland = @import("wayland.zig");
const rendering = @import("rendering.zig");
const FdPool = @import("FdPool.zig");
const builtin = @import("builtin");
const geometry = @import("geometry.zig");

scratch: *sphtud.alloc.BufAllocator,
compositor_res: rendering.Resolution,
drag_state: DragState,
cursor_pos: CursorPos,
renderables: Renderables,

const CursorPos = struct {
    x: f32,
    y: f32,
};

const DragState = union(enum) {
    moving_window: struct {
        id: Renderables.Handle,
        last: CursorPos,
    },
    none,
};

const CompositorState = @This();

pub fn init(alloc: *sphtud.alloc.Sphalloc, scratch: *sphtud.alloc.BufAllocator, current_res: rendering.Resolution) !CompositorState {
    return .{
        .scratch = scratch,
        .compositor_res = current_res,
        .cursor_pos = .{
            .x = @floatFromInt(current_res.width / 2),
            .y = @floatFromInt(current_res.height / 2),
        },
        .drag_state = .none,
        .renderables = try .init(alloc),
    };
}

pub fn requestFrame(self: *CompositorState) !void {
    const source_infos = self.renderables.items(.source_info);
    for (source_infos.inner) |si| {
        try si.connection.requestFrame(si.surface);
    }
}

pub fn notifyCursorMovement(self: *CompositorState, dx: f32, dy: f32) void {
    self.notifyCursorPosition(
        self.cursor_pos.x + dx,
        self.cursor_pos.y + dy,
    );
}

pub fn notifyCursorPosition(self: *CompositorState, x: f32, y: f32) void {
    self.cursor_pos.x = std.math.clamp(x, 0, asf32(self.compositor_res.width));
    self.cursor_pos.y = std.math.clamp(y, 0, asf32(self.compositor_res.height));

    switch (self.drag_state) {
        .moving_window => |*params| {
            const position = self.renderables.items(.position).getPtr(params.id);
            position.cx += @intFromFloat(self.cursor_pos.x - params.last.x);
            position.cy += @intFromFloat(self.cursor_pos.y - params.last.y);
            params.last = self.cursor_pos;
        },
        .none => {},
    }
}

pub fn pushRenderable(
    self: *CompositorState,
    connection: *wayland.Connection,
    surface: wayland.Connection.WlSurfaceId,
    buffer: rendering.RenderBuffer,
    buffer_id: wayland.Connection.WlBufferId,
) !Renderables.Handle {
    const handle = try self.renderables.addOne();

    self.renderables.set(handle, .{
        .source_info = .{
            .connection = connection,
            .surface = surface,
            .buffer_id = buffer_id,
        },
        .position = .{
            .cx = @intCast(self.compositor_res.width / 2),
            .cy = @intCast(self.compositor_res.height / 2),
        },
        .buffer = buffer,
    });

    return handle;
}

pub fn removeRenderable(self: *CompositorState, handle: Renderables.Handle) void {
    switch (self.drag_state) {
        .moving_window => |move_state| {
            if (move_state.id.inner == handle.inner) {
                self.drag_state = .none;
            }
        },
        .none => {},
    }

    self.renderables.orderedRemove(handle);
    self.healRenderableReferences(handle.inner, self.renderables.count(), .removal);
}

pub fn notifyMouse1Up(self: *CompositorState) void {
    self.drag_state = .none;
}

const WindowFgResult = struct {
    location: geometry.WindowBorder.Location,
    handle: Renderables.Handle,
};

fn moveToFront(self: *CompositorState, handle: Renderables.Handle) void {
    self.renderables.moveToEnd(handle);
    self.healRenderableReferences(handle.inner, self.renderables.count(), .{ .rotation = -1 });
}

fn findClickedWindow(self: *CompositorState) !?WindowFgResult {
    var it = self.renderables.iter();
    while (it.next()) {
        const renderable = it.get();
        const window_border = geometry.WindowBorder.fromRenderable(renderable);
        const cursor_x: i32 = @intFromFloat(self.cursor_pos.x);
        const cursor_y: i32 = @intFromFloat(self.cursor_pos.y);

        if (window_border.titleQuad().contains(cursor_x, cursor_y)) {
            return .{
                .location = .titlebar,
                .handle = it.handle(),
            };
        }

        if (window_border.windowTrim().contains(cursor_x, cursor_y)) {
            return .{
                .location = .surface,
                .handle = it.handle(),
            };
        }
    }

    return null;
}

pub fn notifyMouse1Down(self: *CompositorState) !void {
    const res = (try self.findClickedWindow()) orelse return;
    switch (res.location) {
        .titlebar => {
            self.drag_state = .{
                .moving_window = .{
                    .id = res.handle,
                    .last = self.cursor_pos,
                },
            };
        },
        .surface => {},
    }

    self.moveToFront(res.handle);
}

pub const SourceInfo = struct {
    connection: *wayland.Connection,
    surface: wayland.Connection.WlSurfaceId,
    buffer_id: wayland.Connection.WlBufferId,
};

pub const Renderable = struct {
    source_info: SourceInfo,
    position: struct {
        cx: i32,
        cy: i32,
    },
    buffer: rendering.RenderBuffer,
};

const HealReason = union(enum) {
    rotation: i32,
    removal,
};

fn oldIndex(start: usize, end: usize, current: usize, reason: HealReason) usize {
    switch (reason) {
        .removal => {
            return current + 1;
        },
        .rotation => |rotation| {
            const current_offs = current - start;
            const current_offsi: i32 = @intCast(current_offs);

            const old_offsi = @mod((current_offsi - rotation), @as(i32, @intCast(end - start)));
            return @intCast(start + @as(usize, @intCast(old_offsi)));
        },
    }
}

test "oldIndex" {
    try std.testing.expectEqual(3, oldIndex(3, 6, 4, .{ .rotation = -2 }));
    try std.testing.expectEqual(5, oldIndex(3, 6, 4, .{ .rotation = -1 }));
    try std.testing.expectEqual(3, oldIndex(3, 6, 4, .{ .rotation = 1 }));
    try std.testing.expectEqual(5, oldIndex(3, 6, 4, .{ .rotation = 2 }));

    try std.testing.expectEqual(5, oldIndex(3, 6, 4, .removal));
    try std.testing.expectEqual(6, oldIndex(3, 6, 5, .removal));
}

fn healRenderableReferences(self: *CompositorState, start: usize, end: usize, reason: HealReason) void {
    const source_infos = self.renderables.items(.source_info);

    for (source_infos.inner[start..end], start..) |si, new_idx| {
        const new_handle = Renderables.Handle{ .inner = new_idx };
        si.connection.updateRenderableHandle(si.surface, new_handle);
    }

    for (start..end) |new_idx| {
        const old_idx = oldIndex(start, end, new_idx, reason);

        switch (self.drag_state) {
            inline .moving_window => |*move_state| {
                if (move_state.id.inner == old_idx) {
                    move_state.id = .fromIdx(new_idx);
                }
            },
            .none => {},
        }
    }
}

fn calcMultiArrayListPageNumElems(page_size_log2: u8) usize {
    var size_per_item: usize = 0;
    var worst_case_pad: usize = 0;

    inline for (std.meta.fields(Renderable)) |field| {
        size_per_item += @sizeOf(field.type);
        // If every element is somehow really poorly aligned this is what we
        // would see. In reality we have guarantees about how adjacent fields
        // interplay, but I don't think it's relevant enough to matter here
        worst_case_pad += @alignOf(field.type) - 1;
    }

    // page_size = N * size_per_item + worst_case_pad
    // N = ((page_size - worst_case_pad) / size_per_item)

    const page_size = @as(usize, 1) << @intCast(page_size_log2);
    return (page_size - worst_case_pad) / size_per_item;
}

test "calcMultiArrayListPageNumElems" {
    const page_size = 4096;
    const num_elems = calcMultiArrayListPageNumElems(std.math.log2(page_size));

    const capacity_bytes = std.MultiArrayList(Renderable).capacityInBytes(num_elems);
    try std.testing.expect(capacity_bytes <= page_size);
    try std.testing.expect(capacity_bytes > page_size * 9 / 10);
}

// Ties wayland surfaces that are ready to their renderable state
pub const Renderables = struct {
    expansion_alloc: sphtud.util.ExpansionAlloc,
    storage: std.MultiArrayList(Renderable),

    pub fn init(alloc: *sphtud.alloc.Sphalloc) !Renderables {
        const expansion_alloc = alloc.expansion();

        var storage = std.MultiArrayList(Renderable){};
        try storage.setCapacity(expansion_alloc.alloc, calcMultiArrayListPageNumElems(expansion_alloc.info.min_expansion_size_log2));

        return .{
            .expansion_alloc = expansion_alloc,
            .storage = storage,
        };
    }

    pub fn swapBuffer(self: *Renderables, handle: Renderables.Handle, new_buffer: rendering.RenderBuffer, new_buffer_id: wayland.Connection.WlBufferId) void {
        const slice = self.storage.slice();
        slice.items(.source_info)[handle.inner].buffer_id = new_buffer_id;
        slice.items(.buffer)[handle.inner] = new_buffer;
    }

    pub fn addOne(self: *Renderables) !Handle {
        return .{ .inner = try self.storage.addOne(self.expansion_alloc.alloc) };
    }

    const Iter = struct {
        idx: usize,
        storage: std.MultiArrayList(Renderable).Slice,

        pub fn next(self: *Iter) bool {
            if (self.idx == 0) {
                return false;
            }
            self.idx -= 1;
            return true;
        }

        pub fn item(self: Iter, comptime field: std.MultiArrayList(Renderable).Field) *@FieldType(Renderable, @tagName(field)) {
            self.storage.items(field)[self.idx];
        }

        pub fn get(self: Iter) Renderable {
            return self.storage.get(self.idx);
        }

        pub fn handle(self: Iter) Handle {
            return .fromIdx(self.idx);
        }
    };

    pub fn iter(self: *Renderables) Iter {
        return .{
            .idx = self.storage.len,
            .storage = self.storage.slice(),
        };
    }

    pub fn set(self: *Renderables, handle: Handle, renderable: Renderable) void {
        self.storage.set(handle.inner, renderable);
    }

    pub fn count(self: Renderables) usize {
        return self.storage.len;
    }

    pub fn orderedRemove(self: *Renderables, handle: Handle) void {
        self.storage.orderedRemove(handle.inner);
    }

    pub fn Items(comptime T: type) type {
        return struct {
            inner: []T,

            fn get(self: @This(), handle: Handle) T {
                return self.inner[handle.inner];
            }

            fn getPtr(self: @This(), handle: Handle) *T {
                return &self.inner[handle.inner];
            }
        };
    }

    pub fn items(self: *Renderables, comptime field: std.MultiArrayList(Renderable).Field) Items(@FieldType(Renderable, @tagName(field))) {
        return .{ .inner = self.storage.items(field) };
    }

    pub fn get(self: *Renderables, handle: Handle) Renderable {
        return self.storage.get(handle.inner);
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

    pub fn moveToEnd(self: *Renderables, handle: Handle) void {
        const multi_slice = self.storage.slice().subslice(handle.inner, self.storage.len - handle.inner);
        inline for (std.meta.fields(Renderable)) |field| {
            const field_tag = comptime std.meta.stringToEnum(std.MultiArrayList(Renderable).Field, field.name) orelse unreachable;
            const slice = multi_slice.items(field_tag);
            std.mem.rotate(field.type, slice, 1);
        }
    }
};

fn asf32(in: anytype) f32 {
    return @floatFromInt(in);
}
