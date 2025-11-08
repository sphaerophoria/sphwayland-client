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
    const titlebar_height = 30;
    const trim_size = 2;

    // Center position of buffer, relative to top left of screen
    surface_cx: i32,
    surface_cy: i32,

    surface_width: u31,
    surface_height: u31,

    pub fn fromRenderable(renderable: CompositorState.Renderable) WindowBorder {
        return .{
            // Windows don't move yet
            .surface_cx = renderable.cx,
            .surface_cy = renderable.cy,
            .surface_width = @intCast(renderable.buffer.width),
            .surface_height = @intCast(renderable.buffer.height),
        };
    }

    pub fn titleQuad(self: WindowBorder) PixelQuad {
        return .{
            .cx = self.surface_cx,
            .cy = self.titlebarCy(),
            .width = self.surface_width + 2 * trim_size,
            .height = titlebar_height,
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

    fn titlebarCy(self: WindowBorder) i32 {
        return self.surface_cy - titlebar_height / 2 - self.surface_height / 2;
    }
};
