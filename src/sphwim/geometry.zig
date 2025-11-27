const std = @import("std");
const CompositorState = @import("CompositorState.zig");

pub const PixelQuad = struct {
    left: i32,
    top: i32,
    width: u31,
    height: u31,

    pub fn contains(self: PixelQuad, x: i32, y: i32) bool {
        return between(x, self.left, self.right()) and
            between(y, self.top, self.bottom());
    }

    pub fn right(self: PixelQuad) i32 {
        return self.left + self.width;
    }

    pub fn bottom(self: PixelQuad) i32 {
        return self.top + self.height;
    }

    pub fn cx(self: PixelQuad) f32 {
        var ret: f32 = @floatFromInt(self.width);
        ret /= 2.0;
        ret += @floatFromInt(self.left);
        return ret;
    }

    pub fn cy(self: PixelQuad) f32 {
        var ret: f32 = @floatFromInt(self.height);
        ret /= 2.0;
        ret += @floatFromInt(self.top);
        return ret;
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

    // top left pixel of buffer, relative to top left of screen
    surface_left: i32,
    surface_top: i32,

    surface_width: u31,
    surface_height: u31,

    pub const Location = enum {
        titlebar,
        surface,
        close,
        right_border,
        left_border,
        top_border,
        bottom_border,
    };

    pub fn fromRenderable(window: CompositorState.Window) WindowBorder {
        return .{
            // Windows don't move yet
            .surface_left = window.position.left,
            .surface_top = window.position.top,
            .surface_width = @intCast(window.buffer.width),
            .surface_height = @intCast(window.buffer.height),
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
            return .surface;
        }

        return null;
    }

    pub fn titleQuad(self: WindowBorder) PixelQuad {
        return .{
            .left = self.surface_left - trim_size,
            .top = self.titlebarTop(),
            .width = self.surface_width + 2 * trim_size,
            .height = titlebar_height,
        };
    }

    pub fn closeQuad(self: WindowBorder) PixelQuad {
        return .{
            .left = self.surface_left + self.surface_width - close_width,
            .top = self.titlebarTop() + trim_size,
            .width = close_width,
            .height = titlebar_height - trim_size * 2,
        };
    }

    pub fn rightBorderQuad(self: WindowBorder) PixelQuad {
        return .{
            .left = self.surface_left + self.surface_width,
            .top = self.titlebarTop(),
            .width = extra_trim_size,
            .height = self.surface_height + titlebar_height,
        };
    }

    pub fn leftBorderQuad(self: WindowBorder) PixelQuad {
        return .{
            .left = self.surface_left - extra_trim_size,
            .top = self.titlebarTop() - extra_trim_size,
            .width = extra_trim_size,
            .height = self.surface_height + titlebar_height,
        };
    }

    pub fn topBorderQuad(self: WindowBorder) PixelQuad {
        return .{
            .left = self.surface_left - trim_size,
            .top = self.surface_top - titlebar_height - extra_trim_size,
            .width = self.surface_width + trim_size * 2,
            .height = extra_trim_size,
        };
    }

    pub fn bottomBorderQuad(self: WindowBorder) PixelQuad {
        return .{
            .left = self.surface_left - trim_size,
            .top = self.surface_top + self.surface_height,
            .width = self.surface_width + trim_size * 2,
            .height = extra_trim_size,
        };
    }

    pub fn windowTrim(self: WindowBorder) PixelQuad {
        return .{
            .left = self.surface_left - trim_size,
            .top = self.surface_top - trim_size,
            .width = self.surface_width + 2 * trim_size,
            .height = self.surface_height + 2 * trim_size,
        };
    }

    pub fn surface(self: WindowBorder) PixelQuad {
        return .{
            .left = self.surface_left,
            .top = self.surface_top,
            .width = self.surface_width,
            .height = self.surface_height,
        };
    }

    fn titlebarTop(self: WindowBorder) i32 {
        return self.surface_top - titlebar_height;
    }
};
