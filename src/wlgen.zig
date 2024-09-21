const std = @import("std");
const Allocator = std.mem.Allocator;
const XmlParser = @import("XmlParser.zig");

pub const std_options = std.Options{
    .log_level = .warn,
};

const Arg = struct {
    name: []const u8,
    summary: []const u8,
    has_interface: bool,
    typ: Type,

    const Type = enum {
        int,
        uint,
        fixed,
        string,
        object,
        new_id,
        array,
        fd,

        fn fromString(s: []const u8) !Type {
            return std.meta.stringToEnum(Arg.Type, s) orelse {
                return error.UnknownType;
            };
        }

        fn toZigTypeString(self: Type) ?[]const u8 {
            switch (self) {
                .int => return "i32",
                .uint => return "u32",
                .string => return "[:0]const u8",
                .array => return "[]const u8",
                .new_id => return "u32",
                .object => return "u32",
                .fd => return "void",
                else => return null,
            }
        }
    };

    fn init(alloc: Allocator, attrs: *XmlParser.XmlAttrIter) !Arg {
        var name: ?[]const u8 = null;
        errdefer if (name) |n| alloc.free(n);

        var typ: ?Arg.Type = null;

        var summary: []const u8 = &.{};
        errdefer alloc.free(summary);

        var has_interface = false;

        const ArgTag = enum { name, interface, type, summary };

        while (attrs.next()) |attr| {
            const arg_tag = std.meta.stringToEnum(ArgTag, attr.key) orelse {
                std.log.debug("Unhandled arg tag: {s}", .{attr.key});
                continue;
            };

            switch (arg_tag) {
                .name => name = try alloc.dupe(u8, attr.val),
                .interface => has_interface = true,
                .type => {
                    typ = try Arg.Type.fromString(attr.val);
                },
                .summary => summary = try alloc.dupe(u8, attr.val),
            }
        }

        return .{
            .name = name orelse return error.NoArgName,
            .summary = summary,
            .has_interface = has_interface,
            .typ = typ orelse return error.NoArgType,
        };
    }

    fn deinit(self: *Arg, alloc: Allocator) void {
        alloc.free(self.name);
        alloc.free(self.summary);
    }
};

const Interface = struct {
    name: []const u8,
    version: u32,
    description: []const u8,
    requests: []RequestEvent,
    events: []RequestEvent,

    const RequestEvent = struct {
        name: []const u8 = &.{},
        description: []const u8 = &.{},
        args: []Arg = &.{},

        const Builder = struct {
            name: []const u8 = &.{},
            description: std.ArrayListUnmanaged(u8) = .{},
            args: std.ArrayListUnmanaged(Arg) = .{},

            fn init(alloc: Allocator, attrs: *XmlParser.XmlAttrIter) !@This() {
                var name: ?[]const u8 = null;
                errdefer if (name) |n| alloc.free(n);

                while (attrs.next()) |attr| {
                    if (std.mem.eql(u8, attr.key, "name")) {
                        name = try alloc.dupe(u8, attr.val);
                        break;
                    }
                }

                return .{
                    .name = name orelse return error.NoReqName,
                };
            }

            fn deinit(self: *@This(), alloc: Allocator) void {
                alloc.free(self.name);
                self.description.deinit(alloc);
                for (self.args.items) |*arg| {
                    arg.deinit(alloc);
                }
                self.args.deinit(alloc);
            }

            fn finish(self: *@This(), alloc: Allocator) !RequestEvent {
                defer self.* = .{};

                return .{
                    .name = self.name,
                    .description = try self.description.toOwnedSlice(alloc),
                    .args = try self.args.toOwnedSlice(alloc),
                };
            }
        };

        pub fn deinit(self: *RequestEvent, alloc: Allocator) void {
            alloc.free(self.name);
            alloc.free(self.description);
            for (self.args) |*arg| {
                arg.deinit(alloc);
            }
            alloc.free(self.args);
        }
    };

    const Event = struct {};

    const Builder = struct {
        name: []const u8 = &.{},
        version: u32 = 0,
        description: std.ArrayListUnmanaged(u8) = .{},
        requests: std.ArrayListUnmanaged(RequestEvent) = .{},
        events: std.ArrayListUnmanaged(RequestEvent) = .{},

        unfininshed_request_event: RequestEvent.Builder = .{},

        pub fn init(alloc: Allocator, attrs: *XmlParser.XmlAttrIter) !Builder {
            var name: ?[]const u8 = null;
            errdefer if (name) |n| alloc.free(n);
            var version: ?u32 = null;

            const Field = enum { name, version };

            while (attrs.next()) |attr| {
                const field = std.meta.stringToEnum(Field, attr.key) orelse continue;

                switch (field) {
                    .name => name = try alloc.dupe(u8, attr.val),
                    .version => version = try std.fmt.parseInt(u32, attr.val, 10),
                }
            }

            return Interface.Builder{
                .name = name orelse return error.NoInterfaceName,
                .version = version orelse return error.NoInterfaceVersion,
            };
        }

        pub fn pushNewReqEvent(self: *Builder, alloc: Allocator, attrs: *XmlParser.XmlAttrIter) !void {
            self.unfininshed_request_event = try RequestEvent.Builder.init(alloc, attrs);
        }

        pub fn pushReqEventArg(self: *Builder, alloc: Allocator, arg: Arg) !void {
            try self.unfininshed_request_event.args.append(alloc, arg);
        }

        pub fn finishReq(self: *Builder, alloc: Allocator) !void {
            try self.requests.append(
                alloc,
                try self.unfininshed_request_event.finish(alloc),
            );
        }

        pub fn finishEvent(self: *Builder, alloc: Allocator) !void {
            try self.events.append(
                alloc,
                try self.unfininshed_request_event.finish(alloc),
            );
        }

        pub fn deinit(self: *Builder, alloc: Allocator) void {
            alloc.free(self.name);
            self.description.deinit(alloc);
            for (self.requests.items) |*item| {
                item.deinit(alloc);
            }
            self.requests.deinit(alloc);
            self.unfininshed_request_event.deinit(alloc);
            for (self.events.items) |*item| {
                item.deinit(alloc);
            }
            self.events.deinit(alloc);
        }

        fn finish(self: *Builder, alloc: Allocator) !Interface {
            defer self.* = .{};
            return .{
                .name = self.name,
                .version = self.version,
                .description = try self.description.toOwnedSlice(alloc),
                .requests = try self.requests.toOwnedSlice(alloc),
                .events = try self.events.toOwnedSlice(alloc),
            };
        }
    };

    pub fn deinit(self: *Interface, alloc: Allocator) void {
        alloc.free(self.name);
        alloc.free(self.description);
        for (self.requests) |*req| {
            req.deinit(alloc);
        }
        alloc.free(self.requests);
        for (self.events) |*req| {
            req.deinit(alloc);
        }
        alloc.free(self.events);
    }
};

const WaylandXmlParser = struct {
    alloc: Allocator,
    interfaces: std.ArrayListUnmanaged(Interface) = .{},
    unfinished_interface: Interface.Builder = .{},

    unknown_level: u8 = 0,
    unknown_parent: State = .top,

    state: State = .top,

    const State = enum {
        top,
        unknown,
        protocol,
        interface,
        interface_description,
        request,
        request_description,
        request_arg,
        event,
        event_description,
        event_arg,
    };
    const ReqEventTag = enum {
        arg,
        description,
    };

    fn deinit(self: *WaylandXmlParser) void {
        for (self.interfaces.items) |*interface| {
            interface.deinit(self.alloc);
        }
        self.interfaces.deinit(self.alloc);
        self.unfinished_interface.deinit(self.alloc);
    }

    fn onEnter(ctx: ?*anyopaque, name: []const u8, attrs: *XmlParser.XmlAttrIter) anyerror!void {
        const self: *WaylandXmlParser = @ptrCast(@alignCast(ctx));

        switch (self.state) {
            .top => {
                std.debug.assert(std.mem.eql(u8, name, "protocol"));
                self.state = .protocol;
            },
            .protocol => try self.onProtocolEnter(name, attrs),
            .interface => try self.onInterfaceEnter(name, attrs),
            .request => try self.onRequestEnter(name, attrs),
            .event => try self.onEventEnter(name, attrs),
            .unknown => {
                self.unknown_level += 1;
            },
            else => {
                @panic("Unimplemented");
            },
        }
    }

    fn onProtocolEnter(self: *WaylandXmlParser, name: []const u8, attrs: *XmlParser.XmlAttrIter) !void {
        if (std.mem.eql(u8, name, "interface")) {
            self.state = .interface;
            self.unfinished_interface = try Interface.Builder.init(self.alloc, attrs);
        } else {
            std.log.debug("Unhandled protocol child {s}", .{name});
            self.setStateUnknown(.protocol);
        }
    }

    fn onInterfaceEnter(self: *WaylandXmlParser, name: []const u8, attrs: *XmlParser.XmlAttrIter) !void {
        // FIXME: event
        const InterfaceTag = enum { description, request, event };

        const tag = std.meta.stringToEnum(InterfaceTag, name) orelse {
            std.log.debug("Unhandled interface child {s}", .{name});
            self.setStateUnknown(.interface);
            return;
        };

        switch (tag) {
            .description => {
                self.state = .interface_description;
            },
            .request => {
                try self.unfinished_interface.pushNewReqEvent(self.alloc, attrs);
                self.state = .request;
            },
            .event => {
                try self.unfinished_interface.pushNewReqEvent(self.alloc, attrs);
                self.state = .event;
            },
        }
    }

    fn onRequestEnter(self: *WaylandXmlParser, name: []const u8, attrs: *XmlParser.XmlAttrIter) !void {
        const tag = std.meta.stringToEnum(ReqEventTag, name) orelse {
            std.log.debug("Unhandled request child {s}", .{name});
            self.setStateUnknown(.request);
            return;
        };

        switch (tag) {
            .description => {
                self.state = .request_description;
            },
            .arg => {
                try self.unfinished_interface.pushReqEventArg(
                    self.alloc,
                    try Arg.init(self.alloc, attrs),
                );

                self.state = .request_arg;
            },
        }
    }

    fn onEventEnter(self: *WaylandXmlParser, name: []const u8, attrs: *XmlParser.XmlAttrIter) !void {
        const tag = std.meta.stringToEnum(ReqEventTag, name) orelse {
            std.log.debug("Unhandled event child {s}", .{name});
            self.setStateUnknown(.request);
            return;
        };

        switch (tag) {
            .description => {
                self.state = .event_description;
            },
            .arg => {
                try self.unfinished_interface.pushReqEventArg(
                    self.alloc,
                    try Arg.init(self.alloc, attrs),
                );

                self.state = .event_arg;
            },
        }
    }

    fn exitState(self: *WaylandXmlParser) void {
        self.state = switch (self.state) {
            .top => blk: {
                std.debug.assert(false);
                break :blk .top;
            },
            .protocol => .top,
            .interface => .protocol,
            .interface_description => .interface,
            .request => .interface,
            .request_description => .request,
            .request_arg => .request,
            .event => .interface,
            .event_description => .event,
            .event_arg => .event,
            .unknown => blk: {
                self.unknown_level -= 1;
                if (self.unknown_level == 0) {
                    break :blk self.unknown_parent;
                } else {
                    break :blk .unknown;
                }
            },
        };
    }

    fn onExit(ctx: ?*anyopaque, _: []const u8) anyerror!void {
        const self: *WaylandXmlParser = @ptrCast(@alignCast(ctx));

        switch (self.state) {
            .interface => {
                try self.interfaces.append(
                    self.alloc,
                    try self.unfinished_interface.finish(self.alloc),
                );
            },
            .request => {
                try self.unfinished_interface.finishReq(self.alloc);
            },
            .event => {
                try self.unfinished_interface.finishEvent(self.alloc);
            },
            else => {},
        }

        self.exitState();
    }

    fn onCharData(ctx: ?*anyopaque, data: []const u8) anyerror!void {
        const self: *WaylandXmlParser = @ptrCast(@alignCast(ctx));
        if (self.state == .interface_description) {
            try self.unfinished_interface.description.appendSlice(self.alloc, data);
        }
    }

    fn setStateUnknown(self: *WaylandXmlParser, parent: State) void {
        self.state = .unknown;
        self.unknown_level = 1;
        self.unknown_parent = parent;
    }
};

fn printWithUpperFirstChar(writer: anytype, s: []const u8) !void {
    switch (s.len) {
        0 => return,
        1 => try writer.writeByte(std.ascii.toUpper(s[0])),
        else => {
            const first_char = std.ascii.toUpper(s[0]);
            try writer.print("{c}{s}", .{ first_char, s[1..] });
        },
    }
}

const SnakeToPascal = struct {
    name: []const u8,

    pub fn format(
        self: *const SnakeToPascal,
        comptime _: []const u8,
        _: std.fmt.FormatOptions,
        writer: anytype,
    ) !void {
        var it = std.mem.splitScalar(u8, self.name, '_');
        while (it.next()) |elem| {
            try printWithUpperFirstChar(writer, elem);
        }
    }
};

fn snakeToPascal(s: []const u8) SnakeToPascal {
    return .{ .name = s };
}

const SnakeToCamel = struct {
    name: []const u8,

    pub fn format(
        self: *const SnakeToCamel,
        comptime _: []const u8,
        _: std.fmt.FormatOptions,
        writer: anytype,
    ) !void {
        var it = std.mem.splitScalar(u8, self.name, '_');
        const first = it.next() orelse return;
        try writer.writeAll(first);

        while (it.next()) |elem| {
            try printWithUpperFirstChar(writer, elem);
        }
    }
};

fn snakeToCamel(s: []const u8) SnakeToCamel {
    return .{ .name = s };
}

fn allArgsHaveKnownType(req: Interface.RequestEvent) bool {
    for (req.args) |arg| {
        if (arg.typ.toZigTypeString() == null) {
            return false;
        }
    }
    return true;
}

fn dodgeReservedKeyword(name: []const u8) []const u8 {
    if (std.mem.eql(u8, name, "error")) {
        return "err";
    }

    return name;
}

fn anyEventCanBeParsed(interface: Interface) bool {
    for (interface.events) |event| {
        if (allArgsHaveKnownType(event)) {
            return true;
        }
    }

    return false;
}

fn ZigBindingsWriter(comptime Writer: type) type {
    return struct {
        writer: Writer,

        const Self = @This();

        fn writeImports(self: *Self) !void {
            try self.writer.writeAll(
                \\const std = @import("std");
                \\const builtin = @import("builtin");
                \\const Allocator = std.mem.Allocator;
                \\const wlw = @import("wl_writer");
                \\const wlr = @import("wl_reader");
                \\const HeaderLE = wlw.HeaderLE;
                \\
                \\
            );
        }

        fn writeInterfaceStart(self: *Self, interface: Interface) !void {
            try self.writer.print(
                \\pub const {s} = struct {{
                \\    id: u32,
                \\
                \\
            , .{snakeToPascal(interface.name)});
        }

        fn writeInterfaceEnd(self: *Self) !void {
            try self.writer.writeAll("};\n\n");
        }

        fn writeInterfaceReqParams(self: *Self, req: Interface.RequestEvent, i: usize) !void {
            try self.writer.print(
                \\    pub const {s}Params = struct {{
                \\        pub const op = {d};
                \\
            ,
                .{ snakeToPascal(req.name), i },
            );

            for (req.args) |arg| {
                if (arg.typ == .new_id and !arg.has_interface) {
                    try self.writer.print(
                        "        {s}_interface: [:0]const u8,\n",
                        .{arg.name},
                    );
                    try self.writer.print(
                        "        {s}_interface_version: u32,\n",
                        .{arg.name},
                    );
                }
                try self.writer.print(
                    "        {s}: {s},\n",
                    .{ arg.name, arg.typ.toZigTypeString().? },
                );
            }
            try self.writer.writeAll("    };\n\n");
        }

        fn writeInterfaceReqFn(self: *Self, interface: Interface, req: Interface.RequestEvent) !void {
            try self.writer.print(
                \\    pub fn {s}(self: *const {s}, writer: anytype, params: {s}Params) !void {{
                \\        std.log.debug("Sending {s}::{s} {{any}} ", .{{ params }});
                \\        try wlw.writeWlMessage(writer, params, self.id);
                \\    }}
                \\
                \\
            , .{
                snakeToCamel(req.name),
                snakeToPascal(interface.name),
                snakeToPascal(req.name),
                interface.name,
                req.name,
            });
        }

        fn writeInterfaceReq(self: *Self, interface: Interface, req: Interface.RequestEvent, i: usize) !void {
            if (!allArgsHaveKnownType(req)) {
                return;
            }

            try self.writeInterfaceReqParams(req, i);
            try self.writeInterfaceReqFn(interface, req);
        }

        fn writeEventsStart(self: *Self) !void {
            try self.writer.writeAll(
                \\    pub const Event = union(enum) {
                \\
            );
        }

        fn writeEventsEnd(self: *Self) !void {
            try self.writer.writeAll(
                \\    };
                \\
            );
        }

        fn writeEventType(self: *Self, event: Interface.RequestEvent) !void {
            if (!allArgsHaveKnownType(event)) {
                return;
            }

            try self.writer.print(
                \\        pub const {s} = struct {{
                \\
            , .{snakeToPascal(event.name)});

            for (event.args) |arg| {
                if (arg.typ == .new_id and !arg.has_interface) {
                    try self.writer.print(
                        "            {s}_interface: [:0]const u8,\n",
                        .{arg.name},
                    );
                    try self.writer.print(
                        "            {s}_interface_version: u32,\n",
                        .{arg.name},
                    );
                }
                try self.writer.print(
                    "            {s}: {s},\n",
                    .{ arg.name, arg.typ.toZigTypeString().? },
                );
            }
            try self.writer.writeAll("        };\n\n");
        }

        /// name: Name
        fn writeEventField(self: *Self, event: Interface.RequestEvent) !void {
            if (allArgsHaveKnownType(event)) {
                try self.writer.print("        {s}: {s},\n", .{ dodgeReservedKeyword(event.name), snakeToPascal(event.name) });
            } else {
                try self.writer.print("        {s},\n", .{dodgeReservedKeyword(event.name)});
            }
        }

        fn writeEventParseStart(self: *Self) !void {
            try self.writer.writeAll(
                \\        pub fn parse(op: u32, data: []const u8) !Event {
                \\            return switch (op) {
                \\
            );
        }

        fn writeEventParseEnd(self: *Self, interface: Interface) !void {
            try self.writer.print(
                \\                else => {{
                \\                    std.log.warn("Unknown {s} event {{d}}", .{{op}});
                \\                    return error.UnknownEvent;
                \\                }}
                \\            }};
                \\        }}
                \\
            ,
                .{interface.name},
            );
        }

        fn writeEventParseStatement(self: *Self, event: Interface.RequestEvent, i: usize) !void {
            if (allArgsHaveKnownType(event)) {
                try self.writer.print(
                    \\               {d} => .{{ .{s} = try wlr.parseDataResponse({s}, data) }},
                    \\
                , .{
                    i,
                    dodgeReservedKeyword(event.name),
                    snakeToPascal(event.name),
                });
            } else {
                try self.writer.print(
                    \\               {d} => .{s},
                    \\
                , .{
                    i,
                    dodgeReservedKeyword(event.name),
                });
            }
        }

        fn writeInterface(self: *Self, interface: Interface) !void {
            try self.writeInterfaceStart(interface);

            for (interface.requests, 0..) |req, i| {
                try self.writeInterfaceReq(interface, req, i);
            }

            try self.writeEventsStart();

            for (interface.events) |event| {
                try self.writeEventField(event);
            }

            try self.writer.writeByte('\n');

            for (interface.events) |event| {
                try self.writeEventType(event);
            }

            if (anyEventCanBeParsed(interface)) {
                try self.writeEventParseStart();
                for (interface.events, 0..) |event, i| {
                    try self.writeEventParseStatement(event, i);
                }
                try self.writeEventParseEnd(interface);
            }

            try self.writeEventsEnd();
            try self.writeInterfaceEnd();
        }
    };
}

fn zigBindingsWriter(writer: anytype) ZigBindingsWriter(@TypeOf(writer)) {
    return .{
        .writer = writer,
    };
}

fn deinitInterfaces(alloc: Allocator, interfaces: []Interface) void {
    for (interfaces) |*interface| {
        interface.deinit(alloc);
    }
    alloc.free(interfaces);
}

fn parseWaylandXml(alloc: Allocator, wayland_xml_path: []const u8) ![]Interface {
    var wayland_parser = WaylandXmlParser{
        .alloc = alloc,
    };
    defer wayland_parser.deinit();

    var parser = try XmlParser.init(alloc, .{
        .ctx = &wayland_parser,
        .startElement = WaylandXmlParser.onEnter,
        .endElement = WaylandXmlParser.onExit,
        .charData = WaylandXmlParser.onCharData,
    });
    defer parser.deinit();

    const wayland_xml_file = try std.fs.cwd().openFile(wayland_xml_path, .{});
    defer wayland_xml_file.close();

    const wayland_xml_data = try wayland_xml_file.readToEndAlloc(alloc, 1e9);
    defer alloc.free(wayland_xml_data);

    try parser.feed(wayland_xml_data);

    return try wayland_parser.interfaces.toOwnedSlice(alloc);
}

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();

    const alloc = gpa.allocator();

    const args = try std.process.argsAlloc(alloc);
    defer std.process.argsFree(alloc, args);

    const wayland_xml_path = args[1];
    const output_path = args[2];

    const interfaces = try parseWaylandXml(alloc, wayland_xml_path);
    defer deinitInterfaces(alloc, interfaces);

    const output_file = try std.fs.cwd().createFile(output_path, .{});
    defer output_file.close();

    const output_writer = output_file.writer();
    var buffered_output = std.io.bufferedWriter(output_writer);

    var zig_writer = zigBindingsWriter(buffered_output.writer());
    try zig_writer.writeImports();

    for (interfaces) |interface| {
        try zig_writer.writeInterface(interface);
    }

    try buffered_output.flush();
}
