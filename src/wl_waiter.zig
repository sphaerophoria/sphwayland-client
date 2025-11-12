const std = @import("std");
const wlclient = @import("wlclient");
const wlb = @import("wl_bindings");

pub fn main() !void {
    var alloc_buf: [1 * 1024 * 1024]u8 = undefined;
    var buf_alloc = std.heap.FixedBufferAllocator.init(&alloc_buf);

    const alloc = buf_alloc.allocator();

    while (true) {
        var client = wlclient.Client(wlb).init(alloc, .linear(alloc)) catch {
            std.Thread.sleep(100 * std.time.ns_per_ms);
            continue;
        };
        client.deinit();

        break;
    }
}
