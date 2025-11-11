const std = @import("std");
const CompositorState = @import("CompositorState.zig");

pub const PixelQuad = struct {
    cx: i32,
    cy: i32,
    width: u31,
    height: u31,

    pub fn contains(self: PixelQuad, x: i32, y: i32) bool {
        return between(x, self.left(), self.right()) and
            between(y, self.top(), self.bottom());
    }

    pub fn left(self: PixelQuad) i32 {
        return self.cx - self.width / 2;
    }

    pub fn right(self: PixelQuad) i32 {
        return self.cx + self.width / 2;
    }

    pub fn top(self: PixelQuad) i32 {
        return self.cy - self.height / 2;
    }

    pub fn bottom(self: PixelQuad) i32 {
        return self.cy + self.height / 2;
    }
};

fn between(val: i32, a: i32, b: i32) bool {
    return val >= a and val <= b;
}

pub const WindowBorder = struct {
    pub const titlebar_height = 30;
    const trim_size = 2;
    const extra_trim_size = 8;
    const close_width = titlebar_height;

    // Center position of buffer, relative to top left of screen
    surface_cx: i32,
    surface_cy: i32,

    surface_width: u31,
    surface_height: u31,

    pub const Location = union(enum) {
        titlebar,
        close,
        right_border,
        left_border,
        top_border,
        bottom_border,
        surface: struct {
            x: i32,
            y: i32,
        },
    };

    pub fn fromRenderable(renderable: CompositorState.Renderable) WindowBorder {
        return .{
            // Windows don't move yet
            .surface_cx = renderable.cx,
            .surface_cy = renderable.cy,
            .surface_width = @intCast(renderable.buffer.width),
            .surface_height = @intCast(renderable.buffer.height),
        };
    }

    pub fn contains(self: WindowBorder, x: i32, y: i32) ?Location {
        if (self.closeQuad().contains(x, y)) {
            return .close;
        }

        if (self.rightBorderQuad().contains(x, y)) {
            return .right_border;
        }

        if (self.leftBorderQuad().contains(x, y)) {
            return .left_border;
        }

        if (self.topBorderQuad().contains(x, y)) {
            return .top_border;
        }

        if (self.bottomBorderQuad().contains(x, y)) {
            return .bottom_border;
        }

        if (self.titleQuad().contains(x, y)) {
            return .titlebar;
        }

        const surface_quad = self.surface();
        if (surface_quad.contains(x, y)) {
            return .{ .surface = .{
                .x = x - surface_quad.left(),
                .y = y - surface_quad.top(),
            } };
        }

        return null;
    }

    pub fn titleQuad(self: WindowBorder) PixelQuad {
        return .{
            .cx = self.surface_cx,
            .cy = self.titlebarCy(),
            .width = self.surface_width + 2 * trim_size,
            .height = titlebar_height,
        };
    }

    pub fn closeQuad(self: WindowBorder) PixelQuad {
        return .{
            .cx = self.surface_cx + self.surface_width / 2 - close_width / 2,
            .cy = self.titlebarCy(),
            .width = close_width,
            .height = titlebar_height - trim_size * 2,
        };
    }

    pub fn rightBorderQuad(self: WindowBorder) PixelQuad {
        return .{
            .cx = self.surface_cx + self.surface_width / 2 + extra_trim_size / 2,
            .cy = self.surface_cy,
            .width = extra_trim_size,
            // FIXME: Hard to say where the border for dragging should end
            .height = self.surface_height + trim_size * 2,
        };
    }

    pub fn leftBorderQuad(self: WindowBorder) PixelQuad {
        return .{
            .cx = self.surface_cx - self.surface_width / 2 - extra_trim_size / 2,
            .cy = self.surface_cy,
            .width = extra_trim_size,
            // FIXME: Hard to say where the border for dragging should end
            .height = self.surface_height + trim_size * 2,
        };
    }

    pub fn topBorderQuad(self: WindowBorder) PixelQuad {
        return .{
            .cx = self.surface_cx,
            .cy = self.surface_cy - self.surface_height / 2 - titlebar_height - extra_trim_size / 2,
            .width = self.surface_width + trim_size * 2,
            // FIXME: Hard to say where the border for dragging should end
            .height = extra_trim_size,
        };
    }

    pub fn bottomBorderQuad(self: WindowBorder) PixelQuad {
        return .{
            .cx = self.surface_cx,
            .cy = self.surface_cy + self.surface_height / 2 + extra_trim_size / 2,
            .width = self.surface_width + trim_size * 2,
            // FIXME: Hard to say where the border for dragging should end
            .height = extra_trim_size,
        };
    }

    pub fn windowTrim(self: WindowBorder) PixelQuad {
        return .{
            .cx = self.surface_cx,
            .cy = self.surface_cy,
            .width = self.surface_width + 2 * trim_size,
            .height = self.surface_height + 2 * trim_size,
        };
    }

    pub fn surface(self: WindowBorder) PixelQuad {
        return .{
            .cx = self.surface_cx,
            .cy = self.surface_cy,
            .width = self.surface_width,
            .height = self.surface_height,
        };
    }

    fn titlebarCy(self: WindowBorder) i32 {
        return self.surface_cy - titlebar_height / 2 - self.surface_height / 2;
    }
};
