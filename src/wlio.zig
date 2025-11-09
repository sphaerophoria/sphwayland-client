const std = @import("std");
const builtin = @import("builtin");
const sphtud = @import("sphtud");
const wl_cmsg = @import("wl_cmsg");

pub const HeaderLE = packed struct { id: u32, op: u16, size: u16 };

pub const WlFixed = packed struct(u32) {
    integer: i32,

    pub fn tof32(self: WlFixed) f32 {
        return @as(f32, @floatFromInt(self.integer)) / 256;
    }

    pub fn fromi32(val: i32) WlFixed {
        return .{ .integer = val * 256 };
    }
};

pub fn writeWlMessage(writer: *std.io.Writer, elem: anytype, id: u32) !void {
    var size: usize = @sizeOf(HeaderLE);
    inline for (std.meta.fields(@TypeOf(elem))) |field| {
        switch (field.type) {
            u32 => size += 4,
            i32 => size += 4,
            [:0]const u8 => {
                size += writtenStringLen(@field(elem, field.name));
            },
            []const u8 => {
                size += writtenArrayLen(@field(elem, field.name));
            },
            void => {},
            WlFixed => {
                size += 4;
            },
            else => {
                @compileError("Unsupported field " ++ field.name);
            },
        }
    }

    const header = HeaderLE{
        .id = id,
        .op = @TypeOf(elem).op,
        .size = @intCast(size),
    };
    try writer.writeStruct(header, .little);

    const endian = builtin.cpu.arch.endian();
    inline for (std.meta.fields(@TypeOf(elem))) |field| {
        switch (field.type) {
            u32 => try writer.writeInt(u32, @field(elem, field.name), endian),
            i32 => try writer.writeInt(i32, @field(elem, field.name), endian),
            [:0]const u8 => {
                try writeString(writer, @field(elem, field.name));
            },
            void => {},
            []const u8 => {
                try writeArray(writer, @field(elem, field.name));
            },
            WlFixed => try writer.writeInt(i32, @field(elem, field.name).integer, endian),
            else => {
                @compileError("Unsupported field " ++ field.name);
            },
        }
    }
}

fn writtenStringLen(s: [:0]const u8) usize {
    return writtenArrayLen(s[0 .. s.len + 1]);
}

fn writtenArrayLen(s: []const u8) usize {
    const len_len = 4;
    return roundUp(len_len + s.len, 4);
}

fn writeString(w: *std.Io.Writer, s: [:0]const u8) !void {
    try writeArray(w, s[0 .. s.len + 1]);
}

fn writeArray(w: *std.Io.Writer, s: []const u8) !void {
    // null terminated
    try w.writeInt(u32, @intCast(s.len), .little);
    try w.writeAll(s);
    const written = 4 + s.len;
    const required_len = writtenArrayLen(s);
    try w.splatByteAll(0, required_len - written);
}

pub fn parseDataResponse(comptime T: type, data: []const u8) !T {
    var ret: T = undefined;
    var it = EventDataParser{ .buf = data };
    inline for (std.meta.fields(T)) |field| {
        switch (field.type) {
            u32 => {
                @field(ret, field.name) = try it.getU32();
            },
            i32 => {
                @field(ret, field.name) = try it.getI32();
            },
            [:0]const u8 => {
                @field(ret, field.name) = try it.getString();
            },
            []const u8 => {
                @field(ret, field.name) = try it.getArray();
            },
            WlFixed => {
                @field(ret, field.name) = @bitCast(try it.getU32());
            },
            void => {},
            else => @compileError("Unimplemented parser for " ++ field.name),
        }
    }

    return ret;
}

const EventDataParser = struct {
    buf: []const u8,

    fn getU32(self: *EventDataParser) !u32 {
        if (self.buf.len < 4) {
            return error.InvalidLen;
        }
        const val = std.mem.bytesToValue(u32, self.buf[0..4]);
        self.consume(4);
        return val;
    }

    fn getI32(self: *EventDataParser) !i32 {
        return @bitCast(try self.getU32());
    }

    fn getString(self: *EventDataParser) ![:0]const u8 {
        const arr = try self.getArray();
        return @ptrCast(arr[0 .. arr.len - 1]);
    }

    fn getArray(self: *EventDataParser) ![]const u8 {
        if (self.buf.len < 4) {
            return error.InvalidLen;
        }

        const len = std.mem.bytesToValue(u32, self.buf[0..4]);
        // Length field + 32 bit aligned string length
        const consume_len = 4 + roundUp(len, 4);

        if (consume_len > self.buf.len) {
            return error.InvalidLen;
        }

        const s = self.buf[4 .. 4 + len];
        self.consume(consume_len);
        return s;
    }

    fn consume(self: *EventDataParser, len: usize) void {
        if (self.buf.len == len) {
            self.buf = &.{};
        } else {
            self.buf = self.buf[len..];
        }
    }
};

// FIXME: dup
fn roundUp(val: anytype, mul: @TypeOf(val)) @TypeOf(val) {
    if (val == 0) {
        return 0;
    }
    return ((val - 1) / mul + 1) * mul;
}

// FIXME: This should live in sphtud or something?
pub const FdPool = struct {
    inner: sphtud.util.AutoHashMap(std.posix.fd_t, void),

    pub fn init(alloc: std.mem.Allocator, typical_files: usize, max_files: usize) !FdPool {
        return .{
            .inner = try .init(alloc, .linear(alloc), typical_files, max_files),
        };
    }

    pub fn register(self: *FdPool, fd: std.posix.fd_t) !void {
        try self.inner.put(fd, {});
    }

    pub fn close(self: *FdPool, fd: std.posix.fd_t) void {
        std.posix.close(fd);
        _ = self.inner.remove(fd);
    }

    pub fn closeAll(self: *FdPool) void {
        var it = self.inner.iter();
        while (it.next()) |item| {
            std.posix.close(item.key.*);
        }
    }
};

pub const Reader = struct {
    socket: std.net.Stream,
    fd_pool: *FdPool,
    fd_list: sphtud.util.CircularBuffer(std.posix.fd_t),
    last_res: std.os.linux.E = .SUCCESS,
    interface: std.Io.Reader,

    pub fn init(alloc: std.mem.Allocator, fd_pool: *FdPool, socket: std.net.Stream) !Reader {
        return .{
            .socket = socket,
            .fd_pool = fd_pool,
            .fd_list = .{
                // 100 file descriptors received before we handle any of them seems
                // like an insanely large number for a single connection
                .items = try alloc.alloc(c_int, 100),
            },
            .interface = std.Io.Reader{
                .buffer = try alloc.alloc(u8, 4096),
                .vtable = &.{
                    .stream = stream,
                },
                .seek = 0,
                .end = 0,
            },
        };
    }

    fn stream(r: *std.Io.Reader, writer: *std.Io.Writer, limit: std.Io.Limit) error{ EndOfStream, ReadFailed, WriteFailed }!usize {
        const self: *Reader = @fieldParentPtr("interface", r);
        self.last_res = .SUCCESS;

        const dest = limit.slice(try writer.writableSliceGreedy(1));

        var iov: [1]std.posix.iovec = .{.{
            .base = dest.ptr,
            .len = dest.len,
        }};

        var control: [wl_cmsg.max_buf_size]u8 = undefined;
        var msg_header = std.os.linux.msghdr{
            .name = null,
            .namelen = 0,
            .iov = &iov,
            .iovlen = 1,
            .control = &control,
            .controllen = control.len,
            .flags = 0,
        };

        // We could recvmmsg here, but for now this is good enough
        const ret = std.os.linux.recvmsg(self.socket.handle, &msg_header, 0);

        if (ret == 0) return error.EndOfStream;

        const linux_err: std.os.linux.E = .init(ret);
        switch (linux_err) {
            .SUCCESS => {},
            else => {
                self.last_res = linux_err;
                return error.ReadFailed;
            },
        }

        if (msg_header.controllen >= @sizeOf(wl_cmsg.CmsgHdr)) blk: {
            const hdr = std.mem.bytesToValue(wl_cmsg.CmsgHdr, &control);
            if (hdr.cmsg_level == std.os.linux.SOL.SOCKET) {
                var offs: usize = wl_cmsg.fd_list_start;
                while (offs < hdr.cmsg_len) {
                    const fd: c_int = std.mem.bytesToValue(c_int, control[offs..][0..4]);
                    offs += 4;

                    self.fd_pool.register(fd) catch {
                        std.log.err("Dropped file descriptor", .{});
                        std.posix.close(fd);
                        break :blk;
                    };

                    self.fd_list.pushNoClobber(fd) catch {
                        std.log.err("Dropped file descriptor", .{});
                        self.fd_pool.close(fd);
                        break :blk;
                    };
                }
            }
        }

        writer.advance(@intCast(ret));
        return @intCast(ret);
    }
};

pub fn requiresFd(req: anytype) bool {
    switch (req) {
        inline else => |_, t| {
            const interface_message = @field(req, @tagName(t));
            if (@typeInfo(@TypeOf(interface_message)) == .@"struct") {
                return false;
            }
            switch (interface_message) {
                inline else => |_, t2| {
                    const concrete_message = @field(interface_message, @tagName(t2));
                    return @TypeOf(concrete_message).requires_fd;
                },
            }
        },
    }
}
