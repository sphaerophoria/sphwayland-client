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
windows: Windows,

const CursorPos = struct {
    x: f32,
    y: f32,
};

const DragState = union(enum) {
    moving_window: struct {
        id: Windows.Handle,
        last: CursorPos,
    },
    resize: struct {
        id: Windows.Handle,
        anchor: enum {
            left,
            right,
            bottom,
            top,
        },
        anchor_pos: i32,
    },
    none,

    fn resolveWindowHandle(self: *DragState, params: anytype, windows: *const Windows) ?Windows.UnstableHandle {
        return windows.toUnstable(params.id) orelse {
            std.log.err("drag state has invalid window handle, healing", .{});
            self.* = .none;
            return null;
        };
    }
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
        .windows = try .init(alloc),
    };
}

pub fn requestFrame(self: *CompositorState) !void {
    const source_infos = self.windows.items(.source_info);
    for (source_infos.inner) |si| {
        try si.connection.requestFrame(si.surface);
    }
}

pub fn notifyCursorMovement(self: *CompositorState, dx: f32, dy: f32) !void {
    try self.notifyCursorPosition(
        self.cursor_pos.x + dx,
        self.cursor_pos.y + dy,
    );
}

pub fn notifyCursorPosition(self: *CompositorState, x: f32, y: f32) !void {
    self.cursor_pos.x = std.math.clamp(x, 0, asf32(self.compositor_res.width));
    self.cursor_pos.y = std.math.clamp(y, 0, asf32(self.compositor_res.height));

    switch (self.drag_state) {
        .moving_window => |*params| {
            const unstable_id = self.drag_state.resolveWindowHandle(params, &self.windows) orelse return;
            const position = self.windows.items(.position).getPtr(unstable_id);
            position.left += @intFromFloat(self.cursor_pos.x - params.last.x);
            position.top += @intFromFloat(self.cursor_pos.y - params.last.y);
            params.last = self.cursor_pos;
        },
        .resize => |*params| {
            const unstable_id = self.drag_state.resolveWindowHandle(params, &self.windows) orelse return;
            const si = self.windows.items(.source_info).getPtr(unstable_id);
            const buffer = self.windows.items(.buffer).getPtr(unstable_id);

            var new_width: f32 = @floatFromInt(buffer.width);
            var new_height: f32 = @floatFromInt(buffer.height);
            switch (params.anchor) {
                .left => {
                    new_width = self.cursor_pos.x - @as(f32, @floatFromInt(params.anchor_pos));
                },
                .right => {
                    new_width = @as(f32, @floatFromInt(params.anchor_pos)) - self.cursor_pos.x;
                },
                .top => {
                    new_height = self.cursor_pos.y - @as(f32, @floatFromInt(params.anchor_pos));
                },
                .bottom => {
                    new_height = @as(f32, @floatFromInt(params.anchor_pos)) - self.cursor_pos.y - geometry.WindowBorder.titlebar_height;
                },
            }
            new_width = @max(new_width, 1);
            new_height = @max(new_height, 1);

            try si.connection.requestResize(si.surface, @intFromFloat(new_width), @intFromFloat(new_height));
        },
        .none => {
            if (try self.findHoveredWindow()) |hovered| {
                switch (hovered.location) {
                    .surface => |pos| {
                        const source_info = self.windows.items(.source_info).get(hovered.unstable);
                        try source_info.connection.notifyCursorPosition(source_info.surface, pos.x, pos.y);
                    },
                    else => {},
                }
            }
        },
    }
}

pub fn pushWindow(
    self: *CompositorState,
    connection: *wayland.Connection,
    surface: wayland.Connection.WlSurfaceId,
    buffer: rendering.RenderBuffer,
    buffer_id: wayland.Connection.WlBufferId,
    window_id: wayland.Connection.XdgToplevelId,
) !Windows.Handle {
    const handles = try self.windows.addOne();

    self.windows.set(handles.unstable, .{
        .stable_handle = handles.stable,
        .source_info = .{
            .connection = connection,
            .surface = surface,
            .buffer_id = buffer_id,
            .window = window_id,
        },
        .position = .{
            .left = @as(i32, self.compositor_res.width / 2) - @divTrunc(buffer.width, 2),
            .top = @as(i32, self.compositor_res.height / 2) - @divTrunc(buffer.height, 2),
        },
        .buffer = buffer,
    });

    return handles.stable;
}

pub fn removeWindow(self: *CompositorState, handle: Windows.Handle) void {
    switch (self.drag_state) {
        inline .moving_window, .resize => |move_state| {
            if (move_state.id.inner == handle.inner) {
                self.drag_state = .none;
            }
        },
        .none => {},
    }

    self.windows.orderedRemove(handle);
}

pub fn swapWindowBuffer(self: *CompositorState, handle: Windows.Handle, new_buffer: rendering.RenderBuffer, new_buffer_id: wayland.Connection.WlBufferId) void {
    const unstable_handle = self.windows.toUnstable(handle) orelse {
        std.log.err("swapping window buffer on invalid handle", .{});
        return;
    };
    const source_info = self.windows.items(.source_info).getPtr(unstable_handle);
    const buffer = self.windows.items(.buffer).getPtr(unstable_handle);
    self.pinDragAnchor(unstable_handle, new_buffer);

    source_info.buffer_id = new_buffer_id;
    buffer.* = new_buffer;
}

fn pinDragAnchor(self: *CompositorState, handle: Windows.UnstableHandle, new_buffer: rendering.RenderBuffer) void {
    const position = self.windows.items(.position).getPtr(handle);

    const resize_params = switch (self.drag_state) {
        .resize => |r| r,
        .none, .moving_window => return,
    };

    const resize_unstable = self.windows.toUnstable(resize_params.id) orelse return;
    if (resize_unstable.inner != handle.inner) return;

    switch (resize_params.anchor) {
        .right => {
            position.left = resize_params.anchor_pos - new_buffer.width;
        },
        .bottom => {
            position.top = resize_params.anchor_pos - new_buffer.height;
        },
        .left, .top => {},
    }
}

pub fn notifyMouse1Up(self: *CompositorState) void {
    self.drag_state = .none;
}

const WindowFgResult = struct {
    location: geometry.WindowBorder.Location,
    stable: Windows.Handle,
    unstable: Windows.UnstableHandle,
};

fn moveToFront(self: *CompositorState, handle: Windows.UnstableHandle) void {
    self.windows.moveToEnd(handle);
}

fn findHoveredWindow(self: *CompositorState) !?WindowFgResult {
    var it = self.windows.iter();
    while (it.next()) {
        const window = it.get();
        const window_border = geometry.WindowBorder.fromRenderable(window);
        const cursor_x: i32 = @intFromFloat(self.cursor_pos.x);
        const cursor_y: i32 = @intFromFloat(self.cursor_pos.y);

        if (window_border.contains(cursor_x, cursor_y)) |location| {
            return .{
                .location = location,
                .stable = it.handle(),
                .unstable = it.unstableHandle(),
            };
        }
    }

    return null;
}

pub fn notifyMouse1Down(self: *CompositorState) !void {
    const res = (try self.findHoveredWindow()) orelse return;
    switch (res.location) {
        .titlebar => {
            self.drag_state = .{
                .moving_window = .{
                    .id = res.stable,
                    .last = self.cursor_pos,
                },
            };
        },
        .right_border => {
            const renderable = self.windows.getUnstable(res.unstable);
            self.drag_state = .{
                .resize = .{
                    .id = res.stable,
                    .anchor = .left,
                    .anchor_pos = renderable.position.left,
                },
            };
        },
        .left_border => {
            const renderable = self.windows.getUnstable(res.unstable);
            self.drag_state = .{
                .resize = .{
                    .id = res.stable,
                    .anchor = .right,
                    .anchor_pos = renderable.position.left + renderable.buffer.width,
                },
            };
        },
        .top_border => {
            const renderable = self.windows.getUnstable(res.unstable);
            self.drag_state = .{
                .resize = .{
                    .id = res.stable,
                    .anchor = .bottom,
                    .anchor_pos = renderable.position.top + renderable.buffer.height,
                },
            };
        },
        .bottom_border => {
            const renderable = self.windows.getUnstable(res.unstable);
            self.drag_state = .{
                .resize = .{
                    .id = res.stable,
                    .anchor = .top,
                    .anchor_pos = renderable.position.top,
                },
            };
        },
        .close => {
            const source_info = self.windows.items(.source_info).get(res.unstable);
            try source_info.connection.closeWindow(source_info.window);
        },
        .surface => {},
    }

    self.moveToFront(res.unstable);
}

pub const SourceInfo = struct {
    connection: *wayland.Connection,
    surface: wayland.Connection.WlSurfaceId,
    window: wayland.Connection.XdgToplevelId,
    buffer_id: wayland.Connection.WlBufferId,
};

pub const Window = struct {
    stable_handle: Windows.Handle,
    source_info: SourceInfo,
    position: struct {
        left: i32,
        top: i32,
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

fn calcMultiArrayListPageNumElems(page_size_log2: u8) usize {
    var size_per_item: usize = 0;
    var worst_case_pad: usize = 0;

    inline for (std.meta.fields(Window)) |field| {
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

    const capacity_bytes = std.MultiArrayList(Window).capacityInBytes(num_elems);
    try std.testing.expect(capacity_bytes <= page_size);
    try std.testing.expect(capacity_bytes > page_size * 9 / 10);
}

// Ties wayland surfaces that are ready to their window state
pub const Windows = struct {
    expansion_alloc: sphtud.util.ExpansionAlloc,
    id_map: sphtud.util.AutoHashMap(Handle, UnstableHandle),
    next_id: u64,
    storage: std.MultiArrayList(Window),

    const max_num_windows = 1 << 14;

    pub fn init(alloc: *sphtud.alloc.Sphalloc) !Windows {
        const expansion_alloc = alloc.expansion();

        var storage = std.MultiArrayList(Window){};
        try storage.setCapacity(expansion_alloc.alloc, calcMultiArrayListPageNumElems(expansion_alloc.info.min_expansion_size_log2));

        return .{
            .expansion_alloc = expansion_alloc,
            .id_map = try .init(alloc.arena(), expansion_alloc, 100, max_num_windows),
            .next_id = 1,
            .storage = storage,
        };
    }

    pub fn addOne(self: *Windows) !Handles {
        if (self.storage.len >= max_num_windows) return error.OutOfMemory;

        const unstable_handle = UnstableHandle{ .inner = try self.storage.addOne(self.expansion_alloc.alloc) };

        while (self.id_map.contains(.{ .inner = self.next_id })) {
            self.next_id +%= 1;
        }

        const stable_handle = Handle{ .inner = self.next_id };
        self.next_id +%= 1;

        try self.id_map.put(stable_handle, unstable_handle);

        return .{
            .stable = stable_handle,
            .unstable = unstable_handle,
        };
    }

    const Iter = struct {
        idx: usize,
        storage: std.MultiArrayList(Window).Slice,

        pub fn next(self: *Iter) bool {
            if (self.idx == 0) {
                return false;
            }
            self.idx -= 1;
            return true;
        }

        pub fn item(self: Iter, comptime field: std.MultiArrayList(Window).Field) *@FieldType(Window, @tagName(field)) {
            self.storage.items(field)[self.idx];
        }

        pub fn get(self: Iter) Window {
            return self.storage.get(self.idx);
        }

        pub fn handle(self: Iter) Handle {
            return self.storage.items(.stable_handle)[self.idx];
        }

        pub fn unstableHandle(self: Iter) UnstableHandle {
            return .{ .inner = self.idx };
        }
    };

    pub fn iter(self: *Windows) Iter {
        return .{
            .idx = self.storage.len,
            .storage = self.storage.slice(),
        };
    }

    pub fn set(self: *Windows, handle: UnstableHandle, window: Window) void {
        self.storage.set(handle.inner, window);
    }

    const Handles = struct {
        stable: Handle,
        unstable: UnstableHandle,
    };

    pub fn count(self: Windows) usize {
        return self.storage.len;
    }

    pub fn orderedRemove(self: *Windows, handle: Handle) void {
        const unstable_handle = self.toUnstable(handle).?;

        self.storage.orderedRemove(unstable_handle.inner);
        _ = self.id_map.remove(handle);

        var id_map_it = self.id_map.iter();
        while (id_map_it.next()) |elem| {
            if (elem.val.inner >= unstable_handle.inner) {
                elem.val.inner -= 1;
            }
        }
    }

    pub fn Items(comptime T: type) type {
        return struct {
            inner: []T,

            fn get(self: @This(), handle: UnstableHandle) T {
                return self.inner[handle.inner];
            }

            fn getPtr(self: @This(), handle: UnstableHandle) *T {
                return &self.inner[handle.inner];
            }
        };
    }

    pub fn items(self: *Windows, comptime field: std.MultiArrayList(Window).Field) Items(@FieldType(Window, @tagName(field))) {
        return .{ .inner = self.storage.items(field) };
    }

    pub fn get(self: *Windows, handle: Handle) ?Window {
        const unstable_id = self.id_map.get(handle) orelse return null;
        return self.getUnstable(unstable_id);
    }

    pub fn getUnstable(self: *Windows, handle: UnstableHandle) Window {
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

    const UnstableHandle = struct {
        inner: usize,
    };

    pub fn toUnstable(self: *const Windows, handle: Handle) ?UnstableHandle {
        return self.id_map.get(handle);
    }

    fn moveToEnd(self: *Windows, handle: UnstableHandle) void {
        const multi_slice = self.storage.slice().subslice(handle.inner, self.storage.len - handle.inner);
        inline for (std.meta.fields(Window)) |field| {
            const field_tag = comptime std.meta.stringToEnum(std.MultiArrayList(Window).Field, field.name) orelse unreachable;
            const slice = multi_slice.items(field_tag);
            std.mem.rotate(field.type, slice, 1);
        }

        var it = self.id_map.iter();
        while (it.next()) |elem| {
            if (elem.val.inner == handle.inner) {
                elem.val.inner = self.storage.len - 1;
            } else if (elem.val.inner > handle.inner) {
                elem.val.inner -= 1;
            }
        }
    }
};

fn asf32(in: anytype) f32 {
    return @floatFromInt(in);
}
