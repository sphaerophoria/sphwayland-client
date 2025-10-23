const std = @import("std");
const sphtud = @import("sphtud");
const DrmRenderBackend = @import("rendering/DrmRenderBackend.zig");
const NullRenderBackend = @import("rendering/NullRenderBackend.zig");
const wayland = @import("wayland.zig");
const FdPool = @import("FdPool.zig");
const CompositorState = @import("CompositorState.zig");
const system_gl = @import("system_gl.zig");
const gl = sphtud.render.gl;

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
};

pub const Resolution = struct {
    width: u32,
    height: u32,
};

pub const RenderBackend = struct {
    ctx: ?*anyopaque,
    event_fd: std.posix.fd_t,
    device_path: []const u8,
    vtable: *const VTable,

    const VTable = struct {
        displayBuffer: *const fn (ctx: ?*anyopaque, render_buffer: RenderBuffer, locked_flag: *bool) anyerror!void,
        currentResolution: *const fn (ctx: ?*anyopaque, fd: std.posix.fd_t) anyerror!Resolution,
        service: *const fn (ctx: ?*anyopaque, fd: std.posix.fd_t) anyerror!void,
        deinit: *const fn (ctx: ?*anyopaque, fd: std.posix.fd_t) void,
    };

    pub fn deinit(self: RenderBackend) void {
        self.vtable.deinit(self.ctx, self.event_fd);
    }

    pub fn currentResolution(self: RenderBackend) !Resolution {
        return self.vtable.currentResolution(self.ctx, self.event_fd);
    }

    pub fn displayBuffer(self: RenderBackend, render_buffer: RenderBuffer, locked_flag: *bool) !void {
        try self.vtable.displayBuffer(self.ctx, render_buffer, locked_flag);
    }

    pub fn service(self: RenderBackend) !void {
        try self.vtable.service(self.ctx, self.event_fd);
    }
};

pub fn initRenderBackend(alloc: std.mem.Allocator) !RenderBackend {
    if (DrmRenderBackend.init(alloc)) |backend| {
        return backend;
    } else |e| {
        logger.info("Failed to init drm render backend: {t}", .{e});
    }

    logger.warn("Failed to init render backend, using null backend", .{});
    return try NullRenderBackend.init();
}

fn asf32(in: anytype) f32 {
    return @floatFromInt(in);
}

pub const Renderer = struct {
    frame_gl_alloc: *sphtud.render.GlAlloc,

    egl_ctx: *system_gl.EglContext,
    gbm_ctx: *system_gl.GbmContext,
    render_backend: RenderBackend,

    compositor_state: *CompositorState,
    image_renderer: sphtud.render.xyuvt_program.ImageRenderer,

    last_render_time: std.time.Instant,

    render_in_progress: bool,
    backend_rendering_buf: ?system_gl.GbmContext.Buffer,

    // Eventually we won't need this, but for now it's useful to prove that the
    // compositor is rendering
    background_animation_state: f32 = 1.0,

    const vtable = sphtud.event.LoopSphalloc.Handler.VTable{
        .poll = poll,
        .close = close,
    };

    pub fn handler(self: *Renderer) sphtud.event.LoopSphalloc.Handler {
        return .{
            .ptr = self,
            .fd = self.render_backend.event_fd,
            .desired_events = .{
                .read = true,
                .write = true,
            },
            .vtable = &vtable,
        };
    }

    fn poll(ctx: ?*anyopaque, _: *sphtud.event.LoopSphalloc, reason: sphtud.event.PollReason) sphtud.event.LoopSphalloc.PollResult {
        const self: *Renderer = @ptrCast(@alignCast(ctx));
        self.pollError(reason) catch |e| {
            logger.err("Failed to poll: {t}", .{e});
            return .in_progress;
        };

        return .in_progress;
    }

    fn pollError(self: *Renderer, reason: sphtud.event.PollReason) !void {
        const is_readable = switch (reason) {
            .io => |io_reasons| io_reasons.read,
            .init => false,
        };

        const now = try std.time.Instant.now();
        defer self.last_render_time = now;

        if (reason == .init) {
            try self.renderCompositor(now);
            return;
        }

        if (!is_readable) {
            logger.debug("renderer file not readable, returning early", .{});
            return;
        }

        try self.render_backend.service();

        if (!self.render_in_progress) {
            try self.renderCompositor(now);
        }

        logger.debug("rendered after {d}ms", .{now.since(self.last_render_time) / std.time.ns_per_ms});
    }

    fn close(ctx: ?*anyopaque) void {
        _ = ctx;
    }

    fn renderCompositor(self: *Renderer, now: std.time.Instant) !void {
        if (self.backend_rendering_buf) |buf| {
            self.gbm_ctx.unlock(buf);
            self.backend_rendering_buf = null;
        }

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

        const render_buffer = RenderBuffer{
            .buf_fd = try front_buf.fd(),
            .modifiers = front_buf.modifier(),
            .offset = front_buf.offset(),
            .plane_idx = 0, // HACK, assume plane 0
            .stride = front_buf.stride(),
            .width = @intCast(front_buf.width()),
            .height = @intCast(front_buf.height()),
            .format = front_buf.format(),
        };
        defer std.posix.close(render_buffer.buf_fd);

        try self.render_backend.displayBuffer(render_buffer, &self.render_in_progress);
        self.backend_rendering_buf = front_buf;

        try self.compositor_state.requestFrame();
        logger.debug("rendered after {d}ms", .{now.since(self.last_render_time) / std.time.ns_per_ms});
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
            20.0 / half_width,
            20.0 / half_height,
        )).then(.translate(
            -1.0 + self.compositor_state.cursor_pos.x / half_width,
            1.0 - self.compositor_state.cursor_pos.y / half_height,
        ));
        self.image_renderer.renderTexture(.invalid, transform);
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
