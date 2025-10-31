#include <sys/socket.h>
#include <stdlib.h>
#include <stdio.h>
#include <stddef.h>

// wayland commit 73d4a53672c66fb2ad9576545a5aae3bad2483ed explains that the
// number of file descriptors they will send is purely tied to the size of their
// own internal read buffer impl. We need to support at least as many as them,
// so we just match what they did
#define MAX_NUM_FDS 28

int main(int argc, char** argv) {

  FILE* out = fopen(argv[1], "w");

  size_t fd_size = sizeof(int) * MAX_NUM_FDS;
  struct cmsghdr cmsg;

  fprintf(
      out,
      "pub const fd_cmsg_space = %lu;\n"
      "pub const fd_cmsg_data_offs = %lu;\n",
      CMSG_SPACE(fd_size),
      CMSG_LEN(0)
  );
}
