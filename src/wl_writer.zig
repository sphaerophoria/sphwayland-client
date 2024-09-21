const std = @import("std");
const builtin = @import("builtin");

pub const HeaderLE = packed struct { id: u32, op: u16, size: u16 };

pub fn writeWlMessage(writer: anytype, elem: anytype, id: u32) !void {
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
    try writer.writeStruct(header);

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

fn roundUp(val: anytype, mul: @TypeOf(val)) @TypeOf(val) {
    if (val == 0) {
        return 0;
    }
    return ((val - 1) / mul + 1) * mul;
}

fn writtenStringLen(s: [:0]const u8) usize {
    return writtenArrayLen(s[0 .. s.len + 1]);
}

fn writtenArrayLen(s: []const u8) usize {
    const len_len = 4;
    return roundUp(len_len + s.len, 4);
}

fn writeString(w: anytype, s: [:0]const u8) !void {
    try writeArray(w, s[0 .. s.len + 1]);
}

fn writeArray(w: anytype, s: []const u8) !void {
    // null terminated
    try w.writeInt(u32, @intCast(s.len), .little);
    try w.writeAll(s);
    const written = 4 + s.len;
    const required_len = writtenArrayLen(s);
    try w.writeByteNTimes(0, required_len - written);
}
