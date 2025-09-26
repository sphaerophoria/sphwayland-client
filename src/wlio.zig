const std = @import("std");
const builtin = @import("builtin");

pub const HeaderLE = packed struct { id: u32, op: u16, size: u16 };

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
