#define GL_GLEXT_PROTOTYPES
#include <GL/gl.h>
#include <GL/glext.h>
#include <EGL/egl.h>

struct egl_params {
    EGLDisplay display;
    EGLContext context;
};

struct texture_fd {
	int fd;
	int fourcc;
	uint64_t modifiers;
	int stride;
	int offset;
};

struct egl_params offscreenEGLinit(void);
GLuint makeTestTexture(uint32_t width, uint32_t height);
struct texture_fd makeTextureFileDescriptor(GLuint texture, EGLDisplay display, EGLContext context);
GLuint makeFrameBuffer(GLuint texture);
