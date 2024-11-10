const std = @import("std");
const builtin = @import("builtin");
const Allocator = std.mem.Allocator;
const sphwayland = @import("sphwayland");
const wlb = @import("wl_bindings");
const ModelRenderer = @import("ModelRenderer.zig");
const gl_helpers = @import("gl_helpers.zig");
const gl = @import("gl.zig");

pub const std_options = std.Options{
    .log_level = .warn,
};

const BoundInterfaces = struct {
    compositor: wlb.WlCompositor,
    xdg_wm_base: wlb.XdgWmBase,
    decoration_manager: wlb.ZxdgDecorationManagerV1,
    dmabuf: wlb.ZwpLinuxDmabufV1,
};

fn bindInterfaces(client: *sphwayland.Client(wlb)) !BoundInterfaces {
    var it = client.eventIt();
    try it.retrieveEvents();

    var compositor: ?wlb.WlCompositor = null;
    var xdg_wm_base: ?wlb.XdgWmBase = null;
    var decoration_manager: ?wlb.ZxdgDecorationManagerV1 = null;
    var dmabuf: ?wlb.ZwpLinuxDmabufV1 = null;

    while (try it.getAvailableEvent()) |event| {
        switch (event.event) {
            .wl_display => |parsed| {
                switch (parsed) {
                    .err => |err| sphwayland.logWaylandErr(err),
                    .delete_id => {
                        std.log.warn("Unexpected delete object in binding stage", .{});
                    },
                }
            },
            .wl_registry => |action| {
                switch (action) {
                    .global => |g| blk: {
                        const DesiredInterfaces = enum {
                            wl_compositor,
                            xdg_wm_base,
                            zxdg_decoration_manager_v1,
                            zwp_linux_dmabuf_v1,
                        };

                        const interface_name = std.meta.stringToEnum(DesiredInterfaces, g.interface) orelse {
                            std.log.debug("Unused interface {s}", .{g.interface});
                            break :blk;
                        };

                        switch (interface_name) {
                            .wl_compositor => compositor = try client.bind(wlb.WlCompositor, g),
                            .xdg_wm_base => xdg_wm_base = try client.bind(wlb.XdgWmBase, g),
                            .zxdg_decoration_manager_v1 => decoration_manager = try client.bind(wlb.ZxdgDecorationManagerV1, g),
                            .zwp_linux_dmabuf_v1 => dmabuf = try client.bind(wlb.ZwpLinuxDmabufV1, g),
                        }
                    },
                    .global_remove => {
                        std.log.warn("No registry to remove from", .{});
                    },
                }
            },
            else => sphwayland.logUnusedEvent(event.event),
        }
    }

    return .{
        .compositor = compositor orelse return error.NoCompositor,
        .xdg_wm_base = xdg_wm_base orelse return error.NoXdgWmBase,
        .decoration_manager = decoration_manager orelse return error.DecorationManager,
        .dmabuf = dmabuf orelse return error.NoDmaBuf,
    };
}

const App = struct {
    compositor: wlb.WlCompositor,
    xdg_wm_base: wlb.XdgWmBase,
    wl_surface: wlb.WlSurface,
    xdg_surface: wlb.XdgSurface,
    client: *sphwayland.Client(wlb),
    frame_callback: wlb.WlCallback,
    gl_buffers: *GlBuffers,
    model_renderer: ModelRenderer,

    pub fn init(alloc: Allocator, client: *sphwayland.Client(wlb), gl_buffers: *GlBuffers, bound_interfaces: BoundInterfaces) !App {
        std.log.debug("Initializing app", .{});
        const writer = client.writer();

        const wl_surface = try client.newId(wlb.WlSurface);
        try bound_interfaces.compositor.createSurface(writer, .{
            .id = wl_surface.id,
        });

        const xdg_surface = try client.newId(wlb.XdgSurface);
        try bound_interfaces.xdg_wm_base.getXdgSurface(writer, .{
            .id = xdg_surface.id,
            .surface = wl_surface.id,
        });

        const toplevel = try client.newId(wlb.XdgToplevel);
        try xdg_surface.getToplevel(writer, .{ .id = toplevel.id });
        try toplevel.setAppId(writer, .{ .app_id = "sphwayland-client" });
        try toplevel.setTitle(writer, .{ .title = "sphwayland client" });

        const toplevel_decoration = try client.newId(wlb.ZxdgToplevelDecorationV1);
        try bound_interfaces.decoration_manager.getToplevelDecoration(writer, .{
            .id = toplevel_decoration.id,
            .toplevel = toplevel.id,
        });

        try wl_surface.attach(writer, .{
            .buffer = gl_buffers.getActiveWlBuffer().id,
            .x = 0,
            .y = 0,
        });
        gl_buffers.swap();

        try wl_surface.commit(writer, .{});

        const frame_callback = try client.newId(wlb.WlCallback);
        try wl_surface.frame(writer, .{
            .callback = frame_callback.id,
        });

        const model_renderer = try ModelRenderer.init(alloc);
        return .{
            .compositor = bound_interfaces.compositor,
            .xdg_wm_base = bound_interfaces.xdg_wm_base,
            .wl_surface = wl_surface,
            .xdg_surface = xdg_surface,
            .frame_callback = frame_callback,
            .client = client,
            .gl_buffers = gl_buffers,
            .model_renderer = model_renderer,
        };
    }

    fn deinit(self: *App) void {
        self.model_renderer.deinit();
    }

    fn handleEvent(self: *App, event: wlb.WaylandEvent) !bool {
        switch (event) {
            .wl_display => |parsed| {
                switch (parsed) {
                    .err => |err| sphwayland.logWaylandErr(err),
                    .delete_id => |req| {
                        if (req.id == self.frame_callback.id) {
                            try self.wl_surface.frame(self.client.writer(), .{ .callback = self.frame_callback.id });
                            try self.wl_surface.commit(self.client.writer(), .{});
                        } else {
                            std.log.warn("Deletion of object {d} is not handled", .{req.id});
                        }
                    },
                }
            },
            .xdg_surface => |parsed| {
                try self.xdg_surface.ackConfigure(self.client.writer(), .{
                    .serial = parsed.configure.serial,
                });
                try self.wl_surface.commit(self.client.writer(), .{});
            },
            .xdg_wm_base => |parsed| {
                try self.xdg_wm_base.pong(self.client.writer(), .{
                    .serial = parsed.ping.serial,
                });
            },
            .xdg_toplevel => |parsed| {
                switch (parsed) {
                    .close => {
                        return true;
                    },
                    else => {
                        std.log.debug("Unhandled toplevel event {any}", .{parsed});
                    },
                }
            },
            .wl_callback => |parsed| {
                //std.debug.assert(self.frame_callback.id == event.header.id);
                std.debug.assert(parsed == .done);

                const fbo = self.gl_buffers.getActiveFramebuffer();
                gl.glBindFramebuffer(gl.GL_FRAMEBUFFER, fbo);
                gl.glViewport(0, 0, GlBuffers.width, GlBuffers.height);

                gl.glClearColor(0.4, 0.4, 0.4, 1.0);
                gl.glClearDepth(1.0);
                gl.glClear(gl.GL_COLOR_BUFFER_BIT | gl.GL_DEPTH_BUFFER_BIT);

                self.model_renderer.rotate(0.01, 0.001);
                self.model_renderer.render(1.0);

                // Unlike in normal opengl, nothing is telling the system that
                // we are actually using this texture. We need to flush the
                // draw calls before asking the compositor to draw our texture
                // for us
                gl.glFlush();

                const wl_buf = self.gl_buffers.getActiveWlBuffer();
                try self.wl_surface.attach(self.client.writer(), .{
                    .buffer = wl_buf.id,
                    .x = 0,
                    .y = 0,
                });
                self.gl_buffers.swap();
                try self.wl_surface.damageBuffer(self.client.writer(), .{
                    .x = 0,
                    .y = 0,
                    .width = std.math.maxInt(i32),
                    .height = std.math.maxInt(i32),
                });
                try self.wl_surface.commit(self.client.writer(), .{});
            },
            else => sphwayland.logUnusedEvent(event),
        }
        return false;
    }
};

const GlBuffers = struct {
    const width = 640;
    const height = 480;

    framebuffers: [2]gl_helpers.FrameBuffer,
    wl_buffers: [2]wlb.WlBuffer,
    idx: u1 = 0,

    fn deinit(self: *GlBuffers) void {
        for (&self.framebuffers) |*fb| {
            fb.deinit();
        }
    }

    fn getActiveFramebuffer(self: *GlBuffers) u32 {
        return self.framebuffers[self.idx].fbo;
    }

    fn getActiveWlBuffer(self: *GlBuffers) *wlb.WlBuffer {
        return &self.wl_buffers[self.idx];
    }

    fn swap(self: *GlBuffers) void {
        self.idx +%= 1;
    }
};

fn waitForZwpLinuxWlBuffer(client: *sphwayland.Client(wlb)) !wlb.WlBuffer {
    var it = client.eventIt();
    while (true) {
        const event = try it.getEventBlocking();
        switch (event.event) {
            .zwp_linux_buffer_params_v1 => |parsed| {
                switch (parsed) {
                    .created => |s| {
                        const ret = wlb.WlBuffer{
                            .id = s.buffer,
                        };

                        try client.registerId(ret.id, .wl_buffer);
                        return ret;
                    },
                    .failed => {
                        return error.CreateDmaBuf;
                    },
                }
                break;
            },
            else => sphwayland.logUnusedEvent(event.event),
        }
    }
}

fn createGlBackedBuffers(
    alloc: Allocator,
    egl_context: gl_helpers.EglContext,
    client: *sphwayland.Client(wlb),
    bound_interfaces: BoundInterfaces,
) !GlBuffers {
    const writer = client.writer();

    var framebuffers: [2]gl_helpers.FrameBuffer = undefined;
    var wl_buffers: [2]wlb.WlBuffer = undefined;

    for (0..2) |idx| {
        const buffer_params = try client.newId(wlb.ZwpLinuxBufferParamsV1);
        try bound_interfaces.dmabuf.createParams(writer, .{
            .params_id = buffer_params.id,
        });

        framebuffers[idx] = gl_helpers.makeFarmeBuffer(GlBuffers.width, GlBuffers.height);

        const zwp_params = gl_helpers.makeTextureFileDescriptor(framebuffers[idx].color, egl_context.display, egl_context.context);

        var to_send = std.ArrayList(u8).init(alloc);
        defer to_send.deinit();
        try buffer_params.add(to_send.writer(), .{
            .fd = {}, // out of band,
            .plane_idx = 0, // assumed single plane
            .offset = @intCast(zwp_params.offset),
            .stride = @intCast(zwp_params.stride),
            .modifier_hi = @intCast(zwp_params.modifiers >> 32),
            .modifier_lo = @truncate(zwp_params.modifiers),
        });

        try sphwayland.sendMessageWithFdAttachment(alloc, client.stream, to_send.items, zwp_params.fd);

        try buffer_params.create(writer, .{
            .width = GlBuffers.width,
            .height = GlBuffers.height,
            .format = @bitCast(zwp_params.fourcc),
            .flags = 1,
        });

        wl_buffers[idx] = try waitForZwpLinuxWlBuffer(client);
    }

    return .{
        .framebuffers = framebuffers,
        .wl_buffers = wl_buffers,
    };
}

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();

    const alloc = gpa.allocator();

    var client = try sphwayland.Client(wlb).init(alloc);
    defer client.deinit();

    const bound_interfaces = try bindInterfaces(&client);

    var egl_context = try gl_helpers.EglContext.init();
    defer egl_context.deinit();
    gl_helpers.initializeGlParams();

    var gl_buffers = try createGlBackedBuffers(alloc, egl_context, &client, bound_interfaces);
    defer gl_buffers.deinit();

    var app = try App.init(alloc, &client, &gl_buffers, bound_interfaces);
    defer app.deinit();
    var it = client.eventIt();

    while (true) {
        const event = try it.getEventBlocking();
        const close = try app.handleEvent(event.event);
        if (close) return;
    }
}
