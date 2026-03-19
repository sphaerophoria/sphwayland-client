const std = @import("std");
const sphtud = @import("sphtud");
const sphdbus = @import("sphdbus");
const service_def = @import("dbus_service");
const CompositorState = @import("CompositorState.zig");

const DbusService = @This();

stream: std.posix.fd_t,
scratch: sphtud.alloc.LinearAllocator,

reader_buf: [4096]u8,
stream_reader: sphtud.io.Reader,

writer_buf: [4096]u8,
stream_writer: sphtud.io.Writer,

connection: sphdbus.DbusConnection,
state: *CompositorState,

pub fn initPinned(self: *DbusService, environ: std.process.Environ, scratch: sphtud.alloc.LinearAllocator, state: *CompositorState) !void {
    const bus_path = try sphdbus.sessionBusPath(environ);

    const system = sphtud.io.system;
    self.stream = try sphtud.io.socket(system.AF.UNIX, system.SOCK.STREAM, 0);
    try sphtud.io.connectUnix(self.stream, try .init(bus_path));

    self.scratch = scratch;

    self.stream_reader = sphtud.io.Reader.init(self.stream, &self.reader_buf);
    self.stream_writer = sphtud.io.Writer.init(self.stream, &self.writer_buf);

    self.connection = try .init(&self.stream_reader.interface, &self.stream_writer.interface);
    self.state = state;
}

pub fn service(self: *DbusService) !void {
    self.serviceInner() catch |e| {
        if (self.stream_reader.isWouldBlock(e)) return;
        return e;
    };
}

fn serviceInner(self: *DbusService) !void {
    while (true) {
        const res = try self.connection.poll(.{});

        var body_buf: [4096]u8 = undefined;
        var bs: sphdbus.BodySerializer = undefined;

        switch (res) {
            .initialized => {
                bs.initPinned(&body_buf, "su");
                try bs.addString("dev.sphaerophoria.sphwim");
                try bs.addU32(0);

                // FIXME: Log the handle and freak out if the response is not what we expected
                _ = try self.connection.call(
                    "/org/freedesktop/DBus",
                    "org.freedesktop.DBus",
                    "org.freedesktop.DBus",
                    "RequestName",
                    &bs,
                );
            },
            .response => {},
            .none => {},
            .call => |call| blk: {
                const cp = self.scratch.checkpoint();
                defer self.scratch.restore(cp);

                const req = try sphdbus.service.handleMessage(
                    service_def,
                    self.scratch.allocator(),
                    call,
                    &self.connection,
                    .{},
                ) orelse break :blk;

                switch (req) {
                    .@"/dev/sphaerophoria/sphwim" => |service_name| {
                        switch (service_name) {
                            .@"dev.sphaerophoria.sphwim" => |call_params| {
                                switch (call_params) {
                                    .method => |method| {
                                        switch (method) {
                                            .GetWindowList => |args| {
                                                bs.initPinned(&body_buf, args.retSignature());

                                                var it = self.state.windows.iter();
                                                try bs.startArray();
                                                while (it.next()) {
                                                    try bs.startArrayElem();
                                                    try bs.startKv();
                                                    {
                                                        try bs.addU64(it.item(.stable_handle).inner);
                                                        try bs.addString(it.item(.title).*);
                                                    }
                                                    try bs.endKv();
                                                }
                                                try bs.endArray();

                                                try self.connection.ret(
                                                    call.serial,
                                                    call.headers.sender.?.inner,
                                                    &bs,
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
