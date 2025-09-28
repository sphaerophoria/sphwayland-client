const std = @import("std");
const sphtud = @import("sphtud");
const fd_cmsg = @import("fd_cmsg");
const FdPool = @import("../FdPool.zig");

const Reader = @This();

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

// FIXME: duplicated with client
const CmsgHdr = extern struct {
    cmsg_len: usize,
    cmsg_level: c_int,
    cmsg_type: c_int,
};

fn stream(r: *std.Io.Reader, writer: *std.Io.Writer, limit: std.Io.Limit) error{ EndOfStream, ReadFailed, WriteFailed }!usize {
    const self: *Reader = @fieldParentPtr("interface", r);
    self.last_res = .SUCCESS;

    const dest = limit.slice(try writer.writableSliceGreedy(1));

    var iov: [1]std.posix.iovec = .{.{
        .base = dest.ptr,
        .len = dest.len,
    }};

    var control: [fd_cmsg.fd_cmsg_space]u8 = undefined;
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

    if (msg_header.controllen >= @sizeOf(CmsgHdr)) blk: {
        const hdr = std.mem.bytesToValue(CmsgHdr, &control);
        if (hdr.cmsg_level == std.os.linux.SOL.SOCKET) {
            const fd: c_int = std.mem.bytesToValue(c_int, control[fd_cmsg.fd_cmsg_data_offs..][0..4]);

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

    writer.advance(@intCast(ret));
    return @intCast(ret);
}
