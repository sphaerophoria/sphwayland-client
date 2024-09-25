pub usingnamespace @cImport({
    @cDefine("GL_GLEXT_PROTOTYPES", "");
    @cInclude("GL/gl.h");
    @cInclude("EGL/egl.h");
    @cInclude("EGL/eglext.h");
});
