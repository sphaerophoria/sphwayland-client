#include <stdalign.h>
#include <sys/socket.h>
#include <string.h>

#include "cmsg.h"

size_t getCmsgSpace(size_t data_len) {
  return CMSG_SPACE(data_len);
}

void makeFdTransferCmsg(char* buf, char const* data, size_t data_len) {
  struct cmsghdr *cmsg = (struct cmsghdr*) buf;
  cmsg->cmsg_len = CMSG_LEN(4);
  cmsg->cmsg_level = SOL_SOCKET;
  cmsg->cmsg_type = SCM_RIGHTS;

  memcpy(CMSG_DATA(cmsg), data, data_len);
}
