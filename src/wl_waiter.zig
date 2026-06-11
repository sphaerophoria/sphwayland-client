const std = @import("std");
const sphtud = @import("sphtud");
const wlclient = @import("wlclient");
const wlb = @import("wl_bindings");

pub fn main(init: std.process.Init.Minimal) !void {
    var alloc_buf: [1 * 1024 * 1024]u8 = undefined;
    var buf_alloc = std.heap.FixedBufferAllocator.init(&alloc_buf);

    const alloc = buf_alloc.allocator();

    while (true) {
        var client = wlclient.Client(wlb).init(alloc, .linear(alloc), init.environ) catch {
            try sphtud.io.nanosleep(.fromMilliseconds(100));
            continue;
        };
        client.deinit();

        break;
    }
}
