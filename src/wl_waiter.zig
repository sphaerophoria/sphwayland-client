const std = @import("std");
const wlclient = @import("wlclient");
const wlb = @import("wl_bindings");

pub fn main() !void {
    var gpa = std.heap.DebugAllocator(.{}){};
    defer _ = gpa.deinit();

    const alloc = gpa.allocator();

    while (true) {
        var client = wlclient.Client(wlb).init(alloc) catch {
            std.Thread.sleep(100 * std.time.ns_per_ms);
            continue;
        };
        client.deinit();

        break;
    }
}
