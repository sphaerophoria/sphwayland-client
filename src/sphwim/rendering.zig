const std = @import("std");
const sphtud = @import("sphtud");
const wayland = @import("wayland.zig");
const FdPool = @import("FdPool.zig");
const CompositorState = @import("CompositorState.zig");
const geometry = @import("geometry.zig");
const system_gl = @import("system_gl.zig");
const gl = sphtud.render.gl;
const cursor_img = @import("cursor.zig");

const logger = std.log.scoped(.rendering);

pub const RenderBuffer = struct {
    buf_fd: c_int,
    modifiers: u64,
    offset: u32,
    plane_idx: u32,
    stride: u32,
    width: i32,
    height: i32,
    format: u32,

    pub fn fromGbm(gbm_buf: system_gl.GbmContext.Buffer) !RenderBuffer {
        return .{
            .buf_fd = try gbm_buf.fd(),
            .modifiers = gbm_buf.modifier(),
            .offset = gbm_buf.offset(),
            .plane_idx = 0, // HACK, assume plane 0
            .stride = gbm_buf.stride(),
            .width = @intCast(gbm_buf.width()),
            .height = @intCast(gbm_buf.height()),
            .format = gbm_buf.format(),
        };
    }

    pub fn deinit(self: RenderBuffer) void {
        std.posix.close(self.buf_fd);
    }
};

pub const Resolution = struct {
    width: u32,
    height: u32,
};

fn asf32(in: anytype) f32 {
    return @floatFromInt(in);
}

const window_border_color = sphtud.math.Vec3{
    41.0 / 255.0,
    36.0 / 255.0,
    45.0 / 255.0,
};

const close_default_color = sphtud.math.Vec3{
    100.0 / 255.0,
    0.0,
    0.0,
};

const close_hover_color = sphtud.math.Vec3{
    130.0 / 255.0,
    0.0,
    0.0,
};

pub const Renderer = struct {
    frame_gl_alloc: *sphtud.render.GlAlloc,
    scratch: sphtud.alloc.LinearAllocator,

    egl_ctx: *system_gl.EglContext,
    gbm_ctx: *system_gl.GbmContext,

    compositor_state: *CompositorState,
    image_renderer: sphtud.render.xyuvt_program.ImageRenderer,

    solid_color_renderer: sphtud.render.xyt_program.SolidColorProgram,
    fullscreen_quad: sphtud.render.xyt_program.RenderSource,

    last_render_time: std.time.Instant,

    render_in_progress: bool,
    backend_rendering_buf: ?system_gl.GbmContext.Buffer,

    // Eventually we won't need this, but for now it's useful to prove that the
    // compositor is rendering
    background_animation_state: f32 = 1.0,
    cursor_tex: sphtud.render.Texture,

    pub fn init(
        alloc: *sphtud.alloc.Sphalloc,
        scratch: sphtud.alloc.LinearAllocator,
        gl_alloc: *sphtud.render.GlAlloc,
        egl_ctx: *system_gl.EglContext,
        gbm_ctx: *system_gl.GbmContext,
        compositor_state: *CompositorState,
        image_renderer: sphtud.render.xyuvt_program.ImageRenderer,
        solid_color_renderer: sphtud.render.xyt_program.SolidColorProgram,
    ) !Renderer {
        const cp = scratch.checkpoint();
        defer scratch.restore(cp);

        const rgba_data = try cursor_img.makeRgba(scratch.allocator());
        const cursor_tex = try sphtud.render.makeTextureFromRgba(
            gl_alloc,
            rgba_data,
            cursor_img.width,
        );

        const fullscreen_quad_buf = try sphtud.render.xyt_program.Buffer.init(gl_alloc, &.{
            .{ .vPos = .{ -1.0, -1.0 } },
            .{ .vPos = .{ -1.0, 1.0 } },
            .{ .vPos = .{ 1.0, 1.0 } },

            .{ .vPos = .{ -1.0, -1.0 } },
            .{ .vPos = .{ 1.0, 1.0 } },
            .{ .vPos = .{ 1.0, -1.0 } },
        });
        var fullscreen_quad_render_source = try sphtud.render.xyt_program.RenderSource.init(gl_alloc);
        fullscreen_quad_render_source.bindData(solid_color_renderer.handle(), fullscreen_quad_buf);

        return .{
            .frame_gl_alloc = try gl_alloc.makeSubAlloc(alloc),
            .scratch = scratch,
            .last_render_time = try std.time.Instant.now(),
            .compositor_state = compositor_state,
            .egl_ctx = egl_ctx,
            .gbm_ctx = gbm_ctx,
            .render_in_progress = false,
            .image_renderer = image_renderer,
            .solid_color_renderer = solid_color_renderer,
            .fullscreen_quad = fullscreen_quad_render_source,
            .backend_rendering_buf = null,
            .cursor_tex = cursor_tex,
        };
    }

    pub fn releaseBuffer(self: *Renderer, buf: system_gl.GbmContext.Buffer) void {
        self.gbm_ctx.unlock(buf);
    }

    pub fn render(self: *Renderer) !?system_gl.GbmContext.Buffer {
        const cp = self.scratch.checkpoint();
        defer self.scratch.restore(cp);

        const now = try std.time.Instant.now();
        defer self.last_render_time = now;

        const delta_ns = now.since(self.last_render_time);
        const delta = @as(f32, @floatFromInt(delta_ns)) / std.time.ns_per_s;

        const background_red = @abs(self.background_animation_state - 1.0);
        gl.glClearColor(background_red, 0.0, 0.0, 1.0);
        gl.glClearDepth(std.math.inf(f32));
        gl.glClear(gl.GL_COLOR_BUFFER_BIT | gl.GL_DEPTH_BUFFER_BIT);
        self.background_animation_state = @mod(self.background_animation_state + delta / 4.0, 2.0);

        const renderables = &self.compositor_state.renderables;

        defer self.frame_gl_alloc.reset();

        const num_renderables = renderables.storage.count();

        const renderables_sorted = try self.compositor_state.renderables.getSortedHandles(self.scratch.allocator());

        var hover_found: bool = false;
        const cursor_x: i32 = @intFromFloat(self.compositor_state.cursor_pos.x);
        const cursor_y: i32 = @intFromFloat(self.compositor_state.cursor_pos.y);
        for (renderables_sorted, 0..) |handle, depth| {
            std.debug.print("Rendering {d}\n", .{handle.inner});
            const renderable = renderables.storage.get(handle);
            self.renderWindowSurface(renderable.*, depth, num_renderables) catch |e| {
                logger.warn("failed to import texture {t}, skipping window", .{e});
                continue;
            };

            const window_border = geometry.WindowBorder.fromRenderable(renderable.*);

            var close_hovered = false;
            if (!hover_found) {
                if (window_border.contains(cursor_x, cursor_y)) |location| {
                    close_hovered = location == .close;
                    hover_found = true;
                }
            }

            const close_color = if (close_hovered) close_hover_color else close_default_color;
            self.renderSolidQuad(window_border.closeQuad(), close_color, depth, 1, num_renderables);
            self.renderSolidQuad(window_border.titleQuad(), window_border_color, depth, 2, num_renderables);
            self.renderSolidQuad(window_border.windowTrim(), window_border_color, depth, 2, num_renderables);
        }

        self.renderCursor();

        try self.egl_ctx.swapBuffers();
        const front_buf = try self.gbm_ctx.lockFront();
        errdefer self.gbm_ctx.unlock(front_buf);

        try self.compositor_state.requestFrame();
        logger.debug("rendered after {d}ms", .{now.since(self.last_render_time) / std.time.ns_per_ms});

        return front_buf;
    }

    fn renderWindowSurface(self: *Renderer, renderable: CompositorState.Renderable, depth: usize, num_renderables: usize) !void {
        const buffer = renderable.buffer;
        const texture = try importTexture(self.frame_gl_alloc, self.egl_ctx, buffer);

        const transform = quadTransform(.{
            .cx = renderable.cx,
            .cy = renderable.cy,
            .width = @intCast(renderable.buffer.width),
            .height = @intCast(renderable.buffer.height),
        }, self.compositor_state.compositor_res);

        var depth_f: f32 = @floatFromInt(depth);
        depth_f /= @floatFromInt(num_renderables);
        self.image_renderer.renderTextureAtDepth(texture, transform, depth_f);
    }

    fn renderSolidQuad(self: *Renderer, quad: geometry.PixelQuad, color: sphtud.math.Vec3, depth: usize, sub_order: f32, num_renderables: usize) void {
        const transform = quadTransform(quad, self.compositor_state.compositor_res);
        var depth_f: f32 = @floatFromInt(depth);
        const max_sub_order = 10.0;
        std.debug.assert(sub_order < max_sub_order);
        depth_f += sub_order / max_sub_order;
        depth_f /= @floatFromInt(num_renderables);
        self.solid_color_renderer.render(self.fullscreen_quad, .{
            .color = color,
            .transform = transform.inner,
            .depth = depth_f,
        });
    }

    fn renderCursor(self: *Renderer) void {
        // Proof of concept, render the cursor as a black square. A lot of
        // drivers support hardware blitting of a cursor plane, for now I'm
        // happy to just ignore that

        logger.debug("cursor pos: {any}", .{self.compositor_state.cursor_pos});
        const resolution = self.compositor_state.compositor_res;
        const half_width = asf32(resolution.width) / 2;
        const half_height = asf32(resolution.height) / 2;

        const transform = sphtud.math.Transform.translate(
            1.0,
            -1.0,
        ).then(.scale(
            cursor_img.width / half_width / 2,
            cursor_img.height / half_height / 2,
        )).then(.translate(
            -1.0 + self.compositor_state.cursor_pos.x / half_width,
            1.0 - self.compositor_state.cursor_pos.y / half_height,
        ));
        self.image_renderer.renderTextureAtDepth(self.cursor_tex, transform, -1.0);
    }
};

fn pxToNorm(px: i32, axis_size: u32) f32 {
    var clip: f32 = @floatFromInt(px);
    clip /= @floatFromInt(axis_size);
    return clip;
}

fn pxToClip(px: i32, axis_size: u32) f32 {
    const center: i32 = @intCast(axis_size / 2);
    return pxToNorm(px - center, axis_size) * 2.0;
}

fn quadTransform(quad: geometry.PixelQuad, compositor_res: Resolution) sphtud.math.Transform {
    return sphtud.math.Transform.scale(pxToNorm(quad.width, compositor_res.width), -pxToNorm(quad.height, compositor_res.height))
        .then(.translate(pxToClip(quad.cx, compositor_res.width), -pxToClip(quad.cy, compositor_res.height)));
}

fn importTexture(gl_alloc: *sphtud.render.GlAlloc, egl_ctx: *const system_gl.EglContext, buffer: RenderBuffer) !sphtud.render.Texture {
    const egl_image = try egl_ctx.importDmaBuf(buffer);
    defer egl_ctx.freeEglImage(egl_image);

    const texture = sphtud.render.Texture{ .inner = try gl_alloc.genTexture() };

    gl.glBindTexture(gl.GL_TEXTURE_2D, texture.inner);
    gl.glEGLImageTargetTexture2DOES(gl.GL_TEXTURE_2D, egl_image);
    gl.glTexParameteri(gl.GL_TEXTURE_2D, gl.GL_TEXTURE_MIN_FILTER, gl.GL_NEAREST);
    gl.glTexParameteri(gl.GL_TEXTURE_2D, gl.GL_TEXTURE_MAG_FILTER, gl.GL_NEAREST);
    gl.glBindTexture(gl.GL_TEXTURE_2D, 0);

    return texture;
}
