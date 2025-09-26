const std = @import("std");
const Allocator = std.mem.Allocator;

file: std.fs.File,
buf: CircularBufReader,
buffered_exit_event: ?Item = null,

const XmlLexer = @This();

pub fn init(buf: []u8, file: std.fs.File) !XmlLexer {
    return XmlLexer{
        .file = file,
        .buf = CircularBufReader{
            .buf = buf,
        },
    };
}

pub fn next(self: *XmlLexer) !?Item {
    if (self.buffered_exit_event) |item| {
        self.buffered_exit_event = null;
        return item;
    }

    // There's definitely a better heuristic. Probably lazily fetching
    // is ideal, but this is simple and good enough for now. If we just
    // double the buffer size that's a lot like a perfect heuristic at
    // the current buffer size ;)
    if (self.buf.len() < self.buf.capacity() / 2) {
        try self.buf.populate(FileVectoredReader{ .f = self.file });
    }

    const ret = try self.advanceToTag() orelse return null;

    // No point in returning 0 length content, it's just noise for the
    // caller
    if (ret.start != ret.end) {
        return ret;
    }

    // From here on out, we may return references to data in self.buf,
    // so please don't call populate() again

    const start_pos = self.buf.consumedBytes();
    const buf_slice = self.buf.content();

    const prefix = try parseElementPrefix(buf_slice);

    const name_start = prefix.prefix_end;
    const name_end = buf_slice.indexOfAnyPos(name_start, std.ascii.whitespace ++ ">") orelse return error.NoNameEnd;

    const end_sequence = try prefix.type.endSequence();

    var element_end_tag_start = buf_slice.indexOfPos(name_end, end_sequence) orelse return error.NoEndSequence;
    var element_end_tag_len = end_sequence.len;

    // Special case for handling self closing tags
    if (prefix.type == .element_start and buf_slice.value(element_end_tag_start - 1) == '/') {
        element_end_tag_start -= 1;
        element_end_tag_len += 1;
        self.buffered_exit_event = .{
            .type = .element_end,
            .start = start_pos,
            .end = start_pos + element_end_tag_start + element_end_tag_len,
            .name = buf_slice.slice(name_start, name_end),
            .attributes = BufferPair.empty,
        };
    }

    const attributes_slice = switch (prefix.type) {
        .xml_decl, .element_start => buf_slice.slice(name_end, element_end_tag_start),
        else => BufferPair.empty,
    };

    const element_end = element_end_tag_start + element_end_tag_len;

    // We are returning references to things in buf, which makes this
    // consume look sketchy. HOWEVER, the data in the buffer will not be
    // overwritten until the next call to populate() which should not
    // happen until the user calls next() again
    self.buf.consume(element_end);
    return .{
        .type = prefix.type,
        .start = start_pos,
        .end = start_pos + element_end,
        .name = buf_slice.slice(name_start, name_end),
        .attributes = attributes_slice,
    };
}

pub const Attribute = struct {
    key: BufferPair,
    val: BufferPair,
};

pub const Item = struct {
    type: ItemType,
    name: BufferPair,
    attributes: BufferPair,
    start: usize,
    end: usize,

    pub fn attributeIt(self: Item) AttributeIt {
        return .{
            .data = self.attributes,
        };
    }
};

pub const AttributeIt = struct {
    data: BufferPair,

    pub fn next(self: *AttributeIt) !?Attribute {
        if (self.data.len() == 0) {
            return null;
        }

        var it = BufferPairCursor{
            .data = self.data,
        };

        const key = try parseKey(&it);
        try validateEq(&it);
        try validateQuote(&it);
        const val = try parseVal(&it);

        defer self.data = self.data.slice(it.idx + 1, self.data.len());

        return .{
            .key = key,
            .val = val,
        };
    }

    fn parseKey(it: *BufferPairCursor) !BufferPair {
        const key_start = it.consumeWhileAny(&std.ascii.whitespace);
        const key_end = it.consumeWhileNone(std.ascii.whitespace ++ "=");
        if (key_end == it.data.len()) {
            std.log.err("Cannot find key end in attribute", .{});
            return error.MalformedAttribute;
        }

        return it.data.slice(key_start, key_end);
    }

    fn validateEq(it: *BufferPairCursor) !void {
        _ = it.consumeWhileAny(&std.ascii.whitespace);
        if (it.peekByte() != '=') {
            std.log.err("Attribute is missing an = between key/val", .{});
            return error.MalformedAttribute;
        }
        it.consume(1);
    }

    fn validateQuote(it: *BufferPairCursor) !void {
        _ = it.consumeWhileAny(&std.ascii.whitespace);

        if (it.peekByte() != '"') {
            std.log.err("Attribute is missing a \" for the value start", .{});
            return error.MalformedAttribute;
        }
        it.consume(1);
    }

    fn parseVal(it: *BufferPairCursor) !BufferPair {
        // FIXME: What if we see an invalid character
        // FIXME: Escaped quote
        const val_start = it.idx;
        const val_end = it.consumeWhileNone("\"");
        if (val_end == it.data.len()) {
            std.log.err("Attribute value does not end with a \"", .{});
            return error.MalformedAttribute;
        }

        return it.data.slice(val_start, val_end);
    }
};

const ParsedElementPrefix = struct {
    type: ItemType,
    prefix_end: usize,
};

fn parseElementPrefix(buf_slice: BufferPair) !ParsedElementPrefix {
    var token_type: ItemType = .element_start;
    var prefix_end: usize = 1;

    const initial_matcher_list = [_]ItemTypeMatcher{
        .{ .token = .xml_decl },
        .{ .token = .element_end },
        .{ .token = .comment },
    };

    var prefixes = StackArrayList(ItemTypeMatcher, initial_matcher_list.len)
        .initWithState(initial_matcher_list);

    var buf_slice_idx: usize = 0;

    // Check each matcher for every byte we read. We want to keep the
    // longest match. Because of this we can just keep re-assigning the
    // same output token_type variable as the longer ones will assign
    // later.
    // As matchers reject/accept sequences, we remove them from the
    // list of matchers for next bytes. The scheme of removal was written
    // thinking there would be a lot more than 3 types to match against.
    // It's possible there's something simpler, but this seems fine
    while (prefixes.len > 0) {
        defer buf_slice_idx += 1;
        // FIXME: We don't have to read byte by byte
        const b = buf_slice.value(buf_slice_idx);

        var to_remove = StackArrayList(usize, initial_matcher_list.len){};

        for (prefixes.items(), 0..) |*prefix, prefix_idx| {
            switch (try prefix.push(b)) {
                .matched => {
                    token_type = prefix.token;
                    prefix_end = (try prefix.token.startSequence()).len;
                    to_remove.append(prefix_idx);
                },
                .not_a_match => {
                    to_remove.append(prefix_idx);
                },
                .feeding => {},
            }
        }

        while (to_remove.popOrNull()) |idx| {
            _ = prefixes.swapRemove(idx);
        }
    }

    return .{
        .type = token_type,
        .prefix_end = prefix_end,
    };
}

fn advanceToTag(self: *XmlLexer) !?Item {
    const start = self.buf.consumedBytes();
    while (true) {
        const buffered = self.buf.content();
        if (buffered.len() == 0) {
            return null;
        }

        // Careful here. If we ever change this to look for multiple
        // chars, the consumeAll() below will result in us not catching
        // sequences that appear on a page boundary
        if (buffered.indexOfChar('<')) |v| {
            self.buf.consume(@intCast(v));
            break;
        }
        self.buf.consumeAll();
        try self.buf.populate(FileVectoredReader{ .f = self.file });
    }
    const end = self.buf.consumedBytes();

    return .{
        .type = .element_content,
        .name = BufferPair.empty,
        .attributes = BufferPair.empty,
        .start = @intCast(start),
        .end = @intCast(end),
    };
}

const ItemTypeMatcher = struct {
    token: ItemType,
    pos: u8 = 0,

    const State = enum {
        feeding,
        matched,
        not_a_match,
    };

    fn push(self: *ItemTypeMatcher, b: u8) !State {
        const string = try self.token.startSequence();
        const byte_matches = self.pos < string.len and string[self.pos] == b;
        self.pos += 1;
        if (byte_matches and self.pos == string.len) {
            return .matched;
        } else if (byte_matches) {
            return .feeding;
        } else {
            return .not_a_match;
        }
    }
};

const ItemType = enum {
    xml_decl,
    element_start,
    element_end,
    element_content,
    comment,

    fn startSequence(self: ItemType) ![]const u8 {
        return switch (self) {
            .xml_decl => "<?xml ",
            .element_start => "<",
            .element_end => "</",
            .comment => "<!--",
            .element_content => {
                return error.UnexpectedContent;
            },
        };
    }

    fn endSequence(self: ItemType) ![]const u8 {
        return switch (self) {
            .xml_decl => "?>",
            .element_start, .element_end => ">",
            .comment => "-->",
            .element_content => {
                return error.UnexpectedContent;
            },
        };
    }
};

fn StackArrayList(comptime T: type, comptime size: comptime_int) type {
    return struct {
        inner: [size]T = undefined,
        len: u8 = 0,

        const Self = @This();

        fn initWithState(initial_state: [size]T) Self {
            return .{
                .inner = initial_state,
                .len = size,
            };
        }

        fn items(self: *Self) []T {
            return self.inner[0..self.len];
        }

        fn append(self: *Self, val: T) void {
            self.inner[self.len] = val;
            self.len += 1;
        }

        fn popOrNull(self: *Self) ?T {
            if (self.len == 0) {
                return null;
            }
            defer self.len -= 1;
            return self.inner[self.len - 1];
        }

        fn swapRemove(self: *Self, idx: usize) void {
            std.mem.swap(ItemTypeMatcher, &self.inner[self.len - 1], &self.inner[idx]);
            self.len -= 1;
        }
    };
}

/// Helper type for circular buffer. Since circular buffers are not necessarily
/// contiguous, this type helps us treat a non contiguous set of two buffers as
/// a contiguous one
const BufferPair = struct {
    a: []u8,
    b: []u8,

    const empty = BufferPair{
        .a = &.{},
        .b = &.{},
    };

    pub fn format(self: BufferPair, comptime _: []const u8, _: std.fmt.FormatOptions, writer: anytype) !void {
        try writer.print("{s}{s}", .{ self.a, self.b });
    }

    pub fn makeContiguousAlloc(self: BufferPair, alloc: Allocator) ![]u8 {
        const ret = try alloc.alloc(u8, self.a.len + self.b.len);
        @memcpy(ret[0..self.a.len], self.a);
        @memcpy(ret[self.a.len..], self.b);
        return ret;
    }

    pub fn makeContiguousBuf(self: BufferPair, buf: []u8) ![]u8 {
        if (buf.len < self.len()) {
            return error.BufTooSmall;
        }
        const ret = buf[0..self.len()];
        @memcpy(ret[0..self.a.len], self.a);
        @memcpy(ret[self.a.len..], self.b);
        return ret;
    }

    fn len(self: BufferPair) usize {
        return self.a.len + self.b.len;
    }

    fn slice(self: BufferPair, start: usize, end: usize) BufferPair {
        if (end <= self.a.len) {
            return .{
                .a = self.a[start..end],
                .b = &.{},
            };
        } else if (start >= self.a.len) {
            return .{
                .a = self.b[start - self.a.len .. end - self.a.len],
                .b = &.{},
            };
        } else {
            return .{
                .a = self.a[start..],
                .b = self.b[0 .. end - self.a.len],
            };
        }
    }

    fn value(self: BufferPair, index: usize) u8 {
        if (index < self.a.len) {
            return self.a[index];
        } else {
            return self.b[index - self.a.len];
        }
    }

    fn runIndexOfPos(self: BufferPair, start: usize, needle: anytype, f: anytype) ?usize {
        if (start < self.a.len) {
            if (f(u8, self.a, start, needle)) |p| {
                return p;
            }

            if (f(u8, self.b, 0, needle)) |p| {
                return p + self.a.len;
            }

            return null;
        }

        if (f(u8, self.b, start - self.a.len, needle)) |p| {
            return p + self.a.len;
        }

        return null;
    }

    fn indexOfPos(self: BufferPair, start: usize, needle: []const u8) ?usize {
        return runIndexOfPos(self, start, needle, std.mem.indexOfPos);
    }

    fn indexOfAnyPos(self: BufferPair, start: usize, chars: []const u8) ?usize {
        return runIndexOfPos(self, start, chars, std.mem.indexOfAnyPos);
    }

    fn indexOfNonePos(self: BufferPair, start: usize, chars: []const u8) ?usize {
        return runIndexOfPos(self, start, chars, std.mem.indexOfNonePos);
    }

    fn indexOfCharPos(self: BufferPair, start: usize, char: u8) ?usize {
        return runIndexOfPos(self, start, char, std.mem.indexOfScalarPos);
    }

    fn indexOfChar(self: BufferPair, char: u8) ?usize {
        if (std.mem.indexOfScalar(u8, self.a, char)) |p| {
            return p;
        }

        if (std.mem.indexOfScalar(u8, self.b, char)) |p| {
            return p + self.a.len;
        }

        return null;
    }
};

test "buffer pair slice" {
    var a = "hello ".*;
    var b = "world".*;
    const bp = BufferPair{ .a = &a, .b = &b };

    var slice = bp.slice(0, 4);
    try std.testing.expectEqualStrings("hell", slice.a);
    try std.testing.expectEqualStrings("", slice.b);

    slice = bp.slice(4, 7);
    try std.testing.expectEqualStrings("o ", slice.a);
    try std.testing.expectEqualStrings("w", slice.b);

    slice = bp.slice(7, bp.len());
    try std.testing.expectEqualStrings("orld", slice.a);
    try std.testing.expectEqualStrings("", slice.b);
}

const FileVectoredReader = struct {
    f: std.fs.File,

    fn read(self: FileVectoredReader, buf_pair: BufferPair) !usize {
        if (buf_pair.len() == 0) {
            return 0;
        }

        const readv_arg = [_]std.posix.iovec{
            .{
                .base = buf_pair.a.ptr,
                .len = buf_pair.a.len,
            },
            .{
                .base = buf_pair.b.ptr,
                .len = buf_pair.b.len,
            },
        };
        return try std.posix.readv(self.f.handle, &readv_arg);
    }
};

fn StdMultiReader(comptime Reader: type) type {
    return struct {
        reader: Reader,

        const Self = @This();

        fn read(self: Self, buf_pair: BufferPair) !usize {
            var bytes_read = try self.reader.readAll(buf_pair.a);
            bytes_read += try self.reader.readAll(buf_pair.b);
            return bytes_read;
        }
    };
}

fn stdMultiReader(reader: anytype) StdMultiReader(@TypeOf(reader)) {
    return .{
        .reader = reader,
    };
}

test "std vectored reader" {
    const data = "hello world";
    var fixed_reader = std.io.fixedBufferStream(data);
    const multi_reader = stdMultiReader(fixed_reader.reader());

    var a: [5]u8 = undefined;
    var b: [10]u8 = undefined;
    const output = BufferPair{
        .a = &a,
        .b = &b,
    };

    const bytes_read = try multi_reader.read(output);
    try std.testing.expectEqual(data.len, bytes_read);
    try std.testing.expectEqualStrings("hello", &a);
    try std.testing.expectEqualStrings(" world", b[0 .. bytes_read - a.len]);
}

// Circular buffer data structure written with the intent of reading from a
// file in chunks, then inspecting/making references to the buffered data
// as it is in memory
const CircularBufReader = struct {
    // User provided backing buffer
    buf: []u8,
    write_pos: usize = 0,
    read_pos: usize = 0,
    num_bytes_read: usize = 0,

    const Self = @This();

    pub fn populate(self: *Self, multi_reader: anytype) !void {
        const buf_pair = self.writeableContent();
        const bytes_read = try multi_reader.read(buf_pair);
        self.write_pos += bytes_read;
        self.num_bytes_read += bytes_read;
    }

    pub fn consume(self: *Self, amount: usize) void {
        self.read_pos += amount;
        if (self.read_pos >= self.buf.len) {
            self.read_pos -= self.buf.len;
            self.write_pos -= self.buf.len;
        }
    }

    pub fn consumedBytes(self: Self) usize {
        return self.num_bytes_read - self.len();
    }

    pub fn consumeAll(self: *Self) void {
        self.consume(self.len());
    }

    pub fn content(self: *Self) BufferPair {
        const a_end = @min(self.write_pos, self.buf.len);
        const b_end = if (self.write_pos > self.buf.len) self.write_pos % self.buf.len else 0;

        return .{
            .a = self.buf[self.read_pos..a_end],
            .b = self.buf[0..b_end],
        };
    }

    fn writeableContent(self: *Self) BufferPair {
        if (self.len() == self.buf.len) {
            return .{
                .a = &.{},
                .b = &.{},
            };
        }

        const a_start = self.write_pos % self.buf.len;
        const read_after_start = self.read_pos > a_start;
        const a_end = if (read_after_start) self.read_pos else self.buf.len;
        const b_start = a_end % self.buf.len;
        return .{
            .a = self.buf[a_start..a_end],
            .b = self.buf[b_start..self.read_pos],
        };
    }

    pub fn len(self: Self) usize {
        return self.write_pos - self.read_pos;
    }

    pub fn capacity(self: Self) usize {
        return self.buf.len;
    }
};

test "circular buf reader" {
    const data = "The quick brown fox jumped over the lazy dog";
    var fixed_reader = std.io.fixedBufferStream(data);
    const multi_reader = stdMultiReader(fixed_reader.reader());

    var buf: [4096]u8 = undefined;
    var cbr = CircularBufReader{ .buf = &buf };
    // "__________"
    try cbr.populate(multi_reader);
    var content = cbr.content();
    try std.testing.expectEqualStrings("The quick ", content.a);
    try std.testing.expectEqualStrings("", content.b);

    cbr.consume(4);
    // "____quick "

    content = cbr.content();
    try std.testing.expectEqualStrings("quick ", content.a);
    try std.testing.expectEqualStrings("", content.b);

    try cbr.populate(multi_reader);
    // "browquick "
    content = cbr.content();
    try std.testing.expectEqualStrings("quick ", content.a);
    try std.testing.expectEqualStrings("brow", content.b);

    cbr.consume(7);
    // "_row______"
    content = cbr.content();
    try std.testing.expectEqualStrings("row", content.a);
    try std.testing.expectEqualStrings("", content.b);

    try cbr.populate(multi_reader);
    // "jrown fox "
    content = cbr.content();
    try std.testing.expectEqualStrings("rown fox ", content.a);
    try std.testing.expectEqualStrings("j", content.b);
}

fn indexOfWhitespaceEnd(slice: BufferPair) ?usize {
    return slice.indexOfNonePos(0, &std.ascii.whitespace);
}

const BufferPairCursor = struct {
    data: BufferPair,
    idx: usize = 0,

    fn consumeWhileAny(
        self: *BufferPairCursor,
        chars: []const u8,
    ) usize {
        self.idx = self.data.indexOfNonePos(self.idx, chars) orelse self.data.len();
        return self.idx;
    }

    fn consumeWhileNone(
        self: *BufferPairCursor,
        chars: []const u8,
    ) usize {
        self.idx = self.data.indexOfAnyPos(self.idx, chars) orelse self.data.len();
        return self.idx;
    }

    fn consume(self: *BufferPairCursor, amount: usize) void {
        self.idx += amount;
    }

    fn peekByte(self: *BufferPairCursor) u8 {
        return self.data.value(self.idx);
    }
};
