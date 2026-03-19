const std = @import("std");
const sphtud = @import("sphtud");
const sphdbus = @import("sphdbus");
const service = @import("dbus_service");
const CompositorState = @import("CompositorState.zig");

pub const DbusService = struct {
    stream: std.net.Stream,
    scratch: sphtud.alloc.LinearAllocator,

    reader_buf: [4096]u8,
    stream_reader: std.net.Stream.Reader,

    writer_buf: [4096]u8,
    stream_writer: std.net.Stream.Writer,

    connection: sphdbus.DbusConnection,
    state: *CompositorState,

    pub fn initPinned(self: *DbusService, scratch: sphtud.alloc.LinearAllocator, state: *CompositorState) !void {
        self.stream = try sphdbus.sessionBus();
        self.scratch = scratch;
        try sphtud.event.setNonblock(self.stream.handle);

        self.stream_reader = self.stream.reader(&self.reader_buf);
        self.stream_writer = self.stream.writer(&self.writer_buf);
        self.connection = try sphdbus.dbusConnection(self.stream_reader.interface(), &self.stream_writer.interface);
        self.state = state;
    }

    pub fn handler(self: *DbusService) sphtud.event.Loop.Handler {
        return .{
            .ptr = self,
            .vtable = &.{
                .poll = poll,
                .close = close,
            },
            .fd = self.stream.handle,
            .desired_events = .{
                .read = true,
                .write = false,
            },
        };
    }

    fn poll(ctx: ?*anyopaque, loop: *sphtud.event.Loop, reason: sphtud.event.PollReason) sphtud.event.Loop.PollResult {
        _ = loop;
        _ = reason;

        const self: *DbusService = @ptrCast(@alignCast(ctx));

        self.pollFailable() catch |e| {
            if (e == error.ReadFailed) blk: {
                const source_err = self.stream_reader.getError() orelse break :blk;
                if (source_err == error.WouldBlock) {
                    return .in_progress;
                }
            }

            std.debug.print("uh oh something went wrong {t}\n", .{e});
            if (@errorReturnTrace()) |t| {
                std.debug.print("{f}", .{t});
            }
            return .complete;
        };
        return .in_progress;
    }

    fn pollFailable(self: *DbusService) !void {
        while (true) {
            const res = try self.connection.poll(.{});

            // FIXME: Below code should be factored out and errors should be logged and ignored if possible

            switch (res) {
                .initialized => {
                    std.debug.print("Initializing dbus boy", .{});
                    // FIXME: Log the handle and freak out if the response is not what we expected
                    _ = try self.connection.call(
                        "/org/freedesktop/DBus",
                        "org.freedesktop.DBus",
                        "org.freedesktop.DBus",
                        "RequestName",
                        .{
                            sphdbus.DbusString{ .inner = "dev.sphaerophoria.sphwim" },
                            @as(u32, 0),
                        },
                    );
                },
                .response => |response| {
                    std.debug.print("Got response {any}\n", .{response});
                },
                .none => {},
                .call => |call| blk: {
                    const cp = self.scratch.checkpoint();
                    defer self.scratch.restore(cp);

                    const req = try sphdbus.service.handleMessage(
                        service,
                        self.scratch.allocator(),
                        call,
                        &self.connection,
                    ) orelse break :blk;

                    switch (req) {
                        .@"/dev/sphaerophoria/sphwim" => |service_name| {
                            switch (service_name) {
                                .@"dev.sphaerophoria.sphwim" => |call_params| {
                                    switch (call_params) {
                                        .method => |method| {
                                            switch (method) {
                                                .GetWindowList => |params| {
                                                    // FIXME: There really
                                                    // shouldn't be any
                                                    // parameters here, but we
                                                    // cannot generate bindings
                                                    // without them lololololol
                                                    _ = params;

                                                    var ret = std.ArrayList(sphdbus.DbusKV(u64, sphdbus.DbusString)){};

                                                    var it = self.state.windows.iter();
                                                    while (it.next()) {
                                                        const title = it.item(.title);
                                                        try ret.append(self.scratch.allocator(), .{
                                                            .key = it.item(.stable_handle).inner,
                                                            .val = .{ .inner = title.* },
                                                        });
                                                    }

                                                    try self.connection.ret(
                                                        call.serial,
                                                        call.headers.sender.?.inner,
                                                        ret.items,
                                                    );
                                                },
                                            }
                                        },
                                        .get_property => return error.InvalidCall,
                                        .set_property => return error.InvalidCall,

                                    }
                                },

                            }
                        },

                    }
                },
            }
        }
        return .in_progress;
    }

    fn close(ctx: ?*anyopaque) void {
        _ = ctx;
    }
};
