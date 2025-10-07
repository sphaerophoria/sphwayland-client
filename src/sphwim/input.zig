const std = @import("std");
const sphtud = @import("sphtud");
const CompositorState = @import("CompositorState.zig");
const system = @import("input");

const input_logger = std.log.scoped(.input);

const InputBackend = struct {
    ctx: ?*anyopaque,
    fd: std.posix.fd_t,
    vtable: *const VTable,

    const VTable = struct {
        service: *const fn (ctx: ?*anyopaque, fd: std.posix.fd_t, compositor_state: *CompositorState) anyerror!void,
        close: *const fn (ctx: ?*anyopaque, fd: std.posix.fd_t) void,
    };

    fn service(self: InputBackend, compositor_state: *CompositorState) !void {
        return self.vtable.service(self.ctx, self.fd, compositor_state);
    }

    fn close(self: InputBackend) void {
        return self.vtable.close(self.ctx, self.fd);
    }
};

const LibInputHandler = struct {
    udev_ctx: *system.udev,
    input_ctx: *system.libinput,

    const libinput_interface = system.libinput_interface{
        .open_restricted = openFile,
        .close_restricted = closeFile,
    };

    fn init(alloc: std.mem.Allocator) !InputBackend {
        const udev_ctx = system.udev_new() orelse return error.UdevInit;

        const input_ctx = system.libinput_udev_create_context(&libinput_interface, null, udev_ctx) orelse return error.CreateContext;

        const seat_name = std.posix.getenv("XDG_SEAT") orelse return error.NoSeat;
        if (system.libinput_udev_assign_seat(input_ctx, seat_name) != 0) {
            return error.AssignSeat;
        }

        const ret = try alloc.create(LibInputHandler);
        ret.* = .{
            .udev_ctx = udev_ctx,
            .input_ctx = input_ctx,
        };

        return .{
            .ctx = ret,
            .fd = system.libinput_get_fd(input_ctx),
            .vtable = &.{
                .service = service,
                .close = close,
            },
        };
    }

    fn openFile(path: [*c]const u8, flags: c_int, _: ?*anyopaque) callconv(.c) c_int {
        return std.posix.system.open(path, @bitCast(flags));
    }

    fn closeFile(fd: c_int, _: ?*anyopaque) callconv(.c) void {
        std.posix.close(fd);
    }

    fn service(ctx: ?*anyopaque, _: std.posix.fd_t, compositor_state: *CompositorState) anyerror!void {
        const self: *LibInputHandler = @ptrCast(@alignCast(ctx));

        if (system.libinput_dispatch(self.input_ctx) != 0) {
            return error.InputError;
        }

        while (true) {
            const next_event_opt = system.libinput_get_event(self.input_ctx);
            const next_event = next_event_opt orelse break;
            defer system.libinput_event_destroy(next_event);

            const next_event_type = system.libinput_event_get_type(next_event);

            switch (next_event_type) {
                system.LIBINPUT_EVENT_POINTER_MOTION => {
                    const pointer_event = system.libinput_event_get_pointer_event(next_event);
                    const dx = system.libinput_event_pointer_get_dx(pointer_event);
                    const dy = system.libinput_event_pointer_get_dy(pointer_event);
                    compositor_state.notifyCursorMovement(@floatCast(dx), @floatCast(dy));
                },
                system.LIBINPUT_EVENT_POINTER_MOTION_ABSOLUTE => {
                    const pointer_event = system.libinput_event_get_pointer_event(next_event);

                    const x = system.libinput_event_pointer_get_absolute_x_transformed(
                        pointer_event,
                        compositor_state.compositor_res.width,
                    );

                    const y = system.libinput_event_pointer_get_absolute_y_transformed(
                        pointer_event,
                        compositor_state.compositor_res.height,
                    );

                    compositor_state.notifyCursorPosition(@floatCast(x), @floatCast(y));
                },
                else => {
                    input_logger.debug("unhandled input event for {d}", .{next_event_type});
                },
            }
        }
    }

    fn close(ctx: ?*anyopaque, _: std.posix.fd_t) void {
        const self: *LibInputHandler = @ptrCast(@alignCast(ctx));
        _ = system.libinput_unref(self.input_ctx);
        _ = system.udev_unref(self.udev_ctx);
    }
};

pub const InputHandler = struct {
    backend: InputBackend,
    compositor_state: *CompositorState,

    pub fn handler(self: *InputHandler) sphtud.event.Handler {
        return .{
            .fd = self.backend.fd,
            .ptr = self,
            .vtable = &.{
                .poll = poll,
                .close = close,
            },
        };
    }

    fn poll(ctx: ?*anyopaque, _: *sphtud.event.Loop, _: sphtud.event.PollReason) sphtud.event.PollResult {
        const self: *InputHandler = @ptrCast(@alignCast(ctx));
        self.backend.service(self.compositor_state) catch {
            input_logger.err("failed to service input backend, shutting down", .{});
            return .complete;
        };
        return .in_progress;
    }

    fn close(ctx: ?*anyopaque) void {
        const self: *InputHandler = @ptrCast(@alignCast(ctx));
        self.backend.close();
    }
};

pub fn initializeBackend(alloc: std.mem.Allocator) !InputBackend {
    return try LibInputHandler.init(alloc);
}
