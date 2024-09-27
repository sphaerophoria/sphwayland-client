const std = @import("std");
const Allocator = std.mem.Allocator;

const c = @cImport({
    @cDefine("GL_GLEXT_PROTOTYPES", "1");
    @cInclude("GL/gl.h");
    @cInclude("GL/glext.h");
    @cInclude("stb_image.h");
});

const ModelRenderer = @This();

model_transform: Mat4 = Mat4.identity(),
fov: f32 = std.math.pi / 4.0,
buffers: BufferPair,
program: c.GLuint,
num_vertices: c_int,
transform_loc: c_int,
texture: c.GLuint,


// FIXME: deinit
pub fn init(alloc: Allocator) !ModelRenderer {
    const model = try Model.load(alloc, "untitled.obj");
    const buffers = try bindModel(alloc, model);
    const img = try Img.init("Untitled.001.png");
    const texture = texFromImg(img);
    const program = try compileLinkProgram(@embedFile("vertex.glsl"), @embedFile("fragment.glsl"));
    const transform_loc = c.glGetUniformLocation(program, "transform");
    const num_vertices: c_int =  @intCast(model.faces.len * 3);

    // FIXME: This should arguably be set by whoever calls us
    setGlParams();

    return .{
        .buffers = buffers,
        .program = program,
        .transform_loc = transform_loc,
        .num_vertices = num_vertices,
        .texture = texture,
    };
}

pub fn render(self: *ModelRenderer, aspect: f32) void {
    c.glUseProgram(self.program);
    c.glBindVertexArray(self.buffers.vao);
    c.glActiveTexture(c.GL_TEXTURE0); // activate the texture unit first before binding texture
    c.glBindTexture(c.GL_TEXTURE_2D, self.texture);

    const perspective = Mat4.perspective(self.fov, 0.1, aspect);
    const transform = perspective.matmul(Mat4.translation(0.0, 0.0, -10.0).matmul(self.model_transform));
    c.glUniformMatrix4fv(self.transform_loc, 1, 1, @ptrCast(&transform));
    c.glDrawArrays(c.GL_TRIANGLES, 0, self.num_vertices);
}

// x and y movement are normalized to width and height
pub fn applyMouseMovement(self: *ModelRenderer, x_movement: f32, y_movement: f32, aspect: f32) void {
    var x_rot = Mat4.rotAroundY(4.0 * x_movement * aspect);
    var y_rot = Mat4.rotAroundX(4.0 * y_movement);
    self.model_transform = y_rot.matmul(x_rot.matmul(self.model_transform));
}

const fov_adjustment_amount = 0.1;
pub fn zoomIn(self: *ModelRenderer) void {
    self.fov -= fov_adjustment_amount;
    self.fov = std.math.clamp(self.fov, 0.0001, std.math.pi);
}

pub fn zoomOut(self: *ModelRenderer) void {
    self.fov += fov_adjustment_amount;
    self.fov = std.math.clamp(self.fov, 0.0001, std.math.pi);
}

// FIXME: We don't need all of these certainly
fn setGlParams() void {
    // App draws all streets with one drawElements
    c.glEnable(c.GL_PRIMITIVE_RESTART);
    c.glPrimitiveRestartIndex(0xffffffff);

    c.glEnable(c.GL_DEPTH_TEST);
    c.glDepthFunc(c.GL_LESS);

    // App sets point size in shaders
    c.glEnable(c.GL_PROGRAM_POINT_SIZE);

    // We want our lines to be pretty
    c.glEnable(c.GL_MULTISAMPLE);
    c.glEnable(c.GL_LINE_SMOOTH);
    c.glEnable(c.GL_BLEND);
    c.glBlendFunc(c.GL_SRC_ALPHA, c.GL_ONE_MINUS_SRC_ALPHA);
    c.glLineWidth(2.0);
}


fn compileLinkProgram(vs: []const u8, fs: []const u8) !c.GLuint {
    const vertex_shader = c.glCreateShader(c.GL_VERTEX_SHADER);
    const vs_len_i: i32 = @intCast(vs.len);
    c.glShaderSource(vertex_shader, 1, &vs.ptr, &vs_len_i);
    c.glCompileShader(vertex_shader);
    // FIXME: getShaderIv compile status
    var success: c_int = 0;
    c.glGetShaderiv(vertex_shader, c.GL_COMPILE_STATUS, &success);
    if (success == 0) {
        return error.VertexShaderCompile;
    }


    const fragment_shader = c.glCreateShader(c.GL_FRAGMENT_SHADER);
    const fs_len_i: i32 = @intCast(fs.len);
    c.glShaderSource(fragment_shader, 1, &fs.ptr, &fs_len_i);
    c.glCompileShader(fragment_shader);
    c.glGetShaderiv(fragment_shader, c.GL_COMPILE_STATUS, &success);
    if (success == 0) {
        return error.FragmentShaderCompile;
    }

    const program = c.glCreateProgram();
    c.glAttachShader(program, vertex_shader);
    c.glAttachShader(program, fragment_shader);
    c.glLinkProgram(program);
    return program;
}

const Vec4 = struct {
    inner: [4]f32,

    fn dot(a: Vec4, b: Vec4) f32 {
        var sum: f32 = 0;
        for (0..4) |i| {
            sum += a.inner[i] * b.inner[i];
        }
        return sum;
    }
};

const Mat4 = struct {
    inner: [4]Vec4,

    fn matmul(self: Mat4, mat: Mat4) Mat4 {
        var ret: Mat4 = undefined;
        for (0..4) |y| {
            for (0..4) |x| {
                var sum: f32 = 0;
                for (0..4) |i| {
                    const a = self.inner[y].inner[i];
                    const b = mat.inner[i].inner[x];
                    sum += a * b;
                }

                ret.inner[y].inner[x] = sum;
            }
        }

        return ret;
    }

    fn mul(self: Mat4, vec: Vec4) Vec4 {
        return .{
            .inner = .{
                self.inner[0].dot(vec),
                self.inner[1].dot(vec),
                self.inner[2].dot(vec),
                self.inner[3].dot(vec),
            }
        };
    }

    fn rotAroundY(rot: f32) Mat4 {
        const cos = @cos(rot);
        const sin = @sin(rot);
        const inner: [4]Vec4 = .{
            .{ .inner = .{ cos, 0, -sin, 0} } ,
            .{ .inner = .{   0, 1,    0, 0} } ,
            .{ .inner = .{ sin, 0,  cos, 0} } ,
            .{ .inner = .{   0, 0,    0, 1} } ,
        };
        return .{ .inner = inner };
    }

    fn rotAroundX(rot: f32) Mat4 {
        const cos = @cos(rot);
        const sin = @sin(rot);
        const inner: [4]Vec4 = .{
            .{ .inner = .{ 1,   0,    0, 0} } ,
            .{ .inner = .{ 0, cos, -sin, 0} } ,
            .{ .inner = .{ 0, sin,  cos, 0} } ,
            .{ .inner = .{ 0,   0,    0, 1} } ,
        };
        return .{ .inner = inner };
    }

    // https://www.songho.ca/opengl/gl_projectionmatrix.html
    fn perspective(fov: f32, n: f32, aspect: f32) Mat4 {
        const t = @tan(fov / 2) * n;
        const r = t * aspect;

        const inner: [4]Vec4 = .{
            .{ .inner = .{ n / r,     0,  0,      0} } ,
            .{ .inner = .{ 0    , n / t,  0,      0} } ,
            .{ .inner = .{ 0    ,     0, -1, -2 * n} } ,
            .{ .inner = .{ 0    ,     0, -1,      0} } ,
        };

        return Mat4 {
            .inner = inner,
        };
    }

    fn translation(x: f32, y: f32, z: f32) Mat4 {
        return .{ .inner = .{
            .{ .inner = .{ 1.0,   0,   0,   x} },
            .{ .inner = .{   0, 1.0,   0,   y} },
            .{ .inner = .{   0,   0, 1.0,   z} },
            .{ .inner = .{   0,   0, 0.0, 1.0} },
        }};
    }

    fn scale(x: f32, y: f32, z: f32) Mat4 {
        return .{ .inner = .{
            .{ .inner = .{   x,   0,   0,   0} },
            .{ .inner = .{   0,   y,   0,   0} },
            .{ .inner = .{   0,   0,   z,   0} },
            .{ .inner = .{   0,   0, 0.0, 1.0} },
        }};
    }

    fn identity() Mat4 {
        return .{ .inner = .{
            .{ .inner = .{ 1.0,   0,   0,   0} },
            .{ .inner = .{   0, 1.0,   0,   0} },
            .{ .inner = .{   0,   0, 1.0,   0} },
            .{ .inner = .{   0,   0, 0.0, 1.0} },
        }};
    }
};

test "matmul" {
    const a = Mat4 {
        .inner = .{
            .{ .inner = .{ 0, 1, 2, 3 } },
            .{ .inner = .{ 4, 5, 6, 7} },
            .{ .inner = .{ 8, 9, 10, 11} },
            .{ .inner = .{ 12, 13, 14, 15} },
        },
    };

    const b = Mat4 {
        .inner = .{
            .{ .inner = .{ 1, 2, 3, 4 } },
            .{ .inner = .{ 5, 6, 7, 8 } },
            .{ .inner = .{ 9, 10, 11, 12} },
            .{ .inner = .{ 13, 14, 15, 16} },
        },
    };

    const ret = a.matmul(b);
    const expected = Mat4 {
        .inner = .{
           .{ .inner = .{ 62,  68,  74,  80 } },
           .{ .inner = .{174, 196, 218, 240 } },
           .{ .inner = .{286, 324, 362, 400 } },
           .{ .inner = .{398, 452, 506, 560 } },
        }
    };


    for (0..4) |i| {
        try std.testing.expectApproxEqAbs(expected.inner[0].inner[i], ret.inner[0].inner[i], 0.001);
        try std.testing.expectApproxEqAbs(expected.inner[1].inner[i], ret.inner[1].inner[i], 0.001);
        try std.testing.expectApproxEqAbs(expected.inner[2].inner[i], ret.inner[2].inner[i], 0.001);
        try std.testing.expectApproxEqAbs(expected.inner[3].inner[i], ret.inner[3].inner[i], 0.001);
    }
}

test "matvecmul" {
    const a = Mat4 {
        .inner = .{
            .{ .inner = .{ 0, 1, 2, 3 } },
            .{ .inner = .{ 4, 5, 6, 7} },
            .{ .inner = .{ 8, 9, 10, 11} },
            .{ .inner = .{ 12, 13, 14, 15} },
        },
    };

    const b = Vec4 { .inner = .{ 1, 2, 3, 4 } };

    const ret = a.mul(b);
    const expected = Vec4 {
        .inner = .{
            0 + 2 + 6 + 12,
            4 + 10 + 18 + 28,
            8 + 18 + 30 + 44,
            12 + 26 + 42 + 60,
        }
    };

    try std.testing.expectApproxEqAbs(expected.inner[0], ret.inner[0], 0.001);
    try std.testing.expectApproxEqAbs(expected.inner[1], ret.inner[1], 0.001);
    try std.testing.expectApproxEqAbs(expected.inner[2], ret.inner[2], 0.001);
    try std.testing.expectApproxEqAbs(expected.inner[3], ret.inner[3], 0.001);

}

const Vert = struct {
    x: f32,
    y: f32,
    z: f32,
};

const Uv = struct {
    u: f32,
    v: f32,
};

const Face = struct {
    vert_ids: [3]u32,
    uv_ids: [3]u32,
};

fn nextAsF32(it: anytype) !f32 {
    const s = it.next() orelse return error.InvalidF32;
    return try std.fmt.parseFloat(f32, s);
}

const Model = struct {
    // Grouped in 3s
    verts: []Vert,
    // Grouped in 2s
    uvs: []Uv,
    // Grouped in 3s, indexes into vertices
    faces: []Face,

    fn load(alloc: Allocator, obj_path: []const u8) !Model {
        const f = try std.fs.cwd().openFile(obj_path, .{});
        defer f.close();

        const data = try f.readToEndAlloc(alloc, 10_000_000);
        defer alloc.free(data);

        var line_it = std.mem.splitScalar(u8, data, '\n');

        var verts = std.ArrayList(Vert).init(alloc);
        defer verts.deinit();

        var uvs = std.ArrayList(Uv).init(alloc);
        defer uvs.deinit();

        var faces = std.ArrayList(Face).init(alloc);
        defer faces.deinit();

        while (line_it.next()) |line| {
            if (std.mem.startsWith(u8, line, "v ")) {
                var vert_it = std.mem.splitScalar(u8, line, ' ');
                _ = vert_it.next();

                const vert = Vert{
                    .x = try nextAsF32(&vert_it),
                    .y = try nextAsF32(&vert_it),
                    .z = try nextAsF32(&vert_it),
                };

                try verts.append(vert);

                if (vert_it.next()) |_| {
                    std.log.warn("Unexpected 4th vertex dimension", .{});
                }
            }
            else if (std.mem.startsWith(u8, line, "vt ")) {
                var uv_it = std.mem.splitScalar(u8, line, ' ');
                _ = uv_it.next();

                const uv = Uv{
                    .u = try nextAsF32(&uv_it),
                    .v = try nextAsF32(&uv_it),
                };

                try uvs.append(uv);

                if (uv_it.next()) |_| {
                    std.log.warn("Unexpected 3rd uv dimension", .{});
                }
            }
            else if (std.mem.startsWith(u8, line, "f ")) {
                var face_it = std.mem.splitScalar(u8, line, ' ');
                _ = face_it.next();

                var vert_ids: [3]u32 = undefined;
                var uv_ids: [3]u32 = undefined;

                for (0..3) |i| {
                    const face = face_it.next() orelse return error.InvalidFace;
                    var component_it = std.mem.splitScalar(u8, face, '/');

                    const vert_id_s = component_it.next() orelse return error.NoFaceVertex;
                    const vert_id = try std.fmt.parseInt(u32, vert_id_s, 10) - 1;

                    const uv_id_s = component_it.next() orelse return error.NoFaceUV;
                    const uv_id = try std.fmt.parseInt(u32, uv_id_s, 10) - 1;

                    vert_ids[i] = vert_id;
                    uv_ids[i] = uv_id;
                }

                try faces.append(Face {
                    .vert_ids = vert_ids,
                    .uv_ids = uv_ids,
                });

                if (face_it.next()) |_| {
                    std.log.err("Faces should be triangulated", .{});
                    return error.NonTriangulatedMesh;
                }

            }
        }

        return .{
            .verts = try verts.toOwnedSlice(),
            .uvs = try uvs.toOwnedSlice(),
            .faces = try faces.toOwnedSlice(),
        };
    }
};


const BufferPair = struct {
    vao: c.GLuint,
    vbo: c.GLuint,
};

// FIXME: Direct state access (named buffers and stuff)
fn bindModel(alloc: Allocator, model: Model) !BufferPair {

    var vertex_buffer = try std.ArrayList(f32).initCapacity(alloc, model.faces.len * 15);
    defer vertex_buffer.deinit();

    for (model.faces) |face| {
        for (0..3) |i| {
            const vert = model.verts[face.vert_ids[i]];
            const uv = model.uvs[face.uv_ids[i]];

            try vertex_buffer.appendSlice(&.{vert.x, vert.y, vert.z, uv.u, uv.v});
        }
    }
    std.debug.assert(vertex_buffer.items.len == model.faces.len  * 15);

    var vao: c.GLuint = 0;
    c.glGenVertexArrays(1, &vao);
    c.glBindVertexArray(vao);

    var vbo: c.GLuint = 0;
    c.glGenBuffers(1, &vbo);
    c.glBindBuffer(c.GL_ARRAY_BUFFER, vbo);

    c.glBufferData(c.GL_ARRAY_BUFFER, @intCast(@sizeOf(f32) * vertex_buffer.items.len), vertex_buffer.items.ptr, c.GL_STATIC_DRAW);

    c.glVertexAttribPointer(0, 3, c.GL_FLOAT, c.GL_FALSE, 5 * @sizeOf(f32), @ptrFromInt(0));
    c.glEnableVertexAttribArray(0);

    c.glVertexAttribPointer(1, 2, c.GL_FLOAT, c.GL_FALSE, 5 * @sizeOf(f32), @ptrFromInt(12));
    c.glEnableVertexAttribArray(1);

    return .{
        .vao = vao,
        .vbo = vbo,
    };
}

const Img = struct {
    data: []u32,
    width: usize,

    pub fn init(path: [:0]const u8) !Img {
        var width: c_int = 0;
        var height_out: c_int = 0;
        c.stbi_set_flip_vertically_on_load(1);
        const img_opt = c.stbi_load(path, &width, &height_out, null, 4);
        const img_ptr: [*]u8 = img_opt orelse return error.FailedToOpen;
        const img_u32: [*]u32 = @ptrCast(@alignCast(img_ptr));

        return .{
            .data = img_u32[0..@intCast(width * height_out)],
            .width = @intCast(width),
        };
    }

    pub fn height(self: Img) usize {
        return self.data.len / self.width;
    }
};


fn texFromImg(img: Img) c.GLuint {
    var texture: c.GLuint = 0;
    c.glGenTextures(1, &texture);

    c.glBindTexture(c.GL_TEXTURE_2D, texture);
    c.glTexParameteri(c.GL_TEXTURE_2D, c.GL_TEXTURE_MIN_FILTER, c.GL_NEAREST);
    c.glTexParameteri(c.GL_TEXTURE_2D, c.GL_TEXTURE_MAG_FILTER, c.GL_LINEAR);

    c.glTexImage2D(c.GL_TEXTURE_2D, 0, c.GL_RGBA, @intCast(img.width), @intCast(img.height()), 0, c.GL_RGBA, c.GL_UNSIGNED_BYTE, img.data.ptr);

    return texture;
}

