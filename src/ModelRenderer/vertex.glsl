#version 330 core
layout (location = 0) in vec3 aPos;
layout (location = 1) in vec2 in_uv;

uniform mat4 transform;

out float depth;
out vec2 uv;

vec2 verts[3] = vec2[](
    vec2(0.0, 0.5),
    vec2(-0.5, -0.5),
    vec2(0.5, -0.5)
);
void main()
{
        //gl_Position = vec4(verts[gl_VertexID], 0.0, 1.0);
        gl_Position = vec4(transform * vec4(aPos, 1.0));
        depth = gl_Position.z;
        //gl_Position = vec4(aPos, 1.0);
        uv = in_uv;
}
