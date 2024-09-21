const std = @import("std");

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
