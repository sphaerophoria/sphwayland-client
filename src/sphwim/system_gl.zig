const std = @import("std");
const c = @import("gl_system_bindings");
const rendering = @import("rendering.zig");

pub const GbmContext = struct {
    drm_handle: std.fs.File,
    device: *c.gbm_device,
    surface: *c.gbm_surface,

    pub const Buffer = struct {
        inner: *c.gbm_bo,

        pub fn fd(self: Buffer) !c_int {
            const ret = c.gbm_bo_get_fd(self.inner);
            if (ret < 0) {
                return error.BadF;
            }
            return ret;
        }

        pub fn offset(self: Buffer) u32 {
            return c.gbm_bo_get_offset(self.inner, 0);
        }

        pub fn stride(self: Buffer) u32 {
            return c.gbm_bo_get_stride(self.inner);
        }

        pub fn modifier(self: Buffer) u64 {
            return c.gbm_bo_get_modifier(self.inner);
        }

        pub fn width(self: Buffer) u32 {
            return c.gbm_bo_get_width(self.inner);
        }

        pub fn height(self: Buffer) u32 {
            return c.gbm_bo_get_height(self.inner);
        }

        pub fn format(self: Buffer) u32 {
            return c.gbm_bo_get_format(self.inner);
        }
    };

    const format = c.GBM_FORMAT_XRGB8888;

    pub fn init(
        init_width: u32,
        init_height: u32,
        device_path: []const u8,
    ) !GbmContext {
        const f = try std.fs.openFileAbsolute(device_path, .{ .mode = .read_write });
        errdefer f.close();

        const device = c.gbm_create_device(f.handle) orelse return error.GbmDeviceInit;
        errdefer c.gbm_device_destroy(device);

        var modifiers: u64 = 0;
        const surface = c.gbm_surface_create_with_modifiers2(device, init_width, init_height, format, &modifiers, 1, c.GBM_BO_USE_SCANOUT | c.GBM_BO_USE_RENDERING) orelse return error.GbmSurfaceInit;
        errdefer c.gbm_surface_destroy(surface);

        return .{
            .drm_handle = f,
            .device = device,
            .surface = surface,
        };
    }

    pub fn lockFront(self: *GbmContext) !Buffer {
        const bo = c.gbm_surface_lock_front_buffer(self.surface) orelse return error.LockFailed;
        if (c.gbm_bo_get_plane_count(bo) != 1) return error.Unimplemented;

        return .{ .inner = bo };
    }

    pub fn unlock(self: *GbmContext, buf: Buffer) void {
        c.gbm_surface_release_buffer(self.surface, buf.inner);
    }

    pub fn deinit(self: *GbmContext) void {
        c.gbm_surface_destroy(self.surface);
        c.gbm_device_destroy(self.device);
        self.drm_handle.close();
    }

    pub fn getDevt(self: GbmContext) !u64 {
        const stat = try std.posix.fstat(self.drm_handle.handle);
        return stat.rdev;
    }
};

pub const getProcAddress = c.eglGetProcAddress;

pub const EglContext = struct {
    display: c.EGLDisplay,
    context: c.EGLContext,
    surface: c.EGLSurface,

    pub fn init(alloc: std.mem.Allocator, gbm_context: GbmContext) !EglContext {
        const display = c.eglGetDisplay(gbm_context.device);
        if (display == c.EGL_NO_DISPLAY) {
            return error.NoDisplay;
        }

        if (c.eglInitialize(display, null, null) != c.EGL_TRUE) {
            return error.EglInit;
        }

        if (c.eglBindAPI(c.EGL_OPENGL_API) == c.EGL_FALSE) {
            return error.BindApi;
        }

        const attribs = [_]c.EGLint{
            c.EGL_RENDERABLE_TYPE, c.EGL_OPENGL_BIT,
            c.EGL_SURFACE_TYPE,    c.EGL_WINDOW_BIT,
            c.EGL_RENDERABLE_TYPE, c.EGL_OPENGL_BIT,
            c.EGL_DEPTH_SIZE,      8,
            c.EGL_NONE,
        };

        var num_configs: c_int = 0;
        if (c.eglChooseConfig(display, &attribs, null, 0, &num_configs) != c.EGL_TRUE) {
            return error.GetConfigNum;
        }

        const num_configs_u = std.math.cast(usize, num_configs) orelse return error.InvalidNumConfigs;
        const available_configs = try alloc.alloc(c.EGLConfig, num_configs_u);
        defer alloc.free(available_configs);

        if (c.eglChooseConfig(display, &attribs, available_configs.ptr, num_configs, &num_configs) != c.EGL_TRUE) {
            return error.ChooseConfig;
        }

        var selected_config: ?c.EGLConfig = null;
        for (available_configs) |config| {
            var id: c.EGLint = 0;
            if (c.eglGetConfigAttrib(display, config, c.EGL_NATIVE_VISUAL_ID, &id) != c.EGL_TRUE) {
                continue;
            }
            if (id == GbmContext.format) {
                selected_config = config;
                break;
            }
        }

        const config = selected_config orelse return error.NoConfig;
        const context = c.eglCreateContext(display, config, c.EGL_NO_CONTEXT, null);
        if (context == c.EGL_NO_CONTEXT) {
            return error.CreateContext;
        }

        const surface = c.eglCreateWindowSurface(display, config, @intFromPtr(gbm_context.surface), null);
        if (surface == c.EGL_NO_SURFACE) {
            return error.CreateSurface;
        }

        if (c.eglMakeCurrent(display, surface, surface, context) == 0) {
            const err = c.eglGetError();
            std.log.err("EGL error: {d}\n", .{err});
            return error.UpdateContext;
        }

        return .{
            .display = display,
            .surface = surface,
            .context = context,
        };
    }

    pub fn swapBuffers(self: *const EglContext) !void {
        if (c.eglSwapBuffers(self.display, self.surface) != c.EGL_TRUE) return error.SwapFailed;
    }

    pub fn getWidth(self: *const EglContext) !c.EGLint {
        var ret: c.EGLint = 0;
        if (c.eglQuerySurface(self.display, self.surface, c.EGL_WIDTH, &ret) != c.EGL_TRUE) {
            return error.Query;
        }
        return ret;
    }

    pub fn getHeight(self: *const EglContext) !c.EGLint {
        var ret: c.EGLint = 0;
        if (c.eglQuerySurface(self.display, self.surface, c.EGL_HEIGHT, &ret) != c.EGL_TRUE) {
            return error.Query;
        }
        return ret;
    }

    pub fn deinit(self: *EglContext) void {
        _ = c.eglDestroySurface(self.display, self.surface);
        _ = c.eglDestroyContext(self.display, self.context);
        _ = c.eglTerminate(self.display);
    }

    pub fn importDmaBuf(self: EglContext, buffer: rendering.RenderBuffer) !c.EGLImage {
        const attrib_list: []const c.EGLAttrib = &.{
            c.EGL_WIDTH,                          buffer.width,
            c.EGL_HEIGHT,                         buffer.height,
            c.EGL_LINUX_DRM_FOURCC_EXT,           buffer.format,
            c.EGL_DMA_BUF_PLANE0_FD_EXT,          buffer.buf_fd,
            c.EGL_DMA_BUF_PLANE0_OFFSET_EXT,      buffer.offset,
            c.EGL_DMA_BUF_PLANE0_PITCH_EXT,       buffer.stride,
            c.EGL_DMA_BUF_PLANE0_MODIFIER_LO_EXT, @as(u32, @truncate(buffer.modifiers)),
            c.EGL_DMA_BUF_PLANE0_MODIFIER_HI_EXT, @as(u32, @truncate(buffer.modifiers >> 32)),
            c.EGL_NONE,
        };

        const egl_image = c.eglCreateImage(
            self.display,
            null,
            c.EGL_LINUX_DMA_BUF_EXT,
            null,
            attrib_list.ptr,
        );

        if (egl_image == c.EGL_NO_IMAGE) {
            return error.ImportFailed;
        }

        return egl_image;
    }

    pub fn freeEglImage(self: EglContext, image: c.EGLImage) void {
        _ = c.eglDestroyImage(self.display, image);
    }
};
