const std = @import("std");
const gl = @import("gl.zig");

pub const EglContext = struct {
    display: gl.EGLDisplay,
    context: gl.EGLContext,

    pub fn init() !EglContext {
        const display = gl.eglGetDisplay(gl.EGL_DEFAULT_DISPLAY);
        if (display == gl.EGL_NO_DISPLAY) {
            return error.NoDisplay;
        }

        if (gl.eglInitialize(display, null, null) != gl.EGL_TRUE) {
            return error.EglInit;
        }

        if (gl.eglBindAPI(gl.EGL_OPENGL_API) == gl.EGL_FALSE) {
            return error.BindApi;
        }

        var config: gl.EGLConfig = undefined;
        const attribs = [_]gl.EGLint{ gl.EGL_RENDERABLE_TYPE, gl.EGL_OPENGL_BIT, gl.EGL_NONE };

        var num_configs: c_int = 0;
        if (gl.eglChooseConfig(display, &attribs, &config, 1, &num_configs) != gl.EGL_TRUE) {
            return error.ChooseConfig;
        }

        const context = gl.eglCreateContext(display, config, gl.EGL_NO_CONTEXT, null);
        if (context == gl.EGL_NO_CONTEXT) {
            return error.CreateContext;
        }

        if (gl.eglMakeCurrent(display, gl.EGL_NO_SURFACE, gl.EGL_NO_SURFACE, context) == 0) {
            return error.UpdateContext;
        }

        return .{
            .display = display,
            .context = context,
        };
    }

    pub fn deinit(self: *EglContext) void {
        _ = gl.eglDestroyContext(self.display, self.context);
        _ = gl.eglTerminate(self.display);
    }
};

fn debugCallback(_: gl.GLenum, _: gl.GLenum, _: gl.GLuint, _: gl.GLenum, length: gl.GLsizei, message: [*c]const gl.GLchar, _: ?*const anyopaque) callconv(.C) void {
    std.log.debug("GL: {s}\n", .{message[0..@intCast(length)]});
}

pub fn initializeGlParams() void {
    gl.glEnable(gl.GL_DEBUG_OUTPUT);
    gl.glDebugMessageCallback(debugCallback, null);
    gl.glEnable(gl.GL_DEPTH_TEST);
    gl.glDepthFunc(gl.GL_LESS);
}

pub fn makeTextureDefaultParams() gl.GLuint {
    var texture: gl.GLuint = undefined;
    gl.glGenTextures(1, &texture);
    gl.glBindTexture(gl.GL_TEXTURE_2D, texture);
    gl.glTexParameteri(gl.GL_TEXTURE_2D, gl.GL_TEXTURE_MIN_FILTER, gl.GL_LINEAR);
    gl.glTexParameteri(gl.GL_TEXTURE_2D, gl.GL_TEXTURE_MAG_FILTER, gl.GL_LINEAR);
    gl.glTexParameteri(gl.GL_TEXTURE_2D, gl.GL_TEXTURE_WRAP_S, gl.GL_CLAMP_TO_EDGE);
    gl.glTexParameteri(gl.GL_TEXTURE_2D, gl.GL_TEXTURE_WRAP_T, gl.GL_CLAMP_TO_EDGE);

    return texture;
}

pub const FrameBuffer = struct {
    fbo: gl.GLuint,
    color: gl.GLuint,
    depth: gl.GLuint,

    pub fn deinit(self: *FrameBuffer) void {
        gl.glDeleteFramebuffers(1, &self.fbo);
        gl.glDeleteTextures(1, &self.color);
        gl.glDeleteTextures(1, &self.depth);
    }
};

pub fn makeFarmeBuffer(width: u31, height: u31) FrameBuffer {
    const color = makeTextureDefaultParams();
    gl.glTexImage2D(
        gl.GL_TEXTURE_2D,
        0,
        gl.GL_RGBA,
        width,
        height,
        0,
        gl.GL_RGBA,
        gl.GL_UNSIGNED_BYTE,
        null,
    );

    const depth = makeTextureDefaultParams();
    // FIXME: Renderbuffer?
    gl.glTexImage2D(
        gl.GL_TEXTURE_2D,
        0,
        gl.GL_DEPTH24_STENCIL8,
        width,
        height,
        0,
        gl.GL_DEPTH_STENCIL,
        gl.GL_UNSIGNED_INT_24_8,
        null,
    );

    var fbo: gl.GLuint = undefined;
    gl.glGenFramebuffers(1, &fbo);

    gl.glBindFramebuffer(gl.GL_FRAMEBUFFER, fbo);
    gl.glFramebufferTexture2D(
        gl.GL_FRAMEBUFFER,
        gl.GL_COLOR_ATTACHMENT0,
        gl.GL_TEXTURE_2D,
        color,
        0,
    );
    gl.glFramebufferTexture2D(
        gl.GL_FRAMEBUFFER,
        gl.GL_DEPTH_STENCIL_ATTACHMENT,
        gl.GL_TEXTURE_2D,
        depth,
        0,
    );

    return .{
        .fbo = fbo,
        .color = color,
        .depth = depth,
    };
}

const TextureFd = struct {
    fd: c_int,
    fourcc: c_int,
    modifiers: u64,
    stride: c_int,
    offset: c_int,
};

pub fn makeTextureFileDescriptor(texture: gl.GLuint, display: gl.EGLDisplay, context: gl.EGLContext) TextureFd {
    var ret: TextureFd = undefined;

    const eglCreateImageKHR: gl.PFNEGLCREATEIMAGEKHRPROC = @ptrCast(gl.eglGetProcAddress("eglCreateImageKHR"));
    const eglExportDMABUFImageQueryMESA: gl.PFNEGLEXPORTDMABUFIMAGEQUERYMESAPROC = @ptrCast(gl.eglGetProcAddress("eglExportDMABUFImageQueryMESA"));
    const eglExportDMABUFImageMESA: gl.PFNEGLEXPORTDMABUFIMAGEMESAPROC = @ptrCast(gl.eglGetProcAddress("eglExportDMABUFImageMESA"));

    const tex_u64: u64 = texture;
    const image = eglCreateImageKHR.?(display, context, gl.EGL_GL_TEXTURE_2D, @ptrFromInt(tex_u64), null);

    // Workaround for radeon driver bug, texture is turned black without it
    gl.glFlush();

    var num_planes: c_int = undefined;
    var success = eglExportDMABUFImageQueryMESA.?(display, image, &ret.fourcc, &num_planes, &ret.modifiers);
    // FIXME: fail if not success
    std.debug.assert(num_planes == 1);

    // This is fine because there is only 1 plane (i think)
    success = eglExportDMABUFImageMESA.?(display, image, &ret.fd, &ret.stride, &ret.offset);

    return ret;
}
