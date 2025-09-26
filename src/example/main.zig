const std = @import("std");
const builtin = @import("builtin");
const Allocator = std.mem.Allocator;
const sphwindow = @import("sphwindow");
const wlb = @import("wl_bindings");
const ModelRenderer = @import("ModelRenderer.zig");
const gl = @import("gl");

pub const std_options = std.Options{
    .log_level = .warn,
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

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();

    const alloc = gpa.allocator();

    var window = try sphwindow.Window.init(alloc);
    defer window.deinit();

    initializeGlParams();

    var model_renderer = try ModelRenderer.init(alloc);
    defer model_renderer.deinit();


    while (!(try window.service())) {
        if (window.wantsFrame()) {
            const window_size = try window.getSize();
            gl.glViewport(0, 0, window_size.width, window_size.height);

            gl.glClearColor(0.4, 0.4, 0.4, 1.0);
            gl.glClearDepth(1.0);
            gl.glClear(gl.GL_COLOR_BUFFER_BIT | gl.GL_DEPTH_BUFFER_BIT);

            model_renderer.rotate(0.01, 0.001);
            model_renderer.render(1.0);

            try window.swapBuffers(alloc);
        }

        try window.wait();
    }
}
