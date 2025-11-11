const std = @import("std");
const c = @import("c_bindings");

pub const GbmContext = struct {
    drm_handle: std.fs.File,
    device: *c.gbm_device,
    surface: *c.gbm_surface,

    pub const Buffer = struct {
        inner: *c.gbm_bo,

        pub fn fd(self: Buffer) c_int {
            return c.gbm_bo_get_fd(self.inner);
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
        desired_device: []const u8,
    ) !GbmContext {
        // Would be nice if user could choose
        const device_path = desired_device;
        std.debug.print("{s}\n", .{device_path});
        const f = try std.fs.openFileAbsolute(device_path, .{ .mode = .read_write });
        errdefer f.close();

        const device = c.gbm_create_device(f.handle) orelse return error.GbmDeviceInit;
        errdefer c.gbm_device_destroy(device);

        const surface = try makeSurface(device, init_width, init_height);
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

    pub fn updateSurfaceSize(self: *GbmContext, width: u32, height: u32) !void {
        const new_surface = try makeSurface(self.device, width, height);
        c.gbm_surface_destroy(self.surface);
        self.surface = new_surface;
    }

    pub fn deinit(self: *GbmContext) void {
        c.gbm_surface_destroy(self.surface);
        c.gbm_device_destroy(self.device);
        self.drm_handle.close();
    }

    fn makeSurface(device: *c.gbm_device, width: u32, height: u32) !*c.gbm_surface {
        var modifiers: u64 = 0;
        return c.gbm_surface_create_with_modifiers2(device, width, height, format, &modifiers, 1, c.GBM_BO_USE_SCANOUT | c.GBM_BO_USE_RENDERING) orelse return error.GbmSurfaceInit;
    }
};

pub const EglContext = struct {
    display: c.EGLDisplay,
    config: c.EGLConfig,
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

        const surface = c.EGL_NO_SURFACE;
        if (c.eglMakeCurrent(display, surface, surface, context) == 0) {
            const err = c.eglGetError();
            std.log.err("EGL error: {d}\n", .{err});
            return error.UpdateContext;
        }

        var ret = EglContext{
            .display = display,
            .config = config,
            .surface = surface,
            .context = context,
        };
        // FIXME: Factor out a more reasonable fn
        try ret.updateSurface(gbm_context.surface);
        return ret;
    }

    pub fn swapBuffers(self: *const EglContext) !void {
        if (c.eglSwapBuffers(self.display, self.surface) != c.EGL_TRUE) return error.SwapFailed;
    }

    pub fn updateSurface(self: *EglContext, gbm_surface: ?*c.gbm_surface) !void {
        const surface = if (gbm_surface != null) blk: {
            const surface = c.eglCreateWindowSurface(self.display, self.config, @intFromPtr(gbm_surface), null);
            if (surface == c.EGL_NO_SURFACE) {
                return error.CreateEglSurface;
            }
            break :blk surface;
        } else c.EGL_NO_SURFACE;

        const old_surface = self.surface;
        defer if (old_surface != c.EGL_NO_SURFACE) {
            if (c.eglDestroySurface(self.display, old_surface) != c.EGL_TRUE) {
                const err = c.eglGetError();
                std.log.err("EGL error: 0x{x}\n", .{err});
                unreachable;
            }
        };

        self.surface = surface;

        if (c.eglMakeCurrent(self.display, self.surface, self.surface, self.context) == 0) {
            const err = c.eglGetError();
            std.log.err("EGL error: {d}\n", .{err});
            return error.UpdateContext;
        }
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
};
