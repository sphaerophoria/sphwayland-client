#include <sys/socket.h>
#include <stdio.h>
#include <stddef.h>

int main(int argc, char** argv) {
  size_t fd_size = sizeof(int);

  FILE* out = fopen(argv[1], "w");

  struct cmsghdr cmsg;
  ptrdiff_t cmsg_base = CMSG_DATA(&cmsg) - (unsigned char*)&cmsg;
  fprintf(
      out,
      "pub const fd_cmsg_space = %u;\n"
      "pub const fd_cmsg_len = %u;\n"
      "pub const fd_cmsg_data_offs = %u;\n",
      CMSG_SPACE(fd_size),
      CMSG_LEN(fd_size),
      cmsg_base
  );

}
