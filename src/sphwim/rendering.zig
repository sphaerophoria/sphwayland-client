const std = @import("std");
const sphtud = @import("sphtud");
const wayland = @import("wayland.zig");
const FdPool = @import("FdPool.zig");
const CompositorState = @import("CompositorState.zig");
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

pub const Renderer = struct {
    frame_gl_alloc: *sphtud.render.GlAlloc,

    egl_ctx: *system_gl.EglContext,
    gbm_ctx: *system_gl.GbmContext,

    compositor_state: *CompositorState,
    image_renderer: sphtud.render.xyuvt_program.ImageRenderer,

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
    ) !Renderer {
        const cp = scratch.checkpoint();
        defer scratch.restore(cp);

        const rgba_data = try cursor_img.makeRgba(scratch.allocator());
        const cursor_tex = try sphtud.render.makeTextureFromRgba(
            gl_alloc,
            rgba_data,
            cursor_img.width,
        );

        return .{
            .frame_gl_alloc = try gl_alloc.makeSubAlloc(alloc),
            .last_render_time = try std.time.Instant.now(),
            .compositor_state = compositor_state,
            .egl_ctx = egl_ctx,
            .gbm_ctx = gbm_ctx,
            .render_in_progress = false,
            .image_renderer = image_renderer,
            .backend_rendering_buf = null,
            .cursor_tex = cursor_tex,
        };
    }

    pub fn releaseBuffer(self: *Renderer, buf: system_gl.GbmContext.Buffer) void {
        self.gbm_ctx.unlock(buf);
    }

    pub fn render(self: *Renderer) !?system_gl.GbmContext.Buffer {
        const now = try std.time.Instant.now();
        defer self.last_render_time = now;

        const delta_ns = now.since(self.last_render_time);
        const delta = @as(f32, @floatFromInt(delta_ns)) / std.time.ns_per_s;

        const background_red = @abs(self.background_animation_state - 1.0);
        gl.glClearColor(background_red, 0.0, 0.0, 1.0);
        gl.glClear(gl.GL_COLOR_BUFFER_BIT);
        self.background_animation_state = @mod(self.background_animation_state + delta / 4.0, 2.0);

        const renderables = &self.compositor_state.renderables;

        defer self.frame_gl_alloc.reset();

        var renderable_it = renderables.storage.iter();
        while (renderable_it.next()) |item| {
            const buffer = item.val.buffer;
            const texture = importTexture(self.frame_gl_alloc, self.egl_ctx, buffer) catch |e| {
                logger.warn("failed to import texture {t}, skipping window", .{e});
                continue;
            };

            // HACK: If we read the DRM file descriptor directly into DRM
            // scanout it is the right way up on our screen. When we import as
            // a texture it's upside down according to glReadPixels (first
            // pixel read is top left of image). Just flip the image in our
            // transform for now
            const transform = sphtud.math.Transform.scale(0.5, -0.5);
            self.image_renderer.renderTexture(texture, transform);
        }

        self.renderCursor();

        try self.egl_ctx.swapBuffers();
        const front_buf = try self.gbm_ctx.lockFront();
        errdefer self.gbm_ctx.unlock(front_buf);

        try self.compositor_state.requestFrame();
        logger.debug("rendered after {d}ms", .{now.since(self.last_render_time) / std.time.ns_per_ms});

        return front_buf;
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
        self.image_renderer.renderTexture(self.cursor_tex, transform);
    }
};

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
