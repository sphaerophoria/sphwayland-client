const std = @import("std");
const builtin = @import("builtin");
const Allocator = std.mem.Allocator;
const sphwayland = @import("sphwayland");
const wlb = @import("wl_bindings");
const ModelRenderer = @import("ModelRenderer.zig");
const gl_helpers = @import("gl_helpers.zig");
const gl = @import("gl");

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
    dmabuf: wlb.ZwpLinuxDmabufV1,
    wl_surface: wlb.WlSurface,
    xdg_surface: wlb.XdgSurface,
    client: *sphwayland.Client(wlb),
    frame_callback: wlb.WlCallback,
    model_renderer: ModelRenderer,

    egl_ctx: gl_helpers.EglContext,
    gbm_ctx: gl_helpers.GbmContext,
    compositor_owned_buffers: std.AutoHashMap(u32, gl_helpers.GbmContext.Buffer),

    pub fn init(alloc: Allocator, egl_ctx: gl_helpers.EglContext, gbm_ctx: gl_helpers.GbmContext, client: *sphwayland.Client(wlb), bound_interfaces: BoundInterfaces) !App {
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
            .dmabuf = bound_interfaces.dmabuf,
            .xdg_surface = xdg_surface,
            .frame_callback = frame_callback,
            .client = client,
            .model_renderer = model_renderer,
            .egl_ctx = egl_ctx,
            .gbm_ctx = gbm_ctx,
            .compositor_owned_buffers = .init(alloc),
        };
    }

    fn deinit(self: *App) void {
        self.compositor_owned_buffers.deinit();
        self.model_renderer.deinit();
    }

    fn addBufferObjectToBufParams(
        self: *App,
        alloc: std.mem.Allocator,
        front_buf: gl_helpers.GbmContext.Buffer,
        params: wlb.ZwpLinuxBufferParamsV1,
    ) !void {
        var add_writer = std.Io.Writer.Allocating.init(alloc);
        defer add_writer.deinit();

        const modifier = front_buf.modifier();
        try params.add(&add_writer.writer, .{
            // Out of band
            .fd = {},
            .plane_idx = 0, // assumed single plane
            .offset = front_buf.offset(),
            .stride = front_buf.stride(),
            .modifier_hi = @truncate(modifier >> 32),
            .modifier_lo = @truncate(modifier),
        });


        const buf_fd = front_buf.fd();
        try sphwayland.sendMessageWithFdAttachment(
            alloc,
            self.client.stream,
            add_writer.written(),
            @bitCast(buf_fd),
        );
    }

    fn render(self: *App, alloc: Allocator) !void {
        gl.glViewport(
            0, 0,
            try self.egl_ctx.getWidth(),
            try self.egl_ctx.getHeight(),
        );

        gl.glClearColor(0.4, 0.4, 0.4, 1.0);
        gl.glClearDepth(1.0);
        gl.glClear(gl.GL_COLOR_BUFFER_BIT | gl.GL_DEPTH_BUFFER_BIT);

        self.model_renderer.rotate(0.01, 0.001);
        self.model_renderer.render(1.0);

        try self.egl_ctx.swapBuffers();

        const front_buf = try self.gbm_ctx.lockFront();

        // front buffer is owned by us until it is committed to a
        // wl_surface, then it is owned by the compositor
        errdefer self.gbm_ctx.unlock(front_buf);

        const params = try self.client.newId(wlb.ZwpLinuxBufferParamsV1);
        try self.dmabuf.createParams(self.client.writer(), .{
            .params_id = params.id,
        });

        try self.addBufferObjectToBufParams(alloc, front_buf, params);

        const wl_buf = try self.client.newId(wlb.WlBuffer);
        try params.createImmed(self.client.writer(), .{
            .buffer_id = wl_buf.id,
            .width = std.math.cast(i32, front_buf.width()) orelse return error.InvalidWidth,
            .height = std.math.cast(i32, front_buf.height()) orelse return error.InvalidHeight,
            .format = front_buf.format(),
            .flags = 0,
        });


        try self.wl_surface.attach(self.client.writer(), .{
            .buffer = wl_buf.id,
            .x = 0,
            .y = 0,
        });

        try self.wl_surface.damageBuffer(self.client.writer(), .{
            .x = 0,
            .y = 0,
            .width = std.math.maxInt(i32),
            .height = std.math.maxInt(i32),
        });

        try self.compositor_owned_buffers.put(wl_buf.id, front_buf);
        errdefer _ = self.compositor_owned_buffers.remove(wl_buf.id);

        try self.wl_surface.commit(self.client.writer(), .{});

        // Commit has to be the last call in this scope, or a bunch of
        // errdefers will be incorrect
    }

    fn handleEvent(self: *App, alloc: Allocator, event: sphwayland.Event(wlb)) !bool {
        switch (event.event) {
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

                try self.render(alloc);
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
                try self.render(alloc);

            },
            .wl_buffer => |parsed| {
                switch (parsed) {
                    .release => blk: {
                        const gbm_handle = self.compositor_owned_buffers.get(event.object_id) orelse {
                            std.log.err("Got release event for unknown buffer", .{});
                            break :blk;
                        };
                        self.gbm_ctx.unlock(gbm_handle);
                    },

                }
            },
            else => sphwayland.logUnusedEvent(event.event),
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

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();

    const alloc = gpa.allocator();

    var client = try sphwayland.Client(wlb).init(alloc);
    defer client.deinit();

    const bound_interfaces = try bindInterfaces(&client);

    var gbm_context = try gl_helpers.GbmContext.init(640, 480);
    defer gbm_context.deinit();

    var egl_context = try gl_helpers.EglContext.init(alloc, gbm_context);
    defer egl_context.deinit();

    gl_helpers.initializeGlParams();

    var app = try App.init(alloc, egl_context, gbm_context, &client, bound_interfaces);
    defer app.deinit();
    var it = client.eventIt();

    while (true) {
        const event = try it.getEventBlocking();
        const close = try app.handleEvent(alloc, event);
        if (close) return;
    }
}
