const fd_cmsg = @import("fd_cmsg");
const std = @import("std");

pub const max_buf_size = fd_cmsg.fd_cmsg_space;
pub const fd_list_start = fd_cmsg.fd_cmsg_data_offs;

pub fn sendMessageWithFdAttachment(stream: std.net.Stream, msg: []const u8, fd: c_int) !void {
    const SCM_RIGHTS = 1;
    var cmsg_buf: [fd_cmsg.fd_cmsg_space]u8 = @splat(0);
    const cmsg_len = fd_cmsg.fd_cmsg_data_offs + @sizeOf(c_int);
    const hdr = CmsgHdr{
        .cmsg_len = cmsg_len,
        .cmsg_level = std.os.linux.SOL.SOCKET,
        .cmsg_type = SCM_RIGHTS,
    };
    @memcpy(cmsg_buf[0..@sizeOf(CmsgHdr)], std.mem.asBytes(&hdr));
    @memcpy(cmsg_buf[fd_cmsg.fd_cmsg_data_offs..][0..@sizeOf(c_int)], std.mem.asBytes(&fd));

    const iov = [1]std.posix.iovec_const{.{
        .base = msg.ptr,
        .len = msg.len,
    }};

    const msghdr = std.posix.msghdr_const{
        .name = null,
        .namelen = 0,
        .iov = &iov,
        .iovlen = 1,
        .control = &cmsg_buf,
        .controllen = cmsg_len,
        .flags = 0,
    };

    // FIXME: check result
    _ = try std.posix.sendmsg(stream.handle, &msghdr, 0);
}

pub const CmsgHdr = extern struct {
    cmsg_len: usize,
    cmsg_level: c_int,
    cmsg_type: c_int,
};
