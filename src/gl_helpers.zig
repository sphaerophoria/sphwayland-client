const std = @import("std");
const gl = @import("gl");
const gbm = @import("gbm");

pub const GbmContext = struct {
    drm_handle: std.fs.File,
    device: *gbm.gbm_device,
    surface: *gbm.gbm_surface,

    pub const Buffer = struct {
        inner: *gbm.gbm_bo,

        pub fn fd(self: Buffer) c_int {
            return gbm.gbm_bo_get_fd(self.inner);
        }

        pub fn offset(self: Buffer) u32 {
            return gbm.gbm_bo_get_offset(self.inner, 0);
        }

        pub fn stride(self: Buffer) u32 {
            return gbm.gbm_bo_get_stride(self.inner);
        }

        pub fn modifier(self: Buffer) u64 {
            return gbm.gbm_bo_get_modifier(self.inner);
        }

        pub fn width(self: Buffer) u32 {
            return gbm.gbm_bo_get_width(self.inner);
        }

        pub fn height(self: Buffer) u32 {
            return gbm.gbm_bo_get_height(self.inner);
        }

        pub fn format(self: Buffer) u32 {
            return gbm.gbm_bo_get_format(self.inner);
        }

    };

    const format = gbm.GBM_FORMAT_ARGB8888;

    pub fn init(init_width: u32, init_height: u32,) !GbmContext {
        // Would be nice if user could choose
        const device_path = "/dev/dri/card0";

        const f = try std.fs.openFileAbsolute(device_path, .{ .mode = .read_write });
        errdefer f.close();

        const device = gbm.gbm_create_device(f.handle) orelse return error.GbmDeviceInit;
        errdefer gbm.gbm_device_destroy(device);

        var modifiers: u64 = 0;
        const surface = gbm.gbm_surface_create_with_modifiers2(
            device,
            init_width,
            init_height,
            format,
            &modifiers,
            1,
            gbm.GBM_BO_USE_SCANOUT | gbm.GBM_BO_USE_RENDERING
        ) orelse return error.GbmSurfaceInit;
        errdefer gbm.gbm_surface_destroy(surface);

        return .{
            .drm_handle = f,
            .device = device,
            .surface = surface,
        };
    }

    pub fn lockFront(self: *GbmContext) !Buffer {
        const bo = gbm.gbm_surface_lock_front_buffer(self.surface) orelse return error.LockFailed;
        if (gbm.gbm_bo_get_plane_count(bo) != 1) return error.Unimplemented;

        return .{ .inner = bo };
    }

    pub fn unlock(self: *GbmContext, buf: Buffer) void {
        gbm.gbm_surface_release_buffer(self.surface, buf.inner);
    }

    pub fn deinit(self: *GbmContext) void {
        gbm.gbm_surface_destroy(self.surface);
        gbm.gbm_device_destroy(self.device);
        self.drm_handle.close();
    }
};

pub const EglContext = struct {
    display: gl.EGLDisplay,
    context: gl.EGLContext,
    surface: gl.EGLSurface,

    pub fn init(alloc: std.mem.Allocator, gbm_context: GbmContext) !EglContext {
        const display = gl.eglGetDisplay(gbm_context.device);
        if (display == gl.EGL_NO_DISPLAY) {
            return error.NoDisplay;
        }

        if (gl.eglInitialize(display, null, null) != gl.EGL_TRUE) {
            return error.EglInit;
        }

        if (gl.eglBindAPI(gl.EGL_OPENGL_API) == gl.EGL_FALSE) {
            return error.BindApi;
        }

        const attribs = [_]gl.EGLint{
            gl.EGL_RENDERABLE_TYPE, gl.EGL_OPENGL_BIT,
            gl.EGL_SURFACE_TYPE, gl.EGL_WINDOW_BIT,
            gl.EGL_RENDERABLE_TYPE, gl.EGL_OPENGL_BIT,
            gl.EGL_DEPTH_SIZE, 8,
            gl.EGL_NONE,
        };

        var num_configs: c_int = 0;
        if (gl.eglChooseConfig(display, &attribs, null, 0, &num_configs) != gl.EGL_TRUE) {
            return error.GetConfigNum;
        }

        const num_configs_u = std.math.cast(usize, num_configs) orelse return error.InvalidNumConfigs;
        const available_configs = try alloc.alloc(gl.EGLConfig, num_configs_u);
        defer alloc.free(available_configs);


        if (gl.eglChooseConfig(display, &attribs, available_configs.ptr, num_configs, &num_configs) != gl.EGL_TRUE) {
            return error.ChooseConfig;
        }

        var selected_config: ?gl.EGLConfig = null;
        for (available_configs) |config| {
            var id: gl.EGLint = 0;
            if (gl.eglGetConfigAttrib(display, config, gl.EGL_NATIVE_VISUAL_ID, &id) != gl.EGL_TRUE) {
                continue;
            }
            if (id == GbmContext.format) {
                selected_config = config;
                break;
            }
        }

        const config = selected_config orelse return error.NoConfig;
        const context = gl.eglCreateContext(display, config, gl.EGL_NO_CONTEXT, null);
        if (context == gl.EGL_NO_CONTEXT) {
            return error.CreateContext;
        }

        const surface = gl.eglCreateWindowSurface(display, config, @intFromPtr(gbm_context.surface), null);
        if (surface == gl.EGL_NO_SURFACE) {
            return error.CreateSurface;
        }

        if (gl.eglMakeCurrent(display, surface, surface, context) == 0) {
            const err = gl.eglGetError();
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
        if (gl.eglSwapBuffers(self.display, self.surface) != gl.EGL_TRUE) return error.SwapFailed;
    }


    pub fn getWidth(self: *const EglContext) !gl.EGLint {
        var ret: gl.EGLint = 0;
        if (gl.eglQuerySurface(self.display, self.surface, gl.EGL_WIDTH, &ret) != gl.EGL_TRUE) {
            return error.Query;
        }
        return ret;
    }

    pub fn getHeight(self: *const EglContext) !gl.EGLint {
        var ret: gl.EGLint = 0;
        if (gl.eglQuerySurface(self.display, self.surface, gl.EGL_HEIGHT, &ret) != gl.EGL_TRUE) {
            return error.Query;
        }
        return ret;
    }

    pub fn deinit(self: *EglContext) void {
        _ = gl.eglDestroySurface(self.display, self.surface);
        _ = gl.eglDestroyContext(self.display, self.context);
        _ = gl.eglTerminate(self.display);
    }
};

fn debugCallback(_: gl.GLenum, _: gl.GLenum, _: gl.GLuint, _: gl.GLenum, length: gl.GLsizei, message: [*c]const gl.GLchar, _: ?*const anyopaque) callconv(.c) void {
    std.log.debug("GL: {s}\n", .{message[0..@intCast(length)]});
}

pub fn initializeGlParams() void {
    gl.glEnable(gl.GL_DEBUG_OUTPUT);
    gl.glDebugMessageCallback(debugCallback, null);
    gl.glEnable(gl.GL_DEPTH_TEST);
    gl.glDepthFunc(gl.GL_LESS);
}
