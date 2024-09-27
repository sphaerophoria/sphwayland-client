#include <stdio.h>
#include <assert.h>
#include <unistd.h>
#include <stdlib.h>
#include <string.h>

#include "gl_impl.h"
#include <drm/drm_fourcc.h>

#include <sys/socket.h>
#include <sys/un.h>
#include <EGL/egl.h>
#include <EGL/eglext.h>


#define bindEglExtension(__type, __name) __type __name = (__type)eglGetProcAddress(#__name)

void debugCallback(GLenum source,GLenum type,GLuint id,GLenum severity,GLsizei length,const GLchar *message,const void *userParam) {
    printf("%*s\n", length, message);
}
 void debugCallbackEgl(
            EGLenum error,
            const char *command,
            EGLint messageType,
            EGLLabelKHR threadLabel,
            EGLLabelKHR objectLabel,
            const char* message) {
    printf("EGL error: 0x%x %s\n", error,  message);
 }


GLuint genTexture() {
    GLuint texture;
    glGenTextures(1, &texture);
    printf("generating texture: %d\n", texture);
    glBindTexture(GL_TEXTURE_2D, texture);
    glTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_MIN_FILTER, GL_LINEAR);
    glTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_MAG_FILTER, GL_LINEAR);
    glTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_WRAP_S, GL_CLAMP_TO_EDGE);
    glTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_WRAP_T, GL_CLAMP_TO_EDGE);

    return texture;
}

struct egl_params offscreenEGLinit(void) {
    EGLint major;
    EGLint minor;
    EGLint num_configs;
    EGLint attribs[] = {
        EGL_RENDERABLE_TYPE, EGL_OPENGL_BIT,
        EGL_NONE
    };


    EGLDisplay egl_display = eglGetDisplay(EGL_DEFAULT_DISPLAY);
    if(egl_display == EGL_NO_DISPLAY) {
        fprintf(stderr, "Couldn't get EGL display\n");
        exit(EXIT_FAILURE);
    }

    if(eglInitialize(egl_display, &major, &minor) != EGL_TRUE) {
        fprintf(stderr, "Couldnt initialize EGL\n");
        exit(EXIT_FAILURE);
    }

    eglBindAPI(EGL_OPENGL_API);

    EGLConfig config;
    if(eglChooseConfig(egl_display, attribs, &config, 1,
                &num_configs) != EGL_TRUE) {
        fprintf(stderr, "CouldnÄt find matching EGL config\n");
        exit(EXIT_FAILURE);
    }

    EGLContext egl_context = eglCreateContext(egl_display, config,
            EGL_NO_CONTEXT, NULL);
    if(egl_context == EGL_NO_CONTEXT) {
        fprintf(stderr, "Couldn't create EGL context\n");
        exit(EXIT_FAILURE);
    }

    if(!eglMakeCurrent(egl_display, EGL_NO_SURFACE,
                EGL_NO_SURFACE,  egl_context)) {
        fprintf(stderr, "Couldn't make EGL context current\n");
        exit(EXIT_FAILURE);
    }
    const GLubyte* ver = glGetString(GL_VERSION);
    printf("GL_VERSION=%s\n", ver);

    return (struct egl_params){
        egl_display, egl_context
    };
}

struct texture_fd makeTextureFileDescriptor(GLuint texture, EGLDisplay display, EGLContext context) {
    struct texture_fd ret = {0};
    EGLint attr[] = {
        EGL_NONE,
    };
    bindEglExtension(PFNEGLCREATEIMAGEKHRPROC, eglCreateImageKHR);
    bindEglExtension(PFNEGLEXPORTDMABUFIMAGEQUERYMESAPROC, eglExportDMABUFImageQueryMESA);
    bindEglExtension(PFNEGLEXPORTDMABUFIMAGEMESAPROC, eglExportDMABUFImageMESA);
    EGLImageKHR image = eglCreateImageKHR(display, context,  EGL_GL_TEXTURE_2D, (EGLClientBuffer)(uintptr_t)texture, attr);
    glFlush();


    int num_planes;
    EGLBoolean success = eglExportDMABUFImageQueryMESA(display, image, &ret.fourcc, &num_planes, &ret.modifiers);
    // FIXME: fail if not success
    printf("success: %d\n", success);
    printf("format \"%*s\"\n", 4, (char*)&ret.fourcc);
    printf("modifiers \"%lx\"\n", ret.modifiers);
    assert(num_planes == 1);

    // This is fine because there is only 1 plane (i think)
    success = eglExportDMABUFImageMESA(display, image, &ret.fd, &ret.stride, &ret.offset);
    // FIXME: fail if not success
    printf("success: %d\n", success);
    printf("stride %d\n", ret.stride);
    printf("offset %d\n", ret.offset);

    return ret;
}

GLuint makeFrameBuffer(GLuint texture) {
    GLuint fbo;
    glGenFramebuffers(1, &fbo);

    glBindFramebuffer(GL_FRAMEBUFFER, fbo);
    glFramebufferTexture2D(GL_FRAMEBUFFER, GL_COLOR_ATTACHMENT0, GL_TEXTURE_2D, texture, 0);
    return fbo;
}

GLuint makeTestTexture(uint32_t width, uint32_t height) {
    // Initialize texture data
    unsigned char data[width * height * 4]; // RGBA

    // Fill the texture with solid red color
    for (int i = 0; i < width * height; ++i) {
        int x = i % width;
        int y = i / width;
        data[i * 4 + 0] = x * 255 / width; // Red
        data[i * 4 + 1] = y * 255 / width;   // Green
        data[i * 4 + 2] = 0;   // Blue
        data[i * 4 + 3] = 255; // Alpha
    }

    GLuint texture = genTexture();
    glTexImage2D(GL_TEXTURE_2D, 0, GL_RGBA, width, height, 0, GL_RGBA, GL_UNSIGNED_BYTE, data);
    return texture;
}

#if 0
int main(int argc, char const *argv[]) {
    struct egl_params egl_params = offscreenEGLinit();

    // Initialize texture data
    const int width = 256;
    const int height = 256;
    unsigned char data[width * height * 4]; // RGBA

    // Fill the texture with solid red color
    for (int i = 0; i < width * height; ++i) {
        int x = i % width;
        int y = i / width;
        data[i * 4 + 0] = x * 255 / width; // Red
        data[i * 4 + 1] = y * 255 / width;   // Green
        data[i * 4 + 2] = 0;   // Blue
        data[i * 4 + 3] = 255; // Alpha
    }

    GLuint texture = genTexture();
    glTexImage2D(GL_TEXTURE_2D, 0, GL_RGBA, width, height, 0, GL_RGBA, GL_UNSIGNED_BYTE, data);

    makeFrameBuffer(texture);
    glClearColor(0.0, 1.0, 0.0, 1.0);
    glClear(GL_COLOR_BUFFER_BIT);

    int texture_fd = makeTextureFileDescriptor(texture, egl_params.display, egl_params.context);
    int socket_fd = connectToServer();
    sendFdToServer(socket_fd, texture_fd);
}
#endif
