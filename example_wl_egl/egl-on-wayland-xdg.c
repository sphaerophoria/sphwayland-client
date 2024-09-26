/* Compile with: wayland-scanner private-code /usr/share/wayland-protocols/stable/xdg-shell/xdg-shell.xml xdg-shell.c
 * wayland-scanner client-header /usr/share/wayland-protocols/stable/xdg-shell/xdg-shell.xml xdg-shell.h
 * gcc -c xdg-shell.c
 * gcc -c egl-on-wayland-xdg.c
 * gcc -o egl-on-wayland-xdg xdg-shell.o egl-on-wayland-xdg.o -lwayland-egl -lwayland-client -lEGL -lGL
 */
#include <stdio.h>
#include <assert.h>
#include <unistd.h>
#include <stdlib.h>
#include <string.h>
#define GL_GLEXT_PROTOTYPES
#include <GL/gl.h>
#include <GL/glext.h>
#include <drm/drm_fourcc.h>

#include <sys/socket.h>
#include <sys/un.h>
#include <wayland-egl.h>
#include <EGL/egl.h>
#include <EGL/eglext.h>

#include "xdg-shell.h"

struct client_state {
    struct wl_display *display;
    struct wl_registry *registry;
    struct wl_compositor *compositor;
    struct xdg_wm_base *xdg_wm_base;

    struct wl_surface *surface;
    struct xdg_surface *xdg_surface;
    struct xdg_toplevel *xdg_toplevel;
    struct wl_egl_window *egl_window;

    EGLDisplay egl_display;
    EGLConfig egl_config;
    EGLContext egl_context;
    EGLSurface egl_surface;

    int32_t width;
    int32_t height;
    uint8_t running;
};

/******************************/
/***********Registry***********/
/******************************/

static void global_registry(void *data, struct wl_registry *wl_registry,
        uint32_t name, const char *interface, uint32_t version) {
    struct client_state *state = data;

    if(!strcmp(interface, wl_compositor_interface.name)) {
        state->compositor = wl_registry_bind(wl_registry, name,
                &wl_compositor_interface, version);
    } else if(!strcmp(interface, xdg_wm_base_interface.name)) {
        state->xdg_wm_base = wl_registry_bind(wl_registry, name,
                &xdg_wm_base_interface, version);
    }
}

static void global_remove(void *data, struct wl_registry *wl_registry,
        uint32_t name) {
    (void) data;
    (void) wl_registry;
    (void) name;
}

static const struct wl_registry_listener registry_listener = {
    global_registry,
    global_remove
};

/******************************/
/******XDG Window Manager******/
/******************************/

static void wm_ping(void *data, struct xdg_wm_base *xdg_wm_base,
        uint32_t serial) {
    (void) data;
    xdg_wm_base_pong(xdg_wm_base, serial);
}

static const struct xdg_wm_base_listener wm_base_listener = {
    wm_ping
};

/******************************/
/*********XDG Surface**********/
/******************************/

static void surface_configure(void *data, struct xdg_surface *xdg_surface,
        uint32_t serial) {
    (void) data;

    xdg_surface_ack_configure(xdg_surface, serial);
}

static const struct xdg_surface_listener surface_listener = {
    surface_configure
};

/******************************/
/********XDG Toplevel**********/
/******************************/

static void toplevel_configure(void *data, struct xdg_toplevel *xdg_toplevel,
        int32_t width, int32_t height, struct wl_array *states) {
    struct client_state *state = data;
    (void) xdg_toplevel;
    (void) states;

    if(!width && !height) return;

    if(state->width != width || state->height != height) {
        state->width = width;
        state->height = height;

        wl_egl_window_resize(state->egl_window, width, height, 0, 0);
        wl_surface_commit(state->surface);
    }
}

static void toplevel_close(void *data, struct xdg_toplevel *xdg_toplevel) {
    (void) xdg_toplevel;

    struct client_state *state = data;

    state->running = 0;
}

static void toplevel_configure_bounds(void *data,
        struct xdg_toplevel *xdg_toplevel,
        int32_t width,
        int32_t height) {}
static void toplevel_wm_capabilities(void *data,
        struct xdg_toplevel *xdg_toplevel,
        struct wl_array *capabilities) {}

static const struct xdg_toplevel_listener toplevel_listener = {
    toplevel_configure,
    toplevel_close,
    toplevel_configure_bounds,
    toplevel_wm_capabilities,
};

/******************************/
/******************************/
/******************************/

static void wayland_connect(struct client_state *state) {
    state->display = wl_display_connect(NULL);
    if(!state->display) {
        fprintf(stderr, "Couldn't connect to wayland display\n");
        exit(EXIT_FAILURE);
    }

    state->registry = wl_display_get_registry(state->display);
    wl_registry_add_listener(state->registry, &registry_listener, state);
    wl_display_roundtrip(state->display);
    if(!state->compositor || !state->xdg_wm_base) {
        fprintf(stderr, "Couldn't find compositor or xdg shell\n");
        exit(EXIT_FAILURE);
    }

    xdg_wm_base_add_listener(state->xdg_wm_base, &wm_base_listener, NULL);

    state->surface = wl_compositor_create_surface(state->compositor);
    state->xdg_surface = xdg_wm_base_get_xdg_surface(state->xdg_wm_base,
            state->surface);
    xdg_surface_add_listener(state->xdg_surface, &surface_listener, NULL);
    state->xdg_toplevel = xdg_surface_get_toplevel(state->xdg_surface);
    xdg_toplevel_set_title(state->xdg_toplevel, "Hello World");
    xdg_toplevel_add_listener(state->xdg_toplevel, &toplevel_listener, state);
    wl_surface_commit(state->surface);
}

static void egl_init(struct client_state *state) {
    EGLint major;
    EGLint minor;
    EGLint num_configs;
    EGLint attribs[] = {
        EGL_RENDERABLE_TYPE, EGL_OPENGL_BIT,
        EGL_NONE
    };

    state->egl_window = wl_egl_window_create(state->surface, state->width,
            state->height);

    state->egl_display = eglGetDisplay((EGLNativeDisplayType) state->display);
    if(state->display == EGL_NO_DISPLAY) {
        fprintf(stderr, "Couldn't get EGL display\n");
        exit(EXIT_FAILURE);
    }

    if(eglInitialize(state->egl_display, &major, &minor) != EGL_TRUE) {
        fprintf(stderr, "Couldnt initialize EGL\n");
        exit(EXIT_FAILURE);
    }

    eglBindAPI(EGL_OPENGL_API);

    if(eglChooseConfig(state->egl_display, attribs, &state->egl_config, 1,
                &num_configs) != EGL_TRUE) {
        fprintf(stderr, "CouldnÄt find matching EGL config\n");
        exit(EXIT_FAILURE);
    }

    state->egl_surface = eglCreateWindowSurface(state->egl_display,
            state->egl_config,
            (EGLNativeWindowType) state->egl_window, NULL);
    if(state->egl_surface == EGL_NO_SURFACE) {
        fprintf(stderr, "Couldn't create EGL surface\n");
        exit(EXIT_FAILURE);
    }

    state->egl_context = eglCreateContext(state->egl_display, state->egl_config,
            EGL_NO_CONTEXT, NULL);
    if(state->egl_context == EGL_NO_CONTEXT) {
        fprintf(stderr, "Couldn't create EGL context\n");
        exit(EXIT_FAILURE);
    }

    if(!eglMakeCurrent(state->egl_display, state->egl_surface,
                state->egl_surface, state->egl_context)) {
        fprintf(stderr, "Couldn't make EGL context current\n");
        exit(EXIT_FAILURE);
    }
    const GLubyte* ver = glGetString(GL_VERSION);
    printf("GL_VERSION=%s\n", ver);
}

static void initShaders() {

    char buf[4096];
    int ret_len;
    int success = 0;
    // Shader setup
    GLuint vertexShader = glCreateShader(GL_VERTEX_SHADER);
    const char* vertexShaderSource = " \n\
#version 330 core \n\
                                      layout(location = 0) in vec2 aPos; \n\
                                      out vec2 texcoord;\n\
                                      \n\
                                      void main() { \n\
                                          // Hardcoded vertices for a quad \n\
                                          vec2 vertices[4]; \n\
                                          vertices[0] = vec2(-0.5, -0.5); \n\
                                          vertices[1] = vec2( 0.5, -0.5); \n\
                                          vertices[2] = vec2(-0.5,  0.5); \n\
                                          vertices[3] = vec2( 0.5,  0.5); \n\
                                          \n\
                                          vec2 vert = vertices[int(gl_VertexID)];\n\
                                          gl_Position = vec4(vert, 0.0, 1.0); \n\
                                          texcoord = vert + 0.5;\n\
                                      } \n\
                                      \n\
                                      ";
                                      glShaderSource(vertexShader, 1, &vertexShaderSource, NULL);
    glCompileShader(vertexShader);

    glGetShaderiv(vertexShader, GL_COMPILE_STATUS, &success);
    if (!success) {
        printf("Failed\n");
        glGetShaderInfoLog(vertexShader, 4096, NULL, buf);
        printf("%s\n",  buf);
    }

    GLuint fragmentShader = glCreateShader(GL_FRAGMENT_SHADER);
    const char* fragmentShaderSource = "\n\
#version 330 core\n\
                                        in vec2 texcoord;\n\
                                        out vec4 FragColor;\n\
                                        \n\
                                        uniform sampler2D tex;\n\
                                        \n\
                                        void main() {\n\
                                            FragColor = texture(tex, texcoord); // Red color\n\
                                        }\n\
                                        ";
                                        glShaderSource(fragmentShader, 1, &fragmentShaderSource, NULL);
    glCompileShader(fragmentShader);
    glGetShaderiv(fragmentShader, GL_COMPILE_STATUS, &success);
    if (!success) {
        printf("Failed frag shader\n");
        glGetShaderInfoLog(vertexShader, 4096, NULL, buf);
        printf("%s\n",  buf);
    }

    GLuint shaderProgram = glCreateProgram();
    glAttachShader(shaderProgram, vertexShader);
    glAttachShader(shaderProgram, fragmentShader);
    glLinkProgram(shaderProgram);

    // Set up vertex data (and buffer(s)) and configure vertex attributes
    glUseProgram(shaderProgram);
}

static void draw(struct client_state *state, GLuint textureID) {
    glClearColor(0.0, 0.0, 0.0, 1.0);
    glClear(GL_COLOR_BUFFER_BIT);

    glActiveTexture(GL_TEXTURE0);
    glBindTexture(GL_TEXTURE_2D, textureID);
    glDrawArrays(GL_TRIANGLE_STRIP, 0, 4);

    eglSwapBuffers(state->egl_display, state->egl_surface);
}

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
    printf("EGL error: %d %s\n", error,  message);
 }

int main(int argc, char const *argv[]) {
    struct client_state state;

    state.width = 800;
    state.height = 600;
    state.running = 1;

    wayland_connect(&state);
    egl_init(&state);

    if (argc < 2) {
        fprintf(stderr, "please tell us if we are a server or client\n");
        return 1;
    }

    glDebugMessageCallback(debugCallback, NULL);
    PFNEGLDEBUGMESSAGECONTROLKHRPROC eglDebugMessageControlKHR = (PFNEGLDEBUGMESSAGECONTROLKHRPROC)eglGetProcAddress("eglDebugMessageControlKHR");
    PFNEGLEXPORTDMABUFIMAGEQUERYMESAPROC eglExportDMABUFImageQueryMESA = (PFNEGLEXPORTDMABUFIMAGEQUERYMESAPROC)eglGetProcAddress("eglExportDMABUFImageQueryMESA");
    PFNEGLEXPORTDMABUFIMAGEMESAPROC eglExportDMABUFImageMESA = (PFNEGLEXPORTDMABUFIMAGEMESAPROC) eglGetProcAddress("eglExportDMABUFImageMESA");
    PFNEGLCREATEIMAGEKHRPROC eglCreateImageKHR = (PFNEGLCREATEIMAGEKHRPROC)eglGetProcAddress("eglCreateImageKHR");

    eglDebugMessageControlKHR(debugCallbackEgl, NULL);

    GLuint textureID;
    glGenTextures(1, &textureID);
    glBindTexture(GL_TEXTURE_2D, textureID);

    glTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_MIN_FILTER, GL_NEAREST);
    glTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_MAG_FILTER, GL_NEAREST);
    glTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_WRAP_S, GL_CLAMP_TO_EDGE);
    glTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_WRAP_T, GL_CLAMP_TO_EDGE);

    if (strcmp(argv[1], "server") == 0) {
        int fd = socket(AF_UNIX, SOCK_STREAM, 0);
        struct sockaddr_un name = {0};
        name.sun_family = AF_UNIX;
        strncpy(name.sun_path, "tex_socket", sizeof(name.sun_path) - 1);

        unlink("tex_socket");
        int ret = bind(fd, (const struct sockaddr *) &name,
                sizeof(name));
        if (ret == -1) {
            perror("bind");
            exit(EXIT_FAILURE);
        }

        /*
         * Prepare for accepting connections. The backlog size is set
         * to 20. So while one request is being processed other requests
         * can be waiting.
         */

        ret = listen(fd, 20);
        if (ret == -1) {
            perror("listen");
            exit(EXIT_FAILURE);
        }
        int data_socket = accept(fd, NULL, NULL);
        if (data_socket == -1) {
            perror("accept");
            exit(EXIT_FAILURE);
        }


        char cmsg_buf[CMSG_SPACE(sizeof(int))];
        char buf[1024];
        struct iovec iov;
        iov.iov_base = buf;
        iov.iov_len = 1024;
        struct msghdr hdr;
        hdr.msg_name = NULL;
        hdr.msg_namelen = 0;
        hdr.msg_iov = &iov;
        hdr.msg_iovlen = 1;
        hdr.msg_control = cmsg_buf;
        hdr.msg_controllen = sizeof(cmsg_buf);
        printf("control len: %lu\n", hdr.msg_controllen);
        ret = recvmsg(data_socket, &hdr, 0);
        if (ret == -1) {
            fprintf(stderr, "Failed to read from socket\n");
            exit(1);
        } else if (ret == 0) {
            fprintf(stderr, "Remote hung up");
            exit(1);

        }

        printf("control len: %lu\n", hdr.msg_controllen);

        struct cmsghdr* cmsg = CMSG_FIRSTHDR(&hdr);
        int* texture_fd = (int*)CMSG_DATA(cmsg);
        printf("texture fd: %d\n", *texture_fd);

        EGLAttrib atts[] = {
            // W, H used in TexImage2D above!
            EGL_WIDTH, 256,
            EGL_HEIGHT, 256,
            EGL_GL_TEXTURE_LEVEL, 1,
            EGL_LINUX_DRM_FOURCC_EXT, DRM_FORMAT_ABGR8888,
            EGL_DMA_BUF_PLANE0_FD_EXT, *texture_fd,
            EGL_DMA_BUF_PLANE0_OFFSET_EXT, 0,
            EGL_DMA_BUF_PLANE0_PITCH_EXT, 1024,
            EGL_NONE,
        };

        EGLImage image = eglCreateImage(state.egl_display, EGL_NO_CONTEXT,  EGL_LINUX_DMA_BUF_EXT, (EGLClientBuffer)(uintptr_t)0, atts);

        glBindTexture(GL_TEXTURE_2D, textureID);
        glEGLImageTargetTexture2DOES(GL_TEXTURE_2D, image);

    } else if (strcmp(argv[1], "client") == 0) {
        // Create and bind texture
        GLuint internalTextureId;
        glGenTextures(1, &internalTextureId);
        glBindTexture(GL_TEXTURE_2D, internalTextureId);

        // Set texture parameters
        glTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_WRAP_S, GL_REPEAT);
        glTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_WRAP_T, GL_REPEAT);
        glTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_MIN_FILTER, GL_NEAREST);
        glTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_MAG_FILTER, GL_NEAREST);

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

        // Upload texture data to GPU
        glTexImage2D(GL_TEXTURE_2D, 0, GL_RGBA, width, height, 0, GL_RGBA, GL_UNSIGNED_BYTE, data);
        glGenerateMipmap(GL_TEXTURE_2D); // Generate mipmaps

        EGLImageKHR image = eglCreateImageKHR(state.egl_display, state.egl_context,  EGL_GL_TEXTURE_2D, (EGLClientBuffer)(uintptr_t)internalTextureId, NULL);

        glBindTexture(GL_TEXTURE_2D, textureID);
        glEGLImageTargetTexture2DOES(GL_TEXTURE_2D, image);

        int fourcc;
        int num_planes;
        EGLuint64KHR modifiers;
        EGLBoolean success = eglExportDMABUFImageQueryMESA(state.egl_display, image, &fourcc, &num_planes, &modifiers);
        printf("success: %d\n", success);
        printf("format \"%*s\"\n", 4, (char*)&fourcc);
        assert(num_planes == 1);


        // This is fine because there is only 1 plane (i think)
        int fd;
        int stride;
        int offset;
        success = eglExportDMABUFImageMESA(state.egl_display, image, &fd, &stride, &offset);
        printf("success: %d\n", success);
        printf("stride %d\n", stride);
        printf("offset %d\n", offset);

        int socket_fd = socket(AF_UNIX, SOCK_STREAM, 0);
        struct sockaddr_un name = {0};
        name.sun_family = AF_UNIX;
        strncpy(name.sun_path, "tex_socket", sizeof(name.sun_path) - 1);

        int ret = connect(socket_fd, (const struct sockaddr *) &name, sizeof(name));
        if (ret == -1) {
            perror("connect");
            exit(EXIT_FAILURE);
        }


        char cmsg_buf[CMSG_SPACE(sizeof(int))];
        struct iovec iov;
        iov.iov_base = "asdf";
        iov.iov_len = 4;
        struct msghdr hdr = {0};
        hdr.msg_name = NULL;
        hdr.msg_namelen = 0;
        hdr.msg_iov = &iov;
        hdr.msg_iovlen = 1;
        hdr.msg_control = cmsg_buf;
        hdr.msg_controllen = sizeof(cmsg_buf);
        struct cmsghdr* cmsg_hdr = CMSG_FIRSTHDR(&hdr);
        cmsg_hdr->cmsg_len = CMSG_LEN(sizeof(int));
        cmsg_hdr->cmsg_level = SOL_SOCKET;
        cmsg_hdr->cmsg_type = SCM_RIGHTS;
        memcpy(CMSG_DATA(cmsg_hdr), &fd, 4);
        printf("%d\n", *(int*)CMSG_DATA(cmsg_hdr));

        if (sendmsg(socket_fd, &hdr, 0) == -1) {
            perror("sendmsg");
            fprintf(stderr, "Failed to write to socket\n");
            exit(1);
        }

        //while (1) {
        //    sleep(1);
        //}
    }


    initShaders();

    while(state.running) {
        wl_display_dispatch_pending(state.display);
        draw(&state, textureID);
    }

    eglDestroySurface(state.egl_display, state.egl_surface);
    eglDestroyContext(state.egl_display, state.egl_context);
    wl_egl_window_destroy(state.egl_window);
    xdg_toplevel_destroy(state.xdg_toplevel);
    xdg_surface_destroy(state.xdg_surface);
    wl_surface_destroy(state.surface);
    wl_display_disconnect(state.display);

    return 0;
}
