const std = @import("std");
const sphtud = @import("sphtud");

inner: sphtud.util.AutoHashMapSphalloc(std.posix.fd_t, void),

const FdPool = @This();

pub fn init(alloc: *sphtud.alloc.Sphalloc, typical_files: usize, max_files: usize) !FdPool {
    return .{
        .inner = try .init(alloc.arena(), alloc.block_alloc.allocator(), typical_files, max_files),
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
